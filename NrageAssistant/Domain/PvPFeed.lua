local _, ns = ...

-- The guild kill feed: who killed whom, shown to the members that run the addon. Nothing here touches the client:
-- the clock, the timer, the transport and the lockdown state are injected, so the rules are tested with fakes.
--
-- Sending (own kills):
--   * The client gives two events for one kill, an honour credit and a killing blow, in either order. Both call
--     Own(): an event for a victim that already has an entry younger than PVP_FEED_MERGE_SECONDS joins that entry
--     (a blow sets `blow`), otherwise it starts one. Group credit therefore produces one entry per honour kill.
--     A killing blow without honour (a grey target) has no honour event to wait for and is sent alone, with
--     `blow = true`; an honour kill without a blow is sent with `blow = false`.
--   * An entry waits PVP_FEED_MERGE_SECONDS before it is sent, so the second event can still join it. Then it is
--     sent only if the setting of its place is on, not during the encounter lockdown (dropped, never queued) and
--     not beyond PVP_FEED_MAX_PER_MINUTE in a rolling minute (the extra ones are dropped).
--
-- Receiving: OnReceived() keeps the last PVP_FEED_MAX entries in memory (newest first, never saved). The killer is
-- always the sender. An entry about a victim already in the list, seen within PVP_FEED_DEDUPE_SECONDS, is the same
-- kill (several members get honour for it): the sender joins its killers, bounded, and no new chat line is wanted.
-- Own kills are added to the list too, since own messages are never received.
--
-- deps = { now = function() -> seconds (monotonic), serverTime = function() -> seconds (for display),
--          send = function(payload) -> ok, isLocked = function() -> boolean, schedule = function(delay, fn),
--          settings = function() -> { feedWorld, feedBg }, ownName = function() -> string,
--          onChange = function() (optional) }
local PvPFeed = {}
PvPFeed.__index = PvPFeed

local WINDOW_SECONDS = 60
local SETTING_OF = { world = "feedWorld", bg = "feedBg" }

-- db.global.settings.pvp, created and repaired as needed: { feedWorld = boolean, feedBg = boolean }. A missing or
-- non-boolean field gets its default. Returns the table stored in `db`, so changes to it are saved.
function PvPFeed.Settings(db)
  local global = db.global
  global.settings = type(global.settings) == "table" and global.settings or {}
  local settings = global.settings
  settings.pvp = type(settings.pvp) == "table" and settings.pvp or {}
  for key, default in pairs(ns.Constants.PVP_FEED_DEFAULTS) do
    if type(settings.pvp[key]) ~= "boolean" then
      settings.pvp[key] = default
    end
  end
  return settings.pvp
end

function PvPFeed.New(deps)
  return setmetatable({
    deps = deps,
    list = {},
    own = {},
    sentAt = {},
    senders = {},
    senderCount = 0,
    -- Which sources of a victim name this client has; set by the wiring at start-up.
    honorNames = false,
    blowNames = false,
  }, PvPFeed)
end

-- Can this client ever give the name of a killed player?
function PvPFeed:Available()
  return self.honorNames or self.blowNames
end

function PvPFeed:Entries()
  return self.list
end

-- Is the feed on for `where` ("world" | "bg")? Sharing and showing are one switch.
function PvPFeed:Enabled(where)
  local key = SETTING_OF[where]
  if not key then
    return false
  end
  local ok, settings = pcall(self.deps.settings)
  if not ok or type(settings) ~= "table" then
    return false
  end
  local value = settings[key]
  if type(value) ~= "boolean" then
    value = ns.Constants.PVP_FEED_DEFAULTS[key]
  end
  return value
end

function PvPFeed:Changed()
  if self.deps.onChange then
    self.deps.onChange()
  end
end

local function validKill(victim, where)
  return ns.Validate.Text(victim, ns.Constants.PVP_FEED_VICTIM_MAX) and SETTING_OF[where] ~= nil
end

