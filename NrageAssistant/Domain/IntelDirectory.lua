local _, ns = ...

-- The enemy sightings the guild shared (docs/PVP_INTEL_PLAN.md section 3.2). In memory only: nothing is saved, nothing
-- goes into a snapshot, and no player record is written. Nothing here touches the client: the clock is injected.
--
--   * Apply(sender, decoded) keeps one entry per enemy, the newest sighting winning, whoever reported it. At most
--     Constants.INTEL_DIRECTORY_MAX enemies are kept: a new one is refused when it is full of live entries.
--   * An entry older than Constants.INTEL_DIRECTORY_TTL is removed by Prune() and is not listed.
--   * The position of a sighting is the position of the reporter, not the enemy's.
--   * onChange() fires after anything was added, replaced or removed, so the views can be redrawn.
--
-- deps = { now = function() -> seconds (monotonic), onChange = function() (optional) }
local IntelDirectory = {}
IntelDirectory.__index = IntelDirectory

function IntelDirectory.New(deps)
  return setmetatable({ deps = deps, entries = {}, count = 0 }, IntelDirectory)
end

local function changed(self)
  if self.deps.onChange then
    pcall(self.deps.onChange)
  end
end

local function expired(entry, now)
  return now - entry.at > ns.Constants.INTEL_DIRECTORY_TTL
end

-- Removes the entries older than the TTL. Returns true when something was removed.
function IntelDirectory:Prune()
  local now, removed = self.deps.now(), false
  for key, entry in pairs(self.entries) do
    if expired(entry, now) then
      self.entries[key] = nil
      self.count = self.count - 1
      removed = true
    end
  end
  if removed then
    changed(self)
  end
  return removed
end

-- `decoded` is the result of IntelModel.DecodeSighting. Returns true, or false plus "bad_sender" | "bad_state" |
-- "limit".
function IntelDirectory:Apply(sender, decoded)
  if type(sender) ~= "string" or sender == "" then
    return false, "bad_sender"
  end
  local key = type(decoded) == "table" and ns.IntelModel.Key(decoded.name) or nil
  if not key then
    return false, "bad_state"
  end
  if not self.entries[key] then
    if self.count >= ns.Constants.INTEL_DIRECTORY_MAX then
      self:Prune()
    end
    if self.count >= ns.Constants.INTEL_DIRECTORY_MAX then
      return false, "limit"
    end
    self.count = self.count + 1
  end
  self.entries[key] = {
    key = key,
    name = decoded.name,
    class = decoded.class,
    race = decoded.race,
    level = decoded.level,
    estimated = decoded.estimated == true,
    stealth = decoded.stealth == true,
    map = decoded.map,
    x = decoded.x,
    y = decoded.y,
    at = self.deps.now(),
    source = sender,
  }
  changed(self)
  return true
end

-- Forgets an enemy. Returns true when there was one.
function IntelDirectory:Remove(key)
  if not self.entries[key] then
    return false
  end
  self.entries[key] = nil
  self.count = self.count - 1
  changed(self)
  return true
end

-- The live entries as copies { key, name, class, race, level, estimated, stealth, map, x, y, at, source }, most recent
-- first. `mapId` (optional) keeps the ones reported on that map.
function IntelDirectory:List(mapId)
  local now, list = self.deps.now(), {}
  for _, entry in pairs(self.entries) do
    if not expired(entry, now) and (mapId == nil or entry.map == mapId) then
      local copy = {}
      for field, value in pairs(entry) do
        copy[field] = value
      end
      list[#list + 1] = copy
    end
  end
  table.sort(list, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.key < b.key
  end)
  return list
end

ns.IntelDirectory = IntelDirectory
