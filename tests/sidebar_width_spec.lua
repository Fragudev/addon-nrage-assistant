local function load_sidebar()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/UI/SidebarWidth.lua"))("NrageAssistant", ns)
  return ns
end

local ns = load_sidebar()
local Width = ns.SidebarWidth

local function newDb()
  return { global = { settings = {} } }
end

local UNUSABLE = { "250", true, {}, 0 / 0, math.huge, -math.huge }

describe("SidebarWidth.Clamp", function()
  it("keeps a width inside the range, rounded to a whole unit", function()
    assert.are.equal(240, Width.Clamp(240))
    assert.are.equal(241, Width.Clamp(240.6))
  end)

  it("brings a width outside the range back to its edge", function()
    assert.are.equal(160, Width.Clamp(20))
    assert.are.equal(360, Width.Clamp(900))
  end)

  it("gives the default width for anything that is not a usable number", function()
    for _, value in ipairs(UNUSABLE) do
      assert.are.equal(200, Width.Clamp(value), tostring(value))
    end
    assert.are.equal(200, Width.Clamp(nil))
  end)

  it("leaves the page its minimum width in a narrow window", function()
    -- 760 is the smallest window: the page keeps 440 units, so the sidebar may reach 320.
    assert.are.equal(320, Width.Clamp(360, 760))
    assert.are.equal(300, Width.Clamp(300, 760))
    assert.are.equal(360, Width.Clamp(360, 1400))
  end)

  it("never goes under the minimum, however narrow the window", function()
    assert.are.equal(160, Width.Clamp(300, 400))
    assert.are.equal(160, Width.Max(100))
  end)

  it("ignores a window width that is not a usable number", function()
    assert.are.equal(360, Width.Clamp(360, 0 / 0))
    assert.are.equal(360, Width.Max("760"))
  end)
end)

describe("SidebarWidth.Get", function()
  it("creates the setting with the default width", function()
    local db = newDb()
    assert.are.equal(200, Width.Get(db))
    assert.are.equal(200, db.global.settings.sidebarWidth)
  end)

  it("keeps a saved width", function()
    local db = newDb()
    db.global.settings.sidebarWidth = 280
    assert.are.equal(280, Width.Get(db))
  end)

  it("repairs an unusable or out-of-range width", function()
    for _, value in ipairs(UNUSABLE) do
      local db = newDb()
      db.global.settings.sidebarWidth = value
      assert.are.equal(200, Width.Get(db), tostring(value))
      assert.are.equal(200, db.global.settings.sidebarWidth, tostring(value))
    end
    local db = newDb()
    db.global.settings.sidebarWidth = 5000
    assert.are.equal(360, Width.Get(db))
    assert.are.equal(360, db.global.settings.sidebarWidth)
  end)

  it("creates the settings table when it is missing or broken", function()
    local db = { global = { settings = "broken" } }
    assert.are.equal(200, Width.Get(db))
    assert.are.same({ sidebarWidth = 200 }, db.global.settings)
  end)

  it("never touches the other settings", function()
    local db = newDb()
    db.global.settings.minimap = { angle = 10, hide = true }
    db.global.settings.groupsIcon = { x = -1, y = -2 }
    Width.Get(db)
    Width.Set(db, 300)
    assert.are.same({ angle = 10, hide = true }, db.global.settings.minimap)
    assert.are.same({ x = -1, y = -2 }, db.global.settings.groupsIcon)
  end)
end)

describe("SidebarWidth.Set", function()
  it("saves the width, clamped to the range", function()
    local db = newDb()
    assert.are.equal(300, Width.Set(db, 300))
    assert.are.equal(300, db.global.settings.sidebarWidth)
    assert.are.equal(360, Width.Set(db, 999))
    assert.are.equal(360, db.global.settings.sidebarWidth)
    assert.are.equal(200, Width.Set(db, 0 / 0))
  end)
end)

describe("SidebarWidth.Drag", function()
  it("moves the edge by the distance dragged", function()
    assert.are.equal(250, Width.Drag(200, 50, 1000))
    assert.are.equal(170, Width.Drag(200, -30, 1000))
  end)

  it("stops at the edges of the range and of the window", function()
    assert.are.equal(160, Width.Drag(200, -500, 1000))
    assert.are.equal(360, Width.Drag(200, 500, 1400))
    assert.are.equal(320, Width.Drag(200, 500, 760))
  end)

  it("treats an unusable start or distance as the default and no move", function()
    assert.are.equal(200, Width.Drag(nil, 0 / 0, 1000))
    assert.are.equal(230, Width.Drag(0 / 0, 30, 1000))
  end)
end)
