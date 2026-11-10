local _, ns = ...

-- Rows for the Announcements tabs (the board in the Guild group, the editor in the Admin group), the text of the
-- popup and the count of the sidebar (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md part B). Functions that return tables of
-- values, not frames, so every decision is tested here. Everything that was received (a title, a body, an author) goes
-- through ViewModel.Escape.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- Why something could not be done: the reasons of the service.
ViewModel.ANNOUNCEMENT_REASONS = ns.Locale.Table(function()
  return {
    forbidden = L("Only the guild master and the co-guild master can do that"),
    not_found = L("That announcement is gone"),
    limit = L("The board is full: delete an announcement first"),
    ["invalid:title"] = L("The title is not valid"),
    ["invalid:body"] = L("The text is not valid"),
    ["invalid:popup"] = L("The popup choice is not valid"),
    ["invalid:pinned"] = L("The pin choice is not valid"),
    ["invalid:expiry"] = L("The expiry is not valid"),
  }
end)

function ViewModel.AnnouncementReason(reason)
  local text = ViewModel.ANNOUNCEMENT_REASONS[reason]
  if text then
    return text
  end
  return L("It could not be done (%s)"):format(Escape(tostring(reason)))
end

-- The count on the Announcements item of the sidebar: a text, or nil when there is nothing unread.
function ViewModel.AnnouncementsBadge(count)
  return ViewModel.GroupsBadge(count)
end

local EXPIRY_TEXT = ns.Locale.Table(function()
  return {
    never = L("Never expires"),
    ["1d"] = L("Expires in 1 day"),
    ["7d"] = L("Expires in 7 days"),
    ["30d"] = L("Expires in 30 days"),
  }
end)

-- The items of the expiry dropdown, in order.
function ViewModel.AnnouncementExpiryItems()
  local items = {}
  for _, choice in ipairs(ns.Constants.ANNOUNCE_EXPIRY_CHOICES) do
    items[#items + 1] = { value = choice, text = EXPIRY_TEXT[choice] }
  end
  return items
end

-- "Expires in 3 d" / "Expires in 5 h" / "Expired", or nil when it never does.
local function expiryLine(announcement, now)
  if announcement.expiresAt == nil then
    return nil
  end
  local left = announcement.expiresAt - now
  if left <= 0 then
    return L("Expired")
  elseif left < 3600 then
    return L("Expires in %d min"):format(math.max(1, math.floor(left / 60)))
  elseif left < 86400 then
    return L("Expires in %d h"):format(math.floor(left / 3600))
  end
  return L("Expires in %d d"):format(math.floor(left / 86400))
end

local function rowOf(announcement, now)
  return {
    id = announcement.id,
    title = Escape(announcement.title),
    body = Escape(announcement.body or ""),
    author = Escape(announcement.author or "?"),
    pinned = announcement.pinned == true,
    popup = announcement.popup == true,
    age = ViewModel.AgeText(math.max(0, now - announcement.createdAt)),
    date = ViewModel.DateText(announcement.createdAt),
    expires = expiryLine(announcement, now),
    expired = ns.AnnouncementModel.IsExpired(announcement, now),
  }
end

-- The board: { rows, empty, emptyText }. `announcements` is what the service lists (the expired ones are already gone).
function ViewModel.AnnouncementBoard(announcements, now)
  local rows = {}
  for _, announcement in ipairs(announcements) do
    rows[#rows + 1] = rowOf(announcement, now)
  end
  return { rows = rows, empty = #rows == 0, emptyText = L("No announcements yet") }
end

-- The editor's list: every announcement, the expired ones marked, and "N of 30".
function ViewModel.AnnouncementAdminList(announcements, now)
  local rows = {}
  for _, announcement in ipairs(announcements) do
    rows[#rows + 1] = rowOf(announcement, now)
  end
  return {
    rows = rows,
    counter = L("%d of %d"):format(#rows, ns.Constants.ANNOUNCE_MAX),
    full = #rows >= ns.Constants.ANNOUNCE_MAX,
  }
end

-- An empty form. Popup is on by default.
function ViewModel.AnnouncementFormNew()
  return { editing = nil, title = "", body = "", popup = true, pinned = false, expiry = "never" }
end

-- A form to change an announcement. The expiry shown is the closest choice to what is stored.
function ViewModel.AnnouncementFormFrom(announcement, now)
  return {
    editing = announcement.id,
    title = announcement.title,
    body = announcement.body or "",
    popup = announcement.popup == true,
    pinned = announcement.pinned == true,
    expiry = ns.AnnouncementModel.ExpiryChoiceOf(announcement.expiresAt, now),
    -- What the form started with: the expiry is only sent when the player changes it.
    originalExpiry = ns.AnnouncementModel.ExpiryChoiceOf(announcement.expiresAt, now),
  }
end

-- "12/60" with the colour of the state: muted while there is room, warning near the limit, danger over it.
local function counter(text, max)
  local count = ns.AnnouncementModel.CharCount(text or "")
  local token = count > max and "danger" or (count >= max * 0.9 and "warning" or "muted")
  return { text = ("%d/%d"):format(count, max), token = token, over = count > max }
end

-- What the editor shows for a form: the button text, whether it can be pressed and why not, the counters. `full` is
-- whether the board is full (it only blocks a new announcement).
function ViewModel.AnnouncementFormView(form, full)
  local constants = ns.Constants
  local title = counter(form.title, constants.ANNOUNCE_TITLE_MAX)
  local body = counter(form.body, constants.ANNOUNCE_BODY_MAX)
  local view = {
    heading = form.editing and L("Edit the announcement") or L("New announcement"),
    submitText = form.editing and L("Save changes") or L("Publish"),
    titleCounter = title,
    bodyCounter = body,
    expiryItems = ViewModel.AnnouncementExpiryItems(),
    canSubmit = true,
    reason = nil,
  }
  local clean, reason = ns.AnnouncementModel.ValidateFields({
    title = form.title,
    body = form.body,
    popup = form.popup,
    pinned = form.pinned,
    expiry = form.expiry,
  })
  if not clean then
    view.canSubmit = false
    view.reason = ViewModel.AnnouncementReason(reason)
  elseif full and not form.editing then
    view.canSubmit = false
    view.reason = ViewModel.AnnouncementReason("limit")
  end
  return view
end

-- The card of the popup: `index` of `total` announcements waiting. { title, meta, body, counter (nil for one), long }.
function ViewModel.AnnouncementPopupView(announcement, index, total, now)
  local lines = 1
  for _ in (announcement.body or ""):gmatch("\n") do
    lines = lines + 1
  end
  return {
    title = Escape(announcement.title),
    meta = L("%s - %s"):format(
      Escape(announcement.author or "?"),
      ViewModel.AgeText(math.max(0, now - announcement.createdAt))
    ),
    body = Escape(announcement.body or ""),
    counter = total > 1 and L("%d of %d"):format(index, total) or nil,
    -- A body past about ten lines scrolls inside the card.
    long = lines > 10 or #(announcement.body or "") > 600,
    canPrev = total > 1 and index > 1,
    canNext = total > 1 and index < total,
  }
end

-- The newest pinned announcement for the Home banner, or nil. `announcements` is what the service lists (pinned first).
function ViewModel.AnnouncementBanner(announcements)
  local top = announcements[1]
  if top and top.pinned then
    return { id = top.id, text = Escape(top.title) }
  end
  return nil
end
