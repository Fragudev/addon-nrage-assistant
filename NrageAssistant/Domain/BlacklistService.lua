local _, ns = ...

-- The guild blacklist: players the guild wants to be warned about, each with a short reason. Pure logic over
-- plain tables, no client API, so it is tested without a client.
--   blacklist[key] = { name, reason, addedBy, addedAt, rev, updatedAt, updatedBy }
-- `key` is the name without realm, lowercase and without spaces (Key). Names on Forever can have several words
-- ("Yonemon Gg"), so the key joins them; the name is kept as it was typed for display.
--
-- A removal leaves a tombstone "B:<key>" in the shared tombstones (the same bounded list the raid data uses), so
-- an older copy of the entry arriving later cannot bring it back; adding the player again needs a revision above
-- the tombstone's.
--
-- ctx = { blacklist = db.global.blacklist, tombstones = db.global.sync.tombstones, role, actor, now = function() }
local BlacklistService = {}

local Can = ns.PermissionService.Can

-- The key of a name: a "-Realm" suffix dropped, lowercase, no whitespace. Nil when nothing is left.
function BlacklistService.Key(name)
  if type(name) ~= "string" then
    return nil
  end
  local key = ns.Validate.NameKey(name:match("^([^%-]*)"))
  return key ~= "" and key or nil
end

-- The name as it is kept: realm suffix dropped, edges trimmed and inner runs of spaces made one.
function BlacklistService.CleanName(name)
  if type(name) ~= "string" then
    return nil
  end
  local clean = name:match("^([^%-]*)"):gsub("%s+", " "):match("^%s*(.-)%s*$")
  return clean ~= "" and clean or nil
end

-- The first word of a name, as the client's UnitName gives it for a multi-word name. Nil for a single word.
function BlacklistService.FirstWord(name)
  local first, rest = name:match("^(%S+)%s+(%S.*)$")
  return rest and first or nil
end

-- Returns { name, reason, key } for the text typed by a person, or nil plus
-- "empty_name" | "long_name" | "bad_name" | "empty_reason" | "long_reason" | "bad_reason".
function BlacklistService.Validate(name, reason)
  local constants = ns.Constants
  local clean = BlacklistService.CleanName(name)
  if not clean then
    return nil, "empty_name"
  end
  if #clean > constants.BLACKLIST_NAME_MAX then
    return nil, "long_name"
  end
  -- ":" would break the tombstone key, "|" and control characters are text-renderer escapes.
  if not ns.Validate.Text(clean, constants.BLACKLIST_NAME_MAX) or clean:find(":", 1, true) then
    return nil, "bad_name"
  end

  if type(reason) ~= "string" then
    return nil, "empty_reason"
  end
  reason = reason:match("^%s*(.-)%s*$")
  if reason == "" then
    return nil, "empty_reason"
  end
  if #reason > constants.BLACKLIST_REASON_MAX then
    return nil, "long_reason"
  end
  if not ns.Validate.Text(reason, constants.BLACKLIST_REASON_MAX) then
    return nil, "bad_reason"
  end
  return { name = clean, reason = reason, key = BlacklistService.Key(clean) }
end

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- The revision a new entry for `key` needs: 1, or one above the removal that is remembered.
function BlacklistService.NextRev(tombstones, key)
  local tombstone = tombstones["B:" .. key]
  return tombstone and (tombstone.rev + 1) or 1
end

-- Adds a player. Returns the entry, or nil plus "forbidden" | "exists" | "limit" | a Validate reason.
-- May `actor` (with `role`) change the reason of `entry`? The member who added it, and admins for any entry.
-- Names are compared the way keys are, ignoring case and spaces.
function BlacklistService.CanEdit(entry, actor, role)
  if Can(role, "blacklist_edit_any") then
    return true
  end
  return type(actor) == "string"
    and type(entry.addedBy) == "string"
    and ns.Validate.NameKey(actor) == ns.Validate.NameKey(entry.addedBy)
end

function BlacklistService.Add(ctx, name, reason)
  if not Can(ctx.role, "blacklist_add") then
    return nil, "forbidden"
  end
  local clean, why = BlacklistService.Validate(name, reason)
  if not clean then
    return nil, why
  end
  local now = ctx.now()
  local listed = ctx.blacklist[clean.key]
  if listed then
    -- Adding a player who is already listed changes the reason, but only for the one who added the entry and for
    -- admins; the name, who added it and when stay.
    if not BlacklistService.CanEdit(listed, ctx.actor, ctx.role) then
      return nil, "not_author"
    end
    listed.reason = clean.reason
    listed.rev = listed.rev + 1
    listed.updatedAt = now
    listed.updatedBy = ctx.actor
    return listed, clean.key, true
  end
  if countKeys(ctx.blacklist) >= ns.Constants.BLACKLIST_MAX then
    return nil, "limit"
  end

  local entry = {
    name = clean.name,
    reason = clean.reason,
    addedBy = ctx.actor,
    addedAt = now,
    rev = BlacklistService.NextRev(ctx.tombstones, clean.key),
    updatedAt = now,
    updatedBy = ctx.actor,
  }
  ctx.blacklist[clean.key] = entry
  -- The addition outranks the removal it follows; the entry's revision now says so.
  ctx.tombstones["B:" .. clean.key] = nil
  return entry, clean.key
end

-- Removes the entry of `key` and leaves a tombstone above its revision. Returns true plus the tombstone's
-- revision, or false plus "forbidden" | "not_found".
function BlacklistService.Remove(ctx, key)
  if not Can(ctx.role, "blacklist_remove") then
    return false, "forbidden"
  end
  local entry = ctx.blacklist[key]
  if not entry then
    return false, "not_found"
  end
  ctx.blacklist[key] = nil
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, "B:" .. key, entry.rev + 1)
  return true, entry.rev + 1
end

-- The entries as a list of copies with their `key`, sorted by name (then key).
function BlacklistService.List(entries)
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
function BlacklistService.Find(entries, name)
  local key = BlacklistService.Key(name)
  if not key or not entries[key] then
    return nil
  end
  return entries[key], key
end

-- Which of the group `members` (list of names, realm suffix or not) are on the blacklist. A member matches when
-- the whole key matches, or when the member is a single word equal to the first word of a listed name with
-- several: the client's UnitName gives only that first word, so the match is a guess (`approximate`), and a false
-- alarm is better than a warning that never fires. Each member is listed once, an exact match first. Returns a
-- list of { key, entry, member, approximate } in the order of `members`.
function BlacklistService.Match(entries, members)
  local firstWords = {}
  for key, entry in pairs(entries) do
    local first = type(entry) == "table" and type(entry.name) == "string" and BlacklistService.FirstWord(entry.name)
    if first then
      local word = ns.Validate.NameKey(first)
      firstWords[word] = firstWords[word] or {}
      table.insert(firstWords[word], key)
    end
  end

  local matches = {}
  for _, member in ipairs(members) do
    local key = BlacklistService.Key(member)
    if key and entries[key] then
      matches[#matches + 1] = { key = key, entry = entries[key], member = member, approximate = false }
    elseif key and not BlacklistService.FirstWord(member) and firstWords[key] then
      -- Several listed names can share a first word: the alphabetically first one is named, the rest are guesses too.
      table.sort(firstWords[key])
      local guess = firstWords[key][1]
      matches[#matches + 1] = { key = guess, entry = entries[guess], member = member, approximate = true }
    end
  end
  return matches
end

ns.BlacklistService = BlacklistService
