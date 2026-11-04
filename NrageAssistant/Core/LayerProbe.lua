local _, ns = ...

-- Client-side harness for the layer measurements (docs/LAYER_SWAP_PLAN.md section 1.1). Not unit tested: it only
-- wires PvPProbeLog (a generic bounded log) to real events. Every client read is guarded, because an API may be
-- missing on this client or return secret values.
-- Usage: /nrage debug layer start | stop | status | log | clear
local LayerProbe = {}

local PREFIX = "|cffff0019Nrage Assistant|r"
local EVENTS = {
  "PLAYER_TARGET_CHANGED",
  "UPDATE_MOUSEOVER_UNIT",
  "NAME_PLATE_UNIT_ADDED",
  "PLAYER_ENTERING_WORLD",
  "ZONE_CHANGED_NEW_AREA",
  "GROUP_ROSTER_UPDATE",
  "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED",
}
-- The units whose GUID is read when the event does not name one.
local UNIT_OF_EVENT = { PLAYER_TARGET_CHANGED = "target", UPDATE_MOUSEOVER_UNIT = "mouseover" }

local Log = ns.PvPProbeLog

local log
local frame

local function say(text)
  print(PREFIX .. " " .. text)
end

-- Calls a global client function if it exists; false plus "missing" when it does not, or the error text.
local function Read(name, ...)
  local fn = _G[name]
  if type(fn) ~= "function" then
    return false, "missing"
  end
  local ok, a, b = pcall(fn, ...)
  if not ok then
    return false, Log.ToText(a)
  end
  return true, a, b
end

-- Records something that happened outside the probe (the invite or leave button of the popup) when it is running.
function LayerProbe.Note(kind, detail)
  if frame and log then
    log:Record(kind, detail)
  end
end

local function Describe(guid)
  local parsed = ns.LayerModel and ns.LayerModel.Parse(guid)
  if not parsed then
    return "not a creature"
  end
  return ("%s map=%s layer=%s npc=%s spawn=%s"):format(
    parsed.kind,
    parsed.map,
    parsed.layer,
    parsed.npcId,
    parsed.spawnUid
  )
end

local function ReadUnit(unit, event)
  local ok, guid = Read("UnitGUID", unit)
  if not ok then
    log:Record("guid", ("%s %s: UnitGUID %s"):format(event, unit, Log.ToText(guid)))
    return
  end
  log:Record("guid", ("%s %s: raw=%s -> %s"):format(event, unit, Log.ToText(guid), Describe(guid)))
  -- Feeds the live tracker too, so `status` shows what the probe saw (the tracker is idle without the probe).
  if ns.layerTracker then
    ns.layerTracker:Observe(guid)
  end
end

local function DescribeGroup()
  local _, inGroup = Read("IsInGroup")
  local _, inRaid = Read("IsInRaid")
  local _, inInstance, instanceType = Read("IsInInstance")
  local _, leader = Read("UnitIsGroupLeader", "player")
  return ("inGroup=%s inRaid=%s leader=%s %s"):format(
    Log.ToText(inGroup),
    Log.ToText(inRaid),
    Log.ToText(leader),
    Log.DescribeInstance(inInstance, instanceType)
  )
end

local function OnEvent(_, event, arg1)
  local unit = UNIT_OF_EVENT[event]
  if event == "NAME_PLATE_UNIT_ADDED" then
    unit = arg1
  end
  if unit then
    ReadUnit(type(unit) == "string" and unit or "nameplate", event)
    return
  end
  log:Record("event", event .. " " .. DescribeGroup())
  local current = ns.layerTracker and ns.layerTracker:Current()
  if current then
    log:Record("layer", ("confirmed map=%s layer=%s"):format(current.map, current.layer))
  end
end

local function Register(event)
  local ok, err = pcall(frame.RegisterEvent, frame, event)
  log:Record("register", ("%s %s"):format(event, ok and "registered" or "failed: " .. Log.ToText(err)))
end

local function Start()
  if not ns.active then
    say("probe unavailable: the addon is disabled for this character.")
    return
  end
  if frame then
    say("probe already running.")
    return
  end
  log = log or Log.New(ns.Platform)
  frame = CreateFrame("Frame")
  frame:SetScript("OnEvent", OnEvent)
  log:Record("probe", "started")
  for _, event in ipairs(EVENTS) do
    Register(event)
  end
  log:Record("instance", DescribeGroup())
  say("probe started. Target or mouse over NPCs, then /nrage debug layer log.")
end

local function Stop()
  if not frame then
    say("probe is not running.")
    return
  end
  frame:UnregisterAllEvents()
  frame:SetScript("OnEvent", nil)
  frame = nil
  log:Record("probe", "stopped")
  say("probe stopped.")
end

local function PrintLog()
  if not log then
    say("no log yet.")
    return
  end
  local entries = log:GetLog()
  local first = entries[1] and entries[1].t or 0
  say(("log (%d entries):"):format(#entries))
  for _, entry in ipairs(entries) do
    print(("  %s +%.2fs [%s] %s"):format(entry.wall, entry.t - first, entry.kind, entry.detail))
  end
end

local function Has(path)
  local value = _G
  for part in path:gmatch("[^%.]+") do
    value = type(value) == "table" and value[part] or nil
  end
  return type(value) == "function"
end

local function PrintStatus()
  local current = ns.layerTracker and ns.layerTracker:Current()
  say(("running=%s %s"):format(tostring(frame ~= nil), DescribeGroup()))
  if current then
    print(
      ("  layer: map=%s layer=%s (%s)"):format(current.map, current.layer, ns.LayerModel.Describe(nil, current.layer))
    )
  else
    print("  layer: unknown (target or mouse over NPCs)")
  end
  print(
    ("  APIs: UnitGUID=%s C_PartyInfo.InviteUnit=%s InviteUnit=%s C_PartyInfo.LeaveParty=%s LeaveParty=%s"):format(
      tostring(Has("UnitGUID")),
      tostring(Has("C_PartyInfo.InviteUnit")),
      tostring(Has("InviteUnit")),
      tostring(Has("C_PartyInfo.LeaveParty")),
      tostring(Has("LeaveParty"))
    )
  )
end

local ACTIONS = {
  start = Start,
  stop = Stop,
  log = PrintLog,
  clear = function()
    if log then
      log:Clear()
    end
    say("log cleared.")
  end,
  status = PrintStatus,
}

function LayerProbe.Handle(action)
  local run = ACTIONS[action or ""]
  if run then
    run()
  else
    say("usage: /nrage debug layer start | stop | status | log | clear")
  end
end

ns.LayerProbe = LayerProbe
