local _, ns = ...

-- Local character profile. Every value carries its provenance: observed values come from the
-- client API, declared ones from the player. A value the API cannot give stays nil (unknown),
-- never a guess.
local ProfileService = {}

local L = ns.L

local SOURCE_LABELS = ns.Locale.Table(function()
  return {
    observed = L("verified"),
    declared = L("declared"),
    received = L("received"),
  }
end)

local LINES = ns.Locale.Table(function()
  return {
    { key = "class", label = L("Class") },
    { key = "level", label = L("Level") },
    { key = "ilvl", label = L("Item level") },
  }
end)

local function ensureTable(parent, key)
  if type(parent[key]) ~= "table" then
    parent[key] = {}
  end
  return parent[key]
end

-- Rebuilds the observed part of `profile` from the client. Manual fields are left untouched.
function ProfileService.Refresh(platform, profile)
  local now = platform.ServerTime()
  local provenance = ensureTable(profile, "provenance")

  local function observe(key, value)
    profile[key] = value
    provenance[key] = value ~= nil and { source = "observed", at = now } or nil
  end

  profile.identityKey = platform.GetIdentityKey()
  observe("guid", platform.GetGUID())
  observe("class", platform.GetClass())
  observe("level", platform.GetLevel())
  observe("ilvl", platform.GetAverageItemLevel())

  local professions = platform.GetProfessions()
  observe("professions", #professions > 0 and professions or nil)
  observe("enchants", platform.GetEquippedEnchants())
  observe("buffs", platform.GetActiveBuffs())
  ensureTable(profile, "fields")
end

-- The roles a player can declare, in display order. `role` is the main spec, `role2` the optional second one.
ProfileService.ROLES = { "Tank", "Dps", "Heal" }

local ROLE_ALIASES = { tank = "Tank", dps = "Dps", heal = "Heal", healer = "Heal" }

-- The canonical role for a declared value (any case, surrounding spaces ignored), or nil when it is not
-- one of the allowed roles or an unambiguous spelling of one (e.g. "healer" from the old free text box).
function ProfileService.NormalizeRole(value)
  if type(value) ~= "string" then
    return nil
  end
  return ROLE_ALIASES[value:match("^%s*(.-)%s*$"):lower()]
end

-- Returns true, or false plus "unknown_field" | "too_long" | "invalid_value".
-- An empty value clears the field. The roles only accept Tank, Dps or Heal.
function ProfileService.SetField(platform, profile, key, value)
  local constants = ns.Constants
  if not constants.MANUAL_FIELDS[key] then
    return false, "unknown_field"
  end
  if type(value) ~= "string" then
    return false, "invalid_value"
  end

  value = value:match("^%s*(.-)%s*$")
  if #value > constants.MAX_FIELD_LENGTH then
    return false, "too_long"
  end

  if (key == "role" or key == "role2") and value ~= "" then
    value = ProfileService.NormalizeRole(value)
    if not value then
      return false, "invalid_value"
    end
  end

  local fields = ensureTable(profile, "fields")
  if value == "" then
    fields[key] = nil
  else
    fields[key] = { value = value, source = "declared", at = platform.ServerTime() }
  end
  return true
end

-- Human-readable lines; each one says where its value comes from.
function ProfileService.Describe(profile)
  local provenance = profile.provenance or {}
  local lines = {}

  for _, spec in ipairs(LINES) do
    local value = profile[spec.key]
    local source = provenance[spec.key] and provenance[spec.key].source
    if value ~= nil and source then
      lines[#lines + 1] = ("%s: %s [%s]"):format(spec.label, tostring(value), SOURCE_LABELS[source])
    else
      lines[#lines + 1] = L("%s: unknown"):format(spec.label)
    end
  end

  local names = {}
  for _, profession in ipairs(profile.professions or {}) do
    names[#names + 1] = ("%s (%s)"):format(profession.name, tostring(profession.skill))
  end
  if #names > 0 then
    lines[#lines + 1] = L("Professions: %s [%s]"):format(table.concat(names, ", "), SOURCE_LABELS.observed)
  else
    lines[#lines + 1] = L("Professions: unknown")
  end

  local enchanted, equipped = 0, 0
  for _, enchantId in pairs(profile.enchants or {}) do
    equipped = equipped + 1
    if enchantId ~= 0 then
      enchanted = enchanted + 1
    end
  end
  if profile.enchants then
    lines[#lines + 1] = L("Enchants: %d of %d equipped items [%s]"):format(enchanted, equipped, SOURCE_LABELS.observed)
  else
    lines[#lines + 1] = L("Enchants: unknown")
  end
  if profile.buffs then
    lines[#lines + 1] = L("Active buffs: %d [%s]"):format(#profile.buffs, SOURCE_LABELS.observed)
  else
    lines[#lines + 1] = L("Active buffs: unknown")
  end

  local keys = {}
  for key in pairs(profile.fields or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local field = profile.fields[key]
    lines[#lines + 1] = ("%s: %s [%s]"):format(key, field.value, SOURCE_LABELS[field.source])
  end

  return lines
end

ns.ProfileService = ProfileService
