local _, ns = ...

-- The guild Kill On Sight list: enemy players the whole guild wants to know about, each with a category and an
-- optional reason (docs/PVP_INTEL_PLAN.md section 3.2). Pure logic over plain tables, no client API. It follows the
-- pattern of BlacklistService.
--   guildKos[key] = { name, category, reason, addedBy, addedAt, rev, updatedAt, updatedBy }
-- `key` is IntelModel.Key(name), the name without realm, lowercase and without spaces.
--
-- Who may do what: every member adds; the member who added an entry, and gm and cogm for any entry, change or remove
-- it. A removal leaves a tombstone "K:<key>" in the shared tombstones (the same bounded list the raid data uses), so an
-- older copy of the entry arriving later cannot bring it back; adding the player again needs a revision above the
-- tombstone's.
--
-- ctx = { guildKos = db.global.guildKos, tombstones = db.global.sync.tombstones, role, actor, now = function() }
local GuildKosService = {}

local Can = ns.PermissionService.Can

-- Does `actor` (with `role`) own `entry`, the way the author of a blacklist entry does? Names are compared as keys.
local function isAuthor(entry, actor)
  return type(actor) == "string"
    and type(entry.addedBy) == "string"
    and ns.Validate.NameKey(actor) == ns.Validate.NameKey(entry.addedBy)
end

-- May `actor` change the category and reason of `entry`? The member who added it, and gm and cogm for any entry.
function GuildKosService.CanEdit(entry, actor, role)
  return Can(role, "kos_edit_any") or isAuthor(entry, actor)
end

-- May `actor` remove `entry`? The member who added it, and gm and cogm for any entry.
function GuildKosService.CanRemove(entry, actor, role)
  return Can(role, "kos_remove_any") or isAuthor(entry, actor)
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- The revision a new entry for `key` needs: 1, or one above the removal that is remembered.
function GuildKosService.NextRev(tombstones, key)
  local tombstone = tombstones["K:" .. key]
  return tombstone and (tombstone.rev + 1) or 1
end

-- Adds a player, or changes the category and reason of one already listed (only its author, gm and cogm may; the
-- name, who added it and when stay). `fields` = { name, category, reason }. Returns the entry, its key and true when
-- an existing entry was changed; or nil plus "forbidden" | "not_author" | "limit" | an IntelModel.ValidateKos reason.
function GuildKosService.Add(ctx, fields)
  if not Can(ctx.role, "kos_add") then
    return nil, "forbidden"
  end
  local clean, why = ns.IntelModel.ValidateKos(fields)
  if not clean then
    return nil, why
  end
  local now = ctx.now()
  local listed = ctx.guildKos[clean.key]
  if listed then
    if not GuildKosService.CanEdit(listed, ctx.actor, ctx.role) then
      return nil, "not_author"
    end
    listed.category, listed.reason = clean.category, clean.reason
    listed.rev = listed.rev + 1
    listed.updatedAt = now
    listed.updatedBy = ctx.actor
    return listed, clean.key, true
  end
  if countKeys(ctx.guildKos) >= ns.Constants.INTEL_KOS_MAX then
    return nil, "limit"
  end

  local entry = {
    name = clean.name,
    category = clean.category,
    reason = clean.reason,
    addedBy = ctx.actor,
    addedAt = now,
    rev = GuildKosService.NextRev(ctx.tombstones, clean.key),
    updatedAt = now,
    updatedBy = ctx.actor,
  }
  ctx.guildKos[clean.key] = entry
  -- The addition outranks the removal it follows; the entry's revision now says so.
  ctx.tombstones["K:" .. clean.key] = nil
  return entry, clean.key
end

-- Removes the entry of `key` and leaves a tombstone above its revision. Returns true plus the tombstone's revision,
-- or false plus "forbidden" | "not_found".
function GuildKosService.Remove(ctx, key)
  if not Can(ctx.role, "kos_add") then
    return false, "forbidden"
  end
  local entry = ctx.guildKos[key]
  if not entry then
    return false, "not_found"
  end
  if not GuildKosService.CanRemove(entry, ctx.actor, ctx.role) then
    return false, "forbidden"
  end
  ctx.guildKos[key] = nil
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, "K:" .. key, entry.rev + 1)
  return true, entry.rev + 1
end

-- The entries as a list of copies with their `key`, sorted by name (then key).
function GuildKosService.List(entries)
  local list = {}
  for key, entry in pairs(entries) do
    if type(entry) == "table" and type(entry.name) == "string" then
      local copy = { key = key }
      for field, value in pairs(entry) do
        copy[field] = value
      end
      list[#list + 1] = copy
    end
  end
  table.sort(list, function(a, b)
    local left, right = a.name:lower(), b.name:lower()
    if left ~= right then
      return left < right
    end
    return a.key < b.key
  end)
  return list
end

-- The entry for `name` (as typed, or with a realm suffix), plus its key; nil when it is not listed.
function GuildKosService.Find(entries, name)
  local key = ns.IntelModel.Key(name)
  if not key or not entries[key] then
    return nil
  end
  return entries[key], key
end

ns.GuildKosService = GuildKosService
