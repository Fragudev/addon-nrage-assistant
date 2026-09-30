-- Real vendored libraries and real domain; nothing is faked here.
local function load_modules()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
    "Sync/Transfer",
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
      events = s.events,
      tombstones = s.tombstones,
      role = role or "rl",
      actor = "Leader-Realm",
      now = function()
        return s.clock
      end,
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
    encounter = "Ragnaros",
    characterKey = "Ann-Realm",
    group = 1,
    task = "Main tank",
  }))
  local gone = assert(EventService.AddAssignment(ctx, event.eventId, {
    encounter = "Garr",
    characterKey = "Bob-Realm",
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
    target.events[dead.eventId] = {
      eventId = dead.eventId,
      title = "Old",
      status = "planned",
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = {},
    }
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
    for i = 1, Constants.IMPORT_MAX_ITEMS + 1 do
      items[i] = { t = "HELLO", p = {} }
    end
    local many = encode({ items = items })
    assert.is_true(#many <= Constants.IMPORT_MAX_ENCODED_BYTES)
    assert.are.equal("too_large", select(2, import_into(store(), many, "rl")))
  end)

  it("skips items that are unsupported or invalid and still applies the good ones", function()
    local text = encode({
      items = {
        { t = "EVENT_UPSERT", p = { eventId = "ev-1", rev = 1, updatedAt = 10, title = "Good" } },
        { t = "PROFILE", p = { rev = 1, class = "MAGE", level = 60 } },
        { t = "EVENT_UPSERT", p = { eventId = "bad id", rev = 1, updatedAt = 10, title = "Bad" } },
        { t = "EVENT_UPSERT", p = { eventId = "ev-2", rev = 1, updatedAt = 10, title = "|cffff0000Red" } },
        "not a table",
        { t = 5, p = {} },
        {
          t = "ATTENDANCE_UPSERT",
          p = { eventId = "ghost", characterKey = "A-Realm", state = "present", rev = 1, updatedAt = 10 },
        },
      },
    })
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
    local text = encode({
      items = {
        { t = "EVENT_UPSERT", p = { eventId = "ev-1", rev = 1, updatedAt = 4000000000, title = "Future" } },
      },
    })
    local target = store()
    assert(import_into(target, text, "rl"))
    assert.are.equal(target.clock + 300, target.events["ev-1"].updatedAt)
  end)

  it("respects the event limit", function()
    local target = store()
    for i = 1, Constants.EVENT_MAX do
      target.events["e" .. i] = { rev = 1, updatedAt = 1 }
    end
    local text = encode({
      items = {
        { t = "EVENT_UPSERT", p = { eventId = "new", rev = 1, updatedAt = 10, title = "One more" } },
      },
    })
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

describe("Transfer.BuildSnapshot and ApplyItems", function()
  local function event_at(startAt, id)
    return {
      eventId = id,
      title = "E" .. id,
      status = "planned",
      startAt = startAt,
      rev = 1,
      updatedAt = 10,
      attendance = {},
      assignments = {},
    }
  end

  it("takes the most recent events, each with its records, and every tombstone", function()
    local events = { a = event_at(100, "a"), b = event_at(300, "b"), c = event_at(200, "c") }
    events.b.attendance["Ann-Realm"] = { state = "present", rev = 1, updatedAt = 10 }
    local tombstones = { ["E:gone"] = { at = 1, rev = 2 } }

    local items = Transfer.BuildSnapshot(events, tombstones, 2)
    local seen = {}
    for _, item in ipairs(items) do
      seen[#seen + 1] = item.t .. ":" .. (item.p.eventId or "")
    end
    table.sort(seen)
    assert.are.same({
      "ATTENDANCE_UPSERT:b",
      "DELETE:gone",
      "EVENT_UPSERT:b",
      "EVENT_UPSERT:c",
    }, seen)
  end)

  it("falls back to the last edit for undated events and is stable on ties", function()
    local first, second = event_at(nil, "x"), event_at(nil, "y")
    first.updatedAt, second.updatedAt = 50, 90
    local items = Transfer.BuildSnapshot({ x = first, y = second }, {}, 1)
    assert.are.equal(1, #items)
    assert.are.equal("y", items[1].p.eventId)
  end)

  it("applies items as the given sender, under the given role", function()
    local target = store()
    local ctx = { events = target.events, tombstones = target.tombstones, now = target.ctx().now }
    local items = {
      { t = "EVENT_UPSERT", p = { eventId = "ev-1", rev = 1, updatedAt = 10, title = "Shared" } },
    }
    local summary = Transfer.ApplyItems(items, ctx, "Lead-Realm", "rl")
    assert.are.equal(1, summary.applied)
    assert.are.equal("Lead-Realm", target.events["ev-1"].updatedBy)

    local denied = Transfer.ApplyItems(
      { { t = "EVENT_UPSERT", p = { eventId = "ev-2", rev = 1, updatedAt = 10, title = "Nope" } } },
      ctx,
      "Raider-Realm",
      "member"
    )
    assert.are.equal(0, denied.applied)
    assert.are.equal(1, denied.skipped.forbidden)
    assert.is_nil(target.events["ev-2"])
  end)
end)

describe("Transfer with loot sessions", function()
  local LootService = ns.LootService
  local ITEM = { itemId = 19019, itemName = "Thunderfury" }

  -- One event with an awarded session (with a candidate and a vote) and an open one.
  local function with_loot()
    local source = store()
    local event = assert(EventService.Create(source.ctx("rl"), { title = "Molten Core" }))
    local admin = source.ctx("admin")
    local awarded = assert(LootService.OpenSession(admin, event.eventId, ITEM))
    local ann = source.ctx("member")
    ann.actor = "Ann-Realm"
    assert(LootService.Register(ann, event.eventId, awarded.sessionId, { spec = "Fury", need = "main" }))
    assert(LootService.Vote(admin, event.eventId, awarded.sessionId, "Ann-Realm"))
    assert(LootService.Award(admin, event.eventId, awarded.sessionId, "Ann-Realm", "Highest need"))
    local open = assert(LootService.OpenSession(admin, event.eventId, { itemId = 2, itemName = "Other" }))
    return source, event, awarded, open
  end

  it("exports awards and open sessions, and an admin imports them", function()
    local source, event, awarded, open = with_loot()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))

    local target = store()
    local summary = assert(import_into(target, text, "admin"))
    assert.are.equal(summary.total, summary.applied)

    local loot = target.events[event.eventId].loot
    assert.are.equal("closed", loot[awarded.sessionId].status)
    assert.are.equal("Ann-Realm", loot[awarded.sessionId].award.characterKey)
    assert.are.equal("Highest need", loot[awarded.sessionId].award.reason)
    assert.are.equal("Thunderfury", loot[awarded.sessionId].itemName)
    assert.are.equal("open", loot[open.sessionId].status)
  end)

  it("leaves candidates and votes out, because they cannot be re-attributed", function()
    local source, event, awarded = with_loot()
    local target = store()
    assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "admin"))
    local imported = target.events[event.eventId].loot[awarded.sessionId]
    assert.are.same({}, imported.candidates)
    assert.are.same({}, imported.votes)
  end)

  it("lets a raid leader import the events but skips the loot they may not touch", function()
    local source, event = with_loot()
    local target = store()
    local summary = assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "rl"))
    assert.are.equal(2, summary.skipped.forbidden)
    assert.is_truthy(target.events[event.eventId])
    assert.is_nil(next(target.events[event.eventId].loot))
  end)

  it("puts an event's loot in its snapshot", function()
    local source = with_loot()
    local snapshot = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
    local types = {}
    for _, item in ipairs(snapshot) do
      types[item.t] = (types[item.t] or 0) + 1
    end
    assert.are.equal(1, types.EVENT_UPSERT)
    assert.are.equal(1, types.LOOT_AWARD)
    assert.are.equal(1, types.LOOT_SESSION)
  end)
end)
