local _, ns = ...

-- Pure helpers for guild map positions. Nothing here touches the client.
--
-- On the wire a position is "P1:<map>:<x>:<y>" with x and y as integers 0..10000 (the zone coordinates 0..1 times
-- Constants.POSITION_SCALE), and "P1:0" means "forget me". Anything else is dropped; a future format adds a new tag.
local PositionModel = {}

local FORGET = "P1:0"

-- The position settings, created and repaired as needed: { share, minimap, worldmap }. Sharing and drawing the guild
-- are on until the player turns them off.
function PositionModel.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.position = type(settings.position) == "table" and settings.position or {}
  local position = settings.position
  position.share = position.share ~= false
  position.minimap = position.minimap ~= false
  position.worldmap = position.worldmap ~= false
  return position
end

-- True once after the migration turned sharing on for this account, so the player can be told.
function PositionModel.TakeShareNotice(db)
  local settings = db.global.settings
  if type(settings) ~= "table" or settings.positionShareNotice ~= true then
    return false
  end
  settings.positionShareNotice = nil
  return true
end

-- The zone coordinates 0..1 as the integers of the wire, clamped and rounded. Not a number gives nil.
function PositionModel.FromZone(x, y)
  if type(x) ~= "number" or type(y) ~= "number" or x ~= x or y ~= y then
    return nil
  end
  local scale = ns.Constants.POSITION_SCALE
  local function convert(value)
    return math.floor(math.min(1, math.max(0, value)) * scale + 0.5)
  end
  return convert(x), convert(y)
end

-- The integers of the wire as zone coordinates 0..1 (clamped), which is what the map library takes.
function PositionModel.ToZone(ix, iy)
  if type(ix) ~= "number" or type(iy) ~= "number" or ix ~= ix or iy ~= iy then
    return nil
  end
  local scale = ns.Constants.POSITION_SCALE
  return math.min(1, math.max(0, ix / scale)), math.min(1, math.max(0, iy / scale))
end

local function validPosition(position)
  local constants = ns.Constants
  return type(position) == "table"
    and ns.Validate.Int(position.map, 1, constants.MAP_ID_MAX)
    and ns.Validate.Int(position.x, 0, constants.POSITION_SCALE)
    and ns.Validate.Int(position.y, 0, constants.POSITION_SCALE)
end

-- The wire text of { map, x, y } (x and y as integers 0..10000), or nil when it is not a valid position.
function PositionModel.Encode(position)
  if not validPosition(position) then
    return nil
  end
  return ("P1:%d:%d:%d"):format(position.map, position.x, position.y)
end

function PositionModel.EncodeForget()
  return FORGET
end

-- { map, x, y } or { forget = true } for a message, or nil plus "too_long" | "bad_format" | "out_of_range". Never
-- raises on a value that is not a string.
function PositionModel.Decode(text)
  if type(text) ~= "string" then
    return nil, "bad_format"
  end
  if #text > ns.Constants.POSITION_MAX_BYTES then
    return nil, "too_long"
  end
  if text == FORGET then
    return { forget = true }
  end
  local map, x, y = text:match("^P1:(%d+):(%d+):(%d+)$")
  if not map then
    return nil, "bad_format"
  end
  local position = { map = tonumber(map), x = tonumber(x), y = tonumber(y) }
  if not validPosition(position) then
    return nil, "out_of_range"
  end
  return position
end

-- Did the player move between two positions { map, x, y }? A different map always counts, otherwise the distance in
-- wire units has to be over Constants.POSITION_MIN_MOVE. Without a position to compare with, it moved.
function PositionModel.Moved(a, b)
  if type(a) ~= "table" or type(b) ~= "table" or a.map ~= b.map then
    return true
  end
  local dx, dy = a.x - b.x, a.y - b.y
  local limit = ns.Constants.POSITION_MIN_MOVE
  return dx * dx + dy * dy > limit * limit
end

ns.PositionModel = PositionModel
