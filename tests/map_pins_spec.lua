local FakeFrames = dofile("tests/support/fake_frames.lua")

local function load_pins()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Domain/LayerModel",
    "UI/MapPins",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_pins()
local MapPins, Constants = ns.MapPins, ns.Constants

local function pin(name, overrides)
  local value = { key = name, name = name, class = "MAGE", level = 60, map = 1411, x = 0.5, y = 0.25, age = 12 }
  for key, item in pairs(overrides or {}) do
    value[key] = item
  end
  return value
end

local function fake_hbd()
  local hbd = { calls = {} }
  for _, method in ipairs({
    "RemoveAllMinimapIcons",
    "RemoveAllWorldMapIcons",
    "AddMinimapIconMap",
    "AddWorldMapIconMap",
  }) do
    hbd[method] = function(_, ...)
      hbd.calls[#hbd.calls + 1] = { method, ... }
    end
  end
  return hbd
end

local function count(hbd, method)
  local total = 0
  for _, call in ipairs(hbd.calls) do
    if call[1] == method then
      total = total + 1
    end
  end
  return total
end

local function build(overrides)
  local env = { hbd = fake_hbd(), built = {}, dressed = {}, timers = {}, clock = 100 }
  local deps = {
    hbd = env.hbd,
    ref = "ref",
    newPin = function(kind)
      local frame = { kind = kind }
      env.built[#env.built + 1] = frame
      return frame
    end,
    dress = function(frame, value)
      env.dressed[#env.dressed + 1] = { frame = frame, pin = value }
    end,
    worldFlag = "FLAG",
    now = function()
      return env.clock
    end,
    after = function(seconds, fn)
      env.timers[#env.timers + 1] = { seconds = seconds, fn = fn }
    end,
    pins = function()
      return env.pins
    end,
    settings = function()
      return env.settings
    end,
  }
  for key, value in pairs(overrides or {}) do
    deps[key] = value
  end
  env.pins = { pin("Ann") }
  env.settings = { minimap = true, worldmap = true }
  env.controller = MapPins.Controller.New(deps)
  return env
end

describe("MapPins.Controller:Redraw", function()
  it("does nothing without the library", function()
    local env = build({ hbd = false })
    assert.is_nil(env.controller:Redraw({ pin("Ann") }, { minimap = true, worldmap = true }))
    assert.are.same({}, env.built)
    env.controller:Request()
    assert.are.same({}, env.timers)
  end)

  it("removes every icon, then adds one per pin on each enabled map", function()
    local env = build()
    assert.are.equal(2, env.controller:Redraw({ pin("Ann"), pin("Bob", { map = 1412, x = 1, y = 0 }) }, env.settings))
    local calls = env.hbd.calls
    assert.are.same({ "RemoveAllMinimapIcons", "ref" }, calls[1])
    assert.are.same({ "RemoveAllWorldMapIcons", "ref" }, calls[2])
    assert.are.equal(2, count(env.hbd, "AddMinimapIconMap"))
    assert.are.equal(2, count(env.hbd, "AddWorldMapIconMap"))
    assert.are.same({ "AddMinimapIconMap", "ref", env.built[1], 1411, 0.5, 0.25, true, true }, calls[3])
    assert.are.same({ "AddWorldMapIconMap", "ref", env.built[2], 1411, 0.5, 0.25, "FLAG" }, calls[4])
  end)

  it("draws only on the maps the settings enable", function()
    local env = build()
    env.controller:Redraw({ pin("Ann") }, { minimap = true, worldmap = false })
    assert.are.equal(1, count(env.hbd, "AddMinimapIconMap"))
    assert.are.equal(0, count(env.hbd, "AddWorldMapIconMap"))
    env.hbd.calls = {}
    env.controller:Redraw({ pin("Ann") }, { minimap = false, worldmap = true })
    assert.are.equal(0, count(env.hbd, "AddMinimapIconMap"))
    assert.are.equal(1, count(env.hbd, "AddWorldMapIconMap"))
    env.hbd.calls = {}
    env.controller:Redraw({ pin("Ann") }, { minimap = false, worldmap = false })
    assert.are.equal(0, count(env.hbd, "AddMinimapIconMap") + count(env.hbd, "AddWorldMapIconMap"))
    assert.are.equal(1, count(env.hbd, "RemoveAllMinimapIcons"))
  end)

  it("reuses the frames it built", function()
    local env = build()
    env.controller:Redraw({ pin("Ann"), pin("Bob") }, env.settings)
    local built = #env.built
    assert.are.equal(4, built)
    env.controller:Redraw({ pin("Ann"), pin("Bob") }, env.settings)
    env.controller:Redraw({ pin("Cid") }, env.settings)
    assert.are.equal(built, #env.built)
  end)

  it("never draws more pins than the directory holds", function()
    local env = build()
    local pins = {}
    for i = 1, Constants.POSITION_DIRECTORY_MAX + 20 do
      pins[i] = pin("Member" .. i)
    end
    assert.are.equal(Constants.POSITION_DIRECTORY_MAX, env.controller:Redraw(pins, env.settings))
    assert.are.equal(Constants.POSITION_DIRECTORY_MAX * 2, #env.built)
  end)

  it("dresses each frame with its pin", function()
    local env = build()
    env.controller:Redraw({ pin("Ann") }, env.settings)
    assert.are.equal("Ann", env.dressed[1].pin.name)
    assert.are.equal(env.built[1], env.dressed[1].frame)
  end)
end)

describe("MapPins.Controller:Request", function()
  it("redraws once, however many changes ask for it", function()
    local env = build()
    env.controller:Request()
    env.controller:Request()
    env.controller:Request()
    assert.are.equal(1, #env.timers)
    assert.are.equal(0, env.timers[1].seconds)
    env.timers[1].fn()
    assert.are.equal(1, count(env.hbd, "RemoveAllMinimapIcons"))
    assert.are.equal(1, count(env.hbd, "AddMinimapIconMap"))
  end)

  it("waits for the end of the interval after a redraw", function()
    local env = build()
    env.controller:Request()
    env.timers[1].fn()
    env.clock = env.clock + 0.25
    env.controller:Request()
    assert.are.equal(2, #env.timers)
    assert.are.near(Constants.POSITION_REDRAW_SECONDS - 0.25, env.timers[2].seconds, 0.0001)
    env.timers[2].fn()
    env.clock = env.clock + 10
    env.controller:Request()
    assert.are.equal(0, env.timers[3].seconds)
  end)

  it("draws what the pins and the settings say when the timer fires", function()
    local env = build()
    env.controller:Request()
    env.settings = { minimap = false, worldmap = true }
    env.pins = { pin("Ann"), pin("Bob") }
    env.timers[1].fn()
    assert.are.equal(0, count(env.hbd, "AddMinimapIconMap"))
    assert.are.equal(2, count(env.hbd, "AddWorldMapIconMap"))
  end)
end)

describe("MapPins.TooltipLines", function()
  it("lists the level, the layer and the age", function()
    local lines = MapPins.TooltipLines(pin("Ann", { layer = 123456, sameLayer = true }))
    assert.are.same({
      { text = "Level 60" },
      { text = "Layer #3456", green = true },
      { text = "12 s ago" },
    }, lines)
  end)

  it("does not paint another layer green, and leaves out what is unknown", function()
    local lines = MapPins.TooltipLines(pin("Ann", { layer = 7, sameLayer = false, level = false, age = 3.9 }))
    assert.are.same({ { text = "Layer #0007", green = false }, { text = "3 s ago" } }, lines)
    assert.are.same({ { text = "Level 60" }, { text = "0 s ago" } }, MapPins.TooltipLines(pin("Ann", { age = false })))
  end)

  it("is translated", function()
    ns.Locale.Use("esES")
    local lines = MapPins.TooltipLines(pin("Ann", { layer = 7 }))
    ns.Locale.Use("enUS")
    assert.are.equal("Nivel 60", lines[1].text)
    assert.are.equal("Capa #0007", lines[2].text)
    assert.are.equal("hace 12 s", lines[3].text)
  end)
end)

describe("MapPins frames", function()
  local NAMES = { "RAID_CLASS_COLORS", "CLASS_ICON_TCOORDS", "GameTooltip", "LibStub" }
  local saved = {}

  before_each(function()
    FakeFrames.install()
    for _, name in ipairs(NAMES) do
      saved[name] = _G[name]
    end
    _G.RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
    _G.CLASS_ICON_TCOORDS = { MAGE = { 0.25, 0.5, 0, 0.25 } }
    local tooltip = { lines = {} }
    function tooltip:SetOwner(owner)
      self.owner = owner
    end
    function tooltip:AddLine(text, r, g, b)
      self.lines[#self.lines + 1] = { text, r, g, b }
    end
    function tooltip:Show()
      self.shown = true
    end
    function tooltip:Hide()
      self.shown = false
    end
    _G.GameTooltip = tooltip
  end)

  after_each(function()
    FakeFrames.uninstall()
    for _, name in ipairs(NAMES) do
      _G[name] = saved[name]
    end
  end)

  it("builds a 12 px pin for the minimap and a 14 px pin for the world map", function()
    local mini, world = MapPins.BuildPin("minimap"), MapPins.BuildPin("worldmap")
    assert.are.same({ 12, 12 }, { mini.width, mini.height })
    assert.are.same({ 14, 14 }, { world.width, world.height })
    assert.is_truthy(mini.border)
    assert.is_truthy(mini.icon)
  end)

  it("shows the class icon with a border in the class colour", function()
    local frame = MapPins.BuildPin("minimap")
    MapPins.DressPin(frame, pin("Ann", { sameLayer = true }))
    assert.are.equal("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES", frame.icon.texture)
    assert.are.same({ 0.25, 0.78, 0.92, 1 }, frame.border.color)
    assert.are.equal(1, frame.alpha)
  end)

  it("shows a grey dot when the class is unknown, and half transparent on another layer", function()
    local frame = MapPins.BuildPin("worldmap")
    MapPins.DressPin(frame, pin("Ann", { class = "UNKNOWN", sameLayer = false }))
    assert.are.equal("Interface\\Buttons\\WHITE8X8", frame.icon.texture)
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, frame.border.color)
    assert.are.equal(0.5, frame.alpha)
    MapPins.DressPin(frame, pin("Ann", { class = false }))
    assert.are.equal("Interface\\Buttons\\WHITE8X8", frame.icon.texture)
    assert.are.equal(1, frame.alpha)
  end)

  it("falls back to the grey dot when the client has no class tables", function()
    _G.RAID_CLASS_COLORS, _G.CLASS_ICON_TCOORDS = nil, nil
    local frame = MapPins.BuildPin("minimap")
    MapPins.DressPin(frame, pin("Ann"))
    assert.are.equal("Interface\\Buttons\\WHITE8X8", frame.icon.texture)
  end)

  it("shows a tooltip on enter and hides it on leave", function()
    local frame = MapPins.BuildPin("minimap")
    MapPins.DressPin(frame, pin("Ann", { layer = 9, sameLayer = true }))
    frame.scripts.OnEnter(frame)
    local tooltip = _G.GameTooltip
    assert.are.equal(frame, tooltip.owner)
    assert.are.same({ "Ann", 0.25, 0.78, 0.92 }, tooltip.lines[1])
    assert.are.equal("Level 60", tooltip.lines[2][1])
    assert.are.same({ "Layer #0009", 0.3, 1, 0.3 }, tooltip.lines[3])
    assert.is_true(tooltip.shown)
    frame.scripts.OnLeave(frame)
    assert.is_false(tooltip.shown)
  end)

  it("shows nothing for a frame that was never dressed, or without a tooltip", function()
    local frame = MapPins.BuildPin("minimap")
    frame.scripts.OnEnter(frame)
    assert.is_nil(_G.GameTooltip.owner)
    MapPins.DressPin(frame, pin("Ann"))
    _G.GameTooltip = nil
    assert.has_no.errors(function()
      frame.scripts.OnEnter(frame)
      frame.scripts.OnLeave(frame)
    end)
  end)

  it("starts on the shared library, or without it", function()
    local env = { pins = {}, settings = {} }
    local deps = {
      now = function() end,
      after = function() end,
      pins = function()
        return env.pins
      end,
      settings = function()
        return env.settings
      end,
    }
    _G.LibStub = function(name, silent)
      assert.are.equal("HereBeDragons-Pins-2.0", name)
      assert.is_true(silent)
      return env.library
    end
    env.library = fake_hbd()
    assert.are.equal(env.library, MapPins.Start(deps).deps.hbd)
    env.library = nil
    assert.is_nil(MapPins.Start(deps).deps.hbd)
    deps.hbd = fake_hbd()
    assert.are.equal(deps.hbd, MapPins.Start(deps).deps.hbd)
    assert.are.equal(MapPins.BuildPin, MapPins.Start(deps).deps.newPin)
  end)
end)
