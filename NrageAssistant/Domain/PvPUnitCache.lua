local _, ns = ...

-- The unit cache of the PvP missions (docs/PVP_MISSIONS_PLAN.md, 2.2). The combat log is off on this client, so the
-- class and race of a victim cannot come from its GUID; they come from the enemy players the player has seen (target,
-- mouseover, nameplates). The cache maps a name to the class and race file tokens, in memory only.
--
--   * It keeps at most PVP_UNIT_CACHE_MAX names; when full, the least recently seen one is dropped.
--   * An entry older than PVP_UNIT_CACHE_TTL seconds is ignored (and forgotten when it is looked up).
--   * Names are compared case-insensitively with repeated whitespace collapsed. Which form of the name the kill feed
--     produces (full or first word) is not measured yet (M3); a genuinely truncated name still cannot match.
--
-- deps = { now = function() -> seconds (monotonic) }
local PvPUnitCache = {}
PvPUnitCache.__index = PvPUnitCache

function PvPUnitCache.New(deps)
  return setmetatable({ deps = deps, entries = {}, count = 0, tick = 0 }, PvPUnitCache)
end

local function validToken(value)
  return type(value) == "string" and value:find("^%u+$") ~= nil
end

local function keyOf(name)
  if type(name) ~= "string" or name == "" then
    return nil
  end
  -- Keep word boundaries: removing all whitespace would merge distinct players such as "Ana B" and "Anab".
  return name:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
end

function PvPUnitCache:Count()
  return self.count
end

-- A stable, read-only view for the development diagnostic. It intentionally exposes no internal entry tables.
function PvPUnitCache:DebugRows()
  local now = self.deps.now()
  local rows = {}
  for name, entry in pairs(self.entries) do
    rows[#rows + 1] = {
      name = name,
      class = entry.class,
      race = entry.race,
      age = type(now) == "number" and type(entry.seenAt) == "number" and math.max(0, now - entry.seenAt) or nil,
    }
  end
  table.sort(rows, function(a, b)
    return a.name < b.name
  end)
  return rows
end

local function dropOldest(self)
  local oldestKey, oldestTick
  for key, entry in pairs(self.entries) do
    if not oldestTick or entry.tick < oldestTick then
      oldestKey, oldestTick = key, entry.tick
    end
  end
  if oldestKey then
    self.entries[oldestKey] = nil
    self.count = self.count - 1
  end
end

-- Remembers what was seen of the player `name`. Returns true when something was stored; a name that is not text, or
-- a class and race that are both unusable (not an upper-case token, e.g. a secret value), store nothing. A token that
-- is not usable keeps the one already known.
function PvPUnitCache:Remember(name, class, race)
  local key = keyOf(name)
  class = validToken(class) and class or nil
  race = validToken(race) and race or nil
  if not key or not (class or race) then
    return false
  end
  local entry = self.entries[key]
  if not entry then
    if self.count >= ns.Constants.PVP_UNIT_CACHE_MAX then
      dropOldest(self)
    end
    entry = {}
    self.entries[key] = entry
    self.count = self.count + 1
  end
  self.tick = self.tick + 1
  entry.tick = self.tick
  entry.seenAt = self.deps.now()
  entry.class = class or entry.class
  entry.race = race or entry.race
  return true
end

-- The class and race last seen for `name` (either may be nil), or nil when it is unknown or too old.
function PvPUnitCache:Lookup(name)
  local key = keyOf(name)
  local entry = key and self.entries[key]
  if not entry then
    return nil
  end
  if self.deps.now() - entry.seenAt > ns.Constants.PVP_UNIT_CACHE_TTL then
    self.entries[key] = nil
    self.count = self.count - 1
    return nil
  end
  return entry.class, entry.race
end

ns.PvPUnitCache = PvPUnitCache
