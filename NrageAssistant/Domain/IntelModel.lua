local _, ns = ...

-- Pure helpers for Intel (docs/PVP_INTEL_PLAN.md): names and keys, the Kill On Sight fields, the rule that decides
-- where detection runs, and the wire text of a sighting. Nothing here touches the client, and every received byte
-- is hostile: a text that is not exactly what was asked for is refused.
--
-- A sighting is "I1:<map>:<x>:<y>:<class>:<race>:<level>:<flags>:<name>"
--   map 1..9999; x and y 0..10000 (the reporter's position, not the enemy's); class and race are the position in
--   Constants.INTEL_CLASSES and INTEL_RACES (0 is unknown); level 0..100 (0 is unknown); flags 0..3 (bit 1 stealth,
--   bit 2 estimated level); name last, so it is the only field that can hold spaces.
-- The text is at most Constants.INTEL_MAX_BYTES bytes.
local IntelModel = {}

local FLAG_STEALTH, FLAG_ESTIMATED = 1, 2
local MAX_DIGITS = 5

-- The key of a name: a "-Realm" suffix dropped, lowercase, no whitespace. Nil when nothing is left. The same key is
-- used for the personal lists, the guild list and the player records.
function IntelModel.Key(name)
  if type(name) ~= "string" then
    return nil
  end
  local key = ns.Validate.NameKey(name:match("^([^%-]*)"))
  return key ~= "" and key or nil
end

-- The name as it is kept: realm suffix dropped, edges trimmed and inner runs of spaces made one. Nil when it is empty,
-- longer than Constants.INTEL_NAME_MAX, or holds "|", ":" or a control character (they break the wire text, the
-- removal marks and the text renderer).
function IntelModel.CleanName(name)
  if type(name) ~= "string" then
    return nil
  end
  local clean = name:match("^([^%-]*)"):gsub("%s+", " "):match("^%s*(.-)%s*$")
  if not ns.Validate.Text(clean, ns.Constants.INTEL_NAME_MAX) or clean:find(":", 1, true) then
    return nil
  end
  return clean
end

-- Text from the client (a guild name) made safe to show: "|" and control characters removed, cut to `max` bytes
-- (default INTEL_NAME_MAX). Nil when nothing is left.
function IntelModel.Plain(text, max)
  if type(text) ~= "string" then
    return nil
  end
  local plain = text:gsub("[|%c]", ""):sub(1, max or ns.Constants.INTEL_NAME_MAX)
  return plain ~= "" and plain or nil
end

-- True once after the migration turned sharing the sightings on for this account, so the player can be told.
function IntelModel.TakeShareNotice(db)
  local settings = db.global.settings
  if type(settings) ~= "table" or settings.intelShareNotice ~= true then
    return false
  end
  settings.intelShareNotice = nil
  return true
end

local function indexIn(list, value)
  for index, entry in ipairs(list) do
    if entry == value then
      return index
    end
  end
  return nil
end

function IntelModel.CategoryValid(value)
  return indexIn(ns.Constants.INTEL_KOS_CATEGORIES, value) ~= nil
end

-- Returns { name, key, category, reason } for the fields of a Kill On Sight entry, or nil plus
-- "bad_name" | "bad_category" | "long_reason" | "bad_reason". The category defaults to "other" and the reason is
-- optional (nil when absent or blank), trimmed and cleaned like a blacklist reason.
function IntelModel.ValidateKos(fields)
  if type(fields) ~= "table" then
    return nil, "bad_name"
  end
  local name = IntelModel.CleanName(fields.name)
  if not name then
    return nil, "bad_name"
  end
  local category = fields.category
  if category == nil then
    category = "other"
  elseif not IntelModel.CategoryValid(category) then
    return nil, "bad_category"
  end
  local reason = fields.reason
  if reason ~= nil then
    if type(reason) ~= "string" then
      return nil, "bad_reason"
    end
    reason = reason:match("^%s*(.-)%s*$")
    if reason == "" then
      reason = nil
    elseif #reason > ns.Constants.INTEL_REASON_MAX then
      return nil, "long_reason"
    elseif not ns.Validate.Text(reason, ns.Constants.INTEL_REASON_MAX) then
      return nil, "bad_reason"
    end
  end
  return { name = name, key = IntelModel.Key(name), category = category, reason = reason }
end

-- May the contacts be read here? `context` = { instance = "none" | "pvp" | "arena" | "party" | "raid" (nil is none),
-- pvpType = the zone PvP type ("sanctuary"...), mapId }, `settings` = Settings.Intel. Returns true, or false plus
-- "disabled" | "dungeon" | "battleground" | "arena" | "sanctuary" | "excluded".
function IntelModel.DetectionAllowed(context, settings)
  if type(context) ~= "table" or type(settings) ~= "table" or settings.enabled ~= true then
    return false, "disabled"
  end
  local instance = context.instance
  if instance == "party" or instance == "raid" then
    return false, "dungeon"
  end
  if instance == "pvp" and settings.inBattleground ~= true then
    return false, "battleground"
  end
  if instance == "arena" and settings.inArena ~= true then
    return false, "arena"
  end
  if context.pvpType == "sanctuary" and settings.inSanctuary ~= true then
    return false, "sanctuary"
  end
  if context.mapId ~= nil and type(settings.excludedZones) == "table" and settings.excludedZones[context.mapId] then
    return false, "excluded"
  end
  return true
