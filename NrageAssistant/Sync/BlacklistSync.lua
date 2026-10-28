local _, ns = ...

-- Applies received blacklist changes to local data, and builds the payloads for them.
--
-- Authority: the sender's role comes from the receiver's own guild roster (`role`), never from the message.
-- BLACKLIST_UPSERT needs `blacklist_add` (every member) and, for a player who is already listed, to come from the
-- member who added the entry or from a gm or cogm; BLACKLIST_DELETE needs `blacklist_remove` (gm or cogm). The
-- author is the sender as well: a new entry gets `addedBy = sender`, every write `updatedBy = sender`, and the
-- payload has no field for either. The receiver works the key out from the name and drops a message whose key is
-- another one.
--
-- The one exception is a snapshot for a late joiner (see Transfer.ApplyItems): a leader relays entries that other
-- members added, and may name the original author and date of an item (`origin`), so a relay does not turn into
-- the author. That is accepted only for the items of a snapshot, which only a leader can send; a message on the
-- guild channel has nowhere to carry it.
--
-- Conflicts follow the other shared data: the higher `rev` wins, then the later (clamped) `updatedAt`, then the
-- larger sender; an identical message is a no-op. A removal leaves a tombstone "B:<key>", and an upsert whose
-- `rev` does not exceed the tombstone's is dropped, so an older copy cannot bring a removed player back; adding
-- the player again needs the revision above the tombstone's.
--
-- ctx = { blacklist = db.global.blacklist, tombstones = db.global.sync.tombstones, now = function() }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "bad_key" | "bad_origin" | "stale" | "tombstoned" | "limit" | "unsupported"
local BlacklistSync = {}

local Rules = ns.SyncRules
local countKeys, authorize, clampTimestamp = Rules.CountKeys, Rules.Authorize, Rules.ClampTimestamp

local MAX_TIMESTAMP = 4102444800 -- 2100-01-01, as in Protocol

-- The original author and date an item of a snapshot may carry, or nil when it carries none. Returns false when
-- one of them is there but unusable.
local function readOrigin(origin)
  if origin == nil then
    return nil
  end
  if type(origin) ~= "table" or not ns.EventModel.IsCharacterKey(origin.addedBy) then
    return false
  end
  if not ns.Validate.Int(origin.addedAt, 0, MAX_TIMESTAMP) then
    return false
  end
  return { addedBy = origin.addedBy, addedAt = origin.addedAt }
end

local function applyUpsert(ctx, payload, sender, role, origin)
  local denied = authorize(role, "blacklist_add")
  if denied then
    return false, denied
  end
  if ns.BlacklistService.Key(payload.name) ~= payload.key then
    return false, "bad_key"
  end
  origin = readOrigin(origin)
  if origin == false then
    return false, "bad_origin"
  end

  local tombstoneKey = "B:" .. payload.key
  if Rules.BlockedByTombstone(ctx, tombstoneKey, payload.rev) then
    return false, "tombstoned"
  end

  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local entry = ctx.blacklist[payload.key]
  if entry then
    -- Only the member who added the entry, or a gm or cogm, may change a player who is already listed. Inside a
    -- snapshot the sender is the leader who relays it, so a relay changes an entry only when the leader is gm or cogm.
    if not ns.BlacklistService.CanEdit(entry, sender, role) then
      return false, "forbidden"
    end
    if not Rules.Wins(payload.rev, updatedAt, sender, entry) then
      return false, "stale"
    end
  else
    if countKeys(ctx.blacklist) >= ns.Constants.BLACKLIST_MAX then
      return false, "limit"
    end
    entry = {
      addedBy = origin and origin.addedBy or sender,
      addedAt = origin and math.min(origin.addedAt, updatedAt) or updatedAt,
    }
    ctx.blacklist[payload.key] = entry
  end

  entry.name = payload.name
  entry.reason = payload.reason
  entry.rev = payload.rev
  entry.updatedAt = updatedAt
  entry.updatedBy = sender
  ctx.tombstones[tombstoneKey] = nil
  return true
