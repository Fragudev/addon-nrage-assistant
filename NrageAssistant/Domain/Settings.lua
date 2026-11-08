local _, ns = ...

-- Account-wide settings (db.global.settings), read and written through these functions so every default lives in one
-- place and a damaged value never raises:
--   language        "auto" | "es" | "en"   the language of the window (auto follows the game client)
--   blacklistSound  boolean                the sound of the blacklist alert (the chat line and the warning stay)
--   intel           table                  the Intel settings (Settings.Intel; docs/PVP_INTEL_PLAN.md section 2)
-- The minimap button keeps its own settings (MinimapButton.Settings) and the window positions theirs.
local Settings = {}

Settings.LANGUAGES = { "auto", "es", "en" }

local function settingsOf(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  return db.global.settings
end

-- "auto" | "es" | "en".
function Settings.Language(db)
  local value = settingsOf(db).language
  for _, language in ipairs(Settings.LANGUAGES) do
    if value == language then
      return value
    end
  end
  return "auto"
end

-- Returns true, or false plus "invalid" for something that is not one of Settings.LANGUAGES.
function Settings.SetLanguage(db, value)
  for _, language in ipairs(Settings.LANGUAGES) do
    if value == language then
      settingsOf(db).language = value
      return true
    end
  end
  return false, "invalid"
end

-- true unless the player switched the alert sound off.
function Settings.BlacklistSound(db)
  return settingsOf(db).blacklistSound ~= false
end

function Settings.SetBlacklistSound(db, enabled)
  settingsOf(db).blacklistSound = enabled ~= false
end

local function isBoolean(value)
  return type(value) == "boolean"
end

local function oneOf(allowed)
  return function(value)
    return allowed[value] == true
  end
end

local function removeMinutesValid(value)
  return ns.Validate.Int(value, 0, 15)
end

-- The Intel settings: key -> { default, valid(value) }. A value that is not valid is put back to its default.
local INTEL_SCALARS = {
  { "enabled", true, isBoolean },
  { "share", true, isBoolean },
  { "removeMinutes", 5, removeMinutesValid },
  { "sound", true, isBoolean },
  { "alertNew", false, isBoolean },
  { "alertKos", true, isBoolean },
  { "alertKosGuild", true, isBoolean },
  { "alertStealth", true, isBoolean },
  { "alertGuildReports", true, isBoolean },
  { "warnTarget", "window", oneOf({ window = true, error = true, none = true }) },
  { "announce", "none", oneOf({ none = true, self = true, party = true, raid = true, guild = true }) },
  { "inSanctuary", false, isBoolean },
  { "inBattleground", true, isBoolean },
  { "inArena", true, isBoolean },
  { "mapMode", "zone", oneOf({ all = true, zone = true, continent = true, none = true }) },
  { "mapFollow", false, isBoolean },
  { "worldmapPins", true, isBoolean },
  { "minimapTooltip", true, isBoolean },
  { "minimapFeed", false, isBoolean },
  { "targetButton", true, isBoolean },
}

local WINDOW_ROWS_MIN, WINDOW_ROWS_MAX = 1, 20

-- Keeps the entries of a set (`key = true`) the test accepts, as `true`.
local function repairSet(set, keyValid)
  if type(set) ~= "table" then
    return {}
  end
  for key, value in pairs(set) do
    if value ~= true or not keyValid(key) then
      set[key] = nil
    end
  end
  return set
end

local function raceValid(key)
  for _, race in ipairs(ns.Constants.INTEL_RACES) do
    if key == race then
      return true
    end
  end
  return false
end

local function mapValid(key)
  return ns.Validate.Int(key, 1, ns.Constants.LAYER_MAP_MAX)
end

-- The Intel settings (db.global.settings.intel), created and repaired as needed, so a damaged saved value never
-- raises and every default lives here. Returns the live table.
function Settings.Intel(db)
  local settings = settingsOf(db)
  if type(settings.intel) ~= "table" then
    settings.intel = {}
  end
  local intel = settings.intel
  for _, spec in ipairs(INTEL_SCALARS) do
    local key, default, valid = spec[1], spec[2], spec[3]
    if not valid(intel[key]) then
      intel[key] = default
    end
  end
  intel.alertRaces = repairSet(intel.alertRaces, raceValid)
  intel.excludedZones = repairSet(intel.excludedZones, mapValid)
  if type(intel.window) ~= "table" then
    intel.window = {}
  end
  local window = intel.window
  window.shown = window.shown ~= false
  window.locked = window.locked == true
  if not ns.Validate.Int(window.rows, WINDOW_ROWS_MIN, WINDOW_ROWS_MAX) then
    window.rows = 8
  end
  return intel
end

ns.Settings = Settings
