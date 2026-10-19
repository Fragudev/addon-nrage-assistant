local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/ReadinessRules",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/ReadinessRulesSync",
    "Sync/RosterSync",
    "Sync/RecipeSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Rules, Sync, Protocol = ns.ReadinessRules, ns.ReadinessRulesSync, ns.Protocol

local NOW = 100000

local function rule(overrides)
  local r = { id = "level", label = "Level 60", check = "level", min = 60 }
  for k, v in pairs(overrides or {}) do
    r[k] = v
  end
  return r
end

describe("ReadinessRules.Validate", function()
  it("accepts every starting rule", function()
    local clean = Rules.Validate(ns.Constants.DEFAULT_RULES)
    assert.is_table(clean)
    assert.are.equal(#ns.Constants.DEFAULT_RULES, #clean)
  end)

  it("works out evidenceMode from the check and ignores the one given", function()
    local clean = Rules.Validate({
      rule({ evidenceMode = "manual" }),
      { id = "food", label = "Food", check = "confirm", evidenceMode = "observed" },
    })
    assert.are.equal("observed", clean[1].evidenceMode)
    assert.are.equal("manual", clean[2].evidenceMode)
  end)

  it("drops fields it does not know", function()
    local clean = Rules.Validate({ rule({ evil = "x", min = 60 }) })
    assert.is_nil(clean[1].evil)
  end)

  it("refuses an empty set, too many rules and repeated ids", function()
    assert.are.equal("empty", select(2, Rules.Validate({})))
    assert.are.equal("empty", select(2, Rules.Validate("nope")))
    local many = {}
    for i = 1, ns.Constants.READINESS_RULES_MAX + 1 do
      many[i] = rule({ id = "r" .. i })
    end
    assert.are.equal("too_many", select(2, Rules.Validate(many)))
    assert.are.equal("duplicate_id", select(2, Rules.Validate({ rule(), rule() })))
  end)

  it("refuses unusable ids, labels, checks and details", function()
    assert.are.equal("bad_id", select(2, Rules.Validate({ rule({ id = "has space" }) })))
    assert.are.equal("bad_id", select(2, Rules.Validate({ rule({ id = "" }) })))
    assert.are.equal("bad_label", select(2, Rules.Validate({ rule({ label = "|cffff0000red|r" }) })))
    assert.are.equal("bad_check", select(2, Rules.Validate({ rule({ check = "run_code" }) })))
    assert.are.equal("bad_details", select(2, Rules.Validate({ rule({ min = 0 }) })))
    assert.are.equal("bad_details", select(2, Rules.Validate({ rule({ min = "60" }) })))
    assert.are.equal("bad_details", select(2, Rules.Validate({ rule({ check = "field", field = "nope" }) })))
  end)

  it("checks the lists of enchants and buffs", function()
    local ok = Rules.Validate({
      { id = "ench", label = "Enchants", check = "enchants", slots = { 16, 5 } },
      { id = "flask", label = "Flask", check = "buff", spellIds = { 17538 }, names = { "Well Fed" } },
    })
    assert.are.same({ 16, 5 }, ok[1].slots)
    assert.are.same({ 17538 }, ok[2].spellIds)
    local function bad(r)
      return select(2, Rules.Validate({ r }))
    end
    assert.are.equal("bad_details", bad({ id = "e", label = "E", check = "enchants", slots = { 99 } }))
    assert.are.equal("bad_details", bad({ id = "e", label = "E", check = "enchants", slots = {} }))
    assert.are.equal("bad_details", bad({ id = "b", label = "B", check = "buff" }))
    assert.are.equal("bad_details", bad({ id = "b", label = "B", check = "buff", names = { 5 } }))
  end)
end)

describe("ReadinessRules.Active", function()
  it("falls back to the starting rules until the guild sets its own", function()
    assert.are.equal(ns.Constants.DEFAULT_RULES, Rules.Active({}))
    assert.are.equal(ns.Constants.DEFAULT_RULES, Rules.Active(nil))
    local own = { rule() }
    assert.are.equal(own, Rules.Active({ rules = own, rev = 1 }))
  end)
end)

local function message(overrides)
  local payload = { rev = 1, updatedAt = NOW - 10, rules = { rule() } }
  for k, v in pairs(overrides or {}) do
    payload[k] = v
  end
  local clean, reason = Protocol.Validate(Protocol.Build("READINESS_RULES", payload, "id-1"))
  assert(clean, reason)
  return clean
end

local function context()
  return {
    record = {},
    now = function()
      return NOW
    end,
  }
end

describe("READINESS_RULES validation", function()
  it("refuses a payload whose rules do not validate", function()
    local built = Protocol.Build("READINESS_RULES", { rev = 1, updatedAt = 5, rules = { rule({ check = "x" }) } }, "id")
    assert.are.equal("bad_payload", select(2, Protocol.Validate(built)))
  end)

  it("bounds the revision and the time", function()
    local function reason(payload)
      return select(2, Protocol.Validate(Protocol.Build("READINESS_RULES", payload, "id")))
    end
    assert.are.equal("bad_payload", reason({ rev = 0, updatedAt = 5, rules = { rule() } }))
    assert.are.equal("bad_payload", reason({ rev = 1, updatedAt = -1, rules = { rule() } }))
  end)
end)

describe("ReadinessRulesSync.Apply", function()
  it("keeps the rules an admin sends and records who and when", function()
    local ctx = context()
    assert.is_true(Sync.Apply(ctx, message(), "Boss", "admin"))
    assert.are.equal(1, ctx.record.rev)
    assert.are.equal("Boss", ctx.record.updatedBy)
    assert.are.equal(60, ctx.record.rules[1].min)
  end)

  it("refuses anyone who is not an admin, and a sender the roster does not know", function()
    for _, role in ipairs({ "member", "rl", "council" }) do
      local ctx = context()
      local ok, reason = Sync.Apply(ctx, message(), "Someone", role)
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.is_nil(ctx.record.rules)
    end
    local ok, reason = Sync.Apply(context(), message(), "Ghost", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
  end)

  it("takes a newer revision, ignores an older one and a replay", function()
    local ctx = context()
    Sync.Apply(ctx, message({ rev = 2, rules = { rule({ min = 58 }) } }), "Boss", "admin")
    local ok, reason = Sync.Apply(ctx, message({ rev = 1, rules = { rule({ min = 40 }) } }), "Boss", "admin")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_false((Sync.Apply(ctx, message({ rev = 2, rules = { rule({ min = 58 }) } }), "Boss", "admin")))
    assert.is_true(Sync.Apply(ctx, message({ rev = 3, rules = { rule({ min = 60 }) } }), "Boss", "admin"))
    assert.are.equal(60, ctx.record.rules[1].min)
  end)

  it("does not let a sender date a set in the future to win", function()
    local ctx = context()
    Sync.Apply(ctx, message({ updatedAt = NOW + 999999 }), "Boss", "admin")
    assert.are.equal(NOW + 300, ctx.record.updatedAt)
  end)

  it("builds the payload of a stored set, and none while there is no set", function()
    assert.is_nil(Sync.Payload({}))
    local ctx = context()
    Sync.Apply(ctx, message(), "Boss", "admin")
    local payload = Sync.Payload(ctx.record)
    assert.are.equal(1, payload.rev)
    assert.is_table(Sync.SnapshotItem(ctx.record))
    assert.is_nil(Sync.SnapshotItem({}))
  end)
end)