end

local function applyDelete(ctx, payload, _, role)
  local denied = authorize(role, "blacklist_remove")
  if denied then
    return false, denied
  end

  local entry = ctx.blacklist[payload.key]
  local tombstoneKey = "B:" .. payload.key
  local tombstone = ctx.tombstones[tombstoneKey]
  if entry and entry.rev >= payload.rev then
    return false, "stale"
  end
  if not entry and tombstone and tombstone.rev >= payload.rev then
    return false, "stale"
  end

  ctx.blacklist[payload.key] = nil
  -- Remembered even when the entry is unknown here, so a late older upsert is still dropped.
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, tombstoneKey, payload.rev)
  return true
end

local APPLIERS = { BLACKLIST_UPSERT = applyUpsert, BLACKLIST_DELETE = applyDelete }

function BlacklistSync.IsBlacklistMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` and `role` come from the client. `origin`
-- ({ addedBy, addedAt }) is only ever passed for an item of a snapshot.
function BlacklistSync.Apply(ctx, message, sender, role, origin)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role, origin)
end

-- Payload builders: what a local change looks like on the wire.

function BlacklistSync.UpsertPayload(key, entry)
  return { key = key, name = entry.name, reason = entry.reason, rev = entry.rev, updatedAt = entry.updatedAt }
end

-- Delete payloads reuse the revision stored in the tombstone the local removal left behind.
function BlacklistSync.DeletePayload(tombstones, key)
  local tombstone = tombstones["B:" .. key]
  if not tombstone then
    return nil
  end
  return { key = key, rev = tombstone.rev }
end

-- The payload of a message as the receiver will see it, or nil when it does not validate.
local function validPayload(messageType, payload)
  local message = ns.Protocol.Validate(ns.Protocol.Build(messageType, payload, "snapshot"))
  return message and message.p or nil
end

-- Items for a snapshot: the `max` most recently updated entries ({ t, p, addedBy, addedAt }: the author is kept
-- for a relay) and the `max` newest removals ({ t, p }). What does not validate is left out.
function BlacklistSync.SnapshotItems(entries, tombstones, max)
  local list = {}
  for key, entry in pairs(entries) do
    if type(entry) == "table" and type(entry.updatedAt) == "number" then
      list[#list + 1] = { key = key, entry = entry }
    end
  end
  table.sort(list, function(a, b)
    if a.entry.updatedAt ~= b.entry.updatedAt then
      return a.entry.updatedAt > b.entry.updatedAt
    end
    return a.key < b.key
  end)

  local items = {}
  for _, row in ipairs(list) do
    if #items >= max then
      break
    end
    local entry = row.entry
    local payload = validPayload("BLACKLIST_UPSERT", BlacklistSync.UpsertPayload(row.key, entry))
    if payload and readOrigin({ addedBy = entry.addedBy, addedAt = entry.addedAt }) then
      items[#items + 1] = { t = "BLACKLIST_UPSERT", p = payload, addedBy = entry.addedBy, addedAt = entry.addedAt }
    end
  end

  local removals = {}
  for tombstoneKey, tombstone in pairs(tombstones) do
    local key = tombstoneKey:match("^B:(.+)$")
    if key and type(tombstone) == "table" and type(tombstone.at) == "number" then
      removals[#removals + 1] = { key = key, rev = tombstone.rev, at = tombstone.at }
    end
  end
  table.sort(removals, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.key < b.key
  end)
  local added = 0
  for _, removal in ipairs(removals) do
    if added >= max then
      break
    end
    local payload = validPayload("BLACKLIST_DELETE", { key = removal.key, rev = removal.rev })
    if payload then
      items[#items + 1] = { t = "BLACKLIST_DELETE", p = payload }
      added = added + 1
    end
  end
  return items
end

ns.BlacklistSync = BlacklistSync
