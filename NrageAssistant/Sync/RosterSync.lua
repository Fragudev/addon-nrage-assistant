local _, ns = ...

-- Applies received roster definitions and member assignments, and builds the payloads for local changes.
--
--   ROSTER_UPSERT  { rosterId, name, rev, updatedAt }                    define or rename a roster
--   ROSTER_DELETE  { rosterId, rev }                                     remove a roster
--   MEMBER_UPSERT  { key, rosterId?, rev, updatedAt }                    the roster of a member
--   MEMBER_DELETE  { key, rev }                                          take the assignment of a member away
--
-- Authority: the sender's role comes from the receiver's own guild roster (`role`), never from the message, and every
-- one of these needs `members_manage` and, until phases 4 and 5 of docs/NAV_PERMISSIONS_PLAN.md add roster scoping,
-- a global rank (gm or cogm): rl would pass `members_manage` at its own scope, but is not accepted yet. The author of a
-- record is always the message sender.
--
-- Conflicts follow the other shared data: the higher `rev` wins, then the later (clamped) `updatedAt`, then the larger
-- sender; an identical message is a no-op. A removal leaves a tombstone ("R:<id>", "M:<key>"), and an upsert whose
-- `rev` does not exceed the tombstone's is dropped.
--
-- ctx = { rosters = db.global.rosters, members = db.global.members, tombstones = db.global.sync.tombstones,
--         now = function() }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "stale" | "tombstoned" | "limit" | "unsupported"
local RosterSync = {}

local Rules = ns.SyncRules
local countKeys, authorizeGlobal, clampTimestamp = Rules.CountKeys, Rules.AuthorizeGlobal, Rules.ClampTimestamp

local function applyRosterUpsert(ctx, payload, sender, role)
  local denied = authorizeGlobal(role, "members_manage")
  if denied then
    return false, denied
  end
  local tombstoneKey = "R:" .. payload.rosterId
  if Rules.BlockedByTombstone(ctx, tombstoneKey, payload.rev) then
    return false, "tombstoned"
  end
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local roster = ctx.rosters[payload.rosterId]
  if roster then
    if not Rules.Wins(payload.rev, updatedAt, sender, roster) then
      return false, "stale"
    end
  else
    if countKeys(ctx.rosters) >= ns.Constants.ROSTERS_MAX then
      return false, "limit"
    end
    roster = { id = payload.rosterId }
    ctx.rosters[payload.rosterId] = roster
  end
  roster.name = payload.name
  roster.rev = payload.rev
  roster.updatedAt = updatedAt
  roster.updatedBy = sender
  ctx.tombstones[tombstoneKey] = nil
  return true
end

local function applyRosterDelete(ctx, payload, _, role)
  local denied = authorizeGlobal(role, "members_manage")
  if denied then
    return false, denied
  end
  local tombstoneKey = "R:" .. payload.rosterId
  local roster = ctx.rosters[payload.rosterId]
  local tombstone = ctx.tombstones[tombstoneKey]
  if roster and roster.rev >= payload.rev then
    return false, "stale"
  end
  if not roster and tombstone and tombstone.rev >= payload.rev then
    return false, "stale"
  end
  ctx.rosters[payload.rosterId] = nil
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, tombstoneKey, payload.rev)
  return true
end

local function applyMemberUpsert(ctx, payload, sender, role)
  local denied = authorizeGlobal(role, "members_manage")
  if denied then
    return false, denied
  end
  local tombstoneKey = "M:" .. payload.key
  if Rules.BlockedByTombstone(ctx, tombstoneKey, payload.rev) then
    return false, "tombstoned"
  end
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local record = ctx.members[payload.key]
  if record then
    if not Rules.Wins(payload.rev, updatedAt, sender, record) then
      return false, "stale"
    end
  else
    if countKeys(ctx.members) >= ns.Constants.MEMBER_ASSIGNMENTS_MAX then
      return false, "limit"
    end
    record = {}
    ctx.members[payload.key] = record
  end
  -- A record carries the whole assignment: a roster it leaves out means "no roster".
  record.rosterId = payload.rosterId
  record.rev = payload.rev
  record.updatedAt = updatedAt
  record.updatedBy = sender
  ctx.tombstones[tombstoneKey] = nil
  return true
end

