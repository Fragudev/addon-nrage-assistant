local function load_button()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/MinimapButton.lua"))("NrageAssistant", ns)
  return ns.MinimapButton, ns.Constants
end

local MinimapButton, Constants = load_button()

describe("MinimapButton.NormalizeAngle", function()
  it("keeps an angle in [0, 360)", function()
    assert.are.equal(0, MinimapButton.NormalizeAngle(0))
    assert.are.equal(0, MinimapButton.NormalizeAngle(360))
    assert.are.equal(270, MinimapButton.NormalizeAngle(-90))
    assert.are.equal(5, MinimapButton.NormalizeAngle(725))
    assert.are.equal(359.5, MinimapButton.NormalizeAngle(359.5))
  end)

  it("falls back to the default position for anything that is not a usable number", function()
    for _, value in ipairs({ "90", true, {}, 0 / 0, math.huge, -math.huge }) do
      assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, MinimapButton.NormalizeAngle(value), tostring(value))
    end
    assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, MinimapButton.NormalizeAngle(nil))
  end)
end)

describe("MinimapButton.Position", function()
  local function near(expected, actual)
    assert.are.near(expected, actual, 0.0001)
  end

  it("puts the button on the circle: 0 is right, 90 is up, 180 is left, 270 is down", function()
    local x, y = MinimapButton.Position(0, 80)
    near(80, x)
    near(0, y)
    x, y = MinimapButton.Position(90, 80)
    near(0, x)
    near(80, y)
    x, y = MinimapButton.Position(180, 80)
    near(-80, x)
    near(0, y)
    x, y = MinimapButton.Position(270, 80)
    near(0, x)
    near(-80, y)
  end)

  it("always stays at the given distance from the centre", function()
    for angle = 0, 350, 25 do
      local x, y = MinimapButton.Position(angle, 75)
      near(75, math.sqrt(x * x + y * y))
    end
  end)

  it("uses the default angle for a bad one", function()
    local x, y = MinimapButton.Position("nonsense", 80)
    local expectedX, expectedY = MinimapButton.Position(Constants.MINIMAP_DEFAULT_ANGLE, 80)
    assert.are.equal(expectedX, x)
    assert.are.equal(expectedY, y)
  end)
end)

describe("MinimapButton.AngleFromCursor", function()
  local function near(expected, actual)
    assert.are.near(expected, actual, 0.0001)
  end

  it("measures the angle of the cursor around the minimap centre", function()
    near(0, MinimapButton.AngleFromCursor(100, 100, 150, 100))
    near(90, MinimapButton.AngleFromCursor(100, 100, 100, 150))
    near(180, MinimapButton.AngleFromCursor(100, 100, 50, 100))
    near(270, MinimapButton.AngleFromCursor(100, 100, 100, 50))
    near(45, MinimapButton.AngleFromCursor(100, 100, 130, 130))
    near(225, MinimapButton.AngleFromCursor(100, 100, 70, 70))
  end)

  it("gives the position the button is dragged to, whatever the distance", function()
    local angle = MinimapButton.AngleFromCursor(0, 0, 3, 4)
    local x, y = MinimapButton.Position(angle, 5)
    near(3, x)
    near(4, y)
  end)
end)

describe("MinimapButton.Settings", function()
  local function database()
    return { global = {} }
  end

  it("creates the defaults", function()
    local db = database()
    local settings = MinimapButton.Settings(db)
    assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, settings.angle)
    assert.is_false(settings.hide)
  end)

  it("returns the stored table, so changes are saved", function()
    local db = database()
    MinimapButton.Settings(db).angle = 90
    MinimapButton.Settings(db).hide = true
    assert.are.same({ angle = 90, hide = true }, db.global.settings.minimap)
  end)

  it("keeps valid saved values", function()
    local db = { global = { settings = { minimap = { angle = 45.5, hide = true } } } }
    assert.are.same({ angle = 45.5, hide = true }, MinimapButton.Settings(db))
  end)

  it("repairs values that are not what they should be, and wrong section types", function()
    local db = { global = { settings = { minimap = { angle = "left", hide = "yes" } } } }
    assert.are.same({ angle = Constants.MINIMAP_DEFAULT_ANGLE, hide = false }, MinimapButton.Settings(db))

    db = { global = { settings = "oops" } }
    assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, MinimapButton.Settings(db).angle)

    db = { global = { settings = { minimap = 5 } } }
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("wraps an out-of-range saved angle", function()
    local db = { global = { settings = { minimap = { angle = -90 } } } }
    assert.are.equal(270, MinimapButton.Settings(db).angle)
  end)
