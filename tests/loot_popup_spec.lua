local function load_controller()
  local ns = { UI = { lootListeners = {} } }
  assert(loadfile("NrageAssistant/UI/LootPopup.lua"))("NrageAssistant", ns)
  return ns.LootPopup.Controller, ns
end

local Controller, ns = load_controller()

-- Fakes only what the popup touches: what is waiting, the lockdown, the timer and the two frame actions.
local function build(waiting)
  local env = { waiting = waiting, locked = false, shown = {}, hidden = 0, timers = {} }
  env.controller = Controller.New({
    pending = function(dismissed)
      local list = {}
      for _, entry in ipairs(env.waiting) do
        if not dismissed[entry.sessionId] then
          list[#list + 1] = entry
        end
      end
      return list
    end,
    isLockedDown = function()
      return env.locked
    end,
    after = function(seconds, fn)
      env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
    end,
    show = function(entries)
      env.shown[#env.shown + 1] = entries
    end,
    hide = function()
      env.hidden = env.hidden + 1
    end,
  })
  return env
end

local function entry(id)
  return { sessionId = id, itemName = "Item " .. id, eventTitle = "Raid" }
end

describe("LootPopup controller", function()
  it("is hooked to the loot change notification", function()
    assert.are.equal(ns.LootPopup.Refresh, ns.UI.lootListeners[1])
  end)

  it("shows what is waiting for an answer", function()
    local env = build({ entry("s1"), entry("s2") })
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.are.equal(2, #env.shown[1])
  end)

  it("does not rebuild while the list of waiting items is the same", function()
    local env = build({ entry("s1") })
    env.controller:Refresh()
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
  end)

  it("rebuilds when an item arrives or one is answered, and closes when none is left", function()
    local env = build({ entry("s1") })
    env.controller:Refresh()
    env.waiting[#env.waiting + 1] = entry("s2")
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)

    env.controller:Dismiss("s1")
    env.controller:Refresh()
    assert.are.equal(3, #env.shown)
    assert.are.equal("s2", env.shown[3][1].sessionId)

    env.controller:Dismiss("s2")
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
  end)

  it("never shows during a lockdown: it waits, then shows once the lockdown is over", function()
    local env = build({ entry("s1") })
    env.locked = true
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
    assert.are.equal(1, #env.timers)
    assert.are.equal(5, env.timers[1].seconds)

    env.timers[1].fn()
    assert.are.equal(0, #env.shown)
    assert.are.equal(2, #env.timers)

    env.locked = false
    env.timers[2].fn()
    assert.are.equal(1, #env.shown)
  end)

  it("does not offer again what was passed on, even if it is still open", function()
    local env = build({ entry("s1") })
    env.controller:Dismiss("s1")
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
  end)

  it("lets a closed window be reopened by a new item", function()
    local env = build({ entry("s1") })
    env.controller:Refresh()
    env.controller:Hide()
    env.controller:Dismiss("s1")
    env.waiting[#env.waiting + 1] = entry("s2")
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
    assert.are.equal("s2", env.shown[2][1].sessionId)
  end)
end)

describe("LootPopup controller countdown", function()
  local function counting(waiting, timeout)
    local env = { waiting = waiting, clock = 100, shown = {}, hidden = 0, timers = {}, statuses = {} }
    env.controller = Controller.New({
      pending = function(dismissed)
        local list = {}
        for _, entry in ipairs(env.waiting) do
          if not dismissed[entry.sessionId] then
            list[#list + 1] = entry
          end
        end
        return list
      end,
      isLockedDown = function()
        return env.locked == true
      end,
      after = function(seconds, fn)
        env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
      end,
      show = function(entries)
        env.shown[#env.shown + 1] = entries
      end,
      hide = function()
        env.hidden = env.hidden + 1
      end,
      now = function()
        return env.clock
      end,
      timeout = timeout,
      status = function(text)
        env.statuses[#env.statuses + 1] = text
      end,
    })
    function env.tick()
      table.remove(env.timers, 1).fn()
    end
    return env
  end

  it("counts down once the popup is shown and says how long is left", function()
    local env = counting({ entry("s1") }, 60)
    env.controller:Refresh()
    assert.are.equal(1, #env.timers)
    assert.are.equal(1, env.timers[1].seconds)

    env.clock = 110
    env.tick()
    assert.are.equal("Passing on the next item in 50 s unless you answer.", env.statuses[1])
    assert.are.equal(1, #env.timers)
  end)

  it("passes on an item nobody answered, which closes the popup when none is left", function()
    local env = counting({ entry("s1") }, 60)
    env.controller:Refresh()
    env.clock = 161
    env.tick()
    assert.are.equal(1, env.hidden)
    assert.is_true(env.controller.dismissed.s1)
  end)

  it("times each item from when it was first shown, not from when the others were", function()
    local env = counting({ entry("s1") }, 60)
    env.controller:Refresh()
    env.clock = 140
    env.waiting[#env.waiting + 1] = entry("s2")
    env.controller:Refresh()
    env.clock = 165
    env.tick()
    assert.is_true(env.controller.dismissed.s1)
    assert.is_nil(env.controller.dismissed.s2)
    assert.are.equal("s2", env.shown[#env.shown][1].sessionId)
  end)

  it("does not count a lockdown, because nothing is shown then", function()
    local env = counting({ entry("s1") }, 60)
    env.locked = true
    env.controller:Refresh()
    env.clock = 500
    env.locked = false
    env.tick()
    env.controller:Refresh()
    env.clock = 530
    env.tick()
    assert.is_nil(env.controller.dismissed.s1)
  end)

  it("does nothing without a timeout", function()
    local env = counting({ entry("s1") }, nil)
    env.controller:Refresh()
    assert.are.equal(0, #env.timers)
  end)
end)
