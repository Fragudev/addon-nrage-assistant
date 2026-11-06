local _, ns = ...

-- Tells the guild about the enemy players the own client sees (docs/PVP_INTEL_PLAN.md section 3.2). Live data: when
-- sending is not possible the sighting is dropped, never kept for later. Nothing here touches the client; everything is
-- injected.
--
--   * Offer(details, where, isKos) queues a sighting. An enemy is sent at most once per
--     Constants.INTEL_SHARE_ENEMY_SECONDS, and again sooner only when it starts stealth. The queue holds
--     Constants.INTEL_SHARE_QUEUE_MAX sightings; Kill On Sight enemies go first, and a full queue drops its oldest
--     other sighting for a new one.
--   * Tick() sends at most one message per Constants.INTEL_SHARE_TICK_SECONDS. It sends nothing, and clears the queue,
--     when sharing is off, during the encounter lockdown, or where no channel applies. An enemy that was ignored in the
--     meantime is not sent.
--   * Channel: the open world uses GUILD; a battleground uses the group channel; arenas, dungeons and raids send
--     nothing.
--
-- deps = { now = function() -> seconds (monotonic),
--          settings = function() -> Settings.Intel, canSend = function() -> boolean (false during the lockdown),
--          instanceKind = function() -> "none" | "pvp" | "arena" | "party" | "raid" | nil,
--          groupChannel = function() -> "RAID" | "INSTANCE_CHAT" | "PARTY" | nil,
--          isIgnored = function(name) -> boolean, send = function(text, channel) -> boolean }
local IntelPublisher = {}
IntelPublisher.__index = IntelPublisher

function IntelPublisher.New(deps)
  return setmetatable({
    deps = deps,
    queue = {},
    lastSent = {},
    lastStealth = {},
    lastTickAt = nil,
    sent = 0,
    drops = {},
  }, IntelPublisher)
end

local function drop(self, reason, count)
  self.drops[reason] = (self.drops[reason] or 0) + (count or 1)
  return false, reason
end

local function call(fn, ...)
  local ok, value = pcall(fn, ...)
  return ok and value or nil
end

-- The channel the sightings go to now, or nil.
function IntelPublisher:Channel()
  local kind = call(self.deps.instanceKind)
  if kind == nil or kind == "none" then
    return "GUILD"
  elseif kind == "pvp" then
    return call(self.deps.groupChannel)
  end
  return nil
end

local function oldestOther(queue, keepKos)
  local index
  for position, item in ipairs(queue) do
    if (not keepKos or not item.kos) and (not index or item.at < queue[index].at) then
      index = position
    end
  end
  return index
end

-- Queues a sighting: `details` = { name, class, race, level, levelEstimated, stealth }, `where` = { map, x, y } (the
-- own position), `isKos` marks an enemy of a Kill On Sight list. Returns true when it was queued, or false plus
-- "disabled" | "lockdown" | "ignored" | "no_position" | "bad_fields" | "recent" | "full".
function IntelPublisher:Offer(details, where, isKos)
  local deps = self.deps
  local settings = deps.settings()
  if settings.share ~= true then
    return drop(self, "disabled")
  end
  if not call(deps.canSend) then
    return drop(self, "lockdown")
  end
  if type(details) ~= "table" then
    return drop(self, "bad_fields")
  end
  if call(deps.isIgnored, details.name) then
    return drop(self, "ignored")
  end
  if type(where) ~= "table" or not (where.map and where.x and where.y) then
    return drop(self, "no_position")
  end
  local key = ns.IntelModel.Key(details.name)
  local text = ns.IntelModel.EncodeSighting({
    map = where.map,
    x = where.x,
    y = where.y,
    class = details.class,
    race = details.race,
    level = details.level,
    stealth = details.stealth == true,
    estimated = details.levelEstimated == true,
    name = ns.IntelModel.CleanName(details.name),
  })
  if not (key and text) then
    return drop(self, "bad_fields")
  end

  local now = deps.now()
  local lastAt = self.lastSent[key]
  local startsStealth = details.stealth == true and not self.lastStealth[key]
  if lastAt and now - lastAt < ns.Constants.INTEL_SHARE_ENEMY_SECONDS and not startsStealth then
    return drop(self, "recent")
  end

  local item = { key = key, name = details.name, text = text, kos = isKos == true, at = now, stealth = details.stealth }
  for position, queued in ipairs(self.queue) do
    if queued.key == key then
      -- The same enemy again: the newest reading replaces the one waiting, and keeps its place in the line.
      item.at = queued.at
      self.queue[position] = item
      return true
    end
  end
  if #self.queue >= ns.Constants.INTEL_SHARE_QUEUE_MAX then
    local victim = oldestOther(self.queue, true)
    if not victim then
      if not item.kos then
        return drop(self, "full")
      end
      victim = oldestOther(self.queue, false)
    end
    table.remove(self.queue, victim)
    drop(self, "full")
  end
  self.queue[#self.queue + 1] = item
  return true
end

-- Kill On Sight first, then the one that waited longest.
local function nextIndex(queue)
  local best
  for position, item in ipairs(queue) do
    local current = best and queue[best]
    if not current or (item.kos and not current.kos) or (item.kos == current.kos and item.at < current.at) then
      best = position
    end
  end
  return best
end

-- The periodic send. Returns true when a message went out, or false plus the reason nothing did: "throttled" |
-- "empty" | "disabled" | "lockdown" | "no_channel" | "ignored" | "send_failed".
function IntelPublisher:Tick()
  local deps = self.deps
  local now = deps.now()
  -- An enemy sent long ago may be sent again, so there is nothing to remember about it.
  for key, at in pairs(self.lastSent) do
    if now - at >= ns.Constants.INTEL_SHARE_ENEMY_SECONDS then
      self.lastSent[key], self.lastStealth[key] = nil, nil
    end
  end
  if self.lastTickAt and now - self.lastTickAt < ns.Constants.INTEL_SHARE_TICK_SECONDS then
    return false, "throttled"
  end
  if #self.queue == 0 then
    return false, "empty"
  end
  -- Live data is not kept for later: the whole queue goes when it cannot be sent now.
  local reason
  if deps.settings().share ~= true then
    reason = "disabled"
  elseif not call(deps.canSend) then
    reason = "lockdown"
  end
  local channel = not reason and self:Channel() or nil
  if not reason and not channel then
    reason = "no_channel"
  end
  if reason then
    drop(self, reason, #self.queue)
    self.queue = {}
    return false, reason
  end

  local position = nextIndex(self.queue)
  local item = table.remove(self.queue, position)
  if call(deps.isIgnored, item.name) then
    return drop(self, "ignored")
  end
  self.lastTickAt = now
  if not call(deps.send, item.text, channel) then
    return drop(self, "send_failed")
  end
  self.lastSent[item.key] = now
  self.lastStealth[item.key] = item.stealth == true
  self.sent = self.sent + 1
  return true
end

ns.IntelPublisher = IntelPublisher
