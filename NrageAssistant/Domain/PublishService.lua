local _, ns = ...

-- Voluntary publication of the local profile. Nothing leaves the client without consent, consent is
-- split per kind of data, and what is sent is exactly what Describe() previews.
--   profile    -> class, level, and the declared role/main fields
--   gear       -> item level
--   professions
--   notes      -> the declared notes field
-- Withdrawing consent stops future publications; it cannot recall what other clients already hold.
local PublishService = {}

PublishService.CONSENT_KEYS = { "profile", "gear", "professions", "notes" }

local CONSENT_SET = {}
for _, key in ipairs(PublishService.CONSENT_KEYS) do
  CONSENT_SET[key] = true
end

-- Which declared field needs which consent.
local FIELD_CONSENT = { role = "profile", main = "profile", notes = "notes" }

local MAX_PROFESSIONS = 8

-- Removes what the receiver would reject anyway (escape sequences, control characters).
local function clean(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("|", ""):gsub("%c", ""):match("^%s*(.-)%s*$")
  return text ~= "" and text or nil
end

-- Returns true, or false plus "unknown_key".
function PublishService.SetConsent(consent, key, enabled)
  if not CONSENT_SET[key] then
    return false, "unknown_key"
  end
  consent[key] = enabled and true or nil
  return true
end

local function buildProfessions(list)
  local result = {}
  for _, entry in ipairs(list or {}) do
    local name = clean(entry.name)
    if name and type(entry.skill) == "number" and #result < MAX_PROFESSIONS then
      local profession = { name = name, skill = entry.skill }
      if type(entry.max) == "number" then
        profession.max = entry.max
      end
      result[#result + 1] = profession
    end
  end
  return #result > 0 and result or nil
end

local function buildFields(fields, consent)
  local result = {}
  for key, needed in pairs(FIELD_CONSENT) do
    local field = fields and fields[key]
    local value = field and consent[needed] and clean(field.value)
    if value then
      result[key] = value
    end
  end
  return next(result) and result or nil
end

-- Returns the PROFILE payload for what the player consented to, or nil plus
-- "no_consent" | "missing_data". Unknown values are left out, never guessed.
function PublishService.BuildPayload(profile, consent, rev)
  if not consent.profile then
    return nil, "no_consent"
  end
  if type(profile.class) ~= "string" or type(profile.level) ~= "number" then
    return nil, "missing_data"
  end

  local payload = { rev = rev, class = profile.class, level = profile.level }
  if consent.gear and type(profile.ilvl) == "number" then
    payload.ilvl = profile.ilvl
  end
  if consent.professions then
    payload.professions = buildProfessions(profile.professions)
  end
  payload.fields = buildFields(profile.fields, consent)
  return payload
end

-- Lines that show what would be shared and what stays private.
function PublishService.Describe(profile, consent)
  local payload, reason = PublishService.BuildPayload(profile, consent, 0)
  if not payload then
    if reason == "no_consent" then
      return { "Nothing will be shared: profile consent is off. Use /nrage consent profile on." }
    end
    return { "Nothing can be shared yet: class or level is unknown." }
  end

  local lines = { ("Will share: %s, level %d"):format(payload.class, payload.level) }
  if payload.ilvl then
    lines[#lines + 1] = ("Will share: item level %d"):format(payload.ilvl)
  end
  for _, profession in ipairs(payload.professions or {}) do
    lines[#lines + 1] = ("Will share: %s %d"):format(profession.name, profession.skill)
  end
  local keys = {}
  for key in pairs(payload.fields or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    lines[#lines + 1] = ("Will share: %s = %s"):format(key, payload.fields[key])
  end

  for _, key in ipairs(PublishService.CONSENT_KEYS) do
    if not consent[key] then
      lines[#lines + 1] = ("Not shared: %s (no consent)"):format(key)
    end
  end
  return lines
end

-- Publishes through `comm`. `character` = { profile, consent, publish }.
-- Returns true, or false plus "no_consent" | "missing_data" | "cooldown" | a send failure reason.
function PublishService.Publish(comm, character, platform)
  local constants = ns.Constants
  local now = platform.ServerTime()
  local state = character.publish

  if state.at and now - state.at < constants.PUBLISH_COOLDOWN_SECONDS then
    return false, "cooldown"
  end

  -- Server time keeps revisions monotonic even if the saved data is ever reset.
  local rev = math.max((state.rev or 0) + 1, now)
  local payload, reason = PublishService.BuildPayload(character.profile, character.consent, rev)
  if not payload then
    return false, reason
  end

  local ok, sendReason = comm:Send("PROFILE", payload, "PROFILE")
  if not ok then
    return false, sendReason
  end
  state.rev = rev
  state.at = now
  return true
end

ns.PublishService = PublishService
