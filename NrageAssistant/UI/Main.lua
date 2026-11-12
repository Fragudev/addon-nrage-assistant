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

local LOOT_REDRAW_SECONDS = 0.25
local lootThrottle

-- Loot changed here or on a received message (a council opening a session sends a burst): the listeners run at most
-- once per LOOT_REDRAW_SECONDS.
function UI.LootChanged()
  lootThrottle = lootThrottle
    or ns.Throttle.New({
      run = function()
        for _, listener in ipairs(UI.lootListeners) do
          listener()
        end
      end,
      now = function()
        return ns.Platform.Now()
      end,
      schedule = C_Timer.After,
      interval = LOOT_REDRAW_SECONDS,
    })
  lootThrottle:Call()
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

-- The roster of this player, or nil without one.
function UI.OwnRosterId()
  local global = ns.db.global
  return ns.RosterService.RosterOf(global.members, global.rosters, ns.Platform.GetIdentityKey())
end

-- `tab` when this player sees it, else "home": a hidden tab, one the rank cannot see, or an unknown value.
function UI.ResolveTab(tab)
  if ns.ViewModel.TabVisible(tab, UI.Role(), UI.OwnRosterId()) then
    return tab
  end
  return "home"
end

-- What the roster selector of `tab` shows (ViewModel.RosterSelector for `action`): { visible, options, selected,
-- label }.
-- The pick is kept in UI.nav.rosters[tab] until the session ends (plan 2.2).
function UI.RosterSelection(tab, action)
  UI.nav.rosters = UI.nav.rosters or {}
  return ns.ViewModel.RosterSelector(UI.Role(), action, UI.OwnRosterId(), ns.db.global.rosters, UI.nav.rosters[tab])
end

-- Draws the selector of `tab` from UI.RosterSelection: a dropdown for who has the action on every roster, else the
-- own roster as a label. `onChange` runs after a pick, before the tab is drawn again.
function UI.DrawRosterSelector(parent, tab, data, onChange)
  if data.visible then
    local bar = Kit.Row(parent, { gap = 10, align = "center" })
    Kit.Dropdown(bar, {
      items = data.options,
      value = data.selected,
      layout = { width = 220 },
      onChange = function(value)
        UI.nav.rosters[tab] = value
        if onChange then
          onChange(value)
        end
        UI.Redraw()
      end,
    })
  elseif data.label then
    Kit.Label(parent, { text = L("Roster: %s"):format(data.label), color = "dim" })
  end
end

-- Who sees which events (RosterService.Viewer) for the own character; `selected` is what an admin picked in a selector.
function UI.Viewer(selected)
  local global = ns.db.global
  return ns.RosterService.OwnViewer(ns.Platform, global.rosters, global.members, selected)
end

-- Remembers where a window was left and how big: the saved numbers live in settings.windows[name] and the window
-- keeps them up to date as it is moved or resized. `width`/`height` are the first-time
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
  UI.Notify(ns.ViewModel.ReportBanner(lines))
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

-- Closes the menus and pickers opened from the page (a dropdown, a date picker): drawing the page again recycles the
-- widgets they were opened for, so a pick would land on another row. The settings popover and the modal belong to the
-- window, not to the page, and stay. Set below, next to the settings.
local closePagePopups

-- Draws the banner and the tab into the page again, keeping the scroll position.
function UI.Redraw()
  if not (UI.IsOpen() and page) then
    return
  end
  closePagePopups()
  -- Before the page goes: a text being typed is committed, not lost. Its commit may redraw too, which is harmless.
  Kit.CommitEdit()
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

-- A redraw that follows what arrived from the guild. While an edit box has the keyboard (a search or reason box being
-- typed in) it would destroy that box mid-typing, so it waits and runs once the focus is gone. A redraw the player
-- asked for with a click goes through UI.Redraw directly and is not held back.
local FOCUS_RETRY_SECONDS = 1
local focusWaiting = false

