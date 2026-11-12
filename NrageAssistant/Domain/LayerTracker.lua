local _, ns = ...

-- Works out the layer this client is on from the creature GUIDs it reads (target, mouseover, nameplates). Nothing
-- here touches the client: the clock and the instance check are injected.
--
--   * A new layer is confirmed after Constants.LAYER_CONFIRM_READINGS readings of the same (map, layer) from
--     different spawns, so one stale or odd creature does not flip it.
--   * Current() is nil while unknown: before the first confirmation, in an instance, and after
--     Constants.LAYER_STATE_TTL without a reading of the current layer.
--   * onChange(current) fires only when a new layer is confirmed.
--   * Layers are per zone on Forever: the zone the layer was confirmed in is kept with it, and the state is dropped
--     when the player is in another zone (or the zone is no longer known), so a new reading has to confirm it again.
--
-- deps = { now = function() -> seconds (monotonic), isInInstance = function() -> boolean,
--          zone = function() -> zone uiMapId or nil (optional), onChange = function(current) (optional) }
local LayerTracker = {}
LayerTracker.__index = LayerTracker

function LayerTracker.New(deps)
  return setmetatable({ deps = deps, readings = {}, current = nil, seenAt = nil }, LayerTracker)
end

local function inInstance(self)
  local ok, inside = pcall(self.deps.isInInstance)
  return ok and inside == true
end

function LayerTracker:Clear()
  self.readings = {}
  self.readingsZone = nil
  self.current = nil
  self.seenAt = nil
end

local function ownZone(self)
  if not self.deps.zone then
    return nil
  end
  local ok, zone = pcall(self.deps.zone)
  return ok and type(zone) == "number" and zone or nil
end

-- Drops the state when it is stale, the player is in an instance or the player left the zone it was read in.
-- Returns true when it dropped it.
function LayerTracker:Expire()
  local current = self.current
  if not current then
    return false
  end
  local stale = self.deps.now() - self.seenAt > ns.Constants.LAYER_STATE_TTL
  local moved = self.deps.zone ~= nil and ownZone(self) ~= current.zone
  if inInstance(self) or stale or moved then
    self:Clear()
    return true
  end
  return false
end

-- Reads one GUID. Returns true when it was a usable reading, false when it was refused (not a creature, or the
-- player is in an instance).
function LayerTracker:Observe(guid)
  if inInstance(self) then
    self:Clear()
    return false
  end
  local parsed = ns.LayerModel.Parse(guid)
  if not parsed then
    return false
  end

  -- Readings of another zone are of no use: the zone just changed.
  self:Expire()
  if self.deps.zone then
    local zone = ownZone(self)
    if zone ~= self.readingsZone then
      self.readings = {}
      self.readingsZone = zone
    end
  end
  local constants = ns.Constants
  local now = self.deps.now()
  local readings = self.readings
  local key = ns.LayerModel.Key(parsed.map, parsed.layer)
  local known = false
  for _, reading in ipairs(readings) do
    if reading.key == key and reading.spawnUid == parsed.spawnUid then
      reading.at = now
      known = true
    end
  end
  if not known then
    readings[#readings + 1] = { key = key, spawnUid = parsed.spawnUid, at = now }
    if #readings > constants.LAYER_READINGS_MAX then
      table.remove(readings, 1)
    end
  end

  if self.current and ns.LayerModel.Key(self.current.map, self.current.layer) == key then
    self.seenAt = now
    return true
  end

  local spawns = 0
  for _, reading in ipairs(readings) do
    if reading.key == key and now - reading.at <= constants.LAYER_STATE_TTL then
      spawns = spawns + 1
    end
  end
  if spawns >= constants.LAYER_CONFIRM_READINGS then
    self.current = { map = parsed.map, layer = parsed.layer, zone = ownZone(self), confirmedAt = now }
    self.seenAt = now
    if self.deps.onChange then
      self.deps.onChange(self:Current())
    end
  end
  return true
end

-- { map, layer, zone, confirmedAt } or nil; `zone` is nil when it was not known.
function LayerTracker:Current()
  self:Expire()
  local current = self.current
  if not current then
    return nil
  end
  return { map = current.map, layer = current.layer, zone = current.zone, confirmedAt = current.confirmedAt }
end

-- Forgets what was read before `t` (a value of the injected clock) and the confirmed layer if it was confirmed
-- before `t`, so only readings taken after a move count.
function LayerTracker:ResetSince(t)
  local kept = {}
  for _, reading in ipairs(self.readings) do
    if reading.at >= t then
      kept[#kept + 1] = reading
    end
  end
  self.readings = kept
  if self.current and self.current.confirmedAt < t then
    self.current = nil
    self.seenAt = nil
  end
end

ns.LayerTracker = LayerTracker
