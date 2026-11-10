local _, ns = ...

-- Guild announcements (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md part B): publishing, editing, deleting and resending the
-- popup of an announcement (only a role with `announce_manage`: gm and cogm), what the board shows, what is unread and
-- which popups are due. Received announcements are applied by AnnouncementSync; this object tells the UI about them.
--
-- store = db.global.announcements = { items = { [id] = announcement }, tombstones = { [id] = { at, rev } },
--                                     openedAt = the last time the board was opened }
-- seen  = db.global.announcementsSeen = { [id] = popupRev already shown }, kept per account
--
-- deps = {
--   store, seen,
--   now        = function() -> server time,
--   ownName    = function() -> "Name-Realm",
--   ownRole    = function() -> a rank role or nil,
--   newId      = function() -> unique id,
--   send       = { upsert = function(announcement), delete = function(id) } (both optional),
--   onChange   = function() (optional): the data changed, redraw,
--   onPopup    = function(announcement) (optional): a popup is due for this announcement,
-- }
-- Every operation returns its result, or nil/false plus a reason:
--   "forbidden" | "not_found" | "limit" | "invalid:<field>".
local AnnouncementService = {}
AnnouncementService.__index = AnnouncementService

local Model = ns.AnnouncementModel

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- Remembers that `id` was removed at revision `rev`, dropping the oldest tombstone when the list is full. Also used
-- when a received ANN_DEL is applied, so both paths share the same bounded list.
function AnnouncementService.AddTombstone(store, id, rev, now)
  local tombstones = store.tombstones
  if not tombstones[id] and countKeys(tombstones) >= ns.Constants.ANNOUNCE_TOMBSTONE_MAX then
    local oldestId, oldestAt
    for existing, entry in pairs(tombstones) do
      if not oldestAt or entry.at < oldestAt or (entry.at == oldestAt and existing < oldestId) then
        oldestId, oldestAt = existing, entry.at
      end
    end
    tombstones[oldestId] = nil
  end
  tombstones[id] = { at = now, rev = rev }
end

-- Local housekeeping: removes what expired, tombstones past their time and the "seen" marks of announcements that are
-- gone. ctx = { store, seen, now = function() }. Returns the number of announcements removed.
function AnnouncementService.Purge(ctx)
  local now = ctx.now()
  local removed = 0
  for id, announcement in pairs(ctx.store.items) do
    if Model.IsExpired(announcement, now) then
      ctx.store.items[id] = nil
      removed = removed + 1
    end
  end
  for id, entry in pairs(ctx.store.tombstones) do
    if now - entry.at > ns.Constants.ANNOUNCE_TOMBSTONE_TTL_SECONDS then
      ctx.store.tombstones[id] = nil
    end
  end
  for id in pairs(ctx.seen) do
    if not ctx.store.items[id] then
      ctx.seen[id] = nil
    end
  end
  return removed
end

function AnnouncementService.New(deps)
  local send = deps.send or {}
  return setmetatable({
    store = deps.store,
    seen = deps.seen,
    now = deps.now,
    ownName = deps.ownName,
    ownRole = deps.ownRole,
    newId = deps.newId,
    sendUpsert = send.upsert,
    sendDelete = send.delete,
    onChange = deps.onChange,
    onPopup = deps.onPopup,
  }, AnnouncementService)
end

-- Can the own role publish, edit and delete announcements?
function AnnouncementService:CanManage()
  return ns.PermissionService.Can(self:ownRole(), "announce_manage")
end

function AnnouncementService:Changed()
  if self.onChange then
    self.onChange()
  end
end

function AnnouncementService:Count()
  return countKeys(self.store.items)
end

local function stamp(self, announcement)
  announcement.rev = announcement.rev + 1
  announcement.updatedAt = self.now()
  announcement.updatedBy = self:ownName()
  announcement.author = self:ownName()
end

-- The own client never receives its own messages, so what is published is also marked as shown: the author gets no
-- popup of their own announcement.
local function markShown(self, announcement)
  self.seen[announcement.id] = math.max(self.seen[announcement.id] or 0, announcement.popupRev)
end

-- `fields` = { title, body, popup (default true), pinned, expiry ("never" | "1d" | "7d" | "30d") }.
function AnnouncementService:Publish(fields)
  if not self:CanManage() then
    return nil, "forbidden"
  end
  local clean, reason = Model.ValidateFields(fields)
  if not clean then
    return nil, reason
  end
  if self:Count() >= ns.Constants.ANNOUNCE_MAX then
    return nil, "limit"
  end
  local now = self.now()
  local announcement = {
    id = self.newId(),
    title = clean.title,
    body = clean.body,
    createdAt = now,
    updatedAt = now,
    rev = 0,
    popup = clean.popup ~= false,
    popupRev = 1,
    pinned = clean.pinned == true,
    expiresAt = Model.ExpiresAt(clean.expiry or "never", now),
  }
  stamp(self, announcement)
  self.store.items[announcement.id] = announcement
  self.store.tombstones[announcement.id] = nil
  markShown(self, announcement)
  if self.sendUpsert then
    self.sendUpsert(announcement)
  end
  self:Changed()
  return announcement
