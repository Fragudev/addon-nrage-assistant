-- Uses the real vendored libraries: the codec is only worth testing against them.
local function load_codec()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/Codec.lua"))("NrageAssistant", ns)
  local codec = ns.Codec.New({
    serialize = _G.LibStub("LibSerialize"),
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

  it("produces a string safe for the addon channel (no NUL)", function()
    local text = assert(codec:Encode({ t = "HELLO", p = { version = "0.1.0" } }))
    assert.is_nil(text:find("\0", 1, true))
  end)

  it("refuses to encode a message that is too large", function()
    local noise = {}
    math.randomseed(42)
    for i = 1, 6000 do noise[i] = string.char(math.random(0, 255)) end
    local text, reason = codec:Encode({ blob = table.concat(noise) })
    assert.is_nil(text)
    assert.are.equal("too_large", reason)
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
    local libs = { serialize = _G.LibStub("LibSerialize"), deflate = _G.LibStub("LibDeflate") }
    local serialized = libs.serialize:Serialize("just a string")
    local text = libs.deflate:EncodeForWoWAddonChannel(libs.deflate:CompressDeflate(serialized))
    local value, reason = codec:Decode(text)
    assert.is_nil(value)
    assert.are.equal("bad_payload", reason)
  end)

  it("rejects content that decompresses beyond the limit", function()
    local libs = { serialize = _G.LibStub("LibSerialize"), deflate = _G.LibStub("LibDeflate") }
    local big = libs.serialize:Serialize({ blob = ("x"):rep(Constants.MAX_DECOMPRESSED_BYTES + 1) })
    local text = libs.deflate:EncodeForWoWAddonChannel(libs.deflate:CompressDeflate(big))
    assert.is_true(#text <= Constants.MAX_ENCODED_BYTES)
    local value, reason = codec:Decode(text)
    assert.is_nil(value)
    assert.are.equal("too_large", reason)
  end)
end)
