local function load_pins()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/LayerModel",
    "Domain/PositionModel",
    "Domain/PositionPins",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_pins()

local function build(overrides)
  local ctx = {
    now = function()
      return 130
    end,
    list = {
      { name = "Ann", map = 1411, x = 5000, y = 2500, at = 100 },
      { name = "Bob", map = 1412, x = 0, y = 10000, at = 125 },
    },
    lookup = function(name)
      return ({ Ann = { class = "MAGE", level = 60 }, Bob = { class = "WARRIOR", level = 58 } })[name]
    end,
    profile = function()
      return nil
    end,
    ownLayer = { map = 0, layer = 10 },
    layerOf = function(name)
      return ({ Ann = { map = 0, layer = 10 }, Bob = { map = 0, layer = 20 } })[name]
    end,
    isGroupMember = function()
      return false
    end,
    settings = { minimap = true, worldmap = true },
  }
  for key, value in pairs(overrides or {}) do
    ctx[key] = value
  end
  return ctx
end

describe("PositionPins.Build", function()
  it("builds a pin per member with zone coordinates, class, level, layer and age", function()
    local pins = ns.PositionPins.Build(build())
    assert.are.same({
      {
        key = "Ann",
        name = "Ann",
        class = "MAGE",
        level = 60,
        map = 1411,
        x = 0.5,
        y = 0.25,
        layer = 10,
        sameLayer = true,
        age = 30,
      },
      {
        key = "Bob",
        name = "Bob",
        class = "WARRIOR",
        level = 58,
        map = 1412,
        x = 0,
        y = 1,
        layer = 20,
        sameLayer = false,
        age = 5,
      },
    }, pins)
  end)

  it("skips the members of the own party or raid", function()
    local pins = ns.PositionPins.Build(build({
      isGroupMember = function(name)
        return name == "Ann"
      end,
    }))
    assert.are.equal(1, #pins)
    assert.are.equal("Bob", pins[1].name)
  end)

  it("skips a member who is not in the local guild roster", function()
    local pins = ns.PositionPins.Build(build({
      lookup = function(name)
        return name == "Bob" and { class = "WARRIOR", level = 58 } or nil
      end,
    }))
    assert.are.equal(1, #pins)
    assert.are.equal("Bob", pins[1].name)
  end)

  it("leaves sameLayer out when either layer is unknown", function()
    local pins = ns.PositionPins.Build(build({ ownLayer = false }))
    assert.is_nil(pins[1].sameLayer)
    assert.are.equal(10, pins[1].layer)
    pins = ns.PositionPins.Build(build({
      layerOf = function() end,
    }))
    assert.is_nil(pins[1].sameLayer)
    assert.is_nil(pins[1].layer)
    pins = ns.PositionPins.Build(build({ layerOf = false }))
    assert.is_nil(pins[1].sameLayer)
  end)

  it("compares the layers on the same continent only", function()
    local pins = ns.PositionPins.Build(build({
      layerOf = function()
        return { map = 1, layer = 10 }
      end,
    }))
    assert.is_false(pins[1].sameLayer)
  end)

  it("takes the class and level from a received profile when the roster has none", function()
    local pins = ns.PositionPins.Build(build({
      lookup = function()
        return { rankName = "Soldado" }
      end,
      profile = function()
        return { class = "ROGUE", level = 42 }
      end,
    }))
    assert.are.equal("ROGUE", pins[1].class)
    assert.are.equal(42, pins[1].level)
  end)

  it("leaves the class and level empty when nobody knows them", function()
    local pins = ns.PositionPins.Build(build({
      lookup = function()
        return {}
      end,
    }))
    assert.is_nil(pins[1].class)
    assert.is_nil(pins[1].level)
  end)

  it("survives a lookup that raises", function()
    local pins = ns.PositionPins.Build(build({
      profile = function()
        error("boom")
      end,
      layerOf = function()
        error("boom")
      end,
      isGroupMember = function()
        error("boom")
      end,
    }))
    assert.are.equal(2, #pins)
    assert.is_nil(pins[1].layer)
  end)

  it("never gives a negative age", function()
    local pins = ns.PositionPins.Build(build({
      now = function()
        return 50
      end,
    }))
    assert.are.equal(0, pins[1].age)
  end)

  it("draws nothing when both maps are off, and nothing for an empty list", function()
    assert.are.same({}, ns.PositionPins.Build(build({ settings = { minimap = false, worldmap = false } })))
    assert.are.same({}, ns.PositionPins.Build(build({ list = {} })))
    assert.are.same({}, ns.PositionPins.Build(build({ list = false })))
    assert.are.equal(2, #ns.PositionPins.Build(build({ settings = false })))
  end)

  it("skips an entry whose coordinates are not usable", function()
    local pins = ns.PositionPins.Build(build({
      list = { { name = "Ann", map = 1, x = "x", y = 1, at = 100 } },
    }))
    assert.are.same({}, pins)
  end)
end)