local function syncRedraw()
  if Kit.HasEditFocus() then
    if not focusWaiting then
      focusWaiting = true
      C_Timer.After(FOCUS_RETRY_SECONDS, function()
        focusWaiting = false
        if UI.IsOpen() then
          syncRedraw()
        end
      end)
    end
    return
  end
  UI.Redraw()
end

local function throttledRedraw(shown, seconds)
  local throttle
  return function()
    if not UI.IsOpen() or not shown() then
      return
    end
    throttle = throttle
      or ns.Throttle.New({
        run = syncRedraw,
        now = function()
          return ns.Platform.Now()
        end,
        schedule = C_Timer.After,
        interval = seconds,
      })
    throttle:Call()
  end
end

-- A PvP counter changed, here or on a received record (a whole guild logging in): the PvP tabs are drawn again if one
-- is on screen, at most once per PVP_REDRAW_SECONDS.
UI.PvPChanged = throttledRedraw(function()
  return currentTab == "pvp" or currentTab == "pvpadmin"
end, ns.Constants.PVP_REDRAW_SECONDS)

-- An event (or its attendance or assignments) arrived from the guild: the Raid tabs follow, once per interval.
UI.EventsChanged = throttledRedraw(function()
  return currentTab == "events" or currentTab == "raid"
end, 1)

-- A PvP season record changed here or arrived (`messageType`): the PvP tab follows like for a counter, and the Members
-- tab too when the PvP officer flag moved.
function UI.PvPSeasonChanged(messageType)
  UI.PvPChanged()
  if messageType == "PVP_OFFICER" and currentTab == "roster" then
    syncRedraw()
  end
end

-- The own layer, a received layer or the swap changed (a whole guild logging in sends one state each): the Layers tab
-- is drawn again if it is the one on screen, at most once per LAYER_REDRAW_SECONDS.
UI.LayersChanged = throttledRedraw(function()
  return currentTab == "layers" or currentTab == "home"
end, ns.Constants.LAYER_REDRAW_SECONDS)

-- The open groups of the board, the own one included: the count of the Groups item of the sidebar.
local function openGroups()
  return ns.lfgBoard and ns.lfgBoard:OpenCount() or 0
end

-- Changes the count of the sidebar without building it again. Cheap, and not tied to the tab on screen: the count is
-- on every tab.
function UI.RefreshGroupsBadge()
  if UI.IsOpen() and sidebar then
    sidebar:SetItemBadge("groups", ns.ViewModel.GroupsBadge(openGroups()))
  end
end

local groupsRedraw = throttledRedraw(function()
  return currentTab == "groups" or currentTab == "home"
end, ns.Constants.LFG_REDRAW_SECONDS)

-- The board, the own post or the own application changed (a whole guild logging in sends one post each): the count of
-- the sidebar follows at once, and the Groups tab (and Home, which shows the count) is drawn again at most once per
-- LFG_REDRAW_SECONDS.
function UI.LfgChanged()
  UI.RefreshGroupsBadge()
  groupsRedraw()
  if ns.GroupsIcon then
    ns.GroupsIcon.Refresh()
  end
end

-- The announcements not read yet: the count of the Announcements item of the sidebar.
local function unreadAnnouncements()
  return ns.announcements and ns.announcements:Unread() or 0
end

-- Changes the count of the sidebar without building it again; the count is on every tab.
function UI.RefreshAnnouncementsBadge()
  if UI.IsOpen() and sidebar then
    sidebar:SetItemBadge("announcements", ns.ViewModel.AnnouncementsBadge(unreadAnnouncements()))
  end
end

local announcementsRedraw = throttledRedraw(function()
  return currentTab == "announcements" or currentTab == "announceadmin" or currentTab == "home"
end, ns.Constants.ANNOUNCE_REDRAW_SECONDS)

-- An announcement was published, changed, deleted or arrived from the guild (a snapshot brings the whole board): the
-- count of the sidebar follows at once, and the board, the editor and Home are drawn again at most once per
-- ANNOUNCE_REDRAW_SECONDS.
function UI.AnnouncementsChanged()
  UI.RefreshAnnouncementsBadge()
  announcementsRedraw()
