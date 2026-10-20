-- Automatic sync (plan 0.1): the profile publishes itself on game events, a change made inside the cooldown is not
-- lost, and nothing is read or sent during a lockdown. Also the throttle behind the readiness redraws.
local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Domain/ProfileService",
    "Domain/PublishService",
    "Domain/AutoPublisher",
    "Domain/Throttle",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

-- A manual clock and scheduler.
local function timeline()
  local t = { now = 0, timers = {} }
  function t.schedule(delay, fn)
    t.timers[#t.timers + 1] = { at = t.now + delay, fn = fn }
  end
  -- Moves time forward and runs every timer that falls due, in order.
  function t.advance(seconds)
    local target = t.now + seconds
    while true do
      table.sort(t.timers, function(a, b)
        return a.at < b.at
      end)
      local first = t.timers[1]
      if not first or first.at > target then
        break
      end
      table.remove(t.timers, 1)
      t.now = first.at
      first.fn()
    end
    t.now = target
  end
  return t
end

describe("AutoPublisher", function()
  local clock, publisher, calls, result, locked

  before_each(function()
    clock = timeline()
    calls = { refresh = 0, publish = 0 }
    result = { true }
    locked = false
    publisher = ns.AutoPublisher.New({
      refresh = function()
        calls.refresh = calls.refresh + 1
      end,
      publish = function()
        calls.publish = calls.publish + 1
        return unpack(result)
      end,
      cooldownLeft = function()
        return 20
      end,
      schedule = clock.schedule,
      isLocked = function()
        return locked
      end,
      debounce = 3,
    })
  end)

  it("waits for the changes to settle, then refreshes and publishes once", function()
    publisher:Changed()
    clock.advance(1)
    publisher:Changed()
    publisher:Changed()
    clock.advance(1)
    assert.are.same({ refresh = 0, publish = 0 }, calls)
    clock.advance(1.5)
    assert.are.same({ refresh = 1, publish = 1 }, calls)
    assert.is_false(publisher:IsPending())
  end)

  it("keeps a single pending timer however many changes arrive", function()
    for _ = 1, 20 do
      publisher:Changed()
    end
    assert.are.equal(1, #clock.timers)
  end)

  it("retries once the cooldown ends when a change arrived inside it", function()
    result = { false, "cooldown" }
    publisher:Changed()
    clock.advance(3)
    assert.are.equal(1, calls.publish)
    assert.is_true(publisher:IsPending())
    -- More changes while the retry waits add no timer.
    publisher:Changed()
    publisher:Changed()
    assert.are.equal(1, #clock.timers)
    -- The cooldown is over and the publication goes through.
    result = { true }
    clock.advance(20)
    assert.are.equal(1, calls.publish)
    clock.advance(1)
    assert.are.equal(2, calls.publish)
    assert.are.equal(2, calls.refresh)
    assert.is_false(publisher:IsPending())
    clock.advance(100)
    assert.are.equal(2, calls.publish)
  end)

  it("keeps retrying while the cooldown is still on", function()
    result = { false, "cooldown" }
    publisher:Changed()
    clock.advance(3)
    clock.advance(21)
    assert.are.equal(2, calls.publish)
    assert.is_true(publisher:IsPending())
    result = { false, "unchanged" }
    clock.advance(21)
    assert.are.equal(3, calls.publish)
    assert.is_false(publisher:IsPending())
  end)

  it("does nothing during a lockdown, and tries again when it ends", function()
    locked = true
    publisher:Changed()
    clock.advance(3)
    assert.are.same({ refresh = 0, publish = 0 }, calls)
    assert.is_true(publisher:IsPending())
    clock.advance(5)
    assert.are.same({ refresh = 0, publish = 0 }, calls)
    locked = false
    clock.advance(5)
    assert.are.same({ refresh = 1, publish = 1 }, calls)
  end)

  it("runs at once for the login and the safety net, and reports what the publication said", function()
    result = { false, "unchanged" }
    assert.are.same({ false, "unchanged" }, { publisher:Run() })
    result = { true }
    assert.are.same({ true }, { publisher:Run() })
    assert.are.same({ refresh = 2, publish = 2 }, calls)
    locked = true
    assert.are.same({ false, "locked" }, { publisher:Run() })
  end)
end)

describe("PublishService.CooldownLeft", function()
  local function platform(now)
    return {
      ServerTime = function()
        return now
      end,
    }
  end

  it("says how long until the next publication is allowed", function()
    local limit = ns.Constants.PUBLISH_COOLDOWN_SECONDS
    assert.are.equal(0, ns.PublishService.CooldownLeft({ publish = {} }, platform(1000)))
    assert.are.equal(limit - 10, ns.PublishService.CooldownLeft({ publish = { at = 990 } }, platform(1000)))
    assert.are.equal(0, ns.PublishService.CooldownLeft({ publish = { at = 1 } }, platform(1000)))
  end)

  it("matches what Publish refuses: a change inside the cooldown, then the same change after it", function()
    local character = {
      profile = { class = "MAGE", level = 60 },
      publish = {},
    }
    local now = 1000
    local plat = {
      ServerTime = function()
        return now
      end,
    }
    local sent = 0
    local comm = {
      Send = function()
        sent = sent + 1
        return true
      end,
    }
    assert.is_true(ns.PublishService.PublishIfChanged(comm, character, plat))
    character.profile.level = 61
    now = now + 5
    assert.are.same({ false, "cooldown" }, { ns.PublishService.PublishIfChanged(comm, character, plat) })
    assert.are.equal(ns.Constants.PUBLISH_COOLDOWN_SECONDS - 5, ns.PublishService.CooldownLeft(character, plat))
    now = now + ns.PublishService.CooldownLeft(character, plat)
    assert.is_true(ns.PublishService.PublishIfChanged(comm, character, plat))
    assert.are.equal(2, sent)
  end)
end)

describe("Throttle", function()
  it("runs at once, postpones a call that comes too soon once, and the last state wins", function()
    local clock = timeline()
    local runs = 0
    local throttle = ns.Throttle.New({
      run = function()
        runs = runs + 1
      end,
      now = function()
        return clock.now
      end,
      schedule = clock.schedule,
      interval = 1,
    })
    assert.is_true(throttle:Call())
    assert.are.equal(1, runs)
    clock.advance(0.2)
    assert.is_false(throttle:Call())
    throttle:Call()
    throttle:Call()
    assert.are.equal(1, #clock.timers)
    assert.are.equal(1, runs)
    clock.advance(0.9)
    assert.are.equal(2, runs)
    clock.advance(5)
    assert.are.equal(2, runs)
    assert.is_true(throttle:Call())
    assert.are.equal(3, runs)
  end)
end)
