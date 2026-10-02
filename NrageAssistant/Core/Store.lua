local _, ns = ...

-- SavedVariables layout and migrations. Plain tables (no AceDB yet); the shape follows plan section 9:
--   db.global = { schemaVersion, roster, events, loot, templates, settings = { minimap, pvp },
--                 sync = { seen, tombstones }, pvpStats = {}, pvpResets = {}, blacklist = {},
--                 readinessRules = { rev, updatedAt, updatedBy, rules } }
--   db.chars[identityKey] = { profile = {}, readiness = {}, consent = {}, publish = {}, pvp = {},
--                             pvpSync = { rev } }
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
  -- v6: PvP counters received from the guild (pvpStats[ownerKey]) and the minimum revision accepted for a
  -- member after an admin reset (pvpResets[ownerKey]); GetChar creates the revision of the own record.
  [6] = function(db)
    local global = ensureTable(db, "global")
    ensureTable(global, "pvpStats")
    ensureTable(global, "pvpResets")
  end,
  -- v7: account-wide PvP settings table (db.global.settings.pvp). The kill feed switches that lived there are
  -- gone: every kill is shared; the table is kept so older data migrates unchanged.
  [7] = function(db)
    ensureTable(ensureTable(ensureTable(db, "global"), "settings"), "pvp")
  end,
  -- v8: the guild blacklist (blacklist[nameKey], see BlacklistService). Its removals are tombstones "B:<key>" in
  -- sync.tombstones, which already exists.
  [8] = function(db)
    ensureTable(ensureTable(db, "global"), "blacklist")
  end,
  -- v9: the guild's readiness rules (readinessRules = { rev, updatedAt, updatedBy, rules }, see ReadinessRules).
  -- Empty until an admin sets them; the starting checklist applies meanwhile.
  [9] = function(db)
    ensureTable(ensureTable(db, "global"), "readinessRules")
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
  local sync = ensureTable(char, "pvpSync")
  if type(sync.rev) ~= "number" or sync.rev < 0 or sync.rev % 1 ~= 0 then
    sync.rev = 0
  end
  return char
end

ns.Store = Store
