local function load_protocol()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PermissionService.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/EventModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/BlacklistService.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/ReadinessRules.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/LootModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/PvPSeasonModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/LfgModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/RankMapModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/AnnouncementModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/Protocol.lua"))("NrageAssistant", ns)
  return ns.Protocol, ns.Constants
end

local Protocol, Constants = load_protocol()

local function profile(overrides)
  local p = {
    rev = 3,
    class = "WARRIOR",
    level = 60,
    ilvl = 200,
    professions = { { name = "Mining", skill = 300, max = 300 } },
    fields = { role = "tank" },
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

local function message(payload, overrides)
  local m = Protocol.Build("PROFILE", payload or profile(), "abc-123")
  for k, v in pairs(overrides or {}) do
    m[k] = v
  end
  return m
end

describe("Protocol.Build", function()
  it("stamps the current protocol version", function()
    local m = Protocol.Build("HELLO", { version = "0.1.0" }, "id-1")
    assert.are.equal(Constants.PROTOCOL_MAJOR, m.v)
    assert.are.equal(Constants.PROTOCOL_MINOR, m.m)
    assert.are.equal("HELLO", m.t)
  end)
end)

describe("Protocol.Validate envelope", function()
  it("accepts a well-formed HELLO", function()
    local clean = Protocol.Validate(Protocol.Build("HELLO", { version = "0.1.0" }, "id-1"))
    assert.are.equal("HELLO", clean.t)
    assert.are.equal("0.1.0", clean.p.version)
  end)

  it("rejects non-tables", function()
    for _, value in ipairs({ "text", 5, true }) do
      local clean, reason = Protocol.Validate(value)
      assert.is_nil(clean)
      assert.are.equal("not_table", reason)
    end
  end)

  it("rejects a bad version and explains an incompatible major", function()
    local _, reason = Protocol.Validate(message(nil, { v = "1" }))
    assert.are.equal("bad_version", reason)
    _, reason = Protocol.Validate(message(nil, { v = Constants.PROTOCOL_MAJOR + 1 }))
    assert.are.equal("incompatible_version", reason)
  end)

  it("accepts a newer minor version", function()
    assert.is_truthy(Protocol.Validate(message(nil, { m = Constants.PROTOCOL_MINOR + 5 })))
  end)

  it("rejects unknown types", function()
    local _, reason = Protocol.Validate(message(nil, { t = "LOOT_TRADE" }))
    assert.are.equal("unknown_type", reason)
    _, reason = Protocol.Validate(message(nil, { t = {} }))
    assert.are.equal("unknown_type", reason)
  end)

  it("rejects bad ids", function()
    for _, id in ipairs({ "", ("x"):rep(41), "has space", "pipe|id", "colon:id", 7 }) do
      local _, reason = Protocol.Validate(message(nil, { id = id }))
      assert.are.equal("bad_id", reason)
    end
  end)

  it("rejects a missing payload", function()
    local _, reason = Protocol.Validate(message(nil, { p = "nope" }))
    assert.are.equal("bad_payload", reason)
  end)
end)

describe("Protocol.Validate HELLO", function()
  it("rejects a missing or hostile version string", function()
    for _, version in ipairs({ "", ("v"):rep(33), "|cffff0000red", "line\nbreak", 1 }) do
      local _, reason = Protocol.Validate(Protocol.Build("HELLO", { version = version }, "id-1"))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate PROFILE", function()
  it("keeps every valid field", function()
    local clean = Protocol.Validate(message())
    assert.are.equal(3, clean.p.rev)
    assert.are.equal("WARRIOR", clean.p.class)
    assert.are.equal(60, clean.p.level)
    assert.are.equal(200, clean.p.ilvl)
    assert.are.same({ { name = "Mining", skill = 300, max = 300 } }, clean.p.professions)
    assert.are.same({ role = "tank" }, clean.p.fields)
  end)

  it("accepts a minimal profile", function()
    local clean = Protocol.Validate(message({ rev = 0, class = "MAGE", level = 1 }))
    assert.is_truthy(clean)
    assert.is_nil(clean.p.ilvl)
    assert.is_nil(clean.p.professions)
    assert.is_nil(clean.p.fields)
  end)

  it("drops unknown fields, including nested ones", function()
    local payload = profile({ guid = "Player-1", secret = "x" })
    payload.fields.evil = "y"
    payload.professions[1].extra = "z"
    local clean = Protocol.Validate(message(payload))
    assert.is_nil(clean.p.guid)
    assert.is_nil(clean.p.secret)
    assert.is_nil(clean.p.fields.evil)
    assert.is_nil(clean.p.professions[1].extra)
  end)

  it("rejects values outside their domain", function()
    local bad = {
      { rev = -1 },
      { rev = 1.5 },
      { rev = "3" },
      { class = "warrior" },
      { class = "" },
      { class = "WAR|RIOR" },
      { level = 0 },
      { level = 1000 },
      { level = "60" },
      { ilvl = -1 },
      { ilvl = 2001 },
      { professions = "mining" },
      { professions = { { name = "", skill = 1 } } },
      { professions = { { name = "Mining", skill = 1001 } } },
      { professions = { { name = "Mining", skill = 1, max = -1 } } },
      { fields = "role" },
      { fields = { role = "|cffff0000red" } },
      { fields = { notes = ("n"):rep(Constants.MAX_FIELD_LENGTH + 1) } },
    }
    for _, overrides in ipairs(bad) do
      local clean, reason = Protocol.Validate(message(profile(overrides)))
      assert.is_nil(clean)
      assert.are.equal("bad_payload", reason)
    end
  end)

  it("rejects too many professions", function()
    local list = {}
    for i = 1, 9 do
      list[i] = { name = "P" .. i, skill = 1 }
    end
    local _, reason = Protocol.Validate(message(profile({ professions = list })))
    assert.are.equal("bad_payload", reason)
  end)
end)

local function raid_message(messageType, payload)
  return Protocol.Build(messageType, payload, "id-raid")
end

local function event_payload(overrides)
  local p = { eventId = "ev-1", rev = 2, updatedAt = 1000, title = "Molten Core", instance = "MC", startAt = 5000 }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

describe("Protocol.Validate EVENT_UPSERT", function()
  it("keeps the valid fields and drops unknown ones", function()
    local clean = Protocol.Validate(raid_message("EVENT_UPSERT", event_payload({ status = "open", junk = "x" })))
    assert.are.same({
      eventId = "ev-1",
      rev = 2,
      updatedAt = 1000,
      title = "Molten Core",
      instance = "MC",
      startAt = 5000,
      status = "open",
    }, clean.p)
  end)

  it("accepts an event with only the required fields", function()
    local clean = Protocol.Validate(raid_message("EVENT_UPSERT", {
      eventId = "ev-1",
      rev = 1,
      updatedAt = 0,
      title = "Raid",
    }))
    assert.is_truthy(clean)
  end)

  it("rejects invalid ids, revisions, timestamps and fields", function()
    local bad = {
      { eventId = "has space" },
      { eventId = 7 },
      { eventId = "a|b" },
      { rev = 0 },
      { rev = 1.5 },
      { rev = "2" },
      { updatedAt = -1 },
      { updatedAt = 5000000000 },
      { title = "" },
      { title = "|cffff0000Red" },
      { title = ("t"):rep(61) },
      { status = "boom" },
      { startAt = -5 },
    }
    for _, overrides in ipairs(bad) do
      local clean, reason = Protocol.Validate(raid_message("EVENT_UPSERT", event_payload(overrides)))
      assert.is_nil(clean)
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate ATTENDANCE_UPSERT", function()
  local function payload(overrides)
    local p = { eventId = "ev-1", characterKey = "Nrager-Realm", state = "present", rev = 1, updatedAt = 10 }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  it("accepts a valid record and never carries the recorder", function()
    local clean = Protocol.Validate(raid_message("ATTENDANCE_UPSERT", payload({ recordedBy = "Fake-Realm" })))
    assert.are.equal("present", clean.p.state)
    assert.is_nil(clean.p.recordedBy)
  end)

  it("rejects an unknown state, a bad key and missing revision data", function()
    for _, overrides in ipairs({
      { state = "disconnected" },
      { state = 5 },
      { characterKey = "" },
      { characterKey = "A|B" },
      { rev = 0 },
      { updatedAt = "now" },
      { eventId = "no way" },
    }) do
      local _, reason = Protocol.Validate(raid_message("ATTENDANCE_UPSERT", payload(overrides)))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate ASSIGN_UPSERT", function()
  local function payload(overrides)
    local p = {
      eventId = "ev-1",
      assignmentId = "as-1",
      rev = 1,
      updatedAt = 10,
      encounter = "Ragnaros",
      characterKey = "Nrager-Realm",
      group = 2,
      task = "Main tank",
      note = "watch out",
    }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  it("keeps every valid field", function()
    local clean = Protocol.Validate(raid_message("ASSIGN_UPSERT", payload()))
    assert.are.same(payload(), clean.p)
  end)

  it("rejects values outside their domain", function()
    for _, overrides in ipairs({
      { assignmentId = "bad id" },
      { encounter = "" },
      { characterKey = "|x" },
      { group = 9 },
      { group = 0 },
      { task = ("t"):rep(61) },
      { note = ("n"):rep(101) },
      { rev = 0 },
    }) do
      local _, reason = Protocol.Validate(raid_message("ASSIGN_UPSERT", payload(overrides)))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate DELETE", function()
  it("accepts deleting an event", function()
    local clean = Protocol.Validate(raid_message("DELETE", { kind = "event", eventId = "ev-1", rev = 3 }))
    assert.are.same({ kind = "event", eventId = "ev-1", rev = 3 }, clean.p)
  end)

  it("requires an assignment id when deleting an assignment", function()
    local ok = Protocol.Validate(raid_message("DELETE", {
      kind = "assignment",
      eventId = "ev-1",
      assignmentId = "as-1",
      rev = 2,
    }))
    assert.are.equal("as-1", ok.p.assignmentId)

    local _, reason = Protocol.Validate(raid_message("DELETE", { kind = "assignment", eventId = "ev-1", rev = 2 }))
    assert.are.equal("bad_payload", reason)
  end)

  it("rejects unknown kinds and bad ids or revisions", function()
    for _, payload in ipairs({
      { kind = "guild", eventId = "ev-1", rev = 1 },
      { kind = "event", eventId = "no way", rev = 1 },
      { kind = "event", eventId = "ev-1", rev = 0 },
      { kind = 5, eventId = "ev-1", rev = 1 },
    }) do
      local _, reason = Protocol.Validate(raid_message("DELETE", payload))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate SYNC_REQ and SYNC_DATA", function()
  it("accepts an empty request and drops anything it carries", function()
    local clean = Protocol.Validate(raid_message("SYNC_REQ", { junk = "x" }))
    assert.are.same({}, clean.p)
  end)

  it("keeps the items of a snapshot without judging them", function()
    local items = { { t = "EVENT_UPSERT", p = {} }, "whatever" }
    local clean = Protocol.Validate(raid_message("SYNC_DATA", { items = items, junk = 1 }))
    assert.are.same({ items = items }, clean.p)
  end)

  it("rejects a snapshot without a list or with too many items", function()
    assert.are.equal("bad_payload", select(2, Protocol.Validate(raid_message("SYNC_DATA", { items = "no" }))))
    assert.are.equal("bad_payload", select(2, Protocol.Validate(raid_message("SYNC_DATA", {}))))
    local items = {}
    for i = 1, Constants.IMPORT_MAX_ITEMS + 1 do
      items[i] = { t = "DELETE", p = {} }
    end
    assert.are.equal("bad_payload", select(2, Protocol.Validate(raid_message("SYNC_DATA", { items = items }))))
  end)
end)

describe("Protocol.Validate loot messages", function()
  local function base(overrides)
    local p = { eventId = "ev-1", sessionId = "s-1", rev = 2, updatedAt = 100 }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  local function invalid(messageType, payload)
    local clean, reason = Protocol.Validate(raid_message(messageType, payload))
    assert.is_nil(clean)
    assert.are.equal("bad_payload", reason)
  end

  it("accepts a LOOT_SESSION and drops unknown fields", function()
    local clean = Protocol.Validate(raid_message(
      "LOOT_SESSION",
      base({
        itemId = 19019,
        itemName = "Thunderfury",
        status = "open",
        junk = "x",
      })
    ))
    assert.are.same({
      eventId = "ev-1",
      sessionId = "s-1",
      rev = 2,
      updatedAt = 100,
      itemId = 19019,
      itemName = "Thunderfury",
      status = "open",
    }, clean.p)
  end)

  it("rejects an invalid LOOT_SESSION", function()
    local good = { itemId = 1, itemName = "X", status = "open" }
    for _, overrides in ipairs({
      { eventId = "bad id" },
      { sessionId = "a:b" },
      { rev = 0 },
      { updatedAt = -1 },
      { itemId = 0 },
      { itemId = "1" },
      { itemName = "|cffff0000X" },
      { itemName = "" },
      { status = "won" },
      { status = 5 },
    }) do
      local payload = base(good)
      for k, v in pairs(overrides) do
        payload[k] = v
      end
      invalid("LOOT_SESSION", payload)
    end
  end)

  it("accepts a LOOT_AWARD, which carries the item, and never the awarder", function()
    local clean = Protocol.Validate(raid_message(
      "LOOT_AWARD",
      base({
        itemId = 1,
        itemName = "X",
        characterKey = "Ann-Realm",
        reason = "Highest need",
        awardedBy = "Fake-Realm",
      })
    ))
    assert.are.equal("Ann-Realm", clean.p.characterKey)
    assert.are.equal("Highest need", clean.p.reason)
    assert.is_nil(clean.p.awardedBy)
  end)

  it("rejects an invalid LOOT_AWARD", function()
    local good = { itemId = 1, itemName = "X", characterKey = "Ann-Realm", reason = "why" }
    for _, overrides in ipairs({
      { characterKey = "" },
      { characterKey = "A|B" },
      { reason = "" },
      { reason = "|cffff0000x" },
      { reason = ("r"):rep(101) },
      { itemId = 0 },
      { rev = 0 },
    }) do
      local payload = base(good)
      for k, v in pairs(overrides) do
        payload[k] = v
      end
      invalid("LOOT_AWARD", payload)
    end
  end)

  it("accepts a LOOT_CANDIDATE without a candidate key", function()
    local clean = Protocol.Validate(raid_message(
      "LOOT_CANDIDATE",
      base({
        spec = "Fury",
        need = "main",
        upgrade = "Better axe",
        candidate = "Fake-Realm",
      })
    ))
    assert.are.equal("Fury", clean.p.spec)
    assert.are.equal("main", clean.p.need)
    assert.are.equal("Better axe", clean.p.upgrade)
    assert.is_nil(clean.p.candidate)
  end)

  it("rejects an invalid LOOT_CANDIDATE", function()
    for _, overrides in ipairs({
      { spec = "" },
      { need = "greed" },
      { need = 5 },
      { upgrade = "|Hitem:1|h" },
    }) do
      local payload = base({ spec = "Fury", need = "main" })
      for k, v in pairs(overrides) do
        payload[k] = v
      end
      invalid("LOOT_CANDIDATE", payload)
    end
    invalid("LOOT_CANDIDATE", base({ need = "main" }))
  end)

  it("accepts a LOOT_VOTE without a voter and rejects a bad target", function()
    local clean = Protocol.Validate(raid_message("LOOT_VOTE", base({ target = "Ann-Realm", voter = "Fake-Realm" })))
    assert.are.equal("Ann-Realm", clean.p.target)
    assert.is_nil(clean.p.voter)
    invalid("LOOT_VOTE", base({ target = "" }))
    invalid("LOOT_VOTE", base({ target = "A|B" }))
    invalid("LOOT_VOTE", base({}))
  end)
end)

describe("Protocol.Validate PVP_STATS", function()
  local function stats(overrides)
    local p = {
      rev = 4,
      updatedAt = 1000,
      honor = { world = 10, bg = 5 },
      blows = { world = 3, bg = 1 },
      today = { day = "2026-10-01", honor = { world = 2, bg = 1 }, blows = { world = 1, bg = 0 } },
    }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  local function validate(payload)
    return Protocol.Validate(Protocol.Build("PVP_STATS", payload, "id-1"))
  end

  it("keeps the counters and the day", function()
    local clean = validate(stats())
    assert.are.same(stats(), clean.p)
  end)

  it("drops unknown fields, such as a name", function()
    local clean = validate(stats({ owner = "Victim", name = "Victim" }))
    assert.is_nil(clean.p.owner)
    assert.is_nil(clean.p.name)
  end)

  it("accepts a record without killing blows", function()
    local payload = stats({ today = { day = "2026-10-01", honor = { world = 2, bg = 1 } } })
    payload.blows = nil
    local clean = validate(payload)
    assert.is_nil(clean.p.blows)
    assert.is_nil(clean.p.today.blows)
  end)

  it("bounds every counter to whole numbers in 0..PVP_MAX_KILLS", function()
    local high = Constants.PVP_MAX_KILLS
    assert.is_truthy(validate(stats({ honor = { world = high, bg = 0 } })))
    for _, bad in ipairs({ -1, high + 1, 1.5, "7", math.huge, 0 / 0 }) do
      local _, reason = validate(stats({ honor = { world = bad, bg = 0 } }))
      assert.are.equal("bad_payload", reason, tostring(bad))
      _, reason = validate(stats({ blows = { world = 0, bg = bad } }))
      assert.are.equal("bad_payload", reason, tostring(bad))
      _, reason = validate(stats({ today = { day = "2026-10-01", honor = { world = bad, bg = 0 } } }))
      assert.are.equal("bad_payload", reason, tostring(bad))
      _, reason = validate(
        stats({ today = { day = "2026-10-01", honor = { world = 0, bg = 0 }, blows = { world = bad, bg = 0 } } })
      )
      assert.are.equal("bad_payload", reason, tostring(bad))
    end
  end)

  it("needs both counters of a pair and the pair to be a table", function()
    for _, bad in ipairs({ { world = 1 }, { bg = 1 }, "many", {} }) do
      local _, reason = validate(stats({ honor = bad }))
      assert.are.equal("bad_payload", reason)
    end
  end)

  it("rejects a bad day", function()
    for _, day in ipairs({ "2026-1-01", "20261001", "2026-13-01", "2026-10-00", "2026-10-32", "1999-10-01", "x", 5 }) do
      local _, reason = validate(stats({ today = { day = day, honor = { world = 0, bg = 0 } } }))
      assert.are.equal("bad_payload", reason, tostring(day))
    end
    local payload = stats()
    payload.today = nil
    local _, reason = validate(payload)
    assert.are.equal("bad_payload", reason)
  end)

  it("bounds the revision and the timestamp", function()
    for _, overrides in ipairs({
      { rev = 0 },
      { rev = 2147483648 },
      { rev = 1.5 },
      { updatedAt = -1 },
      { updatedAt = "now" },
    }) do
      local _, reason = validate(stats(overrides))
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate PVP_RESET", function()
  local function validate(payload)
    return Protocol.Validate(Protocol.Build("PVP_RESET", payload, "id-1"))
  end

  it("keeps the target and the revision", function()
    assert.are.same({ target = "Ann-Realm", rev = 7 }, validate({ target = "Ann-Realm", rev = 7, extra = 1 }).p)
  end)

  it("rejects a hostile or oversized target and a bad revision", function()
    for _, target in ipairs({ "", ("n"):rep(65), "|cffff0000Ann", "line\nbreak", 5 }) do
      local _, reason = validate({ target = target, rev = 1 })
      assert.are.equal("bad_payload", reason)
    end
    for _, rev in ipairs({ 0, -1, 2147483648, 1.5, "1" }) do
      local _, reason = validate({ target = "Ann", rev = rev })
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate PVP_KILL", function()
  local function kill(overrides)
    local payload = { victim = "Zed", where = "world", blow = true }
    for k, v in pairs(overrides or {}) do
      payload[k] = v
    end
    return payload
  end

  local function validate(payload)
    return Protocol.Validate(Protocol.Build("PVP_KILL", payload, "id-1"))
  end

  it("keeps the victim, the place and the blow", function()
    assert.are.same(kill(), validate(kill()).p)
    assert.are.same(kill({ where = "bg", blow = false }), validate(kill({ where = "bg", blow = false })).p)
  end)

  it("accepts multi-word names up to the limit and drops unknown fields such as a killer", function()
    assert.is_truthy(validate(kill({ victim = "Yonemon Gg" })))
    assert.is_truthy(validate(kill({ victim = ("x"):rep(Constants.PVP_FEED_VICTIM_MAX) })))
    local clean = validate(kill({ killer = "Someone", owner = "Someone" }))
    assert.is_nil(clean.p.killer)
    assert.is_nil(clean.p.owner)
  end)

  it("rejects a victim that is empty, too long, not text or carries escapes", function()
    for _, bad in ipairs({ "", ("x"):rep(Constants.PVP_FEED_VICTIM_MAX + 1), 5, true, "A|cffff0000B", "A\nB" }) do
      local _, reason = validate(kill({ victim = bad }))
      assert.are.equal("bad_payload", reason, tostring(bad))
    end
    local missing = kill()
    missing.victim = nil
    local _, reason = validate(missing)
    assert.are.equal("bad_payload", reason)
  end)

  it("rejects a place that is not world or bg", function()
    for _, bad in ipairs({ "arena", "World", "", 1, true }) do
      local _, reason = validate(kill({ where = bad }))
      assert.are.equal("bad_payload", reason, tostring(bad))
    end
    local missing = kill()
    missing.where = nil
    local _, reason = validate(missing)
    assert.are.equal("bad_payload", reason)
  end)

  it("rejects a blow that is not a boolean", function()
    for _, bad in ipairs({ "true", 1, 0, {} }) do
      local _, reason = validate(kill({ blow = bad }))
      assert.are.equal("bad_payload", reason, tostring(bad))
    end
    local missing = kill()
    missing.blow = nil
    local _, reason = validate(missing)
    assert.are.equal("bad_payload", reason)
  end)
end)

describe("Protocol.Validate BLACKLIST_UPSERT and BLACKLIST_DELETE", function()
  local function upsert(overrides)
    local payload = { key = "yonemongg", name = "Yonemon Gg", reason = "ninja", rev = 1, updatedAt = 1000 }
    for k, v in pairs(overrides or {}) do
      payload[k] = v
    end
    return payload
  end

  local function validate_upsert(payload)
    return Protocol.Validate(Protocol.Build("BLACKLIST_UPSERT", payload, "id-1"))
  end

  local function validate_delete(payload)
    return Protocol.Validate(Protocol.Build("BLACKLIST_DELETE", payload, "id-1"))
  end

  it("keeps the fields of an upsert and drops everything else, such as an author", function()
    assert.are.same(upsert(), validate_upsert(upsert()).p)
    local clean = validate_upsert(upsert({ addedBy = "Boss-Realm", updatedBy = "Boss-Realm", addedAt = 5, extra = 1 }))
    assert.are.same(upsert(), clean.p)
  end)

  it("accepts the limits of the name and the reason", function()
    local name = ("n"):rep(Constants.BLACKLIST_NAME_MAX)
    local reason = ("r"):rep(Constants.BLACKLIST_REASON_MAX)
    assert.is_truthy(validate_upsert(upsert({ key = name, name = name, reason = reason })))
  end)

  it("rejects a name or a key that is empty, too long, not text, or carries escapes or separators", function()
    local long = ("n"):rep(Constants.BLACKLIST_NAME_MAX + 1)
    for _, bad in ipairs({ "", long, 5, true, "A|cffff0000B", "A\nB", "A:B" }) do
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ name = bad }))), tostring(bad))
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ key = bad }))), tostring(bad))
      assert.are.equal("bad_payload", select(2, validate_delete({ key = bad, rev = 1 })), tostring(bad))
    end
  end)

  it("rejects a name that is not the one the blacklist would keep", function()
    for _, bad in ipairs({ " Ann", "Ann ", "A  nn", "Ann-Realm" }) do
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ name = bad }))), bad)
    end
  end)

  it("rejects a reason that is empty, too long, not text, or carries escapes", function()
    local long = ("r"):rep(Constants.BLACKLIST_REASON_MAX + 1)
    for _, bad in ipairs({ "", long, 5, false, "a|cffff0000b", "two\nlines", " padded " }) do
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ reason = bad }))), tostring(bad))
    end
  end)

  it("rejects a revision or a time out of range or not a whole number", function()
    for _, bad in ipairs({ 0, -1, 1.5, 2147483648, "1", true }) do
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ rev = bad }))), tostring(bad))
      assert.are.equal("bad_payload", select(2, validate_delete({ key = "ann", rev = bad })), tostring(bad))
    end
    for _, bad in ipairs({ -1, 4102444801, 1.5, "1" }) do
      assert.are.equal("bad_payload", select(2, validate_upsert(upsert({ updatedAt = bad }))), tostring(bad))
    end
  end)

  it("rejects a message with a missing field", function()
    for _, field in ipairs({ "key", "name", "reason", "rev", "updatedAt" }) do
      local payload = upsert()
      payload[field] = nil
      assert.are.equal("bad_payload", select(2, validate_upsert(payload)), field)
    end
    assert.are.equal("bad_payload", select(2, validate_delete({ key = "ann" })))
    assert.are.equal("bad_payload", select(2, validate_delete({ rev = 2 })))
  end)

  it("keeps the fields of a delete", function()
    assert.are.same({ key = "ann", rev = 2 }, validate_delete({ key = "ann", rev = 2, extra = true }).p)
  end)