end

-- A blacklist entry arrived from the guild (a snapshot brings the whole list), or the group changed.
UI.BlacklistChanged = throttledRedraw(function()
  return currentTab == "blacklist"
end, ns.Constants.BLACKLIST_REDRAW_SECONDS)

-- ---------------------------------------------------------------------------------------------------------------
-- Intel (docs/PVP_INTEL_PLAN.md section 3.4): the compact window, the button by the target frame, the pins and the
-- Intel sub-tab follow what the lists hold.

-- Draws again what is not the main window: the compact window, the target button and the enemy pins. Cheap when they
-- are hidden. Each part is guarded, so one that fails does not stop the others.
function UI.IntelRefreshAll()
  if ns.IntelWindow then
    pcall(ns.IntelWindow.Sync)
    pcall(ns.IntelWindow.Refresh)
  end
  if ns.IntelTargetButton then
    pcall(ns.IntelTargetButton.Refresh)
  end
  if ns.intelMapPins then
    pcall(ns.intelMapPins.Request, ns.intelMapPins)
  end
  -- The Enemies button on the world map shows the "worldmapPins" setting.
  if ns.WorldMapToggles then
    pcall(ns.WorldMapToggles.Refresh)
  end
end

local intelThrottle
local intelFull = false

-- The Intel lists changed (a sighting, a list edit, a guild Kill on Sight entry): everything that shows them is drawn
-- again, at most once per INTEL_REDRAW_SECONDS. `periodic` marks the call of the one second ticker, which only ages
-- what is listed: then the Intel sub-tab is drawn again only for the views that show ages. The sub-tab waits for an
-- edit box to lose the focus, and for a menu to close (drawing it again would take the menu away).
function UI.IntelChanged(periodic)
  if not periodic then
    intelFull = true
  end
  intelThrottle = intelThrottle
    or ns.Throttle.New({
      run = function()
        UI.IntelRefreshAll()
        if not (UI.IsOpen() and UI.IntelShown and UI.IntelShown()) then
          intelFull = false
        elseif intelFull or UI.IntelLive() then
          if Kit.Popup.Get(2):IsOpen() then
            return
          end
          intelFull = false
          syncRedraw()
        end
      end,
      now = function()
        return ns.Platform.Now()
      end,
      schedule = C_Timer.After,
      interval = ns.Constants.INTEL_REDRAW_SECONDS,
    })
  intelThrottle:Call()
end

-- What /nrage intel show, hide, config and stats call.
function UI.IntelShow()
  if ns.IntelWindow then
    ns.IntelWindow.Show()
  end
end

function UI.IntelHide()
  if ns.IntelWindow then
    ns.IntelWindow.Hide()
  end
end

function UI.IntelConfig()
  UI.OpenIntelTab("settings")
end

function UI.IntelStats()
  UI.OpenIntelTab("stats")
end

-- Recipes arrived from the guild, or a profession was scanned: the Professions tab and the Profile tab follow, once per
-- interval (a guild logging in sends many lists).
UI.RecipesChanged = throttledRedraw(function()
  return currentTab == "professions" or currentTab == "profile"
end, 1)

-- A member was heard from (Domain/InstallDirectory): the Installed check tab follows, once per interval (a guild
-- logging in announces itself all at once, and every message counts).
UI.InstallsChanged = throttledRedraw(function()
  return currentTab == "installs"
end, 2)

-- The guild's readiness rules changed: rare (one message per change), so no throttling.
function UI.RulesChanged()
  if UI.IsOpen() and (currentTab == "ready" or currentTab == "rules") then
    syncRedraw()
  end
end

