local _, ns = ...

-- SavedVariables layout and migrations. Plain tables (no AceDB yet); the shape follows plan section 9:
--   db.global = { schemaVersion, roster, events, loot, templates, settings = { minimap },
--                 sync = { seen, tombstones } }
--   db.chars[identityKey] = { profile = {}, readiness = {}, consent = {}, publish = {}, pvp = {} }
local Store = {}

local function ensureTable(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end
  return parent[key]
end

-- Each entry upgrades a db to that version. All of them must be idempotent.
local MIGRATIONS = {
  [1] = function() end,
  [2] = function(db)
    local global = ensureTable(db, "global")
    ensureTable(global, "roster")
    ensureTable(global, "events")
    ensureTable(global, "loot")
    local sync = ensureTable(global, "sync")
    ensureTable(sync, "seen")
    ensureTable(sync, "tombstones")
    ensureTable(db, "chars")
    -- v1 kept the version at the top level.
    db.schemaVersion = nil
  end,
  -- v3: reusable assignment templates.
  [3] = function(db)
    ensureTable(ensureTable(db, "global"), "templates")
  end,
  -- v4: account-wide settings, starting with the minimap button (see MinimapButton.Settings).
  [4] = function(db)
    ensureTable(ensureTable(ensureTable(db, "global"), "settings"), "minimap")
  end,
  -- v5: per-character PvP counters (char.pvp, filled by PvPService.Ensure). Nothing global changes; GetChar
  -- creates the table for each character, so this only makes sure the characters already saved have it.
  [5] = function(db)
    for _, char in pairs(ensureTable(db, "chars")) do
      if type(char) == "table" then
        ensureTable(char, "pvp")
      end
    end
  end,
}

local function versionOf(db)
  local global = type(db.global) == "table" and db.global or nil
  local version = (global and global.schemaVersion) or db.schemaVersion
  if type(version) == "number" and version >= 0 and version % 1 == 0 then
    return version
  end
  return 0
end

-- Returns db, or nil plus "newer_schema" when the saved data comes from a newer addon version.
-- In that case the raw table is left untouched so the local data survives a downgrade.
function Store.Load(raw, targetVersion)
  targetVersion = targetVersion or ns.Constants.SCHEMA_VERSION
  local db = type(raw) == "table" and raw or {}

  local version = versionOf(db)
  if version > targetVersion then
    return nil, "newer_schema"
  end

  for target = version + 1, targetVersion do
    MIGRATIONS[target](db)
  end
  ensureTable(db, "global").schemaVersion = targetVersion
  return db
end

function Store.GetChar(db, identityKey)
  local char = ensureTable(db.chars, identityKey)
  ensureTable(char, "profile")
  ensureTable(char, "readiness")
  ensureTable(char, "consent")
  ensureTable(char, "publish")
  ensureTable(char, "pvp")
  return char
end

ns.Store = Store
