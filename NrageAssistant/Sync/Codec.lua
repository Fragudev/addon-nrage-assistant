local _, ns = ...

-- Turns a message table into a wire string and back:
--   LibSerialize -> LibDeflate compress -> LibDeflate addon-channel encoding.
-- Decode treats its input as hostile: sizes are bounded before each stage, every library call
-- is protected, and nothing is ever executed (LibSerialize never uses loadstring).
local Codec = {}
Codec.__index = Codec

-- `libs` = { serialize = LibSerialize, deflate = LibDeflate }.
function Codec.New(libs)
  return setmetatable({ serialize = libs.serialize, deflate = libs.deflate }, Codec)
end

function Codec.Default()
  return Codec.New({
    serialize = LibStub("LibSerialize"),
    deflate = LibStub("LibDeflate"),
  })
end

-- Returns the wire string, or nil plus "too_large" | "encode_failed".
function Codec:Encode(message)
  local ok, encoded = pcall(function()
    local serialized = self.serialize:Serialize(message)
    local compressed = self.deflate:CompressDeflate(serialized)
    return self.deflate:EncodeForWoWAddonChannel(compressed)
  end)
  if not ok or type(encoded) ~= "string" then
    return nil, "encode_failed"
  end
  if #encoded > ns.Constants.MAX_ENCODED_BYTES then
    return nil, "too_large"
  end
  return encoded
end

-- Returns the decoded table, or nil plus
-- "not_string" | "too_large" | "bad_encoding" | "bad_compression" | "bad_payload".
function Codec:Decode(text)
  local constants = ns.Constants
  if type(text) ~= "string" then
    return nil, "not_string"
  end
  if #text > constants.MAX_ENCODED_BYTES then
    return nil, "too_large"
  end

  local ok, decoded = pcall(self.deflate.DecodeForWoWAddonChannel, self.deflate, text)
  if not ok or type(decoded) ~= "string" then
    return nil, "bad_encoding"
  end

  local decompressed
  ok, decompressed = pcall(self.deflate.DecompressDeflate, self.deflate, decoded)
  if not ok or type(decompressed) ~= "string" then
    return nil, "bad_compression"
  end
  if #decompressed > constants.MAX_DECOMPRESSED_BYTES then
    return nil, "too_large"
  end

  local success, value
  ok, success, value = pcall(self.serialize.Deserialize, self.serialize, decompressed)
  if not ok or not success or type(value) ~= "table" then
    return nil, "bad_payload"
  end
  return value
end

ns.Codec = Codec
