local _, ns = ...

-- Applies the recipe lists received from the members, and builds the messages for the own.
--
--   RECIPES  { prof, name, rev, updatedAt, part, parts, total, ids }
--
-- The list of one profession of one member is sent as `parts` messages of at most RECIPE_CHUNK ids (a profession can
-- have
-- hundreds of recipes and a message is limited to MAX_ENCODED_BYTES). The record belongs to the sender: there is no
-- name in
-- the payload, and a member can only publish their own, whatever their role (`recipes_publish`). Authority is read
-- from the
-- receiver's own guild roster, never from the message.
--
-- Parts are kept aside (in memory only) until the list is complete, and only then replace what is stored, so a list
-- that
-- never arrives complete changes nothing. A newer `rev` starts a new list and drops the half-received older one; a
-- list whose
-- `rev` does not beat the stored one is ignored. Everything is bounded: ids per profession, professions per member,
-- members, and lists waiting for parts.
--
-- ctx = { recipes = db.global.recipes, staging = {} (kept by the caller between messages), now = function(),
--         onStored = function() (optional) }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "stale" | "incomplete" | "bad_parts" | "limit" | "unsupported"
-- `true` with a second value "partial" means the part was kept and the list is not complete yet.
local RecipeSync = {}

local Rules = ns.SyncRules

local MESSAGE = "RECIPES"

function RecipeSync.IsRecipeMessage(messageType)
  return messageType == MESSAGE
end

local function countKeys(tbl)
  return Rules.CountKeys(tbl)
end

-- Drops the oldest list waiting for parts when there are too many.
local function trimStaging(staging)
  local count = 0
  for _ in pairs(staging) do
    count = count + 1
  end
  while count >= ns.Constants.RECIPE_STAGING_MAX do
    local oldestKey, oldestAt
    for key, entry in pairs(staging) do
      if not oldestAt or entry.at < oldestAt then
        oldestKey, oldestAt = key, entry.at
      end
    end
    staging[oldestKey] = nil
    count = count - 1
  end
end

-- `message` must already be validated by Protocol. `sender` and `role` come from the client.
function RecipeSync.Apply(ctx, message, sender, role)
  if message.t ~= MESSAGE then
    return false, "unsupported"
  end
  local denied = Rules.Authorize(role, "recipes_publish")
  if denied then
    return false, denied
  end
  local payload = message.p
  local constants = ns.Constants

  local owned = ctx.recipes[sender]
  local record = owned and owned[payload.prof]
  if record and record.rev >= payload.rev then
    return false, "stale"
  end
  if not owned and countKeys(ctx.recipes) >= constants.RECIPE_MEMBERS_MAX then
    return false, "limit"
  end
  if not record and owned and countKeys(owned) >= constants.RECIPE_PROFESSIONS_MAX then
    return false, "limit"
  end

  local key = sender .. "\n" .. payload.prof
  local entry = ctx.staging[key]
  if entry and entry.rev > payload.rev then
    return false, "stale"
  end
  if not entry or entry.rev < payload.rev or entry.parts ~= payload.parts then
    trimStaging(ctx.staging)
    entry = { rev = payload.rev, parts = payload.parts, got = {}, count = 0, ids = 0, at = ctx.now() }
    ctx.staging[key] = entry
  end
  if not entry.got[payload.part] then
    entry.count = entry.count + 1
    entry.ids = entry.ids + #payload.ids
    if entry.ids > constants.RECIPES_MAX_PER_PROFESSION then
      ctx.staging[key] = nil
      return false, "limit"
    end
  end
  entry.got[payload.part] = payload.ids
  entry.name = payload.name or entry.name
  entry.at = ctx.now()
  if entry.count < entry.parts then
    return true, "partial"
  end

  -- Complete: put the parts together and check the whole, the way a single message is checked.
  local ids, seen = {}, {}
  for part = 1, entry.parts do
    for _, id in ipairs(entry.got[part] or {}) do
      if seen[id] then
        ctx.staging[key] = nil
        return false, "bad_parts"
      end
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  ctx.staging[key] = nil
  table.sort(ids)
  if not owned then
    owned = {}
    ctx.recipes[sender] = owned
  end
  owned[payload.prof] = {
    name = entry.name,
    ids = ids,
    rev = payload.rev,
    receivedAt = ctx.now(),
  }
  if ctx.onStored then
    ctx.onStored()
  end
  return true
end

-- Payload builders: what a local change looks like on the wire.
function RecipeSync.Payloads(professionId, record, now)
  return ns.RecipeService.Chunks(professionId, record, now)
end

ns.RecipeSync = RecipeSync