end)

describe("Protocol.Validate LAYER_STATE", function()
  local function validate(payload)
    return Protocol.Validate(Protocol.Build("LAYER_STATE", payload, "ly-1"))
  end

  it("accepts a layer and drops unknown fields", function()
    local m = validate({ map = 1, layer = 4321, owner = "Someone" })
    assert.are.same({ map = 1, layer = 4321 }, m.p)
  end)

  it("accepts layer 0, which means forget me", function()
    assert.is_truthy(validate({ map = 0, layer = 0 }))
  end)

  it("carries the zone the layer was read in, and accepts a state without one from an older client", function()
    assert.are.same({ map = 1, layer = 4321, zone = 1429 }, validate({ map = 1, layer = 4321, zone = 1429 }).p)
    assert.are.same({ map = 1, layer = 4321 }, validate({ map = 1, layer = 4321 }).p)
    for _, zone in ipairs({ 0, -1, 100000, 1.5, "1429" }) do
      local _, reason = validate({ map = 1, layer = 4321, zone = zone })
      assert.are.equal("bad_payload", reason, tostring(zone))
    end
  end)

  it("rejects values out of range or not whole numbers", function()
    for _, bad in ipairs({
      { map = -1, layer = 5 },
      { map = 10000, layer = 5 },
      { map = 1, layer = -1 },
      { map = 1, layer = 2147483648 },
      { map = 1.5, layer = 5 },
      { map = 1, layer = "5" },
      { map = 1 },
      { layer = 5 },
    }) do
      local _, reason = validate(bad)
      assert.are.equal("bad_payload", reason)
    end
  end)
end)

