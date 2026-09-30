local _, ns = ...

-- Local character profile. Every value carries its provenance: observed values come from the
-- client API, declared ones from the player. A value the API cannot give stays nil (unknown),
-- never a guess.
local ProfileService = {}

local SOURCE_LABELS = {
  observed = "verified",
  declared = "declared",
  received = "received",
}

local LINES = {
  { key = "class", label = "Class" },
  { key = "level", label = "Level" },
  { key = "ilvl", label = "Item level" },
}

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
  ensureTable(profile, "fields")
end

-- Returns true, or false plus "unknown_field" | "too_long" | "invalid_value".
-- An empty value clears the field.
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
      lines[#lines + 1] = ("%s: unknown"):format(spec.label)
    end
  end

  local names = {}
  for _, profession in ipairs(profile.professions or {}) do
    names[#names + 1] = ("%s (%s)"):format(profession.name, tostring(profession.skill))
  end
  if #names > 0 then
    lines[#lines + 1] = ("Professions: %s [%s]"):format(table.concat(names, ", "), SOURCE_LABELS.observed)
  else
    lines[#lines + 1] = "Professions: unknown"
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
