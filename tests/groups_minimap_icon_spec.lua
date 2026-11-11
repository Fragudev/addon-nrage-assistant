local function load_icon()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Locale.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/MinimapButton.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/GroupsMinimapIcon.lua"))("NrageAssistant", ns)
  return ns
end

local ns = load_icon()
local Icon = ns.GroupsMinimapIcon

local function newDb()
  return { global = { settings = {} } }
end

describe("GroupsMinimapIcon.Settings", function()
  it("creates the table with the default angle", function()
    local db = newDb()
    local settings = Icon.Settings(db)
    assert.are.equal(160, ns.Constants.MINIMAP_GROUPS_DEFAULT_ANGLE)
    assert.are.equal(160, settings.angle)
    assert.are.equal(settings, db.global.settings.minimapGroups)
  end)

  it("keeps a valid angle", function()
    local db = newDb()
    db.global.settings.minimapGroups = { angle = 90 }
    assert.are.equal(90, Icon.Settings(db).angle)
  end)

  it("repairs an invalid angle to the groups default", function()
    for _, value in ipairs({ "90", true, {}, 0 / 0, math.huge }) do
      local db = newDb()
      db.global.settings.minimapGroups = { angle = value }
      assert.are.equal(160, Icon.Settings(db).angle, tostring(value))
    end
    local db = newDb()
    db.global.settings.minimapGroups = "broken"
    assert.are.equal(160, Icon.Settings(db).angle)
  end)

  it("normalises an angle out of range", function()
    local db = newDb()
    db.global.settings.minimapGroups = { angle = 400 }
    assert.are.equal(40, Icon.Settings(db).angle)
  end)

  it("never touches the addon button settings", function()
    local db = newDb()
    db.global.settings.minimap = { angle = 10, hide = true }
    Icon.Settings(db)
    assert.are.same({ angle = 10, hide = true }, db.global.settings.minimap)
    local empty = newDb()
    Icon.Settings(empty)
    assert.is_nil(empty.global.settings.minimap)
  end)
end)

describe("GroupsMinimapIcon.State", function()
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

describe("GroupsMinimapIcon.Refresh", function()
  it("does nothing before Create", function()
    assert.has_no.errors(function()
      Icon.Refresh()
    end)
  end)
end)
