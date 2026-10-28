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
  it("falls back to the starting rules until the roster sets its own", function()
    assert.are.equal(ns.Constants.DEFAULT_RULES, Rules.Active({}))
    assert.are.equal(ns.Constants.DEFAULT_RULES, Rules.Active(nil))
    local own = { rule() }
    assert.are.equal(own, Rules.Active({ rules = own, rev = 1 }))
  end)
end)

describe("ReadinessRules.Current", function()
  local own = { rule({ min = 55 }) }

  before_each(function()
    ns.db = { global = { readinessRulesByRoster = { r1 = { rev = 1, rules = own } } } }
  end)

  after_each(function()
    ns.db = nil
  end)

  it("answers the rules of that roster", function()
    assert.are.equal(own, Rules.Current("r1"))
  end)

  it("answers the starting rules for a roster without a record", function()
    assert.are.equal(ns.Constants.DEFAULT_RULES, Rules.Current("r2"))
  end)

  it("answers no rules without a roster", function()
    assert.are.same({}, Rules.Current(nil))
  end)

  it("finds the record of a roster", function()
    assert.are.equal(ns.db.global.readinessRulesByRoster.r1, Rules.Record("r1"))
    assert.is_nil(Rules.Record("r2"))
    assert.is_nil(Rules.Record(nil))
  end)
end)

local function message(overrides)
  local payload = { rosterId = "r1", rev = 1, updatedAt = NOW - 10, rules = { rule() } }
  for k, v in pairs(overrides or {}) do
    payload[k] = v
  end
  local clean, reason = Protocol.Validate(Protocol.Build("ROSTER_RULES", payload, "id-1"))
  assert(clean, reason)
  return clean
end

-- Two rosters; Ann and Rita are in r1, Rob in r2, Nina in none.
local function context()
  return {
    records = {},
    rosters = { r1 = { id = "r1", name = "Alpha" }, r2 = { id = "r2", name = "Bravo" } },
    members = {
      Ann = { rosterId = "r1" },
      Rita = { rosterId = "r1" },
      Rob = { rosterId = "r2" },
      Nina = {},
    },
    tombstones = {},
    now = function()
      return NOW
    end,
  }
end

describe("ROSTER_RULES validation", function()
  it("refuses a payload whose rules do not validate", function()
    local built = Protocol.Build(
      "ROSTER_RULES",
      { rosterId = "r1", rev = 1, updatedAt = 5, rules = { rule({ check = "x" }) } },
      "id"
    )
    assert.are.equal("bad_payload", select(2, Protocol.Validate(built)))
  end)

  it("needs a roster id", function()
    local built = Protocol.Build("ROSTER_RULES", { rev = 1, updatedAt = 5, rules = { rule() } }, "id")
    assert.are.equal("bad_payload", select(2, Protocol.Validate(built)))
  end)

  it("bounds the revision and the time", function()
    local function reason(payload)
      return select(2, Protocol.Validate(Protocol.Build("ROSTER_RULES", payload, "id")))
    end
    assert.are.equal("bad_payload", reason({ rosterId = "r1", rev = 0, updatedAt = 5, rules = { rule() } }))
    assert.are.equal("bad_payload", reason({ rosterId = "r1", rev = 1, updatedAt = -1, rules = { rule() } }))
  end)

  it("no longer knows the guild-wide message", function()
    local built = Protocol.Build("READINESS_RULES", { rev = 1, updatedAt = 5, rules = { rule() } }, "id")
    assert.are.equal("unknown_type", select(2, Protocol.Validate(built)))
  end)
end)

