local _, ns = ...

-- Applies received guild Kill On Sight changes to local data, and builds the payloads for them. It follows
-- BlacklistSync.
--
-- Authority: the sender's role comes from the receiver's own guild roster (`role`), never from the message.
-- KOS_UPSERT needs `kos_add` (every member) and, for a player who is already listed, to come from the member who added
-- the entry or from a gm or cogm (`kos_edit_any`). KOS_DELETE needs the same member or a gm or cogm (`kos_remove_any`),
-- checked against the entry the receiver holds; a removal of a player this receiver does not know is only a gm or
-- cogm's to remember. The author is the sender: a new entry gets `addedBy = sender`, every write `updatedBy = sender`,
-- and the payload has no field for either. The receiver works the key out from the name and drops a message whose key
-- is another one.
--
-- The one exception is a snapshot for a late joiner (see Transfer.ApplyItems): a leader relays entries that other
-- members added, and may name the original author and date of an item (`origin`), so a relay does not turn into the
-- author. That is accepted only for the items of a snapshot, which only a leader can send.
--
-- Conflicts follow the other shared data: the higher `rev` wins, then the later (clamped) `updatedAt`, then the
-- larger sender; an identical message is a no-op. A removal leaves a tombstone "K:<key>", and an upsert whose `rev`
-- does not exceed the tombstone's is dropped; adding the player again needs the revision above the tombstone's.
--
-- ctx = { guildKos = db.global.guildKos, tombstones = db.global.sync.tombstones, now = function() }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "bad_key" | "bad_origin" | "stale" | "tombstoned" | "limit" | "unsupported"
local GuildKosSync = {}

local Rules = ns.SyncRules
local countKeys, authorize, clampTimestamp = Rules.CountKeys, Rules.Authorize, Rules.ClampTimestamp
local readOrigin = Rules.ReadOrigin

local function applyUpsert(ctx, payload, sender, role, origin)
  local denied = authorize(role, "kos_add")
  if denied then
    return false, denied
  end
  if ns.IntelModel.Key(payload.name) ~= payload.key then
    return false, "bad_key"
  end
  origin = readOrigin(origin)
  if origin == false then
    return false, "bad_origin"
  end

  local tombstoneKey = "K:" .. payload.key
  if Rules.BlockedByTombstone(ctx, tombstoneKey, payload.rev) then
    return false, "tombstoned"
  end

  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local entry = ctx.guildKos[payload.key]
  if entry then
    -- Inside a snapshot the sender is the leader who relays it, so a relay changes an entry only when the leader is gm
    -- or cogm.
    if not ns.GuildKosService.CanEdit(entry, sender, role) then
      return false, "forbidden"
    end
    if not Rules.Wins(payload.rev, updatedAt, sender, entry) then
      return false, "stale"
    end
  else
    if countKeys(ctx.guildKos) >= ns.Constants.INTEL_KOS_MAX then
      return false, "limit"
    end
    entry = {
      addedBy = origin and origin.addedBy or sender,
      addedAt = origin and math.min(origin.addedAt, updatedAt) or updatedAt,
    }
    ctx.guildKos[payload.key] = entry
  end

  entry.name = payload.name
  entry.category = payload.category
  entry.reason = payload.reason
  entry.rev = payload.rev
  entry.updatedAt = updatedAt
  entry.updatedBy = sender
  ctx.tombstones[tombstoneKey] = nil
  return true
end

local function applyDelete(ctx, payload, sender, role)
  local denied = authorize(role, "kos_add")
  if denied then
    return false, denied
  end

  local entry = ctx.guildKos[payload.key]
  local tombstoneKey = "K:" .. payload.key
  local tombstone = ctx.tombstones[tombstoneKey]
  if entry then
    if not ns.GuildKosService.CanRemove(entry, sender, role) then
      return false, "forbidden"
    end
    if entry.rev >= payload.rev then
      return false, "stale"
    end
  else
    -- Without the entry there is no author to compare with: only a gm or cogm may leave the mark.
    denied = authorize(role, "kos_remove_any")
    if denied then
      return false, denied
    end
    if tombstone and tombstone.rev >= payload.rev then
      return false, "stale"
    end
  end

  ctx.guildKos[payload.key] = nil
  -- Remembered even when the entry is unknown here, so a late older upsert is still dropped.
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, tombstoneKey, payload.rev)
  return true
end

local APPLIERS = { KOS_UPSERT = applyUpsert, KOS_DELETE = applyDelete }

function GuildKosSync.IsGuildKosMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` and `role` come from the client. `origin`
-- ({ addedBy, addedAt }) is only ever passed for an item of a snapshot.
function GuildKosSync.Apply(ctx, message, sender, role, origin)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role, origin)
end

-- Payload builders: what a local change looks like on the wire.

function GuildKosSync.UpsertPayload(key, entry)
  return {
    key = key,
    name = entry.name,
    category = entry.category,
    reason = entry.reason,
    rev = entry.rev,
    updatedAt = entry.updatedAt,
  }
end

-- Delete payloads reuse the revision stored in the tombstone the local removal left behind.
function GuildKosSync.DeletePayload(tombstones, key)
  local tombstone = tombstones["K:" .. key]
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

-- Items for a snapshot: the `max` most recently updated entries ({ t, p, addedBy, addedAt }: the author is kept for a
-- relay) and the `max` newest removals ({ t, p }). What does not validate is left out.
function GuildKosSync.SnapshotItems(entries, tombstones, max)
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
    local payload = validPayload("KOS_UPSERT", GuildKosSync.UpsertPayload(row.key, entry))
    if payload and readOrigin({ addedBy = entry.addedBy, addedAt = entry.addedAt }) then
      items[#items + 1] = { t = "KOS_UPSERT", p = payload, addedBy = entry.addedBy, addedAt = entry.addedAt }
    end
  end

  local removals = {}
  for tombstoneKey, tombstone in pairs(tombstones) do
    local key = tombstoneKey:match("^K:(.+)$")
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
    local payload = validPayload("KOS_DELETE", { key = removal.key, rev = removal.rev })
    if payload then
      items[#items + 1] = { t = "KOS_DELETE", p = payload }
      added = added + 1
    end
  end
  return items
end

ns.GuildKosSync = GuildKosSync
