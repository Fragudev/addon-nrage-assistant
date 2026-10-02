local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Commands/RaidCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

-- Fakes only the client (platform) and the transport (comm); everything else is the real domain.
local function build(rank)
  local env = { events = {}, tombstones = {}, sent = {}, sendResult = { true }, counter = 0 }
  env.platform = {
    GetOwnGuildRank = function()
      return rank
    end,
    GetIdentityKey = function()
      return "Leader-Realm"
    end,
    ServerTime = function()
      return 1000
    end,
    FormatDate = function(timestamp)
      return "date:" .. timestamp
    end,
    ParseDate = function(text)
      local day = text:match("^2026%-10%-(%d%d) 20:30$")
      return day and (1000 + tonumber(day)) or nil
    end,
  }
  env.comm = {}
  function env.comm.NextId()
    env.counter = env.counter + 1
    return "id" .. env.counter
  end
  local function record(kind)
    return function(_, ...)
      env.sent[#env.sent + 1] = { kind = kind, args = { ... } }
      return unpack(env.sendResult)
    end
  end
  for _, kind in ipairs({
    "SendEvent",
    "SendAttendance",
    "SendAssignment",
    "SendDeleteEvent",
    "SendDeleteAssignment",
  }) do
    env.comm[kind] = record(kind)
  end
  env.raid = ns.RaidCommands.New({
    events = env.events,
    tombstones = env.tombstones,
    platform = env.platform,
    comm = env.comm,
  })
  return env
end

local function text(lines)
  return table.concat(lines, "\n")
end

describe("RaidCommands structured operations", function()
  local env

  local function first_event()
    return ns.EventService.List({ events = env.events })[1]
  end

  before_each(function()
    env = build("RL")
    env.raid:CreateEvent("Raid night")
    env.sent = {}
  end)

  it("creates, renames, sets status and start time, and sends each change", function()
    local event = first_event()
    assert.is_truthy(text(env.raid:RenameEvent(event, "Renamed")):find("updated 'Renamed'", 1, true))
    assert.is_truthy(text(env.raid:SetEventStatus(event, "open")):find("[open]", 1, true))
    env.raid:SetEventStart(event, "2026-10-03 20:30")
    assert.are.equal(1003, event.startAt)
    assert.are.equal(3, #env.sent)
    assert.are.equal("SendEvent", env.sent[3].kind)
  end)

  it("rejects a bad status or start time without sending", function()
    local event = first_event()
    assert.is_truthy(text(env.raid:SetEventStatus(event, "boom")):find("status must be", 1, true))
    assert.is_truthy(text(env.raid:SetEventStart(event, "tomorrow")):find("YYYY-MM-DD HH:MM", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("records attendance and adds and removes an assignment", function()
    local event = first_event()
    env.raid:SetAttendance(event, "Yonemon Gg", "present")
    assert.are.equal("present", event.attendance["Yonemon Gg"].state)

    env.raid:AddAssignment(event, "Yonemon Gg", "Ragnaros")
    local assignment = ns.RaidCommands.SortedAssignments(event)[1]
    assert.are.equal("Yonemon Gg", assignment.characterKey)
    assert.is_truthy(text(env.raid:RemoveAssignment(event, assignment)):find("removed Yonemon Gg", 1, true))
    assert.is_nil(next(event.assignments))
    assert.are.same({ "SendAttendance", "SendAssignment", "SendDeleteAssignment" }, {
      env.sent[1].kind,
      env.sent[2].kind,
      env.sent[3].kind,
    })
  end)

  it("keeps the role checks: a member changes nothing", function()
    local member = build("member")
    local event = { eventId = "ev-1", title = "Raid", status = "planned", attendance = {}, assignments = {} }
    member.events["ev-1"] = event
    assert.is_truthy(text(member.raid:CreateEvent("Nope")):find("not allowed", 1, true))
    assert.is_truthy(text(member.raid:SetAttendance(event, "Ann-Realm", "present")):find("not allowed", 1, true))
    assert.is_truthy(text(member.raid:AddAssignment(event, "Ann-Realm", "Garr")):find("not allowed", 1, true))
    assert.is_nil(next(event.attendance))
    assert.is_nil(next(event.assignments))
    assert.are.equal(0, #member.sent)
  end)

  it("creates an event, stores it and sends it to the guild", function()
    local fresh = build("RL")
    local lines = fresh.raid:CreateEvent("Molten Core night")
    assert.is_truthy(text(lines):find("created event 'Molten Core night'", 1, true))
    assert.are.equal("Molten Core night", ns.EventService.List({ events = fresh.events })[1].title)
    assert.are.equal("SendEvent", fresh.sent[1].kind)
  end)

  it("rejects an empty title without sending anything", function()
    local fresh = build("RL")
    assert.is_truthy(text(fresh.raid:CreateEvent("")):find("invalid title", 1, true))
    assert.are.equal(0, #fresh.sent)
  end)

  it("deletes an event, leaves a tombstone and sends the deletion", function()
    local event = first_event()
    assert.is_truthy(text(env.raid:DeleteEvent(event)):find("deleted 'Raid night'", 1, true))
    assert.is_nil(first_event())
    assert.are.equal("SendDeleteEvent", env.sent[1].kind)
  end)

  it("treats an unmapped or missing rank as a member without raising", function()
    for _, rank in ipairs({ "Unknown rank", "" }) do
      assert.is_truthy(text(build(rank).raid:CreateEvent("X")):find("not allowed", 1, true))
    end
    assert.is_truthy(text(build(nil).raid:CreateEvent("X")):find("not allowed", 1, true))
  end)

  it("says when a change was saved here but could not be queued", function()
    local offline = build("RL")
    offline.sendResult = { false, "full" }
    local lines = text(offline.raid:CreateEvent("Offline"))
    assert.is_truthy(lines:find("saved here, but not sent to the guild (full)", 1, true))
    assert.are.equal("Offline", ns.EventService.List({ events = offline.events })[1].title)
  end)

  it("refuses an attendance state it does not know", function()
    local event = first_event()
    assert.is_truthy(text(env.raid:SetAttendance(event, "Ann-Realm", "disconnected")):find("unknown state", 1, true))
    assert.is_nil(next(event.attendance))
    assert.are.equal(0, #env.sent)
  end)

  it("keeps a name with several words and an encounter with several words", function()
    local event = first_event()
    env.raid:SetAttendance(event, "Yonemon Gg", "late")
    assert.are.equal("late", event.attendance["Yonemon Gg"].state)
    local lines = text(env.raid:AddAssignment(event, "Yonemon Gg", "Baron Geddon"))
    assert.is_truthy(lines:find("assigned Yonemon Gg to Baron Geddon", 1, true))
  end)

  it("sorts the assignments by encounter and then by character", function()
    local event = first_event()
    env.raid:AddAssignment(event, "Zed-Realm", "Ragnaros")
    env.raid:AddAssignment(event, "Ann-Realm", "Ragnaros")
    env.raid:AddAssignment(event, "Bob-Realm", "Garr")
    local order = {}
    for _, assignment in ipairs(ns.RaidCommands.SortedAssignments(event)) do
      order[#order + 1] = assignment.encounter .. ":" .. assignment.characterKey
    end
    assert.are.same({ "Garr:Bob-Realm", "Ragnaros:Ann-Realm", "Ragnaros:Zed-Realm" }, order)
  end)

  it("keeps the role checks for the start time and for deleting", function()
    local member = build("member")
    local event = { eventId = "ev-1", title = "Raid", status = "planned", attendance = {}, assignments = {} }
    member.events["ev-1"] = event
    assert.is_truthy(text(member.raid:SetEventStart(event, "2026-10-03 20:30")):find("not allowed", 1, true))
    assert.is_truthy(text(member.raid:DeleteEvent(event)):find("not allowed", 1, true))
    assert.is_truthy(member.events["ev-1"])
  end)
end)
