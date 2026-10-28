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
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/EventSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local EventSync, EventService, Protocol, Constants = ns.EventSync, ns.EventService, ns.Protocol, ns.Constants

-- One simulated client: its own data, its own clock.
local function client(name)
  local c = { name = name, events = {}, tombstones = {}, clock = 10000, counter = 0 }
  function c.apply_ctx()
    return {
      events = c.events,
      tombstones = c.tombstones,
      -- Everybody is in roster r1 unless a test says otherwise.
      rosterOf = c.rosterOf or function()
        return "r1"
      end,
      now = function()
        return c.clock
      end,
    }
  end
  function c.local_ctx(role)
    return {
      events = c.events,
      tombstones = c.tombstones,
      role = role or "rl",
      actor = name,
      rosterId = "r1",
      now = function()
        return c.clock
      end,
      newId = function()
        c.counter = c.counter + 1
        return name .. "-" .. c.counter
      end,
    }
  end
  return c
end

-- Sends a payload through the real protocol validation, as the receiver would see it.
local function on_wire(messageType, payload)
  local message = assert(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")))
  return message
end

local function deliver(receiver, messageType, payload, sender, role)
  return EventSync.Apply(receiver.apply_ctx(), on_wire(messageType, payload), sender, role)
end

local function new_event(author, fields)
  return assert(EventService.Create(author.local_ctx(), fields or { title = "Molten Core", startAt = 5000 }))
end

describe("EventSync EVENT_UPSERT", function()
  it("stores a received event with the sender as author and source received", function()
    local rl, member = client("Leader-Realm"), client("Member-Realm")
    local event = new_event(rl)
    assert.is_true(deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl"))

    local stored = member.events[event.eventId]
    assert.are.equal("Molten Core", stored.title)
    assert.are.equal("received", stored.source)
    assert.are.equal("Leader-Realm", stored.updatedBy)
    assert.are.same({}, stored.attendance)
    assert.are.same({}, stored.loot)
  end)

  it("takes the author from the sender, not from anything in the payload", function()
    local member = client("Member-Realm")
    local payload =
      { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 10, title = "X", updatedBy = "Fake-Realm" }
    assert.is_true(deliver(member, "EVENT_UPSERT", payload, "Real-Realm", "rl"))
    assert.are.equal("Real-Realm", member.events["ev-1"].updatedBy)
  end)

  it("refuses members and senders the roster does not know", function()
    local rl, member = client("Leader-Realm"), client("Member-Realm")
    local payload = EventSync.EventPayload(new_event(rl))
    local ok, reason = deliver(member, "EVENT_UPSERT", payload, "Raider-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = deliver(member, "EVENT_UPSERT", payload, "Stranger-Realm", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(next(member.events))
  end)

  it("applies a higher revision and ignores an older one", function()
    local rl, member = client("Leader-Realm"), client("Member-Realm")
    local event = new_event(rl)
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl")
    local first = EventSync.EventPayload(event)

    EventService.Update(rl.local_ctx(), event.eventId, { title = "Renamed" })
    assert.is_true(deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl"))
    assert.are.equal("Renamed", member.events[event.eventId].title)

    local ok, reason = deliver(member, "EVENT_UPSERT", first, "Leader-Realm", "rl")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal("Renamed", member.events[event.eventId].title)
  end)

  it("breaks a revision tie by time, then by sender, and ignores an identical record", function()
    local member = client("Member-Realm")
    local base = { eventId = "ev-1", rosterId = "r1", rev = 2, updatedAt = 100, title = "Base" }
    deliver(member, "EVENT_UPSERT", base, "Bbb-Realm", "rl")

    local later = { eventId = "ev-1", rosterId = "r1", rev = 2, updatedAt = 200, title = "Later" }
    assert.is_true(deliver(member, "EVENT_UPSERT", later, "Aaa-Realm", "rl"))
    assert.are.equal("Later", member.events["ev-1"].title)

    local earlier = { eventId = "ev-1", rosterId = "r1", rev = 2, updatedAt = 150, title = "Earlier" }
    assert.are.equal("stale", select(2, deliver(member, "EVENT_UPSERT", earlier, "Zzz-Realm", "rl")))

    local sameTimeLarger = { eventId = "ev-1", rosterId = "r1", rev = 2, updatedAt = 200, title = "Larger sender" }
    assert.is_true(deliver(member, "EVENT_UPSERT", sameTimeLarger, "Zzz-Realm", "rl"))
    assert.are.equal("Larger sender", member.events["ev-1"].title)

    assert.are.equal("stale", select(2, deliver(member, "EVENT_UPSERT", sameTimeLarger, "Zzz-Realm", "rl")))
  end)

  it("clamps an updatedAt dated far in the future", function()
    local member = client("Member-Realm")
    deliver(
      member,
      "EVENT_UPSERT",
      { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 4000000000, title = "X" },
      "A-Realm",
      "rl"
    )
    assert.are.equal(member.clock + 300, member.events["ev-1"].updatedAt)
  end)

  it("keeps the receiver's attendance and assignments when the event fields change", function()
    local rl, member = client("Leader-Realm"), client("Member-Realm")
    local event = new_event(rl)
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl")
    local record = EventService.SetAttendance(rl.local_ctx(), event.eventId, "A-Realm", "present")
    local attendance = EventSync.AttendancePayload(event.eventId, "A-Realm", record)
    deliver(member, "ATTENDANCE_UPSERT", attendance, "Leader-Realm", "rl")

    EventService.Update(rl.local_ctx(), event.eventId, { title = "Renamed" })
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl")
    assert.are.equal("present", member.events[event.eventId].attendance["A-Realm"].state)
  end)

  it("clears fields the newer upsert omits, and defaults the status", function()
    local member = client("Member-Realm")
    local first =
      { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 1, title = "X", instance = "MC", status = "open" }
    deliver(member, "EVENT_UPSERT", first, "A-Realm", "rl")
    deliver(
      member,
      "EVENT_UPSERT",
      { eventId = "ev-1", rosterId = "r1", rev = 2, updatedAt = 2, title = "X" },
      "A-Realm",
      "rl"
    )
    assert.is_nil(member.events["ev-1"].instance)
    assert.are.equal("planned", member.events["ev-1"].status)
  end)

  it("stops at the event limit", function()
    local member = client("Member-Realm")
    for i = 1, Constants.EVENT_MAX do
      member.events["e" .. i] = { rev = 1, updatedAt = 1 }
    end
    local extra = { eventId = "new", rosterId = "r1", rev = 1, updatedAt = 1, title = "X" }
    local ok, reason = deliver(member, "EVENT_UPSERT", extra, "A-Realm", "rl")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("EventSync ATTENDANCE_UPSERT", function()
  local rl, member, event

  before_each(function()
    rl, member = client("Leader-Realm"), client("Member-Realm")
    event = new_event(rl)
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl")
  end)

  local function attendance(state)
    local record = assert(EventService.SetAttendance(rl.local_ctx(), event.eventId, "A-Realm", state))
    return EventSync.AttendancePayload(event.eventId, "A-Realm", record)
  end

  it("stores the record with the sender as recorder", function()
    assert.is_true(deliver(member, "ATTENDANCE_UPSERT", attendance("present"), "Leader-Realm", "rl"))
    local record = member.events[event.eventId].attendance["A-Realm"]
    assert.are.equal("present", record.state)
    assert.are.equal("Leader-Realm", record.recordedBy)
    assert.are.equal("received", record.source)
  end)

  it("needs a known event", function()
    local other = client("Other-Realm")
    local ok, reason = deliver(other, "ATTENDANCE_UPSERT", attendance("present"), "Leader-Realm", "rl")
    assert.is_false(ok)
    assert.are.equal("unknown_event", reason)
  end)

  it("refuses members and unknown senders", function()
    local payload = attendance("present")
    assert.are.equal("forbidden", select(2, deliver(member, "ATTENDANCE_UPSERT", payload, "R-Realm", "member")))
    assert.are.equal("unknown_sender", select(2, deliver(member, "ATTENDANCE_UPSERT", payload, "S-Realm", nil)))
  end)

  it("keeps the newest revision only", function()
    local first, second = attendance("present"), attendance("leftEarly")
    deliver(member, "ATTENDANCE_UPSERT", second, "Leader-Realm", "rl")
    assert.are.equal("stale", select(2, deliver(member, "ATTENDANCE_UPSERT", first, "Leader-Realm", "rl")))
    assert.are.equal("leftEarly", member.events[event.eventId].attendance["A-Realm"].state)
  end)

  it("stops at the attendance limit", function()
    for i = 1, Constants.EVENT_ATTENDANCE_MAX do
      member.events[event.eventId].attendance["P" .. i .. "-Realm"] = { rev = 1, updatedAt = 1 }
    end
    local payload = attendance("present")
    assert.are.equal("limit", select(2, deliver(member, "ATTENDANCE_UPSERT", payload, "Leader-Realm", "rl")))
  end)
end)

describe("EventSync assignments and deletes", function()
  local rl, member, event

  before_each(function()
    rl, member = client("Leader-Realm"), client("Member-Realm")
    event = new_event(rl)
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(event), "Leader-Realm", "rl")
  end)

  local function assignment()
    return assert(EventService.AddAssignment(rl.local_ctx(), event.eventId, {
      encounter = "Ragnaros",
      characterKey = "A-Realm",
      group = 1,
      task = "Main tank",
    }))
  end

  it("stores an assignment and refuses a member", function()
    local created = assignment()
    local payload = EventSync.AssignPayload(event.eventId, created)
    assert.are.equal("forbidden", select(2, deliver(member, "ASSIGN_UPSERT", payload, "R-Realm", "member")))
    assert.is_true(deliver(member, "ASSIGN_UPSERT", payload, "Leader-Realm", "rl"))
    local stored = member.events[event.eventId].assignments[created.assignmentId]
    assert.are.equal("Main tank", stored.task)
    assert.are.equal("Leader-Realm", stored.updatedBy)
  end)

  it("blocks a stale assignment upsert after a delete, but accepts a newer revision", function()
    local created = assignment()
    local upsert = EventSync.AssignPayload(event.eventId, created)
    deliver(member, "ASSIGN_UPSERT", upsert, "Leader-Realm", "rl")

    EventService.RemoveAssignment(rl.local_ctx(), event.eventId, created.assignmentId)
    local delete = EventSync.DeleteAssignmentPayload(rl.tombstones, event.eventId, created.assignmentId)
    assert.is_true(deliver(member, "DELETE", delete, "Leader-Realm", "rl"))
    assert.is_nil(member.events[event.eventId].assignments[created.assignmentId])

    assert.are.equal("tombstoned", select(2, deliver(member, "ASSIGN_UPSERT", upsert, "Leader-Realm", "rl")))

    local newer = EventSync.AssignPayload(event.eventId, created)
    newer.rev = delete.rev + 1
    assert.is_true(deliver(member, "ASSIGN_UPSERT", newer, "Leader-Realm", "rl"))
    assert.is_truthy(member.events[event.eventId].assignments[created.assignmentId])
    assert.is_nil(member.tombstones[("A:%s:%s"):format(event.eventId, created.assignmentId)])
  end)

  it("deletes an event, remembers it, and drops stale upserts afterwards", function()
    local upsert = EventSync.EventPayload(event)
    EventService.Delete(rl.local_ctx(), event.eventId)
    local delete = EventSync.DeleteEventPayload(rl.tombstones, event.eventId)

    assert.is_true(deliver(member, "DELETE", delete, "Leader-Realm", "rl"))
    assert.is_nil(member.events[event.eventId])
    assert.are.equal("tombstoned", select(2, deliver(member, "EVENT_UPSERT", upsert, "Leader-Realm", "rl")))

    local concurrent = EventSync.EventPayload(event)
    concurrent.rev = delete.rev
    assert.are.equal("tombstoned", select(2, deliver(member, "EVENT_UPSERT", concurrent, "Leader-Realm", "rl")))
  end)

  it("remembers a delete from the guild master for an event it never saw, but not from a raid leader", function()
    local fresh = client("Fresh-Realm")
    local delete = { kind = "event", eventId = "ghost", rev = 5 }
    assert.are.equal("unknown_event", select(2, deliver(fresh, "DELETE", delete, "Leader-Realm", "rl")))
    assert.is_nil(fresh.tombstones["E:ghost"])
    assert.is_true(deliver(fresh, "DELETE", delete, "Boss-Realm", "gm"))
    assert.are.equal(5, fresh.tombstones["E:ghost"].rev)
    local stale = { eventId = "ghost", rev = 4, updatedAt = 1, title = "X" }
    assert.are.equal("tombstoned", select(2, deliver(fresh, "EVENT_UPSERT", stale, "Leader-Realm", "rl")))
  end)

  it("ignores a delete older than the event and refuses members", function()
    local edited = EventService.Update(rl.local_ctx(), event.eventId, { title = "Edited" })
    deliver(member, "EVENT_UPSERT", EventSync.EventPayload(edited), "Leader-Realm", "rl")

    local old = { kind = "event", eventId = event.eventId, rev = 1 }
    assert.are.equal("stale", select(2, deliver(member, "DELETE", old, "Leader-Realm", "rl")))
    assert.is_truthy(member.events[event.eventId])

    local forceful = { kind = "event", eventId = event.eventId, rev = 99 }
    assert.are.equal("forbidden", select(2, deliver(member, "DELETE", forceful, "R-Realm", "member")))
    assert.is_truthy(member.events[event.eventId])
  end)

  it("reports an unsupported type", function()
    local ok, reason = EventSync.Apply(member.apply_ctx(), { t = "PROFILE", p = {} }, "A-Realm", "rl")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    assert.is_false(EventSync.IsRaidMessage("PROFILE"))
    assert.is_true(EventSync.IsRaidMessage("DELETE"))
  end)
end)

describe("EventSync convergence", function()
  it("leaves two clients identical after concurrent edits arrive in opposite orders", function()
    local a, b = client("Aaa-Realm"), client("Bbb-Realm")
    local event = new_event(a)
    local created = EventSync.EventPayload(event)
    deliver(b, "EVENT_UPSERT", created, "Aaa-Realm", "rl")

    -- Both leaders edit the same revision at the same time.
    a.clock, b.clock = 20000, 20005
    local editA = assert(EventService.Update(a.local_ctx(), event.eventId, { title = "From A" }))
    local fromA = EventSync.EventPayload(editA)
    local editB = assert(EventService.Update(b.local_ctx(), event.eventId, { title = "From B" }))
    local fromB = EventSync.EventPayload(editB)

    deliver(a, "EVENT_UPSERT", fromB, "Bbb-Realm", "rl")
    deliver(b, "EVENT_UPSERT", fromA, "Aaa-Realm", "rl")

    assert.are.equal("From B", a.events[event.eventId].title)
    assert.are.equal("From B", b.events[event.eventId].title)
    assert.are.equal(a.events[event.eventId].updatedBy, b.events[event.eventId].updatedBy)
  end)
end)

describe("EventSync payload builders", function()
  it("build payloads the protocol accepts", function()
    local rl = client("Leader-Realm")
    local event = new_event(rl)
    local record = EventService.SetAttendance(rl.local_ctx(), event.eventId, "A-Realm", "late")
    local created = EventService.AddAssignment(rl.local_ctx(), event.eventId, {
      encounter = "Ragnaros",
      characterKey = "A-Realm",
      note = "n",
    })
    EventService.RemoveAssignment(rl.local_ctx(), event.eventId, created.assignmentId)

    local payloads = {
      EVENT_UPSERT = EventSync.EventPayload(event),
      ATTENDANCE_UPSERT = EventSync.AttendancePayload(event.eventId, "A-Realm", record),
      ASSIGN_UPSERT = EventSync.AssignPayload(event.eventId, created),
      DELETE = EventSync.DeleteAssignmentPayload(rl.tombstones, event.eventId, created.assignmentId),
    }
    for messageType, payload in pairs(payloads) do
      assert.is_truthy(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")), messageType)
    end
  end)

  it("have no delete payload without a tombstone", function()
    assert.is_nil(EventSync.DeleteEventPayload({}, "ev-1"))
    assert.is_nil(EventSync.DeleteAssignmentPayload({}, "ev-1", "as-1"))
  end)
end)

describe("EventSync rosters", function()
  -- A receiver that holds an event of roster r1, and knows which roster each sender is in.
  local function setup(rosterOfSender)
    local author, receiver = client("Leader-Realm"), client("Receiver-Realm")
    receiver.rosterOf = function(sender)
      return rosterOfSender[sender]
    end
    local event = new_event(author)
    assert.are.equal("r1", event.rosterId)
    assert.is_true(deliver(receiver, "EVENT_UPSERT", EventSync.EventPayload(event), "Boss-Realm", "gm"))
    return author, receiver, event
  end

  it("carries the roster of an event on the wire and stores it", function()
    local _, receiver, event = setup({})
    assert.are.equal("r1", receiver.events[event.eventId].rosterId)
    assert.are.equal("r1", EventSync.EventPayload(event).rosterId)
  end)

  it("accepts a raid leader's change to an event of their own roster", function()
    local author, receiver, event = setup({ ["Leader-Realm"] = "r1" })
    local edited = EventService.Update(author.local_ctx(), event.eventId, { title = "Renamed" })
    assert.is_true(deliver(receiver, "EVENT_UPSERT", EventSync.EventPayload(edited), "Leader-Realm", "rl"))
    assert.are.equal("Renamed", receiver.events[event.eventId].title)
  end)

  it("refuses a raid leader of another roster, and one with no roster, on every kind of change", function()
    for _, roster in ipairs({ "r2", false }) do
      local author, receiver, event = setup({ ["Other-Realm"] = roster or nil })
      local edited = EventService.Update(author.local_ctx(), event.eventId, { title = "Hijacked" })
      local payload = EventSync.EventPayload(edited)
      assert.are.equal("other_roster", select(2, deliver(receiver, "EVENT_UPSERT", payload, "Other-Realm", "rl")))
      assert.are.equal("Molten Core", receiver.events[event.eventId].title)

      local attendance =
        { eventId = event.eventId, characterKey = "Ann-Realm", state = "present", rev = 1, updatedAt = 1 }
      assert.are.equal(
        "other_roster",
        select(2, deliver(receiver, "ATTENDANCE_UPSERT", attendance, "Other-Realm", "rl"))
      )
      local assign = { eventId = event.eventId, assignmentId = "a1", encounter = "Rag", characterKey = "Ann-Realm" }
      assign.rev, assign.updatedAt = 1, 1
      assert.are.equal("other_roster", select(2, deliver(receiver, "ASSIGN_UPSERT", assign, "Other-Realm", "rl")))
      local delete = { kind = "event", eventId = event.eventId, rev = 99 }
      assert.are.equal("other_roster", select(2, deliver(receiver, "DELETE", delete, "Other-Realm", "rl")))
      assert.is_truthy(receiver.events[event.eventId])
    end
  end)

  it("lets the guild master change any roster's event", function()
    local author, receiver, event = setup({})
    local edited = EventService.Update(author.local_ctx(), event.eventId, { title = "By the boss" })
    assert.is_true(deliver(receiver, "EVENT_UPSERT", EventSync.EventPayload(edited), "Boss-Realm", "gm"))
    local delete = { kind = "event", eventId = event.eventId, rev = 99 }
    assert.is_true(deliver(receiver, "DELETE", delete, "Boss-Realm", "gm"))
    assert.is_nil(receiver.events[event.eventId])
  end)

  it("needs the new event of a raid leader to say it is of their roster", function()
    local receiver = client("Receiver-Realm")
    receiver.rosterOf = function()
      return "r1"
    end
    local payload = { eventId = "new-1", rev = 1, updatedAt = 1, title = "No roster" }
    assert.are.equal("other_roster", select(2, deliver(receiver, "EVENT_UPSERT", payload, "Leader-Realm", "rl")))
    payload.rosterId = "r2"
    assert.are.equal("other_roster", select(2, deliver(receiver, "EVENT_UPSERT", payload, "Leader-Realm", "rl")))
    payload.rosterId = "r1"
    assert.is_true(deliver(receiver, "EVENT_UPSERT", payload, "Leader-Realm", "rl"))
    assert.are.equal("r1", receiver.events["new-1"].rosterId)
    -- The guild master may create one with no roster at all.
    local free = { eventId = "free-1", rev = 1, updatedAt = 1, title = "Open" }
    assert.is_true(deliver(receiver, "EVENT_UPSERT", free, "Boss-Realm", "gm"))
    assert.is_nil(receiver.events["free-1"].rosterId)
  end)

  it("does not let a raid leader move an event to another roster", function()
    local author, receiver, event = setup({ ["Leader-Realm"] = "r1" })
    local payload = EventSync.EventPayload(EventService.Update(author.local_ctx(), event.eventId, { title = "Moved" }))
    payload.rosterId = "r2"
    assert.are.equal("other_roster", select(2, deliver(receiver, "EVENT_UPSERT", payload, "Leader-Realm", "rl")))
    assert.are.equal("r1", receiver.events[event.eventId].rosterId)
  end)

  it("keeps the roster when an older client edits the event and leaves it out", function()
    local author, receiver, event = setup({ ["Leader-Realm"] = "r1" })
    local payload = EventSync.EventPayload(EventService.Update(author.local_ctx(), event.eventId, { title = "Old" }))
    payload.rosterId = nil
    assert.is_true(deliver(receiver, "EVENT_UPSERT", payload, "Leader-Realm", "rl"))
    assert.are.equal("r1", receiver.events[event.eventId].rosterId)
    assert.are.equal("Old", receiver.events[event.eventId].title)
  end)

  it("lets the guild master move an event to another roster", function()
    local author, receiver, event = setup({})
    local payload = EventSync.EventPayload(EventService.Update(author.local_ctx(), event.eventId, { title = "Moved" }))
    payload.rosterId = "r2"
    assert.is_true(deliver(receiver, "EVENT_UPSERT", payload, "Boss-Realm", "gm"))
    assert.are.equal("r2", receiver.events[event.eventId].rosterId)
  end)

  it("keeps an event no roster owns open to a raid leader who has one", function()
    local receiver = client("Receiver-Realm")
    receiver.rosterOf = function(sender)
      return sender == "Leader-Realm" and "r1" or nil
    end
    receiver.events["legacy"] =
      { eventId = "legacy", title = "Old", rev = 1, updatedAt = 1, attendance = {}, assignments = {}, loot = {} }
    local attendance = { eventId = "legacy", characterKey = "Ann-Realm", state = "present", rev = 1, updatedAt = 1 }
    assert.is_true(deliver(receiver, "ATTENDANCE_UPSERT", attendance, "Leader-Realm", "rl"))
    assert.are.equal(
      "other_roster",
      select(2, deliver(receiver, "ATTENDANCE_UPSERT", attendance, "Nobody-Realm", "rl"))
    )
  end)

  it("reads the roster of the sender from the assignments and rosters it holds", function()
    local receiver = client("Receiver-Realm")
    local ctx = receiver.apply_ctx()
    ctx.rosterOf = nil
    ctx.members =
      { ["Leader-Realm"] = { role = "rl", rosterId = "r1" }, ["Gone-Realm"] = { role = "rl", rosterId = "r9" } }
    ctx.rosters = { r1 = { id = "r1", name = "Main" } }
    local payload = { eventId = "new-1", rev = 1, updatedAt = 1, title = "Raid", rosterId = "r1" }
    assert.is_true(EventSync.Apply(ctx, on_wire("EVENT_UPSERT", payload), "Leader-Realm", "rl"))
    -- A roster that was deleted counts as no roster.
    payload.eventId, payload.rosterId = "new-2", "r9"
    assert.are.equal(
      "other_roster",
      select(2, EventSync.Apply(ctx, on_wire("EVENT_UPSERT", payload), "Gone-Realm", "rl"))
    )
  end)
end)