describe("Protocol.Validate LAYER_SWAP (removed)", function()
  it("is an unknown type, so a message from an older client is dropped", function()
    local m, reason = Protocol.Validate(Protocol.Build("LAYER_SWAP", { rid = "a1", s = "offer" }, "sw-1"))
    assert.is_nil(m)
    assert.are.equal("unknown_type", reason)
  end)
end)

describe("Protocol.Validate LFG_POST", function()
  local function validate(payload)
    return Protocol.Validate(Protocol.Build("LFG_POST", payload, "lf-1"))
  end

  local function open(overrides)
    local payload = {
      pid = "p-1",
      rev = 1,
      s = "open",
      kind = "dungeon",
      title = "Deadmines",
      needs = { tank = 1, heal = 1, dps = 2 },
      members = 1,
    }
    for k, v in pairs(overrides or {}) do
      payload[k] = v
    end
    return payload
  end

  it("accepts an open post and drops unknown fields", function()
    local m = validate(open({ extra = 1, needs = { tank = 1, heal = 1, dps = 2, x = 9 } }))
    assert.are.same(open(), m.p)
  end)

  it("accepts the optional minimum level and note", function()
    local m = validate(open({ minLevel = 20, note = "bring water" }))
    assert.are.equal(20, m.p.minLevel)
    assert.are.equal("bring water", m.p.note)
  end)

  it("accepts a closed post with each outcome and keeps only its fields", function()
    for _, outcome in ipairs({ "full", "cancelled", "expired" }) do
      local m = validate({ pid = "p-1", rev = 4, s = "closed", o = outcome, title = "x", needs = {} })
      assert.are.same({ pid = "p-1", rev = 4, s = "closed", o = outcome }, m.p)
    end
  end)

  it("rejects a bad id, revision, state, kind or outcome", function()
    for _, bad in ipairs({
      open({ pid = "p:1" }),
      open({ pid = "" }),
      open({ rev = 0 }),
      open({ rev = 1.5 }),
      open({ rev = 2147483648 }),
      open({ s = "other" }),
      open({ kind = "raid" }),
      { pid = "p-1", rev = 1, s = "closed" },
      { pid = "p-1", rev = 1, s = "closed", o = "won" },
    }) do
      local _, reason = validate(bad)
      assert.are.equal("bad_payload", reason)
    end
  end)

  it("rejects a post that lacks its id, state or kind", function()
    for _, key in ipairs({ "pid", "rev", "s", "kind", "title", "needs", "members" }) do
      local payload = open()
      payload[key] = nil
      assert.are.equal("bad_payload", select(2, validate(payload)))
    end
  end)

  it("rejects text that is empty, oversized, or carries escapes or control characters", function()
    for _, bad in ipairs({ "", string.rep("a", 61), "|cffff0000Red|r", "line\nbreak", "tab\there", 5 }) do
      assert.are.equal("bad_payload", select(2, validate(open({ title = bad }))))
    end
    for _, bad in ipairs({ "", string.rep("a", 101), "a|Hitem|h", "a\1b", 5 }) do
      assert.are.equal("bad_payload", select(2, validate(open({ note = bad }))))
    end
    assert.is_truthy(validate(open({ title = string.rep("a", 60), note = string.rep("b", 100) })))
  end)

  it("rejects needs out of range, missing, or with no seat to fill", function()
    for _, bad in ipairs({
      { tank = 0, heal = 0, dps = 0 },
      { tank = 5, heal = 0, dps = 0 },
      { tank = -1, heal = 1, dps = 1 },
      { tank = 1, heal = 1 },
      { tank = "1", heal = 1, dps = 1 },
      "needs",
    }) do
      assert.are.equal("bad_payload", select(2, validate(open({ needs = bad }))))
    end
    assert.are.equal("bad_payload", select(2, validate(open({ needs = false }))))
  end)

  it("rejects members out of range or a party that would exceed five", function()
    for _, members in ipairs({ 0, 5, 1.5, "1" }) do
      assert.are.equal("bad_payload", select(2, validate(open({ members = members }))))
    end
    assert.are.equal("bad_payload", select(2, validate(open({ members = 2, needs = { tank = 1, heal = 1, dps = 2 } }))))
    assert.is_truthy(validate(open({ members = 2, needs = { tank = 1, heal = 1, dps = 1 } })))
  end)

  it("rejects a minimum level out of range", function()
    for _, level in ipairs({ 0, 101, 1.5, "20" }) do
      assert.are.equal("bad_payload", select(2, validate(open({ minLevel = level }))))
    end
  end)

  it("keeps the optional party, one seat per member, and drops what a seat should not carry", function()
    local m = validate(open({
      members = 2,
      needs = { tank = 1, heal = 1, dps = 1 },
      party = { { c = "WARRIOR", r = "tank", x = 1 }, { c = "PRIEST" } },
    }))
    assert.are.same({ { c = "WARRIOR", r = "tank" }, { c = "PRIEST" } }, m.p.party)
  end)

  it("drops a party that does not fit and keeps the post", function()
    local base = { members = 2, needs = { tank = 1, heal = 1, dps = 1 } }
    for _, party in ipairs({
      { { c = "WARRIOR" } },
      { { c = "WARRIOR" }, { c = "PRIEST" }, { c = "MAGE" } },
      { { c = "warrior" }, { c = "PRIEST" } },
      { { c = "WARRIOR|r" }, { c = "PRIEST" } },
      { { c = ("A"):rep(21) }, { c = "PRIEST" } },
      { { c = "WARRIOR", r = "healer" }, { c = "PRIEST" } },
      { { r = "tank" }, { c = "PRIEST" } },
      { "WARRIOR", "PRIEST" },
      "WARRIOR",
    }) do
      local fields = { party = party }
      for k, v in pairs(base) do
        fields[k] = v
      end
      local m = validate(open(fields))
      assert.is_truthy(m)
      assert.is_nil(m.p.party)
      assert.are.equal(2, m.p.members)
    end
  end)
end)

