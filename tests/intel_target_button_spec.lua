-- The Kill on Sight button by the target frame: what it shows is decided by a pure function, and the frame is built
-- with the real kit on fake frames.
local FakeFrames = dofile("tests/support/fake_frames.lua")

local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/Settings",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/GuildKosService",
    "Domain/IntelReport",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
    "UI/Kit/Shape",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/Kit/Icons",
    "UI/Kit/Core",
    "UI/Kit/Text",
    "UI/Kit/Controls",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelIntel",
    "UI/IntelTargetButton",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Button = ns.IntelTargetButton

describe("IntelTargetButton.State", function()
  local details = { name = "Ann-Realm", class = "MAGE" }

  it("is hidden unless the setting is on and the target is an enemy player", function()
    assert.is_false(Button.State({ enabled = false, details = details }).visible)
    assert.is_false(Button.State({ enabled = true, details = nil }).visible)
    assert.is_false(Button.State({ enabled = true, details = { name = 5 } }).visible)
    assert.is_false(Button.State({ enabled = true, details = { name = "a|b" } }).visible)
  end)

  it("says what a click does", function()
    local plain = Button.State({ enabled = true, details = details })
    assert.is_true(plain.visible)
    assert.are.equal("Ann", plain.name)
    assert.are.equal("Add to my Kill on Sight list", plain.tooltip)
    assert.are.equal(
      "Remove from my Kill on Sight list",
      Button.State({ enabled = true, details = details, kos = "personal" }).tooltip
    )
    assert.are.equal(
      "On the guild list. Click to add to yours.",
      Button.State({ enabled = true, details = details, kos = "guild" }).tooltip
    )
  end)
end)

describe("IntelTargetButton on fake frames", function()
  local NAMES = { "CreateFrame", "TargetFrame", "print", "UIParent" }
  local saved = {}
  local env

  before_each(function()
    FakeFrames.install()
    for _, name in ipairs(NAMES) do
      saved[name] = _G[name]
    end
    Button.Reset()
    env = { combat = false, target = { name = "Ann-Realm" }, said = {}, registered = {}, menu = {} }
    _G.TargetFrame = CreateFrame("Frame", "TargetFrame")
    _G.print = function(text)
      env.said[#env.said + 1] = text
    end
    ns.active = true
    ns.db = { global = {} }
    ns.intel = ns.IntelService.New({
      intel = { players = {}, kos = {}, ignore = {}, zones = {} },
      guildKos = {},
      settings = function()
        return { removeMinutes = 5 }
      end,
      now = function()
        return 100
      end,
      wall = function()
        return 1000
      end,
    })
    ns.intelCommands = {
      KosAdd = function(_, name)
        ns.intel:AddKos({ name = name })
        return { "added " .. name }
      end,
      KosRemove = function(_, name)
        ns.intel:RemoveKos(ns.IntelModel.Key(name))
        return { "removed " .. name }
      end,
    }
    ns.Platform = {
      IsInCombat = function()
        return env.combat
      end,
      GetEnemyDetails = function(unit)
        assert.are.equal("target", unit)
        return env.target
      end,
      TryRegisterEvent = function(frame, event)
        env.registered[event] = frame
        return true
      end,
      AddEnemyPlayerMenuEntry = function(label, onPick)
        env.menu = { label = label, onPick = onPick }
        return true
      end,
    }
  end)

  after_each(function()
    FakeFrames.uninstall()
    for _, name in ipairs(NAMES) do
      _G[name] = saved[name]
    end
    Button.Reset()
  end)

  local function shown()
    local button = Button.Widget()
    return button ~= nil and button.frame:IsShown() == true
  end

  it("shows by the target frame for an enemy target and toggles his mark", function()
    assert.is_nil(Button.Widget())
    Button.Refresh()
    local button = Button.Widget()
    assert.is_true(shown())
    assert.are.equal("Ann", Button.LastName())
    assert.are.equal(TargetFrame, button.frame.points[1][2])
    assert.are.equal("Add to my Kill on Sight list", button.opts.tooltip)
    assert.is_nil(button.opts.color)

    button.opts.onClick()
    assert.are.equal("personal", ns.intel:IsKos("Ann"))
    assert.are.same({ "Nrage Assistant: added Ann" }, env.said)
    assert.are.equal("danger", button.opts.color)
    assert.are.equal("Remove from my Kill on Sight list", button.opts.tooltip)
    button.opts.onClick()
    assert.is_nil(ns.intel:IsKos("Ann"))
    assert.is_nil(button.opts.color)
  end)

  it("is anchored once, and stays out of the parent frame", function()
    Button.Refresh()
    Button.Refresh()
    local button = Button.Widget()
    assert.are.equal(1, #button.frame.points)
    assert.are_not.equal(TargetFrame, button.frame.parent)
  end)

  it("hides when the target is not an enemy player, the setting is off, or Intel is not running", function()
    Button.Refresh()
    assert.is_true(shown())
    env.target = nil
    Button.Refresh()
    assert.is_false(shown())
    env.target = { name = "Ann" }
    Button.Refresh()
    assert.is_true(shown())
    ns.db.global.settings.intel.targetButton = false
    Button.Refresh()
    assert.is_false(shown())
    ns.db.global.settings.intel.targetButton = true
    ns.intel = nil
    Button.Refresh()
    assert.is_false(shown())
    -- Nothing to hide before it was ever shown.
    Button.Reset()
    assert.has_no.errors(Button.Refresh)
    assert.is_nil(Button.Widget())
  end)

  it("waits for the end of combat to anchor to the target frame", function()
    env.combat = true
    Button.Refresh()
    assert.is_false(shown())
    assert.are.equal(0, #Button.Widget().frame.points)
    env.combat = false
    Button.Refresh()
    assert.is_true(shown())
    assert.are.equal(1, #Button.Widget().frame.points)
  end)

  it("cannot anchor without a target frame", function()
    _G.TargetFrame = nil
    Button.Refresh()
    assert.is_false(shown())
  end)

  it("does nothing when clicked while the target is no enemy or the commands are missing", function()
    Button.Refresh()
    env.target = nil
    Button.Widget().opts.onClick()
    assert.are.same({}, env.said)
    env.target = { name = "Ann" }
    ns.intelCommands = nil
    Button.Widget().opts.onClick()
    assert.are.same({}, env.said)
  end)

  it("listens for target changes and the end of combat, and adds the menu entry", function()
    Button.Start()
    assert.is_truthy(env.registered.PLAYER_TARGET_CHANGED)
    assert.are.equal(env.registered.PLAYER_TARGET_CHANGED, env.registered.PLAYER_REGEN_ENABLED)
    local frame = env.registered.PLAYER_TARGET_CHANGED
    Button.Start()
    frame.scripts.OnEvent()
    assert.is_true(shown())

    assert.are.equal("Add to my Kill on Sight list", env.menu.label("Bob"))
    env.menu.onPick("Bob")
    assert.are.equal("personal", ns.intel:IsKos("Bob"))
    assert.are.equal("Remove from my Kill on Sight list", env.menu.label("Bob"))
    env.menu.onPick("Bob")
    assert.is_nil(ns.intel:IsKos("Bob"))
    assert.are.same({ "Nrage Assistant: added Bob", "Nrage Assistant: removed Bob" }, env.said)
    env.menu.onPick("a|b")
    ns.intel = nil
    assert.are.equal("Add to my Kill on Sight list", env.menu.label("Bob"))
    env.menu.onPick("Bob")
    assert.has_no.errors(function()
      frame.scripts.OnEvent()
    end)
  end)
end)
