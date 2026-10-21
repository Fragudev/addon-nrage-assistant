local function load_model()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/PositionModel" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_model()
local PositionModel, Constants = ns.PositionModel, ns.Constants

describe("PositionModel.Settings", function()
  it("shares nothing by default and shows the guild on both maps", function()
    local db = { global = {} }
    assert.are.same({ share = false, minimap = true, worldmap = true }, PositionModel.Settings(db))
    assert.are.same({ share = false, minimap = true, worldmap = true }, db.global.settings.position)
  end)

  it("keeps what the player chose", function()
    local db = { global = { settings = { position = { share = true, minimap = false, worldmap = true } } } }
    assert.are.same({ share = true, minimap = false, worldmap = true }, PositionModel.Settings(db))
  end)

  it("falls back to the defaults for damaged values", function()
    for _, damaged in ipairs({ "x", 5, true }) do
      local db = { global = { settings = damaged } }
      assert.are.same({ share = false, minimap = true, worldmap = true }, PositionModel.Settings(db))
    end
    local db = { global = { settings = { position = { share = "yes", minimap = 0, worldmap = "no" } } } }
    assert.are.same({ share = false, minimap = true, worldmap = true }, PositionModel.Settings(db))
    db = { global = { settings = { position = "broken" } } }
    assert.are.same({ share = false, minimap = true, worldmap = true }, PositionModel.Settings(db))
  end)

  it("returns the stored table, so a change is saved", function()
    local db = { global = {} }
    PositionModel.Settings(db).share = true
    assert.is_true(db.global.settings.position.share)
  end)
end)

describe("PositionModel zone conversion", function()
  it("turns zone coordinates into the integers of the wire, rounded and clamped", function()
    assert.are.same({ 0, 0 }, { PositionModel.FromZone(0, 0) })
    assert.are.same({ 10000, 10000 }, { PositionModel.FromZone(1, 1) })
    assert.are.same({ 1235, 5000 }, { PositionModel.FromZone(0.12346, 0.5) })
    assert.are.same({ 0, 10000 }, { PositionModel.FromZone(-3, 7) })
  end)

  it("gives nothing for what is not a number", function()
    assert.is_nil(PositionModel.FromZone(nil, 0.5))
    assert.is_nil(PositionModel.FromZone(0.5, "0.5"))
    assert.is_nil(PositionModel.FromZone(0 / 0, 0.5))
  end)

  it("turns the integers back into zone coordinates, clamped", function()
    assert.are.same({ 0.5, 0.25 }, { PositionModel.ToZone(5000, 2500) })
    assert.are.same({ 0, 1 }, { PositionModel.ToZone(-5, 20000) })
    assert.is_nil(PositionModel.ToZone(nil, 1))
    assert.is_nil(PositionModel.ToZone(1, "1"))
    assert.is_nil(PositionModel.ToZone(1, 0 / 0))
  end)
end)

