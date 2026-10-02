local function load_service()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/ReadinessService.lua"))("NrageAssistant", ns)
  return ns.ReadinessService, ns.Constants
end

local platform = {
  ServerTime = function()
    return 1000
  end,
}

describe("ReadinessService.EvaluateRule", function()
  local Service = load_service()

  it("meets or misses a level rule using observed data", function()
    local rule = { id = "lvl", label = "Level", check = "level", min = 60 }
    assert.are.equal("met", Service.EvaluateRule(rule, { level = 60 }, {}).status)
    assert.are.equal("missing", Service.EvaluateRule(rule, { level = 59 }, {}).status)
  end)

  it("never turns missing data into met", function()
    local rule = { id = "ilvl", label = "Item level", check = "ilvl", min = 0 }
    local outcome = Service.EvaluateRule(rule, {}, {})
    assert.are.equal("unknown", outcome.status)
  end)

  it("checks a profession by name and optional skill", function()
    local rule = { id = "min", label = "Mining", check = "profession", profession = "mining", min = 300 }
    local known = { professions = { { name = "Mining", skill = 300 } } }
    assert.are.equal("met", Service.EvaluateRule(rule, known, {}).status)
    known.professions[1].skill = 250
    assert.are.equal("missing", Service.EvaluateRule(rule, known, {}).status)
    local other = { professions = { { name = "Herbalism", skill = 1 } } }
    assert.are.equal("missing", Service.EvaluateRule(rule, other, {}).status)
    assert.are.equal("unknown", Service.EvaluateRule(rule, {}, {}).status)
  end)

  it("reads a declared profile field", function()
    local rule = { id = "role", label = "Role", check = "field", field = "role" }
    local declared = { fields = { role = { value = "tank", source = "declared" } } }
    local outcome = Service.EvaluateRule(rule, declared, {})
    assert.are.equal("met", outcome.status)
    assert.are.equal("declared", outcome.source)
    assert.are.equal("unknown", Service.EvaluateRule(rule, {}, {}).status)
  end)

  it("keeps a confirm rule unknown until the player confirms it", function()
    local rule = { id = "food", label = "Food", check = "confirm" }
    assert.are.equal("unknown", Service.EvaluateRule(rule, {}, {}).status)
    assert.are.equal("met", Service.EvaluateRule(rule, {}, { food = { status = "met", source = "declared" } }).status)
  end)

  it("reports an unsupported rule as unknown instead of raising", function()
    assert.are.equal("unknown", Service.EvaluateRule({ id = "x", label = "X", check = "nope" }, {}, {}).status)
  end)
end)

