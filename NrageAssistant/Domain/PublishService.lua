local _, ns = ...

-- Publication of the local profile to the guild. It is automatic and has no consent switch (issue #36): every
-- member running the addon shares what the guild needs to organise raids, and what is sent is exactly what
-- Describe() lists.
--   shared:     class, level, item level, professions, and the declared role and main
--   not shared: the declared notes, which stay on this computer
-- The profile is sent after login and again whenever it changes (PublishIfChanged), at most once per
-- PUBLISH_COOLDOWN_SECONDS. A publication cannot be recalled from the clients that already hold it.
local PublishService = {}

local L = ns.L

-- The declared fields that are shared. Anything else, notes included, is never sent.
local SHARED_FIELDS = { "role", "main" }

local MAX_PROFESSIONS = 8

-- Removes what the receiver would reject anyway (escape sequences, control characters).
local function clean(text)
  if type(text) ~= "string" then
    return nil
  end
  text = text:gsub("|", ""):gsub("%c", ""):match("^%s*(.-)%s*$")
  return text ~= "" and text or nil
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
      if entry.secondary == true then
        profession.secondary = true
      end
      result[#result + 1] = profession
    end
  end
  return #result > 0 and result or nil
end

local function buildFields(fields)
  local result = {}
  for _, key in ipairs(SHARED_FIELDS) do
    local field = fields and fields[key]
    local value = field and clean(field.value)
    if value then
      result[key] = value
    end
  end
  return next(result) and result or nil
end

-- Returns the PROFILE payload, or nil plus "missing_data". Unknown values are left out, never guessed.
function PublishService.BuildPayload(profile, rev)
  if type(profile.class) ~= "string" or type(profile.level) ~= "number" then
    return nil, "missing_data"
  end

  local payload = { rev = rev, class = profile.class, level = profile.level }
  if type(profile.ilvl) == "number" then
    payload.ilvl = profile.ilvl
  end
  payload.professions = buildProfessions(profile.professions)
  payload.fields = buildFields(profile.fields)
  return payload
end

-- A string that is the same for two payloads that say the same thing, whatever their revision.
local function fingerprint(payload)
  local parts = { payload.class, tostring(payload.level), tostring(payload.ilvl or "") }
  for _, profession in ipairs(payload.professions or {}) do
    parts[#parts + 1] = ("%s=%d%s"):format(profession.name, profession.skill, profession.secondary and "s" or "")
  end
  for _, key in ipairs(SHARED_FIELDS) do
    parts[#parts + 1] = key .. ":" .. ((payload.fields or {})[key] or "")
  end
  return table.concat(parts, "|")
end

-- Lines that show what is shared and what stays private.
function PublishService.Describe(profile)
  local payload = PublishService.BuildPayload(profile, 0)
  if not payload then
    return { L("Nothing can be shared yet: class or level is unknown.") }
  end

  local lines = { L("Shared with the guild: %s, level %d"):format(payload.class, payload.level) }
  if payload.ilvl then
    lines[#lines + 1] = L("Shared with the guild: item level %d"):format(payload.ilvl)
  end
  for _, profession in ipairs(payload.professions or {}) do
    lines[#lines + 1] = L("Shared with the guild: %s %d"):format(profession.name, profession.skill)
  end
  for _, key in ipairs(SHARED_FIELDS) do
    if payload.fields and payload.fields[key] then
      lines[#lines + 1] = L("Shared with the guild: %s = %s"):format(key, payload.fields[key])
    end
  end
  lines[#lines + 1] = L("Shared with the guild: the recipes you have learned, once you open each profession.")
  lines[#lines + 1] = L("Not shared: notes, enchants and buffs (they stay on this computer).")
  return lines
end

-- Publishes through `comm`. `character` = { profile, publish }.
-- Returns true, or false plus "missing_data" | "cooldown" | a send failure reason.
function PublishService.Publish(comm, character, platform)
  local constants = ns.Constants
  local now = platform.ServerTime()
  local state = character.publish

  if state.at and now - state.at < constants.PUBLISH_COOLDOWN_SECONDS then
    return false, "cooldown"
  end

  -- Server time keeps revisions monotonic even if the saved data is ever reset.
  local rev = math.max((state.rev or 0) + 1, now)
  local payload, reason = PublishService.BuildPayload(character.profile, rev)
  if not payload then
    return false, reason
  end

  local ok, sendReason = comm:Send("PROFILE", payload, "PROFILE")
  if not ok then
    return false, sendReason
  end
  state.rev = rev
  state.at = now
  state.fingerprint = fingerprint(payload)
  return true
end

-- Seconds until the own profile may be published again (0 when it may be now).
function PublishService.CooldownLeft(character, platform)
  local at = character.publish.at
  if not at then
    return 0
  end
  return math.max(0, ns.Constants.PUBLISH_COOLDOWN_SECONDS - (platform.ServerTime() - at))
end

-- Publishes only when what would be shared is not what was last sent. Returns true when it published, or false
-- plus "unchanged" | what Publish returns. A change that arrives inside the cooldown is not lost: it is still
-- different from the last one sent, so the next call publishes it.
function PublishService.PublishIfChanged(comm, character, platform)
  local payload, reason = PublishService.BuildPayload(character.profile, 0)
  if not payload then
    return false, reason
  end
  if character.publish.fingerprint == fingerprint(payload) then
    return false, "unchanged"
  end
  return PublishService.Publish(comm, character, platform)
end

ns.PublishService = PublishService
