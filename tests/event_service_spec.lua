local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Constants = ns.EventService, ns.Constants

local function build_ctx(role)
  local ctx = {
    events = {},
    tombstones = {},
    role = role or "rl",
    actor = "Leader-Realm",
    rosterId = "r1",
    clock = 1000,
  }
  local counter = 0
  ctx.now = function()
    return ctx.clock
  end
  ctx.newId = function()
    counter = counter + 1
    return "id-" .. counter
  end
  return ctx
end

describe("EventModel", function()
  local Model = ns.EventModel

  it("validates event fields and drops unknown ones", function()
    local clean = Model.ValidateEvent({ title = "Molten Core", instance = "MC", startAt = 100, junk = 1 })
    assert.are.same({ title = "Molten Core", instance = "MC", startAt = 100 }, clean)
  end)

  it("names the invalid field", function()
    assert.are.equal("invalid:title", select(2, Model.ValidateEvent({ title = "" })))
    assert.are.equal("invalid:title", select(2, Model.ValidateEvent({ title = "|cffff0000Red" })))
    assert.are.equal("invalid:startAt", select(2, Model.ValidateEvent({ title = "X", startAt = -1 })))
    assert.are.equal("invalid:startAt", select(2, Model.ValidateEvent({ title = "X", startAt = 1.5 })))
    assert.are.equal("invalid:status", select(2, Model.ValidateEvent({ title = "X", status = "boom" })))
    assert.are.equal("invalid:fields", select(2, Model.ValidateEvent("nope")))
  end)

  it("requires a title on create but not on partial updates", function()
    assert.is_nil(Model.ValidateEvent({ instance = "MC" }))
    assert.are.same({ instance = "MC" }, Model.ValidateEvent({ instance = "MC" }, true))
  end)

  it("validates assignments", function()
    local clean = Model.ValidateAssignment({ encounter = "Ragnaros", characterKey = "A-Realm", group = 2, task = "MT" })
    assert.are.equal(2, clean.group)
    assert.are.equal("invalid:encounter", select(2, Model.ValidateAssignment({ characterKey = "A-Realm" })))
    assert.are.equal("invalid:characterKey", select(2, Model.ValidateAssignment({ encounter = "X" })))
    assert.are.equal(
      "invalid:group",
      select(
        2,
        Model.ValidateAssignment({
          encounter = "X",
          characterKey = "A-Realm",
          group = 9,
        })
      )
    )
    assert.are.equal(
      "invalid:note",
      select(
        2,
        Model.ValidateAssignment({
          encounter = "X",
          characterKey = "A-Realm",
          note = ("n"):rep(101),
        })
      )
    )
  end)

  it("knows the attendance states from the plan", function()
    local states = { "invited", "confirmed", "present", "late", "leftEarly", "absent", "excused", "unknown" }
    for _, state in ipairs(states) do
      assert.is_true(Model.IsAttendanceState(state), state)
    end
    assert.is_false(Model.IsAttendanceState("disconnected"))
    assert.is_false(Model.IsAttendanceState(nil))
  end)
end)

describe("EventService.Create", function()
  it("lets an RL create an event with stamped metadata", function()
    local ctx = build_ctx("rl")
    local event = assert(Service.Create(ctx, { title = "Molten Core", startAt = 5000 }))
    assert.are.equal("id-1", event.eventId)
    assert.are.equal("planned", event.status)
    assert.are.equal(1, event.rev)
    assert.are.equal("Leader-Realm", event.updatedBy)
    assert.are.equal(1000, event.updatedAt)
    assert.are.equal("declared", event.source)
    assert.are.equal(event, ctx.events["id-1"])
    assert.are.same({}, event.loot)
  end)

  it("refuses members and unknown roles", function()
    for _, role in ipairs({ "member", "stranger" }) do
      local ctx = build_ctx(role)
      local event, reason = Service.Create(ctx, { title = "X" })
      assert.is_nil(event)
      assert.are.equal("forbidden", reason)
      assert.is_nil(next(ctx.events))
    end
    local ctx = build_ctx(nil)
    ctx.role = nil
    assert.are.equal("forbidden", select(2, Service.Create(ctx, { title = "X" })))
  end)

  it("rejects invalid fields without creating anything", function()
    local ctx = build_ctx("gm")
    assert.are.equal("invalid:title", select(2, Service.Create(ctx, { title = "" })))
    assert.is_nil(next(ctx.events))
  end)

  it("stops at the event limit", function()
    local ctx = build_ctx("rl")
    for i = 1, Constants.EVENT_MAX do
      ctx.events["e" .. i] = { title = "E" }
    end
    assert.are.equal("limit", select(2, Service.Create(ctx, { title = "One more" })))
  end)
end)

