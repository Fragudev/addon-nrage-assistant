local function load_controller()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/LayerModel",
    "UI/ViewModel",
    "UI/ViewModelLayers",
    "UI/LayerPopup",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.LayerPopup.Controller, ns
end

local Controller, ns = load_controller()

local function build(status, overrides)
  local env = { status = status, locked = false, shown = {}, hidden = 0, timers = {}, alerts = 0, countdowns = {} }
  local deps = {
    status = function()
      return env.status
    end,
    isLockedDown = function()
      return env.locked
    end,
    after = function(seconds, fn)
      env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
    end,
    show = function(view)
      env.shown[#env.shown + 1] = view
    end,
    hide = function()
      env.hidden = env.hidden + 1
    end,
    alert = function()
      env.alerts = env.alerts + 1
    end,
    countdown = function(text)
      env.countdowns[#env.countdowns + 1] = text
    end,
  }
  for key, value in pairs(overrides or {}) do
    deps[key] = value
  end
  env.controller = Controller.New(deps)
  return env
end

local function helper_status(overrides)
  local status = { rid = "r1", role = "helper", stage = "request", requester = "Ann", map = 0, layer = 1234 }
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function requester_status(overrides)
  local status = { rid = "r1", role = "requester", stage = "request", map = 0, layer = 1234, left = 42.2 }
  for key, value in pairs(overrides or {}) do
    status[key] = value
  end
  return status
end

local function ids(view)
  local list = {}
  for _, button in ipairs(view.buttons) do
    list[#list + 1] = button.id
  end
  return table.concat(list, ",")
end

describe("LayerPopup controller", function()
  it("shows nothing without a swap", function()
    local env = build(nil)
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
    assert.are.equal(0, env.hidden)
  end)

  it("asks a helper for help, with a sound, once", function()
    local env = build(helper_status())
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.are.equal("help,ignore", ids(env.shown[1]))
    assert.is_truthy(env.shown[1].text:find("Ann wants to join your layer", 1, true))
    assert.are.equal(1, env.alerts)
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.are.equal(1, env.alerts)
  end)

  it("does not alert again for a later step of the same request", function()
    local env = build(helper_status())
    env.controller:Refresh()
    env.status = helper_status({ stage = "assigned" })
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
    assert.are.equal("invite,decline", ids(env.shown[2]))
    assert.are.equal(1, env.alerts)
  end)

  it("keeps working when the alert raises", function()
    local env = build(helper_status(), {
      alert = function()
        error("sound")
      end,
    })
    assert.has_no.errors(function()
      env.controller:Refresh()
    end)
    assert.are.equal(1, #env.shown)
  end)

  it("follows the requester step by step", function()
    local env = build(requester_status())
    env.controller:Refresh()
    assert.are.equal("cancel", ids(env.shown[1]))
    env.status = requester_status({ stage = "assign", helper = "Bob" })
    env.controller:Refresh()
    assert.is_truthy(env.shown[2].text:find("Bob will invite you", 1, true))
    env.status = requester_status({ stage = "joined", joined = true })
    env.controller:Refresh()
    assert.are.equal("leave,cancel", ids(env.shown[3]))
    env.status = requester_status({ stage = "done", outcome = "done", left = nil })
    env.controller:Refresh()
    assert.are.equal("leave", ids(env.shown[4]))
    assert.is_truthy(env.shown[4].text:find("Layer changed", 1, true))
    assert.are.equal(0, env.alerts)
  end)

  it("closes when the swap ends or the helper hides it", function()
    local env = build(helper_status())
    env.controller:Refresh()
    env.status = helper_status({ hidden = true })
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
    env.status = nil
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
  end)

  it("shows the time left and counts down without rebuilding the frame", function()
    local env = build(requester_status())
    env.controller:Refresh()
    assert.are.equal("43 s left", env.countdowns[1])
    assert.are.equal(1, #env.timers)
    assert.are.equal(1, env.timers[1].seconds)
    env.status = requester_status({ left = 41 })
    env.timers[1].fn()
    assert.are.equal(1, #env.shown)
    assert.are.equal("41 s left", env.countdowns[2])
    assert.are.equal(2, #env.timers)
  end)

  it("does not tick when there is no countdown", function()
    local env = build(helper_status())
    env.controller:Refresh()
    assert.are.equal(0, #env.timers)
  end)

  it("waits during the lockdown and shows the popup afterwards", function()
    local env = build(helper_status())
    env.locked = true
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
    assert.are.equal(1, #env.timers)
    assert.are.equal(ns.Constants.LAYER_POPUP_RETRY_SECONDS, env.timers[1].seconds)
    env.locked = false
    env.timers[1].fn()
    assert.are.equal(1, #env.shown)
  end)

  it("stays closed after the player closes it, until the swap moves on", function()
    local env = build(helper_status())
    env.controller:Refresh()
    env.controller:Closed()
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    env.status = helper_status({ stage = "assigned" })
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
  end)

  it("remembers nothing to keep closed when the swap is gone", function()
    local env = build(nil)
    env.controller:Closed()
    assert.is_nil(env.controller.closedKey)
  end)

  it("hides when there is no view for the status", function()
    local env = build(helper_status(), {
      view = function() end,
    })
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
  end)

  it("uses the view model by default", function()
    local env = build(helper_status())
    env.controller:Refresh()
    assert.are.equal("Layer swap", env.shown[1].title)
  end)
end)

describe("LayerPopup without the frame", function()
  it("does nothing before it is started", function()
    assert.has_no.errors(function()
      ns.LayerPopup.Refresh()
    end)
  end)
end)
