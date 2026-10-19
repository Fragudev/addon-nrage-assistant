local _, ns = ...

-- Account-wide settings (db.global.settings), read and written through these functions so every default lives in one
-- place and a damaged value never raises:
--   language        "auto" | "es" | "en"   the language of the window (auto follows the game client)
--   blacklistSound  boolean                the sound of the blacklist alert (the chat line and the warning stay)
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

ns.Settings = Settings