describe("Protocol.Validate LFG_APPLY", function()
  local function validate(payload)
    return Protocol.Validate(Protocol.Build("LFG_APPLY", payload, "la-1"))
  end

  it("accepts an apply with and without a note, and drops unknown fields", function()
    assert.are.same(
      { pid = "p-1", s = "apply", role = "tank", note = "hi" },
      validate({ pid = "p-1", s = "apply", role = "tank", note = "hi", to = "X", extra = 1 }).p
    )
    assert.are.same({ pid = "p-1", s = "apply", role = "dps" }, validate({ pid = "p-1", s = "apply", role = "dps" }).p)
  end)

  it("accepts a withdraw without anything else", function()
    assert.are.same(
      { pid = "p-1", s = "withdraw" },
      validate({ pid = "p-1", s = "withdraw", role = "tank", to = "X" }).p
    )
  end)

  it("accepts an accept and a decline that name a character, including a multi-word name", function()
    for _, step in ipairs({ "accept", "decline" }) do
      assert.are.same(
        { pid = "p-1", s = step, to = "Yonemon Gg" },
        validate({ pid = "p-1", s = step, to = "Yonemon Gg", role = "tank" }).p
      )
    end
  end)

  it("rejects a bad id, step or role", function()
    for _, bad in ipairs({
      { pid = "p:1", s = "withdraw" },
      { s = "withdraw" },
      { pid = "p-1" },
      { pid = "p-1", s = "invite" },
      { pid = "p-1", s = 3 },
      { pid = "p-1", s = "apply" },
      { pid = "p-1", s = "apply", role = "healer" },
      { pid = "p-1", s = "apply", role = 1 },
    }) do
      assert.are.equal("bad_payload", select(2, validate(bad)))
    end
  end)

  it("rejects a note or a target that is not plain text", function()
    for _, bad in ipairs({ "", string.rep("a", 101), "|cffff0000Red|r", "line\nbreak" }) do
      assert.are.equal("bad_payload", select(2, validate({ pid = "p-1", s = "apply", role = "tank", note = bad })))
    end
    for _, bad in ipairs({ "", string.rep("a", 200), "|cffff0000Red|r", "line\nbreak" }) do
      assert.are.equal("bad_payload", select(2, validate({ pid = "p-1", s = "accept", to = bad })))
    end
    assert.are.equal("bad_payload", select(2, validate({ pid = "p-1", s = "decline" })))
  end)
end)

