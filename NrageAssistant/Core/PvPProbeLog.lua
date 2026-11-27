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

-- Diagnostic data is local to the character and is never sent to the guild. Keep explicit retention counts.
function PvPProbeLog.Archive(character)
  if type(character.pvpProbe) ~= "table" then
    character.pvpProbe = { version = 1, nextId = 0, sessions = {} }
  end
  return character.pvpProbe
end

-- SavedVariables must never receive a restricted client value (including restricted strings).
function PvPProbeLog.SavedText(value)
  local ok, text = pcall(function()
    if type(_G.issecretvalue) == "function" and _G.issecretvalue(value) then
      return SECRET
    end
    return tostring(value):sub(1, 1024)
  end)
  if not ok then
    return SECRET
  end
  return text
end

-- The GUID is passed straight through to the API: do not test its type, compare it, stringify it or index it first.
function PvPProbeLog.QueryGUID(guid)
  local fn = _G.GetPlayerInfoByGUID
  if type(fn) ~= "function" then
    return { status = "missing" }
  end
  local values = { pcall(fn, guid) }
  if not values[1] then
    return { status = "error", error = PvPProbeLog.SavedText(values[2]) }
  end
  local function field(value)
    local readable, text = pcall(function()
      if type(_G.issecretvalue) == "function" and _G.issecretvalue(value) then
        return nil
      end
      if type(value) == "string" then
        return value:sub(1, 256)
      end
    end)
    return readable and text or nil
  end
  local result =
    { class = field(values[3]), race = field(values[5]), name = field(values[7]), realm = field(values[8]) }
  result.status = result.class and result.race and result.name and result.name ~= "" and "resolved" or "partial"
  return result
end

function PvPProbeLog.DescribeGUIDQuery(result)
  return ("GetPlayerInfoByGUID %s classToken=%s raceToken=%s name=%s realm=%s error=%s"):format(
    result.status,
    result.class or "unreadable",
    result.race or "unreadable",
    result.name or "unreadable",
    result.realm or "unreadable",
    result.error or "none"
  )
end

-- Rebase across loading screens and decreases. In particular, a temporary lifetimeHK=0 must never become a new floor.
function PvPProbeLog.NewCounterGuard(initial, context)
  return ns.PvPCounterGuard.New(initial, context)
end

function PvPProbeLog.NewCapture(character, platform)
  local archive = PvPProbeLog.Archive(character)
  archive.nextId = archive.nextId + 1
  local capture = {
    id = archive.nextId,
    started = PvPProbeLog.SavedText(platform.WallClock()),
    windows = {},
    records = {},
    droppedRecords = 0,
    droppedWindows = 0,
  }
  archive.sessions[#archive.sessions + 1] = capture
  if #archive.sessions > 3 then
    table.remove(archive.sessions, 1)
  end
  return capture
end

function PvPProbeLog.CaptureRecord(capture, platform, windowId, kind, detail, fields)
  local records = capture.records
  local safeFields
  if fields then
    safeFields = {}
    for key, value in pairs(fields) do
      if type(key) == "string" and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
        safeFields[PvPProbeLog.SavedText(key)] = PvPProbeLog.SavedText(value)
      end
    end
  end
  records[#records + 1] = {
    t = platform.Now(),
    wall = PvPProbeLog.SavedText(platform.WallClock()),
    windowId = windowId,
    kind = PvPProbeLog.SavedText(kind),
    detail = PvPProbeLog.SavedText(detail),
    fields = safeFields,
  }
  if #records > 4000 then
    table.remove(records, 1)
    capture.droppedRecords = capture.droppedRecords + 1
  end
end

function PvPProbeLog.CaptureWindow(capture, platform, id)
  local row = {
    id = id,
    wall = PvPProbeLog.SavedText(platform.WallClock()),
    status = "pending",
    hk = "pending",
    victims = {},
    truncatedVictims = false,
  }
  capture.windows[#capture.windows + 1] = row
  if #capture.windows > 600 then
    table.remove(capture.windows, 1)
    capture.droppedWindows = capture.droppedWindows + 1
  end
  return row
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