end

-- Changes the fields that are there; the others stay. The popup is not shown again by an edit (see ResendPopup).
function AnnouncementService:Edit(id, fields)
  if not self:CanManage() then
    return nil, "forbidden"
  end
  local announcement = self.store.items[id]
  if not announcement then
    return nil, "not_found"
  end
  local clean, reason = Model.ValidateFields(fields, true)
  if not clean then
    return nil, reason
  end
  local now = self.now()
  for _, key in ipairs({ "title", "body", "popup", "pinned" }) do
    if clean[key] ~= nil then
      announcement[key] = clean[key]
    end
  end
  if clean.expiry ~= nil then
    announcement.expiresAt = Model.ExpiresAt(clean.expiry, now)
  end
  stamp(self, announcement)
  if self.sendUpsert then
    self.sendUpsert(announcement)
  end
  self:Changed()
  return announcement
end

function AnnouncementService:Delete(id)
  if not self:CanManage() then
    return false, "forbidden"
  end
  local announcement = self.store.items[id]
  if not announcement then
    return false, "not_found"
  end
  self.store.items[id] = nil
  AnnouncementService.AddTombstone(self.store, id, announcement.rev + 1, self.now())
  if self.sendDelete then
    self.sendDelete(id)
  end
  self:Changed()
  return true
end

-- "Send popup again": members who closed the popup see it once more. Turns the popup on if it was off.
function AnnouncementService:ResendPopup(id)
  if not self:CanManage() then
    return nil, "forbidden"
  end
  local announcement = self.store.items[id]
  if not announcement then
    return nil, "not_found"
  end
  announcement.popup = true
  announcement.popupRev = announcement.popupRev + 1
  stamp(self, announcement)
  markShown(self, announcement)
  if self.sendUpsert then
    self.sendUpsert(announcement)
  end
  self:Changed()
  return announcement
end

-- The announcements to show, pinned first then the newest. `includeExpired` is for the editor.
function AnnouncementService:List(includeExpired)
  local now, list = self.now(), {}
  for _, announcement in pairs(self.store.items) do
    if includeExpired or not Model.IsExpired(announcement, now) then
      list[#list + 1] = announcement
    end
  end
  return Model.Sort(list)
end

function AnnouncementService:Get(id)
  return self.store.items[id]
end

-- The player has seen the popup of `id` (or its current revision).
function AnnouncementService:MarkSeen(id)
  local announcement = self.store.items[id]
  if announcement then
    markShown(self, announcement)
  end
end

-- The board was opened: what exists now is no longer unread. It does not call `onChange`: the board that draws this
-- is the one that would be drawn again.
function AnnouncementService:MarkBoardOpened()
  self.store.openedAt = self.now()
end

-- How many announcements are new since the board was last opened (the badge of the sidebar). The own ones are not.
function AnnouncementService:Unread()
  local now, since, own, count = self.now(), self.store.openedAt or 0, self:ownName(), 0
  for _, announcement in pairs(self.store.items) do
    if not Model.IsExpired(announcement, now) and announcement.createdAt > since and announcement.author ~= own then
      count = count + 1
    end
  end
  return count
end

-- The popups still due for announcements already stored (a card that never showed because the player logged out or
-- stayed in combat), newest first: the announcements with a popup not seen, touched in the last week.
function AnnouncementService:PendingPopups()
  local now, list = self.now(), {}
  for _, announcement in pairs(self.store.items) do
    if
      Model.NeedsPopup(announcement, self.seen, now)
      and now - announcement.updatedAt < ns.Constants.ANNOUNCE_POPUP_MAX_AGE_SECONDS
    then
      list[#list + 1] = announcement
    end
  end
  table.sort(list, function(a, b)
    if a.updatedAt ~= b.updatedAt then
      return a.updatedAt > b.updatedAt
    end
    return a.id < b.id
  end)
  return list
end

-- An announcement arrived (live, or in a snapshot) and was stored: tell the UI, and ask for its popup when it is due. A
-- popup is only worth showing for an announcement touched recently: an old one only counts as unread on the board.
function AnnouncementService:OnReceived(announcement)
  local now = self.now()
  if
    self.onPopup
    and Model.NeedsPopup(announcement, self.seen, now)
    and now - announcement.updatedAt < ns.Constants.ANNOUNCE_POPUP_MAX_AGE_SECONDS
  then
    self.onPopup(announcement)
  end
end

ns.AnnouncementService = AnnouncementService
