local function load_protocol()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/EventModel.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/LootModel.lua"))("NrageAssistant", ns)
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