describe("ReadinessRulesSync.Apply", function()
  it("keeps the rules gm and cogm send for any roster and records who and when", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      for _, rosterId in ipairs({ "r1", "r2" }) do
        local ctx = context()
        assert.is_true(Sync.Apply(ctx, message({ rosterId = rosterId }), "Boss", role))
        local record = ctx.records[rosterId]
        assert.are.same({ 1, "Boss", 60 }, { record.rev, record.updatedBy, record.rules[1].min })
        assert.is_nil(ctx.records[rosterId == "r1" and "r2" or "r1"])
      end
    end
  end)

  it("keeps what an rl sends for its own roster", function()
    local ctx = context()
    assert.is_true(Sync.Apply(ctx, message(), "Ann", "rl"))
    assert.are.equal("Ann", ctx.records.r1.updatedBy)
  end)

  it("refuses an rl for another roster, without a roster or unknown to the receiver", function()
    for _, sender in ipairs({ "Rob", "Nina", "Ghost" }) do
      local ctx = context()
      local ok, reason = Sync.Apply(ctx, message(), sender, "rl")
      assert.is_false(ok)
      assert.are.equal("forbidden", reason, sender)
      assert.is_nil(ctx.records.r1)
    end
  end)

  it("refuses an rl whose roster no longer exists at the receiver", function()
    local ctx = context()
    ctx.rosters.r1 = nil
    local ok, reason = Sync.Apply(ctx, message(), "Ann", "rl")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
  end)

  it("refuses officer, roster, member and alter, even on their own roster", function()
    for _, role in ipairs({ "officer", "roster", "member", "alter" }) do
      local ctx = context()
      local ok, reason = Sync.Apply(ctx, message(), "Ann", role)
      assert.is_false(ok)
      assert.are.equal("forbidden", reason, role)
      assert.is_nil(ctx.records.r1)
    end
  end)

  it("refuses a sender the roster does not know", function()
    local ok, reason = Sync.Apply(context(), message(), "Ghost", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
  end)

  it("refuses the rules of a roster that was deleted", function()
    local ctx = context()
    ctx.tombstones["R:r1"] = { rev = 3, at = 1 }
    local ok, reason = Sync.Apply(ctx, message(), "Boss", "gm")
    assert.is_false(ok)
    assert.are.equal("tombstoned", reason)
  end)

  it("takes a newer revision per roster, ignores an older one and a replay", function()
    local ctx = context()
    Sync.Apply(ctx, message({ rev = 2, rules = { rule({ min = 58 }) } }), "Boss", "gm")
    local ok, reason = Sync.Apply(ctx, message({ rev = 1, rules = { rule({ min = 40 }) } }), "Boss", "gm")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_false((Sync.Apply(ctx, message({ rev = 2, rules = { rule({ min = 58 }) } }), "Boss", "gm")))
    assert.is_true(Sync.Apply(ctx, message({ rev = 3, rules = { rule({ min = 60 }) } }), "Boss", "gm"))
    assert.are.equal(60, ctx.records.r1.rules[1].min)
    -- Another roster has its own revision line.
    assert.is_true(Sync.Apply(ctx, message({ rosterId = "r2", rev = 1 }), "Boss", "gm"))
    assert.are.equal(3, ctx.records.r1.rev)
  end)

  it("breaks a tie by time and then by sender", function()
    local ctx = context()
    Sync.Apply(ctx, message({ rev = 2, updatedAt = NOW - 20 }), "Boss", "gm")
    assert.is_true(Sync.Apply(ctx, message({ rev = 2, updatedAt = NOW - 10 }), "Aaron", "cogm"))
    assert.is_false((Sync.Apply(ctx, message({ rev = 2, updatedAt = NOW - 15 }), "Zed", "gm")))
  end)

  it("does not let a sender date a set in the future to win", function()
    local ctx = context()
    Sync.Apply(ctx, message({ updatedAt = NOW + 999999 }), "Boss", "gm")
    assert.are.equal(NOW + 300, ctx.records.r1.updatedAt)
  end)

  it("builds the payload of a stored set, and none while there is no set", function()
    assert.is_nil(Sync.Payload("r1", {}))
    assert.is_nil(Sync.Payload(nil, { rules = {} }))
    local ctx = context()
    Sync.Apply(ctx, message(), "Boss", "gm")
    local payload = Sync.Payload("r1", ctx.records.r1)
    assert.are.same({ "r1", 1 }, { payload.rosterId, payload.rev })
    assert.is_table(Sync.SnapshotItem("r1", ctx.records.r1))
    assert.is_nil(Sync.SnapshotItem("r1", {}))
  end)

  it("puts every roster that has a set in a snapshot, and no deleted one", function()
    local ctx = context()
    Sync.Apply(ctx, message({ rosterId = "r1" }), "Boss", "gm")
    Sync.Apply(ctx, message({ rosterId = "r2" }), "Boss", "gm")
    ctx.records.gone = ctx.records.r1
    local items = Sync.SnapshotItems(ctx.records, ctx.rosters)
    assert.are.same({ "r1", "r2" }, { items[1].p.rosterId, items[2].p.rosterId })
    assert.are.equal(2, #items)
    ctx.rosters.r2 = nil
    assert.are.equal(1, #Sync.SnapshotItems(ctx.records, ctx.rosters))
  end)

  it("lists the sets the own role may author", function()
    local ctx = context()
    Sync.Apply(ctx, message({ rosterId = "r1" }), "Boss", "gm")
    Sync.Apply(ctx, message({ rosterId = "r2" }), "Boss", "gm")
    local function ids(role, own)
      local list = {}
      for _, payload in ipairs(Sync.Authored(ctx.records, role, own)) do
        list[#list + 1] = payload.rosterId
      end
      return list
    end
    assert.are.same({ "r1", "r2" }, ids("gm"))
    assert.are.same({ "r1", "r2" }, ids("cogm"))
    assert.are.same({ "r2" }, ids("rl", "r2"))
    assert.are.same({}, ids("rl", nil))
    assert.are.same({}, ids("officer", "r1"))
  end)

  it("drops the rules of a deleted roster", function()
    local ctx = context()
    Sync.Apply(ctx, message(), "Boss", "gm")
    Sync.Forget(ctx.records, "r1")
    assert.is_nil(ctx.records.r1)
  end)
end)
