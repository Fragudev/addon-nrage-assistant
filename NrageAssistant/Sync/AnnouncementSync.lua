local _, ns = ...

-- Applies received announcement messages to local data, and builds the payloads for local changes
-- (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md part B).
--
-- Authority: the sender's role comes from the receiver's own guild roster (`role`), never from the message, and only a
-- role with `announce_manage` (gm, cogm) is heard: an ANN or ANN_DEL from anyone else is dropped. The author is the
-- sender, and so is `updatedBy`; the payload has no field for either.
--
-- The one exception is an item of a snapshot (see Transfer.ApplyItems): a gm or cogm relays announcements that the
-- other one published, and names the original author (`origin`), which Transfer only accepts when the local guild
-- roster says that member may manage announcements. A message on the guild channel has nowhere to carry it.
--
-- Conflicts follow the other shared data: the higher `rev` wins, then the later (clamped) `updatedAt`, then the larger
-- sender; an identical message is a no-op. A removal leaves a tombstone, and an ANN whose `rev` does not exceed the
-- tombstone's is dropped, so an older copy cannot bring a deleted announcement back.
--
-- ctx = { store = db.global.announcements, now = function(), onApplied = function(announcement) (optional) }
-- Every function returns true, or false plus:
--   "unknown_sender" | "forbidden" | "stale" | "tombstoned" | "expired" | "limit" | "unsupported"
local AnnouncementSync = {}

local Rules = ns.SyncRules
local authorize, clampTimestamp = Rules.Authorize, Rules.ClampTimestamp

-- Makes room for an incoming announcement in a full list: the oldest unpinned one goes, and only if it is older than
-- the incoming one (or the incoming one is pinned), so a snapshot of old announcements cannot push newer ones out. The
-- one removed is remembered, so a late copy of it does not come back. Returns false when nothing may go.
local function makeRoom(ctx, incoming)
  local oldest
  for _, announcement in pairs(ctx.store.items) do
    if
      not announcement.pinned
      and (
        not oldest
        or announcement.createdAt < oldest.createdAt
        or (announcement.createdAt == oldest.createdAt and announcement.id < oldest.id)
      )
    then
      oldest = announcement
    end
  end
  if not oldest or not (incoming.pinned or oldest.createdAt < incoming.createdAt) then
    return false
  end
  ctx.store.items[oldest.id] = nil
  ns.AnnouncementService.AddTombstone(ctx.store, oldest.id, oldest.rev, ctx.now())
  return true
end

local function applyUpsert(ctx, payload, sender, role, origin)
  local denied = authorize(role, "announce_manage")
  if denied then
    return false, denied
  end
  local actor = origin and origin.author or sender

  if Rules.BlockedByTombstone({ tombstones = ctx.store.tombstones }, payload.id, payload.rev) then
    return false, "tombstoned"
  end

  local now = ctx.now()
  local updatedAt = clampTimestamp(ctx, payload.updatedAt)
  local createdAt = clampTimestamp(ctx, payload.createdAt)
  local announcement = ctx.store.items[payload.id]
  if announcement then
    if not Rules.Wins(payload.rev, updatedAt, actor, announcement) then
      return false, "stale"
    end
  else
    if payload.expiresAt and now >= payload.expiresAt then
      return false, "expired"
    end
    if ns.SyncRules.CountKeys(ctx.store.items) >= ns.Constants.ANNOUNCE_MAX then
      if not makeRoom(ctx, { pinned = payload.pinned, createdAt = createdAt }) then
        return false, "limit"
      end
    end
    announcement = { id = payload.id, createdAt = createdAt }
    ctx.store.items[payload.id] = announcement
  end

  -- An upsert carries the whole announcement: fields it omits are cleared.
  announcement.title = payload.title
  announcement.body = payload.body
  announcement.popup = payload.popup
  announcement.popupRev = payload.popupRev
  announcement.pinned = payload.pinned
  announcement.expiresAt = payload.expiresAt
  announcement.author = actor
  announcement.rev = payload.rev
  announcement.updatedAt = updatedAt
  announcement.updatedBy = actor
  if ctx.onApplied then
    ctx.onApplied(announcement)
  end
  return true
end

local function applyDelete(ctx, payload, _, role)
  local denied = authorize(role, "announce_manage")
  if denied then
    return false, denied
  end
  local announcement = ctx.store.items[payload.id]
  if announcement and announcement.rev >= payload.rev then
    return false, "stale"
  end
  local tombstone = ctx.store.tombstones[payload.id]
  if not announcement and tombstone and tombstone.rev >= payload.rev then
    return false, "stale"
  end
  ctx.store.items[payload.id] = nil
  -- Remembered even when the announcement is unknown here, so a late stale upsert is still dropped.
  ns.AnnouncementService.AddTombstone(ctx.store, payload.id, payload.rev, ctx.now())
  return true
end

local APPLIERS = { ANN = applyUpsert, ANN_DEL = applyDelete }

function AnnouncementSync.IsAnnouncementMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` and `role` come from the client; `origin` (optional,
-- { author }) only from a snapshot item.
function AnnouncementSync.Apply(ctx, message, sender, role, origin)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role, origin)
end

-- Payload builders: what a local change looks like on the wire. The author is not on it.

function AnnouncementSync.UpsertPayload(announcement)
  return {
    id = announcement.id,
    title = announcement.title,
    body = announcement.body,
    createdAt = announcement.createdAt,
    updatedAt = announcement.updatedAt,
    rev = announcement.rev,
    popup = announcement.popup,
    popupRev = announcement.popupRev,
    pinned = announcement.pinned,
    expiresAt = announcement.expiresAt,
  }
end

-- Delete payloads reuse the revision stored in the tombstone the local delete left behind.
function AnnouncementSync.DeletePayload(store, id)
  local tombstone = store.tombstones[id]
  if not tombstone then
    return nil
  end
  return { id = id, rev = tombstone.rev, updatedAt = tombstone.at }
end

-- The items of a snapshot for a late joiner: the newest `max` announcements that are still alive (each names its
-- author, as an item of a snapshot may) and the removals, newest first. The tombstones count against `max` last.
function AnnouncementSync.SnapshotItems(store, now, max)
  local items = {}
  local live = {}
  for _, announcement in pairs(store.items) do
    if not ns.AnnouncementModel.IsExpired(announcement, now) then
      live[#live + 1] = announcement
    end
  end
  table.sort(live, function(a, b)
    if a.createdAt ~= b.createdAt then
      return a.createdAt > b.createdAt
    end
    return a.id < b.id
  end)
  for index = 1, math.min(max, #live) do
    items[#items + 1] = {
      t = "ANN",
      p = AnnouncementSync.UpsertPayload(live[index]),
      author = live[index].author,
    }
  end
  local ids = {}
  for id in pairs(store.tombstones) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    local left, right = store.tombstones[a].at, store.tombstones[b].at
    if left ~= right then
      return left > right
    end
    return a < b
  end)
  for index = 1, math.min(max - #items, #ids) do
    local tombstone = store.tombstones[ids[index]]
    items[#items + 1] = { t = "ANN_DEL", p = { id = ids[index], rev = tombstone.rev, updatedAt = tombstone.at } }
  end
  return items
end

ns.AnnouncementSync = AnnouncementSync
