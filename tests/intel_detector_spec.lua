local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelDetector",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build(overrides)
  local env = {
    clock = 1000,
    units = {},
    targeting = {},
    allowed = true,
    contacts = {},
    ownLevel = 60,
    ownFaction = "Alliance",
    intel = { players = {}, kos = {}, ignore = {}, zones = {} },
  }
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  env.service = ns.IntelService.New({
    intel = env.intel,
    settings = function()
      return { removeMinutes = 5 }
    end,
    now = function()
      return env.clock
    end,
    wall = function()
      return 5000000 + env.clock
    end,
  })
  env.detector = ns.IntelDetector.New({
    reader = {
      GetEnemyDetails = function(unit)
        local details = env.units[unit]
        if details == "raise" then
          error("secret")
        end
        return details
      end,
      IsEnemyTargetingPlayer = function(unit)
        return env.targeting[unit] == true
      end,
      GetLevel = function()
        return env.ownLevel
      end,
      GetPlayerFaction = function()
        return env.ownFaction
      end,
    },
    service = env.service,
    now = function()
      return env.clock
    end,
    allowed = function()
      return env.allowed, env.allowed and nil or "sanctuary"
    end,
    where = function()
      return { map = 1411, x = 5, y = 6 }
    end,
    onContact = function(result, details, where)
      env.contacts[#env.contacts + 1] = { result = result, details = details, where = where }
    end,
  })
  return env
end

local function enemy(name, overrides)
  local details = { name = name, class = "ROGUE", race = "ORC", level = 60, faction = "Horde" }
  for key, value in pairs(overrides or {}) do
    details[key] = value
  end
  return details
end

describe("IntelDetector:OnUnit", function()
  local env

  before_each(function()
    env = build()
  end)

  it("hands an enemy to the service with the position of the reporter", function()
    env.units.target = enemy("Bob")
    local result = env.detector:OnUnit("target")
    assert.is_true(result.isNew)
    assert.are.equal(1411, env.intel.players.bob.lastMap)
    assert.are.equal(1, env.detector.contacts)
    assert.are.equal(1, #env.contacts)
    assert.are.same({ map = 1411, x = 5, y = 6 }, env.contacts[1].where)
  end)

  it("counts a second read of the same enemy apart from a new contact", function()
    env.units.target = enemy("Bob")
    env.detector:OnUnit("target")
    env.detector:OnUnit("target")
    assert.are.equal(1, env.detector.contacts)
    assert.are.equal(1, env.detector.reads)
  end)

  it("skips a unit the reader cannot read, including a secret value that raises", function()
    assert.are.same({ nil, "unreadable" }, { env.detector:OnUnit("target") })
    env.units.focus = "raise"
    assert.are.same({ nil, "error" }, { env.detector:OnUnit("focus") })
    assert.are.same({}, env.intel.players)
    assert.are.equal(1, env.detector.drops.unreadable)
    assert.are.equal(1, env.detector.drops.error)
  end)

  it("skips a unit of the own faction", function()
    env.units.target = enemy("Duelist", { faction = "Alliance" })
    assert.are.same({ nil, "same_faction" }, { env.detector:OnUnit("target") })
    assert.are.same({}, env.intel.players)
  end)

  it("keeps a unit whose faction is not known", function()
    env.units.target = enemy("Bob", { faction = nil })
    assert.is_table(env.detector:OnUnit("target"))
  end)

  it("reads nothing where detection is not allowed, and says why", function()
    env.allowed = false
    env.units.target = enemy("Bob")
    assert.are.same({ nil, "sanctuary" }, { env.detector:OnUnit("target") })
    assert.are.same({}, env.intel.players)
  end)

  it("estimates a skull level from the own level", function()
    env.units.target = enemy("Boss", { level = nil, skull = true })
    env.detector:OnUnit("target")
    assert.are.equal(60 + Constants.INTEL_SKULL_LEVEL_BONUS, env.intel.players.boss.level)
    assert.is_true(env.intel.players.boss.levelEstimated)
  end)

  it("leaves the level unknown when the own level cannot be read", function()
    env.ownLevel = nil
    env.units.target = enemy("Boss", { level = nil, skull = true })
    env.detector:OnUnit("target")
    assert.is_nil(env.intel.players.boss.level)
  end)

  it("drops a name the service cannot keep", function()
    env.units.target = enemy("a|b")
    assert.are.same({ nil, "bad_name" }, { env.detector:OnUnit("target") })
  end)

  it("does not change the table the reader gave", function()
    local details = enemy("Boss", { level = 1, skull = true })
    env.units.target = details
    env.detector:OnUnit("target")
    assert.are.equal(1, details.level)
    assert.is_nil(details.levelEstimated)
  end)

  it("survives a contact handler that raises", function()
    env.detector.deps.onContact = function()
      error("boom")
    end
    env.units.target = enemy("Bob")
    assert.is_table(env.detector:OnUnit("target"))
  end)
end)

describe("IntelDetector:Rescan", function()
  it("goes through every kind of unit", function()
    local env = build()
    for _, unit in ipairs({ "nameplate1", "nameplate17", "nameplate40", "target", "focus", "mouseover" }) do
      env.units[unit] = enemy("P" .. unit)
    end
    env.units.nameplate41 = enemy("TooFar")
    assert.are.equal(6, env.detector:Rescan())
    assert.is_nil(env.intel.players.toofar)
    assert.are.equal(6, env.service:Counts().players)
  end)

  it("does not count the units that are not there as drops", function()
    local env = build()
    env.units.target = enemy("Bob")
    env.detector:Rescan()
    assert.is_nil(env.detector.drops.unreadable)
  end)

  it("asks whether detection is allowed once per scan", function()
    local env = build()
    local asked = 0
    local allowed = env.detector.deps.allowed
    env.detector.deps.allowed = function()
      asked = asked + 1
      return allowed()
    end
    env.detector:Rescan()
    assert.are.equal(1, asked)
  end)

  it("reads the same enemy on a nameplate and as the target once", function()
    local env = build()
    env.units.nameplate2 = enemy("Bob")
    env.units.target = enemy("Bob")
    env.detector:Rescan()
    assert.are.equal(1, env.intel.players.bob.seen)
  end)

  it("reads nothing when detection is off", function()
    local env = build({ allowed = false })
    env.units.target = enemy("Bob")
    assert.are.equal(0, env.detector:Rescan())
    assert.are.equal(1, env.detector.drops.sanctuary)
  end)
end)

describe("IntelDetector:RecentTargeters", function()
  it("remembers the enemies that target the player, newest first, for a while", function()
    local env = build()
    env.units.nameplate1 = enemy("Old")
    env.units.nameplate2 = enemy("New")
    env.units.nameplate3 = enemy("Calm")
    env.targeting.nameplate1 = true
    env.detector:Rescan()
    env.clock = env.clock + 4
    env.targeting.nameplate1 = nil
    env.targeting.nameplate2 = true
    env.detector:Rescan()
    env.clock = env.clock + 3
    local names = {}
    for _, item in ipairs(env.detector:RecentTargeters(10)) do
      names[#names + 1] = item.name
    end
    assert.are.same({ "New", "Old" }, names)
    env.clock = env.clock + 5
    names = {}
    for _, item in ipairs(env.detector:RecentTargeters(10)) do
      names[#names + 1] = item.name
    end
    assert.are.same({ "New" }, names)
    env.clock = env.clock + 20
    assert.are.same({}, env.detector:RecentTargeters(10))
  end)
end)

describe("IntelDetector:OnCast", function()
  local env

  before_each(function()
    env = build()
  end)

  it("reads the caster again as stealthed when a stealth spell comes from a watched unit", function()
    env.units.nameplate3 = enemy("Bob")
    local result, details = env.detector:OnCast("nameplate3", 1784)
    assert.is_truthy(result)
    assert.is_true(details.stealth)
    assert.is_true(env.contacts[1].details.stealth)
  end)

  it("ignores another spell, another unit and an addon that is not allowed without counting a drop", function()
    env.units.nameplate3 = enemy("Bob")
    env.units.party1 = enemy("Ann")
    assert.are.same({ nil, "not_stealth" }, { env.detector:OnCast("nameplate3", 133) })
    assert.are.same({ nil, "not_stealth" }, { env.detector:OnCast("party1", 1784) })
    assert.are.same({}, env.detector.drops)
    env.allowed = false
    assert.are.same({ nil, "sanctuary" }, { env.detector:OnCast("nameplate3", 1784) })
    assert.are.equal(1, env.detector.drops.sanctuary)
  end)
end)

describe("IntelDetector:OnDeath", function()
  local env

  before_each(function()
    env = build()
  end)

  it("takes the killer of the death recap when it is a known enemy", function()
    env.units.target = enemy("Bob")
    env.detector:OnUnit("target")
    local record, source = env.detector:OnDeath("Bob-Realm")
    assert.are.equal("recap", source)
    assert.are.equal(1, record.losses)
    assert.are.equal(1, env.detector.lossSources.recap)
  end)

  it("falls back to the newest enemy that targeted the player", function()
    env.targeting.nameplate1 = true
    env.units.nameplate1 = enemy("Old")
    env.detector:OnUnit("nameplate1")
    env.clock = env.clock + 3
    env.targeting.nameplate1, env.targeting.nameplate2 = nil, true
    env.units.nameplate2 = enemy("New")
    env.detector:OnUnit("nameplate2")
    env.clock = env.clock + 1
    local record, source = env.detector:OnDeath("a creature")
    assert.are.equal("targeting", source)
    assert.are.equal("New", record.name)
    assert.are.equal(1, env.detector.lossSources.targeting)
  end)

  it("falls back to the enemy target, and says when nobody can be named", function()
    env.units.target = enemy("Tom")
    local record, source = env.detector:OnDeath(nil)
    assert.are.equal("target", source)
    assert.are.equal("Tom", record.name)
    env.units.target = nil
    assert.are.same({ nil, "unknown" }, { env.detector:OnDeath(nil) })
    assert.are.equal(1, env.detector.lossSources.unknown)
  end)

  it("does not use an enemy that targeted the player a long time ago", function()
    env.targeting.nameplate1 = true
    env.units.nameplate1 = enemy("Old")
    env.detector:OnUnit("nameplate1")
    env.clock = env.clock + Constants.INTEL_LOSS_FALLBACK_SECONDS + 1
    assert.are.same({ nil, "unknown" }, { env.detector:OnDeath(nil) })
  end)

  it("gives up when the target cannot be read", function()
    env.units.target = "raise"
    assert.are.same({ nil, "unknown" }, { env.detector:OnDeath(nil) })
  end)
end)
