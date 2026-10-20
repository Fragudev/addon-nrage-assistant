local _, ns = ...

-- The kill feed: the own kills, shown in the Recent kills sub-tab and shared with the guild. Nothing here touches
-- the client: the clock, the timer, the transport and the lockdown state are injected, so the rules are tested with
-- fakes.
--
--   * The client gives two events for one kill, an honour credit and a killing blow, in either order. Both call
--     Own(): an event for a victim that already has an entry younger than PVP_FEED_MERGE_SECONDS joins that entry
--     (a blow sets `blow`), otherwise it starts one. Group credit therefore produces one entry per honour kill.
--     A killing blow without honour (a grey target) has no honour event to wait for and is sent alone, with
--     `blow = true`; an honour kill without a blow is sent with `blow = false`.
--   * An entry is listed at once (the last PVP_FEED_MAX are kept in memory, newest first, never saved) and waits
--     PVP_FEED_MERGE_SECONDS before it is sent, so the second event can still join it. Every kill is shared: it is
--     sent unless the encounter lockdown is on (dropped, never queued) or PVP_FEED_MAX_PER_MINUTE went out in the
--     last rolling minute (the extra ones are dropped).
--   * Kills of other members are received by the transport but not kept: the list is only the own history.
--
-- deps = { now = function() -> seconds (monotonic), serverTime = function() -> seconds (for display),
--          send = function(payload) -> ok, isLocked = function() -> boolean, schedule = function(delay, fn),
--          ownName = function() -> string, onChange = function() (optional),
--          onHonorKill = function(entry) (optional) }
--
-- `onHonorKill` is told once per honour kill (never for a killing blow without honour), also when the blow came first.
-- The PvP missions log their kills from it (docs/PVP_MISSIONS_PLAN.md, 2.1).
local PvPFeed = {}
PvPFeed.__index = PvPFeed

local WINDOW_SECONDS = 60
local PLACES = { world = true, bg = true }

function PvPFeed.New(deps)
  return setmetatable({
    deps = deps,
    list = {},
    own = {},
    sentAt = {},
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

function PvPFeed:Changed()
  if self.deps.onChange then
    self.deps.onChange()
  end
end

local function validKill(victim, where)
  return ns.Validate.Text(victim, ns.Constants.PVP_FEED_VICTIM_MAX) and PLACES[where] == true
end

function PvPFeed:Add(entry)
  local list = self.list
  table.insert(list, 1, entry)
  while #list > ns.Constants.PVP_FEED_MAX do
    list[#list] = nil
  end
end

-- Sends `entry` when the rules allow it. Returns true, or false plus "locked" | "limit" | the reason the transport
-- gave.
function PvPFeed:Flush(entry)
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
  self:Add(entry)
  self:Changed()
  self.deps.schedule(ns.Constants.PVP_FEED_MERGE_SECONDS, function()
    self:Flush(entry)
  end)
  return true
end

function PvPFeed:OnHonorKill(victim, where)
  local started = self:Own(victim, where, false)
  if self.deps.onHonorKill and type(victim) == "string" then
    local key = victim:lower()
    for _, entry in ipairs(self.own) do
      if entry.key == key and not entry.honor then
        entry.honor = true
        pcall(self.deps.onHonorKill, entry)
        break
      end
    end
  end
  return started
end

function PvPFeed:OnKillingBlow(victim, where)
  return self:Own(victim, where, true)
end

ns.PvPFeed = PvPFeed
