local _, ns = ...

-- Pure rules of a guild announcement (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md part B). Nothing here touches the client.
--
-- announcement = {
--   id,                    -- unique id (a message id)
--   title,                 -- 1..ANNOUNCE_TITLE_MAX characters
--   body,                  -- 0..ANNOUNCE_BODY_MAX characters, plain text, newlines allowed
--   author,                -- who published (or last edited) it: set by the receiver from the message sender
--   createdAt, updatedAt, rev, updatedBy,
--   popup,                 -- boolean: members get a popup
--   popupRev,              -- starts at 1, bumped by "Send popup again": a member sees the popup once per popupRev
--   pinned,                -- boolean: pinned ones come first
--   expiresAt,             -- nil: never; otherwise it is purged from this time on
-- }
local AnnouncementModel = {}

local V = ns.Validate

local MAX_REV = 2147483647
local MAX_TIMESTAMP = 4102444800 -- 2100-01-01, as in Protocol

-- The number of characters of UTF-8 `text` (the bytes that start a character).
local function charCount(text)
  return select(2, text:gsub("[^\128-\191]", ""))
end
AnnouncementModel.CharCount = charCount

-- The title: one line of plain text, trimmed, 1..max characters, no escape sequences or control characters.
local function cleanTitle(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = value:match("^%s*(.-)%s*$")
  local max = ns.Constants.ANNOUNCE_TITLE_MAX
  if text == "" or #text > max * 4 or charCount(text) > max or text:find("|", 1, true) or text:find("%c") then
    return nil
  end
  return text
end

-- The body: plain text with newlines ("\r\n" becomes "\n"), up to the limit; no escape sequences or other control
-- characters. Empty is fine.
local function cleanBody(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = (value:gsub("\r\n", "\n")):match("^%s*(.-)%s*$")
  local max = ns.Constants.ANNOUNCE_BODY_MAX
  if #text > max * 4 or charCount(text) > max or text:find("|", 1, true) or text:gsub("\n", ""):find("%c") then
    return nil
  end
  return text
end

local function isExpiryChoice(value)
  for _, choice in ipairs(ns.Constants.ANNOUNCE_EXPIRY_CHOICES) do
    if choice == value then
      return true
    end
  end
  return false
end

-- Checks what an editor hands over: { title, body, popup, pinned, expiry }. With `partial` only the fields that are
-- there are checked (an edit); otherwise the title is required and the rest has defaults. Returns the clean fields
-- (only the ones that were checked), or nil plus "invalid:<field>".
function AnnouncementModel.ValidateFields(fields, partial)
  if type(fields) ~= "table" then
    return nil, "invalid:title"
  end
  local clean = {}
  if fields.title ~= nil or not partial then
    clean.title = cleanTitle(fields.title)
    if not clean.title then
      return nil, "invalid:title"
    end
  end
  if fields.body ~= nil or not partial then
    clean.body = cleanBody(fields.body == nil and "" or fields.body)
    if not clean.body then
      return nil, "invalid:body"
    end
  end
  for _, key in ipairs({ "popup", "pinned" }) do
    if fields[key] ~= nil then
      if type(fields[key]) ~= "boolean" then
        return nil, "invalid:" .. key
      end
      clean[key] = fields[key]
    end
  end
  if fields.expiry ~= nil then
    if not isExpiryChoice(fields.expiry) then
      return nil, "invalid:expiry"
    end
    clean.expiry = fields.expiry
  end
  return clean
end

-- When an announcement published at `now` with this expiry choice expires (nil: never).
function AnnouncementModel.ExpiresAt(choice, now)
  local span = ns.Constants.ANNOUNCE_EXPIRY_SECONDS[choice]
  return span and (now + span) or nil
end

-- The choice an expiry stamp is closest to, for the editor ("never" for none).
function AnnouncementModel.ExpiryChoiceOf(expiresAt, now)
  if expiresAt == nil then
    return "never"
  end
  local remaining, best, bestDistance = expiresAt - now, "never", math.huge
  for choice, span in pairs(ns.Constants.ANNOUNCE_EXPIRY_SECONDS) do
    local distance = math.abs(span - remaining)
    if distance < bestDistance or (distance == bestDistance and choice < best) then
      best, bestDistance = choice, distance
    end
  end
  return best
end

-- A whole record, from the wire or from storage: a clean copy, or nil plus the reason. The author is checked when it
-- is there (the wire does not carry it).
function AnnouncementModel.Validate(record)
  if type(record) ~= "table" then
    return nil, "not_table"
  end
  if not V.Id(record.id) then
    return nil, "invalid:id"
  end
  local title = cleanTitle(record.title)
  if not title then
    return nil, "invalid:title"
  end
  local body = cleanBody(record.body == nil and "" or record.body)
  if not body then
    return nil, "invalid:body"
  end
  if not (V.Int(record.createdAt, 0, MAX_TIMESTAMP) and V.Int(record.updatedAt, 0, MAX_TIMESTAMP)) then
    return nil, "invalid:time"
  end
  if not (V.Int(record.rev, 1, MAX_REV) and V.Int(record.popupRev, 1, MAX_REV)) then
    return nil, "invalid:rev"
  end
  if type(record.popup) ~= "boolean" or type(record.pinned) ~= "boolean" then
    return nil, "invalid:flag"
  end
  if record.expiresAt ~= nil and not V.Int(record.expiresAt, 0, MAX_TIMESTAMP) then
    return nil, "invalid:expiresAt"
  end
  if record.author ~= nil and not ns.EventModel.IsCharacterKey(record.author) then
    return nil, "invalid:author"
  end
  return {
    id = record.id,
    title = title,
    body = body,
    author = record.author,
    createdAt = record.createdAt,
    updatedAt = record.updatedAt,
    rev = record.rev,
    popup = record.popup,
    popupRev = record.popupRev,
    pinned = record.pinned,
    expiresAt = record.expiresAt,
  }
end

-- Sorts `list` in place: pinned first, then the newest, then by id.
function AnnouncementModel.Sort(list)
  table.sort(list, function(a, b)
    if a.pinned ~= b.pinned then
      return a.pinned
    end
    if a.createdAt ~= b.createdAt then
      return a.createdAt > b.createdAt
    end
    return a.id < b.id
  end)
  return list
end

function AnnouncementModel.IsExpired(announcement, now)
  return announcement.expiresAt ~= nil and now >= announcement.expiresAt
end

-- Is the popup of `announcement` still to be shown to this account? `seen[id]` is the popupRev already shown.
function AnnouncementModel.NeedsPopup(announcement, seen, now)
  return announcement.popup == true
    and not AnnouncementModel.IsExpired(announcement, now)
    and (seen[announcement.id] or 0) < announcement.popupRev
end

ns.AnnouncementModel = AnnouncementModel