describe("PositionModel.Encode", function()
  it("writes the position as text", function()
    assert.are.equal("P1:1411:1235:5000", PositionModel.Encode({ map = 1411, x = 1235, y = 5000 }))
    assert.are.equal("P1:1:0:10000", PositionModel.Encode({ map = 1, x = 0, y = 10000 }))
  end)

  it("always fits the size limit", function()
    local text = PositionModel.Encode({ map = Constants.LAYER_MAP_MAX, x = 10000, y = 10000 })
    assert.is_true(#text <= Constants.POSITION_MAX_BYTES)
  end)

  it("refuses what is not a valid position", function()
    for _, position in ipairs({
      {},
      { map = 0, x = 1, y = 1 },
      { map = 1, x = -1, y = 1 },
      { map = 1, x = 1, y = 10001 },
      { map = 1.5, x = 1, y = 1 },
      { map = 10000, x = 1, y = 1 },
      { map = 1, x = "1", y = 1 },
    }) do
      assert.is_nil(PositionModel.Encode(position))
    end
    assert.is_nil(PositionModel.Encode("P1"))
    assert.is_nil(PositionModel.Encode(nil))
  end)

  it("writes the forget message", function()
    assert.are.equal("P1:0", PositionModel.EncodeForget())
  end)
end)

describe("PositionModel.Decode", function()
  it("reads a position", function()
    assert.are.same({ map = 1411, x = 1235, y = 5000 }, PositionModel.Decode("P1:1411:1235:5000"))
    assert.are.same({ map = 1, x = 0, y = 10000 }, PositionModel.Decode("P1:1:0:10000"))
  end)

  it("reads the forget message", function()
    assert.are.same({ forget = true }, PositionModel.Decode("P1:0"))
  end)

  it("round trips what Encode wrote", function()
    local position = { map = 37, x = 4321, y = 8765 }
    assert.are.same(position, PositionModel.Decode(PositionModel.Encode(position)))
  end)

  it("rejects a text that is too long", function()
    local _, reason = PositionModel.Decode("P1:1:" .. ("1"):rep(30) .. ":1")
    assert.are.equal("too_long", reason)
    local ok = "P1:1:1:" .. ("0"):rep(Constants.POSITION_MAX_BYTES - 7)
    assert.are.equal(Constants.POSITION_MAX_BYTES, #ok)
    local decoded = PositionModel.Decode(ok)
    assert.are.same({ map = 1, x = 1, y = 0 }, decoded)
  end)

  it("rejects a wrong tag, a missing part and anything that is not digits", function()
    for _, text in ipairs({
      "",
      "P2:1:1:1",
      "p1:1:1:1",
      "P1:1:1",
      "P1:1:1:1:1",
      "P1:a:1:1",
      "P1:1:-1:1",
      "P1:1:1.5:1",
      "P1:1: 1:1",
      "P1:1:1:1 ",
      "P1:00",
      "P1:0:0",
      "P1::1:1",
      "garbage",
    }) do
      local decoded, reason = PositionModel.Decode(text)
      assert.is_nil(decoded, text)
      assert.are.equal("bad_format", reason, text)
    end
  end)

  it("rejects a map or coordinates out of range", function()
    for _, text in ipairs({
      "P1:00:1:1",
      "P1:10000:1:1",
      "P1:1:10001:1",
      "P1:1:1:10001",
      "P1:1:99999:1",
    }) do
      local decoded, reason = PositionModel.Decode(text)
      assert.is_nil(decoded, text)
      assert.are.equal("out_of_range", reason, text)
    end
  end)

  it("rejects what is not a string", function()
    for _, value in ipairs({ 5, true, {} }) do
      local decoded, reason = PositionModel.Decode(value)
      assert.is_nil(decoded)
      assert.are.equal("bad_format", reason)
    end
    assert.is_nil(PositionModel.Decode(nil))
  end)
end)

describe("PositionModel.Moved", function()
  local a = { map = 1, x = 1000, y = 1000 }

  it("is true without something to compare with, or on another map", function()
    assert.is_true(PositionModel.Moved(nil, a))
    assert.is_true(PositionModel.Moved(a, nil))
    assert.is_true(PositionModel.Moved(a, { map = 2, x = 1000, y = 1000 }))
  end)

  it("is true only when the distance is over the limit", function()
    local limit = Constants.POSITION_MIN_MOVE
    assert.is_false(PositionModel.Moved(a, { map = 1, x = 1000, y = 1000 }))
    assert.is_false(PositionModel.Moved(a, { map = 1, x = 1000 + limit, y = 1000 }))
    assert.is_true(PositionModel.Moved(a, { map = 1, x = 1000 + limit + 1, y = 1000 }))
    assert.is_true(PositionModel.Moved(a, { map = 1, x = 1000, y = 1000 - limit - 1 }))
    assert.is_false(PositionModel.Moved(a, { map = 1, x = 1014, y = 1014 }))
    assert.is_true(PositionModel.Moved(a, { map = 1, x = 1015, y = 1015 }))
  end)
end)
