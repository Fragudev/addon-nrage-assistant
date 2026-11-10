-- Real vendored libraries and real domain; nothing is faked here.
local function load_modules()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RankMapModel",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/AnnouncementModel",
    "Domain/AnnouncementService",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/IntelModel",
    "Domain/GuildKosService",
    "Domain/ReadinessRules",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
    "Sync/PvPSync",
    "Sync/BlacklistSync",
    "Sync/GuildKosSync",
    "Sync/ReadinessRulesSync",
    "Sync/RosterSync",
    "Sync/RecipeSync",
    "Sync/RankMapSync",
    "Sync/AnnouncementSync",
    "Sync/Transfer",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Transfer, EventService, Constants = ns.Transfer, ns.EventService, ns.Constants
local libs = { serialize = _G.LibStub("NrageAssistant-LibSerialize"), deflate = _G.LibStub("LibDeflate") }

local function store()
  local s = { events = {}, tombstones = {}, clock = 10000, counter = 0 }
  function s.ctx(role)
    return {
      events = s.events,
      tombstones = s.tombstones,
      role = role or "rl",
      actor = "Leader-Realm",
      rosterId = "r1",
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
  -- An import is applied under the importer's own role and roster (here roster r1).
  local ctx = {
    events = target.events,
    tombstones = target.tombstones,
    now = target.ctx().now,
    rosterOf = function()
      return "r1"
    end,
  }
  return Transfer.Import(libs, text, ctx, role)
end

describe("Transfer export and import", function()
  it("moves a full event, with attendance, assignments and deletions, to another store", function()
    local source, event, dead = populated()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))
    assert.are.equal("NRAGE1:", text:sub(1, 7))

    local target = store()
    -- The deletion of an event this store never saw is only the guild master's to remember.
    local summary = assert(import_into(target, text, "gm"))
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
    assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "gm"))
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
        { t = "EVENT_UPSERT", p = { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 10, title = "Good" } },
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
        {
          t = "EVENT_UPSERT",
          p = { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 4000000000, title = "Future" },
        },
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
        { t = "EVENT_UPSERT", p = { eventId = "new", rosterId = "r1", rev = 1, updatedAt = 10, title = "One more" } },
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
    local ctx = {
      events = target.events,
      tombstones = target.tombstones,
      now = target.ctx().now,
      rosterOf = function()
        return "r1"
      end,
    }
    local items = {
      { t = "EVENT_UPSERT", p = { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 10, title = "Shared" } },
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

describe("Transfer.ApplyItems with a failing item", function()
  it("skips an item that raises, counts it, keeps the error and carries on with the rest", function()
    local s = populated()
    local good = Transfer.BuildItems(s.events, s.tombstones)
    local items = {
      setmetatable({ t = "EVENT_UPSERT" }, {
        __index = function()
          error("boom")
        end,
      }),
    }
    for _, item in ipairs(good) do
      items[#items + 1] = item
    end
    local target = store()
    local summary = Transfer.ApplyItems(
      items,
      { events = target.events, tombstones = target.tombstones, now = target.ctx().now },
      "Lead-Realm",
      "gm"
    )
    assert.are.equal(1, summary.skipped.error)
    assert.is_truthy(summary.firstError:find("boom", 1, true))
    assert.is_true(summary.applied > 0)
    assert.is_truthy(next(target.events))
  end)
end)

describe("Transfer sign-ups in a snapshot", function()
  local source, event

  before_each(function()
    source = store()
    event = assert(EventService.Create(source.ctx("rl"), { title = "Raid", startAt = 50000, rosterId = "r1" }))
    event.signups["Fan-Realm"] = { status = "yes", rev = 2, updatedAt = 20, updatedBy = "Fan-Realm" }
  end)

  local function receiver(roleOf)
    local target = store()
    local ctx = target.ctx()
    ctx.rosterOf = function()
      return "r1"
    end
    ctx.roleOf = roleOf
    return target, ctx
  end

  it("carries the sign-ups and applies them under the rank of the character", function()
    local items = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
    local target, ctx = receiver(function()
      return "roster"
    end)
    local summary = Transfer.ApplyItems(items, ctx, "Leader-Realm", "rl")
    assert.are.equal(#items, summary.applied)
    local record = target.events[event.eventId].signups["Fan-Realm"]
    assert.are.equal("yes", record.status)
    assert.are.equal(2, record.rev)
  end)

  it("skips a sign-up of a character that is a member, or unknown", function()
    local items = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
    local target, ctx = receiver(function()
      return "member"
    end)
    local summary = Transfer.ApplyItems(items, ctx, "Leader-Realm", "rl")
    assert.are.equal(1, summary.skipped.forbidden)
    assert.is_nil(next(target.events[event.eventId].signups))
    local _, unknown = receiver(function() end)
    assert.are.equal(1, Transfer.ApplyItems(items, unknown, "Leader-Realm", "rl").skipped.unknown_sender)
  end)

  it("does not relay a sign-up from a sender who is not a leader", function()
    local items = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
    local target, ctx = receiver(function()
      return "roster"
    end)
    -- The event itself is already known here, so only the sign-up is at stake.
    target.events[event.eventId] = { eventId = event.eventId, rosterId = "r1", signups = {}, attendance = {} }
    local summary = Transfer.ApplyItems(items, ctx, "Fan-Realm", "roster")
    assert.is_truthy(summary.skipped.forbidden)
    assert.is_nil(next(target.events[event.eventId].signups))
  end)

  it("skips them in a text import, where the importer is not the character", function()
    local items = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
    local _, ctx = receiver(nil)
    assert.are.equal(1, Transfer.ApplyItems(items, ctx, "import", "rl").skipped.unknown_sender)
  end)
end)

describe("Transfer with loot sessions", function()
  local LootService = ns.LootService
  local ITEM = { itemId = 19019, itemName = "Thunderfury" }

  -- One event with an awarded session (with a candidate and a vote) and an open one.
  local function with_loot()
    local source = store()
    local event = assert(EventService.Create(source.ctx("rl"), { title = "Molten Core" }))
    local admin = source.ctx("gm")
    local awarded = assert(LootService.OpenSession(admin, event.eventId, ITEM))
    local ann = source.ctx("roster")
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
    local summary = assert(import_into(target, text, "gm"))
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
    assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "gm"))
    local imported = target.events[event.eventId].loot[awarded.sessionId]
    assert.are.same({}, imported.candidates)
    assert.are.same({}, imported.votes)
  end)

  it("lets a raid leader import the events, the awards and the sessions: loot_manage is theirs too", function()
    local source, event, awarded = with_loot()
    local target = store()
    local summary = assert(import_into(target, assert(Transfer.Export(libs, source.events, source.tombstones)), "rl"))
    assert.is_nil(summary.skipped.forbidden)
    assert.is_truthy(target.events[event.eventId])
    assert.is_truthy(target.events[event.eventId].loot[awarded.sessionId].award)
  end)

  it("refuses an import from a roster player, a member and an alter", function()
    local source = with_loot()
    local text = assert(Transfer.Export(libs, source.events, source.tombstones))
    for _, role in ipairs({ "roster", "member", "alter" }) do
      local result, reason = import_into(store(), text, role)
      assert.is_nil(result, role)
      assert.are.equal("forbidden", reason, role)
    end
  end)

  describe("the awarder of a relayed award", function()
    local function award_item(source)
      local snapshot = Transfer.BuildSnapshot(source.events, source.tombstones, 5)
      for _, item in ipairs(snapshot) do
        if item.t == "LOOT_AWARD" then
          return item, snapshot
        end
      end
    end

    local function receiver(roleOf)
      local target = store()
      return target,
        {
          events = target.events,
          tombstones = target.tombstones,
          now = target.ctx().now,
          roleOf = roleOf,
          rosterOf = function()
            return "r1"
          end,
        }
    end

    it("travels with the item of the snapshot and is kept when the receiver knows them as a loot manager", function()
      local source, event, awarded = with_loot()
      local item, snapshot = award_item(source)
      assert.are.equal("Leader-Realm", item.awardedBy)
      local target, ctx = receiver(function(name)
        return name == "Leader-Realm" and "rl" or "gm"
      end)
      Transfer.ApplyItems(snapshot, ctx, "Boss-Realm", "gm")
      assert.are.equal("Leader-Realm", target.events[event.eventId].loot[awarded.sessionId].award.awardedBy)
    end)

    it(
      "falls back to the sender for an older snapshot, an unknown awarder or a member who cannot manage loot",
      function()
        local source, event, awarded = with_loot()
        local item, snapshot = award_item(source)
        local function awarder_with(roleOf, edit)
          local target, ctx = receiver(roleOf)
          local copy = {}
          for index, entry in ipairs(snapshot) do
            copy[index] = entry == item and { t = entry.t, p = entry.p, awardedBy = edit(entry.awardedBy) } or entry
          end
          Transfer.ApplyItems(copy, ctx, "Boss-Realm", "gm")
          return target.events[event.eventId].loot[awarded.sessionId].award.awardedBy
        end
        local function manager()
          return "gm"
        end
        local function keep(by)
          return by
        end
        assert.are.equal(
          "Boss-Realm",
          awarder_with(manager, function()
            return nil
          end)
        )
        assert.are.equal(
          "Boss-Realm",
          awarder_with(manager, function()
            return "|cffff0000Nobody"
          end)
        )
        assert.are.equal(
          "Boss-Realm",
          awarder_with(function(name)
            return name == "Leader-Realm" and "member" or "gm"
          end, keep)
        )
        assert.are.equal(
          "Boss-Realm",
          awarder_with(function(name)
            if name ~= "Leader-Realm" then
              return "gm"
            end
          end, keep)
        )
        -- No guild roster (a text import): the item cannot be checked, so the importer stays the awarder.
        assert.are.equal("Boss-Realm", awarder_with(nil, keep))
      end
    )
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

describe("Transfer PvP items in a snapshot", function()
  local function record(world)
    return {
      rev = 2,
      updatedAt = 9000,
      honor = { world = world, bg = 5 },
      blows = { world = 3, bg = 1 },
      today = { day = "2026-10-01", honor = { world = 2, bg = 1 }, blows = { world = 1, bg = 0 } },
      receivedAt = 9001,
    }
  end

  local function pvp_context(overrides)
    local ctx = {
      events = {},
      tombstones = {},
      pvpStats = {},
      pvpResets = {},
      -- The guild roster of the receiver: every owner of a relayed record has to be somebody it knows.
      roleOf = function()
        return "member"
      end,
      now = function()
        return 10000
      end,
    }
    for k, v in pairs(overrides or {}) do
      ctx[k] = v
    end
    return ctx
  end

  local function source_context()
    return pvp_context({
      pvpStats = { ["Ann-Realm"] = record(10), ["Bob-Realm"] = record(20) },
      pvpResets = { ["Cid-Realm"] = { rev = 4 } },
    })
  end

  it("adds the PvP records with their owners and the resets after the raid items", function()
    local s = populated()
    local items = Transfer.BuildSnapshot(s.events, s.tombstones, 5, source_context(), 10)
    local raid = #Transfer.BuildItems(s.events, s.tombstones)
    assert.are.equal(raid + 3, #items)
    local owners, resets = {}, {}
    for index = raid + 1, #items do
      local item = items[index]
      if item.t == "PVP_STATS" then
        owners[item.owner] = item.p.honor.world
        assert.is_nil(item.p.owner)
        assert.is_nil(item.p.receivedAt)
      else
        resets[item.p.target] = item.p.rev
      end
    end
    assert.are.same({ ["Ann-Realm"] = 10, ["Bob-Realm"] = 20 }, owners)
    assert.are.same({ ["Cid-Realm"] = 4 }, resets)
  end)

  it("adds nothing without a PvP part or with a cap of zero", function()
    local s = populated()
    local plain = Transfer.BuildItems(s.events, s.tombstones)
    assert.are.equal(#plain, #Transfer.BuildSnapshot(s.events, s.tombstones, 5))
    assert.are.equal(#plain, #Transfer.BuildSnapshot(s.events, s.tombstones, 5, source_context(), 0))
  end)

  it("caps the records at the most recently updated ones", function()
    local ctx = pvp_context()
    for index = 1, 30 do
      local r = record(10)
      r.updatedAt = 1000 + index
      ctx.pvpStats["M" .. index .. "-Realm"] = r
    end
    local items = Transfer.BuildSnapshot({}, {}, 5, ctx, 4)
    assert.are.equal(4, #items)
    assert.are.equal("M30-Realm", items[1].owner)
    assert.are.equal("M27-Realm", items[4].owner)
  end)

  it("applies each record to its owner and the resets under the role of the snapshot's sender", function()
    local items = Transfer.BuildSnapshot({}, {}, 5, source_context(), 10)
    local ctx = pvp_context()
    local summary = Transfer.ApplyItems(items, ctx, "Lead-Realm", "gm")
    assert.are.equal(3, summary.applied)
    assert.are.equal(3, summary.pvp)
    assert.are.equal(10, ctx.pvpStats["Ann-Realm"].honor.world)
    assert.are.equal(20, ctx.pvpStats["Bob-Realm"].honor.world)
    assert.is_nil(ctx.pvpStats["Lead-Realm"])
    assert.are.equal(4, ctx.pvpResets["Cid-Realm"].rev)

    -- A raid leader's snapshot still brings the records, but cannot reset anybody.
    local other = pvp_context()
    summary = Transfer.ApplyItems(items, other, "Lead-Realm", "rl")
    assert.are.equal(2, summary.applied)
    assert.are.equal(1, summary.skipped.forbidden)
    assert.is_nil(other.pvpResets["Cid-Realm"])
  end)

  it("skips an item whose owner is missing or not a valid name", function()
    local ctx = pvp_context()
    local good = Transfer.BuildSnapshot({}, {}, 5, source_context(), 10)[2]
    local items = {
      { t = "PVP_STATS", p = good.p },
      { t = "PVP_STATS", p = good.p, owner = "" },
      { t = "PVP_STATS", p = good.p, owner = ("n"):rep(65) },
      { t = "PVP_STATS", p = good.p, owner = "|cffff0000Ann" },
      { t = "PVP_STATS", p = good.p, owner = 5 },
      { t = "PVP_STATS", p = { rev = 1 }, owner = "Ann-Realm" },
    }
    local summary = Transfer.ApplyItems(items, ctx, "Lead-Realm", "rl")
    assert.are.equal(0, summary.applied)
    assert.are.equal(5, summary.skipped.bad_owner)
    assert.are.equal(1, summary.skipped.bad_payload)
    assert.is_nil(next(ctx.pvpStats))
  end)

  it("skips a record whose owner the guild roster does not know, or cannot be checked", function()
    local items = Transfer.BuildSnapshot({}, {}, 5, source_context(), 10)
    local ctx = pvp_context({
      roleOf = function(name)
        return name == "Ann-Realm" and "member" or nil
      end,
    })
    local summary = Transfer.ApplyItems(items, ctx, "Lead-Realm", "rl")
    assert.are.equal(1, summary.skipped.unknown_owner)
    assert.is_truthy(ctx.pvpStats["Ann-Realm"])
    assert.is_nil(ctx.pvpStats["Bob-Realm"])

    local blind = pvp_context({ roleOf = false })
    summary = Transfer.ApplyItems(items, blind, "Lead-Realm", "rl")
    assert.are.equal(2, summary.skipped.unknown_owner)
    assert.is_nil(next(blind.pvpStats))
  end)

  it("limits how far a relay can raise the revision of a member", function()
    local function item(rev)
      local r = record(30)
      r.rev = rev
      return { t = "PVP_STATS", p = r, owner = "Ann-Realm" }
    end
    local ctx = pvp_context()
    ctx.pvpStats["Ann-Realm"] = record(10)
    ctx.pvpStats["Ann-Realm"].rev = 50
    local summary =
      Transfer.ApplyItems({ item(50 + ns.Constants.PVP_SNAPSHOT_REV_JUMP_MAX + 1) }, ctx, "Lead-Realm", "rl")
    assert.are.equal(1, summary.skipped.implausible)
    assert.are.equal(50, ctx.pvpStats["Ann-Realm"].rev)
    summary = Transfer.ApplyItems({ item(50 + ns.Constants.PVP_SNAPSHOT_REV_JUMP_MAX) }, ctx, "Lead-Realm", "rl")
    assert.are.equal(1, summary.applied)

    -- A member not held yet: no huge revision either, which would make their own messages stale for good.
    local fresh = pvp_context()
    summary = Transfer.ApplyItems({ item(ns.Constants.PVP_SNAPSHOT_REV_NEW_MAX + 1) }, fresh, "Lead-Realm", "rl")
    assert.are.equal(1, summary.skipped.implausible)
    assert.is_nil(fresh.pvpStats["Ann-Realm"])
    summary = Transfer.ApplyItems({ item(ns.Constants.PVP_SNAPSHOT_REV_NEW_MAX) }, fresh, "Lead-Realm", "rl")
    assert.are.equal(1, summary.applied)
  end)

  it("does not apply PvP items to a context without PvP tables, such as a text import", function()
    local items = Transfer.BuildSnapshot({}, {}, 5, source_context(), 10)
    local ctx = pvp_context()
    ctx.pvpStats, ctx.pvpResets = nil, nil
    local summary = Transfer.ApplyItems(items, ctx, "import", "gm")
    assert.are.equal(0, summary.applied)
    assert.are.equal(3, summary.skipped.unsupported)
  end)

  it("keeps PvP out of the text export", function()
    local s = populated()
    local plain = Transfer.BuildItems(s.events, s.tombstones)
    for _, item in ipairs(plain) do
      assert.is_false(item.t == "PVP_STATS" or item.t == "PVP_RESET")
      assert.is_nil(item.owner)
    end
    local text = assert(Transfer.Export(libs, s.events, s.tombstones))
    local decoded = assert(Transfer.Decode(libs, text))
    assert.are.equal(#plain, #decoded)
  end)
end)

describe("Transfer blacklist items in a snapshot", function()
  local function entry(name, overrides)
    local e = {
      name = name,
      reason = "ninja",
      addedBy = "Ann-Realm",
      addedAt = 500,
      rev = 1,
      updatedAt = 9000,
      updatedBy = "Ann-Realm",
    }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end

  local function context(overrides)
    local ctx = {
      events = {},
      tombstones = {},
      blacklist = {},
      now = function()
        return 10000
      end,
    }
    for k, v in pairs(overrides or {}) do
      ctx[k] = v
    end
    return ctx
  end

  local function source()
    return context({
      blacklist = { yonemongg = entry("Yonemon Gg"), ann = entry("Ann", { addedBy = "Bob-Realm", updatedAt = 9500 }) },
      tombstones = { ["B:gone"] = { at = 10, rev = 4 }, ["E:event"] = { at = 10, rev = 2 } },
    })
  end

  it("adds the entries with their author and the removals after the raid items", function()
    local s = source()
    local items = Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, s.blacklist, 10)
    local types = {}
    for _, item in ipairs(items) do
      types[#types + 1] = item.t
    end
    assert.are.same({ "DELETE", "BLACKLIST_UPSERT", "BLACKLIST_UPSERT", "BLACKLIST_DELETE" }, types)
    assert.are.equal("ann", items[2].p.key)
    assert.are.equal("Bob-Realm", items[2].addedBy)
    assert.are.equal(500, items[2].addedAt)
    assert.are.same({ key = "gone", rev = 4 }, items[4].p)
  end)

  it("adds nothing without a blacklist or with a cap of zero", function()
    local s = source()
    local plain = Transfer.BuildSnapshot({}, s.tombstones, 5)
    assert.are.equal(#plain, #Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, s.blacklist, 0))
    assert.are.equal(#plain, #Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, nil, 10))
  end)

  it("caps the entries and the removals separately", function()
    local ctx = context()
    for index = 1, 5 do
      ctx.blacklist["p" .. index] = entry("P" .. index, { updatedAt = 100 + index })
      ctx.tombstones["B:t" .. index] = { at = index, rev = 1 }
    end
    local items = Transfer.BuildSnapshot({}, ctx.tombstones, 5, nil, nil, ctx.blacklist, 2)
    assert.are.equal(4, #items)
  end)

  it("applies the entries as the sender with the author kept, and the removals under the sender's role", function()
    local s = source()
    local items = Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, s.blacklist, 10)

    local target = context()
    local summary = Transfer.ApplyItems(items, target, "Lead-Realm", "rl")
    assert.are.equal(2, summary.blacklist)
    -- The two entries. The removal of an event this store never saw is only the guild master's to remember.
    assert.are.equal(2, summary.applied)
    assert.are.equal(1, summary.skipped.unknown_event)
    assert.are.equal("Bob-Realm", target.blacklist.ann.addedBy)
    assert.are.equal(500, target.blacklist.ann.addedAt)
    assert.are.equal("Lead-Realm", target.blacklist.ann.updatedBy)
    -- A removal only counts from an admin.
    assert.are.equal(1, summary.skipped.forbidden)
    assert.is_nil(target.tombstones["B:gone"])

    local admin = context()
    summary = Transfer.ApplyItems(items, admin, "Boss-Realm", "gm")
    assert.are.equal(3, summary.blacklist)
    assert.are.equal(4, admin.tombstones["B:gone"].rev)
  end)

  it("applies the same result whatever the order of the items", function()
    local s = source()
    s.tombstones["B:ann"] = { at = 20, rev = 2 }
    local items = Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, s.blacklist, 10)
    local reversed = {}
    for index = #items, 1, -1 do
      reversed[#reversed + 1] = items[index]
    end
    local a, b = context(), context()
    Transfer.ApplyItems(items, a, "Boss-Realm", "gm")
    Transfer.ApplyItems(reversed, b, "Boss-Realm", "gm")
    assert.are.same(a.blacklist, b.blacklist)
  end)

  it("skips an item whose author or date is unusable, or that does not validate", function()
    local ctx = context()
    local good = { t = "BLACKLIST_UPSERT", p = { key = "ann", name = "Ann", reason = "x", rev = 1, updatedAt = 10 } }
    local function with(overrides)
      local item = { t = good.t, p = good.p, addedBy = "Ann-Realm", addedAt = 5 }
      for k, v in pairs(overrides) do
        item[k] = v
      end
      return item
    end
    local summary = Transfer.ApplyItems({
      with({ addedBy = "|cffff0000Evil" }),
      with({ addedAt = "yesterday" }),
      with({ addedBy = false }),
      with({ p = { key = "ann", name = "Ann", reason = "", rev = 1, updatedAt = 10 } }),
    }, ctx, "Lead-Realm", "rl")
    assert.are.equal(0, summary.applied)
    assert.are.equal(3, summary.skipped.bad_origin)
    assert.are.equal(1, summary.skipped.bad_payload)
    assert.is_nil(next(ctx.blacklist))
  end)

  it("takes an item without an author as sent by the relay", function()
    local ctx = context()
    local item = { t = "BLACKLIST_UPSERT", p = { key = "ann", name = "Ann", reason = "x", rev = 1, updatedAt = 10 } }
    assert.are.equal(1, Transfer.ApplyItems({ item }, ctx, "Lead-Realm", "rl").applied)
    assert.are.equal("Lead-Realm", ctx.blacklist.ann.addedBy)
  end)

  it("does not apply blacklist items to a context without a blacklist, such as a text import", function()
    local s = source()
    local items = Transfer.BuildSnapshot({}, {}, 5, nil, nil, s.blacklist, 10)
    local ctx = context()
    ctx.blacklist = nil
    local summary = Transfer.ApplyItems(items, ctx, "import", "gm")
    assert.are.equal(0, summary.applied)
    assert.are.equal(2, summary.skipped.unsupported)
  end)

  it("keeps the blacklist out of the text export", function()
    local s = source()
    local plain = Transfer.BuildItems({}, s.tombstones)
    for _, item in ipairs(plain) do
      assert.is_false(item.t == "BLACKLIST_UPSERT" or item.t == "BLACKLIST_DELETE")
    end
  end)
end)

describe("Transfer guild Kill On Sight items in a snapshot", function()
  local function entry(name, overrides)
    local e = {
      name = name,
      category = "gank",
      reason = "ninja",
      addedBy = "Ann-Realm",
      addedAt = 500,
      rev = 1,
      updatedAt = 9000,
      updatedBy = "Ann-Realm",
    }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end

  local function context(overrides)
    local ctx = {
      events = {},
      tombstones = {},
      guildKos = {},
      now = function()
        return 10000
      end,
    }
    for k, v in pairs(overrides or {}) do
      ctx[k] = v
    end
    return ctx
  end

  local function source()
    return context({
      guildKos = { bob = entry("Bob"), eve = entry("Eve", { addedBy = "Cid-Realm", updatedAt = 9500 }) },
      tombstones = { ["K:gone"] = { at = 10, rev = 4 }, ["B:other"] = { at = 10, rev = 2 } },
    })
  end

  local function build(s, max)
    return Transfer.BuildSnapshot({}, s.tombstones, 5, nil, nil, nil, nil, nil, nil, nil, nil, s.guildKos, max)
  end

  it("adds the entries with their author and the removals", function()
    local s = source()
    local items = build(s, 10)
    local types = {}
    for _, item in ipairs(items) do
      types[#types + 1] = item.t
    end
    assert.are.same({ "KOS_UPSERT", "KOS_UPSERT", "KOS_DELETE" }, types)
    assert.are.equal("eve", items[1].p.key)
    assert.are.equal("Cid-Realm", items[1].addedBy)
    assert.are.same({ key = "gone", rev = 4 }, items[3].p)
  end)

  it("adds nothing without the table or with a cap of zero", function()
    local s = source()
    assert.are.equal(0, #build(s, 0))
    assert.are.equal(0, #build({ tombstones = s.tombstones }, 10))
  end)

  it("applies the entries as the sender with the author kept, and the removals under the sender's role", function()
    local items = build(source(), 10)
    local target = context()
    local summary = Transfer.ApplyItems(items, target, "Lead-Realm", "rl")
    assert.are.equal(2, summary.guildKos)
    assert.are.equal("Cid-Realm", target.guildKos.eve.addedBy)
    assert.are.equal("Lead-Realm", target.guildKos.eve.updatedBy)
    assert.are.equal(1, summary.skipped.forbidden)
    assert.is_nil(target.tombstones["K:gone"])

    local admin = context()
    summary = Transfer.ApplyItems(items, admin, "Boss-Realm", "gm")
    assert.are.equal(3, summary.guildKos)
    assert.are.equal(4, admin.tombstones["K:gone"].rev)
  end)

  it("skips an item that does not validate or whose author is unusable", function()
    local ctx = context()
    local good = { key = "ann", name = "Ann", category = "gank", rev = 1, updatedAt = 10 }
    local summary = Transfer.ApplyItems({
      { t = "KOS_UPSERT", p = good, addedBy = "|cffff0000Evil", addedAt = 5 },
      { t = "KOS_UPSERT", p = { key = "ann", name = "Ann", category = "nope", rev = 1, updatedAt = 10 } },
    }, ctx, "Lead-Realm", "rl")
    assert.are.equal(0, summary.applied)
    assert.are.equal(1, summary.skipped.bad_origin)
    assert.are.equal(1, summary.skipped.bad_payload)
  end)

  it("does not apply them to a context without the table, such as a text import", function()
    local items = build(source(), 10)
    local ctx = context()
    ctx.guildKos = nil
    local summary = Transfer.ApplyItems(items, ctx, "import", "gm")
    assert.are.equal(0, summary.applied)
    assert.are.equal(3, summary.skipped.unsupported)
  end)

  it("keeps the list out of the text export", function()
    for _, item in ipairs(Transfer.BuildItems({}, source().tombstones)) do
      assert.is_false(item.t == "KOS_UPSERT" or item.t == "KOS_DELETE")
    end
  end)
end)
