-- The decisions of the Groups popup (UI/LfgPopup.lua), apart from its frame: when it shows, waits, closes and stays
-- closed, and what it draws.
local function load_controller()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/ProfileService",
    "Domain/LfgModel",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelGroups",
    "UI/LfgPopup",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.LfgPopup.Controller, ns
end

local Controller, ns = load_controller()

local function build(status, overrides)
  local env = { status = status, locked = false, shown = {}, hidden = 0, timers = {}, alerts = 0 }
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
  }
  for key, value in pairs(overrides or {}) do
    deps[key] = value
  end
  env.controller = Controller.New(deps)
  return env
end

local function leader_status(rows)
  local default = { { name = "Ann", role = "tank", state = "pending", at = 1 } }
  return { post = { pid = "mine", applicants = rows or default } }
end

local function applicant_status(state)
  return { application = { pid = "p-1", leader = "Kaelis", title = "Deadmines", role = "dps", state = state } }
end

describe("LfgPopup controller", function()
  it("shows nothing without an applicant or a notice", function()
    local env = build({})
    env.controller:Refresh()
    env.status = leader_status({ { name = "Ann", role = "dps", state = "invited", at = 1 } })
    env.controller:Refresh()
    env.status = nil
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
    assert.are.equal(0, env.hidden)
  end)

  it("asks the leader about a new applicant, with a sound, once", function()
    local env = build(leader_status())
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.is_truthy(env.shown[1].text:find("Ann wants to go as Tank", 1, true))
    assert.are.equal("Ann", env.shown[1].target)
    assert.are.equal(1, env.alerts)
  end)

  it("does not open a second popup for the same applicant", function()
    local env = build(leader_status())
    env.controller:Refresh()
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    assert.are.equal(1, env.alerts)
  end)

  it("moves on to the next applicant once the first is answered, with its own sound", function()
    local env = build(leader_status({
      { name = "Ann", role = "tank", state = "pending", at = 1 },
      { name = "Bob", role = "dps", state = "pending", at = 2 },
    }))
    env.controller:Refresh()
    env.status = leader_status({ { name = "Bob", role = "dps", state = "pending", at = 2 } })
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
    assert.are.equal("Bob", env.shown[2].target)
    assert.are.equal(2, env.alerts)
  end)

  it("closes when nobody is waiting any more", function()
    local env = build(leader_status())
    env.controller:Refresh()
    env.status = leader_status({})
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
    env.controller:Refresh()
    assert.are.equal(1, env.hidden)
  end)

  it("waits during the lockdown, once, and shows the popup afterwards", function()
    local env = build(leader_status())
    env.locked = true
    env.controller:Refresh()
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
    assert.are.equal(1, #env.timers)
    assert.are.equal(ns.Constants.LFG_POPUP_RETRY_SECONDS, env.timers[1].seconds)
    env.locked = false
    env.timers[1].fn()
    assert.are.equal(1, #env.shown)
    assert.are.equal(1, env.alerts)
  end)

  it("keeps trying while the lockdown lasts", function()
    local env = build(leader_status())
    env.locked = true
    env.controller:Refresh()
    env.timers[1].fn()
    assert.are.equal(0, #env.shown)
    assert.are.equal(2, #env.timers)
  end)

  it("stays closed after the player closes it, until another applicant comes", function()
    local env = build(leader_status())
    env.controller:Refresh()
    env.controller:Closed()
    env.controller:Refresh()
    assert.are.equal(1, #env.shown)
    env.status = leader_status({
      { name = "Ann", role = "tank", state = "pending", at = 1 },
    })
    env.status.post.applicants[1].name = "Bob"
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
  end)

  it("may show the same words again after they were over", function()
    local env = build(leader_status())
    env.controller:Refresh()
    env.controller:Closed()
    env.status = {}
    env.controller:Refresh()
    env.status = leader_status()
    env.controller:Refresh()
    assert.are.equal(2, #env.shown)
    assert.are.equal(2, env.alerts)
  end)

  it("remembers nothing to keep closed when nothing was shown", function()
    local env = build({})
    env.controller:Closed()
    assert.is_nil(env.controller.closedKey)
  end)

  it("tells an applicant that the leader accepted, then declined, without a sound", function()
    local env = build(applicant_status("invited"))
    env.controller:Refresh()
    assert.is_truthy(env.shown[1].text:find("Kaelis invited you", 1, true))
    assert.are.equal("close", env.shown[1].buttons[1].id)
    env.status = applicant_status("declined")
    env.controller:Refresh()
    assert.is_truthy(env.shown[2].text:find("Kaelis declined your application", 1, true))
    assert.are.equal(0, env.alerts)
  end)

  it("stays quiet while the application waits or after the applicant joined", function()
    local env = build(applicant_status("applied"))
    env.controller:Refresh()
    env.status = applicant_status("joined")
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
  end)

  it("keeps working when the sound raises", function()
    local env = build(leader_status(), {
      alert = function()
        error("sound")
      end,
    })
    assert.has_no.errors(function()
      env.controller:Refresh()
    end)
    assert.are.equal(1, #env.shown)
  end)

  it("works without a sound", function()
    local env = build(leader_status(), { alert = false })
    env.controller.deps.alert = nil
    assert.has_no.errors(function()
      env.controller:Refresh()
    end)
  end)

  it("hides when there is no view for the status", function()
    local env = build(leader_status(), {
      view = function() end,
    })
    env.controller:Refresh()
    assert.are.equal(0, #env.shown)
  end)
end)

describe("LfgPopup drawing", function()
  it("draws the text and one button per action, the first as the main one", function()
    local Kit = { made = {} }
    local function make(kind)
      return function(parent, opts)
        local node = { kind = kind, opts = opts, parent = parent }
        Kit.made[#Kit.made + 1] = node
        return node
      end
    end
    Kit.Label, Kit.Row, Kit.Button = make("Label"), make("Row"), make("Button")
    ns.Kit = Kit
    local pressed
    local view = ns.ViewModel.LfgPopupView({
      post = { pid = "p", applicants = { { name = "Ann", role = "heal", state = "pending", at = 1 } } },
    })
    ns.LfgPopup.Draw({}, view, function(id, shown)
      pressed = { id, shown.target }
    end)
    local buttons = {}
    for _, node in ipairs(Kit.made) do
      if node.kind == "Button" then
        buttons[#buttons + 1] = node
      end
    end
    assert.are.equal("Ann wants to go as Heal.", Kit.made[1].opts.text)
    assert.are.same({ "Invite", "Decline" }, { buttons[1].opts.text, buttons[2].opts.text })
    assert.are.same({ "primary", "secondary" }, { buttons[1].opts.variant, buttons[2].opts.variant })
    buttons[2].opts.onClick()
    assert.are.same({ "decline", "Ann" }, pressed)
  end)
end)

describe("LfgPopup without the frame", function()
  it("does nothing before it is started", function()
    assert.has_no.errors(function()
      ns.LfgPopup.Refresh()
    end)
  end)
end)
