local function load_controller()
  local ns = { UI = { lootListeners = {} } }
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
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
        for _, waiting_entry in ipairs(env.waiting) do
          if not dismissed[waiting_entry.sessionId] then
            list[#list + 1] = waiting_entry
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

describe("LootPopup session bookkeeping", function()
  it("forgets the sessions that do not exist any more", function()
    local env = build({ entry("s1"), entry("s2") })
    env.controller:Dismiss("s1")
    env.controller:Dismiss("gone")
    env.controller.firstShown.gone = 5
    env.controller.firstShown.s2 = 6
    env.controller:Prune({ s1 = true, s2 = true })
    assert.is_true(env.controller.dismissed.s1)
    assert.is_nil(env.controller.dismissed.gone)
    assert.is_nil(env.controller.firstShown.gone)
    assert.are.equal(6, env.controller.firstShown.s2)
  end)

  it("moves the footer and the bars of a drawn popup without drawing it again", function()
    local texts, values = {}, {}
    local refs = {
      footer = {
        SetText = function(_, text)
          texts[#texts + 1] = text
        end,
      },
      bars = {
        {
          sessionId = "s1",
          bar = {
            SetValue = function(_, value)
              values[#values + 1] = value
            end,
          },
        },
        {
          sessionId = "s2",
          bar = {
            SetValue = function()
              error("no time left for s2")
            end,
          },
        },
      },
    }
    ns.LootPopup.UpdateCountdown(refs, "soon", function(id)
      return id == "s1" and 15 or nil
    end, 60)
    assert.are.same({ "soon" }, texts)
    assert.are.same({ 0.25 }, values)
    assert.has_no.errors(function()
      ns.LootPopup.UpdateCountdown(nil, "x", function() end, 60)
    end)
  end)

  it("moves the bar with its setter and never lays it out again", function()
    local calls = {}
    local bar = {
      SetValue = function(_, value)
        calls[#calls + 1] = value
      end,
      Layout = function()
        error("the countdown must not lay the bar out")
      end,
    }
    local refs = { bars = { { sessionId = "s1", bar = bar } } }
    ns.LootPopup.UpdateCountdown(refs, nil, function()
      return 30
    end, 60)
    assert.are.same({ 0.5 }, calls)
  end)
end)

describe("LootPopup.Pending", function()
  local Roles = dofile("tests/support/roles.lua")

  local function rosterEvent(id, rosterId)
    return {
      eventId = id,
      title = id,
      rosterId = rosterId,
      loot = { [id] = { sessionId = id, itemName = "Item " .. id, status = "open", candidates = {}, votes = {} } },
    }
  end

  local function buildFor(rank)
    local fresh = { UI = { lootListeners = {} } }
    for _, path in ipairs({
      "Core/Constants",
      "Core/Locale",
      "Core/Validate",
      "Domain/PermissionService",
      "Domain/RosterService",
      "Domain/EventModel",
      "Domain/EventService",
      "Domain/LootModel",
      "Domain/LootService",
      "UI/Kit/Theme",
      "UI/Kit/Util",
      "UI/Kit/Calendar",
      "UI/ViewModel",
      "UI/LootPopup",
    }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", fresh)
    end
    local members, rosters = Roles.assignments(rank, "Me-Realm")
    rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
    fresh.db = {
      global = {
        members = members,
        rosters = rosters,
        events = { own = rosterEvent("own", "r1"), other = rosterEvent("other", "r2") },
      },
    }
    fresh.Platform = {
      GetIdentityKey = function()
        return "Me-Realm"
      end,
      GetOwnGuildRank = Roles.ranking(rank),
    }
    return fresh
  end

  local function ids(list)
    local out = {}
    for _, item in ipairs(list) do
      out[#out + 1] = item.sessionId
    end
    table.sort(out)
    return out
  end

  it("never asks a member or an alter", function()
    for _, rank in ipairs({ "Member", "Alter" }) do
      assert.are.same({}, ids(buildFor(rank).LootPopup.Pending({})), rank)
    end
  end)

  it("asks roster, rl and officer about the sessions of the own roster only", function()
    for _, rank in ipairs({ "Roster", "RL", "Officer" }) do
      assert.are.same({ "own" }, ids(buildFor(rank).LootPopup.Pending({})), rank)
    end
  end)

  it("asks the guild master and the co-guild master about every roster", function()
    for _, rank in ipairs({ "GM", "CoGM" }) do
      assert.are.same({ "other", "own" }, ids(buildFor(rank).LootPopup.Pending({})), rank)
    end
  end)

  it("leaves out what was dismissed", function()
    assert.are.same({}, ids(buildFor("Roster").LootPopup.Pending({ own = true })))
  end)
end)
