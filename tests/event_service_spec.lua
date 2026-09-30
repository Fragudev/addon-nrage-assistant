local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
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
    local ctx = build_ctx("admin")
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