function PvPFeed:Add(entry)
  local list = self.list
  table.insert(list, 1, entry)
  while #list > ns.Constants.PVP_FEED_MAX do
    list[#list] = nil
  end
end

-- Sends `entry` when the rules allow it. Returns true, or false plus "off" | "locked" | "limit" | the reason the
-- transport gave.
function PvPFeed:Flush(entry)
  if not self:Enabled(entry.where) then
    return false, "off"
  end
  local lockedOk, locked = pcall(self.deps.isLocked)
  if not lockedOk or locked then
    return false, "locked"
  end

  local now = self.deps.now()
  local kept = {}
  for _, at in ipairs(self.sentAt) do
    if now - at < WINDOW_SECONDS then
      kept[#kept + 1] = at
    end
  end
  self.sentAt = kept
  if #kept >= ns.Constants.PVP_FEED_MAX_PER_MINUTE then
    return false, "limit"
  end

  local ok, sent, reason = pcall(self.deps.send, { victim = entry.victim, where = entry.where, blow = entry.blow })
  if not ok or not sent then
    return false, ok and reason or "error"
  end
  kept[#kept + 1] = now
  return true
end

-- An own kill, from the honour message (`blow` false) or from the killing blow (`blow` true). Returns true when
-- it started a new entry, false when it joined one or was refused (an unusable victim name or place).
function PvPFeed:Own(victim, where, blow)
  if not validKill(victim, where) then
    return false
  end
  local now = self.deps.now()
  local recent = {}
  local key = victim:lower()
  for _, entry in ipairs(self.own) do
    if now - entry.at <= ns.Constants.PVP_FEED_MERGE_SECONDS then
      recent[#recent + 1] = entry
    end
  end
  self.own = recent
  for _, entry in ipairs(recent) do
    if entry.key == key then
      entry.blow = entry.blow or blow
      return false
    end
  end

  local entry = {
    victim = victim,
    key = key,
    where = where,
    blow = blow,
    killers = { self.deps.ownName() or "You" },
    at = now,
    time = self.deps.serverTime(),
    own = true,
  }
  recent[#recent + 1] = entry
  if self:Enabled(where) then
    self:Add(entry)
    self:Changed()
  end
  self.deps.schedule(ns.Constants.PVP_FEED_MERGE_SECONDS, function()
    self:Flush(entry)
  end)
  return true
end

function PvPFeed:OnHonorKill(victim, where)
  return self:Own(victim, where, false)
end

function PvPFeed:OnKillingBlow(victim, where)
  return self:Own(victim, where, true)
end

-- At most PVP_FEED_MAX_PER_MINUTE entries per sender per rolling minute, and a bounded number of senders.
function PvPFeed:AllowFrom(sender, now)
  local constants = ns.Constants
  local times = self.senders[sender]
  if not times then
    if self.senderCount >= constants.PVP_FEED_SENDERS_MAX then
      for name, list in pairs(self.senders) do
        if now - list[#list] >= WINDOW_SECONDS then
          self.senders[name] = nil
          self.senderCount = self.senderCount - 1
        end
      end
      if self.senderCount >= constants.PVP_FEED_SENDERS_MAX then
        return false
      end
    end
    times = {}
    self.senders[sender] = times
    self.senderCount = self.senderCount + 1
  end
  local kept = {}
  for _, at in ipairs(times) do
    if now - at < WINDOW_SECONDS then
      kept[#kept + 1] = at
    end
  end
  if #kept >= constants.PVP_FEED_MAX_PER_MINUTE then
    self.senders[sender] = kept
    return false
  end
  kept[#kept + 1] = now
  self.senders[sender] = kept
  return true
end

-- A validated PVP_KILL payload from `sender`. Returns whether a chat line should be shown, and the entry it is
-- about (the new one, or the one the sender was added to).
function PvPFeed:OnReceived(sender, payload, now)
  if type(sender) ~= "string" or type(payload) ~= "table" or not validKill(payload.victim, payload.where) then
    return false
  end
  if not self:Enabled(payload.where) then
    return false
  end
  now = now or self.deps.now()
  if not self:AllowFrom(sender, now) then
    return false
  end

  local constants = ns.Constants
  local key = payload.victim:lower()
  for _, entry in ipairs(self.list) do
    if entry.key == key and now - entry.at <= constants.PVP_FEED_DEDUPE_SECONDS then
      local known = false
      for _, killer in ipairs(entry.killers) do
        known = known or killer == sender
      end
      if not known and #entry.killers < constants.PVP_FEED_KILLERS_MAX then
        entry.killers[#entry.killers + 1] = sender
      end
      entry.blow = entry.blow or payload.blow == true
      self:Changed()
      return false, entry
    end
  end

  local entry = {
    victim = payload.victim,
    key = key,
    where = payload.where,
    blow = payload.blow == true,
    killers = { sender },
    at = now,
    time = self.deps.serverTime(),
    own = false,
  }
  self:Add(entry)
  self:Changed()
  return true, entry
end

ns.PvPFeed = PvPFeed
