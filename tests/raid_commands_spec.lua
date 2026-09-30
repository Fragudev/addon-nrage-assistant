local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Core/Args", "Domain/PermissionService", "Domain/EventModel",
    "Domain/EventService", "Commands/RaidCommands",
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
    GetOwnGuildRank = function() return rank end,
    GetIdentityKey = function() return "Leader-Realm" end,
    ServerTime = function() return 1000 end,
    FormatDate = function(timestamp) return "date:" .. timestamp end,
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
    "SendEvent", "SendAttendance", "SendAssignment", "SendDeleteEvent", "SendDeleteAssignment",
  }) do
    env.comm[kind] = record(kind)
  end
  env.raid = ns.RaidCommands.New({
    events = env.events, tombstones = env.tombstones, platform = env.platform, comm = env.comm,
  })
  return env
end

local function text(lines)
  return table.concat(lines, "\n")
end

describe("RaidCommands events", function()
  local env

  before_each(function()
    env = build("RL")
  end)

  it("explains an empty list", function()
    assert.is_truthy(text(env.raid:Event("")):find("No events yet", 1, true))
  end)

  it("creates an event, stores it and sends it to the guild", function()
    local lines = env.raid:Event("new Molten Core night")
    assert.is_truthy(text(lines):find("created event 'Molten Core night'", 1, true))
    assert.are.equal(1, #env.sent)
    assert.are.equal("SendEvent", env.sent[1].kind)
    local stored = env.sent[1].args[1]
    assert.are.equal("Molten Core night", stored.title)
    assert.are.equal("Leader-Realm", stored.updatedBy)
  end)

  it("lists events by number with status and date", function()
    env.raid:Event("new Later")
    local first = ns.EventService.List({ events = env.events })[1]
    first.startAt = 100
    env.raid:Event("new Sooner")
    local lines = env.raid:Event("list")
    assert.are.equal("2 event(s):", lines[1])
    assert.is_truthy(lines[2]:find("1. Later [planned] - date:100", 1, true))
  end)

  it("renames, changes the status and deletes by number", function()
    env.raid:Event("new Old name")
    assert.is_truthy(text(env.raid:Event("rename 1 New name")):find("updated 'New name'", 1, true))
    assert.is_truthy(text(env.raid:Event("status 1 open")):find("[open]", 1, true))
    assert.are.equal("SendEvent", env.sent[3].kind)

    assert.is_truthy(text(env.raid:Event("delete 1")):find("deleted 'New name'", 1, true))
    assert.are.equal("SendDeleteEvent", env.sent[4].kind)
    assert.is_nil(next(env.events))
    assert.is_truthy(next(env.tombstones))
  end)

  it("rejects bad input without sending anything", function()
    assert.is_truthy(text(env.raid:Event("new")):find("invalid title", 1, true))
    env.raid:Event("new Real")
    local before = #env.sent
    assert.is_truthy(text(env.raid:Event("status 1 boom")):find("status must be", 1, true))
    assert.is_truthy(text(env.raid:Event("rename 1")):find("invalid title", 1, true))
    assert.is_truthy(text(env.raid:Event("rename x New")):find("give the event number", 1, true))
    assert.is_truthy(text(env.raid:Event("rename 9 New")):find("no event number 9", 1, true))
    assert.is_truthy(text(env.raid:Event("frobnicate")):find("usage:", 1, true))
    assert.are.equal(before, #env.sent)
  end)

  it("tells a member why they cannot create events, and sends nothing", function()
    local member = build("member")
    local lines = member.raid:Event("new Nope")
    assert.is_truthy(text(lines):find("not allowed", 1, true))
    assert.is_truthy(text(lines):find("'member'", 1, true))
    assert.are.equal(0, #member.sent)
    assert.is_nil(next(member.events))
  end)

  it("treats an unmapped or missing rank as a member without raising", function()
    for _, rank in ipairs({ "Recruit" }) do
      assert.is_truthy(text(build(rank).raid:Event("new X")):find("not allowed", 1, true))
    end
    local nobody = build(nil)
    assert.is_truthy(text(nobody.raid:Event("new X")):find("not allowed", 1, true))
  end)

  it("reports when a change was saved but could not be queued", function()
    env.sendResult = { false, "full" }
    local lines = text(env.raid:Event("new Offline"))
    assert.is_truthy(lines:find("created event 'Offline'", 1, true))
    assert.is_truthy(lines:find("saved here, but not sent to the guild (full)", 1, true))
    assert.is_truthy(next(env.events))
  end)
end)

describe("RaidCommands attendance", function()
  local env

  before_each(function()
    env = build("Officer")
    env.raid:Event("new Raid night")
    env.sent = {}
  end)

  it("says nothing was recorded yet", function()
    assert.is_truthy(text(env.raid:Attendance("1")):find("No attendance recorded", 1, true))
  end)

  it("records a state, sends it, and lists it sorted with its source", function()
    env.raid:Attendance("1 Zed-Realm present")
    env.raid:Attendance("1 Ann-Realm late")
    assert.are.equal("SendAttendance", env.sent[1].kind)
    assert.are.equal("Zed-Realm", env.sent[1].args[2])

    local lines = env.raid:Attendance("1")
    assert.are.equal("  Ann-Realm - late [declared]", lines[2])
    assert.are.equal("  Zed-Realm - present [declared]", lines[3])
  end)

  it("rejects unknown states and missing events", function()
    local before = #env.sent
    assert.is_truthy(text(env.raid:Attendance("1 Ann-Realm disconnected")):find("unknown state", 1, true))
    assert.is_truthy(text(env.raid:Attendance("7 Ann-Realm present")):find("no event number 7", 1, true))
    assert.is_truthy(text(env.raid:Attendance("")):find("usage:", 1, true))
    assert.are.equal(before, #env.sent)
  end)

  it("refuses a member", function()
    local member = build("member")
    member.events["ev-1"] = { eventId = "ev-1", title = "Raid", status = "planned", attendance = {}, assignments = {} }
    assert.is_truthy(text(member.raid:Attendance("1 Ann-Realm present")):find("not allowed", 1, true))
    assert.is_nil(next(member.events["ev-1"].attendance))
  end)
end)

describe("RaidCommands assignments", function()
  local env

  before_each(function()
    env = build("GM")
    env.raid:Event("new Raid night")
    env.sent = {}
  end)

  it("adds an assignment with a multi-word encounter and sends it", function()
    local lines = text(env.raid:Assign("1 add Ann-Realm Baron Geddon"))
    assert.is_truthy(lines:find("assigned Ann-Realm to Baron Geddon", 1, true))
    assert.are.equal("SendAssignment", env.sent[1].kind)
    assert.are.equal("Baron Geddon", env.sent[1].args[2].encounter)
  end)

  it("lists assignments sorted by encounter and character", function()
    env.raid:Assign("1 add Zed-Realm Ragnaros")
    env.raid:Assign("1 add Ann-Realm Ragnaros")
    env.raid:Assign("1 add Bob-Realm Garr")
    local lines = env.raid:Assign("1")
    assert.are.equal("  1. Garr: Bob-Realm", lines[2])
    assert.are.equal("  2. Ragnaros: Ann-Realm", lines[3])
    assert.are.equal("  3. Ragnaros: Zed-Realm", lines[4])
  end)

  it("removes an assignment by its listed number", function()
    env.raid:Assign("1 add Ann-Realm Garr")
    env.raid:Assign("1 add Bob-Realm Ragnaros")
    env.sent = {}
    assert.is_truthy(text(env.raid:Assign("1 remove 2")):find("removed Bob-Realm from Ragnaros", 1, true))
    assert.are.equal("SendDeleteAssignment", env.sent[1].kind)
    assert.is_truthy(text(env.raid:Assign("1")):find("Garr: Ann-Realm", 1, true))
    assert.is_nil(text(env.raid:Assign("1")):find("Ragnaros", 1, true))
  end)

  it("explains bad usage without changing anything", function()
    local before = #env.sent
    assert.is_truthy(text(env.raid:Assign("1 add Ann-Realm")):find("usage:", 1, true))
    assert.is_truthy(text(env.raid:Assign("1 remove 5")):find("give the assignment number", 1, true))
    assert.is_truthy(text(env.raid:Assign("1 dance")):find("usage:", 1, true))
    assert.is_truthy(text(env.raid:Assign("9 add A-Realm X")):find("no event number 9", 1, true))
    assert.are.equal(before, #env.sent)
  end)

  it("refuses a member", function()
    local member = build("alter")
    member.events["ev-1"] = { eventId = "ev-1", title = "Raid", status = "planned", attendance = {}, assignments = {} }
    assert.is_truthy(text(member.raid:Assign("1 add Ann-Realm Garr")):find("not allowed", 1, true))
    assert.is_nil(next(member.events["ev-1"].assignments))
  end)
end)

describe("RaidCommands event start time", function()
  it("sets the start from a local date and sends the update", function()
    local env = build("RL")
    env.raid:Event("new Raid")
    env.sent = {}
    assert.is_truthy(text(env.raid:Event("start 1 2026-10-03 20:30")):find("updated 'Raid'", 1, true))
    assert.are.equal(1003, ns.EventService.List({ events = env.events })[1].startAt)
    assert.are.equal("SendEvent", env.sent[1].kind)
  end)

  it("explains the format and changes nothing when the date is not valid", function()
    local env = build("RL")
    env.raid:Event("new Raid")
    env.sent = {}
    local lines = text(env.raid:Event("start 1 tomorrow evening"))
    assert.is_truthy(lines:find("YYYY-MM-DD HH:MM", 1, true))
    assert.is_nil(ns.EventService.List({ events = env.events })[1].startAt)
    assert.are.equal(0, #env.sent)
  end)

  it("reports a missing event and refuses a member", function()
    local env = build("RL")
    assert.is_truthy(text(env.raid:Event("start 3 2026-10-03 20:30")):find("no event number 3", 1, true))

    local member = build("member")
    member.events["ev-1"] = { eventId = "ev-1", title = "Raid", status = "planned", attendance = {}, assignments = {} }
    assert.is_truthy(text(member.raid:Event("start 1 2026-10-03 20:30")):find("not allowed", 1, true))
    assert.are.equal(0, #member.sent)
  end)
end)

describe("RaidCommands character names with spaces", function()
  local env

  before_each(function()
    env = build("Officer")
    env.raid:Event("new Raid night")
    env.sent = {}
  end)

  it("records attendance for a name with spaces: the state is the last word", function()
    local lines = text(env.raid:Attendance("1 Yonemon Gg present"))
    assert.is_truthy(lines:find("Yonemon Gg: present.", 1, true))
    assert.are.equal("SendAttendance", env.sent[1].kind)
    assert.are.equal("Yonemon Gg", env.sent[1].args[2])
    assert.is_truthy(text(env.raid:Attendance("1")):find("  Yonemon Gg - present [declared]", 1, true))
  end)

  it("accepts the name in quotes, and still accepts a single-word name", function()
    env.raid:Attendance('1 "Black Coffee" late')
    env.raid:Attendance("1 Ann-Realm absent")
    local listing = text(env.raid:Attendance("1"))
    assert.is_truthy(listing:find("  Black Coffee - late [declared]", 1, true))
    assert.is_truthy(listing:find("  Ann-Realm - absent [declared]", 1, true))
  end)

  it("asks for a state when only a name is given, and records nothing", function()
    assert.is_truthy(text(env.raid:Attendance("1 Ann-Realm")):find("usage:", 1, true))
    assert.is_truthy(text(env.raid:Attendance('1 "" present')):find("usage:", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("adds an assignment for a quoted name with spaces and a multi-word encounter", function()
    local lines = text(env.raid:Assign('1 add "Yonemon Gg" Baron Geddon'))
    assert.is_truthy(lines:find("assigned Yonemon Gg to Baron Geddon", 1, true))
    assert.are.equal("Yonemon Gg", env.sent[1].args[2].characterKey)
    assert.are.equal("Baron Geddon", env.sent[1].args[2].encounter)
  end)

  it("explains how to quote when the assignment is malformed", function()
    for _, args in ipairs({ '1 add "Yonemon Gg"', '1 add "Yonemon Gg Ragnaros', "1 add" }) do
      local lines = text(env.raid:Assign(args))
      assert.is_truthy(lines:find("usage:", 1, true), args)
      assert.is_truthy(lines:find("quotes", 1, true), args)
    end
    assert.are.equal(0, #env.sent)
  end)
end)
