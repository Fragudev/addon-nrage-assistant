local function load_guard()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/AccessGuard.lua"))("NrageAssistant", ns)
  return ns.AccessGuard
end

local function fake_platform(overrides)
  local p = {
    IsInGuild = function()
      return true
    end,
    GetGuildClubId = function()
      return 123
    end,
    GetGuildName = function()
      return "Nrage"
    end,
    GetFaction = function()
      return "Alliance"
    end,
    GetRealmName = function()
      return "ClassicBetaPvP"
    end,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

describe("AccessGuard.Evaluate", function()
  local guard = load_guard()
  local by_name = { GUILD_NAME = "Nrage", FACTION = "Alliance", RULESET_REALM_MARKER = "PvP" }
  local by_id = { GUILD_NAME = "Nrage", GUILD_CLUB_ID = 123, FACTION = "Alliance", RULESET_REALM_MARKER = "PvP" }

  it("allows a Nrage Alliance member (name fallback)", function()
    assert.is_true(guard.Evaluate(fake_platform(), by_name))
  end)

  it("allows a Nrage Alliance member (club id)", function()
    assert.is_true(guard.Evaluate(fake_platform(), by_id))
  end)

  it("rejects players without a guild", function()
    local ok, reason = guard.Evaluate(
      fake_platform({
        IsInGuild = function()
          return false
        end,
      }),
      by_name
    )
    assert.is_false(ok)
    assert.are.equal("not_in_guild", reason)
  end)

  it("rejects another guild by name", function()
    local ok, reason = guard.Evaluate(
      fake_platform({
        GetGuildName = function()
          return "Other"
        end,
      }),
      by_name
    )
    assert.is_false(ok)
    assert.are.equal("wrong_guild", reason)
  end)

  it("rejects another guild by club id, ignoring a matching name", function()
    local ok, reason = guard.Evaluate(
      fake_platform({
        GetGuildClubId = function()
          return 999
        end,
      }),
      by_id
    )
    assert.is_false(ok)
    assert.are.equal("wrong_guild", reason)
  end)

  it("rejects a non-PvP ruleset", function()
    local platform = fake_platform({
      GetRealmName = function()
        return "ClassicBetaNormal"
      end,
    })
    local ok, reason = guard.Evaluate(platform, by_name)
    assert.is_false(ok)
    assert.are.equal("wrong_ruleset", reason)
  end)

  it("waits for a value the client has not given yet", function()
    local function pending(platform, constants)
      local ok, reason = guard.Evaluate(fake_platform(platform), constants)
      assert.is_false(ok)
      assert.are.equal("pending", reason)
    end
    local function none()
      return nil
    end
    pending({ GetGuildClubId = none }, by_id)
    pending({ GetGuildName = none }, by_name)
    pending({ GetFaction = none }, by_name)
    pending({ GetRealmName = none }, by_name)
    pending({
      GetRealmName = function()
        return ""
      end,
    }, by_name)
  end)

  it("rejects the wrong faction", function()
    local ok, reason = guard.Evaluate(
      fake_platform({
        GetFaction = function()
          return "Horde"
        end,
      }),
      by_name
    )
    assert.is_false(ok)
    assert.are.equal("wrong_faction", reason)
  end)
end)

describe("AccessGuard monitor", function()
  local guard = load_guard()

  -- `answers` is what evaluate gives on each call; the last one repeats.
  local function monitor(answers, active)
    local env = { active = active or false, activations = 0, deactivated = {}, timers = {}, waits = 0, calls = 0 }
    env.monitor = guard.NewMonitor({
      evaluate = function()
        env.calls = env.calls + 1
        local answer = answers[math.min(env.calls, #answers)]
        return answer[1], answer[2]
      end,
      isActive = function()
        return env.active
      end,
      activate = function()
        env.active = true
        env.activations = env.activations + 1
      end,
      deactivate = function(reason)
        env.active = false
        env.deactivated[#env.deactivated + 1] = reason
      end,
      schedule = function(seconds, fn)
        env.timers[#env.timers + 1] = fn
        env.delay = seconds
      end,
      onWait = function()
        env.waits = env.waits + 1
      end,
      retrySeconds = 2,
      retryMax = 3,
    })
    function env.fire()
      table.remove(env.timers, 1)()
    end
    return env
  end

  it("activates at once when the access is confirmed", function()
    local env = monitor({ { true } })
    env.monitor:Check()
    assert.are.equal(1, env.activations)
    assert.are.equal(0, #env.timers)
  end)

  it("activates when the data arrives late, without a notice", function()
    local env = monitor({ { false, "pending" }, { false, "not_in_guild" }, { true } })
    env.monitor:Check()
    assert.are.equal(2, env.delay)
    env.fire()
    env.fire()
    assert.are.equal(1, env.activations)
    assert.are.same({}, env.deactivated)
    assert.are.equal(2, env.waits)
  end)

  it("keeps one retry however many events arrive while it waits", function()
    local env = monitor({ { false, "pending" } })
    env.monitor:Check()
    env.monitor:Check()
    env.monitor:Check()
    assert.are.equal(1, #env.timers)
  end)

  it("gives up after the last retry and still activates on a later event", function()
    local env =
      monitor({ { false, "pending" }, { false, "pending" }, { false, "pending" }, { false, "pending" }, { true } })
    env.monitor:Check()
    env.fire()
    env.fire()
    env.fire()
    assert.are.same({ "pending" }, env.deactivated)
    assert.are.equal(0, #env.timers)
    env.monitor:Check()
    assert.are.equal(1, env.activations)
  end)

  it("stops at once on a definite answer", function()
    local env = monitor({ { false, "wrong_guild" } })
    env.monitor:Check()
    assert.are.same({ "wrong_guild" }, env.deactivated)
    assert.are.equal(0, #env.timers)
  end)

  it("stays active through a momentary empty answer", function()
    local env = monitor({ { false, "not_in_guild" }, { true } }, true)
    env.monitor:Check()
    env.fire()
    assert.is_true(env.active)
    assert.are.same({}, env.deactivated)
    assert.are.equal(0, env.activations)
  end)

  it("turns off a player who really left the guild, once the answer holds", function()
    local env = monitor({ { false, "not_in_guild" } }, true)
    env.monitor:Check()
    env.fire()
    env.fire()
    assert.is_true(env.active)
    env.fire()
    assert.are.same({ "not_in_guild" }, env.deactivated)
  end)

  it("gives a new momentary answer its full wait after the access was confirmed", function()
    local env = monitor({ { false, "pending" }, { true }, { false, "pending" } }, true)
    env.monitor:Check()
    env.fire()
    assert.are.equal(0, env.monitor.attempts)
    env.monitor:Check()
    assert.are.equal(1, #env.timers)
  end)
end)
