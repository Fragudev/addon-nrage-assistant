local _, ns = ...

-- Reads the enemy players the client shows and hands them to IntelService (docs/PVP_INTEL_PLAN.md section 3.1).
-- Nothing here touches the client: the reader is injected (Platform in the game, a fake in the tests), and a unit the
-- reader cannot read, or that raises, is skipped and counted, never guessed.
--
--   * OnUnit(unit) reads one unit; Rescan() goes through nameplate1 to nameplate<N>, target, focus and mouseover.
--   * A skull level (-1) becomes the own level plus Constants.INTEL_SKULL_LEVEL_BONUS, marked as estimated.
--   * It remembers which enemies target the player, with the time, for the loss fallback (RecentTargeters).
--
-- deps = { reader = { GetEnemyDetails(unit), IsEnemyTargetingPlayer(unit), GetLevel(), GetPlayerFaction() },
--          service = IntelService, now = function() -> monotonic seconds,
--          allowed = function() -> boolean (and a reason),
--          where = function() -> { map, x, y } (the reporter's position),
--          onContact = function(result, details, where) (optional; called for every enemy read) }
local IntelDetector = {}
IntelDetector.__index = IntelDetector

function IntelDetector.New(deps)
  local units = {}
  for index = 1, ns.Constants.INTEL_NAMEPLATE_UNITS do
    units[#units + 1] = "nameplate" .. index
  end
  for _, unit in ipairs({ "target", "focus", "mouseover" }) do
    units[#units + 1] = unit
  end
  return setmetatable({
    deps = deps,
    units = units,
    targeting = {},
    drops = {},
    contacts = 0,
    reads = 0,
  }, IntelDetector)
end

function IntelDetector:Drop(reason)
  self.drops[reason] = (self.drops[reason] or 0) + 1
  return nil, reason
end

local function copy(value)
  local result = {}
  for key, inner in pairs(value) do
    result[key] = inner
  end
  return result
end

local function allowedNow(self)
  local called, allowed, why = pcall(self.deps.allowed)
  if not called or not allowed then
    return false, called and why or "not_allowed"
  end
  return true
end

-- Reads one unit already known to be allowed. `quiet` leaves the "unreadable" drop uncounted: a scan asks about
-- units that do not exist, which is the normal case.
function IntelDetector:Read(unit, quiet)
  local deps = self.deps
  local reader = deps.reader
  local read, details = pcall(reader.GetEnemyDetails, unit)
  if not read then
    return self:Drop("error")
  end
  if type(details) ~= "table" then
    if quiet then
      return nil, "unreadable"
    end
    return self:Drop("unreadable")
  end
  details = copy(details)

  -- The reader rejects the own faction already; a second look keeps a duel or a reader that forgot from getting in.
  local own = reader.GetPlayerFaction and select(2, pcall(reader.GetPlayerFaction)) or nil
  if own and details.faction == own then
    return self:Drop("same_faction")
  end

  if details.skull then
    local level = reader.GetLevel and select(2, pcall(reader.GetLevel)) or nil
    if type(level) == "number" then
      details.level, details.levelEstimated = level + ns.Constants.INTEL_SKULL_LEVEL_BONUS, true
    else
      details.level = nil
    end
  end

  local placed, where = pcall(deps.where)
  where = placed and type(where) == "table" and where or {}

  local result, reason = deps.service:OnSeen(details, where)
  if not result then
    return self:Drop(reason or "bad_name")
  end
  if result.isNew then
    self.contacts = self.contacts + 1
  else
    self.reads = self.reads + 1
  end

  local targeted, targetsMe = pcall(reader.IsEnemyTargetingPlayer, unit)
  if targeted and targetsMe == true then
    self.targeting[result.key] = { name = result.record.name, at = deps.now() }
  end
  if deps.onContact then
    pcall(deps.onContact, result, details, where)
  end
  return result, details
end

-- Reads one unit (an event told about it). Returns the IntelService result ({ isNew, record, key, kos, ignored }) plus
-- the details, or nil plus the reason it was dropped: the reason of `allowed` (or "not_allowed") | "error" |
-- "unreadable" | "same_faction" | "bad_name".
function IntelDetector:OnUnit(unit)
  local ok, why = allowedNow(self)
  if not ok then
    return self:Drop(why)
  end
  return self:Read(unit, false)
end

-- Reads every unit the client can show an enemy on, asking `allowed` once. Returns how many enemies were read.
function IntelDetector:Rescan()
  local ok, why = allowedNow(self)
  if not ok then
    self:Drop(why)
    return 0
  end
  local count = 0
  for _, unit in ipairs(self.units) do
    if self:Read(unit, true) then
      count = count + 1
    end
  end
  return count
end

-- The enemies that targeted the player in the last `within` seconds, newest first: { key, name, at }.
function IntelDetector:RecentTargeters(within)
  local now, list = self.deps.now(), {}
  for key, seen in pairs(self.targeting) do
    if now - seen.at > within then
      self.targeting[key] = nil
    else
      list[#list + 1] = { key = key, name = seen.name, at = seen.at }
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

ns.IntelDetector = IntelDetector
