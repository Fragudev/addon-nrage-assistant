-- Real vendored libraries and real domain; nothing is faked here.
local function load_modules()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Domain/PermissionService", "Domain/EventModel",
    "Domain/EventService", "Sync/Protocol", "Sync/EventSync", "Sync/Transfer",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Transfer, EventService, Constants = ns.Transfer, ns.EventService, ns.Constants
local libs = { serialize = _G.LibStub("LibSerialize"), deflate = _G.LibStub("LibDeflate") }

local function store()
  local s = { events = {}, tombstones = {}, clock = 10000, counter = 0 }
  function s.ctx(role)
    return {
      events = s.events, tombstones = s.tombstones, role = role or "rl", actor = "Leader-Realm",
      now = function() return s.clock end,
      newId = function()
        s.counter = s.counter + 1
        return "id" .. s.counter
      end,
    }
  end
  return s
end

-- A store with one full event, one assignment that was removed, and one deleted event.
local function populated()
  local s = store()
  local ctx = s.ctx()
  local event = assert(EventService.Create(ctx, { title = "Molten Core", instance = "MC", startAt = 5000 }))
  assert(EventService.SetAttendance(ctx, event.eventId, "Ann-Realm", "present"))
  assert(EventService.SetAttendance(ctx, event.eventId, "Bob-Realm", "late"))
  assert(EventService.AddAssignment(ctx, event.eventId, {
    encounter = "Ragnaros", characterKey = "Ann-Realm", group = 1, task = "Main tank",
  }))
  local gone = assert(EventService.AddAssignment(ctx, event.eventId, {
    encounter = "Garr", characterKey = "Bob-Realm",
  }))
  assert(EventService.RemoveAssignment(ctx, event.eventId, gone.assignmentId))
  local dead = assert(EventService.Create(ctx, { title = "Cancelled raid" }))
  assert(EventService.Delete(ctx, dead.eventId))
  return s, event, dead
end

local function import_into(target, text, role)
  local ctx = { events = target.events, tombstones = target.tombstones, now = target.ctx().now }
  return Transfer.Import(libs, text, ctx, role)
end

describe("Transfer export and import", function()
  it("moves a full event, with attendance, assignments and deletions, to another store", function()
    local source, event, dead = populated()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))
    assert.are.equal("NRAGE1:", text:sub(1, 7))

    local target = store()
    local summary = assert(import_into(target, text, "rl"))
    assert.are.equal(0, next(summary.skipped) and 1 or 0)
    assert.are.equal(summary.total, summary.applied)

    local copy = target.events[event.eventId]
    assert.are.equal("Molten Core", copy.title)
    assert.are.equal("MC", copy.instance)
    assert.are.equal(5000, copy.startAt)
    assert.are.equal("present", copy.attendance["Ann-Realm"].state)
    assert.are.equal("late", copy.attendance["Bob-Realm"].state)

    local assignments = 0
    for _, assignment in pairs(copy.assignments) do
      assignments = assignments + 1
      assert.are.equal("Main tank", assignment.task)
    end
    assert.are.equal(1, assignments)
    assert.is_nil(target.events[dead.eventId])
    assert.is_truthy(target.tombstones["E:" .. dead.eventId])
  end)

  it("marks imported records as received, authored by the import", function()
    local source, event = populated()
    local target = store()
    assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "admin"))
    assert.are.equal("received", target.events[event.eventId].source)
    assert.are.equal("import", target.events[event.eventId].updatedBy)
  end)

  it("removes a local event that the exporter had deleted", function()
    local source, _, dead = populated()
    local target = store()
    target.events[dead.eventId] = { eventId = dead.eventId, title = "Old", status = "planned", rev = 1,
      updatedAt = 1, attendance = {}, assignments = {} }
    assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "rl"))
    assert.is_nil(target.events[dead.eventId])
  end)

  it("is idempotent: importing twice changes nothing", function()
    local source, event = populated()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))
    local target = store()
    assert(import_into(target, text, "rl"))
    local title = target.events[event.eventId].title
    local second = assert(import_into(target, text, "rl"))
    assert.are.equal(title, target.events[event.eventId].title)
    assert.is_truthy(second.skipped.stale)
  end)

  it("does not overwrite newer local edits", function()
    local source, event = populated()
    local target = store()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))
    assert(import_into(target, text, "rl"))
    target.events[event.eventId].title = "Edited here"
    target.events[event.eventId].rev = 50
    assert(import_into(target, text, "rl"))
    assert.are.equal("Edited here", target.events[event.eventId].title)
  end)

  it("exports an empty store as valid text that imports as nothing", function()
    local text = assert(Transfer.Export(libs, {}, {}))
    local summary = assert(import_into(store(), text, "rl"))
    assert.are.equal(0, summary.total)
  end)
end)

