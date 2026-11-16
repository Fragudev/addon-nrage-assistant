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

describe("GroupsIcon.Size", function()
  it("uses 52 as the default size", function()
    local db = newDb()

    assert.are.equal(52, Icon.Settings(db).size)
  end)

  it("keeps a saved size", function()
    local db = newDb()
    db.global.settings.groupsIcon = {
      x = -250,
      y = -30,
      size = 64,
    }

    assert.are.equal(64, Icon.Settings(db).size)
  end)

  it("clamps sizes to the allowed range", function()
    assert.are.equal(32, Icon.NormalizeSize(10))
    assert.are.equal(80, Icon.NormalizeSize(120))
    assert.are.equal(32, Icon.NormalizeSize(32))
    assert.are.equal(80, Icon.NormalizeSize(80))
  end)

  it("repairs invalid sizes", function()
    assert.are.equal(52, Icon.NormalizeSize(nil))
    assert.are.equal(52, Icon.NormalizeSize("large"))
    assert.are.equal(52, Icon.NormalizeSize(math.huge))
    assert.are.equal(52, Icon.NormalizeSize(0 / 0))
  end)

  it("rounds sizes to whole pixels", function()
    assert.are.equal(45, Icon.NormalizeSize(44.6))
    assert.are.equal(44, Icon.NormalizeSize(44.4))
  end)

  it("keeps the saved position when repairing the size", function()
    local db = newDb()
    db.global.settings.groupsIcon = {
      x = -400,
      y = -200,
      size = 200,
    }

    local settings = Icon.Settings(db)

    assert.are.equal(-400, settings.x)
    assert.are.equal(-200, settings.y)
    assert.are.equal(80, settings.size)
  end)
end)


describe("GroupsIcon.Visibility", function()
  it("defaults to an always-visible icon", function()
    local db = newDb()

    assert.is_true(Icon.Settings(db).alwaysShow)
  end)

  it("keeps the saved always-visible preference", function()
    local db = newDb()
    db.global.settings.groupsIcon = {
      x = -250,
      y = -30,
      alwaysShow = true,
    }

    assert.is_true(Icon.Settings(db).alwaysShow)
  end)

  it("keeps automatic visibility when explicitly disabled", function()
    local db = newDb()
    db.global.settings.groupsIcon = {
      x = -250,
      y = -30,
      alwaysShow = false,
    }

    -- An explicit false preserves automatic visibility across sessions.
    assert.is_false(Icon.Settings(db).alwaysShow)
  end)

  it("defaults invalid visibility preferences to always visible", function()
    for _, value in ipairs({ "true", "false", 0, 1, {} }) do
      local db = newDb()
      db.global.settings.groupsIcon = {
        alwaysShow = value,
      }

      assert.is_true(Icon.Settings(db).alwaysShow)
    end
  end)

  it("preserves the icon position and size when changing visibility", function()
    local db = newDb()
    db.global.settings.groupsIcon = {
      x = -400,
      y = -200,
      size = 64,
      alwaysShow = false,
    }

    local settings = Icon.Settings(db)

    -- Changing visibility must not reset the saved layout.
    settings.alwaysShow = true

    assert.is_true(Icon.Settings(db).alwaysShow)
    assert.are.equal(-400, settings.x)
    assert.are.equal(-200, settings.y)
    assert.are.equal(64, settings.size)
  end)
end)


describe("GroupsIcon.SetAlwaysShow", function()
  local icon
  local db

  before_each(function()
    local freshNs = load_icon()
    icon = freshNs.GroupsIcon
    db = newDb()

    -- Provide the saved database used by the visibility setter.
    freshNs.db = db
  end)

  it("disables persistent visibility", function()
    local enabled = icon.SetAlwaysShow(false)

    assert.is_false(enabled)
    assert.is_false(db.global.settings.groupsIcon.alwaysShow)
  end)

  it("enables persistent visibility", function()
    icon.SetAlwaysShow(false)

    local enabled = icon.SetAlwaysShow(true)

    assert.is_true(enabled)
    assert.is_true(db.global.settings.groupsIcon.alwaysShow)
  end)

  it("only accepts true to enable persistent visibility", function()
    icon.SetAlwaysShow("true")

    assert.is_false(icon.AlwaysShow())
  end)

  it("refreshes the icon after changing visibility", function()
    local calls = 0

    -- Replace the client refresh with a counter.
    icon.Refresh = function()
      calls = calls + 1
    end

    icon.SetAlwaysShow(false)
    icon.SetAlwaysShow(true)

    assert.are.equal(2, calls)
  end)
end)


describe("GroupsIcon.CountLayout", function()
  it("uses the original badge layout at the default icon size", function()
    assert.are.same({
      fontSize = 20,
      x = 14,
      y = -5,
    }, Icon.CountLayout(52))
  end)

  it("scales the badge down for a small icon", function()
    assert.are.same({
      fontSize = 12,
      x = 9,
      y = -3,
    }, Icon.CountLayout(32))
  end)

  it("scales the badge up for a large icon", function()
    assert.are.same({
      fontSize = 31,
      x = 22,
      y = -8,
    }, Icon.CountLayout(80))
  end)

  it("uses the default layout for invalid sizes", function()
    assert.are.same(Icon.CountLayout(52), Icon.CountLayout(nil))
    assert.are.same(Icon.CountLayout(52), Icon.CountLayout("large"))
  end)

  it("clamps out-of-range sizes before calculating the layout", function()
    assert.are.same(Icon.CountLayout(32), Icon.CountLayout(10))
    assert.are.same(Icon.CountLayout(80), Icon.CountLayout(120))
  end)
end)

