local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/IntelModel", "Domain/IntelPublisher" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build(overrides)
  local env = {
    clock = 100,
    settings = { share = true },
    canSend = true,
    kind = "none",
    group = "RAID",
    ignored = {},
    sent = {},
    sendOk = true,
  }
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  env.publisher = ns.IntelPublisher.New({
    now = function()
      return env.clock
    end,
    settings = function()
      return env.settings
    end,
    canSend = function()
      return env.canSend
    end,
    instanceKind = function()
      return env.kind
    end,
    groupChannel = function()
      return env.group
    end,
    isIgnored = function(name)
      return env.ignored[name] == true
    end,
    send = function(text, channel)
      env.sent[#env.sent + 1] = { text = text, channel = channel }
      return env.sendOk
    end,
  })
  return env
end

local function enemy(name, overrides)
  local details = { name = name, class = "ROGUE", race = "ORC", level = 60 }
  for key, value in pairs(overrides or {}) do
    details[key] = value
  end
  return details
end

local WHERE = { map = 1411, x = 10, y = 20 }

-- Ticks `count` times, moving the clock past the tick limit each time.
local function drain(env, count)
  for _ = 1, count do
    env.publisher:Tick()
    env.clock = env.clock + Constants.INTEL_SHARE_TICK_SECONDS
  end
end

describe("IntelPublisher:Offer", function()
  local env

  before_each(function()
    env = build()
  end)

  it("queues a sighting and sends it on the next tick", function()
    assert.is_true(env.publisher:Offer(enemy("Bob"), WHERE, false))
    assert.is_true(env.publisher:Tick())
    assert.are.same({ { text = "I1:1411:10:20:4:6:60:0:Bob", channel = "GUILD" } }, env.sent)
    assert.are.equal(1, env.publisher.sent)
  end)

  it("sends the flags of an estimated level and of stealth", function()
    env.publisher:Offer(enemy("Bob", { levelEstimated = true, stealth = true }), WHERE)
    env.publisher:Tick()
    assert.are.equal("I1:1411:10:20:4:6:60:3:Bob", env.sent[1].text)
  end)

  it("does nothing when sharing is off", function()
    env.settings.share = false
    assert.are.same({ false, "disabled" }, { env.publisher:Offer(enemy("Bob"), WHERE) })
    assert.are.same({ false, "empty" }, { env.publisher:Tick() })
  end)

  it("drops the sighting during the lockdown", function()
    env.canSend = false
    assert.are.same({ false, "lockdown" }, { env.publisher:Offer(enemy("Bob"), WHERE) })
    assert.are.equal(1, env.publisher.drops.lockdown)
  end)

  it("drops an ignored enemy, one without a position and one with unusable fields", function()
    env.ignored.Bob = true
    assert.are.same({ false, "ignored" }, { env.publisher:Offer(enemy("Bob"), WHERE) })
    assert.are.same({ false, "no_position" }, { env.publisher:Offer(enemy("Eve"), { map = 1411 }) })
    assert.are.same({ false, "no_position" }, { env.publisher:Offer(enemy("Eve"), nil) })
    assert.are.same({ false, "bad_fields" }, { env.publisher:Offer(enemy("a|b"), WHERE) })
    assert.are.same({ false, "bad_fields" }, { env.publisher:Offer(nil, WHERE) })
  end)

  it("sends an enemy at most once per interval", function()
    env.publisher:Offer(enemy("Bob"), WHERE)
    env.publisher:Tick()
    env.clock = env.clock + Constants.INTEL_SHARE_ENEMY_SECONDS - 1
    assert.are.same({ false, "recent" }, { env.publisher:Offer(enemy("Bob"), WHERE) })
    env.clock = env.clock + 1
    assert.is_true(env.publisher:Offer(enemy("Bob"), WHERE))
  end)

  it("sends again sooner when the enemy starts stealth, once", function()
    env.publisher:Offer(enemy("Bob"), WHERE)
    env.publisher:Tick()
    env.clock = env.clock + 5
    assert.is_true(env.publisher:Offer(enemy("Bob", { stealth = true }), WHERE))
    env.publisher:Tick()
    env.clock = env.clock + 5
    assert.are.same({ false, "recent" }, { env.publisher:Offer(enemy("Bob", { stealth = true }), WHERE) })
  end)

  it("replaces a sighting that is waiting for the same enemy", function()
    env.publisher:Offer(enemy("Bob", { level = 50 }), WHERE)
    env.publisher:Offer(enemy("Bob", { level = 51 }), { map = 1411, x = 99, y = 20 })
    assert.are.equal(1, #env.publisher.queue)
    env.publisher:Tick()
    assert.are.equal("I1:1411:99:20:4:6:51:0:Bob", env.sent[1].text)
  end)

  it("keeps a queue of a few and drops the oldest sighting that is not Kill On Sight", function()
    local limit = Constants.INTEL_SHARE_QUEUE_MAX
    env.publisher:Offer(enemy("Kos"), WHERE, true)
    for index = 1, limit - 1 do
      env.clock = env.clock + 1
      env.publisher:Offer(enemy("P" .. index), WHERE)
    end
    env.clock = env.clock + 1
    assert.is_true(env.publisher:Offer(enemy("Late"), WHERE))
    assert.are.equal(limit, #env.publisher.queue)
    local names = {}
    for _, item in ipairs(env.publisher.queue) do
      names[item.name] = true
    end
    assert.is_true(names.Kos)
    assert.is_nil(names.P1)
    assert.is_true(names.Late)
  end)

  it("drops a new sighting that is not Kill On Sight when the queue is full of those", function()
    local limit = Constants.INTEL_SHARE_QUEUE_MAX
    for index = 1, limit do
      env.clock = env.clock + 1
      env.publisher:Offer(enemy("K" .. index), WHERE, true)
    end
    assert.are.same({ false, "full" }, { env.publisher:Offer(enemy("Plain"), WHERE) })
    env.clock = env.clock + 1
    assert.is_true(env.publisher:Offer(enemy("NewKos"), WHERE, true))
    local names = {}
    for _, item in ipairs(env.publisher.queue) do
      names[item.name] = true
    end
    assert.is_nil(names.K1)
    assert.is_true(names.NewKos)
  end)
end)

describe("IntelPublisher:Tick", function()
  local env

  before_each(function()
    env = build()
  end)

  it("sends at most one message per tick interval", function()
    env.publisher:Offer(enemy("A"), WHERE)
    env.publisher:Offer(enemy("B"), WHERE)
    assert.is_true(env.publisher:Tick())
    assert.are.same({ false, "throttled" }, { env.publisher:Tick() })
    env.clock = env.clock + Constants.INTEL_SHARE_TICK_SECONDS - 1
    assert.are.same({ false, "throttled" }, { env.publisher:Tick() })
    env.clock = env.clock + 1
    assert.is_true(env.publisher:Tick())
    assert.are.equal(2, #env.sent)
  end)

  it("sends Kill On Sight first, then the one that waited longest", function()
    env.publisher:Offer(enemy("First"), WHERE)
    env.clock = env.clock + 1
    env.publisher:Offer(enemy("Second"), WHERE)
    env.publisher:Offer(enemy("Kos"), WHERE, true)
    drain(env, 3)
    local names = {}
    for _, message in ipairs(env.sent) do
      names[#names + 1] = message.text:match(":(%a+)$")
    end
    assert.are.same({ "Kos", "First", "Second" }, names)
  end)

  it("sends nothing and forgets the queue during the lockdown", function()
    env.publisher:Offer(enemy("A"), WHERE)
    env.publisher:Offer(enemy("B"), WHERE)
    env.canSend = false
    assert.are.same({ false, "lockdown" }, { env.publisher:Tick() })
    assert.are.same({}, env.sent)
    assert.are.equal(0, #env.publisher.queue)
    assert.are.equal(2, env.publisher.drops.lockdown)
  end)

  it("sends nothing when sharing was switched off meanwhile", function()
    env.publisher:Offer(enemy("A"), WHERE)
    env.settings.share = false
    assert.are.same({ false, "disabled" }, { env.publisher:Tick() })
    assert.are.equal(0, #env.publisher.queue)
  end)

  it("does not send an enemy that was ignored meanwhile", function()
    env.publisher:Offer(enemy("Bob"), WHERE)
    env.ignored.Bob = true
    assert.are.same({ false, "ignored" }, { env.publisher:Tick() })
    assert.are.same({}, env.sent)
  end)

  it("counts a send that failed and does not remember the enemy as sent", function()
    env.sendOk = false
    env.publisher:Offer(enemy("Bob"), WHERE)
    assert.are.same({ false, "send_failed" }, { env.publisher:Tick() })
    env.clock = env.clock + Constants.INTEL_SHARE_TICK_SECONDS
    assert.is_true(env.publisher:Offer(enemy("Bob"), WHERE))
  end)

  it("survives a sender that raises", function()
    env.publisher.deps.send = function()
      error("boom")
    end
    env.publisher:Offer(enemy("Bob"), WHERE)
    assert.are.same({ false, "send_failed" }, { env.publisher:Tick() })
  end)

  it("forgets an enemy sent long ago", function()
    env.publisher:Offer(enemy("Bob"), WHERE)
    env.publisher:Tick()
    env.clock = env.clock + Constants.INTEL_SHARE_ENEMY_SECONDS
    env.publisher:Tick()
    assert.is_nil(env.publisher.lastSent.bob)
  end)

  describe("channel", function()
    local function channelFor(kind, group)
      local built = build({ kind = kind, group = group })
      built.publisher:Offer(enemy("Bob"), WHERE)
      local ok = built.publisher:Tick()
      return ok and built.sent[1].channel or nil, built
    end

    it("uses the guild in the open world, and when the client does not say", function()
      assert.are.equal("GUILD", (channelFor("none")))
      assert.are.equal("GUILD", (channelFor(nil)))
    end)

    it("uses the group channel in a battleground", function()
      assert.are.equal("RAID", (channelFor("pvp", "RAID")))
      assert.are.equal("INSTANCE_CHAT", (channelFor("pvp", "INSTANCE_CHAT")))
    end)

    it("sends nothing in a battleground without a group", function()
      local channel, built = channelFor("pvp", false)
      assert.is_nil(channel)
      assert.are.equal(1, built.publisher.drops.no_channel)
    end)

    it("sends nothing in arenas, dungeons and raids", function()
      for _, kind in ipairs({ "arena", "party", "raid" }) do
        local channel, built = channelFor(kind, "RAID")
        assert.is_nil(channel, kind)
        assert.are.same({}, built.sent)
        assert.are.equal(0, #built.publisher.queue)
      end
    end)
  end)
end)