describe("Transfer permissions and hostile input", function()
  local function encode(value)
    local serialized = libs.serialize:Serialize(value)
    return "NRAGE1:" .. libs.deflate:EncodeForPrint(libs.deflate:CompressDeflate(serialized))
  end

  it("refuses members and unknown roles before reading anything", function()
    local text = assert(Transfer.Export(libs, {}, {}))
    for _, role in ipairs({ "member" }) do
      local summary, reason = import_into(store(), text, role)
      assert.is_nil(summary)
      assert.are.equal("forbidden", reason)
    end
    local summary, reason = import_into(store(), text, nil)
    assert.is_nil(summary)
    assert.are.equal("forbidden", reason)
  end)

  it("rejects text that is not an export", function()
    for input, expected in pairs({ ["hello"] = "bad_header", ["NRAGE2:abc"] = "bad_header" }) do
      local summary, reason = import_into(store(), input, "rl")
      assert.is_nil(summary)
      assert.are.equal(expected, reason)
    end
    assert.are.equal("not_string", select(2, import_into(store(), nil, "rl")))
  end)

  it("rejects a valid header followed by garbage without raising", function()
    for _, tail in ipairs({ "", "!!!!", ("A"):rep(200), "\0\1\2" }) do
      local summary, reason = import_into(store(), "NRAGE1:" .. tail, "rl")
      assert.is_nil(summary)
      assert.is_string(reason)
    end
  end)

  it("rejects content that is not the expected structure", function()
    assert.are.equal("bad_payload", select(2, import_into(store(), encode("just text"), "rl")))
    assert.are.equal("bad_payload", select(2, import_into(store(), encode({ items = "no" }), "rl")))
    assert.are.equal("bad_payload", select(2, import_into(store(), encode({ other = {} }), "rl")))
  end)

  it("rejects oversized text, oversized expansion and too many items", function()
    local huge = "NRAGE1:" .. ("A"):rep(Constants.IMPORT_MAX_ENCODED_BYTES)
    assert.are.equal("too_large", select(2, import_into(store(), huge, "rl")))

    local blob = encode({ items = {}, padding = ("x"):rep(Constants.IMPORT_MAX_DECOMPRESSED_BYTES + 1) })
    assert.is_true(#blob <= Constants.IMPORT_MAX_ENCODED_BYTES)
    assert.are.equal("too_large", select(2, import_into(store(), blob, "rl")))

    local items = {}
    for i = 1, Constants.IMPORT_MAX_ITEMS + 1 do items[i] = { t = "HELLO", p = {} } end
    local many = encode({ items = items })
    assert.is_true(#many <= Constants.IMPORT_MAX_ENCODED_BYTES)
    assert.are.equal("too_large", select(2, import_into(store(), many, "rl")))
  end)

  it("skips items that are unsupported or invalid and still applies the good ones", function()
    local text = encode({ items = {
      { t = "EVENT_UPSERT", p = { eventId = "ev-1", rev = 1, updatedAt = 10, title = "Good" } },
      { t = "PROFILE", p = { rev = 1, class = "MAGE", level = 60 } },
      { t = "EVENT_UPSERT", p = { eventId = "bad id", rev = 1, updatedAt = 10, title = "Bad" } },
      { t = "EVENT_UPSERT", p = { eventId = "ev-2", rev = 1, updatedAt = 10, title = "|cffff0000Red" } },
      "not a table",
      { t = 5, p = {} },
      { t = "ATTENDANCE_UPSERT", p = { eventId = "ghost", characterKey = "A-Realm", state = "present",
        rev = 1, updatedAt = 10 } },
    } })
    local target = store()
    local summary = assert(import_into(target, text, "rl"))
    assert.are.equal(7, summary.total)
    assert.are.equal(1, summary.applied)
    assert.are.equal(3, summary.skipped.unsupported)
    assert.are.equal(2, summary.skipped.bad_payload)
    assert.are.equal(1, summary.skipped.unknown_event)
    assert.are.equal("Good", target.events["ev-1"].title)
    assert.is_nil(target.events["ev-2"])
  end)

  it("clamps timestamps dated in the future", function()
    local text = encode({ items = {
      { t = "EVENT_UPSERT", p = { eventId = "ev-1", rev = 1, updatedAt = 4000000000, title = "Future" } },
    } })
    local target = store()
    assert(import_into(target, text, "rl"))
    assert.are.equal(target.clock + 300, target.events["ev-1"].updatedAt)
  end)

  it("respects the event limit", function()
    local target = store()
    for i = 1, Constants.EVENT_MAX do target.events["e" .. i] = { rev = 1, updatedAt = 1 } end
    local text = encode({ items = {
      { t = "EVENT_UPSERT", p = { eventId = "new", rev = 1, updatedAt = 10, title = "One more" } },
    } })
    local summary = assert(import_into(target, text, "rl"))
    assert.are.equal(1, summary.skipped.limit)
    assert.is_nil(target.events["new"])
  end)
end)

describe("Transfer.Describe", function()
  it("summarises applied and skipped records", function()
    local text = Transfer.Describe({ total = 5, applied = 3, skipped = { stale = 1, limit = 1 } })
    assert.are.equal("imported 3 of 5 record(s) (skipped - limit: 1, stale: 1)", text)
  end)

  it("stays short when nothing was skipped", function()
    assert.are.equal("imported 2 of 2 record(s)", Transfer.Describe({ total = 2, applied = 2, skipped = {} }))
  end)
end)