local function applyMemberDelete(ctx, payload, _, role)
  local denied = authorizeGlobal(role, "members_manage")
  if denied then
    return false, denied
  end
  local tombstoneKey = "M:" .. payload.key
  local record = ctx.members[payload.key]
  local tombstone = ctx.tombstones[tombstoneKey]
  if record and record.rev >= payload.rev then
    return false, "stale"
  end
  if not record and tombstone and tombstone.rev >= payload.rev then
    return false, "stale"
  end
  ctx.members[payload.key] = nil
  ns.EventService.AddTombstone({ tombstones = ctx.tombstones, now = ctx.now }, tombstoneKey, payload.rev)
  return true
end

local APPLIERS = {
  ROSTER_UPSERT = applyRosterUpsert,
  ROSTER_DELETE = applyRosterDelete,
  MEMBER_UPSERT = applyMemberUpsert,
  MEMBER_DELETE = applyMemberDelete,
}

function RosterSync.IsRosterMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` and `role` come from the client.
function RosterSync.Apply(ctx, message, sender, role)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role)
end

-- Payload builders: what a local change looks like on the wire.

function RosterSync.RosterPayload(roster)
  return { rosterId = roster.id, name = roster.name, rev = roster.rev, updatedAt = roster.updatedAt }
end

function RosterSync.MemberPayload(key, record)
  return { key = key, rosterId = record.rosterId, rev = record.rev, updatedAt = record.updatedAt }
end

-- Delete payloads reuse the revision stored in the tombstone the local removal left behind.
function RosterSync.DeleteRosterPayload(tombstones, rosterId)
  local tombstone = tombstones["R:" .. rosterId]
  if not tombstone then
    return nil
  end
  return { rosterId = rosterId, rev = tombstone.rev }
end

function RosterSync.DeleteMemberPayload(tombstones, key)
  local tombstone = tombstones["M:" .. key]
  if not tombstone then
    return nil
  end
  return { key = key, rev = tombstone.rev }
end

local function validPayload(messageType, payload)
  local message = ns.Protocol.Validate(ns.Protocol.Build(messageType, payload, "snapshot"))
  return message and message.p or nil
end

-- Items for a snapshot: every roster, the `maxMembers` most recently updated assignments, and the newest removals of
-- either kind (`maxMembers` of each at most). Only a gm or cogm snapshot carries them (the receiver applies them under
-- the role of whoever sends the snapshot). What does not validate is left out.
function RosterSync.SnapshotItems(ctx, maxMembers)
  local items = {}
  for _, roster in ipairs(ns.RosterService.List(ctx.rosters)) do
    local payload = validPayload("ROSTER_UPSERT", RosterSync.RosterPayload(roster))
    if payload then
      items[#items + 1] = { t = "ROSTER_UPSERT", p = payload }
    end
  end

  local list = {}
  for key, record in pairs(ctx.members) do
    if type(record) == "table" and type(record.updatedAt) == "number" then
      list[#list + 1] = { key = key, record = record }
    end
  end
  table.sort(list, function(a, b)
    if a.record.updatedAt ~= b.record.updatedAt then
      return a.record.updatedAt > b.record.updatedAt
    end
    return a.key < b.key
  end)
  local added = 0
  for _, row in ipairs(list) do
    if added >= maxMembers then
      break
    end
    local payload = validPayload("MEMBER_UPSERT", RosterSync.MemberPayload(row.key, row.record))
    if payload then
      items[#items + 1] = { t = "MEMBER_UPSERT", p = payload }
      added = added + 1
    end
  end

  local removals = {}
  for tombstoneKey, tombstone in pairs(ctx.tombstones) do
    local rosterId = tombstoneKey:match("^R:(.+)$")
    local memberKey = tombstoneKey:match("^M:(.+)$")
    if (rosterId or memberKey) and type(tombstone) == "table" and type(tombstone.at) == "number" then
      removals[#removals + 1] = { rosterId = rosterId, key = memberKey, rev = tombstone.rev, at = tombstone.at }
    end
  end
  table.sort(removals, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return (a.rosterId or a.key) < (b.rosterId or b.key)
  end)
  added = 0
  for _, removal in ipairs(removals) do
    if added >= maxMembers then
      break
    end
    local payload
    if removal.rosterId then
      payload = validPayload("ROSTER_DELETE", { rosterId = removal.rosterId, rev = removal.rev })
    else
      payload = validPayload("MEMBER_DELETE", { key = removal.key, rev = removal.rev })
    end
    if payload then
      items[#items + 1] = { t = removal.rosterId and "ROSTER_DELETE" or "MEMBER_DELETE", p = payload }
      added = added + 1
    end
  end
  return items
end

ns.RosterSync = RosterSync
