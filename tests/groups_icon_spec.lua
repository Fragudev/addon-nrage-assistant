local function load_icon()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/GroupsIcon.lua"))("NrageAssistant", ns)
  return ns
end

local ns = load_icon()
local Icon = ns.GroupsIcon

local function newDb()
  return { global = { settings = {} } }
end

describe("GroupsIcon.Settings", function()
  it("creates the table with the default place, on the top right of the screen", function()
    local db = newDb()
    local settings = Icon.Settings(db)
    assert.are.equal(-250, settings.x)
    assert.are.equal(-30, settings.y)
    assert.are.equal(settings, db.global.settings.groupsIcon)
  end)

  it("keeps a saved place", function()
    local db = newDb()
    db.global.settings.groupsIcon = { x = -600, y = -400 }
    local settings = Icon.Settings(db)
    assert.are.equal(-600, settings.x)
    assert.are.equal(-400, settings.y)
  end)

  it("repairs an unusable place to the default", function()
    for _, value in ipairs({ "90", true, {}, 0 / 0, math.huge }) do
      local db = newDb()
      db.global.settings.groupsIcon = { x = value, y = -10 }
      local settings = Icon.Settings(db)
      assert.are.equal(-250, settings.x, tostring(value))
      assert.are.equal(-30, settings.y, tostring(value))
    end
    local db = newDb()
    db.global.settings.groupsIcon = "broken"
    assert.are.equal(-250, Icon.Settings(db).x)
  end)

  it("never touches the minimap button settings", function()
    local db = newDb()
    db.global.settings.minimap = { angle = 10, hide = true }
    Icon.Settings(db)
    assert.are.same({ angle = 10, hide = true }, db.global.settings.minimap)
    local empty = newDb()
    Icon.Settings(empty)
    assert.is_nil(empty.global.settings.minimap)
  end)
end)

describe("GroupsIcon.Offsets", function()
  it("measures the dropped corner from the top right of the screen, rounded", function()
    assert.are.same({ -300, -120 }, { Icon.Offsets(1620.4, 960.2, 1920, 1080) })
    assert.are.same({ 0, 0 }, { Icon.Offsets(1920, 1080, 1920, 1080) })
  end)
end)

describe("GroupsIcon.State", function()
  local function env(overrides)
    local e = {
      modules = {
        IsEnabled = function()
          return true
        end,
      },
      lfgBoard = {
        Query = function()
          return { { id = "a" } }
        end,
      },
      lfgService = {
        CanApply = function()
          return true
        end,
      },
      identity = function()
        return "Me-Realm"
      end,
    }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end

  it("is enabled with the module on and a board, and carries posts and own name", function()
    local state = Icon.State(env())
    assert.is_true(state.enabled)
    assert.are.same({ { id = "a" } }, state.posts)
    assert.are.equal("Me-Realm", state.ownName)
    assert.is_true(state.canApply("a"))
  end)

  it("is disabled when the module is off or there is no board", function()
    assert.is_false(Icon.State(env({ modules = {
      IsEnabled = function()
        return false
      end,
    } })).enabled)
    local noBoard = Icon.State(env({ lfgBoard = false }))
    assert.is_false(noBoard.enabled)
    assert.are.same({}, noBoard.posts)
  end)

  it("is enabled without a modules object", function()
    assert.is_true(Icon.State(env({ modules = false })).enabled)
  end)

  it("canApply is false when the service errors or is missing", function()
    local failing = Icon.State(env({ lfgService = {
      CanApply = function()
        error("x")
      end,
    } }))
    assert.is_false(failing.canApply("a"))
    assert.is_false(Icon.State(env({ lfgService = false })).canApply("a"))
  end)

  it("survives an identity that errors", function()
    local state = Icon.State(env({
      identity = function()
        error("x")
      end,
    }))
    assert.is_nil(state.ownName)
  end)
end)

describe("GroupsIcon.Refresh", function()
  it("does nothing before Create", function()
    assert.has_no.errors(function()
      Icon.Refresh()
    end)
  end)
end)

describe("GroupsIcon.DebugPreview", function()
  local icon

  before_each(function()
    -- Each test gets a fresh module with preview disabled.
    icon = load_icon().GroupsIcon
  end)

  it("starts with the preview disabled", function()
    assert.is_false(icon.IsDebugVisible())
  end)

  it("enables the preview", function()
    icon.SetDebugVisible(true)
    assert.is_true(icon.IsDebugVisible())
  end)

  it("disables the preview", function()
    icon.SetDebugVisible(true)
    icon.SetDebugVisible(false)
    assert.is_false(icon.IsDebugVisible())
  end)

  it("only enables the preview for true", function()
    for _, value in ipairs({ false, 0, 1, "true", {} }) do
      icon.SetDebugVisible(value)
      assert.is_false(icon.IsDebugVisible())
    end

    icon.SetDebugVisible(nil)
    assert.is_false(icon.IsDebugVisible())
  end)

  it("refreshes the icon when the preview changes", function()
    local calls = 0

    icon.Refresh = function()
      calls = calls + 1
    end

    icon.SetDebugVisible(true)
    assert.are.equal(1, calls)

    icon.SetDebugVisible(false)
    assert.are.equal(2, calls)
  end)

  it("does not require the WoW client to toggle the preview", function()
    assert.has_no.errors(function()
      icon.SetDebugVisible(true)
      icon.SetDebugVisible(false)
    end)
  end)
end)