end

-- The wire text of a sighting { map, x, y, class, race, level, stealth, estimated, name }, or nil when a field is not
-- valid. `class` and `race` are file tokens; one that is nil or not in the lists goes as unknown. `level` nil is
-- unknown.
function IntelModel.EncodeSighting(fields)
  local constants = ns.Constants
  if type(fields) ~= "table" then
    return nil
  end
  local name = IntelModel.CleanName(fields.name)
  local level = fields.level == nil and 0 or fields.level
  if
    not (
      name
      and name == fields.name
      and ns.Validate.Int(fields.map, 1, constants.LAYER_MAP_MAX)
      and ns.Validate.Int(fields.x, 0, constants.POSITION_SCALE)
      and ns.Validate.Int(fields.y, 0, constants.POSITION_SCALE)
      and ns.Validate.Int(level, 0, 100)
    )
  then
    return nil
  end
  local flags = (fields.stealth == true and FLAG_STEALTH or 0) + (fields.estimated == true and FLAG_ESTIMATED or 0)
  local text = ("I1:%d:%d:%d:%d:%d:%d:%d:%s"):format(
    fields.map,
    fields.x,
    fields.y,
    indexIn(constants.INTEL_CLASSES, fields.class) or 0,
    indexIn(constants.INTEL_RACES, fields.race) or 0,
    level,
    flags,
    name
  )
  if #text > constants.INTEL_MAX_BYTES then
    return nil
  end
  return text
end

-- { map, x, y, class, race, level, stealth, estimated, name } for a received text (`class` and `race` are tokens, or
-- nil when unknown; `level` is nil when unknown), or nil plus "too_long" | "bad_format" | "out_of_range". Never
-- raises on a value that is not a string.
function IntelModel.DecodeSighting(text)
  local constants = ns.Constants
  if type(text) ~= "string" then
    return nil, "bad_format"
  end
  if #text > constants.INTEL_MAX_BYTES then
    return nil, "too_long"
  end
  local map, x, y, class, race, level, flags, name = text:match("^I1:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(.+)$")
  if not map then
    return nil, "bad_format"
  end
  for _, digits in ipairs({ map, x, y, class, race, level, flags }) do
    if #digits > MAX_DIGITS then
      return nil, "out_of_range"
    end
  end
  map, x, y, class, race, level, flags =
    tonumber(map), tonumber(x), tonumber(y), tonumber(class), tonumber(race), tonumber(level), tonumber(flags)
  if
    not (
      ns.Validate.Int(map, 1, constants.LAYER_MAP_MAX)
      and ns.Validate.Int(x, 0, constants.POSITION_SCALE)
      and ns.Validate.Int(y, 0, constants.POSITION_SCALE)
      and ns.Validate.Int(class, 0, #constants.INTEL_CLASSES)
      and ns.Validate.Int(race, 0, #constants.INTEL_RACES)
      and ns.Validate.Int(level, 0, 100)
      and ns.Validate.Int(flags, 0, FLAG_STEALTH + FLAG_ESTIMATED)
    )
  then
    return nil, "out_of_range"
  end
  -- The name must already be in the form this addon keeps: an extra field, a realm suffix or a stray space is not.
  if IntelModel.CleanName(name) ~= name then
    return nil, "bad_format"
  end
  return {
    map = map,
    x = x,
    y = y,
    class = constants.INTEL_CLASSES[class],
    race = constants.INTEL_RACES[race],
    level = level > 0 and level or nil,
    stealth = flags % 2 == 1,
    estimated = flags >= FLAG_ESTIMATED,
    name = name,
  }
end

-- The names of the classes and races, in the language of the player (the tables are made on first use, so a spec that
-- never asks for a name needs no locale). The tokens are the ones the client gives.
local classNames, raceNames

-- The name of a class token ("WARRIOR"), or nil when it is not one.
function IntelModel.ClassName(token)
  classNames = classNames
    or ns.Locale.Table(function()
      local L = ns.L
      return {
        WARRIOR = L("Warrior"),
        PALADIN = L("Paladin"),
        HUNTER = L("Hunter"),
        ROGUE = L("Rogue"),
        PRIEST = L("Priest"),
        SHAMAN = L("Shaman"),
        MAGE = L("Mage"),
        WARLOCK = L("Warlock"),
        DRUID = L("Druid"),
      }
    end)
  return type(token) == "string" and classNames[token] or nil
end

-- The name of a race token ("NIGHTELF"), or nil when it is not one.
function IntelModel.RaceName(token)
  raceNames = raceNames
    or ns.Locale.Table(function()
      local L = ns.L
      return {
        HUMAN = L("Human"),
        DWARF = L("Dwarf"),
        NIGHTELF = L("Night Elf"),
        GNOME = L("Gnome"),
        DRAENEI = L("Draenei"),
        ORC = L("Orc"),
        SCOURGE = L("Undead"),
        TAUREN = L("Tauren"),
        TROLL = L("Troll"),
        BLOODELF = L("Blood Elf"),
      }
    end)
  return type(token) == "string" and raceNames[token] or nil
end

ns.IntelModel = IntelModel
