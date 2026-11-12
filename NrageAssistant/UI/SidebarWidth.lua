local _, ns = ...

-- The width of the sidebar of the main window, which the player drags wider when a menu label is cut off. It is saved
-- account-wide (db.global.settings.sidebarWidth). The settings and the clamping are plain functions and are tested;
-- the drag handle itself lives in UI/Main.lua.
local SidebarWidth = {}

local function finite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- The widest the sidebar may be in a window `windowWidth` wide (optional): the maximum, or less so the page keeps its
-- minimum width, but never under the minimum.
function SidebarWidth.Max(windowWidth)
  local C = ns.Constants
  local max = C.SIDEBAR_MAX_WIDTH
  if finite(windowWidth) then
    max = math.min(max, math.floor(windowWidth - C.SIDEBAR_CONTENT_MIN_WIDTH))
  end
  return math.max(C.SIDEBAR_MIN_WIDTH, max)
end

-- A whole width between the minimum and SidebarWidth.Max(windowWidth). Anything that is not a usable number gives the
-- default width (clamped too).
function SidebarWidth.Clamp(width, windowWidth)
  local C = ns.Constants
  if not finite(width) then
    width = C.SIDEBAR_DEFAULT_WIDTH
  end
  width = math.floor(width + 0.5)
  return math.min(SidebarWidth.Max(windowWidth), math.max(C.SIDEBAR_MIN_WIDTH, width))
end

-- The saved width, created and repaired as needed: an unusable or out-of-range value is brought back into range (the
-- default when it is not a number). Returns the width now stored in `db`.
function SidebarWidth.Get(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.sidebarWidth = SidebarWidth.Clamp(settings.sidebarWidth)
  return settings.sidebarWidth
end

-- Saves `width`, clamped to the range (not to the current window, so a wider window later gets the full width back).
-- Returns the width saved.
function SidebarWidth.Set(db, width)
  SidebarWidth.Get(db)
  db.global.settings.sidebarWidth = SidebarWidth.Clamp(width)
  return db.global.settings.sidebarWidth
end

-- The width after dragging the edge by `delta` units from `startWidth`, in a window `windowWidth` wide.
function SidebarWidth.Drag(startWidth, delta, windowWidth)
  if not finite(delta) then
    delta = 0
  end
  return SidebarWidth.Clamp(
    (finite(startWidth) and startWidth or ns.Constants.SIDEBAR_DEFAULT_WIDTH) + delta,
    windowWidth
  )
end

ns.SidebarWidth = SidebarWidth
