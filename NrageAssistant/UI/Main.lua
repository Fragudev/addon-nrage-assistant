local _, ns = ...

-- The main window: the kit's window shell (header, sidebar, settings popover) and the page of the selected tab. The
-- tabs live in UI/Tabs/*.lua and register themselves with UI.Register; this file keeps what they share: the page, the
-- banner for what an action reported, redraws, and the navigation. What to show comes from ViewModel and the domain
-- services; nothing here decides anything. Client only.
local UI = {}

local Kit = ns.Kit
local L = ns.L

-- The loot screens that want to know when loot changes, here or on a received message. Each registers its
-- refresh function; UI.LootChanged calls them all.
UI.lootListeners = {}

function UI.LootChanged()
  for _, listener in ipairs(UI.lootListeners) do
    listener()
  end
end

local SIDEBAR_WIDTH = 200
local PAGE_PAD = { 30, 26, 30, 26 }

local window
local sidebar
local content
local page
local currentTab = "home"
local banner
local contentWidth, contentHeight = 800, 580

-- The drawing functions of the tabs: value -> function(page).
UI.tabs = {}

function UI.Register(value, draw)
  UI.tabs[value] = draw
end

-- Where the next draw of a tab should start, set by a link from another tab (for example the event to select in the
-- Raid tab). A tab reads and clears what it needs.
UI.nav = {}

-- true while the main window is on screen.
function UI.IsOpen()
  return window ~= nil and window:IsShown()
end

function UI.CurrentTab()
  return currentTab
end

function UI.Role()
  return ns.PermissionService.OwnRole(ns.Platform)
end

-- Who sees which events (RosterService.Viewer) for the own character; `selected` is what an admin picked in a selector.
function UI.Viewer(selected)
  local global = ns.db.global
  return ns.RosterService.OwnViewer(ns.Platform, global.rosters, global.members, selected)
end

-- Remembers where a window was left and how big: the saved numbers live in settings.windows[name] and the window
-- (the kit's or an AceGUI frame) keeps them up to date as it is moved or resized. `width`/`height` are the first-time
-- size.
function UI.ApplyWindowStatus(target, name, width, height)
  local settings = type(ns.db.global.settings) == "table" and ns.db.global.settings or {}
  ns.db.global.settings = settings
  settings.windows = type(settings.windows) == "table" and settings.windows or {}
  local status = type(settings.windows[name]) == "table" and settings.windows[name] or {}
  settings.windows[name] = status
  status.width = type(status.width) == "number" and status.width or width
  status.height = type(status.height) == "number" and status.height or height
  target:SetStatusTable(status)
end

-- ---------------------------------------------------------------------------------------------------------------
-- The banner: what an action reported, at the top of the content until the tab changes or it is dismissed.

function UI.Notify(kind, text)
  banner = { kind = kind, text = text }
  UI.Redraw()
end

function UI.ClearBanner()
  if banner then
    banner = nil
    UI.Redraw()
  end
end

-- Shows what a command returned (a list of lines): a failure in danger, a change that was saved here but could not be
-- sent in warning, anything else in success.
function UI.Report(lines)
  local kind = "success"
  if ns.Validate.IsFailure(lines) then
    kind = "danger"
  elseif lines[2] then
    kind = "warning"
  end
  local parts = {}
  for _, line in ipairs(lines) do
    parts[#parts + 1] = ns.ViewModel.Escape(line)
  end
  UI.Notify(kind, table.concat(parts, " "))
end

-- The two-click confirmation of a destructive action (plan 1.4.11): the first click arms, the second confirms. Only one
-- action is armed at a time, and moving to another tab disarms it.
local armed

function UI.IsArmed(key)
  return armed == key
end

function UI.Arm(key)
  armed = key
  UI.Redraw()
end

function UI.Disarm()
  armed = nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- Drawing

-- Draws the banner and the tab into the page again, keeping the scroll position.
function UI.Redraw()
  if not (UI.IsOpen() and page) then
    return
  end
  local offset = page:GetScroll()
  -- What these views show is read from the character again each time they are drawn.
  if ns.character and (currentTab == "profile" or currentTab == "ready" or currentTab == "home") then
    ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
  end
  page:Clear()
  if banner then
    Kit.Banner(page, {
      kind = banner.kind,
      text = banner.text,
      onDismiss = function()
        banner = nil
        UI.Redraw()
      end,
    })
  end
  local draw = UI.tabs[currentTab]
  if draw then
    local ok, err = pcall(draw, page)
    if not ok then
      -- A failing tab must not take the window down: say so, in the window.
      Kit.Banner(page, { kind = "danger", text = ns.ViewModel.Escape(tostring(err)) })
    end
  end
  page:Layout(contentWidth, contentHeight)
  page:SetScroll(offset)
end

-- Lays the page out again without drawing it (a region of it changed its content).
function UI.Relayout()
  if UI.IsOpen() and page then
    local offset = page:GetScroll()
    page:Layout(contentWidth, contentHeight)
    page:SetScroll(offset)
  end
end

local function ReadinessIsShown()
  return currentTab == "ready" or currentTab == "home"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Redraws that follow what arrives from the guild: bursts count once per interval.

local function throttledRedraw(shown, seconds)
  local throttle
  return function()
    if not UI.IsOpen() or not shown() then
      return
    end
    throttle = throttle
      or ns.Throttle.New({
        run = function()
          UI.Redraw()
        end,
        now = function()
          return ns.Platform.Now()
        end,
        schedule = C_Timer.After,
        interval = seconds,
      })
    throttle:Call()
  end
end

-- A PvP counter changed, here or on a received record (a whole guild logging in): the PvP tab is drawn again if it is
-- the one on screen, at most once per PVP_REDRAW_SECONDS.
UI.PvPChanged = throttledRedraw(function()
  return currentTab == "pvp"
end, ns.Constants.PVP_REDRAW_SECONDS)

-- A blacklist entry arrived from the guild (a snapshot brings the whole list), or the group changed.
UI.BlacklistChanged = throttledRedraw(function()
  return currentTab == "blacklist"
end, ns.Constants.BLACKLIST_REDRAW_SECONDS)

-- Recipes arrived from the guild, or a profession was scanned: the Professions tab and the Profile tab follow, once per
-- interval (a guild logging in sends many lists).
UI.RecipesChanged = throttledRedraw(function()
  return currentTab == "professions" or currentTab == "profile"
end, 1)

-- The guild's readiness rules changed: rare (one message per change), so no throttling.
function UI.RulesChanged()
  if UI.IsOpen() and (currentTab == "ready" or currentTab == "rules" or currentTab == "home") then
    UI.Redraw()
  end
end

-- Rosters or roles arrived or changed: the role of this player may have changed, so the sidebar is built again too.
local rostersRedraw = throttledRedraw(function()
  return true
end, 1)

function UI.RostersChanged()
  if UI.IsOpen() then
    UI.BuildSidebar()
    rostersRedraw()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Readiness views: while Home or Readiness is on screen, what they show is read again by itself on aura, gear, level
-- and skill events, at most once per interval. Nothing is listened to while they are hidden, and nothing is sent.

local READINESS_EVENTS = { "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }
local readinessFrame, readinessThrottle
local readinessWatching = false

function UI.ReadinessChanged()
  if not readinessThrottle then
    readinessThrottle = ns.Throttle.New({
      run = function()
        if UI.IsOpen() and ReadinessIsShown() and ns.character then
          ns.ProfileService.Refresh(ns.Platform, ns.character.profile)
          UI.Redraw()
        end
      end,
      now = function()
        return ns.Platform.Now()
      end,
      schedule = C_Timer.After,
      interval = ns.Constants.READINESS_REDRAW_SECONDS,
    })
  end
  readinessThrottle:Call()
end

-- Starts or stops listening for the events above.
function UI.WatchReadiness(watch)
  if watch == readinessWatching then
    return
  end
  readinessWatching = watch
  if not readinessFrame then
    readinessFrame = CreateFrame("Frame")
    readinessFrame:SetScript("OnEvent", function()
      UI.ReadinessChanged()
    end)
  end
  if watch then
    for _, event in ipairs(READINESS_EVENTS) do
      ns.Platform.TryRegisterEvent(readinessFrame, event)
    end
    -- The auras of the player only: the client sends nothing about the rest of the group.
    ns.Platform.TryRegisterUnitEvent(readinessFrame, "UNIT_AURA", "player")
  else
    readinessFrame:UnregisterAllEvents()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The shell

-- The sidebar again, after a tab or the language changed: the selection and the texts follow.
function UI.BuildSidebar()
  if not window then
    return
  end
  if sidebar then
    sidebar:Release()
  end
  local role = UI.Role()
  sidebar = Kit.Sidebar(window.body, {
    groups = ns.ViewModel.NavGroups(role),
    value = currentTab,
    onSelect = function(value)
      UI.SelectTab(value)
    end,
    user = ns.ViewModel.UserCard(ns.Platform.GetIdentityKey(), ns.Platform.GetOwnGuildRank(), role),
  })
  sidebar:Layout(SIDEBAR_WIDTH, contentHeight)
  Kit.Place(sidebar, window.body, 0, 0)
end

-- The sync pill of the header, from what the sync reports.
function UI.UpdatePill()
  if window then
    local pill = ns.ViewModel.SyncPill(ns.comm and ns.comm:StatusInfo() or nil)
    window:SetPill(pill.text, pill.status)
  end
end

local function onResize(width, height)
  contentWidth, contentHeight = width - SIDEBAR_WIDTH, height
  if content then
    content:SetSize(contentWidth, contentHeight)
  end
  if sidebar then
    sidebar:Layout(SIDEBAR_WIDTH, height)
  end
  UI.Relayout()
end

function UI.SelectTab(tab)
  if tab ~= currentTab then
    banner = nil
    armed = nil
    if page then
      page:SetScroll(0)
    end
  end
  currentTab = tab
  UI.WatchReadiness(ReadinessIsShown())
  UI.BuildSidebar()
  UI.Redraw()
end

-- The language was changed in the settings: every text is read again.
function UI.LanguageChanged()
  UI.BuildSidebar()
  UI.UpdatePill()
  Kit.Popup.Get(1):Rebuild()
  UI.Redraw()
end

-- The settings popover behind the gear of the header.
local function buildSettings(stack)
  local settings = ns.Settings
  Kit.SectionLabel(stack, { text = L("Settings") })
  local field = Kit.Field(stack, { label = L("Language") })
  Kit.Dropdown(field, {
    items = {
      { value = "auto", text = L("Automatic (game language)") },
      { value = "es", text = "Español" },
      { value = "en", text = "English" },
    },
    value = settings.Language(ns.db),
    onChange = function(value)
      settings.SetLanguage(ns.db, value)
      ns.Locale.UsePreference(value, ns.Platform.GetLocale())
      UI.LanguageChanged()
    end,
  })
  Kit.Switch(stack, {
    label = L("Show the minimap button"),
    checked = not ns.MinimapButton.Settings(ns.db).hide,
    onChange = function(on)
      ns.MinimapButton.SetHidden(ns.db, not on)
    end,
  })
  local position = Kit.Row(stack, { gap = 10, align = "center" })
  Kit.Label(position, { text = L("Button position"), layout = { weight = 1 } })
  Kit.Button(position, {
    text = L("Reset"),
    layout = { width = "auto" },
    onClick = function()
      ns.MinimapButton.ResetPosition(ns.db)
    end,
  })
  Kit.Switch(stack, {
    label = L("Blacklist alert sound"),
    checked = settings.BlacklistSound(ns.db),
    onChange = function(on)
      settings.SetBlacklistSound(ns.db, on)
    end,
  })
end

function UI.ToggleSettings()
  if not (window and ns.db) then
    return
  end
  local popup = Kit.Popup.Get(1)
  if popup:IsOpen() then
    popup:Close()
    return
  end
  popup:Open(window.buttons.settings.frame, 320, buildSettings, { point = "BOTTOMRIGHT" })
end

local function buildWindow()
  window = Kit.Window.New({
    name = "NrageAssistantWindow",
    title = "Nrage Assistant",
    version = ns.GetVersion(),
    buttons = {
      {
        name = "settings",
        icon = "gear",
        tooltip = L("Settings"),
        onClick = function()
          UI.ToggleSettings()
        end,
      },
    },
    onResize = onResize,
    onClose = function()
      Kit.CloseAllPopups()
      UI.WatchReadiness(false)
    end,
  })
  UI.ApplyWindowStatus(window, "mainWindow", 1000, 640)
  content = CreateFrame("Frame", nil, window.body)
  content:SetPoint("TOPLEFT", window.body, "TOPLEFT", SIDEBAR_WIDTH, 0)
  content:SetPoint("BOTTOMRIGHT", window.body, "BOTTOMRIGHT", 0, 0)
  page = Kit.ScrollArea(content, { gap = Kit.Theme.metrics.blockGap, pad = PAGE_PAD })
  Kit.Place(page, content, 0, 0)
  if C_Timer.NewTicker then
    C_Timer.NewTicker(2, function()
      if UI.IsOpen() then
        UI.UpdatePill()
      end
    end)
  end
end

function UI.Toggle()
  if not ns.active or not ns.character then
    return
  end
  if window and window:IsShown() then
    window:Hide()
    UI.WatchReadiness(false)
    return
  end
  if not window then
    buildWindow()
  end
  window:Show()
  UI.WatchReadiness(ReadinessIsShown())
  UI.BuildSidebar()
  UI.UpdatePill()
  UI.Redraw()
end

-- Opens the window on `tab` (a value of ViewModel.TABS), or switches to it when the window is already open. `state`
-- (optional) tells the tab where to start (UI.nav): { eventId = ... } for the Raid and Loot tabs.
function UI.OpenTab(tab, state)
  if not ns.active or not ns.character then
    return
  end
  UI.nav = state or {}
  if UI.IsOpen() then
    UI.SelectTab(tab)
  else
    currentTab = tab
    UI.Toggle()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Items, as the loot windows show them (until they move to the kit).

-- An item as the client shows it elsewhere: its icon, its name beside it, and its tooltip on hover. Used by the
-- loot windows. `options` = { itemId, text, width (relative, or nil for the full width) }. Clicking calls
-- `onClick` when given. Returns the widget.
function UI.AddItemLabel(parent, options, onClick)
  local label = LibStub("AceGUI-3.0"):Create("InteractiveLabel")
  label:SetText(options.text)
  label:SetImage(ns.Platform.GetItemIcon(options.itemId))
  label:SetImageSize(24, 24)
  if options.width then
    label:SetRelativeWidth(options.width)
  else
    label:SetFullWidth(true)
  end
  if onClick then
    label:SetCallback("OnClick", onClick)
  end
  label:SetCallback("OnEnter", function(widget)
    if type(options.itemId) == "number" then
      GameTooltip:SetOwner(widget.frame, "ANCHOR_RIGHT")
      -- The tooltip may refuse an item the client has not seen; the icon and name still show.
      if pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. options.itemId) then
        GameTooltip:Show()
      else
        GameTooltip:Hide()
      end
    end
  end)
  label:SetCallback("OnLeave", function()
    GameTooltip:Hide()
  end)
  parent:AddChild(label)
  return label
end

-- ---------------------------------------------------------------------------------------------------------------
-- Export and import (until the modal moves to the kit): a small window with a text box that shows the export text, or
-- takes pasted text to import.

local transferFrame

local function ReleaseTransfer()
  if transferFrame then
    LibStub("AceGUI-3.0"):Release(transferFrame)
    transferFrame = nil
  end
end

local function TransferLibs()
  return { serialize = LibStub("NrageAssistant-LibSerialize"), deflate = LibStub("LibDeflate") }
end

local IMPORT_ERRORS = ns.Locale.Table(function()
  return {
    forbidden = L("your guild rank does not allow importing raid data."),
    not_string = L("nothing to import."),
    bad_header = L("that does not look like a Nrage export (it should start with NRAGE1:)."),
    too_large = L("that text is too large to import."),
    bad_encoding = L("the text is damaged (bad encoding)."),
    bad_compression = L("the text is damaged (bad compression)."),
    bad_payload = L("the text is damaged or not a Nrage export."),
  }
end)

function UI.ShowTransfer(mode)
  if not ns.active or not ns.character then
    return
  end
  ReleaseTransfer()

  local AceGUI = LibStub("AceGUI-3.0")
  local dialog = AceGUI:Create("Frame")
  transferFrame = dialog
  dialog:SetTitle(mode == "export" and L("Nrage export") or L("Nrage import"))
  dialog:SetWidth(520)
  dialog:SetHeight(360)
  dialog:SetLayout("Fill")
  dialog:SetCallback("OnClose", ReleaseTransfer)

  local box = AceGUI:Create("MultiLineEditBox")
  box:SetFullWidth(true)
  box:SetFullHeight(true)
  dialog:AddChild(box)

  if mode == "export" then
    local text, reason = ns.Transfer.Export(TransferLibs(), ns.db.global.events, ns.db.global.sync.tombstones)
    box:SetLabel(L("Select all and copy (Ctrl+C):"))
    box:DisableButton(true)
    box:SetText(text or (L("Export failed: ") .. tostring(reason)))
    if box.editBox then
      box.editBox:HighlightText()
    end
    return
  end

  box:SetLabel(L("Paste an export here, then press Import:"))
  box:SetButtonText(L("Import"))
  box:SetCallback("OnEnterPressed", function(_, _, text)
    -- An import is applied under the importer's own role and roster.
    local ownRoster =
      ns.RosterService.RosterOf(ns.db.global.members, ns.db.global.rosters, ns.Platform.GetIdentityKey())
    local ctx = {
      events = ns.db.global.events,
      tombstones = ns.db.global.sync.tombstones,
      now = ns.Platform.ServerTime,
      rosterOf = function()
        return ownRoster
      end,
    }
    local role = ns.PermissionService.OwnRole(ns.Platform)
    local summary, reason = ns.Transfer.Import(TransferLibs(), text, ctx, role)
    if summary then
      print("Nrage Assistant: " .. ns.Transfer.Describe(summary) .. L(". Imported data stays on this client only."))
    else
      print("Nrage Assistant: " .. L("import failed: ") .. (IMPORT_ERRORS[reason] or tostring(reason)))
    end
  end)
end

ns.UI = UI
