local function load_tracker()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Domain/PvPService", "Domain/PvPTracker" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_tracker()

local OWN = "Player-1-AAAA"

-- A fake platform: `kills` is the session counter (nil = unreadable), `battleground` what IsInBattleground says.
local function build(options)
  options = options or {}
  local env = { kills = options.kills, battleground = false, changes = 0, scheduled = {} }
  env.platform = {
    GetPvPSessionKills = function()
      if env.fail then
        error("secret value")
      end
      return env.kills
    end,
    IsInBattleground = function()
      return env.battleground
    end,
    ServerTime = function()
      return 1000
    end,
    ServerDay = function()
      return env.day or "2026-10-01"
    end,
    GetGUID = function()
      return OWN
    end,
  }
  env.stats = ns.PvPService.Ensure({})
  env.tracker = ns.PvPTracker.New({
    platform = env.platform,
    stats = env.stats,
    schedule = function(delay, fn)
      env.scheduled[#env.scheduled + 1] = { delay = delay, fn = fn }
    end,
    onChange = function()
      env.changes = env.changes + 1
    end,
  })
  return env
end

-- A value that raises on any comparison or conversion, like a secret value.
local function secret()
  return setmetatable({}, {
    __eq = function()
      error("secret")
    end,
    __index = function()
      error("secret")
    end,
    __tostring = function()
      error("secret")
    end,
    __lt = function()
      error("secret")
    end,
    __concat = function()
      error("secret")
    end,
  })
end

describe("PvPTracker honourable kills", function()
  it("takes the session counter as the baseline, so a reload counts nothing twice", function()
    local env = build({ kills = 7 })
    env.tracker:Start()
    assert.is_true(env.tracker.honorAvailable)
    env.tracker:CheckHonor()
    assert.are.equal(0, ns.PvPService.Totals(env.stats).honor.total)
    assert.are.equal(0, env.changes)
  end)

  it("counts the gain in the open world", function()
    local env = build({ kills = 7 })
    env.tracker:Start()
    env.kills = 9
    env.tracker:CheckHonor()
    assert.are.same({ world = 2, bg = 0 }, env.stats.honor)
    assert.are.equal(2, env.stats.daily["2026-10-01"].honor.world)
    assert.are.equal(1, env.changes)
  end)

  it("counts the gain in a battleground", function()
    local env = build({ kills = 0 })
    env.tracker:Start()
    env.battleground = true
    env.kills = 3
    env.tracker:CheckHonor()
    assert.are.same({ world = 0, bg = 3 }, env.stats.honor)
  end)

  it("counts in the world when the battleground state is unknown", function()
    local env = build({ kills = 0 })
    env.tracker:Start()
    env.battleground = nil
    env.kills = 1
    env.tracker:CheckHonor()
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("does not count twice when the event is checked twice", function()
    local env = build({ kills = 0 })
    env.tracker:Start()
    env.kills = 1
    env.tracker:OnHonorEvent()
    assert.are.equal(1, #env.scheduled)
    assert.are.equal(ns.Constants.PVP_RECHECK_SECONDS, env.scheduled[1].delay)
    env.scheduled[1].fn()
    assert.are.equal(1, env.stats.honor.world)
    assert.are.equal(1, env.changes)
  end)

  it("catches a counter that updates after the event", function()
    local env = build({ kills = 0 })
    env.tracker:Start()
    env.tracker:OnHonorEvent()
    env.kills = 1
    env.scheduled[1].fn()
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("works without a scheduler", function()
    local env = build({ kills = 0 })
    env.tracker.schedule = nil
    env.tracker:Start()
    env.kills = 1
    env.tracker:OnHonorEvent()
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("only re-baselines when the counter goes down", function()
    local env = build({ kills = 10 })
    env.tracker:Start()
    env.kills = 2
    env.tracker:CheckHonor()
    assert.are.equal(0, env.stats.honor.world)
    assert.are.equal(0, env.changes)
    env.kills = 3
    env.tracker:CheckHonor()
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("marks honour as unavailable when the counter cannot be read", function()
    local env = build({ kills = nil })
    env.tracker:Start()
    assert.is_false(env.tracker.honorAvailable)
    env.tracker:CheckHonor()
    assert.are.equal(0, env.changes)
  end)

  it("starts counting from the first reading when the counter shows up later", function()
    local env = build({ kills = nil })
    env.tracker:Start()
    env.kills = 4
    env.tracker:CheckHonor()
    assert.is_true(env.tracker.honorAvailable)
    assert.are.equal(0, env.stats.honor.world)
    env.kills = 5
    env.tracker:CheckHonor()
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("never raises when the platform does", function()
    local env = build({ kills = 1 })
    env.fail = true
    assert.has_no.errors(function()
      env.tracker:Start()
      env.tracker:OnHonorEvent()
    end)
    assert.is_false(env.tracker.honorAvailable)
    env.platform.ServerDay = function()
      error("boom")
    end
    env.fail = false
    env.tracker:Start()
    env.kills = 2
    assert.has_no.errors(function()
      env.tracker:CheckHonor()
    end)
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("ignores a reading that is not a number", function()
    local env = build({ kills = 1 })
    env.tracker:Start()
    env.kills = secret()
    assert.has_no.errors(function()
      env.tracker:CheckHonor()
    end)
    assert.are.equal(0, env.stats.honor.world)
  end)

  it("survives an onChange that raises", function()
    local env = build({ kills = 0 })
    env.tracker.onChange = function()
      error("ui")
    end
    env.tracker:Start()
    env.kills = 1
    assert.has_no.errors(function()
      env.tracker:CheckHonor()
    end)
    assert.are.equal(1, env.stats.honor.world)
  end)

  it("keeps working without an onChange", function()
    local env = build({ kills = 0 })
    env.tracker.onChange = nil
    env.tracker:Start()
    env.kills = 1
    env.tracker:CheckHonor()
    assert.are.equal(1, env.stats.honor.world)
  end)
end)

describe("PvPTracker killing blows", function()
  local function kill(overrides)
    local info = { subevent = "PARTY_KILL", sourceGUID = OWN, destGUID = "Player-2-BBBB" }
    for key, value in pairs(overrides or {}) do
      info[key] = value
    end
    return info
  end

  local function available()
    local env = build({ kills = 0 })
    env.tracker.blowsAvailable = true
    return env
  end

  it("counts a PARTY_KILL by the player on a player", function()
    local env = available()
    env.tracker:OnCombatLog(kill())
    assert.are.same({ world = 1, bg = 0 }, env.stats.blows)
    assert.are.equal(1, env.stats.daily["2026-10-01"].blows.world)
    assert.are.equal(1, env.changes)
  end)

  it("counts in the battleground bucket inside a battleground", function()
    local env = available()
    env.battleground = true
    env.tracker:OnCombatLog(kill())
    assert.are.same({ world = 0, bg = 1 }, env.stats.blows)
  end)

  it("ignores other subevents, other sources and non-player victims", function()
    local env = available()
    env.tracker:OnCombatLog(kill({ subevent = "UNIT_DIED" }))
    env.tracker:OnCombatLog(kill({ sourceGUID = "Player-9-ZZZZ" }))
    env.tracker:OnCombatLog(kill({ destGUID = "Creature-0-1" }))
    env.tracker:OnCombatLog({ subevent = "PARTY_KILL", sourceGUID = OWN })
    env.tracker:OnCombatLog({})
    assert.are.same({ world = 0, bg = 0 }, env.stats.blows)
    assert.are.equal(0, env.changes)
  end)

  it("counts nothing when the combat log is not available", function()
    local env = build({ kills = 0 })
    env.tracker:OnCombatLog(kill())
    assert.are.equal(0, env.stats.blows.world)
  end)

  it("counts nothing when the own GUID is unknown", function()
    local env = available()
    env.platform.GetGUID = function() end
    env.tracker:OnCombatLog(kill({ sourceGUID = nil }))
    assert.are.equal(0, env.stats.blows.world)
  end)

  it("drops secret values without raising", function()
    local env = available()
    for _, bad in ipairs({
      { subevent = secret() },
      { sourceGUID = secret() },
      { destGUID = secret() },
      {
        subevent = function()
          error("secret")
        end,
      },
    }) do
      assert.has_no.errors(function()
        env.tracker:OnCombatLog(kill(bad))
      end)
    end
    assert.are.equal(0, env.stats.blows.world)
    assert.are.equal(0, env.changes)
  end)

  it("drops an event whose table raises on access", function()
    local env = available()
    assert.has_no.errors(function()
      env.tracker:OnCombatLog(secret())
    end)
    env.platform.GetGUID = function()
      error("secret")
    end
    assert.has_no.errors(function()
      env.tracker:OnCombatLog(kill())
    end)
    assert.are.equal(0, env.stats.blows.world)
  end)
end)
