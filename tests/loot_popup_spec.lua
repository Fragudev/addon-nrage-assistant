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