describe("Protocol.Validate PvP season messages", function()
  local function validate(messageType, payload)
    return Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
  end

  local GOOD = {
    PVP_SEASON = {
      id = "s1",
      name = "Season One",
      startsAt = 100,
      endsAt = 200,
      state = "active",
      rev = 1,
      updatedAt = 5,
    },
    PVP_MISSION = {
      id = "m1",
      seasonId = "s1",
      title = "Hunt",
      desc = "Kill ten",
      points = 10,
      goal = { kind = "kills", count = 10, zones = { 1424 }, place = "world", distinct = "name" },
      repeatKind = "daily",
      perPlayer = 1,
      active = true,
      rev = 1,
      updatedAt = 5,
    },
    PVP_PRIZES = { seasonId = "s1", tiers = { ["1"] = { { kind = "gold", amount = 100 } } }, rev = 1, updatedAt = 5 },
    PVP_OFFICER = { player = "Ann", intervals = { { from = 5 } }, rev = 1, updatedAt = 5 },
    PVP_CLAIM = {
      id = "Ann:m1:all:1",
      missionId = "m1",
      seasonId = "s1",
      periodKey = "all",
      player = "Ann",
      at = 50,
      summary = { done = 1, total = 1 },
      evidence = { { at = 49, victim = "Grunt", place = "world", mapId = 1424 } },
    },
    PVP_REJECT = { claimId = "Ann:m1:all:1", seasonId = "s1", reason = "no", at = 60 },
    PVP_GRANT = { id = "Ann:m1:all:1", seasonId = "s1", player = "Ann", missionId = "m1", points = 10, at = 60 },
    PVP_VOID = { grantId = "Ann:m1:all:1", seasonId = "s1", reason = "abuse", at = 70 },
    PVP_DELIVERY = { seasonId = "s1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = 80 },
    PVP_FINAL = {
      seasonId = "s1",
      name = "Season One",
      startsAt = 100,
      endsAt = 200,
      closedAt = 210,
      standings = { { pos = 1, player = "Ann", points = 10, lastAt = 60 } },
      prizes = { ["1"] = { { kind = "gold", amount = 100 } } },
    },
  }

  it("accepts each record when it is clean", function()
    for messageType, payload in pairs(GOOD) do
      local accepted = validate(messageType, payload)
      assert.is_truthy(accepted, messageType)
      assert.are.equal(messageType, accepted.t)
    end
  end)

  it("drops unknown fields and never takes an author from the payload", function()
    for messageType, payload in pairs(GOOD) do
      local copy = {}
      for key, value in pairs(payload) do
        copy[key] = value
      end
      copy.by, copy.updatedBy, copy.closedBy, copy.extra = "Boss", "Boss", "Boss", 1
      local clean = assert(validate(messageType, copy), messageType)
      assert.is_nil(clean.p.by, messageType)
      assert.is_nil(clean.p.updatedBy, messageType)
      assert.is_nil(clean.p.closedBy, messageType)
      assert.is_nil(clean.p.extra, messageType)
    end
  end)

  it("refuses each record when a field is out of bounds", function()
    local bad = {
      PVP_SEASON = { endsAt = 50 },
      PVP_MISSION = { points = 0 },
      PVP_PRIZES = { tiers = "gold" },
      PVP_OFFICER = { player = "a:b" },
      PVP_CLAIM = { player = "Bob" },
      PVP_REJECT = { claimId = "plain" },
      PVP_GRANT = { points = 5000 },
      PVP_VOID = { grantId = "has space" },
      PVP_DELIVERY = { tier = "11-20" },
      PVP_FINAL = { standings = { { pos = 2, player = "Ann", points = 1, lastAt = 1 } } },
    }
    for messageType, change in pairs(bad) do
      local payload = {}
      for key, value in pairs(GOOD[messageType]) do
        payload[key] = value
      end
      for key, value in pairs(change) do
        payload[key] = value
      end
      local rejected, reason = validate(messageType, payload)
      assert.is_nil(rejected, messageType)
      assert.are.equal("bad_payload", reason)
    end
  end)

  it("accepts a ledger request with and without a season", function()
    local request = assert(validate("PVP_LEDGER_REQ", { seasonId = "s1", count = 12, digest = "0123abcd", x = 1 }))
    assert.are.same({ seasonId = "s1", count = 12, digest = "0123abcd" }, request.p)
    assert.are.same(
      { count = 0, digest = "00000001" },
      assert(validate("PVP_LEDGER_REQ", { count = 0, digest = "00000001" })).p
    )
  end)

  it("refuses a ledger request with a bad season, count or digest", function()
    for _, payload in ipairs({
      { seasonId = "a b", count = 1, digest = "0123abcd" },
      { count = -1, digest = "0123abcd" },
      { count = 1.5, digest = "0123abcd" },
      { count = 1000001, digest = "0123abcd" },
      { count = 1, digest = "0123abc" },
      { count = 1, digest = "0123abcg" },
      { count = 1, digest = 5 },
      { count = 1 },
    }) do
      assert.is_nil(validate("PVP_LEDGER_REQ", payload))
    end
  end)

  it("checks only the size of a ledger page: each item is validated when it is applied", function()
    local items = { { t = "PVP_GRANT", p = {}, by = "Boss" }, "anything" }
    local page = assert(validate("PVP_LEDGER_DATA", { seasonId = "s1", page = 2, pages = 3, items = items, x = 1 }))
    assert.are.equal(2, #page.p.items)
    assert.are.equal(2, page.p.page)
    assert.is_nil(page.p.x)
    assert.is_truthy(validate("PVP_LEDGER_DATA", { page = 1, pages = 1, items = {} }))
  end)

  it("refuses a ledger page out of range or too big", function()
    local tooMany = {}
    for index = 1, Constants.PVP_LEDGER_PAGE_ITEMS + 1 do
      tooMany[index] = {}
    end
    for _, payload in ipairs({
      { page = 0, pages = 1, items = {} },
      { page = 2, pages = 1, items = {} },
      { page = 1, pages = Constants.PVP_LEDGER_PAGES_MAX + 1, items = {} },
      { page = 1, pages = 1, items = "x" },
      { page = 1, pages = 1, items = tooMany },
      { seasonId = "a b", page = 1, pages = 1, items = {} },
    }) do
      assert.is_nil(validate("PVP_LEDGER_DATA", payload))
    end
  end)
end)

describe("Protocol ANN and ANN_DEL", function()
  local function validate(messageType, p)
    return Protocol.Validate(Protocol.Build(messageType, p, "id-1"))
  end

  local function payload(overrides)
    local p = {
      id = "a-1",
      title = "Raid night",
      body = "Bring flasks",
      createdAt = 9000,
      updatedAt = 9000,
      rev = 1,
      popup = true,
      popupRev = 1,
      pinned = false,
    }
    for key, value in pairs(overrides or {}) do
      p[key] = value
    end
    return p
  end

  it("accepts a whole announcement and drops unknown fields and the author", function()
    local clean = assert(validate("ANN", payload({ junk = 1, author = "Forged-Realm" })))
    assert.is_nil(clean.p.junk)
    assert.is_nil(clean.p.author)
    assert.are.equal("Raid night", clean.p.title)
  end)

  it("takes an announcement without a body", function()
    local p = payload()
    p.body = nil
    assert.are.equal("", assert(validate("ANN", p)).p.body)
  end)

  it("rejects what is out of bounds", function()
    for _, bad in ipairs({
      { title = "" },
      { title = ("x"):rep(61) },
      { body = ("x"):rep(601) },
      { body = "a|cffff0000b" },
      { id = "no spaces" },
      { rev = 0 },
      { rev = 2 ^ 40 },
      { popup = "yes" },
      { popupRev = 0 },
      { pinned = 1 },
      { createdAt = -5 },
      { expiresAt = "never" },
    }) do
      assert.is_nil(validate("ANN", payload(bad)), next(bad))
    end
  end)

  it("validates ANN_DEL strictly", function()
    assert.is_truthy(validate("ANN_DEL", { id = "a-1", rev = 2, updatedAt = 5 }))
    assert.is_nil(validate("ANN_DEL", { id = "a-1", rev = 0, updatedAt = 5 }))
    assert.is_nil(validate("ANN_DEL", { id = "a 1", rev = 2, updatedAt = 5 }))
    assert.is_nil(validate("ANN_DEL", { id = "a-1", rev = 2 }))
  end)

  it("accepts the longest title and body in two-byte characters", function()
    local worst = payload({ title = ("\195\177"):rep(60), body = ("\195\177"):rep(600), expiresAt = 10000 })
    assert.is_truthy(validate("ANN", worst))
  end)
end)

describe("Protocol RANK_MAP", function()
  local function rank_map(payload)
    return Protocol.Validate(Protocol.Build("RANK_MAP", payload, "rm-1"))
  end

  local function good()
    return {
      rev = 2,
      updatedAt = 1000,
      ranks = { { i = 1, r = "cogm", n = "Comandante" }, { i = 3, r = "rl", n = "Raid" } },
    }
  end

  it("accepts a map of rows and drops unknown fields", function()
    local payload = good()
    payload.extra = "x"
    payload.ranks[1].extra = "y"
    local m = rank_map(payload)
    assert.are.same(good(), m.p)
  end)

  it("accepts an empty map", function()
    assert.is_truthy(rank_map({ rev = 1, updatedAt = 0, ranks = {} }))
  end)

  it("refuses gm, index 0, index 10, duplicates, bad roles and bad names", function()
    local function with_row(row)
      local payload = good()
      payload.ranks[2] = row
      return rank_map(payload)
    end
    assert.is_nil(with_row({ i = 2, r = "gm", n = "X" }))
    assert.is_nil(with_row({ i = 0, r = "alter", n = "X" }))
    assert.is_nil(with_row({ i = 10, r = "alter", n = "X" }))
    assert.is_nil(with_row({ i = 1, r = "alter", n = "X" }))
    assert.is_nil(with_row({ i = 2, r = "owner", n = "X" }))
    assert.is_nil(with_row({ i = 2, r = "alter", n = "|cffff0000X" }))
    assert.is_nil(with_row({ i = 2, r = "alter", n = ("n"):rep(33) }))
    assert.is_nil(with_row({ i = 2, r = "alter" }))
  end)

  it("refuses a bad revision, time or row count", function()
    assert.is_nil(rank_map({ rev = 0, updatedAt = 1, ranks = {} }))
    assert.is_nil(rank_map({ rev = 1, updatedAt = -1, ranks = {} }))
    assert.is_nil(rank_map({ rev = 1, updatedAt = 1 }))
    local many = {}
    for index = 1, 10 do
      many[index] = { i = index, r = "alter", n = "N" }
    end
    assert.is_nil(rank_map({ rev = 1, updatedAt = 1, ranks = many }))
  end)
end)
