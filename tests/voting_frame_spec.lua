local function load_controller()
  local ns = { UI = { lootListeners = {} } }
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/VotingFrame.lua"))("NrageAssistant", ns)
  return ns.VotingFrame.Controller, ns
end

local Controller, ns = load_controller()

-- Fakes only what the window touches: which sessions are open, the role, the lockdown, the timer and the
-- three frame actions.
local function build(open_ids)
  local env = { ids = open_ids, canVote = true, locked = false, opened = {}, updates = 0, closes = 0, timers = {} }
  env.controller = Controller.New({
    openSessionIds = function()
      return env.ids
    end,
    canVote = function()
      return env.canVote
    end,
    isLockedDown = function()
      return env.locked
    end,
    after = function(seconds, fn)
      env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
    end,
    open = function(fresh)
      env.opened[#env.opened + 1] = fresh
    end,
    update = function()
      env.updates = env.updates + 1
    end,
    close = function()
      env.closes = env.closes + 1
    end,
  })
  return env
end

describe("VotingFrame controller", function()
  it("is hooked to the loot change notification", function()
    assert.are.equal(ns.VotingFrame.Refresh, ns.UI.lootListeners[1])
  end)

  it("opens for a session that opens after it started, once", function()
    local env = build({ "s1" })
    env.controller:Prime()
    env.controller:Refresh()
    assert.are.equal(0, #env.opened)
    assert.are.equal(1, env.updates)

    env.ids = { "s1", "s2" }
    env.controller:Refresh()
    assert.are.same({ { "s2" } }, env.opened)

    env.controller:Refresh()
    assert.are.equal(1, #env.opened)
  end)

  it("does not open for someone who may not vote, and closes a window they had", function()
    local env = build({})
    env.canVote = false
    env.ids = { "s1" }
    env.controller:Refresh()
    assert.are.equal(0, #env.opened)
    assert.are.equal(1, env.closes)
  end)

  it("waits out a lockdown, then opens", function()
    local env = build({})
    env.ids = { "s1" }
    env.locked = true
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(0, #env.opened)
    assert.are.equal(1, #env.timers)
    assert.are.equal(5, env.timers[1].seconds)

    env.timers[1].fn()
    assert.are.equal(0, #env.opened)
    assert.are.equal(2, #env.timers)

    env.locked = false
    env.timers[2].fn()
    assert.are.same({ { "s1" } }, env.opened)
  end)

  it("opens once for several sessions that arrive together", function()
    local env = build({})
    env.ids = { "s1", "s2" }
    env.controller:Refresh()
    assert.are.same({ { "s1", "s2" } }, env.opened)
  end)
end)

describe("VotingFrame controller redraw limit", function()
  local function throttled(open)
    local env = { clock = 10, updates = 0, timers = {}, open = open ~= false }
    env.controller = Controller.New({
      openSessionIds = function()
        return {}
      end,
      canVote = function()
        return true
      end,
      isLockedDown = function()
        return false
      end,
      after = function(seconds, fn)
        env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
      end,
      open = function() end,
      update = function()
        env.updates = env.updates + 1
      end,
      close = function() end,
      isOpen = function()
        return env.open
      end,
      now = function()
        return env.clock
      end,
    })
    return env
  end

  it("redraws at once the first time, then postpones a redraw that comes too soon", function()
    local env = throttled()
    env.controller:Refresh()
    assert.are.equal(1, env.updates)

    env.clock = 10.05
    env.controller:Refresh()
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(1, env.updates)
    assert.are.equal(1, #env.timers)
    assert.is_true(env.timers[1].seconds > 0 and env.timers[1].seconds <= 0.2)
  end)

  it("draws the latest state once when the postponed redraw fires, and not before", function()
    local env = throttled()
    env.controller:Refresh()
    env.clock = 10.05
    env.controller:Refresh()
    env.clock = 10.25
    env.timers[1].fn()
    assert.are.equal(2, env.updates)
    assert.are.equal(1, #env.timers)
  end)

  it("redraws normally once enough time has passed", function()
    local env = throttled()
    env.controller:Refresh()
    env.clock = 11
    env.controller:Refresh()
    assert.are.equal(2, env.updates)
    assert.are.equal(0, #env.timers)
  end)

  it("does nothing for a window that is not open", function()
    local env = throttled(false)
    env.controller:Refresh()
    assert.are.equal(0, env.updates)
  end)
end)
