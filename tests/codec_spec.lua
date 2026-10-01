local ns_codec

-- Uses the real vendored libraries: the codec is only worth testing against them.
local function load_codec()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/Codec.lua"))("NrageAssistant", ns)
  ns_codec = ns.Codec
  local codec = ns.Codec.New({
    serialize = _G.LibStub("NrageAssistant-LibSerialize"),
    deflate = _G.LibStub("LibDeflate"),
  })
  return codec, ns.Constants
end

describe("Codec", function()
  local codec, Constants = load_codec()

  it("round-trips a message", function()
    local message = { v = 1, m = 0, t = "PROFILE", id = "a-1", p = { rev = 2, class = "MAGE", level = 60 } }
    local text = assert(codec:Encode(message))
    assert.are.same(message, codec:Decode(text))
  end)

  it("round-trips zeros, which every real message carries (the protocol minor is 0)", function()
    -- Built at run time: Lua 5.1 compiles the literal -0 as a plain 0.
    local zero = 0
    local message = { v = 1, m = 0, t = "HELLO", id = "a-1", p = { count = 0, negative = -zero, small = 0.5 } }
    assert.is_true(1 / message.p.negative < 0)
    local decoded = assert(codec:Decode(assert(codec:Encode(message))))
    assert.are.equal(0, decoded.m)
    assert.are.equal(0, decoded.p.count)
    assert.are.equal(0.5, decoded.p.small)
    -- Negative zero keeps its sign, without the serializer dividing by it.
    assert.is_true(1 / decoded.p.negative < 0)
  end)

  it("produces a string safe for the addon channel (no NUL)", function()
    local text = assert(codec:Encode({ t = "HELLO", p = { version = "0.1.0" } }))
    assert.is_nil(text:find("\0", 1, true))
  end)

  it("refuses to encode a message that is too large", function()
    local noise = {}
    math.randomseed(42)
    for i = 1, 6000 do
      noise[i] = string.char(math.random(0, 255))
    end
    local text, reason = codec:Encode({ blob = table.concat(noise) })
    assert.is_nil(text)
    assert.are.equal("too_large", reason)
  end)

  it("says what the library reported when encoding fails", function()
    local broken = ns_codec.New({
      serialize = {
        Serialize = function()
          error("cannot serialize a function")
        end,
      },
      deflate = _G.LibStub("LibDeflate"),
    })
    local text, reason, detail = broken:Encode({ t = "HELLO" })
    assert.is_nil(text)
    assert.are.equal("encode_failed", reason)
    assert.is_truthy(detail:find("cannot serialize a function", 1, true))
  end)

  it("rejects input that is not a string", function()
    local value, reason = codec:Decode(nil)
    assert.is_nil(value)
    assert.are.equal("not_string", reason)
  end)

  it("rejects oversized input before decoding it", function()
    local value, reason = codec:Decode(("a"):rep(Constants.MAX_ENCODED_BYTES + 1))
    assert.is_nil(value)
    assert.are.equal("too_large", reason)
  end)

  it("rejects garbage without raising", function()
    for _, garbage in ipairs({ "", "hello world", "\0\1\2\3", ("\255"):rep(64) }) do
      local value, reason = codec:Decode(garbage)
      assert.is_nil(value)
      assert.is_string(reason)
    end
  end)

  it("rejects a valid frame whose content is not a table", function()
    local libs = { serialize = _G.LibStub("NrageAssistant-LibSerialize"), deflate = _G.LibStub("LibDeflate") }
    local serialized = libs.serialize:Serialize("just a string")
    local text = libs.deflate:EncodeForWoWAddonChannel(libs.deflate:CompressDeflate(serialized))
    local value, reason = codec:Decode(text)
    assert.is_nil(value)
    assert.are.equal("bad_payload", reason)
  end)

  it("rejects content that decompresses beyond the limit", function()
    local libs = { serialize = _G.LibStub("NrageAssistant-LibSerialize"), deflate = _G.LibStub("LibDeflate") }
    local big = libs.serialize:Serialize({ blob = ("x"):rep(Constants.MAX_DECOMPRESSED_BYTES + 1) })
    local text = libs.deflate:EncodeForWoWAddonChannel(libs.deflate:CompressDeflate(big))
    assert.is_true(#text <= Constants.MAX_ENCODED_BYTES)
    local value, reason = codec:Decode(text)
    assert.is_nil(value)
    assert.are.equal("too_large", reason)
  end)
end)

describe("Codec size overrides", function()
  local codec, Constants = load_codec()

  local function noisy_message()
    local noise = {}
    math.randomseed(11)
    for i = 1, 6000 do
      noise[i] = string.char(math.random(0, 255))
    end
    return { blob = table.concat(noise) }
  end

  it("allows a larger message when given a larger encode limit", function()
    local message = noisy_message()
    assert.are.equal("too_large", select(2, codec:Encode(message)))
    local text = assert(codec:Encode(message, Constants.SYNC_MAX_ENCODED_BYTES))
    assert.is_true(#text > Constants.MAX_ENCODED_BYTES)
  end)

  it("decodes a larger message only when given larger decode limits", function()
    local message = noisy_message()
    local text = assert(codec:Encode(message, Constants.SYNC_MAX_ENCODED_BYTES))

    local value, reason = codec:Decode(text)
    assert.is_nil(value)
    assert.are.equal("too_large", reason)

    local decoded = codec:Decode(text, {
      encoded = Constants.SYNC_MAX_ENCODED_BYTES,
      decompressed = Constants.SYNC_MAX_DECOMPRESSED_BYTES,
    })
    assert.are.equal(message.blob, decoded.blob)
  end)

  it("still enforces the override limits", function()
    local text = assert(codec:Encode({ hello = "world" }))
    assert.are.equal("too_large", select(2, codec:Decode(text, { encoded = 5 })))
    assert.are.equal("too_large", select(2, codec:Decode(text, { decompressed = 1 })))
  end)
end)

-- On the Forever client a division by zero raises an error, and the serializer once divided by a zero to find
-- out whether it was negative. That made every message fail to encode in game, which no spec outside the
-- game could notice, so this guards the vendored copy directly.
describe("Vendored LibSerialize", function()
  local function read(path)
    local file = assert(io.open(path, "r"))
    local content = file:read("*a")
    file:close()
    return content
  end

  it("never divides by the number it is serializing", function()
    local source = read("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")
    assert.is_nil(source:find("1 / num", 1, true))
  end)

  it("has its own name, so another addon's copy is never picked instead", function()
    local source = read("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")
    assert.is_truthy(source:find('"NrageAssistant-LibSerialize"', 1, true))
    assert.is_nil(source:find('"LibSerialize", ', 1, true))
  end)
end)