end)

describe("MinimapButton.SetHidden and ResetPosition", function()
  local function database()
    return { global = {} }
  end

  it("hides and shows the button", function()
    local db = database()
    MinimapButton.SetHidden(db, true)
    assert.is_true(MinimapButton.Settings(db).hide)
    MinimapButton.SetHidden(db, false)
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("treats anything but true as showing it", function()
    local db = database()
    MinimapButton.SetHidden(db, true)
    MinimapButton.SetHidden(db, nil)
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("resets the position and shows the button again", function()
    local db = database()
    MinimapButton.SetHidden(db, true)
    MinimapButton.Settings(db).angle = 10
    MinimapButton.ResetPosition(db)
    assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, MinimapButton.Settings(db).angle)
    assert.is_false(MinimapButton.Settings(db).hide)
  end)
end)

describe("MinimapButton tooltip and Intel", function()
  local FakeFrames = dofile("tests/support/fake_frames.lua")
  local NAMES = { "GameTooltip", "Minimap", "MinimapCluster" }
  local saved = {}
  local ns, tooltip

  local function new_tooltip()
    local tip = { lines = {}, scripts = {}, owner = nil, shown = 0 }
    function tip:SetOwner(owner)
      self.owner = owner
    end
    function tip:GetOwner()
      return self.owner
    end
    function tip:AddLine(text, r, g, b)
      self.lines[#self.lines + 1] = { text = text, r = r, g = g, b = b }
      _G["GameTooltipTextLeft" .. #self.lines] = {
        GetText = function()
          return text
        end,
        GetTextColor = function()
          return r, g, b
        end,
      }
    end
    function tip:NumLines()
      return #self.lines
    end
    function tip:Show()
      self.shown = self.shown + 1
      if self.scripts.OnShow then
        self.scripts.OnShow()
      end
    end
    tip.Hide = function() end
    function tip:HookScript(name, fn)
      self.scripts[name] = fn
    end
    return tip
  end

  before_each(function()
    FakeFrames.install()
    for _, name in ipairs(NAMES) do
      saved[name] = _G[name]
    end
    ns = {}
    for _, path in ipairs({
      "Core/Constants",
      "Core/Locale",
      "Locales/esES",
      "Core/Validate",
      "Domain/IntelModel",
      "Domain/IntelService",
      "Domain/IntelMinimapTooltip",
      "UI/MinimapButton",
    }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    end
    tooltip = new_tooltip()
    _G.GameTooltip = tooltip
    _G.Minimap = CreateFrame("Frame", "Minimap")
    _G.MinimapCluster = CreateFrame("Frame", "MinimapCluster")
    ns.GetVersion = function()
      return "test"
    end
    ns.db = { global = {} }
    ns.active = true
  end)

  after_each(function()
    FakeFrames.uninstall()
    for _, name in ipairs(NAMES) do
      _G[name] = saved[name]
    end
    for index = 1, 20 do
      _G["GameTooltipTextLeft" .. index] = nil
    end
  end)

  it("adds the enemies nearby to the tooltip of the button", function()
    ns.intel = {}
    ns.IntelNearby = function()
      return { { kos = "personal" }, {} }
    end
    ns.ViewModel = {
      IntelMinimapLines = function(nearby)
        return { #nearby .. " nearby" }
      end,
    }
    ns.MinimapButton.Create()
    local created = _G.NrageAssistantMinimapButton
    created.scripts.OnEnter(created)
    local texts = {}
    for _, line in ipairs(tooltip.lines) do
      texts[#texts + 1] = line.text
    end
    assert.are.same({ "Nrage Assistant test", "2 nearby", "Left click: open the window" }, {
      texts[1],
      texts[2],
      texts[3],
    })
  end)

  it("adds nothing about Intel while it is not running", function()
    ns.ViewModel = {}
    ns.MinimapButton.Create()
    local created = _G.NrageAssistantMinimapButton
    created.scripts.OnEnter(created)
    assert.are.equal("Left click: open the window", tooltip.lines[2].text)
  end)

  describe("HookTooltip", function()
    local service, fed, settings

    before_each(function()
      service = ns.IntelService.New({
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
      service:OnSeen({ name = "Ann", class = "MAGE", level = 60 }, {})
      fed = {}
      settings = { minimapTooltip = true, minimapFeed = true }
      assert.is_true(ns.MinimapButton.HookTooltip({
        service = service,
        settings = function()
          return settings
        end,
        feed = function(details)
          fed[#fed + 1] = details.name
        end,
      }))
    end)

    local function hover(owner, ...)
      tooltip.lines = {}
      tooltip.owner = owner
      for _, spec in ipairs({ ... }) do
        tooltip:AddLine(spec[1], spec[2], spec[3], spec[4])
      end
      tooltip.shown = 0
      tooltip.scripts.OnShow()
    end

    it("hooks the tooltip once", function()
      assert.is_false(ns.MinimapButton.HookTooltip({}))
    end)

    it("adds the level and class of a known enemy under the minimap, and feeds Nearby", function()
      hover(Minimap, { "Ann", 1, 0, 0 }, { "Bob", 1, 0.1, 0.1 }, { "Cid", 0, 1, 0 })
      assert.are.equal("Ann: Level 60 Mage", tooltip.lines[4].text)
      assert.are.equal(4, #tooltip.lines)
      assert.are.equal(1, tooltip.shown)
      assert.are.same({ "Ann", "Bob" }, fed)
    end)

    it("works under the minimap cluster too", function()
      hover(MinimapCluster, { "Ann", 1, 0, 0 })
      assert.are.equal("Ann: Level 60 Mage", tooltip.lines[2].text)
    end)

    it("leaves every other tooltip alone", function()
      hover(UIParent, { "Ann", 1, 0, 0 })
      assert.are.equal(1, #tooltip.lines)
      hover(nil, { "Ann", 1, 0, 0 })
      assert.are.equal(1, #tooltip.lines)
      assert.are.same({}, fed)
    end)

    it("does nothing while the addon is off or the settings are off", function()
      ns.active = false
      hover(Minimap, { "Ann", 1, 0, 0 })
      assert.are.equal(1, #tooltip.lines)
      ns.active = true
      settings = { minimapTooltip = false, minimapFeed = false }
      hover(Minimap, { "Ann", 1, 0, 0 })
      assert.are.equal(1, #tooltip.lines)
    end)

    it("does nothing for a line it cannot read, and never raises", function()
      tooltip.lines = { { text = "x" } }
      tooltip.owner = Minimap
      _G.GameTooltipTextLeft1 = {
        GetText = function()
          return setmetatable({}, {
            __concat = function()
              error("secret")
            end,
          })
        end,
        GetTextColor = function() end,
      }
      assert.has_no.errors(function()
        tooltip.scripts.OnShow()
      end)
      _G.GameTooltipTextLeft1 = {
        GetText = function()
          return "Ann"
        end,
        GetTextColor = function()
          return setmetatable({}, {
            __le = function()
              error("secret")
            end,
            __lt = function()
              error("secret")
            end,
          })
        end,
      }
      assert.has_no.errors(function()
        tooltip.scripts.OnShow()
      end)
      -- A line the game did not make is skipped.
      tooltip.lines = { { text = "x" } }
      _G.GameTooltipTextLeft1 = nil
      assert.has_no.errors(function()
        tooltip.scripts.OnShow()
      end)
    end)
  end)

  it("does not hook a client without tooltips", function()
    _G.GameTooltip = nil
    assert.is_false(ns.MinimapButton.HookTooltip({}))
  end)
end)
