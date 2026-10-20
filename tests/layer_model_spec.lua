local function load_model()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LayerModel" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.LayerModel
end

local LayerModel = load_model()

describe("LayerModel.Parse", function()
  it("reads the map, the layer, the npc and the spawn from a creature GUID", function()
    assert.are.same(
      { kind = "Creature", map = 1, layer = 4321, npcId = 6491, spawnUid = "00012AB3" },
      LayerModel.Parse("Creature-0-3134-1-4321-6491-00012AB3")
    )
  end)

  it("reads a vehicle too", function()
    local parsed = LayerModel.Parse("Vehicle-0-3134-0-77-1234-0000ABCD")
    assert.are.equal("Vehicle", parsed.kind)
    assert.are.equal(77, parsed.layer)
  end)

  it("refuses players, pets and other kinds of GUID", function()
    assert.is_nil(LayerModel.Parse("Player-3134-0123ABCD"))
    assert.is_nil(LayerModel.Parse("Pet-0-3134-0-77-1234-0000ABCD"))
    assert.is_nil(LayerModel.Parse("GameObject-0-3134-0-77-1234-0000ABCD"))
  end)

  it("refuses malformed, empty and missing values", function()
    for _, value in ipairs({
      "",
      "Creature",
      "Creature-0-3134-0-77-1234",
      "Creature-0-3134-x-77-1234-0000ABCD",
      5,
      true,
      {},
    }) do
      assert.is_nil(LayerModel.Parse(value), tostring(value))
    end
    assert.is_nil(LayerModel.Parse(nil))
  end)

  it("refuses a zero layer (it means forget me) and a map out of range", function()
    assert.is_nil(LayerModel.Parse("Creature-0-3134-0-0-1234-0000ABCD"))
    assert.is_nil(LayerModel.Parse("Creature-0-3134-10000-77-1234-0000ABCD"))
    assert.is_nil(LayerModel.Parse("Creature-0-3134-0-99999999999-1234-0000ABCD"))
  end)

  it("never raises on a secret-like value", function()
    local secret = setmetatable({}, {
      __index = function()
        error("secret")
      end,
      __tostring = function()
        error("secret")
      end,
    })
    assert.is_nil(LayerModel.Parse(secret))
  end)
end)

describe("LayerModel helpers", function()
  it("makes a key from the map and the layer", function()
    assert.are.equal("1:4321", LayerModel.Key(1, 4321))
    assert.are_not.equal(LayerModel.Key(1, 5), LayerModel.Key(2, 5))
  end)

  it("compares layers by map and layer", function()
    assert.is_true(LayerModel.SameLayer({ map = 1, layer = 5 }, { map = 1, layer = 5, extra = true }))
    assert.is_false(LayerModel.SameLayer({ map = 1, layer = 5 }, { map = 2, layer = 5 }))
    assert.is_false(LayerModel.SameLayer({ map = 1, layer = 5 }, { map = 1, layer = 6 }))
    assert.is_false(LayerModel.SameLayer(nil, { map = 1, layer = 5 }))
    assert.is_false(LayerModel.SameLayer({ map = 1, layer = 5 }, "x"))
    assert.is_false(LayerModel.SameLayer({}, {}))
  end)

  it("labels a layer with the last four digits of its id", function()
    assert.are.equal("#4321", LayerModel.Describe(1, 4321))
    assert.are.equal("#4321", LayerModel.Describe(1, 1234321))
    assert.are.equal("#0007", LayerModel.Describe(1, 7))
    assert.are.equal("#????", LayerModel.Describe(1, nil))
  end)

  it("shares the layer by default and keeps a choice", function()
    local db = { global = {} }
    assert.is_true(LayerModel.Settings(db).share)
    db.global.settings.layer.share = false
    assert.is_false(LayerModel.Settings(db).share)
    db.global.settings = "broken"
    assert.is_true(LayerModel.Settings(db).share)
    db.global.settings.layer = { share = "yes" }
    assert.is_true(LayerModel.Settings(db).share)
  end)
end)
