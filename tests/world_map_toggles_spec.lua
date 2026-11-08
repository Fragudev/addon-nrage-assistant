-- The two buttons on the world map: what each shows and what a click does is decided by pure functions.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/Settings",
    "Domain/PositionModel",
    "UI/WorldMapToggles",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Toggles = ns.WorldMapToggles

describe("WorldMapToggles.State", function()
  it("describes the Guild button on and off", function()
    local on = Toggles.State({ guild = true, enemies = false }).guild
    assert.is_true(on.on)
    assert.are.equal("Guild", on.label)
    assert.are.equal("Click to hide guildmates on the world map.", on.tooltip[2])
    local off = Toggles.State({ guild = false, enemies = false }).guild
    assert.is_false(off.on)
    assert.are.equal("Click to show guildmates on the world map.", off.tooltip[2])
    assert.are_not.equal(on.color, off.color)
  end)

  it("describes the Enemies button on and off", function()
    local on = Toggles.State({ guild = false, enemies = true }).enemies
    assert.is_true(on.on)
    assert.are.equal("Enemies", on.label)
    assert.are.equal("Click to hide the enemies reported by Intel on the world map.", on.tooltip[2])
    local off = Toggles.State({ guild = false, enemies = false }).enemies
    assert.is_false(off.on)
    assert.are.equal("Click to show the enemies reported by Intel on the world map.", off.tooltip[2])
    assert.are_not.equal(on.color, off.color)
  end)

  it("treats anything but true as off", function()
    local state = Toggles.State({})
    assert.is_false(state.guild.on)
    assert.is_false(state.enemies.on)
  end)
end)

describe("WorldMapToggles.Toggle", function()
  local function env()
    local e = { position = { worldmap = true }, intel = { worldmapPins = true, mapMode = "zone" }, calls = {} }
    e.setPositionDisplay = function(which, on)
      e.calls[#e.calls + 1] = { which, on }
      e.position[which] = on
    end
    e.requestEnemies = function()
      e.calls[#e.calls + 1] = "request"
    end
    return e
  end

  it("flips the guildmates through the shared setter", function()
    local e = env()
    assert.is_false(Toggles.Toggle("guild", e))
    assert.are.same({ { "worldmap", false } }, e.calls)
    assert.is_true(Toggles.Toggle("guild", e))
    assert.is_true(e.position.worldmap)
  end)

  it("flips the enemy pins and asks for a redraw, leaving mapMode alone", function()
    local e = env()
    assert.is_false(Toggles.Toggle("enemies", e))
    assert.is_false(e.intel.worldmapPins)
    assert.are.same({ "request" }, e.calls)
    assert.are.equal("zone", e.intel.mapMode)
    assert.is_true(Toggles.Toggle("enemies", e))
  end)

  it("ignores an unknown button", function()
    local e = env()
    assert.is_nil(Toggles.Toggle("minimap", e))
    assert.are.same({}, e.calls)
  end)
end)

describe("WorldMapToggles.Start", function()
  it("does nothing without the world map and never raises", function()
    assert.is_nil(_G.WorldMapFrame)
    assert.has_no.errors(function()
      Toggles.Start()
      Toggles.Refresh()
    end)
    assert.is_nil(Toggles.Widgets())
  end)
end)