-- The rank map changed (saved here or received): the role of this player may have changed, so the sidebar is built
-- again, and the Ranks tab, or any tab the role no longer reaches, is drawn again.
function UI.RanksChanged()
  UI.RostersChanged()
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
          syncRedraw()
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
-- The tabs of the section of `value` (ViewModel.SectionTabs), drawn at the top of each of its pages; nothing when the
-- player sees only one of them.
function UI.DrawSectionTabs(page, value)
  local tabs = ns.ViewModel.SectionTabs(value, UI.Role(), UI.OwnRosterId())
  if #tabs < 2 then
    return
  end
  Kit.Segmented(page, {
    items = tabs,
    value = value,
    onChange = function(selected)
      UI.SelectTab(selected)
    end,
  })
end

-- The shell

-- The sidebar again, after a tab or the language changed: the selection and the texts follow.
function UI.BuildSidebar()
  if not window then
    return
  end
  -- The scroll of the rows survives the rebuild, so picking a tab low in a short window does not jump to the top.
  local navScroll = 0
  if sidebar then
    navScroll = sidebar.nav and sidebar.nav:GetScroll() or 0
    sidebar:Release()
  end
  local role = UI.Role()
  -- The rank or the roster may have changed: a tab that is not visible any more gives way to Home, with everything a
  -- change of tab does (the banner, the armed action, the scroll, what is watched). SelectTab builds the sidebar.
  local resolved = UI.ResolveTab(currentTab)
  if resolved ~= currentTab then
    UI.SelectTab(resolved)
    return
  end
  sidebar = Kit.Sidebar(window.body, {
    groups = ns.ViewModel.NavGroups(role, UI.OwnRosterId(), openGroups(), unreadAnnouncements()),
    value = ns.ViewModel.NavValue(currentTab, role, UI.OwnRosterId()),
    onSelect = function(value)
      UI.SelectTab(value)
    end,
    user = ns.ViewModel.UserCard(ns.Platform.GetIdentityKey(), ns.Platform.GetOwnGuildRank(), role),
    translucent = window.scene,
    scroll = navScroll,
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
  tab = UI.ResolveTab(tab)
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

-- A module was switched on or off (ns.modules): the sidebar is built again, so a tab that is hidden now gives way to
-- Home (BuildSidebar), and the open tab is drawn again.
function UI.ModulesChanged()
  UI.BuildSidebar()
  UI.Redraw()
  if ns.GroupsIcon then
    ns.GroupsIcon.Refresh()
  end
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
  local sharing = ns.PositionModel.Settings(ns.db)
  Kit.Switch(stack, {
    label = L("Share my position"),
    description = L("Guildmates see where you are on the map. Turn it off and they forget it."),
    checked = sharing.share,
    onChange = function(on)
      ns.SetPositionShare(on)
    end,
  })
  Kit.Switch(stack, {
    label = L("Show guildmates on the minimap"),
    checked = sharing.minimap,
    onChange = function(on)
      ns.SetPositionDisplay("minimap", on)
    end,
  })
  Kit.Switch(stack, {
    label = L("Show guildmates on the world map"),
    checked = sharing.worldmap,
    onChange = function(on)
      ns.SetPositionDisplay("worldmap", on)
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

closePagePopups = function()
  Kit.Menu.Close()
  local popover = Kit.Popup.Get(1)
  if popover:IsOpen() and popover.build ~= buildSettings then
    popover:Close()
  end
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

-- Opens the window if needed and shows the settings (from the minimap menu).
function UI.OpenSettings()
  if not ns.active or not ns.character then
    return
  end
  if not UI.IsOpen() then
    UI.Toggle()
  end
  if not Kit.Popup.Get(1):IsOpen() then
    UI.ToggleSettings()
  end
end

local pillTicker

-- The window closed (its button, Escape or the toggle): nothing it armed or reported outlives it, and nothing keeps
-- running for it.
function UI.WindowClosed()
  Kit.CloseAllPopups()
  UI.WatchReadiness(false)
  banner = nil
  armed = nil
  if pillTicker then
    pillTicker:Cancel()
    pillTicker = nil
  end
end

local function buildWindow()
  -- An unpackaged checkout reports "dev": the header shows no badge for it, while the minimap and the login line do.
  local version = ns.GetVersion()
  window = Kit.Window.New({
    name = "NrageAssistantWindow",
    title = "Nrage Assistant",
    version = version ~= "dev" and version or nil,
    scene = true,
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
      UI.WindowClosed()
    end,
  })
  UI.ApplyWindowStatus(window, "mainWindow", 1000, 640)
  content = CreateFrame("Frame", nil, window.body)
  content:SetPoint("TOPLEFT", window.body, "TOPLEFT", SIDEBAR_WIDTH, 0)
  content:SetPoint("BOTTOMRIGHT", window.body, "BOTTOMRIGHT", 0, 0)
  page = Kit.ScrollArea(content, { gap = Kit.Theme.metrics.blockGap, pad = PAGE_PAD })
  Kit.Place(page, content, 0, 0)
end

-- The sync pill follows the sync status while the window is open.
local function startPillTicker()
  if not pillTicker and C_Timer.NewTicker then
    pillTicker = C_Timer.NewTicker(2, function()
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
    UI.WindowClosed()
    return
  end
  if not window then
    buildWindow()
  end
  window:Show()
  startPillTicker()
  UI.WatchReadiness(ReadinessIsShown())
  UI.BuildSidebar()
  UI.UpdatePill()
  UI.Redraw()
end

-- Opens the window on `tab` (a value of ViewModel.TABS), or switches to it when the window is already open. A tab that
-- is hidden or that this player does not see opens Home. `state` (optional) tells the tab where to start (UI.nav):
-- { eventId = ... } for the Raid and Loot tabs.
function UI.OpenTab(tab, state)
  if not ns.active or not ns.character then
    return
  end
  tab = UI.ResolveTab(tab)
  local rosters = UI.nav.rosters
  UI.nav = state or {}
  UI.nav.rosters = rosters
  if UI.IsOpen() then
    UI.SelectTab(tab)
  else
    currentTab = tab
    UI.Toggle()
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Export and import: a modal over the dimmed main window with a text box that shows the export text, or takes pasted
-- text to import. Addons cannot write to the clipboard, so the export selects its text and the player copies it.

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

-- Applies pasted text under the importer's own role and roster; returns the banner kind and text.
local function importText(text)
  local ownRoster = ns.RosterService.RosterOf(ns.db.global.members, ns.db.global.rosters, ns.Platform.GetIdentityKey())
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
    return "success", ns.Transfer.Describe(summary) .. L(". Imported data stays on this client only.")
  end
  return "danger", L("import failed: ") .. (IMPORT_ERRORS[reason] or tostring(reason))
end

function UI.ShowTransfer(mode)
  if not ns.active or not ns.character then
    return
  end
  local area
  Kit.Modal.Open({
    title = mode == "export" and L("Nrage export") or L("Nrage import"),
    width = 520,
    build = function(stack)
      if mode == "export" then
        local text, reason = ns.Transfer.Export(TransferLibs(), ns.db.global.events, ns.db.global.sync.tombstones)
        Kit.Label(stack, { text = L("Press Ctrl+C to copy"), color = "dim" })
        area = Kit.TextArea(stack, {
          text = text or (L("Export failed: ") .. tostring(reason)),
          readOnly = true,
          height = 200,
        })
        return
      end
      Kit.Label(stack, { text = L("Paste the text (Ctrl+V)"), color = "dim" })
      area = Kit.TextArea(stack, { text = "", height = 200 })
      local buttons = Kit.Row(stack, { gap = 8, align = "center" })
      Kit.Button(buttons, {
        text = L("Import"),
        variant = "primary",
        layout = { width = "auto" },
        onClick = function()
          local kind, text = importText(area:GetValueText())
          Kit.Modal.Close()
          UI.Notify(kind, ns.ViewModel.Escape(text))
        end,
      })
      Kit.Button(buttons, {
        text = L("Cancel"),
        variant = "ghost",
        layout = { width = "auto" },
        onClick = Kit.Modal.Close,
      })
    end,
  })
  if mode == "export" and area then
    area:HighlightAll()
  end
end

ns.UI = UI
