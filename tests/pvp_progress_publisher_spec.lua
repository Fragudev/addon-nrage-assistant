-- The own progress sent to the approvers: what it says, when it goes out and what stops it.
local function load_publisher()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PvPProgressPublisher",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_publisher()
local Constants = ns.Constants

local function build()
  local env = {
    clock = 1000,
    active = true,
    sent = {},
    timers = {},
    sendResult = true,
    season = { id = "s1", state = "active" },
    missions = {
      { id = "m1", goal = { kind = "kills" } },
      { id = "m2", goal = { kind = "bg_wins" } },
      { id = "m3", goal = { kind = "manual" } },
    },
    progress = {
      m1 = { bars = { { label = "Kills", done = 3, total = 10 } } },
      m2 = { bars = { { label = "Victories", done = 0, total = 2 } } },
      m3 = { bars = {} },
    },
  }
  env.publisher = ns.PvPProgressPublisher.New({
    missions = {
      Progress = function(_, id)
        return env.progress[id]
      end,
    },
    season = {
      ActiveSeason = function()
        return env.season
      end,
      Missions = function()
        return env.missions
      end,
    },
    send = function(payload)
      env.sent[#env.sent + 1] = payload
      if env.sendResult == true then
        return true
      end
      return false, env.sendResult
    end,
    now = function()
      return env.clock
    end,
    schedule = function(delay, fn)
      env.timers[#env.timers + 1] = { delay = delay, fn = fn }
    end,
    random = function(min)
      return min
    end,
    isActive = function()
      return env.active
    end,
  })
  function env.fire()
    local timer = table.remove(env.timers, 1)
    timer.fn()
    return timer.delay
  end
  return env
end

describe("PvPProgressPublisher payload", function()
  it("lists the missions with something counted, never a manual one or one at zero", function()
    local env = build()
    assert.are.same({ seasonId = "s1", rows = { { missionId = "m1", count = 3, goal = 10 } } }, env.publisher:Payload())
  end)

  it("adds the class and race bars of one mission, and never counts past the goal", function()
    local env = build()
    env.progress.m1 =
      { bars = { { label = "Classes", done = 5, total = 8 }, { label = "Races", done = 2, total = 4 } } }
    assert.are.same({ missionId = "m1", count = 7, goal = 12 }, env.publisher:Payload().rows[1])
  end)

  it("has nothing without an active season", function()
    local env = build()
    env.season = nil
    assert.is_nil(env.publisher:Payload())
    env.season = { id = "s1", state = "closed" }
    assert.is_nil(env.publisher:Payload())
    assert.are.same({ false, "no_season" }, { env.publisher:Send() })
  end)
end)

describe("PvPProgressPublisher sending", function()
  it("sends once and then only what changed", function()
    local env = build()
    assert.is_true(env.publisher:Send())
    assert.are.same({ false, "unchanged" }, { env.publisher:Send() })
    assert.are.equal(1, #env.sent)
    env.progress.m1.bars[1].done = 4
    assert.is_true(env.publisher:Send())
    assert.are.equal(4, env.sent[2].rows[1].count)
  end)

  it("says nothing while nothing is counted, and clears the summary when the count goes back to zero", function()
    local env = build()
    env.progress.m1.bars[1].done = 0
    assert.are.same({ false, "empty" }, { env.publisher:Send() })
    env.progress.m1.bars[1].done = 3
    assert.is_true(env.publisher:Send())
    env.progress.m1.bars[1].done = 0
    assert.is_true(env.publisher:Send())
    assert.are.same({}, env.sent[2].rows)
  end)

  it("keeps what it has not sent when the transport refuses, and when it raises", function()
    local env = build()
    env.sendResult = "locked"
    assert.are.same({ false, "locked" }, { env.publisher:Send() })
    env.sendResult = true
    assert.is_true(env.publisher:Send())
    local raising = build()
    raising.publisher.deps.send = function()
      error("transport")
    end
    assert.are.same({ false, "error" }, { raising.publisher:Send() })
  end)
end)

describe("PvPProgressPublisher timing", function()
  it("plans one send after the minimum delay, however many changes arrive", function()
    local env = build()
    assert.is_true(env.publisher:Changed())
    assert.is_false(env.publisher:Changed())
    assert.are.equal(1, #env.timers)
    assert.are.equal(Constants.PVP_SYNC_MIN_DELAY_SECONDS, env.fire())
    assert.are.equal(1, #env.sent)
  end)

  it("waits out the interval after a send, and sends nothing when nothing changed", function()
    local env = build()
    env.publisher:Changed()
    env.fire()
    env.clock = env.clock + 30
    env.progress.m1.bars[1].done = 5
    env.publisher:Changed()
    assert.are.equal(Constants.PVP_PROGRESS_INTERVAL_SECONDS - 30, env.fire())
    assert.are.equal(2, #env.sent)
    env.clock = env.clock + Constants.PVP_PROGRESS_INTERVAL_SECONDS
    env.publisher:Changed()
    assert.are.equal(Constants.PVP_SYNC_MIN_DELAY_SECONDS, env.fire())
    assert.are.equal(2, #env.sent)
  end)

  it("tries again after the interval when the lockdown refused it, and stops when the addon is off", function()
    local env = build()
    env.sendResult = "locked"
    env.publisher:Changed()
    env.fire()
    assert.are.equal(1, #env.timers)
    env.sendResult = true
    assert.are.equal(Constants.PVP_PROGRESS_INTERVAL_SECONDS, env.fire())
    assert.are.equal(2, #env.sent)
    env.active = false
    assert.is_false(env.publisher:Changed())
    env.active = true
    env.publisher:Changed()
    env.active = false
    env.fire()
    assert.are.equal(2, #env.sent)
    assert.are.equal(0, #env.timers)
  end)

  it("sends the first summary a while after login", function()
    local env = build()
    env.publisher:SendAtLogin()
    assert.are.equal(Constants.PVP_LOGIN_SEND_DELAY_MIN, env.fire())
    assert.are.equal(1, #env.timers)
    env.fire()
    assert.are.equal(1, #env.sent)
  end)
end)