describe("EventService.Update and Delete", function()
  it("updates fields, bumps the revision and records who edited", function()
    local ctx = build_ctx("rl")
    local event = Service.Create(ctx, { title = "Old" })
    ctx.clock, ctx.actor = 2000, "Other-Realm"
    assert.are.equal(event, Service.Update(ctx, event.eventId, { title = "New", status = "open" }))
    assert.are.equal("New", event.title)
    assert.are.equal("open", event.status)
    assert.are.equal(2, event.rev)
    assert.are.equal(2000, event.updatedAt)
    assert.are.equal("Other-Realm", event.updatedBy)
  end)

  it("refuses members and unknown events, and leaves the event untouched on bad input", function()
    local ctx = build_ctx("rl")
    local event = Service.Create(ctx, { title = "Keep" })
    assert.are.equal("invalid:status", select(2, Service.Update(ctx, event.eventId, { status = "boom" })))
    assert.are.equal("not_found", select(2, Service.Update(ctx, "nope", { title = "X" })))
    assert.are.equal("Keep", event.title)
    assert.are.equal(1, event.rev)

    ctx.role = "member"
    assert.are.equal("forbidden", select(2, Service.Update(ctx, event.eventId, { title = "X" })))
  end)

  it("deletes an event and leaves a tombstone", function()
    local ctx = build_ctx("rl")
    local event = Service.Create(ctx, { title = "Gone" })
    assert.is_true(Service.Delete(ctx, event.eventId))
    assert.is_nil(ctx.events[event.eventId])
    assert.are.same({ at = 1000, rev = 2 }, ctx.tombstones["E:" .. event.eventId])
  end)

  it("refuses to delete for members or missing events", function()
    local ctx = build_ctx("rl")
    local event = Service.Create(ctx, { title = "Stay" })
    assert.are.equal("not_found", select(2, Service.Delete(ctx, "nope")))
    ctx.role = "member"
    assert.are.equal("forbidden", select(2, Service.Delete(ctx, event.eventId)))
    assert.is_truthy(ctx.events[event.eventId])
    assert.is_nil(next(ctx.tombstones))
  end)

  it("keeps the tombstone list bounded by dropping the oldest", function()
    local ctx = build_ctx("rl")
    for i = 1, Constants.TOMBSTONE_MAX do
      ctx.tombstones["old" .. i] = { at = i, rev = 1 }
    end
    local event = Service.Create(ctx, { title = "New" })
    Service.Delete(ctx, event.eventId)
    assert.is_nil(ctx.tombstones["old1"])
    assert.is_truthy(ctx.tombstones["E:" .. event.eventId])
    local count = 0
    for _ in pairs(ctx.tombstones) do
      count = count + 1
    end
    assert.are.equal(Constants.TOMBSTONE_MAX, count)
  end)
end)

