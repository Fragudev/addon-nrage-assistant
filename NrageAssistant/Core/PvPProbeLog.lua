local _, ns = ...

-- Bounded in-memory log plus the pure helpers of the PvP API probe (issue #92). Everything the probe reads
-- from the client may be a secret value or raise, so every helper here goes through pcall and none of them
-- ever raises or divides.
local PvPProbeLog = {}
PvPProbeLog.__index = PvPProbeLog

local MAX_LOG = 200
local SECRET = "<secret>"

-- The only combat log fields PARTY_KILL needs, with their names in the table the probe builds.
local COMBAT_FIELDS = { "subevent", "sourceGUID", "sourceName", "destGUID", "destName", "destFlags" }

-- The order of the honour counters in a snapshot.
local COUNTERS = { "sessionHK", "sessionHonor", "lifetimeHK", "highestRank" }

function PvPProbeLog.New(platform)
  return setmetatable({ platform = platform, log = {} }, PvPProbeLog)
end

function PvPProbeLog:Record(kind, detail)
  local log = self.log
  log[#log + 1] = {
    t = self.platform.Now(),
    wall = self.platform.WallClock(),
    kind = kind,
    detail = detail,
  }
  if #log > MAX_LOG then
    table.remove(log, 1)
  end
end

function PvPProbeLog:GetLog()
  return self.log
end

function PvPProbeLog:Clear()
  self.log = {}
end

-- Text for any value; a value that cannot be turned into text (a secret) becomes "<secret>".
function PvPProbeLog.ToText(value)
  local ok, text = pcall(tostring, value)
  if ok and type(text) == "string" then
    return text
  end
  return SECRET
end

-- One line for a list of arguments, such as the ones of a chat event.
function PvPProbeLog.FormatArgs(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[i] = ("[%d]=%s"):format(i, PvPProbeLog.ToText((select(i, ...))))
  end
  if #parts == 0 then
    return "(no arguments)"
  end
  return table.concat(parts, " ")
end

-- A number that can be compared, or nil (missing, not a number, or a secret).
local function readableNumber(value)
  local ok, number = pcall(function()
    if type(value) == "number" and value == value then
      return value
    end
  end)
  return ok and number or nil
end

-- Reads the honour counters through `reader`, which returns sessionHK, sessionHonor, lifetimeHK and
-- highestRank. A missing or raising reader gives { error = text }; a value that is not a readable number
-- is kept as text, so a secret shows up in the log instead of being lost.
function PvPProbeLog.Snapshot(reader)
  if type(reader) ~= "function" then
    return { error = "missing" }
  end
  local values = { pcall(reader) }
  if not values[1] then
    return { error = PvPProbeLog.ToText(values[2]) }
  end
  local snapshot = {}
  for i, name in ipairs(COUNTERS) do
    local value = values[i + 1]
    snapshot[name] = readableNumber(value) or PvPProbeLog.ToText(value)
  end
  return snapshot
end

function PvPProbeLog.DescribeSnapshot(snapshot)
  if snapshot.error then
    return "counters unavailable (" .. snapshot.error .. ")"
  end
  local parts = {}
  for _, name in ipairs(COUNTERS) do
    parts[#parts + 1] = ("%s=%s"):format(name, PvPProbeLog.ToText(snapshot[name]))
  end
  return table.concat(parts, " ")
end

-- Says which counters changed between two snapshots, e.g. "sessionHK 3->4 (+1)". A decrease (a relog resets
-- the session counters) is reported as it is.
function PvPProbeLog.DescribeDelta(before, after)
  if before.error or after.error then
    return "delta unavailable (" .. (before.error or after.error) .. ")"
  end
  local changes = {}
  for _, name in ipairs(COUNTERS) do
    local a, b = readableNumber(before[name]), readableNumber(after[name])
    if a and b and a ~= b then
      changes[#changes + 1] = ("%s %s->%s (%+g)"):format(name, a, b, b - a)
    elseif not (a and b) and before[name] ~= after[name] then
      changes[#changes + 1] = ("%s %s->%s (not comparable)"):format(name, before[name], after[name])
    end
  end
  if #changes == 0 then
    return "no change"
  end
  return table.concat(changes, ", ")
end

function PvPProbeLog.DescribeInstance(inInstance, instanceType)
  return ("inInstance=%s instanceType=%s"):format(PvPProbeLog.ToText(inInstance), PvPProbeLog.ToText(instanceType))
end

-- One piece of the PvP missions measurements (plan M1 to M5) as text: `label=a, b, c`. `ok`, `...` are what the probe's
-- reader gives: `nil, reason` when the API is missing or raised, `true, a, b, c, d` otherwise. A value that cannot be
-- turned into text (a secret) shows as "<secret>"; trailing nils are left out and no values at all show as "nil".
function PvPProbeLog.DescribeRead(label, ok, ...)
  if not ok then
    return ("%s=<unavailable: %s>"):format(label, PvPProbeLog.ToText((...)))
  end
  local values = { ... }
  local last = 0
  for index = 1, select("#", ...) do
    if values[index] ~= nil then
      last = index
    end
  end
  if last == 0 then
    return label .. "=nil"
  end
  local parts = {}
  for index = 1, last do
    parts[index] = PvPProbeLog.ToText(values[index])
  end
  return ("%s=%s"):format(label, table.concat(parts, ", "))
end

-- Describes a combat log event given as a table with the fields of COMBAT_FIELDS. Returns the text and the
-- readable fields; sourceIsPlayer is true only when the source GUID could be compared and matches.
function PvPProbeLog.DescribeCombatEvent(event, playerGuid)
  local fields = {}
  local parts = {}
  for _, name in ipairs(COMBAT_FIELDS) do
    local ok, value = pcall(function()
      return event[name]
    end)
    fields[name] = ok and PvPProbeLog.ToText(value) or SECRET
    parts[#parts + 1] = ("%s=%s"):format(name, fields[name])
  end
  local ok, isPlayer = pcall(function()
    return playerGuid ~= nil and event.sourceGUID == playerGuid
  end)
  fields.sourceIsPlayer = ok and isPlayer == true
  parts[#parts + 1] = "sourceIsPlayer=" .. tostring(fields.sourceIsPlayer)
  return table.concat(parts, " "), fields
end

ns.PvPProbeLog = PvPProbeLog
