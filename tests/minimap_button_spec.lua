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

describe("MinimapButton.Command", function()
  local function database()
    return { global = {} }
  end

  it("hides and shows the button and says how to bring it back", function()
    local db = database()
    assert.is_truthy(MinimapButton.Command(db, "hide"):find("/nrage minimap show", 1, true))
    assert.is_true(MinimapButton.Settings(db).hide)
    assert.is_truthy(MinimapButton.Command(db, "show"):find("shown", 1, true))
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("resets the position and shows the button again", function()
    local db = database()
    MinimapButton.Command(db, "hide")
    MinimapButton.Settings(db).angle = 10
    MinimapButton.Command(db, "reset")
    assert.are.equal(Constants.MINIMAP_DEFAULT_ANGLE, MinimapButton.Settings(db).angle)
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("reports the current state without changing anything when no action is given", function()
    local db = database()
    MinimapButton.Settings(db).angle = 10
    assert.is_truthy(MinimapButton.Command(db, ""):find("shown", 1, true))
    assert.are.equal(10, MinimapButton.Settings(db).angle)
  end)

  it("gives the usage for an unknown action and changes nothing", function()
    local db = database()
    assert.is_truthy(MinimapButton.Command(db, "explode"):find("usage:", 1, true))
    assert.is_false(MinimapButton.Settings(db).hide)
  end)

  it("does not fail when the button has not been created yet", function()
    assert.has_no.errors(function()
      MinimapButton.Refresh()
    end)
  end)
end)
