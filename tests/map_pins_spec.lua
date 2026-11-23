local FakeFrames = dofile("tests/support/fake_frames.lua")

local function load_pins()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/LayerModel",
    "Domain/IntelModel",
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

  it("calls the library again only when something that shows changed", function()
    local env = build()
    env.controller:Redraw({ pin("Ann", { age = 1 }) }, env.settings)
    env.hbd.calls = {}
    local later = pin("Ann", { age = 5 })
    assert.are.equal(1, env.controller:Redraw({ later }, env.settings))
    assert.are.same({}, env.hbd.calls)
    assert.are.equal(later, env.built[1].pin)
    env.controller:Redraw({ pin("Ann", { x = 0.6 }) }, env.settings)
    assert.are.equal(1, count(env.hbd, "AddMinimapIconMap"))
    env.hbd.calls = {}
    env.controller:Redraw({ pin("Ann", { x = 0.6 }) }, { minimap = true, worldmap = false })
    assert.are.equal(1, count(env.hbd, "RemoveAllWorldMapIcons"))
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

describe("MapPins.EnemyTooltipLines", function()
  it("tells the level, the class, the marks, who saw him and how long ago", function()
    local lines = MapPins.EnemyTooltipLines(pin("Ann", {
      class = "ROGUE",
      levelEstimated = true,
      kos = "guild",
      stealth = true,
      reporter = "Bob-Realm",
      layer = 9,
      sameLayer = true,
    }))
    assert.are.same({
      { text = "Level 60? Rogue" },
      { text = "Kill on Sight", red = true },
      { text = "Used a stealth ability" },
      { text = "Reported by Bob" },
      { text = "Layer #0009", green = true },
      { text = "12 s ago" },
    }, lines)
  end)

  it("says the enemy was seen by the player, and leaves out what is unknown", function()
    local lines = MapPins.EnemyTooltipLines(pin("Ann", { class = false, level = false, age = false }))
    assert.are.same({ { text = "Seen by you" }, { text = "0 s ago" } }, lines)
    assert.are.equal("Mage", MapPins.EnemyTooltipLines(pin("Ann", { level = false }))[1].text)
    assert.are.equal("Level 60", MapPins.EnemyTooltipLines(pin("Ann", { class = false }))[1].text)
  end)
end)

describe("MapPins.Controller:Follow", function()
  it("goes to the map of the first pin once for each new enemy and map", function()
    local gone = {}
    local env = build({
      follow = function(map)
        gone[#gone + 1] = map
      end,
    })
    local first = pin("Ann", { map = 1411 })
    env.controller:Follow({ first })
    env.controller:Follow({ first })
    assert.are.same({ 1411 }, gone)
    env.controller:Follow({ pin("Ann", { map = 1412 }) })
    assert.are.same({ 1411, 1412 }, gone)
    -- Nobody left, and the same enemy comes back: the map follows again.
    env.controller:Follow({})
    env.controller:Follow({ pin("Ann", { map = 1412 }) })
    assert.are.same({ 1411, 1412, 1412 }, gone)
  end)

  it("works without a way to move the map", function()
    local env = build()
    assert.has_no.errors(function()
      env.controller:Follow({ pin("Ann") })
    end)
  end)

  it("follows after a redraw only when the setting says so", function()
    local gone = {}
    local env = build({
      follow = function(map)
        gone[#gone + 1] = map
      end,
    })
    env.controller:Request()
    env.timers[1].fn()
    assert.are.same({}, gone)
    env.clock = env.clock + 10
    env.settings = { minimap = true, worldmap = true, follow = true }
    env.controller:Request()
    env.timers[2].fn()
    assert.are.same({ 1411 }, gone)
  end)

  it("uses the maximum of its own when it has one", function()
    local env = build({ max = 2 })
    local pins = { pin("A"), pin("B"), pin("C") }
    assert.are.equal(2, env.controller:Redraw(pins, env.settings))
  end)
end)

describe("MapPins enemy frames", function()
  local NAMES =
    { "RAID_CLASS_COLORS", "CLASS_ICON_TCOORDS", "GameTooltip", "LibStub", "HBD_PINS_WORLDMAP_SHOW_CONTINENT" }
  local saved = {}

  before_each(function()
    FakeFrames.install()
    for _, name in ipairs(NAMES) do
      saved[name] = _G[name]
    end
    _G.RAID_CLASS_COLORS = { MAGE = { r = 0.25, g = 0.78, b = 0.92 } }
    _G.CLASS_ICON_TCOORDS = { MAGE = { 0.25, 0.5, 0, 0.25 } }
    _G.HBD_PINS_WORLDMAP_SHOW_CONTINENT = "CONTINENT"
    local tooltip = { lines = {} }
    function tooltip:SetOwner(owner)
      self.owner = owner
    end
    function tooltip:AddLine(text, r, g, b)
      self.lines[#self.lines + 1] = { text, r, g, b }
    end
    tooltip.Show = function() end
    _G.GameTooltip = tooltip
    -- The kit's text helpers, as far as the pin needs them.
    ns.Kit = ns.Kit or {}
    ns.Kit.Theme = ns.Kit.Theme or {
      StyleFont = function()
        return "font"
      end,
    }
    ns.Kit.SetTextColor = ns.Kit.SetTextColor or function() end
  end)

  after_each(function()
    FakeFrames.uninstall()
    for _, name in ipairs(NAMES) do
      _G[name] = saved[name]
    end
  end)

  it("builds a pin with a mark and a swords badge, and dresses it in red", function()
    local frame = MapPins.BuildEnemyPin("worldmap")
    assert.are.same({ 18, 18 }, { frame.width, frame.height })
    assert.is_truthy(frame.mark)
    assert.are.equal("Interface\\AddOns\\NrageAssistant\\Media\\Icons\\role-dps", frame.badge.texture)
    assert.are.equal("Interface\\AddOns\\NrageAssistant\\Media\\Icons\\disc", frame.badgeBack.texture)
    MapPins.DressEnemyPin(frame, pin("Ann", { kos = "personal" }))
    assert.are.same({ 1, 0.35, 0.35, 1 }, frame.border.vertex)
    assert.are.same({ 1, 0.35, 0.35, 1 }, frame.badge.vertex)
    assert.are.equal("!", frame.mark.text)
    assert.is_true(frame.enemy)
    MapPins.DressEnemyPin(frame, pin("Ann"))
    assert.are.equal("", frame.mark.text)
    -- A frame without a mark (an old pool entry) is still dressed.
    frame.mark = nil
    assert.has_no.errors(function()
      MapPins.DressEnemyPin(frame, pin("Ann"))
    end)
  end)

  it("shows the enemy tooltip with the red line for a Kill on Sight player", function()
    local frame = MapPins.BuildEnemyPin("minimap")
    MapPins.DressEnemyPin(frame, pin("Ann", { kos = "guild", reporter = "Bob-Realm" }))
    frame.scripts.OnEnter(frame)
    local lines = _G.GameTooltip.lines
    assert.are.equal("Kill on Sight", lines[3][1])
    assert.are.same({ 1, 0.35, 0.35 }, { lines[3][2], lines[3][3], lines[3][4] })
    assert.are.equal("Reported by Bob", lines[4][1])
  end)

  it("starts the controller of the enemy pins with its own key, pool size and follow function", function()
    local library = fake_hbd()
    local follow = function() end
    local controller = MapPins.StartEnemies({
      hbd = library,
      now = function() end,
      after = function() end,
      pins = function() end,
      settings = function() end,
      follow = follow,
    })
    assert.are.equal(library, controller.deps.hbd)
    assert.are.equal(MapPins.EnemyPins, controller.deps.ref)
    assert.are.equal(Constants.INTEL_DIRECTORY_MAX, controller.deps.max)
    assert.are.equal(MapPins.BuildEnemyPin, controller.deps.newPin)
    assert.are.equal(MapPins.DressEnemyPin, controller.deps.dress)
    assert.are.equal("CONTINENT", controller.deps.worldFlag)
    assert.are.equal(follow, controller.deps.follow)
    _G.LibStub = function()
      return library
    end
    assert.are.equal(library, MapPins.StartEnemies({}).deps.hbd)
    _G.LibStub = nil
    assert.is_nil(MapPins.StartEnemies({}).deps.hbd)
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

  it("builds a 15 px pin for the minimap and an 18 px pin for the world map, with no badge", function()
    local mini, world = MapPins.BuildPin("minimap"), MapPins.BuildPin("worldmap")
    assert.are.same({ 15, 15 }, { mini.width, mini.height })
    assert.are.same({ 18, 18 }, { world.width, world.height })
    assert.is_truthy(mini.border)
    assert.is_truthy(mini.icon)
    assert.is_nil(mini.badge)
  end)

  it("shows the class icon in a diamond in the class colour, so it does not look like a party member", function()
    local frame = MapPins.BuildPin("minimap")
    MapPins.DressPin(frame, pin("Ann", { sameLayer = true }))
    assert.are.equal("Interface\\AddOns\\NrageAssistant\\Media\\Icons\\pin-diamond", frame.border.texture)
    assert.are.equal("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES", frame.icon.texture)
    assert.are.same({ 0.25, 0.78, 0.92, 1 }, frame.border.vertex)
    assert.are.equal(1, frame.alpha)
    -- The cell is cropped inward so the baked square frame is cut off.
    local tc = frame.icon.texcoord
    assert.is_true(tc[1] > 0.25 and tc[2] < 0.5 and tc[3] > 0 and tc[4] < 0.25)
    MapPins.DressPin(frame, pin("Ann", { layer = nil, sameLayer = nil }))
    assert.are.same({ 0.25, 0.78, 0.92, 1 }, frame.border.vertex)
  end)

  it("greys the ring on another layer and never makes the pin transparent", function()
    local frame = MapPins.BuildPin("minimap")
    MapPins.DressPin(frame, pin("Ann", { sameLayer = false }))
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, frame.border.vertex)
    assert.are.equal(1, frame.alpha)
  end)

  it("rings an enemy in red, and in grey on another layer", function()
    local frame = MapPins.BuildEnemyPin("minimap")
    MapPins.DressEnemyPin(frame, pin("Ann", { sameLayer = true }))
    assert.are.same({ 1, 0.35, 0.35, 1 }, frame.border.vertex)
    assert.are.equal("Interface\\AddOns\\NrageAssistant\\Media\\Icons\\pin-diamond", frame.border.texture)
    MapPins.DressEnemyPin(frame, pin("Ann", { sameLayer = false }))
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, frame.border.vertex)
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, frame.badge.vertex)
    assert.are.equal(1, frame.alpha)
  end)

  it("masks the icon to a diamond when the client has mask textures, and still builds without them", function()
    local frame = MapPins.BuildPin("minimap")
    assert.has_no.errors(function()
      MapPins.DressPin(frame, pin("Ann"))
    end)
  end)

  it("shows a grey dot when the class is unknown", function()
    local frame = MapPins.BuildPin("worldmap")
    MapPins.DressPin(frame, pin("Ann", { class = "UNKNOWN", sameLayer = true }))
    assert.are.equal("Interface\\Buttons\\WHITE8X8", frame.icon.texture)
    assert.are.same({ 0.5, 0.5, 0.5, 1 }, frame.border.vertex)
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

describe("MapPins.BuildPin visibility", function()
  before_each(function()
    FakeFrames.install()
  end)

  after_each(function()
    FakeFrames.uninstall()
  end)

  -- A pin frame is anchored only by the library. Shown before that, an unanchored frame sits at the centre of
  -- UIParent, so a pin the library does not place (a pin on another map) stayed on screen after the map closed.
  it("starts hidden on both maps, until the library places it", function()
    assert.is_false(MapPins.BuildPin("worldmap"):IsShown())
    assert.is_false(MapPins.BuildPin("minimap"):IsShown())
  end)

  -- OpenMap's combat view moves every HereBeDragons icon onto its own layer and, as combat ends, gives each one back
  -- to the parent it had then and shows it. An icon the library had let go has UIParent as its parent, so it came
  -- back shown in the middle of the screen.
  it("will not show on UIParent, where nothing places it", function()
    for _, kind in ipairs({ "minimap", "worldmap" }) do
      local frame = MapPins.BuildPin(kind)
      frame:SetParent(UIParent)
      frame:Show()
      assert.is_false(frame:IsShown())
    end
  end)

  it("still shows once the library or another map puts it on a frame of theirs", function()
    local holder = CreateFrame("Frame", nil, UIParent)
    for _, kind in ipairs({ "minimap", "worldmap" }) do
      local frame = MapPins.BuildPin(kind)
      frame:SetParent(holder)
      frame:Show()
      assert.is_true(frame:IsShown())
    end
  end)

  it("keeps every pin frame hidden when the library places none of them", function()
    -- A library that places nothing (the pins are on another map): no pool frame may be left visible.
    local env = build({ hbd = fake_hbd(), newPin = MapPins.BuildPin, dress = MapPins.DressPin })
    env.controller:Redraw({ pin("Ann"), pin("Bob") }, { minimap = true, worldmap = true })
    for _, kind in ipairs({ "minimap", "worldmap" }) do
      for index = 1, 2 do
        assert.is_false(env.controller.pools[kind][index]:IsShown())
      end
    end
  end)
end)