describe("EventService attendance", function()
  local ctx, event

  before_each(function()
    ctx = build_ctx("rl")
    event = Service.Create(ctx, { title = "Raid" })
  end)

  it("records a state with who set it and bumps the revision on change", function()
    local record = assert(Service.SetAttendance(ctx, event.eventId, "A-Realm", "present"))
    assert.are.equal("present", record.state)
    assert.are.equal("Leader-Realm", record.recordedBy)
    assert.are.equal("declared", record.source)
    assert.are.equal(1, record.rev)

    Service.SetAttendance(ctx, event.eventId, "A-Realm", "leftEarly")
    assert.are.equal(2, event.attendance["A-Realm"].rev)
    assert.are.equal("leftEarly", event.attendance["A-Realm"].state)
  end)

  it("refuses members", function()
    ctx.role = "member"
    assert.are.equal("forbidden", select(2, Service.SetAttendance(ctx, event.eventId, "A-Realm", "present")))
    assert.is_nil(next(event.attendance))
  end)

  it("rejects bad states, bad keys and missing events", function()
    assert.are.equal("invalid_state", select(2, Service.SetAttendance(ctx, event.eventId, "A-Realm", "disconnected")))
    assert.are.equal("invalid:characterKey", select(2, Service.SetAttendance(ctx, event.eventId, "", "present")))
    assert.are.equal("not_found", select(2, Service.SetAttendance(ctx, "nope", "A-Realm", "present")))
  end)

  it("stops at the attendance limit but still updates existing entries", function()
    for i = 1, Constants.EVENT_ATTENDANCE_MAX do
      event.attendance["P" .. i .. "-Realm"] = { state = "invited", rev = 1 }
    end
    assert.are.equal("limit", select(2, Service.SetAttendance(ctx, event.eventId, "New-Realm", "present")))
    assert.is_truthy(Service.SetAttendance(ctx, event.eventId, "P1-Realm", "present"))
  end)
end)