describe("ReadinessService.Evaluate", function()
  local Service = load_service()
  local rules = {
    { id = "lvl", label = "Level", check = "level", min = 60 },
    { id = "food", label = "Food", check = "confirm" },
    { id = "ench", label = "Enchants", check = "confirm" },
  }

  it("shows the denominator and counts unknown as not met", function()
    local _, summary = Service.Evaluate(rules, { level = 60 }, {})
    assert.are.equal(1, summary.met)
    assert.are.equal(3, summary.countable)
    assert.are.equal(2, summary.unknown)
    assert.are.equal("1/3 met, 2 unknown", summary.text)
  end)

  it("removes waived rules from the denominator", function()
    local readiness = { food = { status = "waived", source = "declared" } }
    local results, summary = Service.Evaluate(rules, { level = 60 }, readiness)
    assert.are.equal(3, #results)
    assert.are.equal(2, summary.countable)
    assert.are.equal("1/2 met, 1 unknown", summary.text)
  end)

  it("does not hide unknown when everything else is met", function()
    local readiness = { food = { status = "met" }, ench = { status = "missing" } }
    local _, summary = Service.Evaluate(rules, { level = 60 }, readiness)
    assert.are.equal("2/3 met", summary.text)
  end)
end)

describe("ReadinessService.SetManual", function()
  local Service = load_service()
  local rules = {
    { id = "lvl", label = "Level", check = "level", min = 60 },
    { id = "food", label = "Food", check = "confirm" },
  }

  it("records a declared confirmation with source and time", function()
    local readiness = {}
    assert.is_true(Service.SetManual(platform, rules, readiness, "food", "met"))
    assert.are.same({ status = "met", source = "declared", at = 1000 }, readiness.food)
  end)

  it("clears the confirmation with unknown", function()
    local readiness = { food = { status = "met" } }
    assert.is_true(Service.SetManual(platform, rules, readiness, "food", "unknown"))
    assert.is_nil(readiness.food)
  end)

  it("rejects unknown rules, automatic rules and bad statuses", function()
    local readiness = {}
    local ok, reason = Service.SetManual(platform, rules, readiness, "nope", "met")
    assert.is_false(ok)
    assert.are.equal("unknown_rule", reason)

    ok, reason = Service.SetManual(platform, rules, readiness, "lvl", "met")
    assert.is_false(ok)
    assert.are.equal("not_manual", reason)

    ok, reason = Service.SetManual(platform, rules, readiness, "food", "approved")
    assert.is_false(ok)
    assert.are.equal("invalid_status", reason)
    assert.is_nil(next(readiness))
  end)
end)

describe("Default rules", function()
  local Service, Constants = load_service()

  it("start with nothing approved", function()
    local _, summary = Service.Evaluate(Constants.DEFAULT_RULES, {}, {})
    assert.are.equal(0, summary.met)
    assert.are.equal(#Constants.DEFAULT_RULES, summary.unknown)
  end)
end)

describe("ReadinessService.Describe", function()
  local Service = load_service()

  it("prints the summary first and each rule with its status", function()
    local rules = { { id = "food", label = "Food", check = "confirm" } }
    local results, summary = Service.Evaluate(rules, {}, {})
    local lines = Service.Describe(results, summary)
    assert.are.equal("Readiness: 0/1 met, 1 unknown", lines[1])
    assert.are.equal("  [unknown] Food - not confirmed", lines[2])
  end)
end)

describe("Automatic enchant and buff checks", function()
  local Service = load_service()
  local enchantRule = { id = "enchants", label = "Enchants", check = "enchants", slots = { 16, 5 } }
  local buffRule = { id = "flask", label = "Flask", check = "buff", spellIds = { 17538 }, names = { "Well Fed" } }

  it("enchants are unknown without data", function()
    assert.are.equal("unknown", Service.EvaluateRule(enchantRule, {}, {}).status)
  end)

  it("enchants are met only when every required slot is enchanted", function()
    local met = Service.EvaluateRule(enchantRule, { enchants = { [16] = 100, [5] = 200 } }, {})
    assert.are.equal("met", met.status)
    local missing = Service.EvaluateRule(enchantRule, { enchants = { [16] = 100, [5] = 0 } }, {})
    assert.are.equal("missing", missing.status)
    assert.is_truthy(missing.detail:find("5", 1, true))
  end)

  it("an unreadable or empty required slot is unknown, never met", function()
    assert.are.equal("unknown", Service.EvaluateRule(enchantRule, { enchants = { [16] = 100 } }, {}).status)
  end)

  it("a known missing enchant wins over an unknown slot", function()
    assert.are.equal("missing", Service.EvaluateRule(enchantRule, { enchants = { [16] = 0 } }, {}).status)
  end)

  it("buffs match by spell id or by name, case-insensitively", function()
    assert.are.equal(
      "met",
      Service.EvaluateRule(buffRule, { buffs = { { name = "Other", spellId = 17538 } } }, {}).status
    )
    assert.are.equal(
      "met",
      Service.EvaluateRule(buffRule, { buffs = { { name = "well fed", spellId = 1 } } }, {}).status
    )
  end)

  it("no matching buff is missing, and no buff data is unknown", function()
    assert.are.equal(
      "missing",
      Service.EvaluateRule(buffRule, { buffs = { { name = "Other", spellId = 1 } } }, {}).status
    )
    assert.are.equal("unknown", Service.EvaluateRule(buffRule, {}, {}).status)
  end)
end)