describe("EventService sign-up", function()
  local ctx, event

  before_each(function()
    local leader = build_ctx("rl")
    event = Service.Create(leader, { title = "Raid", startAt = 5000, rosterId = "r1" })
    ctx = build_ctx("roster")
    ctx.events = leader.events
    ctx.actor = "Player-Realm"
    ctx.clock = 1000
  end)

  it("signs up the own character and stamps the record", function()
    local record = assert(Service.SetSignup(ctx, event.eventId, "yes"))
    assert.are.equal("yes", record.status)
    assert.are.equal(1, record.rev)
    assert.are.equal(1000, record.updatedAt)
    assert.are.equal("Player-Realm", next(event.signups))
  end)

  it("has no character argument: only the actor can be signed up", function()
    -- A second argument after the status is not read, and a name in place of the status is not a status.
    assert.are.equal("invalid:status", select(2, Service.SetSignup(ctx, event.eventId, "Other-Realm")))
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes", "Other-Realm"))
    assert.is_nil(event.signups["Other-Realm"])
    assert.is_truthy(event.signups["Player-Realm"])
  end)

  it("lets the answer change from yes to no", function()
    Service.SetSignup(ctx, event.eventId, "yes")
    ctx.clock = 1100
    local record = assert(Service.SetSignup(ctx, event.eventId, "no"))
    assert.are.equal("no", record.status)
    assert.are.equal(2, record.rev)
    assert.are.equal(1100, record.updatedAt)
  end)

  it("rejects a status that is neither yes nor no", function()
    assert.are.equal("invalid:status", select(2, Service.SetSignup(ctx, event.eventId, "maybe")))
    assert.are.equal("invalid:status", select(2, Service.SetSignup(ctx, event.eventId, nil)))
  end)

  it("refuses member, alter and a rank with no roster", function()
    ctx.role = "member"
    assert.are.equal("forbidden", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    ctx.role = "alter"
    assert.are.equal("forbidden", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    ctx.role, ctx.rosterId = "rl", nil
    assert.are.equal("forbidden", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    assert.is_nil(next(event.signups))
  end)

  it("accepts every rank that has event_signup", function()
    for _, role in ipairs({ "officer", "rl", "roster" }) do
      ctx.role = role
      assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"), role)
    end
    ctx.role, ctx.rosterId = "gm", nil
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"))
  end)

  it("refuses an event of another roster, but not a guild-wide one", function()
    ctx.rosterId = "r2"
    assert.are.equal("other_roster", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    event.rosterId = nil
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"))
  end)

  it("lets the guild master sign up for any roster", function()
    ctx.role, ctx.rosterId = "gm", nil
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "no"))
  end)

  it("is closed once the event started, or is closed or cancelled", function()
    ctx.clock = 5000
    assert.are.equal("closed", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    ctx.clock = 1000
    for _, status in ipairs({ "closed", "cancelled" }) do
      event.status = status
      assert.are.equal("closed", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    end
    event.status = "open"
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"))
  end)

  it("stays open for an undated event", function()
    event.startAt = nil
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"))
  end)

  it("works on an old event without a signups table, and reports a missing event", function()
    event.signups = nil
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "yes"))
    assert.are.equal("not_found", select(2, Service.SetSignup(ctx, "nope", "yes")))
  end)

  it("stops at the limit but still lets an existing answer change", function()
    for i = 1, Constants.EVENT_ATTENDANCE_MAX do
      event.signups["P" .. i .. "-Realm"] = { status = "yes", rev = 1, updatedAt = 1 }
    end
    assert.are.equal("limit", select(2, Service.SetSignup(ctx, event.eventId, "yes")))
    ctx.actor = "P1-Realm"
    assert.is_truthy(Service.SetSignup(ctx, event.eventId, "no"))
  end)

  it("creates new events with an empty signups table", function()
    assert.are.same({}, event.signups)
  end)
end)

describe("EventService assignments", function()
  local ctx, event

  before_each(function()
    ctx = build_ctx("rl")
    event = Service.Create(ctx, { title = "Raid" })
  end)

  it("adds and removes an assignment, leaving a tombstone on removal", function()
    local assignment = assert(Service.AddAssignment(ctx, event.eventId, {
      encounter = "Ragnaros",
      characterKey = "A-Realm",
      group = 1,
      task = "Main tank",
    }))
    assert.are.equal("Main tank", event.assignments[assignment.assignmentId].task)
    assert.are.equal(1, assignment.rev)

    assert.is_true(Service.RemoveAssignment(ctx, event.eventId, assignment.assignmentId))
    assert.is_nil(event.assignments[assignment.assignmentId])
    local key = ("A:%s:%s"):format(event.eventId, assignment.assignmentId)
    assert.is_truthy(ctx.tombstones[key])
  end)

  it("refuses members and invalid assignments", function()
    local fields = { encounter = "Ragnaros", characterKey = "A-Realm" }
    assert.are.equal("invalid:encounter", select(2, Service.AddAssignment(ctx, event.eventId, { characterKey = "A" })))
    ctx.role = "member"
    assert.are.equal("forbidden", select(2, Service.AddAssignment(ctx, event.eventId, fields)))
    assert.are.equal("forbidden", select(2, Service.RemoveAssignment(ctx, event.eventId, "x")))
    assert.is_nil(next(event.assignments))
  end)

  it("reports missing events and assignments", function()
    local fields = { encounter = "Ragnaros", characterKey = "A-Realm" }
    assert.are.equal("not_found", select(2, Service.AddAssignment(ctx, "nope", fields)))
    assert.are.equal("not_found", select(2, Service.RemoveAssignment(ctx, event.eventId, "nope")))
    assert.are.equal("not_found", select(2, Service.RemoveAssignment(ctx, "nope", "nope")))
  end)

  it("stops at the assignment limit", function()
    for i = 1, Constants.EVENT_ASSIGNMENTS_MAX do
      event.assignments["a" .. i] = { rev = 1 }
    end
    local fields = { encounter = "Ragnaros", characterKey = "A-Realm" }
    assert.are.equal("limit", select(2, Service.AddAssignment(ctx, event.eventId, fields)))
  end)
end)

describe("EventService.List and Purge", function()
  it("sorts by start time, undated last, then by title", function()
    local ctx = build_ctx("rl")
    Service.Create(ctx, { title = "Undated" })
    Service.Create(ctx, { title = "Later", startAt = 300 })
    Service.Create(ctx, { title = "Beta", startAt = 100 })
    Service.Create(ctx, { title = "Alpha", startAt = 100 })
    local titles = {}
    for _, event in ipairs(Service.List(ctx)) do
      titles[#titles + 1] = event.title
    end
    assert.are.same({ "Alpha", "Beta", "Later", "Undated" }, titles)
  end)

  it("purges events past retention and expired tombstones only", function()
    local ctx = build_ctx("rl")
    ctx.clock = 100 * 24 * 3600
    ctx.events.old = { title = "Old", startAt = 1 }
    ctx.events.fresh = { title = "Fresh", startAt = ctx.clock - 10 }
    ctx.events.undated = { title = "Undated", updatedAt = ctx.clock - 10 }
    ctx.tombstones.stale = { at = 1, rev = 1 }
    ctx.tombstones.recent = { at = ctx.clock - 10, rev = 1 }

    assert.are.equal(1, Service.Purge(ctx))
    assert.is_nil(ctx.events.old)
    assert.is_truthy(ctx.events.fresh)
    assert.is_truthy(ctx.events.undated)
    assert.is_nil(ctx.tombstones.stale)
    assert.is_truthy(ctx.tombstones.recent)
  end)
end)

describe("EventService raid_manage scope", function()
  local function with_event(role, rosterId)
    local ctx = build_ctx("gm")
    ctx.rosterId = nil
    local event = assert(Service.Create(ctx, { title = "Raid" }))
    event.rosterId = rosterId
    ctx.role, ctx.rosterId = role, "r1"
    return ctx, event
  end

  it("lets an officer and a raid leader change events, attendance and assignments of the own roster", function()
    for _, role in ipairs({ "officer", "rl" }) do
      local ctx, event = with_event(role, "r1")
      assert.is_truthy(Service.Update(ctx, event.eventId, { title = "Renamed" }), role)
      assert.is_truthy(Service.SetAttendance(ctx, event.eventId, "Ann-Realm", "present"), role)
      assert.is_truthy(
        Service.AddAssignment(ctx, event.eventId, { encounter = "Garr", characterKey = "Ann-Realm" }),
        role
      )
      assert.is_truthy(Service.Delete(ctx, event.eventId), role)
    end
  end)

  it("keeps an officer and a raid leader out of the events of another roster", function()
    for _, role in ipairs({ "officer", "rl" }) do
      local ctx, event = with_event(role, "r2")
      assert.are.equal("other_roster", select(2, Service.Update(ctx, event.eventId, { title = "X" })), role)
      assert.are.equal(
        "other_roster",
        select(2, Service.SetAttendance(ctx, event.eventId, "Ann-Realm", "present")),
        role
      )
      assert.are.equal(
        "other_roster",
        select(2, Service.AddAssignment(ctx, event.eventId, { encounter = "Garr", characterKey = "Ann-Realm" })),
        role
      )
      assert.are.equal("other_roster", select(2, Service.Delete(ctx, event.eventId)), role)
      assert.are.equal("Raid", event.title, role)
    end
  end)

  it("creates the events of an officer in their own roster, and refuses another one", function()
    local ctx = build_ctx("officer")
    assert.are.equal("r1", assert(Service.Create(ctx, { title = "Mine" })).rosterId)
    assert.are.equal("other_roster", select(2, Service.Create(ctx, { title = "Theirs", rosterId = "r2" })))
  end)

  it("refuses a roster player, a member and an alter, and lets gm and cogm act on any roster", function()
    for _, role in ipairs({ "roster", "member", "alter" }) do
      local ctx, event = with_event(role, "r1")
      assert.are.equal("forbidden", select(2, Service.Update(ctx, event.eventId, { title = "X" })), role)
      assert.are.equal("forbidden", select(2, Service.Create(ctx, { title = "Y" })), role)
    end
    for _, role in ipairs({ "gm", "cogm" }) do
      local ctx, event = with_event(role, "r2")
      ctx.rosterId = nil
      assert.is_truthy(Service.Update(ctx, event.eventId, { title = "By boss" }), role)
    end
  end)
end)
