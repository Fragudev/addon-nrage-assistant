-- A smoke test of the window (UI/Main.lua and the tabs in UI/Tabs) against a fake of the kit's API
-- (tests/support/fake_kit.lua). It cannot say how anything looks, but it draws every tab for each kind of player and
-- presses the buttons, which catches the nil calls and wrong argument orders that are otherwise only found in the game.
local FakeFrames = dofile("tests/support/fake_frames.lua")
local FakeKit = dofile("tests/support/fake_kit.lua")
local Roles = dofile("tests/support/roles.lua")

local ALL_TABS = {
  "home",
  "professions",
  "events",
  "ready",
  "loot",
  "pvp",
  "groups",
  "announcements",
  "raid",
  "rules",
  "roster",
  "pvpadmin",
  "installs",
  "ranks",
  "announceadmin",
}
-- Tabs that left the sidebar but stay registered (docs/NAV_PERMISSIONS_PLAN.md 0.1): the specs of their views open them
-- anyway.
local HIDDEN_TABS = { profile = true, layers = true, blacklist = true, broken = true }

-- `locale` (optional) is the client locale code the window is built for, e.g. "esES".
local function load_window(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/Settings",
    "Domain/Throttle",
    "Domain/PvPService",
    "Domain/PvPFeed",
    "Domain/PermissionService",
    "Domain/RankMapModel",
    "Domain/PvPSeasonModel",
    "Domain/PvPSeasonService",
    "Domain/PvPMissionTracker",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSeasonSync",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/TemplateService",
    "Domain/Professions",
    "Domain/ReadinessService",
    "Domain/ReadinessRules",
    "Domain/ProfileService",
    "Domain/PublishService",
    "Domain/BlacklistService",
    "Domain/LayerModel",
    "Domain/LfgModel",
    "Domain/LfgBoard",
    "Domain/LfgService",
    "Domain/PositionModel",
    "Domain/ReportService",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelReport",
    "Domain/IntelImport",
    "Domain/GuildKosService",
    "Domain/InstallDirectory",
    "Domain/AnnouncementModel",
    "Domain/AnnouncementService",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
    "UI/Kit/Shape",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/Kit/Icons",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelRaid",
    "UI/ViewModelGuild",
    "UI/ViewModelPvP",
    "UI/ViewModelProfessions",
    "UI/ViewModelLayers",
    "UI/ViewModelIntel",
    "UI/ViewModelGroups",
    "UI/ViewModelInstalls",
    "UI/ViewModelAnnouncements",
    "UI/ViewModelRanks",
    "UI/MinimapButton",
    "Commands/RaidCommands",
    "Commands/LootCommands",
    "Commands/TemplateCommands",
    "Commands/BlacklistCommands",
    "Commands/RosterCommands",
    "Commands/IntelCommands",
    "UI/SidebarWidth",
    "UI/Main",
    "UI/Cards",
    "UI/Tabs/Home",
    "UI/Tabs/Profile",
    "UI/Tabs/Readiness",
    "UI/Tabs/Members",
    "UI/Tabs/Raid",
    "UI/Tabs/Events",
    "UI/Tabs/Loot",
    "UI/Tabs/PvP",
    "UI/Tabs/PvPAdmin",
    "UI/Tabs/PvPIntel",
    "UI/Tabs/Blacklist",
    "UI/Tabs/Rules",
    "UI/Tabs/Professions",
    "UI/Tabs/Layers",
    "UI/Tabs/Groups",
    "UI/Tabs/Installs",
    "UI/Tabs/Announcements",
    "UI/Tabs/AnnouncementsAdmin",
    "UI/AnnouncementPopup",
    "Domain/ModuleRegistry",
    "Domain/ModuleService",
    "UI/ViewModelModules",
    "UI/Tabs/Modules",
    "UI/Tabs/Ranks",
  }) do
    if path == "UI/ViewModel" then
      ns.Kit = FakeKit.new(ns.Kit)
    end
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns
end

-- rank: "GM" | "CoGM" | "RL" | "Council" (an officer) | "Roster" | "Member" | "Alter" | "Norost" (a roster player
-- with no roster).
local function build(rank, locale)
  local ns = load_window(locale)
  local fake = FakeKit
  local env = { ns = ns, sent = {}, messages = {}, counter = 0, registered = {}, timers = {}, fake = fake }
  env.frames = FakeFrames.install()
  -- The real gate, and one that lets the hidden tabs through so the specs of their views can open them. A spec that
  -- sets `env.forceTabs` opens any tab for any rank, to check what a tab draws for a player who cannot reach it.
  env.realTabVisible = ns.ViewModel.TabVisible
  ns.ViewModel.TabVisible = function(value, ...)
    return HIDDEN_TABS[value] or env.forceTabs or env.realTabVisible(value, ...)
  end

  ns.active = true
  ns.GetVersion = function()
    return "test"
  end
  ns.Platform = {
    GetLocale = function()
      return locale or "enUS"
    end,
    TryRegisterEvent = function(_, event)
      env.registered[event] = true
      return true
    end,
    TryRegisterUnitEvent = function(_, event, unit)
      env.registered[event] = unit
      return true
    end,
    GetOwnGuildRank = Roles.ranking(rank == "Norost" and "Roster" or rank),
    GetGuildRanks = function()
      return env.guildRanks
        or { [0] = "Emperador", [1] = "Comandante", [2] = "Oficial", [3] = "Raider", [5] = "Soldado" }
    end,
    GetIdentityKey = function()
      return "Leader-Realm"
    end,
    GetLegacyIdentityKey = function()
      return "Leader-Realm"
    end,
    NormalizeName = function(name)
      return name
    end,
    ServerTime = function()
      return 1000
    end,
    FormatDate = function(timestamp)
      return "date:" .. timestamp
    end,
    ParseDate = function()
      return 2000
    end,
    FormatClock = function(timestamp)
      return "clock:" .. timestamp
    end,
    GetGUID = function() end,
    GetClass = function()
      return "MAGE"
    end,
    GetLevel = function()
      return 60
    end,
    GetAverageItemLevel = function()
      return 100
    end,
    GetProfessions = function()
      return {
        { name = "Alchemy", icon = 136240, skill = 300, max = 300 },
        { name = "Cooking", skill = 20, max = 300, secondary = true },
      }
    end,
    GetEquippedEnchants = function() end,
    GetActiveBuffs = function() end,
    IsChatMessagingLockedDown = function()
      return false
    end,
    IsInInstance = function()
      return false
    end,
    GetPlayerZoneId = function() end,
    GetItemIcon = function(itemId)
      return "icon:" .. tostring(itemId)
    end,
    GetItemDetails = function()
      return { level = 213, slot = "Two-Hand" }
    end,
    Now = function()
      return 0
    end,
    GroupApiAvailable = function()
      return true
    end,
    IsInGroup = function()
      return true
    end,
    GetFullGroupNames = function()
      return { "Ann-Realm", "Leader-Realm", "Stranger" }
    end,
    GetGroupMemberNames = function()
      return { "Ann-Realm" }
    end,
    LootWindowAvailable = function()
      return false
    end,
    RecipeScanAvailable = function()
      return env.scanAvailable ~= false
    end,
    GetRecipeInfo = function(id)
      return env.recipeNames and env.recipeNames[id] and { name = env.recipeNames[id], link = "[link" .. id .. "]" }
    end,
    CanPrefillChat = function()
      return true
    end,
    PrefillChat = function(text)
      env.prefilled = text
    end,
  }
  ns.db = {
    global = {
      events = {},
      roster = {},
      templates = {},
      sync = { tombstones = {} },
      pvpStats = {},
      blacklist = {},
      readinessRulesByRoster = {},
      rosters = {},
      members = {},
      recipes = {},
      installs = {},
      announcements = { items = {}, tombstones = {} },
      announcementsSeen = {},
    },
  }
  -- The announcements: the real service, over a fake transport that records what it sends.
  env.announced = {}
  ns.announcements = ns.AnnouncementService.New({
    store = ns.db.global.announcements,
    seen = ns.db.global.announcementsSeen,
    now = function()
      return ns.Platform.ServerTime()
    end,
    ownName = function()
      return "Leader-Realm"
    end,
    ownRole = function()
      return ns.PermissionService.OwnRole(ns.Platform)
    end,
    newId = function()
      env.counter = env.counter + 1
      return "ann" .. env.counter
    end,
    send = {
      upsert = function(announcement)
        env.announced[#env.announced + 1] = "ANN:" .. announcement.id
      end,
      delete = function(id)
        env.announced[#env.announced + 1] = "ANN_DEL:" .. id
      end,
    },
    onChange = function() end,
  })
  -- The role is the guild rank: "GM" and "CoGM" have no roster, the other ranks put this character in roster r1 (a
  -- "Norost" player has no roster at all).
  ns.db.global.members, ns.db.global.rosters = Roles.assignments(rank == "Norost" and "Roster" or rank, "Leader-Realm")
  if rank == "Norost" then
    ns.db.global.members["Leader-Realm"].rosterId = nil
  end
  ns.character = {
    profile = { fields = {} },
    recipes = {},
    readiness = {},
    publish = {},
    pvp = { honor = { world = 4, bg = 6 }, blows = { world = 1, bg = 2 }, daily = {} },
  }
  ns.guildRoster = {
    entries = {
      ["Ann-Realm"] = { rankName = "Raider", rankIndex = 3, level = 60, class = "WARRIOR" },
      ["Leader-Realm"] = { rankName = "Raider", rankIndex = 3, level = 60, class = "MAGE" },
      ["Yonemon Gg"] = { rankName = "Raider", rankIndex = 5, level = 50, class = "ROGUE" },
    },
    Names = function()
      return { "Ann-Realm", "Leader-Realm", "Yonemon Gg" }
    end,
    Lookup = function(_, name)
      return name == "Ann-Realm" and { rankName = "Raider" } or nil
    end,
  }
  ns.comm = {
    NextId = function()
      env.counter = env.counter + 1
      return "id" .. env.counter
    end,
    Status = function()
      return { "sync ready" }
    end,
    StatusInfo = function()
      return { paused = false, queued = 0, peers = 2, incompatible = {} }
    end,
    Send = function(_, messageType)
      env.messages[#env.messages + 1] = messageType
      return true
    end,
    AskVersions = function()
      env.asked = (env.asked or 0) + 1
      if env.askReason then
        return false, env.askReason, 12
      end
      return true
    end,
    ResetPvP = function(_, target)
      env.sent[#env.sent + 1] = "ResetPvP:" .. target
      return true, 3, true
    end,
    SetReadinessRules = function(_, rosterId, rules)
      local clean, reason = ns.ReadinessRules.Validate(rules)
      if not clean then
        return false, reason
      end
      local record = ns.db.global.readinessRulesByRoster[rosterId] or {}
      ns.db.global.readinessRulesByRoster[rosterId] = record
      record.rev = (record.rev or 0) + 1
      record.rules = clean
      env.sent[#env.sent + 1] = "SetReadinessRules"
      env.rulesRoster = rosterId
      return true, record.rev
    end,
  }
  for _, kind in ipairs({
    "SendEvent",
    "SendAttendance",
    "SendSignup",
    "SendAssignment",
    "SendDeleteAssignment",
    "SendDeleteEvent",
    "SendLootSession",
    "SendLootCandidate",
    "SendLootVote",
    "SendLootAward",
    "SendBlacklistUpsert",
    "SendBlacklistDelete",
    "SendRoster",
    "SendDeleteRoster",
    "SendMember",
    "SendDeleteMember",
  }) do
    ns.comm[kind] = function()
      env.sent[#env.sent + 1] = kind
      return true
    end
  end
  -- The PvP seasons: the real ledger service over a fake guild. `env.asRole` lets a test act as the admin to seed a
  -- season; `env.pvpSent` records what the service sent.
  env.pvpSent = {}
  env.pvpRoles = { ["Ann-Realm"] = "member", ["Boss-Realm"] = "gm", ["Yonemon Gg"] = "member" }
  ns.db.global.pvpSeason = ns.PvPSeasonSync.NewLedger()
  ns.pvpSeason = ns.PvPSeasonService.New({
    ledger = ns.db.global.pvpSeason,
    now = ns.Platform.ServerTime,
    newId = function()
      return ns.comm:NextId()
    end,
    ownName = ns.Platform.GetIdentityKey,
    ownRole = function()
      return env.asRole or ns.PermissionService.OwnRole(ns.Platform)
    end,
    roleOf = function(name)
      return env.pvpRoles[name]
    end,
    send = function(messageType)
      env.pvpSent[#env.pvpSent + 1] = messageType
      return true
    end,
  })
  ns.VotingFrame = {
    Show = function()
      env.votingShown = true
    end,
  }
  ns.LootPopup = {
    Pass = function(sessionId)
      env.passed = sessionId
    end,
    TimeLeft = function()
      return 30
    end,
  }
  ns.pvpFeed = {
    Entries = function()
      return { { killers = { "Leader-Realm" }, victim = "Zed", where = "world", blow = true, time = 5 } }
    end,
    Available = function()
      return true
    end,
  }
  ns.pvpTracker = {
    honorAvailable = true,
    blowsAvailable = true,
    Day = function()
      return "2026-10-19"
    end,
  }
  _G.GameTooltip = { SetOwner = function() end, Show = function() end, Hide = function() end }
  _G.C_Timer = {
    After = function(_, fn)
      env.timers[#env.timers + 1] = fn
    end,
  }

  -- The last page the window made and the nodes under it.
  function env.page()
    local found
    for _, node in ipairs(ns.Kit.fake.nodes) do
      if node.kind == "ScrollArea" then
        found = node
      end
    end
    return found
  end
  -- Opens the window on `tab` and returns the page, failing when the tab raised (the window shows it as a banner).
  function env.open(tab, state)
    ns.UI.OpenTab(tab, state)
    local page = env.page()
    for _, banner in ipairs(fake.find_all(page, "Banner")) do
      assert.are_not.equal("danger", banner.opts.kind == "danger" and banner.opts.text or nil, tab)
    end
    return page
  end
  function env.redrawn()
    return env.page()
  end
  function env.find(root, kind, text)
    return fake.find(root, kind, text)
  end
  function env.text()
    return fake.text(env.page())
  end
  function env.close()
    if ns.UI.IsOpen() then
      ns.UI.Toggle()
    end
    FakeFrames.uninstall()
  end
  -- Presses a button by its text, anywhere on the page.
  function env.press(text, kind)
    local node = assert(fake.find(env.page(), kind or "Button", text), "no button " .. text)
    return fake.press(node)
  end
  -- A Table node's rows (the cells of each), or all of them.
  function env.tableRows(kind)
    local tables = fake.find_all(env.page(), "Table")
    return tables[kind or 1].opts.rows
  end
  -- The edit box whose placeholder is `placeholder`.
  function env.box(placeholder)
    for _, box in ipairs(fake.find_all(env.page(), "EditBox")) do
      if box.opts.placeholder == placeholder then
        return box
      end
    end
    error("no edit box " .. placeholder)
  end
  function env.banner()
    local banners = fake.find_all(env.page(), "Banner")
    return banners[1]
  end
  return env
end

local function event(id, title, extra)
  local e = {
    eventId = id,
    title = title,
    status = "planned",
    startAt = 5000,
    rev = 1,
    updatedAt = 1,
    rosterId = "r1",
    attendance = {},
    assignments = {},
    loot = {},
  }
  for key, value in pairs(extra or {}) do
    e[key] = value
  end
  return e
end

describe("Window smoke test", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("draws every tab for each of the seven ranks and for a roster player with no roster", function()
    for _, rank in ipairs({ "GM", "CoGM", "Council", "RL", "Roster", "Member", "Alter", "Norost" }) do
      env = build(rank)
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      for _, tab in ipairs(ALL_TABS) do
        assert.is_truthy(env.open(tab), rank .. " " .. tab)
      end
      pcall(env.close)
    end
  end)

  it("draws every tab again after data arrives, and when there is none", function()
    env = build("GM")
    for _, tab in ipairs(ALL_TABS) do
      env.open(tab)
      env.ns.UI.Redraw()
    end
    env.ns.db.global.events["e1"] = event("e1", "Raid", {
      loot = {
        s1 = {
          sessionId = "s1",
          itemId = 5,
          itemName = "Sword",
          status = "open",
          rev = 1,
          updatedAt = 3,
          candidates = { ["Ann-Realm"] = { need = "main", spec = "Tank", rev = 1 } },
          votes = {},
        },
      },
    })
    for _, tab in ipairs(ALL_TABS) do
      env.open(tab)
    end
  end)

  it("opens and closes the window, and a tab it does not know does not break it", function()
    env = build("Member")
    env.ns.UI.Toggle()
    assert.is_true(env.ns.UI.IsOpen())
    env.ns.UI.Toggle()
    assert.is_false(env.ns.UI.IsOpen())
    env.ns.UI.OpenTab("professions")
    assert.are.equal("professions", env.ns.UI.CurrentTab())
    env.ns.UI.OpenTab("home")
    assert.are.equal("home", env.ns.UI.CurrentTab())
  end)

  -- The options the main window is built with: it is made on the first open, so they are captured by wrapping
  -- the kit's window constructor.
  local function window_opts(current)
    local opts
    local New = current.ns.Kit.Window.New
    current.ns.Kit.Window.New = function(given)
      opts = given
      return New(given)
    end
    current.ns.UI.Toggle()
    return opts
  end

  it("shows the version in the header", function()
    env = build("Member")
    assert.are.equal("test", window_opts(env).version)
  end)

  it("shows no version in the header for an unpackaged build, which reports dev", function()
    env = build("Member")
    env.ns.GetVersion = function()
      return "dev"
    end
    assert.is_nil(window_opts(env).version)
  end)

  it("opens Home instead of a tab that is hidden, that the rank cannot see, or that does not exist", function()
    env = build("Member")
    env.ns.ViewModel.TabVisible = env.realTabVisible
    for _, tab in ipairs({ "profile", "layers", "blacklist", "raid", "loot", "roster", "nowhere" }) do
      env.ns.UI.OpenTab("professions")
      env.ns.UI.OpenTab(tab)
      assert.are.equal("home", env.ns.UI.CurrentTab(), tab)
      env.ns.UI.SelectTab("professions")
      env.ns.UI.SelectTab(tab)
      assert.are.equal("home", env.ns.UI.CurrentTab(), tab)
    end
    pcall(env.close)
    env = build("GM")
    env.ns.ViewModel.TabVisible = env.realTabVisible
    for _, tab in ipairs(ALL_TABS) do
      env.ns.UI.OpenTab(tab)
      assert.are.equal(tab, env.ns.UI.CurrentTab())
    end
  end)

  it("falls back to Home when the roster of the player stops allowing the tab on screen", function()
    env = build("RL")
    env.ns.ViewModel.TabVisible = env.realTabVisible
    env.ns.UI.OpenTab("rules")
    assert.are.equal("rules", env.ns.UI.CurrentTab())
    env.ns.db.global.members["Leader-Realm"].rosterId = nil
    env.ns.UI.RostersChanged()
    assert.are.equal("home", env.ns.UI.CurrentTab())
  end)

  describe("the sidebar edge", function()
    local cursor = 0
    local savedCursor

    before_each(function()
      savedCursor = _G.GetCursorPosition
      _G.GetCursorPosition = function()
        return cursor, 0
      end
    end)

    after_each(function()
      _G.GetCursorPosition = savedCursor
    end)

    local function open()
      env = build("Member")
      local window
      local New = env.ns.Kit.Window.New
      env.ns.Kit.Window.New = function(given)
        window = New(given)
        return window
      end
      env.ns.UI.Toggle()
      local edge, content
      for _, frame in ipairs(env.frames) do
        if frame.parent == window.body and frame.scripts.OnDoubleClick then
          edge = frame
        elseif frame.parent == window.body and frame.kind == "Frame" and not content then
          content = frame
        end
      end
      return window, assert(edge, "no sidebar edge"), assert(content, "no content frame")
    end

    -- The x offset of the last TOPLEFT point of a frame.
    local function left(frame)
      for index = #frame.points, 1, -1 do
        if frame.points[index][1] == "TOPLEFT" then
          return frame.points[index][4]
        end
      end
    end

    local function drag(edge, from, to)
      cursor = from
      edge.scripts.OnMouseDown(edge, "LeftButton")
      cursor = to
      edge.scripts.OnUpdate(edge)
      edge.scripts.OnMouseUp(edge)
    end

    it("starts at the saved width, or the default one", function()
      local _, edge, content = open()
      assert.are.equal(200, left(content))
      assert.are.equal(198, left(edge))
      assert.are.equal(200, env.ns.db.global.settings.sidebarWidth)
    end)

    it("moves the page with the edge and saves the width when let go", function()
      local _, edge, content = open()
      drag(edge, 500, 580)
      assert.are.equal(280, left(content))
      assert.are.equal(278, left(edge))
      assert.are.equal(280, env.ns.db.global.settings.sidebarWidth)
      assert.is_nil(edge.scripts.OnUpdate)
    end)

    it("stops at the edges of the range", function()
      local _, edge, content = open()
      drag(edge, 500, 0)
      assert.are.equal(160, left(content))
      drag(edge, 0, 900)
      assert.are.equal(360, left(content))
      assert.are.equal(360, env.ns.db.global.settings.sidebarWidth)
    end)

    it("gives way in a narrow window but keeps the chosen width for a wider one", function()
      local window, edge, content = open()
      drag(edge, 0, 160)
      window.frameWidth = 760
      window:NotifyResize()
      assert.are.equal(320, left(content))
      assert.are.equal(360, env.ns.db.global.settings.sidebarWidth)
      window.frameWidth = 1200
      window:NotifyResize()
      assert.are.equal(360, left(content))
    end)

    it("ignores the right button, and a double click puts back the default width", function()
      local _, edge, content = open()
      edge.scripts.OnMouseDown(edge, "RightButton")
      assert.is_nil(edge.scripts.OnUpdate)
      drag(edge, 0, 60)
      assert.are.equal(260, left(content))
      edge.scripts.OnDoubleClick(edge)
      assert.are.equal(200, left(content))
      assert.are.equal(200, env.ns.db.global.settings.sidebarWidth)
    end)
  end)

  local function sidebarGroups(e)
    local sidebar
    for _, node in ipairs(e.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        sidebar = node
      end
    end
    local labels, values = {}, {}
    for _, group in ipairs(sidebar.opts.groups) do
      labels[#labels + 1] = group.label
      for _, item in ipairs(group.items) do
        values[#values + 1] = item.value
      end
    end
    return labels, values
  end

  it("builds the sidebar from the rank and the roster: Guild for everyone, Admin from rl and officer up", function()
    local all = {
      "home",
      "professions",
      "events",
      "pvp",
      "groups",
      "announcements",
      "modules",
      "raid",
      "rules",
      "roster",
      "pvpadmin",
      "installs",
      "ranks",
      "announceadmin",
    }
    local expected = {
      GM = all,
      CoGM = all,
      Council = {
        "home",
        "professions",
        "events",
        "pvp",
        "groups",
        "announcements",
        "modules",
        "raid",
        "rules",
        "roster",
        "ranks",
      },
      RL = {
        "home",
        "professions",
        "events",
        "pvp",
        "groups",
        "announcements",
        "modules",
        "raid",
        "rules",
        "roster",
        "ranks",
      },
      Roster = { "home", "professions", "events", "pvp", "groups", "announcements", "modules" },
      Member = { "home", "professions", "pvp", "groups", "announcements", "modules" },
      Alter = { "home", "professions", "pvp", "groups", "announcements", "modules" },
      Norost = { "home", "professions", "pvp", "groups", "announcements", "modules" },
    }
    for rank, values in pairs(expected) do
      env = build(rank)
      env.ns.ViewModel.TabVisible = env.realTabVisible
      env.open("home")
      local labels, found = sidebarGroups(env)
      assert.are.same(values, found, rank)
      local admin = rank == "GM" or rank == "CoGM" or rank == "Council" or rank == "RL"
      assert.are.same(admin and { "Guild", "Admin" } or { "Guild" }, labels, rank)
      pcall(env.close)
    end
  end)

  it("shows what an action reported as a banner, colored by its outcome, and clears it when the tab changes", function()
    env = build("RL")
    env.open("raid")
    env.ns.UI.Report({ "done" })
    assert.are.equal("success", env.banner().opts.kind)
    env.ns.UI.Report({ "saved", "but not sent" })
    assert.are.equal("warning", env.banner().opts.kind)
    env.ns.UI.Report(env.ns.Validate.Failure("nope"))
    assert.are.equal("danger", env.banner().opts.kind)
    env.banner().opts.onDismiss()
    assert.is_nil(env.banner())
    env.ns.UI.Notify("success", "x")
    env.ns.UI.SelectTab("home")
    assert.is_nil(env.banner())
  end)

  it("shows a tab that failed as a danger banner instead of raising", function()
    env = build("Member")
    env.ns.UI.Register("broken", function()
      error("boom")
    end)
    env.ns.UI.OpenTab("broken")
    assert.are.equal("danger", env.banner().opts.kind)
    assert.is_truthy(env.banner().opts.text:find("boom", 1, true))
  end)

  describe("Home", function()
    it("shows the identity, the specs and the layer, and nothing else", function()
      env = build("Member")
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      local home = env.open("home")
      local text = env.text()
      assert.is_truthy(text:find("Mage", 1, true))
      assert.is_truthy(text:find("Your declared details", 1, true))
      assert.is_truthy(text:find("Your layer", 1, true))
      assert.is_nil(text:find("Your readiness", 1, true))
      assert.is_nil(text:find("Members with the addon", 1, true))
      assert.is_nil(text:find("Molten Core", 1, true))
      assert.is_nil(env.find(home, "Button", "Request a sync"))
    end)

    it("draws the identity, the specs and the layers for every rank", function()
      for _, rank in ipairs({ "GM", "RL", "Council", "Member", "Norost" }) do
        env = build(rank)
        local home = env.open("home")
        assert.is_truthy(FakeKit.find(home, "StatGrid"), rank)
        assert.are.equal(2, #FakeKit.find_all(home, "Dropdown"), rank)
        assert.is_truthy(env.text():find("Your layer", 1, true), rank)
        pcall(env.close)
      end
    end)

    it("says the layer feature is not available before it starts, and keeps the sharing switch", function()
      env = build("Member")
      env.open("home")
      assert.is_truthy(env.text():find("not available", 1, true))
      assert.is_truthy(FakeKit.find(env.page(), "Switch", "Share my layer"))
    end)

    it("saves a spec through ProfileService.SetField when its dropdown changes, and publishes it", function()
      env = build("Member")
      local keys = {}
      local setField = env.ns.ProfileService.SetField
      env.ns.ProfileService.SetField = function(platform, profile, key, value)
        keys[#keys + 1] = key
        return setField(platform, profile, key, value)
      end
      env.open("home")
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("Tank")
      assert.are.same({ "role" }, keys)
      assert.are.equal("Tank", env.ns.character.profile.fields.role.value)
      assert.are.same({ "PROFILE" }, env.messages)
      env.open("home")
      FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("Heal")
      assert.are.same({ "role", "role2" }, keys)
      assert.are.equal("Heal", env.ns.character.profile.fields.role2.value)
    end)
  end)

  describe("Profile", function()
    it("shows the identity, the professions in two groups and what is shared, with no publish button", function()
      env = build("Member")
      local profile = env.open("profile")
      local text = env.text()
      assert.is_truthy(text:find("Leader", 1, true))
      assert.is_truthy(text:find("Mage", 1, true))
      assert.is_truthy(text:find("Primary", 1, true))
      assert.is_truthy(text:find("Secondary", 1, true))
      assert.is_truthy(text:find("Not published yet", 1, true))
      assert.is_nil(env.find(profile, "Button", "Publish now"))
      assert.is_nil(env.find(profile, "Button", "Save"))
    end)

    it("puts the icon of each profession before its name, and nothing when the client gave none", function()
      env = build("Member")
      local profile = env.open("profile")
      local stats = {}
      for _, grid in ipairs(FakeKit.find_all(profile, "StatGrid")) do
        for _, stat in ipairs(grid.opts.stats) do
          stats[stat.caption] = stat
        end
      end
      assert.are.equal(136240, stats.Alchemy.icon)
      assert.is_nil(stats.Cooking.icon)
    end)

    it("saves the specs when they change and publishes, saying so", function()
      env = build("Member")
      local profile = env.open("profile")
      local dropdowns = FakeKit.find_all(profile, "Dropdown")
      dropdowns[1].opts.onChange("Tank")
      assert.are.equal("Tank", env.ns.character.profile.fields.role.value)
      assert.are.equal("success", env.banner().opts.kind)
      assert.are.same({ "PROFILE" }, env.messages)
      env.open("profile")
      FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("Heal")
      assert.are.equal("Heal", env.ns.character.profile.fields.role2.value)
      env.open("profile")
      FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("")
      assert.is_nil(env.ns.character.profile.fields.role2)
    end)

    it("saves the text fields when they lose the focus, and says why a value was not saved", function()
      env = build("Member")
      local profile = env.open("profile")
      local boxes = FakeKit.find_all(profile, "EditBox")
      boxes[1].opts.onCommit("Mymain")
      assert.are.equal("Mymain", env.ns.character.profile.fields.main.value)
      env.open("profile")
      FakeKit.find_all(env.page(), "EditBox")[2].opts.onCommit(string.rep("x", 300))
      assert.are.equal("danger", env.banner().opts.kind)
      assert.is_truthy(env.banner().opts.text:find("Not saved", 1, true))
      assert.is_nil(env.ns.character.profile.fields.notes)
    end)

    it("shows when it was last published", function()
      env = build("Member")
      env.ns.character.publish.at = 940
      env.open("profile")
      assert.is_truthy(env.text():find("Last published: 1 min ago", 1, true))
    end)

    it("links to the Professions tab", function()
      env = build("Member")
      env.open("profile")
      env.press("See recipes")
      assert.are.equal("professions", env.ns.UI.CurrentTab())
    end)
  end)

  describe("Readiness", function()
    it("lists a row per rule with the manual ones carrying a dropdown, and confirms one by hand", function()
      env = build("Roster")
      local ready = env.open("ready")
      local rows = FakeKit.find_all(ready, "ListRow")
      assert.are.equal(5, #FakeKit.find_all(ready, "List")[1].opts.rows)
      assert.are.equal(0, #rows)
      local dropdowns = {}
      for _, row in ipairs(FakeKit.find_all(ready, "List")[1].opts.rows) do
        if row.right then
          dropdowns[#dropdowns + 1] = row.right.opts
        end
      end
      assert.are.equal(2, #dropdowns)
      dropdowns[1].onChange("met")
      assert.are.equal("met", env.ns.character.readiness.consumables.status)
    end)

    it("shows the summary badge", function()
      env = build("Roster")
      local ready = env.open("ready")
      local header = env.find(ready, "PageHeader")
      assert.are.equal("Raid", header.opts.title)
      assert.is_truthy(header.opts.badge.text:find("met", 1, true))
    end)

    it("is a tab of the Raid section, next to Raid and Loot, and the sidebar keeps the Raid item selected", function()
      env = build("Roster")
      for _, value in ipairs({ "events", "ready", "loot" }) do
        local page = env.open(value)
        local strip = env.find(page, "Segmented")
        assert.is_truthy(strip, value)
        local values = {}
        for _, item in ipairs(strip.opts.items) do
          values[#values + 1] = item.value
        end
        assert.are.same({ "events", "ready", "loot" }, values, value)
        assert.are.equal(value, strip.opts.value, value)
        assert.are.equal("Raid", env.find(page, "PageHeader").opts.title, value)
      end
      local strip = env.find(env.open("events"), "Segmented")
      strip.opts.onChange("loot")
      assert.is_truthy(env.find(env.page(), "Segmented"))
      assert.are.equal("loot", env.find(env.page(), "Segmented").opts.value)
    end)

    local function with_second_roster(target, rules)
      target.ns.db.global.rosters.r2 = { id = "r2", name = "Second", rev = 1, updatedAt = 1 }
      target.ns.db.global.readinessRulesByRoster.r2 = { rev = 1, rules = rules }
    end

    local ONE_RULE = { { id = "only", label = "Only rule", check = "confirm", evidenceMode = "manual" } }

    it("measures a roster player against its own roster, with no selector", function()
      env = build("Roster")
      with_second_roster(env, ONE_RULE)
      local ready = env.open("ready")
      assert.are.equal(5, #FakeKit.find_all(ready, "List")[1].opts.rows)
      assert.is_nil(FakeKit.find(ready, "Dropdown"))
      assert.is_truthy(env.text():find("Roster: Main", 1, true))
    end)

    it("lets gm and cogm pick the roster whose rules to measure", function()
      for _, rank in ipairs({ "GM", "CoGM" }) do
        env = build(rank)
        with_second_roster(env, ONE_RULE)
        local ready = env.open("ready")
        local selector = FakeKit.find(ready, "Dropdown")
        assert.are.equal(2, #selector.opts.items, rank)
        -- No roster of their own: the first by name.
        assert.are.equal("r1", selector.opts.value, rank)
        assert.are.equal(5, #FakeKit.find_all(ready, "List")[1].opts.rows, rank)
        selector.opts.onChange("r2")
        local rows = FakeKit.find_all(env.page(), "List")[1].opts.rows
        assert.are.equal(1, #rows, rank)
        assert.are.equal("Only rule", rows[1].title, rank)
        pcall(env.close)
      end
    end)

    it("says there is no roster to check against when a gm has none", function()
      env = build("GM")
      env.ns.db.global.rosters = {}
      env.open("ready")
      assert.is_truthy(env.text():find("There is no roster to check against.", 1, true))
    end)

    it("redraws when the rules change", function()
      env = build("GM")
      env.open("ready")
      local count = #env.ns.Kit.fake.nodes
      env.ns.UI.RulesChanged()
      assert.is_true(#env.ns.Kit.fake.nodes > count)
    end)
  end)

  describe("Members", function()
    it("lists the whole guild read-only for a member", function()
      env = build("Member")
      env.forceTabs = true
      env.open("roster")
      assert.are.equal(3, #env.tableRows())
      assert.is_nil(env.find(env.page(), "Card", "Rosters"))
      assert.is_nil(env.text():find("New roster", 1, true))
      for _, row in ipairs(env.tableRows()) do
        assert.is_string(row.cells.role.text)
      end
    end)

    it(
      "gives the guild master the Rosters card and a roster dropdown on each row but their own, and no role dropdown",
      function()
        env = build("GM")
        env.open("roster")
        assert.is_truthy(env.text():find("New roster", 1, true))
        local widgets = 0
        for _, row in ipairs(env.tableRows()) do
          if row.cells.roster.widget == "dropdown" then
            widgets = widgets + 1
          end
          assert.is_string(row.cells.role.text)
          assert.is_nil(row.cells.role.widget)
        end
        assert.are.equal(3, widgets)
      end
    )

    it("gives the officer every roster read-only: no Rosters card, no dropdown", function()
      env = build("Council")
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.db.global.members["Ann-Realm"] = { rosterId = "r2", rev = 1, updatedAt = 1 }
      env.open("roster")
      assert.is_nil(env.find(env.page(), "Card", "Rosters"))
      assert.are.equal(3, #env.tableRows())
      for _, row in ipairs(env.tableRows()) do
        assert.is_nil(row.cells.roster.widget)
      end
      assert.is_truthy(FakeKit.find(env.page(), "Chip", "Alts (1)"))
    end)

    it("gives an rl its own roster and the players with no roster, with a limited dropdown", function()
      env = build("RL")
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.db.global.members["Ann-Realm"] = { rosterId = "r2", rev = 1, updatedAt = 1 }
      env.open("roster")
      assert.is_nil(env.find(env.page(), "Card", "Rosters"))
      assert.is_truthy(env.text():find("Roster: Main", 1, true))
      -- Ann is in another roster: she is not listed.
      local names = {}
      for _, row in ipairs(env.tableRows()) do
        names[#names + 1] = row.cells.name.text
        assert.are.equal("dropdown", row.cells.roster.widget)
        local values = {}
        for _, item in ipairs(row.cells.roster.opts.items) do
          values[#values + 1] = tostring(item.value)
        end
        assert.are.same({ "false", "r1" }, values)
      end
      table.sort(names)
      assert.are.same({ "Leader-Realm", "Yonemon Gg" }, names)
      -- Taking a player of the own roster out of it, and putting a free player in.
      for _, row in ipairs(env.tableRows()) do
        if row.cells.name.text == "Yonemon Gg" then
          row.cells.roster.opts.onChange("r1")
        end
      end
      assert.are.equal("r1", env.ns.db.global.members["Yonemon Gg"].rosterId)
      assert.are.same({ "SendMember" }, env.sent)
    end)

    it("creates, assigns, renames and deletes from the Rosters card and the rows", function()
      env = build("GM")
      env.open("roster")
      env.box("New roster name").opts.onChange("Seconds")
      env.press("New roster")
      assert.are.equal("success", env.banner().opts.kind, env.banner().opts.text)
      local id
      for rosterId, roster in pairs(env.ns.db.global.rosters) do
        if roster.name == "Seconds" then
          id = rosterId
        end
      end
      assert.is_truthy(id)
      assert.are.same({ "SendRoster" }, env.sent)

      env.open("roster")
      local target
      for _, row in ipairs(env.tableRows()) do
        if row.cells.roster.widget == "dropdown" then
          target = row
        end
      end
      target.cells.roster.opts.onChange(id)
      local assigned
      for name, record in pairs(env.ns.db.global.members) do
        if record.rosterId == id then
          assigned = name
        end
      end
      assert.is_truthy(assigned)
      assert.is_nil(env.ns.db.global.members[assigned].role)

      env.open("roster")
      for _, button in ipairs(FakeKit.find_all(env.page(), "IconButton")) do
        if button.opts.icon == "pencil" then
          button.opts.onClick()
        end
      end
      local edit
      for _, box in ipairs(FakeKit.find_all(env.page(), "EditBox")) do
        if box.opts.text == "Seconds" then
          edit = box
        end
      end
      edit.opts.onCommit("Renamed")
      assert.are.equal("Renamed", env.ns.db.global.rosters[id].name)

      env.open("roster")
      local trash = {}
      for _, button in ipairs(FakeKit.find_all(env.page(), "IconButton")) do
        if button.opts.icon == "trash" then
          trash[#trash + 1] = button
        end
      end
      trash[#trash].opts.onClick()
      env.press("Confirm: delete")
      assert.is_nil(env.ns.db.global.rosters[id])
    end)

    it("filters by name and chips, sorts a column, expands a row and shows more", function()
      env = build("GM")
      env.ns.db.global.roster["Ann-Realm"] =
        { class = "WARRIOR", level = 60, receivedAt = 1, fields = { role = "Tank" } }
      env.open("roster")
      env.box("Search by name").opts.onChange("ann", true)
      assert.are.equal(1, #env.tableRows())
      env.box("Search by name").opts.onChange("", true)
      local chips = FakeKit.find_all(env.page(), "Chip")
      assert.is_true(#chips >= 4)
      for _, chip in ipairs(chips) do
        if chip.opts.text == "Tank" then
          chip.opts.onToggle(true)
        end
      end
      assert.are.equal(1, #env.tableRows())
      env.open("roster")
      local tbl = FakeKit.find_all(env.page(), "Table")[1]
      tbl.opts.onSort("level")
      tbl = FakeKit.find_all(env.page(), "Table")[1]
      tbl.opts.onSort("level")
      tbl.opts.rows[1].onClick()
      assert.is_truthy(FakeKit.find_all(env.page(), "Table")[1].opts.rows[1].detail)
    end)
  end)

  describe("Installed check", function()
    local function statuses()
      local list = {}
      for _, row in ipairs(env.tableRows()) do
        list[#list + 1] = row.cells.name.text .. "=" .. row.cells.status.opts.text
      end
      return list
    end

    before_each(function()
      env = build("GM")
      env.ns.db.global.installs["Ann-Realm"] = { version = "1.0.0", seenAt = 1 }
      env.ns.guildRoster.entries["Yonemon Gg"].online = true
      env.ns.guildRoster.entries["Bob-Realm"] = { rankName = "Raider", rankIndex = 5, class = "PRIEST" }
    end)

    it("lists every member with its status and version", function()
      env.open("installs")
      assert.are.same(
        { "Ann-Realm=Up to date", "Bob-Realm=Never seen", "Leader-Realm=Installed", "Yonemon Gg=Not installed" },
        statuses()
      )
      assert.are.equal("1.0.0", env.tableRows()[1].cells.version.text)
      assert.is_truthy(env.text():find("Newest seen: 1.0.0", 1, true))
    end)

    it("filters by name, status chip, version and online only", function()
      env.open("installs")
      env.box("Search by name").opts.onChange("ann", true)
      assert.are.same({ "Ann-Realm=Up to date" }, statuses())
      env.box("Search by name").opts.onChange("", true)

      local function chip(prefix)
        for _, node in ipairs(FakeKit.find_all(env.page(), "Chip")) do
          if node.opts.text:sub(1, #prefix) == prefix then
            return node
          end
        end
        error("no chip " .. prefix)
      end
      assert.are.equal("Not installed (1)", chip("Not installed").opts.text)
      chip("Not installed").opts.onToggle(true)
      assert.are.same({ "Yonemon Gg=Not installed" }, statuses())
      chip("Not installed").opts.onToggle(false)
      chip("With addon").opts.onToggle(true)
      assert.are.same({ "Ann-Realm=Up to date", "Leader-Realm=Installed" }, statuses())
      chip("With addon").opts.onToggle(false)

      local dropdown = FakeKit.find_all(env.page(), "Dropdown")[1]
      dropdown.opts.onChange("1.0.0")
      assert.are.same({ "Ann-Realm=Up to date" }, statuses())
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange(false)

      chip("Online only").opts.onToggle(true)
      assert.are.same({ "Leader-Realm=Installed", "Yonemon Gg=Not installed" }, statuses())
      chip("Online only").opts.onToggle(false)
    end)

    it("sorts by a column", function()
      env.open("installs")
      FakeKit.find_all(env.page(), "Table")[1].opts.onSort("status")
      assert.are.equal("Yonemon Gg=Not installed", statuses()[1])
    end)

    it("asks the members online for their version and says when it must wait", function()
      env.open("installs")
      env.press("Ask online members")
      assert.are.equal(1, env.asked)
      assert.are.equal("success", env.banner().opts.kind)
      env.askReason = "cooldown"
      env.press("Ask online members")
      assert.are.equal("warning", env.banner().opts.kind)
      assert.is_truthy(env.banner().opts.text:find("12", 1, true))
    end)

    it("redraws when a member is heard from", function()
      env.open("installs")
      env.ns.db.global.installs["Bob-Realm"] = { version = "0.9.0", seenAt = 2 }
      env.ns.UI.InstallsChanged()
      for _, fn in ipairs(env.timers) do
        fn()
      end
      local found
      for _, entry in ipairs(statuses()) do
        found = found or entry == "Bob-Realm=Outdated"
      end
      assert.is_true(found)
    end)
  end)

  describe("Ranks", function()
    local function saves(target)
      target.ns.comm.SetRankMap = function(_, ranks)
        target.saved = ranks
        return true, 1, true
      end
    end

    local function dropdowns()
      local found = {}
      for _, row in ipairs(env.tableRows()) do
        found[#found + 1] = row.cells.role.widget == "dropdown" and row.cells.role or nil
      end
      return found
    end

    it("lets the guild master pick a role per rank, previews the change and saves every rank", function()
      env = build("GM")
      saves(env)
      env.open("ranks")
      assert.are.equal(5, #env.tableRows())
      assert.are.equal("Guild master", env.tableRows()[1].cells.role.text)
      assert.are.equal(4, #dropdowns())
      -- Nothing saved yet: the first save pins today's roles, so it is enabled.
      assert.is_truthy(env.text():find("No member changes role.", 1, true))
      assert.is_falsy(env.find(env.page(), "Button", "Save mapping").opts.disabled)

      dropdowns()[2].opts.onChange("member") -- rank 2, an Oficial
      env.press("Save mapping")
      assert.are.equal("member", env.saved[2].role)
      assert.are.equal("cogm", env.saved[1].role)
      assert.are.equal("Oficial", env.saved[2].name)
      assert.is_nil(env.saved[0])
      assert.are.equal("success", env.banner().opts.kind)
    end)

    it("shows why a save was refused", function()
      env = build("GM")
      env.ns.comm.SetRankMap = function()
        return false, "stale"
      end
      env.open("ranks")
      env.press("Save mapping")
      assert.are.equal("danger", env.banner().opts.kind)
    end)

    it("gives an officer the mapping to read and no way to change it", function()
      env = build("Council")
      saves(env)
      env.open("ranks")
      assert.are.equal(0, #dropdowns())
      assert.is_nil(env.find(env.page(), "Button", "Save mapping"))
      assert.is_truthy(env.text():find("Only the guild master and the co-guild master", 1, true))
    end)

    it("keeps the row of their own rank read-only for a co-guild master", function()
      env = build("CoGM")
      saves(env)
      env.open("ranks")
      -- Rank 1 is theirs: text, not a dropdown; the other three ranks can be edited.
      assert.are.equal(3, #dropdowns())
      assert.is_nil(env.tableRows()[2].cells.role.widget)
    end)

    it("explains a renamed rank and a changed rank list", function()
      env = build("GM")
      env.ns.rankMapService = {
        Current = function()
          return {
            rev = 1,
            updatedAt = 5,
            by = "Boss",
            ranks = {
              [1] = { role = "cogm", name = "Comandante" },
              [2] = { role = "officer", name = "Oficial" },
              [3] = { role = "roster", name = "Raid Lider" },
              [8] = { role = "alter", name = "Gone" },
            },
          }
        end,
      }
      env.open("ranks")
      assert.is_truthy(env.text():find("Rank 3 was renamed from Raid Lider to Raider", 1, true))
      assert.is_truthy(env.text():find("Guild ranks changed; review the mapping.", 1, true))
      assert.is_truthy(env.text():find("Saved by Boss, date:5", 1, true))
    end)
  end)

  describe("Raid", function()
    local function open_raid(rank, force)
      env = build(rank)
      env.forceTabs = force
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      env.ns.db.global.events["e2"] = event("e2", "Old Raid", { startAt = 10, status = "closed" })
      return env.open("raid")
    end

    it("lists the upcoming events, with the past ones behind a filter", function()
      local raid = open_raid("RL")
      local list = FakeKit.find_all(raid, "List")[1]
      assert.are.equal(1, #list.opts.rows)
      assert.are.equal("Molten Core", list.opts.rows[1].title)
      FakeKit.find(raid, "Segmented").opts.onChange("past")
      assert.are.equal("Old Raid", FakeKit.find_all(env.page(), "List")[1].opts.rows[1].title)
    end)

    it("selects an event from the list and shows its header and the sub-tabs of the role", function()
      local raid = open_raid("RL")
      local strip = FakeKit.find(raid, "TabStrip")
      local values = {}
      for _, tab in ipairs(strip.opts.tabs) do
        values[#values + 1] = tab.value
      end
      assert.are.same({ "summary", "details", "attendance", "assignments", "templates", "reports" }, values)
      assert.is_truthy(env.text():find("Molten Core", 1, true))
    end)

    it("gives a member the summary and the reports only, with no controls", function()
      local raid = open_raid("Member", true)
      local values = {}
      for _, tab in ipairs(FakeKit.find(raid, "TabStrip").opts.tabs) do
        values[#values + 1] = tab.value
      end
      assert.are.same({ "summary", "reports" }, values)
      assert.is_nil(env.find(raid, "Button", "New event"))
    end)

    it("tells a member with no roster to ask for one and shows nothing else", function()
      env = build("Norost")
      env.forceTabs = true
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      local raid = env.open("raid")
      assert.is_truthy(env.find(raid, "EmptyState", "You are not in a roster yet"))
      assert.is_nil(env.find(raid, "TabStrip"))
    end)

    it("creates an event from the form, selects it and sends it", function()
      open_raid("RL")
      env.press("New event")
      local raid = env.page()
      local boxes = FakeKit.find_all(raid, "EditBox")
      boxes[1].opts.onChange("Blackwing Lair")
      FakeKit.find_all(raid, "DateField")[1].opts.onChange(7000)
      env.press("Create")
      local created
      for _, e in pairs(env.ns.db.global.events) do
        if e.title == "Blackwing Lair" then
          created = e
        end
      end
      assert.is_truthy(created)
      assert.are.same({ 7000, "r1" }, { created.startAt, created.rosterId })
      assert.are.equal("SendEvent", env.sent[1])
      assert.is_truthy(env.text():find("Blackwing Lair", 1, true))
    end)

    it("refuses an event with no title and says why", function()
      open_raid("RL")
      env.press("New event")
      env.press("Create")
      assert.are.equal("danger", env.banner().opts.kind)
    end)

    it("lets the guild master pick the roster of the new event, and move an event", function()
      env = build("GM")
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      env.open("raid")
      -- Admins see the roster selector and start on the first roster by name (they have none of their own).
      assert.are.equal("r2", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("r1")
      assert.are.equal("r1", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
      env.press("New event")
      local dropdowns = FakeKit.find_all(env.page(), "Dropdown")
      local rosterDropdown
      for _, d in ipairs(dropdowns) do
        if d.opts.items and d.opts.items[1] and d.opts.items[1].value == false then
          rosterDropdown = d
        end
      end
      assert.is_truthy(rosterDropdown)
      FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Alts raid")
      rosterDropdown.opts.onChange("r2")
      env.press("Create")
      local made
      for _, e in pairs(env.ns.db.global.events) do
        if e.title == "Alts raid" then
          made = e
        end
      end
      assert.are.equal("r2", made.rosterId)
    end)

    it("edits the details: rename, status, date, roster, and deletes only after a second click", function()
      open_raid("GM")
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("r1")
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("details")
      local raid = env.page()
      local box = FakeKit.find_all(raid, "EditBox")[1]
      box.opts.onCommit("Renamed")
      assert.are.equal("Renamed", env.ns.db.global.events.e1.title)
      FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("open")
      assert.are.equal("open", env.ns.db.global.events.e1.status)
      FakeKit.find(env.page(), "DateField").opts.onChange(9000)
      assert.are.equal(9000, env.ns.db.global.events.e1.startAt)
      FakeKit.find(env.page(), "DateField").opts.onError("does_not_exist")
      assert.are.equal("danger", env.banner().opts.kind)
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.UI.Redraw()
      local dropdowns = FakeKit.find_all(env.page(), "Dropdown")
      dropdowns[#dropdowns].opts.onChange("r2")
      assert.are.equal("r2", env.ns.db.global.events.e1.rosterId)
      -- The event left the roster on screen: follow it.
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("r2")
      env.press("Delete this event")
      assert.is_truthy(env.ns.db.global.events.e1)
      env.press("Confirm: delete this event")
      assert.is_nil(env.ns.db.global.events.e1)
    end)

    it("records attendance, adds a member from the search and fills from the group", function()
      open_raid("RL")
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("attendance")
      env.press("Fill from current group")
      local stored = env.ns.db.global.events.e1
      assert.are.equal("present", stored.attendance["Ann-Realm"].state)
      assert.are.equal("present", stored.attendance["Leader-Realm"].state)
      assert.is_nil(stored.attendance["Stranger"])
      assert.is_truthy(env.banner().opts.text:find("2 member(s) marked present", 1, true))
      -- Nothing left to add.
      env.press("Fill from current group")
      assert.is_truthy(env.banner().opts.text:find("Nobody to add", 1, true))

      local rows = env.tableRows()
      rows[1].cells.state.opts.onChange("late")
      assert.are.equal("late", stored.attendance["Ann-Realm"].state)

      FakeKit.find_all(env.page(), "EditBox")[1].opts.onEnter("yone")
      local chip = FakeKit.find(env.page(), "Chip", "Yonemon Gg")
      assert.is_truthy(chip)
      chip.opts.onToggle(true)
      assert.are.equal("present", stored.attendance["Yonemon Gg"].state)
    end)

    it("shows each player's sign-up read-only next to the attendance state", function()
      open_raid("RL")
      local stored = env.ns.db.global.events.e1
      stored.attendance["Ann-Realm"] = { state = "present", rev = 1, updatedAt = 1 }
      stored.attendance["Boss-Realm"] = { state = "absent", rev = 1, updatedAt = 1 }
      stored.attendance["Yonemon Gg"] = { state = "invited", rev = 1, updatedAt = 1 }
      stored.signups = {
        ["Ann-Realm"] = { status = "yes", rev = 1, updatedAt = 1 },
        ["Boss-Realm"] = { status = "no", rev = 1, updatedAt = 1 },
        ["Leader-Realm"] = { status = "yes", rev = 1, updatedAt = 1 },
      }
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("attendance")
      local rows = env.tableRows(1)
      assert.are.same({ "Going", "Not going", "-" }, {
        rows[1].cells.signup.text,
        rows[2].cells.signup.text,
        rows[3].cells.signup.text,
      })
      assert.is_truthy(env.find(env.page(), "Card", "Sign-ups (3)"))
      local signups = env.tableRows(2)
      assert.are.equal(3, #signups)
      assert.are.equal("Going", signups[3].cells.signup.text)
      -- Read-only: the leader cannot change them, and a missing table is fine on an old event.
      assert.is_nil(signups[1].cells.signup.widget)
      stored.signups = nil
      env.open("raid")
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("attendance")
      assert.is_truthy(env.find(env.page(), "Card", "Sign-ups (0)"))
    end)

    it("hides the group button when there is no group", function()
      open_raid("RL")
      env.ns.Platform.IsInGroup = function()
        return false
      end
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("attendance")
      assert.is_nil(env.find(env.page(), "Button", "Fill from current group"))
    end)

    it("adds an assignment under an encounter, creates a new encounter and removes one", function()
      open_raid("RL")
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("assignments")
      env.press("Add")
      assert.is_truthy(env.banner().opts.text:find("Pick a member first", 1, true))
      local dropdowns = FakeKit.find_all(env.page(), "Dropdown")
      dropdowns[1].opts.onChange("Ann-Realm")
      env.open("raid")
      dropdowns = FakeKit.find_all(env.page(), "Dropdown")
      dropdowns[2].opts.onChange(env.ns.ViewModel.NEW_ENCOUNTER)
      FakeKit.find(env.page(), "EditBox", "New encounter") -- the field of the new encounter
      local boxes = FakeKit.find_all(env.page(), "EditBox")
      boxes[1].opts.onChange("Ragnaros")
      env.press("Add")
      local stored = env.ns.db.global.events.e1
      local assignment = select(2, next(stored.assignments))
      assert.are.same({ "Ragnaros", "Ann-Realm" }, { assignment.encounter, assignment.characterKey })
      assert.are.equal("SendAssignment", env.sent[#env.sent])

      env.open("raid")
      for _, button in ipairs(FakeKit.find_all(env.page(), "IconButton")) do
        if button.opts.icon == "trash" then
          button.opts.onClick()
          break
        end
      end
      assert.is_nil(next(stored.assignments))
    end)

    it("applies a suggested template, saves one and deletes it after a second click", function()
      open_raid("RL")
      env.ns.db.global.templates["Molten Core"] = {
        name = "Molten Core",
        rosterId = "r1",
        slots = { { encounter = "Garr", characterKey = "Ann-Realm" } },
      }
      env.ns.UI.Redraw()
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("templates")
      env.press("Apply")
      assert.is_truthy(next(env.ns.db.global.events.e1.assignments))

      FakeKit.find_all(env.page(), "EditBox")[1].opts.onEnter("Saved one")
      assert.is_truthy(env.ns.db.global.templates["Saved one"])
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("Saved one")
      env.press("Delete template")
      assert.is_truthy(env.ns.db.global.templates["Saved one"])
      env.press("Confirm: delete")
      assert.is_nil(env.ns.db.global.templates["Saved one"])
    end)

    it("shows the reports as tables and switches their scope", function()
      open_raid("Member", true)
      FakeKit.find(env.page(), "TabStrip").opts.onSelect("reports")
      assert.is_truthy(env.text():find("Attendance", 1, true))
      FakeKit.find(env.page(), "Segmented").opts.onChange("all")
      assert.is_truthy(env.text():find("Loot", 1, true))
    end)

    it("opens the export and import windows from the overflow menu, import only for who may manage events", function()
      open_raid("RL")
      local shown = {}
      env.ns.UI.ShowTransfer = function(mode)
        shown[#shown + 1] = mode
      end
      FakeKit.find_all(env.page(), "IconButton")[1].opts.onClick()
      local menu = env.ns.Kit.fake.menu
      assert.are.same({ "export", "import" }, { menu.items[1].value, menu.items[2].value })
      menu.onSelect("import")
      assert.are.same({ "import" }, shown)
      pcall(env.close)
      open_raid("Member", true)
      FakeKit.find_all(env.page(), "IconButton")[1].opts.onClick()
      assert.are.equal(1, #env.ns.Kit.fake.menu.items)
    end)
  end)
end)

describe("Window smoke test: Events", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("lists the upcoming events of the roster, soonest first, with the roster or Guild, and no past ones", function()
    env = build("Roster")
    local events = env.ns.db.global.events
    events.late = event("late", "Late raid", { startAt = 9000 })
    events.soon = event("soon", "Soon raid", { startAt = 5000 })
    events.guild = event("guild", "Guild night", { startAt = 7000, rosterId = false })
    events.guild.rosterId = nil
    events.past = event("past", "Old raid", { startAt = 10, status = "closed" })
    events.other = event("other", "Other roster", { startAt = 6000, rosterId = "r9" })
    env.open("events")
    local rows = env.tableRows()
    assert.are.equal(3, #rows)
    assert.are.same(
      { "Soon raid", "Guild night", "Late raid" },
      { rows[1].cells.title, rows[2].cells.title, rows[3].cells.title }
    )
    assert.are.same({ "Main", "Guild", "Main" }, {
      rows[1].cells.roster.text,
      rows[2].cells.roster.text,
      rows[3].cells.roster.text,
    })
    assert.are.equal(env.ns.ViewModel.DateText(5000), rows[1].cells.date.text)
    assert.is_nil(env.text():find("Old raid", 1, true))
    assert.is_nil(env.text():find("Other roster", 1, true))
  end)

  it("is read-only apart from the sign-up: no free buttons or fields, no links into the Admin Raid tab", function()
    env = build("RL")
    env.ns.db.global.events.e1 = event("e1", "Molten Core")
    local page = env.open("events")
    assert.is_nil(FakeKit.find(page, "Button"))
    assert.is_nil(FakeKit.find(page, "EditBox"))
    assert.are.equal("Raid", env.find(page, "PageHeader").opts.title)
  end)

  it("shows the sign-up count and lets a roster player answer Going or Not going", function()
    for _, rank in ipairs({ "Roster", "RL", "Officer", "GM" }) do
      env = build(rank)
      env.ns.db.global.events.e1 = event("e1", "Molten Core", {
        signups = {
          ["Ann-Realm"] = { status = "yes", rev = 1, updatedAt = 1 },
          ["Boss-Realm"] = { status = "no", rev = 1, updatedAt = 1 },
          ["Yonemon Gg"] = { status = "yes", rev = 1, updatedAt = 1 },
        },
      })
      env.open("events")
      local cells = env.tableRows()[1].cells
      assert.are.equal("2 going", cells.going.text, rank)
      assert.is_false(cells.yes.opts.disabled, rank)
      assert.are.equal("secondary", cells.yes.opts.variant)

      cells.yes.opts.onClick()
      local stored = env.ns.db.global.events.e1.signups["Leader-Realm"]
      assert.are.equal("yes", stored.status, rank)
      assert.are.same({ "SendSignup" }, env.sent, rank)
      cells = env.tableRows()[1].cells
      assert.are.equal("3 going", cells.going.text)
      assert.are.equal("primary", cells.yes.opts.variant)
      assert.are.equal("secondary", cells.no.opts.variant)

      cells.no.opts.onClick()
      assert.are.equal("no", env.ns.db.global.events.e1.signups["Leader-Realm"].status)
      assert.are.equal("2 going", env.tableRows()[1].cells.going.text)
      pcall(env.close)
    end
  end)

  it("disables the answer at the start time and sends nothing", function()
    env = build("Roster")
    env.ns.db.global.events.now = event("now", "Starting now", { startAt = 1000 })
    env.ns.db.global.events.soon = event("soon", "Soon raid", { startAt = 5000 })
    env.open("events")
    local rows = env.tableRows()
    assert.are.equal("Starting now", rows[1].cells.title)
    assert.is_true(rows[1].cells.yes.opts.disabled)
    assert.is_true(rows[1].cells.no.opts.disabled)
    assert.is_false(rows[2].cells.yes.opts.disabled)
    rows[1].cells.yes.opts.onClick()
    assert.is_truthy(env.banner().opts.text:find("Sign-up is closed", 1, true))
    assert.is_nil(next(env.ns.db.global.events.now.signups or {}))
  end)

  it("says there are no upcoming events", function()
    env = build("Roster")
    env.open("events")
    assert.is_truthy(FakeKit.find(env.page(), "Table").opts.emptyText:find("No upcoming events", 1, true))
    pcall(env.close)
    env = build("GM", "esES")
    env.open("events")
    assert.are.equal("No hay eventos próximos", FakeKit.find(env.page(), "Table").opts.emptyText)
  end)

  it("shows the guild master every roster's events", function()
    env = build("GM")
    env.ns.db.global.events.a = event("a", "A", { startAt = 5000 })
    env.ns.db.global.events.b = event("b", "B", { startAt = 6000, rosterId = "r2" })
    env.open("events")
    assert.are.equal(2, #env.tableRows())
  end)

  it("draws for a player with no roster, who sees nothing, and for the ranks that cannot reach it", function()
    for _, rank in ipairs({ "Norost", "Member", "Alter" }) do
      env = build(rank)
      env.forceTabs = true
      env.ns.db.global.events.e1 = event("e1", "Molten Core")
      env.open("events")
      assert.are.equal(rank == "Norost" and 0 or 1, #env.tableRows(), rank)
      pcall(env.close)
    end
  end)
end)

describe("Window smoke test: roster selector of the Admin Raid tab", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("shows the guild master a dropdown and keeps the pick in UI.nav across tabs", function()
    env = build("GM")
    env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
    env.ns.db.global.events.e1 = event("e1", "Main raid")
    env.ns.db.global.events.e2 = event("e2", "Alts raid", { startAt = 6000, rosterId = "r2" })
    env.open("raid")
    local dropdown = FakeKit.find_all(env.page(), "Dropdown")[1]
    assert.are.equal("r2", dropdown.opts.value)
    assert.are.same({ "r2", "r1" }, { dropdown.opts.items[1].value, dropdown.opts.items[2].value })
    assert.is_truthy(env.text():find("Alts raid", 1, true))
    assert.is_nil(env.text():find("Main raid", 1, true))
    dropdown.opts.onChange("r1")
    assert.is_truthy(env.text():find("Main raid", 1, true))
    assert.are.equal("r1", env.ns.UI.nav.rosters.raid)
    env.open("home")
    env.open("raid")
    assert.are.equal("r1", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
  end)

  it("fixes a raid leader or an officer to the own roster, shown as a label", function()
    for _, rank in ipairs({ "RL", "Council" }) do
      env = build(rank)
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.db.global.events.e1 = event("e1", "Main raid")
      env.ns.db.global.events.e2 = event("e2", "Alts raid", { startAt = 6000, rosterId = "r2" })
      env.open("raid")
      assert.is_nil(FakeKit.find_all(env.page(), "Dropdown")[1], rank)
      assert.is_truthy(env.find(env.page(), "Label", "Roster: Main"), rank)
      assert.is_truthy(env.text():find("Main raid", 1, true), rank)
      assert.is_nil(env.text():find("Alts raid", 1, true), rank)
      pcall(env.close)
    end
  end)

  it("keeps the events no roster owns in sight of the guild master", function()
    env = build("GM")
    env.ns.db.global.events.e1 = event("e1", "Old raid")
    env.ns.db.global.events.e1.rosterId = nil
    env.open("raid")
    assert.is_truthy(env.text():find("Old raid", 1, true))
  end)
end)

describe("Window smoke test: Loot", function()
  local env
  local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"

  local function open_loot(rank, withSession)
    env = build(rank)
    local e = event("e1", "Molten Core", { status = "open" })
    if withSession then
      e.loot = {
        s1 = {
          sessionId = "s1",
          itemId = 5,
          itemName = "Sword",
          status = "open",
          rev = 1,
          updatedAt = 3,
          candidates = { ["Ann-Realm"] = { need = "main", spec = "Tank", rev = 1, updatedAt = 1 } },
          votes = {},
        },
      }
    end
    env.ns.db.global.events["e1"] = e
    env.ns.character.profile.fields = { role = { value = "Tank" } }
    return env.open("loot")
  end

  after_each(function()
    pcall(env.close)
  end)

  it("previews the pasted item and opens the session", function()
    open_loot("Council")
    local field
    for _, f in ipairs(FakeKit.find_all(env.page(), "Field")) do
      if f.opts.label and f.opts.label:find("Item link", 1, true) then
        field = f
      end
    end
    local input = FakeKit.find_all(field, "EditBox")[1]
    input.opts.onChange("hello")
    assert.is_true(FakeKit.find(env.page(), "Button", "Open").opts.disabled)
    input.opts.onChange(LINK)
    local open = FakeKit.find(env.page(), "Button", "Open")
    assert.is_falsy(open.opts.disabled)
    assert.is_truthy(FakeKit.find(env.page(), "ItemLabel", "Thunderfury"))
    FakeKit.press(open)
    local sessions = env.ns.LootService.Sessions(env.ns.db.global.events.e1)
    assert.are.equal("Thunderfury", sessions[1].itemName)
    assert.are.equal("SendLootSession", env.sent[1])
  end)

  it("renders Loot read-only for a roster player: no council controls and no apply row", function()
    local loot = open_loot("Roster", true)
    assert.is_nil(env.find(loot, "Button", "Open the voting window"))
    assert.is_nil(env.find(loot, "Card", "Open a session"))
    assert.is_nil(env.find(loot, "Button", "Open"))
    for _, label in ipairs({ "Main spec", "Off spec", "Other", "Pass", "Vote", "Award" }) do
      assert.is_nil(env.find(loot, "Button", label), label)
    end
    assert.is_nil(env.text():find("Spec: Tank (from your profile)", 1, true))
    assert.is_truthy(env.text():find("Sword", 1, true))
    assert.is_truthy(env.find(loot, "Label", "Roster: Main"))
    for _, row in ipairs(env.tableRows()) do
      assert.is_nil(row.cells.vote)
      assert.is_nil(row.cells.award)
    end
    assert.are.same({}, env.sent)
  end)

  it("lets an officer and a raid leader manage the loot of the own roster only", function()
    for _, rank in ipairs({ "Council", "RL" }) do
      open_loot(rank, true)
      env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
      env.ns.db.global.events.e2 = event("e2", "Alts raid", { startAt = 6000, rosterId = "r2" })
      env.ns.UI.Redraw()
      assert.is_nil(FakeKit.find_all(env.page(), "Dropdown")[2], rank)
      assert.is_truthy(env.find(env.page(), "Label", "Roster: Main"), rank)
      assert.is_truthy(env.find(env.page(), "Card", "Open a session"), rank)
      assert.is_truthy(env.find(env.page(), "Button", "Open the voting window"), rank)
      assert.is_truthy(env.tableRows()[1].cells.vote, rank)
      assert.is_truthy(env.tableRows()[1].cells.award, rank)
      local events = FakeKit.find_all(env.page(), "Dropdown")[1]
      assert.are.equal(1, #events.opts.items, rank)
      assert.are.equal("e1", events.opts.value, rank)
      pcall(env.close)
    end
  end)

  it("votes and awards with a reason asked under the row, and closes with a second click", function()
    open_loot("Council", true)
    local row = env.tableRows()[1]
    assert.is_truthy(row.cells.vote)
    row.cells.vote.opts.onClick()
    assert.are.equal("Ann-Realm", env.ns.db.global.events.e1.loot.s1.votes["Leader-Realm"].target)
    assert.are.equal("SendLootVote", env.sent[#env.sent])

    env.tableRows()[1].cells.award.opts.onClick()
    local reason = env.box("Reason for the award for Ann-Realm")
    reason.opts.onChange("best in slot")
    env.press("Confirm award")
    local session = env.ns.db.global.events.e1.loot.s1
    assert.are.same(
      { "closed", "Ann-Realm", "best in slot" },
      { session.status, session.award.characterKey, session.award.reason }
    )
    assert.are.equal("SendLootAward", env.sent[#env.sent])
  end)

  it("cancels an award and closes a session without awarding only after a second click", function()
    open_loot("RL", true)
    env.tableRows()[1].cells.award.opts.onClick()
    env.press("Cancel")
    assert.is_nil(env.find(env.page(), "EditBox", "x"))
    env.press("Close without awarding")
    assert.are.equal("open", env.ns.db.global.events.e1.loot.s1.status)
    env.press("Confirm: close without awarding")
    assert.are.equal("closed", env.ns.db.global.events.e1.loot.s1.status)
  end)

  it("collapses a closed session to one line and shows the minutes on demand", function()
    open_loot("Council", true)
    local session = env.ns.db.global.events.e1.loot.s1
    session.status = "closed"
    session.award = { characterKey = "Ann-Realm", reason = "need", awardedBy = "Boss", at = 5 }
    env.ns.UI.Redraw()
    assert.is_truthy(env.text():find("Sword", 1, true))
    assert.is_nil(FakeKit.find(env.page(), "Table"))
    env.press("Show")
    assert.are.equal(1, #env.tableRows())
    env.press("Hide")
    assert.is_nil(FakeKit.find(env.page(), "Table"))
  end)

  it("opens the voting window for a voter, and selects another event", function()
    open_loot("Council", true)
    env.ns.db.global.events.e2 = event("e2", "Older", { startAt = 10 })
    env.press("Open the voting window")
    assert.is_true(env.votingShown)
    FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("e2")
    assert.is_truthy(env.text():find("No loot sessions for this event yet.", 1, true))
  end)

  it("starts on an event chosen elsewhere, and says there are no events", function()
    env = build("Roster")
    env.ns.db.global.events.e1 = event("e1", "One")
    env.ns.db.global.events.e2 = event("e2", "Two", { startAt = 10 })
    env.open("loot", { eventId = "e2" })
    assert.are.equal("e2", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
    pcall(env.close)
    env = build("Roster")
    env.open("loot")
    assert.is_truthy(env.text():find("No events yet", 1, true))
  end)

  it("lets the guild master pick any roster and manage its loot", function()
    env = build("GM")
    env.ns.db.global.rosters.r2 = { id = "r2", name = "Alts", rev = 1 }
    env.ns.db.global.events.e1 = event("e1", "Main raid")
    env.ns.db.global.events.e2 = event("e2", "Alts raid", { startAt = 6000, rosterId = "r2" })
    env.open("loot")
    local selector = FakeKit.find_all(env.page(), "Dropdown")[1]
    assert.are.same({ "r2", "r1" }, { selector.opts.items[1].value, selector.opts.items[2].value })
    assert.are.equal("e2", FakeKit.find_all(env.page(), "Dropdown")[2].opts.value)
    assert.are.equal(1, #FakeKit.find_all(env.page(), "Dropdown")[2].opts.items)
    assert.is_truthy(env.find(env.page(), "Card", "Open a session"))
    selector.opts.onChange("r1")
    assert.are.equal("e1", FakeKit.find_all(env.page(), "Dropdown")[2].opts.value)
    assert.are.equal(1, #FakeKit.find_all(env.page(), "Dropdown")[2].opts.items)
    assert.is_truthy(env.find(env.page(), "Card", "Open a session"))
    assert.are.equal("r1", env.ns.UI.nav.rosters.loot)
    pcall(env.close)
    env = build("GM")
    env.ns.db.global.events.e1 = event("e1", "One")
    env.open("loot")
    assert.are.equal("e1", FakeKit.find_all(env.page(), "Dropdown")[2].opts.value)
    pcall(env.close)
    env = build("Norost")
    -- Without a roster Loot is not reachable: the gate sends the player home.
    env.open("loot")
    assert.are.equal("home", env.ns.UI.CurrentTab())
    pcall(env.close)
    env = build("Norost")
    env.forceTabs = true
    env.open("loot")
    assert.is_truthy(env.text():find("You are not in a roster yet", 1, true))
  end)

  it("shows the strip of the last boss loot, each with its own Open", function()
    env = build("Council")
    env.ns.db.global.events.e1 = event("e1", "One", { status = "open" })
    env.ns.Platform.LootWindowAvailable = function()
      return true
    end
    env.ns.bossLoot = { { link = LINK, icon = "i" } }
    env.open("loot")
    assert.is_truthy(env.text():find("Last boss loot", 1, true))
    local buttons = FakeKit.find_all(env.page(), "Button")
    local open
    for _, button in ipairs(buttons) do
      if button.opts.text == "Open" and not button.opts.disabled and not button.opts.variant then
        open = button
      end
    end
    FakeKit.press(open)
    assert.are.equal("SendLootSession", env.sent[#env.sent])
  end)
end)

describe("Window smoke test: PvP", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("shows my stats in two grids, and the sub-tabs", function()
    env = build("Member")
    local pvp = env.open("pvp")
    local values = {}
    for _, tab in ipairs(FakeKit.find(pvp, "TabStrip").opts.tabs) do
      values[#values + 1] = tab.value
    end
    assert.are.same({ "season", "missions", "stats", "feed", "history", "intel" }, values)
    FakeKit.find(pvp, "TabStrip").opts.onSelect("stats")
    local grids = FakeKit.find_all(env.page(), "StatGrid")
    assert.are.equal(2, #grids)
    assert.are.equal("Open world", grids[1].opts.stats[1].caption)
  end)

  it("says 'Not available' when the client cannot give the figures", function()
    env = build("Member")
    env.ns.pvpTracker.honorAvailable = false
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    assert.is_truthy(env.text():find("Not available", 1, true))
  end)

  it("draws the ranking, sorts by a column and flips on the second click, and searches", function()
    env = build("Member")
    env.ns.db.global.pvpStats = {
      ["Ann-Realm"] = { honor = { world = 30, bg = 20 }, blows = { world = 5, bg = 1 }, updatedAt = 900, rev = 1 },
      ["Gone-Realm"] = { honor = { world = 99, bg = 99 }, updatedAt = 900, rev = 1 },
    }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    FakeKit.find(env.page(), "Segmented").opts.onChange("ranking")
    local rows = env.tableRows()
    assert.are.equal(2, #rows)
    assert.are.same({ "1", "gold" }, { rows[1].cells.position.text, rows[1].cells.position.color })
    assert.is_true(rows[2].highlight)
    assert.is_nil(env.text():find("Gone-Realm", 1, true))
    local tbl = FakeKit.find_all(env.page(), "Table")[1]
    tbl.opts.onSort("name")
    assert.is_false(FakeKit.find_all(env.page(), "Table")[1].opts.sort.descending)
    FakeKit.find_all(env.page(), "Table")[1].opts.onSort("name")
    assert.is_true(FakeKit.find_all(env.page(), "Table")[1].opts.sort.descending)
    env.box("Search by name").opts.onChange("ann", true)
    assert.are.equal(1, #env.tableRows())
    FakeKit.find_all(env.page(), "Segmented")[2].opts.onChange("today")
    assert.is_truthy(env.text():find("Today's kills", 1, true))
  end)

  it("offers the kill-counter reset to the guild master only, in Admin -> Season, with a second click", function()
    env = build("RL")
    env.ns.db.global.pvpStats = { ["Ann-Realm"] = { honor = { world = 3, bg = 0 }, updatedAt = 900, rev = 1 } }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    FakeKit.find(env.page(), "Segmented").opts.onChange("ranking")
    assert.is_nil(env.find(env.page(), "Button", "Reset PvP counters"))
    pcall(env.close)
    env = build("GM")
    env.ns.db.global.pvpStats = { ["Ann-Realm"] = { honor = { world = 3, bg = 0 }, updatedAt = 900, rev = 1 } }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    FakeKit.find(env.page(), "Segmented").opts.onChange("ranking")
    assert.is_nil(env.find(env.page(), "Button", "Reset PvP counters"))
    env.open("pvpadmin")
    FakeKit.find(env.page(), "Segmented").opts.onChange("season")
    assert.is_truthy(env.text():find("Kill counters", 1, true))
    env.press("Reset PvP counters")
    assert.is_truthy(env.banner().opts.text:find("Pick a member first", 1, true))
    local dropdown
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.placeholder == "Member" then
        dropdown = d
      end
    end
    dropdown.opts.onChange("Ann-Realm")
    env.press("Reset PvP counters")
    assert.are.same({}, env.sent)
    env.press("Confirm: reset")
    assert.are.same({ "ResetPvP:Ann-Realm" }, env.sent)
    assert.is_truthy(env.banner().opts.text:find("PvP counters of Ann-Realm reset", 1, true))
  end)

  it("lets the ranking table size its columns to their text, so no header or figure is cut", function()
    env = build("GM")
    env.ns.db.global.pvpStats = {
      ["Ann-Realm"] = { honor = { world = 30, bg = 20 }, blows = { world = 5, bg = 1 }, updatedAt = 900, rev = 1 },
    }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    FakeKit.find(env.page(), "Segmented").opts.onChange("ranking")
    local tbl = FakeKit.find_all(env.page(), "Table")[1]
    assert.is_true(tbl.opts.fit)
    local fitted = {}
    for _, column in ipairs(tbl.opts.columns) do
      fitted[column.key] = column.fit == true
    end
    -- The name takes what is left; every figure and the short texts are measured.
    assert.is_false(fitted.name)
    for _, key in ipairs({ "position", "rank", "world", "bg", "total", "blows", "updated" }) do
      assert.is_true(fitted[key], key)
    end
    -- The footer notes wrap.
    for _, label in ipairs(FakeKit.find_all(env.page(), "Label")) do
      if label.opts.style == "small" then
        assert.is_true(label.opts.wrap, label.opts.text)
      end
    end
    -- The reset button (Admin -> Season) follows its (longer, in Spanish) text instead of a fixed width.
    env.open("pvpadmin")
    FakeKit.find(env.page(), "Segmented").opts.onChange("season")
    assert.are.equal("auto", env.find(env.page(), "Button", "Reset PvP counters").opts.layout.width)
  end)

  it("shows a kill that is too long for its row whole in a tooltip", function()
    env = build("Member")
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("feed")
    for _, row in ipairs(FakeKit.find(env.page(), "List").opts.rows) do
      assert.is_true(row.tooltipWhenCut)
    end
  end)

  it("lists the recent kills with a killing blow badge, and says when there are none or the feed is off", function()
    env = build("Member")
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("feed")
    local list = FakeKit.find(env.page(), "List")
    assert.are.equal("Killing blow", list.opts.rows[1].badge.text)
    env.ns.pvpFeed.Entries = function()
      return {}
    end
    env.ns.UI.Redraw()
    assert.is_truthy(env.text():find("No kills yet", 1, true))
    env.ns.pvpFeed.Available = function()
      return false
    end
    env.ns.UI.Redraw()
    assert.is_truthy(FakeKit.find(env.page(), "Banner"))
  end)

  it("redraws when a record arrives, but not more than once per interval, and only on its own tab", function()
    env = build("Member")
    env.open("pvp")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.PvPChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    count = #env.ns.Kit.fake.nodes
    env.timers = {}
    env.ns.UI.PvPChanged()
    env.ns.UI.PvPChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
    assert.are.equal(1, #env.timers)
    env.ns.UI.SelectTab("home")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.PvPChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)
end)

describe("Window smoke test: PvP seasons", function()
  local env
  local DAY = 86400

  after_each(function()
    pcall(env.close)
  end)

  -- An active season (500 to 30 days later) with missions, prizes, twelve ranked players and two claims waiting.
  local function seed(e)
    local ns, svc = e.ns, e.ns.pvpSeason
    e.asRole = "gm"
    local season = assert(svc:CreateSeason({ name = "Autumn", startsAt = 500, endsAt = 500 + 30 * DAY }))
    local goal = { kind = "kills", count = 10, zones = { 1454 }, place = "any", distinct = "none" }
    assert(
      svc:UpsertMission({ id = "m1", title = "Raid", desc = "Kill ten", points = 50, goal = goal, repeatKind = "once" })
    )
    assert(
      svc:UpsertMission({ id = "m2", title = "Hug", points = 20, goal = { kind = "manual" }, repeatKind = "once" })
    )
    assert(
      svc:UpsertMission({ id = "m3", title = "Hidden", points = 5, goal = goal, repeatKind = "once", active = false })
    )
    assert(svc:SetPrizes(season.id, { ["1"] = { { kind = "gold", amount = 500 } } }))
    e.asRole = nil
    local ledger = ns.db.global.pvpSeason
    ledger.grants[season.id] = {}
    for index = 1, 12 do
      local who = index == 5 and "Leader-Realm" or ("P" .. index .. "-Realm")
      local id = "g" .. index
      ledger.grants[season.id][id] = {
        id = id,
        seasonId = season.id,
        player = who,
        missionId = "m1",
        points = 1000 - index,
        at = 900 + index,
        by = "Boss-Realm",
      }
    end
    for _, who in ipairs({ "Ann-Realm", "Yonemon Gg" }) do
      local periodKey = ns.PvPSeasonModel.PeriodKey("once", 950)
      local id = ns.PvPSeasonModel.ClaimId(who, "m1", periodKey, 1)
      ledger.queue[id] = {
        id = id,
        missionId = "m1",
        seasonId = season.id,
        periodKey = periodKey,
        player = who,
        at = 950,
        summary = { done = 10, total = 10 },
        evidence = { { at = 900, victim = "Zed", mapId = 1454, place = "world" } },
      }
    end
    return season
  end

  -- A PvP officer flag that was stored before the ranks existed: it gives nothing now.
  local function officer(e)
    e.ns.db.global.pvpSeason.officers["Leader-Realm"] =
      { player = "Leader-Realm", intervals = { { from = 0 } }, rev = 1, updatedAt = 1 }
  end

  -- Every node of `kind` with that text.
  local function named(root, kind, text)
    return FakeKit.find_all(root, kind, function(node)
      return node.opts.text == text
    end)
  end

  local function strip(e)
    return FakeKit.find(e.page(), "TabStrip")
  end

  local function go(e, sub, section)
    if sub == "admin" then
      e.open("pvpadmin")
    else
      e.open("pvp")
      strip(e).opts.onSelect(sub)
    end
    if section then
      FakeKit.find(e.page(), "Segmented").opts.onChange(section)
    end
  end

  local function tracker(e)
    local t = { claims = {}, states = {}, progress = {}, availability = nil }
    function t:Progress(id)
      return self.progress[id]
    end
    function t:Claim(id, note)
      self.claims[#self.claims + 1] = { id, note }
      return { id = "c" }, true
    end
    function t:ClaimState(id)
      return self.states[id] or "none"
    end
    function t:Availability()
      return self.availability
    end
    e.ns.pvpMissions = t
    return t
  end

  it("draws every sub-tab for every player and every admin section as gm and cogm", function()
    for _, who in ipairs({ "GM", "CoGM", "Member", "Norost" }) do
      env = build(who)
      seed(env)
      env.open("pvp")
      local subs = {}
      for _, tab in ipairs(strip(env).opts.tabs) do
        subs[#subs + 1] = tab.value
        strip(env).opts.onSelect(tab.value)
      end
      assert.are.equal(6, #subs, who)
      env.open("pvpadmin")
      if who == "GM" or who == "CoGM" then
        assert.are.equal("pvpadmin", env.ns.UI.CurrentTab(), who)
        for _, section in ipairs(FakeKit.find(env.page(), "Segmented").opts.items) do
          FakeKit.find(env.page(), "Segmented").opts.onChange(section.value)
        end
      else
        assert.are.equal("home", env.ns.UI.CurrentTab(), who)
      end
      pcall(env.close)
    end
  end)

  it("draws every sub-tab with no season service at all", function()
    env = build("Member")
    env.ns.pvpSeason = nil
    env.open("pvp")
    for _, tab in ipairs(strip(env).opts.tabs) do
      strip(env).opts.onSelect(tab.value)
    end
    strip(env).opts.onSelect("season")
    assert.is_truthy(env.text():find("No season is running", 1, true))
  end)

  it("gives a member with a stored PvP officer flag no Admin sub-tab", function()
    env = build("Member")
    seed(env)
    officer(env)
    env.open("pvp")
    for _, tab in ipairs(strip(env).opts.tabs) do
      assert.are_not.equal("admin", tab.value)
    end
  end)

  it("shows the season card, the prizes and the standings with the own row and a line under the tenth", function()
    env = build("Member")
    seed(env)
    env.open("pvp")
    local text = env.text()
    assert.is_truthy(text:find("Autumn", 1, true))
    assert.is_truthy(text:find("500 gold", 1, true))
    local rows = env.tableRows()
    assert.are.equal(13, #rows)
    assert.is_true(rows[5].highlight)
    assert.is_truthy(rows[11].cells.name.text:find("No prizes below this line", 1, true))
    assert.are.equal("1st", rows[1].cells.tier.opts.text)
    assert.are.equal("-", rows[12].cells.tier)
  end)

  it("says there is no season, and that one ended", function()
    env = build("Member")
    env.open("pvp")
    assert.is_truthy(env.text():find("No season is running", 1, true))
    strip(env).opts.onSelect("missions")
    assert.is_truthy(env.text():find("No season is running", 1, true))
    seed(env)
    env.ns.Platform.ServerTime = function()
      return 500 + 31 * DAY
    end
    strip(env).opts.onSelect("missions")
    assert.is_truthy(env.banner().opts.text:find("has ended", 1, true))
  end)

  it("shows the missions without progress and with no claim when the tracker is missing", function()
    env = build("Member")
    seed(env)
    go(env, "missions")
    local text = env.text()
    assert.is_truthy(text:find("Raid", 1, true))
    assert.is_truthy(text:find("Not available on this client", 1, true))
    assert.is_nil(text:find("Hidden", 1, true))
    assert.is_nil(env.find(env.page(), "Button", "Claim"))
  end)

  it("claims a complete mission, and a manual one with a note", function()
    env = build("Member")
    seed(env)
    local t = tracker(env)
    t.progress.m1 = {
      bars = { { label = "Kills", done = 10, total = 10 } },
      unknown = 2,
      complete = true,
      claimable = true,
    }
    t.progress.m2 = { bars = {}, unknown = 0, complete = true, claimable = true }
    go(env, "missions")
    assert.is_truthy(env.text():find("without a known class", 1, true))
    env.press("Claim")
    assert.are.same({ { "m1" } }, t.claims)
    assert.is_truthy(env.banner().opts.text:find("Claim sent", 1, true))
    -- The manual mission has no plain Claim button: it asks for a note first.
    local notes = named(env.page(), "Button", "Claim with note")
    assert.are.equal(2, #notes)
    FakeKit.press(notes[1])
    env.press("Send claim")
    assert.is_truthy(env.banner().opts.text:find("Write a note", 1, true))
    env.box("Note for the approver (required)").opts.onChange("proof")
    env.press("Send claim")
    assert.are.same({ "m2", "proof" }, t.claims[2])
  end)

  it("shows a refused claim, the state chip and the availability of a criterion", function()
    env = build("Member")
    seed(env)
    local t = tracker(env)
    t.progress.m1 = { bars = {}, unknown = 0, complete = true, claimable = true }
    t.Claim = function()
      return nil, "limit"
    end
    go(env, "missions")
    env.press("Claim")
    assert.is_truthy(env.banner().opts.text:find("the limit was reached", 1, true))
    t.states.m1 = "pending"
    env.ns.UI.Redraw()
    assert.is_truthy(env.text():find("Pending approval", 1, true))
    assert.is_nil(env.find(env.page(), "Button", "Claim"))
    t.availability = { kills = true, zones = false, classRace = true, bgWins = true }
    env.ns.UI.Redraw()
    assert.is_truthy(env.text():find("Not available on this client", 1, true))
  end)

  it("redraws on a season change and on a PvP officer change in Members", function()
    env = build("GM")
    env.open("pvp")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.PvPSeasonChanged("PVP_GRANT")
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    env.open("roster")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.PvPSeasonChanged("PVP_OFFICER")
    assert.is_true(#env.ns.Kit.fake.nodes > count)
  end)

  it("approves and rejects claims, with the evidence shown on demand", function()
    env = build("GM")
    local season = seed(env)
    go(env, "admin")
    assert.is_truthy(FakeKit.find(env.page(), "Segmented").opts.items[1].text:find("Approvals (2)", 1, true))
    env.press("View evidence")
    assert.is_truthy(env.text():find("Zed", 1, true))
    env.press("Hide evidence")
    local approve = named(env.page(), "Button", "Approve")[1]
    FakeKit.press(approve)
    local held = 0
    for _ in pairs(env.ns.db.global.pvpSeason.grants[season.id]) do
      held = held + 1
    end
    assert.are.equal(13, held)
    assert.is_truthy(env.banner().opts.text:find("Claim approved", 1, true))
    env.press("Reject")
    assert.is_truthy(env.banner().opts.text:find("Claim rejected", 1, true))
    assert.is_truthy(env.text():find("Rejected claims", 1, true))
    env.press("Approve")
    assert.is_truthy(env.banner().opts.text:find("Claim approved", 1, true))
  end)

  it("says so when nothing waits", function()
    env = build("GM")
    go(env, "admin")
    assert.is_truthy(env.text():find("No claims waiting", 1, true))
  end)

  -- The chip text of a listed zone, as the form writes it.
  local function zoneText(e, mapId)
    for _, region in ipairs(e.ns.Constants.PVP_MISSION_REGIONS) do
      for _, zone in ipairs(region.zones) do
        if zone.mapId == mapId then
          return e.ns.L(zone.nameKey)
        end
      end
    end
    return tostring(mapId)
  end

  -- The zone picker of the mission form: the dropdown that adds a zone, whole world included.
  local function zonePicker(e)
    return FakeKit.find_all(e.page(), "Dropdown", function(node)
      return node.opts.placeholder == e.ns.L("Add a zone")
    end)[1]
  end

  it("picks zones from the dropdown: whole world clears them, a sixth zone is refused", function()
    env = build("GM")
    seed(env)
    go(env, "admin", "missions")
    env.press("New mission")
    assert.is_truthy(env.text():find("Whole world", 1, true))
    zonePicker(env).opts.onChange(1454)
    zonePicker(env).opts.onChange(1414)
    assert.is_true(FakeKit.find(env.page(), "Chip", "Orgrimmar").opts.active)
    assert.is_true(FakeKit.find(env.page(), "Chip", "Kalimdor").opts.active)
    -- Picking a zone already chosen adds nothing.
    zonePicker(env).opts.onChange(1454)
    local orgrimmar = FakeKit.find_all(env.page(), "Chip", function(node)
      return node.opts.text == "Orgrimmar"
    end)
    assert.are.equal(1, #orgrimmar)
    for _, mapId in ipairs({ 1411, 1412, 1413 }) do
      zonePicker(env).opts.onChange(mapId)
    end
    zonePicker(env).opts.onChange(1438)
    assert.is_truthy(env.banner().opts.text:find("At most 5 zones.", 1, true))
    assert.is_nil(FakeKit.find(env.page(), "Chip", "Teldrassil"))
    zonePicker(env).opts.onChange("world")
    assert.is_nil(FakeKit.find(env.page(), "Chip", "Orgrimmar"))
    assert.is_truthy(env.text():find("Whole world", 1, true))
  end)

  it("creates, edits and pauses missions from the form", function()
    env = build("GM")
    local season = seed(env)
    go(env, "admin", "missions")
    env.press("New mission")
    local function edit(maxLetters, text)
      for _, box in ipairs(FakeKit.find_all(env.page(), "EditBox")) do
        if box.opts.maxLetters == maxLetters then
          box.opts.onChange(text)
          return
        end
      end
      error("no box " .. tostring(maxLetters))
    end
    edit(env.ns.Constants.PVP_MISSION_TITLE_MAX, "Duel")
    edit(4, "x")
    env.press("Create mission")
    assert.is_truthy(env.banner().opts.text:find("'points' is not valid", 1, true))
    edit(4, "30")
    edit(3, "7")
    -- The zones are chosen from the picker's dropdown.
    for _, mapId in ipairs({ 1454, 1453 }) do
      zonePicker(env).opts.onChange(mapId)
    end
    env.press("Create mission")
    assert.is_truthy(env.banner().opts.text:find("Mission saved", 1, true))
    local found
    for _, mission in pairs(env.ns.db.global.pvpSeason.missions) do
      if mission.title == "Duel" then
        found = mission
      end
    end
    assert.are.same({ 7, { 1454, 1453 } }, { found.goal.count, found.goal.zones })
    -- Edit it: the form starts from its values, and the status dropdown pauses it.
    local edits = FakeKit.find_all(env.page(), "Table")[1].opts.rows
    assert.are.equal(4, #edits)
    for _, row in ipairs(edits) do
      if row.cells.title == "Duel" then
        row.cells.edit.opts.onClick()
      end
    end
    assert.is_truthy(env.find(env.page(), "Button", "Save mission"))
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.value == true then
        d.opts.onChange(false)
      end
    end
    env.press("Save mission")
    assert.is_false(env.ns.db.global.pvpSeason.missions[found.id].active)
    assert.are.equal(season.id, env.ns.db.global.pvpSeason.missions[found.id].seasonId)
  end)

  it("keeps the advanced options of the mission form closed until asked, and saves what they set", function()
    env = build("GM")
    seed(env)
    go(env, "admin", "missions")
    env.press("New mission")
    assert.is_nil(env.find(env.page(), "Switch", "Claim automatically"))
    -- the live line says what the mission counts, with or without the advanced options
    assert.is_truthy(env.text():find("Counts honourable kills, 10 times, 10 points, once.", 1, true))
    env.press("Advanced options")
    assert.is_truthy(env.find(env.page(), "Button", "Hide advanced options"))
    FakeKit.find(env.page(), "Chip", "Mage").opts.onToggle(true)
    FakeKit.find(env.page(), "Chip", "Orc").opts.onToggle(true)
    FakeKit.find(env.page(), "Switch", "Claim automatically").opts.onChange(true)
    assert.is_truthy(env.text():find("Members on an older addon version", 1, true))
    assert.is_truthy(env.text():find("victims of class Mage", 1, true))
    for _, box in ipairs(FakeKit.find_all(env.page(), "EditBox")) do
      if box.opts.maxLetters == env.ns.Constants.PVP_MISSION_TITLE_MAX then
        box.opts.onChange("Mages")
      elseif box.opts.placeholder and box.opts.placeholder:find("Default: 3", 1, true) then
        box.opts.onChange("1")
      end
    end
    env.press("Create mission")
    assert.is_truthy(env.banner().opts.text:find("Mission saved", 1, true))
    local found
    for _, mission in pairs(env.ns.db.global.pvpSeason.missions) do
      if mission.title == "Mages" then
        found = mission
      end
    end
    assert.are.same({ "MAGE" }, found.goal.victimClasses)
    assert.are.same({ "ORC" }, found.goal.victimRaces)
    assert.are.equal(1, found.goal.victimCapPerDay)
    assert.is_true(found.goal.autoClaim)
    -- editing a mission with options opens the section by itself
    for _, row in ipairs(FakeKit.find_all(env.page(), "Table")[1].opts.rows) do
      if row.cells.title == "Mages" then
        row.cells.edit.opts.onClick()
      end
    end
    assert.is_truthy(env.find(env.page(), "Button", "Hide advanced options"))
    assert.is_true(FakeKit.find(env.page(), "Chip", "Mage").opts.active)
  end)

  it("offers the battleground, window and group options for the kinds they apply to", function()
    env = build("GM")
    seed(env)
    go(env, "admin", "missions")
    env.press("New mission")
    env.press("Advanced options")
    local function goalDropdown()
      for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
        if d.opts.items and d.opts.items[1] and d.opts.items[1].value == "kills" then
          return d
        end
      end
    end
    assert.is_nil(env.find(env.page(), "Chip", "Warsong Gulch"))
    goalDropdown().opts.onChange("bg_played")
    FakeKit.find(env.page(), "Chip", "Warsong Gulch").opts.onToggle(true)
    assert.is_nil(env.find(env.page(), "Chip", "Mage"))
    FakeKit.find(env.page(), "Switch", "Only inside a time window").opts.onChange(true)
    local dates = FakeKit.find_all(env.page(), "DateField")
    assert.are.equal(2, #dates)
    dates[1].opts.onChange(1792454400)
    dates[2].opts.onChange(1792454400 + 86400)
    env.ns.UI.Redraw()
    assert.is_truthy(env.text():find("only from", 1, true))
    goalDropdown().opts.onChange("manual")
    assert.is_nil(env.find(env.page(), "Switch", "Claim automatically"))
    assert.is_nil(env.find(env.page(), "Switch", "Only inside a time window"))
  end)

  it("fills a new mission from a template, and offers no template when editing", function()
    env = build("GM")
    seed(env)
    go(env, "admin", "missions")
    env.press("New mission")
    local templates
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.placeholder == "Pick a template" then
        templates = d
      end
    end
    assert.are.equal(6, #templates.opts.items)
    templates.opts.onChange("group_up")
    assert.is_truthy(env.text():find("with at least 3 guildmates in the group", 1, true))
    assert.is_truthy(env.find(env.page(), "Button", "Hide advanced options"))
    env.press("Create mission")
    assert.is_truthy(env.banner().opts.text:find("Mission saved", 1, true))
    for _, row in ipairs(FakeKit.find_all(env.page(), "Table")[1].opts.rows) do
      if row.cells.title == "Group up" then
        row.cells.edit.opts.onClick()
      end
    end
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      assert.are_not.equal("Pick a template", d.opts.placeholder)
    end
  end)

  it("shows the progress the members reported to an approver, closest first, and says when there is none", function()
    env = build("GM")
    local season = seed(env)
    go(env, "admin", "progress")
    assert.is_truthy(env.text():find("No progress reported yet", 1, true))
    env.ns.db.global.pvpSeason.progress = {
      ["Ann-Realm"] = { seasonId = season.id, rows = { { missionId = "m1", count = 3, goal = 10 } }, at = 900 },
      ["Bob-Realm"] = { seasonId = season.id, rows = { { missionId = "m1", count = 10, goal = 10 } }, at = 900 },
    }
    env.ns.UI.Redraw()
    local rows = FakeKit.find_all(env.page(), "Table")[1].opts.rows
    assert.are.equal(2, #rows)
    assert.are.equal("Bob-Realm", rows[1].cells.player)
    assert.are.equal("10 / 10", rows[1].cells.progress)
    assert.are.equal("Ready to claim", rows[1].cells.status.opts.text)
    assert.are.equal("3 / 10", rows[2].cells.progress)
    assert.is_truthy(env.text():find("not checked", 1, true))
  end)

  it("says the rules, since when they count and that a complete mission is ready to claim", function()
    env = build("Member")
    seed(env)
    local t = tracker(env)
    t.progress.m1 = {
      bars = { { label = "Kills", done = 10, total = 10 } },
      unknown = 0,
      complete = true,
      claimable = true,
      evidence = {},
    }
    go(env, "missions")
    local text = env.text()
    assert.is_truthy(text:find("Counts honourable kills in", 1, true))
    assert.is_truthy(text:find("Counts from", 1, true))
    assert.is_truthy(text:find("Ready to claim", 1, true))
  end)

  it("changes the goal of the form, cancels it, and adds the current zone when the platform can read it", function()
    env = build("GM")
    seed(env)
    env.ns.Platform.GetPlayerMapId = function()
      return 1453
    end
    go(env, "admin", "missions")
    env.press("New mission")
    local goal
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.value == "kills" then
        goal = d
      end
    end
    goal.opts.onChange("manual")
    assert.is_nil(env.find(env.page(), "Button", "Add current zone"))
    goal.opts.onChange("kills")
    env.press("Add current zone")
    local stormwind = FakeKit.find(env.page(), "Chip", zoneText(env, 1453))
    assert.is_true(stormwind.opts.active)
    -- A current zone the list does not have shows up as its own chip.
    env.ns.Platform.GetPlayerMapId = function()
      return 9999
    end
    env.press("Add current zone")
    assert.is_true(FakeKit.find(env.page(), "Chip", "9999").opts.active)
    env.press("Cancel")
    assert.is_nil(env.find(env.page(), "Button", "Create mission"))
    env.ns.Platform.GetPlayerMapId = function()
      return nil
    end
    env.press("New mission")
    env.press("Add current zone")
    assert.is_truthy(env.banner().opts.text:find("could not be read", 1, true))
  end)

  it("copies the missions of another season into the active one", function()
    env = build("GM")
    seed(env)
    local ledger = env.ns.db.global.pvpSeason
    ledger.seasons.old =
      { id = "old", name = "Summer", startsAt = 1, endsAt = 2, state = "closed", rev = 1, updatedAt = 1 }
    ledger.missions.o1 = {
      id = "o1",
      seasonId = "old",
      title = "Old one",
      desc = "",
      points = 9,
      goal = { kind = "kills", count = 3, zones = { 1 }, place = "any", distinct = "none" },
      repeatKind = "daily",
      perPlayer = 1,
      active = true,
      rev = 1,
      updatedAt = 1,
    }
    go(env, "admin", "missions")
    local dropdown
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.placeholder == "Copy from another season" then
        dropdown = d
      end
    end
    dropdown.opts.onChange("old")
    assert.is_truthy(env.banner().opts.text:find("Copied 1 mission(s) into 'Autumn'", 1, true))
    local copies = 0
    for _, mission in pairs(ledger.missions) do
      if mission.title == "Old one" then
        copies = copies + 1
      end
    end
    assert.are.equal(2, copies)
  end)

  it("creates a season, edits it and closes it with two clicks and a warning about pending claims", function()
    env = build("GM")
    go(env, "admin", "season")
    for _, box in ipairs(FakeKit.find_all(env.page(), "EditBox")) do
      if box.opts.maxLetters == env.ns.Constants.PVP_SEASON_NAME_MAX then
        box.opts.onChange("Winter")
      end
    end
    local dates = FakeKit.find_all(env.page(), "DateField")
    dates[1].opts.onChange(600)
    dates[2].opts.onChange(600 + 5 * DAY)
    env.press("Create season")
    assert.is_truthy(env.banner().opts.text:find("Season saved", 1, true))
    local season = env.ns.pvpSeason:ActiveSeason()
    assert.are.same({ "Winter", 600 }, { season.name, season.startsAt })
  end)

  it("closes the running season: first click arms with the warning, second freezes the ranking", function()
    env = build("GM")
    local season = seed(env)
    go(env, "admin", "season")
    env.press("Save")
    assert.is_truthy(env.banner().opts.text:find("Season saved", 1, true))
    env.press("Close season")
    assert.is_truthy(env.text():find("2 claim(s) are still pending", 1, true))
    env.press("Confirm: close and freeze the ranking")
    assert.is_truthy(env.banner().opts.text:find("Season closed: 12 player(s) ranked, 2 claim(s) expired", 1, true))
    assert.is_nil(env.ns.pvpSeason:ActiveSeason())
    assert.is_truthy(env.ns.db.global.pvpSeason.finals[season.id])
    -- The closed season is in the history, and its prizes are to be delivered.
    go(env, "history")
    assert.is_truthy(env.text():find("Autumn", 1, true))
    FakeKit.find(env.page(), "Segmented").opts.onChange("total")
    assert.are.equal(12, #env.tableRows())
    FakeKit.find(env.page(), "Segmented").opts.onChange("season")
    env.press("See the full standing")
    assert.are.equal(12, #FakeKit.find_all(env.page(), "Table")[1].opts.rows)
    env.press("Hide the full standing")
  end)

  it("edits the prizes: adds gold and an item, refuses bad input, and removes a reward", function()
    env = build("GM")
    local season = seed(env)
    go(env, "admin", "prizes")
    env.box("Gold amount").opts.onChange("300")
    env.press("Add gold")
    local tiers = env.ns.db.global.pvpSeason.prizes[season.id].tiers
    assert.are.equal(2, #tiers["1"])
    env.box("Gold amount").opts.onChange("x")
    env.press("Add gold")
    assert.is_truthy(env.banner().opts.text:find("'gold' is not valid", 1, true))
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.value == "1" then
        d.opts.onChange("2")
      end
    end
    env.box("Paste an item link").opts.onChange("|Hitem:19019::|h[Thunderfury]|h")
    env.press("Add item")
    tiers = env.ns.db.global.pvpSeason.prizes[season.id].tiers
    assert.are.same({ "Thunderfury", 19019 }, { tiers["2"][1].name, tiers["2"][1].itemId })
    env.box("Paste an item link").opts.onChange("nonsense")
    env.press("Add item")
    assert.is_truthy(env.banner().opts.text:find("'item' is not valid", 1, true))
    local chip = named(env.page(), "Chip", "300 gold")[1]
    FakeKit.press(chip)
    tiers = env.ns.db.global.pvpSeason.prizes[season.id].tiers
    assert.are.equal(1, #tiers["1"])
  end)

  it("lists the deliveries of a closed season and marks one delivered", function()
    env = build("GM")
    local season = seed(env)
    env.ns.pvpSeason:CloseSeason(season.id)
    go(env, "admin", "deliveries")
    assert.is_truthy(env.text():find("0 of 10 delivered", 1, true))
    local rows = env.tableRows()
    assert.are.equal(10, #rows)
    rows[1].cells.status.opts.onClick()
    assert.is_truthy(env.text():find("1 of 10 delivered", 1, true))
    assert.is_truthy(env.tableRows()[1].cells.status.text:find("Delivered", 1, true))
  end)

  it("says there is nothing to deliver before any season closed", function()
    env = build("GM")
    go(env, "admin", "deliveries")
    assert.is_truthy(env.text():find("No closed seasons yet", 1, true))
  end)

  it("has a dropdown to pick among several closed seasons", function()
    env = build("GM")
    local season = seed(env)
    env.ns.pvpSeason:CloseSeason(season.id)
    local ledger = env.ns.db.global.pvpSeason
    ledger.finals.older = {
      seasonId = "older",
      name = "Older",
      startsAt = 1,
      endsAt = 2,
      closedAt = 3,
      standings = {},
      prizes = {},
    }
    go(env, "admin", "deliveries")
    local picker = FakeKit.find(env.page(), "Dropdown")
    picker.opts.onChange("older")
    assert.is_truthy(env.text():find("Older", 1, true))
    assert.is_truthy(env.text():find("Nobody won a prize", 1, true))
  end)

  it("shows the history empty, by season and cumulative", function()
    env = build("Member")
    go(env, "history")
    assert.is_truthy(env.text():find("No closed seasons yet", 1, true))
  end)

  it("shows no PvP officer column in Members, flag or not, and gives nobody a toggle", function()
    for _, rank in ipairs({ "Member", "GM" }) do
      env = build(rank)
      env.forceTabs = true
      officer(env)
      env.ns.db.global.pvpSeason.officers["Ann-Realm"] =
        { player = "Ann-Realm", intervals = { { from = 0 } }, rev = 1, updatedAt = 1 }
      env.open("roster")
      for _, row in ipairs(env.tableRows()) do
        assert.is_nil(row.cells.pvp, rank)
      end
      assert.is_nil(env.text():find("PVP OFFICER", 1, true))
      pcall(env.close)
    end
  end)
end)

describe("Window smoke test: Blacklist", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  local function entry(name, by)
    return { name = name, reason = "ninja", addedBy = by or "Other", addedAt = 100, rev = 1, updatedAt = 1 }
  end

  it("says so when the list is empty, and adds a player from the form", function()
    env = build("Member")
    env.open("blacklist")
    assert.is_truthy(env.text():find("Nobody is on the blacklist.", 1, true))
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Yonemon Gg")
    FakeKit.find_all(env.page(), "EditBox")[2].opts.onChange("ninja looter")
    env.press("Add")
    assert.are.equal("ninja looter", env.ns.db.global.blacklist.yonemongg.reason)
    assert.are.equal("SendBlacklistUpsert", env.sent[1])
    assert.are.equal("success", env.banner().opts.kind)
  end)

  it("shows a validation error and sends nothing", function()
    env = build("Member")
    env.open("blacklist")
    env.press("Add")
    assert.are.equal("danger", env.banner().opts.kind)
    assert.are.same({}, env.sent)
  end)

  it("marks the players in the group and lists them first", function()
    env = build("Member")
    env.ns.db.global.blacklist.zed = entry("Zed")
    env.ns.db.global.blacklist.ann = entry("Ann")
    env.ns.Platform.GetGroupMemberNames = function()
      return { "Zed" }
    end
    env.open("blacklist")
    local rows = env.tableRows()
    assert.are.equal("Zed", rows[1].cells.name.text)
    assert.are.equal("In your group", rows[1].cells.group.opts.text)
    assert.are.equal("", rows[2].cells.group)
  end)

  it("lets who added the entry edit the reason in place, and nobody else", function()
    env = build("Member")
    env.ns.db.global.blacklist.ann = entry("Ann", "Leader-Realm")
    env.ns.db.global.blacklist.bob = entry("Bob", "Other")
    env.open("blacklist")
    local rows = env.tableRows()
    assert.are.equal("pencil", rows[1].cells.edit.opts.icon)
    assert.are.equal("", rows[2].cells.edit)
    rows[1].cells.edit.opts.onClick()
    local editing = env.tableRows()[1]
    assert.are.equal("edit", editing.cells.reason.widget)
    editing.cells.reason.opts.onChange("changed")
    editing.cells.edit.opts.onClick()
    assert.are.equal("changed", env.ns.db.global.blacklist.ann.reason)
    rows = env.tableRows()
    rows[1].cells.edit.opts.onClick()
    env.tableRows()[1].cells.remove.opts.onClick()
    assert.are.equal("changed", env.ns.db.global.blacklist.ann.reason)
  end)

  it("lets only the guild master remove, with a second click", function()
    env = build("Member")
    env.ns.db.global.blacklist.ann = entry("Ann")
    env.open("blacklist")
    assert.are.equal("", env.tableRows()[1].cells.remove)
    pcall(env.close)
    env = build("GM")
    env.ns.db.global.blacklist.ann = entry("Ann")
    env.open("blacklist")
    env.tableRows()[1].cells.remove.opts.onClick()
    assert.is_truthy(env.ns.db.global.blacklist.ann)
    env.tableRows()[1].cells.remove.opts.onClick()
    assert.is_nil(env.ns.db.global.blacklist.ann)
    assert.are.equal("SendBlacklistDelete", env.sent[#env.sent])
  end)

  it("searches and escapes what the guild wrote", function()
    env = build("Member")
    env.ns.db.global.blacklist.ann = entry("Ann")
    env.ns.db.global.blacklist.bob = { name = "Bob", reason = "|cffff0000red|r", addedBy = "|c", addedAt = 1, rev = 1 }
    env.open("blacklist")
    assert.is_nil(env.text():find("[^|]|c", 1))
    env.box("Search by name or reason").opts.onChange("bob", true)
    assert.are.equal(1, #env.tableRows())
    env.box("Search by name or reason").opts.onChange("zzz", true)
    assert.are.equal(0, #env.tableRows())
  end)

  it("redraws when an entry arrives, once per interval, and only on its own tab", function()
    env = build("Member")
    env.open("blacklist")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.BlacklistChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    env.ns.UI.SelectTab("home")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.BlacklistChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)

  it("does nothing when the window is closed", function()
    env = build("Member")
    env.ns.UI.BlacklistChanged()
    env.ns.UI.PvPChanged()
    env.ns.UI.RulesChanged()
    env.ns.UI.RostersChanged()
    assert.are.equal(0, #env.ns.Kit.fake.nodes)
  end)
end)

describe("Window smoke test: Rules", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  local function rule_form()
    return FakeKit.find_all(env.page(), "Card")
  end

  it("shows nothing to edit to roster, member and alter", function()
    for _, rank in ipairs({ "Roster", "Member", "Alter" }) do
      env = build(rank)
      env.forceTabs = true
      env.open("rules")
      assert.is_truthy(env.text():find("There is no roster to show rules for.", 1, true), rank)
      assert.is_nil(env.find(env.page(), "List"), rank)
      pcall(env.close)
    end
  end)

  local function all_disabled(nodes)
    assert.is_true(#nodes > 0)
    for _, node in ipairs(nodes) do
      assert.is_true(node.opts.disabled, node.opts.text or node.opts.tooltip or node.opts.label)
    end
  end

  local function with_second_roster(target)
    target.ns.db.global.rosters.r2 = { id = "r2", name = "Second", rev = 1, updatedAt = 1 }
  end

  it("shows the officer every roster with the selector, read only", function()
    env = build("Officer")
    with_second_roster(env)
    env.open("rules")
    local selector = FakeKit.find_all(env.page(), "Dropdown")[1]
    assert.are.equal(2, #selector.opts.items)
    assert.are.equal("r1", selector.opts.value)
    selector.opts.onChange("r2")
    assert.are.equal("r2", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
    assert.are.equal(5, #FakeKit.find(env.page(), "List").opts.rows)
    assert.is_truthy(env.text():find("Read only", 1, true))
    assert.is_nil(env.text():find("Sent to the guild automatically", 1, true))
    -- Controls are there, but disabled.
    local row = FakeKit.find(env.page(), "List").opts.rows[1]
    all_disabled({ row.rights[1], row.rights[2] })
    local boxes = FakeKit.find_all(env.page(), "EditBox")
    all_disabled(boxes)
    all_disabled({ FakeKit.find_all(env.page(), "Dropdown")[2] })
    all_disabled({
      FakeKit.find(env.page(), "Button", "Add rule"),
      FakeKit.find(env.page(), "Button", "Use the starting list"),
    })
    env.press("Add rule")
    assert.are.same({}, env.sent)
  end)

  it("lets an rl edit its own roster, with no selector", function()
    env = build("RL")
    with_second_roster(env)
    env.open("rules")
    assert.is_truthy(env.text():find("Roster: Main", 1, true))
    assert.are.equal("Kind", FakeKit.find_all(env.page(), "Field")[1].opts.label)
    assert.is_nil(FakeKit.find_all(env.page(), "Dropdown")[2])
    assert.is_truthy(env.text():find("Sent to the guild automatically", 1, true))
    local boxes = FakeKit.find_all(env.page(), "EditBox")
    boxes[1].opts.onChange("Tough")
    boxes[2].opts.onChange("70")
    env.press("Add rule")
    assert.are.same({ "SetReadinessRules", "r1" }, { env.sent[1], env.rulesRoster })
  end)

  it("lets gm and cogm pick a roster and edit it without touching the others", function()
    for _, rank in ipairs({ "GM", "CoGM" }) do
      env = build(rank)
      with_second_roster(env)
      env.open("rules")
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("r2")
      local boxes = FakeKit.find_all(env.page(), "EditBox")
      boxes[1].opts.onChange("Tough")
      boxes[2].opts.onChange("70")
      env.press("Add rule")
      assert.are.equal("r2", env.rulesRoster, rank)
      assert.are.equal(6, #env.ns.db.global.readinessRulesByRoster.r2.rules, rank)
      assert.is_nil(env.ns.db.global.readinessRulesByRoster.r1, rank)
      pcall(env.close)
    end
  end)

  it("lists the rules with their badges and the form to add one", function()
    env = build("GM")
    env.open("rules")
    local list = FakeKit.find(env.page(), "List")
    assert.are.equal(5, #list.opts.rows)
    assert.are.equal("Automatic", list.opts.rows[1].badge.text)
    assert.are.equal("Manual", list.opts.rows[3].badge.text)
    assert.is_truthy(env.text():find("Add a rule", 1, true))
    assert.is_truthy(env.text():find("Sent to the guild automatically", 1, true))
    assert.is_truthy(rule_form())
  end)

  it("adds a level rule", function()
    env = build("GM")
    env.open("rules")
    local boxes = FakeKit.find_all(env.page(), "EditBox")
    boxes[1].opts.onChange("Tough")
    boxes[2].opts.onChange("70")
    env.press("Add rule")
    assert.are.equal("SetReadinessRules", env.sent[1])
    assert.are.equal("success", env.banner().opts.kind)
    local rules = env.ns.db.global.readinessRulesByRoster.r1.rules
    assert.are.equal("Tough", rules[#rules].label)
    assert.are.equal(70, rules[#rules].min)
  end)

  it("shows the error under the field it belongs to, and sends nothing", function()
    env = build("GM")
    env.open("rules")
    env.press("Add rule")
    assert.are.equal("danger", env.banner().opts.kind)
    local field = FakeKit.find(env.page(), "Field", "Name")
    assert.is_truthy(field.opts.error)
    assert.are.same({}, env.sent)
    local boxes = FakeKit.find_all(env.page(), "EditBox")
    boxes[1].opts.onChange("Level")
    boxes[2].opts.onChange("abc")
    env.press("Add rule")
    assert.is_truthy(FakeKit.find(env.page(), "Field", "Minimum").opts.error)
  end)

  it("builds each kind of rule from its controls", function()
    env = build("GM")
    env.open("rules")
    local kind = FakeKit.find_all(env.page(), "Dropdown")[2]
    for _, check in ipairs({ "ilvl", "enchants", "buff", "profession", "field", "confirm" }) do
      kind.opts.onChange(check)
      env.open("rules")
      kind = FakeKit.find_all(env.page(), "Dropdown")[2]
      assert.are.equal(check, kind.opts.value)
    end
    kind.opts.onChange("enchants")
    env.open("rules")
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Enchanted")
    for _, chip in ipairs(FakeKit.find_all(env.page(), "Chip")) do
      if chip.opts.text == "Chest" then
        chip.opts.onToggle(true)
      end
    end
    env.press("Add rule")
    local rules = env.ns.db.global.readinessRulesByRoster.r1.rules
    assert.are.same({ 5 }, rules[#rules].slots)

    kind = FakeKit.find_all(env.page(), "Dropdown")[2]
    kind.opts.onChange("profession")
    env.open("rules")
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Alchemist")
    FakeKit.find_all(env.page(), "Dropdown")[3].opts.onChange("Alchemy")
    FakeKit.find_all(env.page(), "EditBox")[2].opts.onChange("300")
    env.press("Add rule")
    rules = env.ns.db.global.readinessRulesByRoster.r1.rules
    assert.are.same({ "Alchemy", 300 }, { rules[#rules].profession, rules[#rules].min })
  end)

  it("edits a rule in place, keeping its id and position, and cancels", function()
    env = build("GM")
    env.open("rules")
    local list = FakeKit.find(env.page(), "List")
    list.opts.rows[1].rights[2].opts.onClick()
    assert.is_truthy(env.text():find("Edit the rule", 1, true))
    local boxes = FakeKit.find_all(env.page(), "EditBox")
    assert.are.equal("Level 60", boxes[1].opts.text)
    boxes[1].opts.onChange("Level 70")
    boxes[2].opts.onChange("70")
    env.press("Save rule")
    local rules = env.ns.db.global.readinessRulesByRoster.r1.rules
    assert.are.same({ "level", "Level 70", 70 }, { rules[1].id, rules[1].label, rules[1].min })
    assert.are.equal(5, #rules)
    FakeKit.find(env.page(), "List").opts.rows[2].rights[2].opts.onClick()
    env.press("Cancel")
    assert.is_truthy(env.text():find("Add a rule", 1, true))
  end)

  it("deletes a rule after a second click, but never the last one", function()
    env = build("GM")
    env.open("rules")
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    assert.are.equal(4, #env.ns.db.global.readinessRulesByRoster.r1.rules)
    env.ns.db.global.readinessRulesByRoster.r1.rules = { env.ns.db.global.readinessRulesByRoster.r1.rules[1] }
    env.ns.UI.Redraw()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    assert.are.equal("danger", env.banner().opts.kind)
    assert.are.equal(1, #env.ns.db.global.readinessRulesByRoster.r1.rules)
  end)

  it("puts the starting list back only after a second click, and links to Readiness", function()
    env = build("GM")
    env.ns.db.global.readinessRulesByRoster.r1 =
      { rev = 1, rules = { { id = "x", label = "X", check = "confirm", category = "c", evidenceMode = "manual" } } }
    env.open("rules")
    env.press("Use the starting list")
    assert.are.equal(1, #env.ns.db.global.readinessRulesByRoster.r1.rules)
    env.press("Confirm: replace every rule with the starting list")
    assert.are.equal(5, #env.ns.db.global.readinessRulesByRoster.r1.rules)
    env.press("See how members see it")
    assert.are.equal("ready", env.ns.UI.CurrentTab())
  end)

  it("redraws the Readiness and Rules tabs when the rules change", function()
    env = build("GM")
    env.open("rules")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.RulesChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
  end)
end)

describe("Window smoke test: settings, language and automatic refresh", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  local function open_settings()
    env = build("Member")
    env.open("home")
    env.ns.UI.ToggleSettings()
    return env.ns.Kit.Popup.Get(1).stack
  end

  it("hides and shows the minimap button, and puts it back in its place", function()
    local stack = open_settings()
    local switch = FakeKit.find(stack, "Switch", "Show the minimap button")
    assert.is_true(switch.opts.checked)
    switch.opts.onChange(false)
    assert.is_true(env.ns.MinimapButton.Settings(env.ns.db).hide)
    switch.opts.onChange(true)
    assert.is_false(env.ns.MinimapButton.Settings(env.ns.db).hide)
    env.ns.MinimapButton.Settings(env.ns.db).angle = 10
    FakeKit.press(FakeKit.find(stack, "Button", "Reset"))
    assert.are.equal(env.ns.Constants.MINIMAP_DEFAULT_ANGLE, env.ns.MinimapButton.Settings(env.ns.db).angle)
  end)

  it("saves the blacklist alert sound switch, on by default", function()
    local stack = open_settings()
    local switch = FakeKit.find(stack, "Switch", "Blacklist alert sound")
    assert.is_true(switch.opts.checked)
    switch.opts.onChange(false)
    assert.is_false(env.ns.Settings.BlacklistSound(env.ns.db))
  end)

  it("saves the position switches: sharing and the guild on both maps are on by default", function()
    local stack = open_settings()
    local calls = {}
    env.ns.SetPositionShare = function(share)
      calls[#calls + 1] = { "share", share }
    end
    env.ns.SetPositionDisplay = function(which, on)
      calls[#calls + 1] = { which, on }
    end
    local share = FakeKit.find(stack, "Switch", "Share my position")
    local minimap = FakeKit.find(stack, "Switch", "Show guildmates on the minimap")
    local worldmap = FakeKit.find(stack, "Switch", "Show guildmates on the world map")
    assert.is_true(share.opts.checked)
    assert.is_true(minimap.opts.checked)
    assert.is_true(worldmap.opts.checked)
    share.opts.onChange(false)
    minimap.opts.onChange(false)
    worldmap.opts.onChange(false)
    assert.are.same({ { "share", false }, { "minimap", false }, { "worldmap", false } }, calls)
  end)

  it("changes the language and draws the window again in it", function()
    local stack = open_settings()
    local dropdown = FakeKit.find_all(stack, "Dropdown")[1]
    assert.are.equal("auto", dropdown.opts.value)
    dropdown.opts.onChange("es")
    assert.are.equal("es", env.ns.Settings.Language(env.ns.db))
    assert.are.equal("Inicio", env.ns.ViewModel.TABS[1].text)
    assert.is_truthy(env.text():find("Quién eres", 1, true))
    dropdown.opts.onChange("en")
    assert.are.equal("Home", env.ns.ViewModel.TABS[1].text)
  end)

  it("closes on the second press of the gear", function()
    open_settings()
    assert.is_true(env.ns.Kit.Popup.Get(1):IsOpen())
    env.ns.UI.ToggleSettings()
    assert.is_false(env.ns.Kit.Popup.Get(1):IsOpen())
  end)

  it("draws every tab in Spanish for the guild master, and keeps English on another client", function()
    env = build("GM", "esES")
    for _, tab in ipairs(ALL_TABS) do
      assert.is_truthy(env.open(tab), tab)
    end
    env.open("rules")
    assert.is_truthy(FakeKit.find(env.page(), "List"))
    pcall(env.close)
    env = build("GM", "frFR")
    env.open("rules")
    assert.is_truthy(env.text():find("Add a rule", 1, true))
  end)

  it("remembers where the window is left, and the first size", function()
    env = build("Member")
    env.open("home")
    local saved = env.ns.db.global.settings.windows.mainWindow
    assert.are.same({ 1000, 640 }, { saved.width, saved.height })
    saved.width = 900
    env.ns.UI.ApplyWindowStatus({ SetStatusTable = function() end }, "mainWindow", 1000, 640)
    assert.are.equal(900, env.ns.db.global.settings.windows.mainWindow.width)
  end)

  it("listens for gear, level, skill and player aura events while Readiness or Home is on screen", function()
    env = build("Member")
    env.open("ready")
    for _, event_name in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "SKILL_LINES_CHANGED" }) do
      assert.is_true(env.registered[event_name], event_name)
    end
    assert.are.equal("player", env.registered.UNIT_AURA)
  end)

  it("draws the readiness again on such an event, at most once per interval", function()
    env = build("Member")
    env.open("ready")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.ReadinessChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    count = #env.ns.Kit.fake.nodes
    env.timers = {}
    env.ns.UI.ReadinessChanged()
    env.ns.UI.ReadinessChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
    assert.are.equal(1, #env.timers)
    env.ns.Platform.Now = function()
      return 5
    end
    env.timers[1]()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
  end)

  it("leaves the other tabs alone, and does nothing when the window is closed", function()
    env = build("Member")
    env.open("professions")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.ReadinessChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
    env.ns.UI.Toggle()
    env.ns.UI.ReadinessChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)

  it("builds the sidebar again when rosters change", function()
    env = build("Member")
    env.open("home")
    local before = 0
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        before = before + 1
      end
    end
    env.ns.UI.RostersChanged()
    local after = 0
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        after = after + 1
      end
    end
    assert.are.equal(before + 1, after)
  end)
end)

describe("Window smoke test: Professions", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  local function share(name, professionId, professionName, ids)
    env.ns.db.global.recipes[name] = { [professionId] = { name = professionName, ids = ids, rev = 1 } }
  end

  it("says so when nobody has shared recipes", function()
    env = build("Member")
    env.open("professions")
    assert.is_truthy(env.text():find("No recipes shared yet", 1, true))
    assert.is_truthy(env.text():find("My professions", 1, true))
  end)

  it("warns when the client cannot read the own recipes", function()
    env = build("Member")
    env.scanAvailable = false
    env.open("professions")
    assert.is_truthy(env.text():find("Reading your own recipes is not available", 1, true))
  end)

  it("lists who can craft a recipe and prefills a whisper from its dropdown", function()
    env = build("Member")
    env.recipeNames = { [10] = "Elixir of Might", [11] = "Flask of Wisdom" }
    share("Ann-Realm", 171, "Alchemy", { 10, 11 })
    env.open("professions")
    assert.is_truthy(env.text():find("Elixir of Might", 1, true))
    -- The first dropdown is the profession filter; each recipe has its own after it.
    local dropdown = FakeKit.find_all(env.page(), "Dropdown")[2]
    assert.are.equal("Ask... (1)", dropdown.opts.placeholder)
    assert.are.same({ { value = "Ann-Realm", text = "Ann-Realm" } }, dropdown.opts.items)
    dropdown.opts.onChange("Ann-Realm")
    assert.are.equal("/w Ann-Realm Could you craft me [link10]?", env.prefilled)
    assert.is_nil(dropdown:GetValue())
  end)

  it("disables the dropdown of a recipe nobody online can craft and names the crafters", function()
    env = build("Member")
    env.recipeNames = { [10] = "Elixir of Might" }
    share("Ann-Realm", 171, "Alchemy", { 10 })
    env.ns.guildRoster = {
      Lookup = function()
        return { online = false }
      end,
    }
    env.open("professions")
    local dropdown = FakeKit.find_all(env.page(), "Dropdown")[2]
    assert.is_true(dropdown.opts.disabled)
    assert.are.equal("Nobody online (1)", dropdown.opts.placeholder)
    assert.are.equal("Ann-Realm", dropdown.opts.tooltip)
  end)

  it("searches by name and says when nothing matches", function()
    env = build("Member")
    env.recipeNames = { [10] = "Elixir of Might", [11] = "Flask of Wisdom" }
    share("Ann-Realm", 171, "Alchemy", { 10, 11 })
    env.open("professions")
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("flask", true)
    local text = env.text()
    assert.is_truthy(text:find("Flask of Wisdom", 1, true))
    assert.is_falsy(text:find("Elixir of Might", 1, true))
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("zzz", true)
    assert.is_truthy(env.text():find("No recipe matches", 1, true))
  end)
end)

describe("Window smoke test: secondary windows", function()
  local env

  after_each(function()
    pcall(env.close)
    _G.LibStub = nil
  end)

  local function load_file(path)
    assert(loadfile("NrageAssistant/" .. path))("NrageAssistant", env.ns)
  end

  local function with_session()
    env.ns.db.global.events.e1 = event("e1", "Molten Core", { status = "open" })
    env.ns.db.global.events.e1.loot = {
      s1 = {
        sessionId = "s1",
        itemId = 5,
        itemName = "Sword",
        status = "open",
        rev = 1,
        updatedAt = 3,
        candidates = { ["Ann-Realm"] = { need = "main", spec = "Tank", rev = 1, updatedAt = 1 } },
        votes = {},
      },
      s2 = {
        sessionId = "s2",
        itemId = 6,
        itemName = "Shield",
        status = "open",
        rev = 1,
        updatedAt = 4,
        candidates = {},
        votes = {},
      },
    }
  end

  describe("export and import", function()
    local function stub_transfer()
      _G.LibStub = function()
        return {}
      end
      env.ns.Transfer = {
        Export = function()
          return "NRAGE1:abc"
        end,
        Import = function(_, text)
          if text == "NRAGE1:abc" then
            return { events = 1 }
          end
          return nil, "bad_header"
        end,
        Describe = function()
          return "imported 1 event"
        end,
      }
    end

    it("shows the export text read-only in a modal", function()
      env = build("RL")
      stub_transfer()
      env.ns.UI.ShowTransfer("export")
      local modal = env.ns.Kit.fake.modal
      assert.are.equal("Nrage export", modal.opts.title)
      assert.is_truthy(FakeKit.text(modal.stack):find("Press Ctrl+C to copy", 1, true))
      local area = FakeKit.find(modal.stack, "TextArea")
      assert.are.equal("NRAGE1:abc", area.opts.text)
      assert.is_true(area.opts.readOnly)
    end)

    it("imports pasted text and reports in the banner, or says why not", function()
      env = build("RL")
      stub_transfer()
      env.open("home")
      env.ns.UI.ShowTransfer("import")
      local modal = env.ns.Kit.fake.modal
      FakeKit.find(modal.stack, "TextArea").text = "junk"
      FakeKit.press(FakeKit.find(modal.stack, "Button", "Import"))
      assert.is_nil(env.ns.Kit.fake.modal)
      assert.are.equal("danger", env.banner().opts.kind)
      assert.is_truthy(env.banner().opts.text:find("import failed", 1, true))

      env.ns.UI.ShowTransfer("import")
      FakeKit.find(env.ns.Kit.fake.modal.stack, "TextArea").text = "NRAGE1:abc"
      FakeKit.press(FakeKit.find(env.ns.Kit.fake.modal.stack, "Button", "Import"))
      assert.are.equal("success", env.banner().opts.kind)
    end)

    it("closes with Cancel", function()
      env = build("RL")
      stub_transfer()
      env.ns.UI.ShowTransfer("import")
      FakeKit.press(FakeKit.find(env.ns.Kit.fake.modal.stack, "Button", "Cancel"))
      assert.is_nil(env.ns.Kit.fake.modal)
    end)
  end)

  describe("minimap menu", function()
    it("opens the settings of the window from the menu", function()
      env = build("Member")
      env.ns.UI.OpenSettings()
      assert.is_true(env.ns.Kit.Popup.Get(1):IsOpen())
    end)
  end)

  describe("loot popup", function()
    local function handlers(log)
      return {
        answer = function(entry, need)
          log[#log + 1] = entry.sessionId .. ":" .. need
        end,
        pass = function(entry)
          log[#log + 1] = entry.sessionId .. ":pass"
        end,
        timeLeft = function(sessionId)
          return sessionId == "s1" and 15 or nil
        end,
        timeout = 30,
        spec = "Tank",
        footer = "Nothing is sent until you click a button.",
      }
    end

    it("draws a row per item with the answers, the spec, the countdown and the footer", function()
      env = build("Member")
      load_file("UI/LootPopup.lua")
      local root = env.ns.Kit.Stack(nil, {})
      local log = {}
      env.ns.LootPopup.Draw(root, {
        { sessionId = "s1", itemId = 5, itemName = "Sword", eventTitle = "Molten Core" },
        { sessionId = "s2", itemId = 6, itemName = "Shield", eventTitle = "Molten Core" },
      }, handlers(log))
      local items = FakeKit.find_all(root, "ItemLabel")
      assert.are.equal("Shield", items[1].opts.text)
      assert.are.equal("Sword", items[2].opts.text)
      assert.is_truthy(FakeKit.text(root):find("Spec: Tank (from your profile)", 1, true))
      assert.are.equal(1, #FakeKit.find_all(root, "ProgressBar"))
      assert.are.equal(0.5, FakeKit.find(root, "ProgressBar").opts.value)
      local function buttons(text)
        return FakeKit.find_all(root, "Button", function(node)
          return node.opts.text == text
        end)
      end
      FakeKit.press(buttons("Off spec")[2])
      FakeKit.press(buttons("Pass")[1])
      assert.are.same({ "s1:off", "s2:pass" }, log)
      assert.is_truthy(FakeKit.text(root):find("Nothing is sent", 1, true))
    end)

    it("scrolls when more than three items are waiting", function()
      env = build("Member")
      load_file("UI/LootPopup.lua")
      local root = env.ns.Kit.Stack(nil, {})
      local entries = {}
      for index = 1, 5 do
        entries[index] = { sessionId = "s" .. index, itemId = index, itemName = "Item " .. index, eventTitle = "Raid" }
      end
      env.ns.LootPopup.Draw(root, entries, handlers({}))
      assert.is_truthy(FakeKit.find(root, "ScrollArea"))
    end)
  end)

  describe("voting window", function()
    local function open_voting(rank)
      env = build(rank)
      with_session()
      env.ns.VotingFrame = nil
      load_file("UI/VotingFrame.lua")
      env.ns.VotingFrame.Show()
      return env.page()
    end

    -- Picks a session in the list on the left by its item.
    local function select_item(name)
      for _, row in ipairs(FakeKit.find_all(env.page(), "NavRow")) do
        if row.opts.text:find(name, 1, true) then
          FakeKit.press(row)
        end
      end
    end

    it("lists the open sessions on the left and the candidates in the shared table", function()
      local page = open_voting("Council")
      assert.are.equal(2, #FakeKit.find_all(page, "NavRow"))
      assert.is_truthy(env.text():find("Molten Core", 1, true))
      select_item("Sword")
      assert.is_truthy(FakeKit.find(env.page(), "Table"))
    end)

    it("shows the other session when it is selected", function()
      open_voting("Council")
      select_item("Shield")
      assert.is_truthy(env.text():find("no candidates yet", 1, true))
    end)

    it("votes from a row and reports in the window", function()
      open_voting("Council")
      select_item("Sword")
      local rows = FakeKit.find(env.page(), "Table").opts.rows
      local vote = rows[1].cells.vote
      assert.is_truthy(vote)
      vote.opts.onClick()
      assert.are.equal("SendLootVote", env.sent[#env.sent])
      assert.is_truthy(FakeKit.find(env.page(), "Banner"))
    end)

    it("closes a session only after a second click", function()
      open_voting("Council")
      select_item("Sword")
      FakeKit.press(FakeKit.find(env.page(), "Button", "Close without awarding"))
      local confirm = FakeKit.find(env.page(), "Button", "Confirm: close without awarding")
      assert.is_truthy(confirm)
      FakeKit.press(confirm)
      assert.are.equal("closed", env.ns.db.global.events.e1.loot.s1.status)
    end)

    it("says so when no session is open", function()
      env = build("Council")
      env.ns.VotingFrame = nil
      load_file("UI/VotingFrame.lua")
      env.ns.VotingFrame.Show()
      assert.is_truthy(env.text():find("No loot sessions are open.", 1, true))
    end)
  end)
end)

describe("Window smoke test: Layers", function()
  local env, share

  local function install(options)
    options = options or {}
    local zones = {}
    env.ns.Platform.GetPlayerZoneId = function()
      return 1429
    end
    env.ns.Platform.GetMapName = function(map)
      return map == 1429 and "Elwynn Forest" or nil
    end
    env.ns.layerTracker = {
      Current = function()
        return options.own
      end,
    }
    env.ns.layerDirectory = {
      Groups = function(_, map, zone)
        zones[#zones + 1] = { map, zone }
        return { { map = 0, layer = 5678, members = { "Ann-Realm" }, count = 1 } }
      end,
    }
    env.layerZones = zones
    env.ns.SetLayerShare = function(value)
      share = value
    end
  end

  before_each(function()
    env = build("RL")
    share = nil
  end)

  after_each(function()
    pcall(env.close)
  end)

  it("is not in the sidebar of any role", function()
    for _, role in ipairs({ "gm", "cogm", "officer", "rl", "roster", "member", "alter" }) do
      for _, tab in ipairs(env.ns.ViewModel.TabsFor(role, "r1")) do
        assert.are_not.equal("layers", tab.value, role)
      end
    end
  end)

  it("says the feature is not available before it starts", function()
    env.open("layers")
    assert.is_truthy(env.text():find("not available", 1, true))
    assert.is_truthy(FakeKit.find(env.page(), "Switch", "Share my layer"))
  end)

  it("lists the layers of the zone the player is in", function()
    install({ own = { map = 0, layer = 1234 } })
    env.open("layers")
    local text = env.text()
    assert.is_truthy(text:find("Your layer: #1234", 1, true))
    assert.is_truthy(text:find("#5678", 1, true))
    -- Only the layers of the zone the player is in.
    assert.is_truthy(text:find("Layers in Elwynn Forest", 1, true))
    assert.are.same({ 0, 1429 }, env.layerZones[#env.layerZones])
    assert.is_truthy(text:find("Ann-Realm", 1, true))
  end)

  it("switches sharing with the switch", function()
    install()
    env.open("layers")
    local switch = FakeKit.find(env.page(), "Switch", "Share my layer")
    assert.is_true(switch.opts.checked)
    switch.opts.onChange(false)
    assert.is_false(share)
  end)

  it("redraws when the layers change, at most once per interval, and only on the tabs that show them", function()
    install()
    env.open("layers")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.LayersChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    count = #env.ns.Kit.fake.nodes
    env.timers = {}
    env.ns.UI.LayersChanged()
    env.ns.UI.LayersChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
    assert.are.equal(1, #env.timers)
    env.ns.UI.SelectTab("professions")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.LayersChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)

  it("redraws Home when the layers change, since Home shows them", function()
    install()
    env.open("home")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.LayersChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
  end)
end)

describe("Window smoke test: Groups", function()
  local env, world

  -- The real board and service over fakes: a clock that does not move, the messages they would send, and a client that
  -- lets the game invite.
  local function install(options)
    options = options or {}
    local ns = env.ns
    world = { sent = {}, invites = {}, locked = false, clock = 1000, group = {} }
    local function send(kind)
      return function(payload)
        if world.locked then
          return false, "locked"
        end
        world.sent[#world.sent + 1] = { kind = kind, payload = payload }
        return true
      end
    end
    local platform = {
      IsInGroup = function()
        return false
      end,
      IsInRaid = function()
        return false
      end,
      IsInCombat = function()
        return false
      end,
      IsGroupLeader = function()
        return true
      end,
      GetGroupSize = function()
        return 0
      end,
    }
    local function isLocked()
      return world.locked
    end
    ns.lfgBoard = ns.LfgBoard.New({
      now = function()
        return world.clock
      end,
    })
    ns.lfgService = ns.LfgService.New({
      now = function()
        return world.clock
      end,
      schedule = function() end,
      send = { post = send("post"), apply = send("apply") },
      isLocked = isLocked,
      ownName = ns.Platform.GetIdentityKey,
      newId = function()
        return "mine-1"
      end,
      ownLevel = function()
        return 60
      end,
      eligibility = ns.LfgService.Eligibility(platform, isLocked, function()
        return false
      end),
      invite = function(name)
        world.invites[#world.invites + 1] = name
        return true
      end,
      isGroupMember = function(name)
        return world.group[name] == true
      end,
      groupSize = function()
        return 0
      end,
      isRaid = function()
        return false
      end,
      isLeader = function()
        return true
      end,
      board = ns.lfgBoard,
      onChange = function() end,
    })
    ns.Platform.GetGroupSize = function()
      return 0
    end
    ns.Platform.IsInRaid = function()
      return false
    end
    if options.post ~= false then
      ns.lfgBoard:Apply("Kaelis", {
        pid = "k-1",
        rev = 1,
        s = "open",
        kind = "dungeon",
        title = options.title or "Scarlet Monastery",
        needs = { tank = 1, heal = 1, dps = 0 },
        members = 3,
        minLevel = 34,
        note = "Bring potions",
      })
    end
  end

  local function sidebarNode()
    local found
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        found = node
      end
    end
    return found
  end

  local function modalButton(text)
    return FakeKit.find(env.ns.Kit.fake.modal.stack, "Button", text)
  end

  before_each(function()
    env = build("RL")
    install()
  end)

  after_each(function()
    pcall(env.close)
  end)

  it("says the feature is not available before it starts", function()
    env.ns.lfgBoard, env.ns.lfgService = nil, nil
    env.open("groups")
    assert.is_truthy(env.text():find("Groups are not available yet.", 1, true))
  end)

  it("is in the sidebar of every rank", function()
    for _, rank in ipairs({ "GM", "CoGM", "Council", "RL", "Roster", "Member", "Alter" }) do
      local other = build(rank)
      other.ns.ViewModel.TabVisible = other.realTabVisible
      assert.is_true(
        other.ns.ViewModel.TabVisible("groups", other.ns.PermissionService.OwnRole(other.ns.Platform), "r1"),
        rank
      )
      pcall(other.close)
    end
  end)

  it("lists the board with the leader, the level, the age, the roles and the members", function()
    env.open("groups")
    local text = env.text()
    assert.is_truthy(text:find("Scarlet Monastery", 1, true))
    assert.is_truthy(text:find("Leader: Kaelis", 1, true))
    assert.is_truthy(text:find("Level 34+", 1, true))
    assert.is_truthy(text:find("1 Tank", 1, true))
    assert.is_truthy(text:find("Only members who use the addon appear.", 1, true))
    local seats = FakeKit.find(env.page(), "Seats")
    assert.are.equal(5, #seats.opts.seats)
    assert.is_true(seats.opts.seats[3].filled)
    assert.is_false(seats.opts.seats[4].filled)
    assert.are.equal("3 of 5 members", seats.opts.tooltip)
    assert.is_false(env.find(env.page(), "Button", "Apply").opts.disabled)
  end)

  it("shows a hostile title and leader as text, never as a client escape", function()
    install({ title = "|cffff0000Free|r gold" })
    env.ns.lfgBoard:Apply("Ev|il", {
      pid = "e-1",
      rev = 1,
      s = "open",
      kind = "other",
      title = "x",
      needs = { tank = 0, heal = 0, dps = 1 },
      members = 1,
    })
    env.open("groups")
    local text = env.text()
    assert.is_truthy(text:find("||cffff0000Free||r gold", 1, true))
    assert.is_truthy(text:find("Leader: Ev||il", 1, true))
    assert.is_nil(text:find("[^|]|c"))
  end)

  it("explains an empty board and filters by kind and role", function()
    env.open("groups")
    local filters = FakeKit.find_all(env.page(), "Segmented")
    assert.are.equal(2, #filters)
    filters[1].opts.onChange("quest")
    assert.is_truthy(env.text():find("No groups with these filters. Create yours.", 1, true))
    filters = FakeKit.find_all(env.page(), "Segmented")
    filters[1].opts.onChange("all")
    filters = FakeKit.find_all(env.page(), "Segmented")
    filters[2].opts.onChange("dps")
    assert.is_truthy(env.text():find("No groups with these filters.", 1, true))
    filters = FakeKit.find_all(env.page(), "Segmented")
    filters[2].opts.onChange("all")
    assert.is_truthy(env.text():find("Scarlet Monastery", 1, true))
  end)

  it("applies with the role and the note from the dialog, and shows the application", function()
    env.open("groups")
    env.press("Apply")
    assert.is_truthy(env.ns.Kit.fake.modal)
    local roles = FakeKit.find(env.ns.Kit.fake.modal.stack, "Segmented")
    roles.opts.onChange("heal")
    FakeKit.find(env.ns.Kit.fake.modal.stack, "EditBox").opts.onChange("  bring water ")
    FakeKit.press(modalButton("Send"))
    assert.are.same({ pid = "k-1", s = "apply", role = "heal", note = "bring water" }, world.sent[1].payload)
    assert.is_nil(env.ns.Kit.fake.modal)
    local text = env.text()
    assert.is_truthy(text:find("Application sent to Kaelis", 1, true))
    assert.is_truthy(text:find("expires in 2:00", 1, true))
    assert.are.equal("Applied", env.find(env.page(), "Button", "Applied").opts.text)
    assert.is_true(env.find(env.page(), "Button", "Applied").opts.disabled)
  end)

  it("starts the dialog on the declared role when the post needs it", function()
    env.ns.character.profile.fields.role = { value = "Heal" }
    env.open("groups")
    env.press("Apply")
    assert.are.equal("heal", FakeKit.find(env.ns.Kit.fake.modal.stack, "Segmented").opts.value)
  end)

  it("tells what was refused, and why a button is off", function()
    env.ns.lfgService.deps.eligibility.apply = function()
      return false, "in_group"
    end
    env.open("groups")
    local apply = env.find(env.page(), "Button", "Apply")
    assert.is_true(apply.opts.disabled)
    assert.is_truthy(env.text():find("You are already in a group", 1, true))
    env.ns.lfgService.deps.eligibility.apply = function()
      return true
    end
    env.ns.UI.Redraw()
    env.press("Apply")
    env.ns.lfgBoard:Remove("Kaelis")
    FakeKit.press(modalButton("Send"))
    assert.are.equal("warning", env.banner().opts.kind)
    assert.are.equal("That group is gone", env.banner().opts.text)
  end)

  it("takes the application back and clears it", function()
    env.ns.lfgService:Apply("k-1", "tank")
    env.open("groups")
    env.press("Withdraw")
    assert.are.equal("withdraw", world.sent[#world.sent].payload.s)
    assert.is_nil(env.ns.lfgService:Status().application)
    assert.is_nil(env.text():find("Application sent", 1, true))
  end)

  it("shows how a finished application ended and closes it with Close", function()
    env.ns.lfgService:Apply("k-1", "tank")
    env.ns.lfgService:OnApply("Kaelis", { pid = "k-1", s = "decline", to = "Leader-Realm" })
    env.open("groups")
    assert.is_truthy(env.text():find("Kaelis declined your application", 1, true))
    env.press("Close")
    assert.is_nil(env.ns.lfgService:Status().application)
  end)

  describe("as a leader", function()
    local function post()
      env.open("groups")
      env.press("New group")
      local title = env.box("Deadmines")
      title.opts.onChange("Deadmines run")
      env.press("Post")
    end

    it("posts a group from the form and shows it, with a waiting note", function()
      env.open("groups")
      env.press("New group")
      assert.is_truthy(env.text():find("Say what you are going to do", 1, true))
      assert.is_true(env.find(env.page(), "Button", "Post").opts.disabled)
      env.box("Deadmines").opts.onChange("Deadmines run")
      assert.is_false(env.find(env.page(), "Button", "Post").opts.disabled)
      FakeKit.find(env.page(), "Segmented").opts.onChange("quest")
      env.press("Post")
      local status = env.ns.lfgService:Status()
      assert.are.equal("Deadmines run", status.post.title)
      assert.are.equal("quest", status.post.kind)
      assert.are.same({ tank = 1, heal = 1, dps = 1 }, status.post.needs)
      local text = env.text()
      assert.is_truthy(text:find("Your group", 1, true))
      assert.is_truthy(text:find("Posted. Applications will show up here.", 1, true))
      assert.is_true(env.find(env.page(), "Button", "New group").opts.disabled)
      assert.is_nil(text:find("Leader: Leader", 1, true))
    end)

    it("posts a raid of the chosen size and shows its member count", function()
      env.open("groups")
      env.press("New group")
      env.box("Deadmines").opts.onChange("Molten Core")
      assert.are.equal(1, #FakeKit.find_all(env.page(), "Segmented"))
      FakeKit.find(env.page(), "Segmented").opts.onChange("raid")
      local pickers = FakeKit.find_all(env.page(), "Segmented")
      assert.are.equal(2, #pickers)
      assert.is_truthy(env.text():find("Raid size", 1, true))
      pickers[2].opts.onChange(25)
      env.press("Post")
      local status = env.ns.lfgService:Status()
      assert.are.equal("raid", status.post.kind)
      assert.are.equal(25, status.post.size)
      assert.are.equal(24, status.post.remaining)
      local text = env.text()
      assert.is_truthy(text:find("Your group · Raid 25", 1, true))
      assert.is_truthy(text:find("1/25", 1, true))
    end)

    it("changes the roles with the steppers and never past the party", function()
      local function steps(sign)
        return FakeKit.find_all(env.page(), "Button", function(node)
          return node.opts.text == sign
        end)
      end
      env.open("groups")
      env.press("New group")
      -- The leader alone has four seats: one of each role is three of them.
      for _, node in ipairs(steps("+")) do
        assert.is_false(node.opts.disabled)
      end
      steps("+")[3].opts.onClick()
      for _, node in ipairs(steps("+")) do
        assert.is_true(node.opts.disabled)
      end
      steps("-")[1].opts.onClick()
      steps("-")[2].opts.onClick()
      steps("-")[3].opts.onClick()
      steps("-")[3].opts.onClick()
      for _, node in ipairs(steps("-")) do
        assert.is_true(node.opts.disabled)
      end
      assert.is_true(env.find(env.page(), "Button", "Post").opts.disabled)
    end)

    it("refuses an invalid level without sending anything and says why", function()
      env.open("groups")
      env.press("New group")
      env.box("Deadmines").opts.onChange("Deadmines run")
      local level = FakeKit.find_all(env.page(), "EditBox", function(node)
        return node.opts.numeric
      end)[1]
      level.opts.onChange("abc")
      assert.is_true(env.find(env.page(), "Button", "Post").opts.disabled)
      env.press("Post")
      assert.are.equal(0, #world.sent)
      assert.is_truthy(env.banner().opts.text:find("minimum level", 1, true))
      level.opts.onCommit()
      assert.is_truthy(env.text():find("The minimum level must be a number from 1 to 100", 1, true))
    end)

    it("cancels the form without posting", function()
      env.open("groups")
      env.press("New group")
      env.press("Cancel")
      assert.is_nil(env.ns.lfgService:Status().post)
      assert.is_truthy(env.text():find("Scarlet Monastery", 1, true))
    end)

    it("says why it cannot post, and sends nothing during a lockdown", function()
      world.locked = true
      env.open("groups")
      assert.is_truthy(env.text():find("Encounter in progress: nothing is sent until it ends.", 1, true))
      local new = env.find(env.page(), "Button", "New group")
      assert.is_true(new.opts.disabled)
      assert.are.equal("An encounter is in progress", new.opts.tooltip)
      assert.are.equal(0, #world.sent)
    end)

    it("lists an applicant, invites with the click and shows the invitation", function()
      post()
      env.ns.lfgService:OnApply("Ann-Realm", { pid = "mine-1", s = "apply", role = "tank", note = "|cffx" })
      env.ns.UI.Redraw()
      local text = env.text()
      assert.is_truthy(text:find("Ann-Realm", 1, true))
      assert.is_truthy(text:find("||cffx", 1, true))
      env.press("Invite")
      assert.are.same({ "Ann-Realm" }, world.invites)
      assert.is_truthy(env.text():find("Invitation sent...", 1, true))
      assert.are.equal("accept", world.sent[#world.sent].payload.s)
    end)

    it("declines an applicant", function()
      post()
      env.ns.lfgService:OnApply("Ann-Realm", { pid = "mine-1", s = "apply", role = "heal" })
      env.ns.UI.Redraw()
      env.press("Decline")
      assert.are.equal("decline", world.sent[#world.sent].payload.s)
      assert.are.equal(0, #env.ns.lfgService:Status().post.applicants)
    end)

    it("says why Invite is off", function()
      post()
      env.ns.lfgService:OnApply("Ann-Realm", { pid = "mine-1", s = "apply", role = "heal" })
      env.ns.lfgService.deps.eligibility.invite = function()
        return false, "combat"
      end
      env.ns.UI.Redraw()
      local invite = env.find(env.page(), "Button", "Invite")
      assert.is_true(invite.opts.disabled)
      assert.are.equal("You are in combat", invite.opts.tooltip)
    end)

    it("edits the own post and closes it", function()
      post()
      env.press("Edit")
      assert.is_truthy(env.text():find("Edit group", 1, true))
      assert.are.equal("Deadmines run", env.box("Deadmines").opts.text)
      env.box("Deadmines").opts.onChange("Renamed")
      env.press("Save")
      assert.are.equal("Renamed", env.ns.lfgService:Status().post.title)
      assert.are.equal(2, env.ns.lfgService:Status().post.rev)
      env.press("Close group")
      assert.is_nil(env.ns.lfgService:Status().post)
      assert.is_truthy(env.text():find("Scarlet Monastery", 1, true))
    end)

    it("shows a group that closed by itself and removes the note with a click", function()
      post()
      env.ns.lfgService.deps.isRaid = function()
        return true
      end
      env.ns.lfgService.deps.groupSize = function()
        return 2
      end
      env.ns.lfgService:OnGroupChanged()
      env.ns.UI.Redraw()
      assert.is_truthy(env.text():find("Group closed", 1, true))
      env.press("Remove")
      assert.is_nil(env.text():find("Group closed", 1, true))
    end)
  end)

  describe("the sidebar count", function()
    local function badges()
      local found = {}
      for _, group in ipairs(sidebarNode().opts.groups) do
        for _, item in ipairs(group.items) do
          if item.badge then
            found[item.value] = item.badge
          end
        end
      end
      return found
    end

    it("counts the open groups when the sidebar is built, and no other item has a count", function()
      env.open("home")
      assert.are.same({ groups = "1" }, badges())
    end)

    it("shows nothing at zero", function()
      env.ns.lfgBoard:Remove("Kaelis")
      env.open("home")
      assert.are.same({}, badges())
    end)

    it("follows the board on every tab, without building the sidebar again", function()
      env.open("professions")
      local sidebar = sidebarNode()
      local updates = {}
      rawset(sidebar, "SetItemBadge", function(_, value, text)
        updates[#updates + 1] = { value, text }
      end)
      env.ns.lfgBoard:Apply("Belisa", {
        pid = "b-1",
        rev = 1,
        s = "open",
        kind = "quest",
        title = "Elites",
        needs = { tank = 0, heal = 0, dps = 2 },
        members = 1,
      })
      env.ns.UI.LfgChanged()
      assert.are.same({ { "groups", "2" } }, updates)
      assert.are.equal(sidebar, sidebarNode())
      env.ns.lfgBoard:Remove("Kaelis")
      env.ns.lfgBoard:Remove("Belisa")
      env.ns.UI.LfgChanged()
      assert.are.same({ "groups", nil }, updates[2])
    end)

    it("does nothing while the window is closed", function()
      env.open("home")
      local sidebar = sidebarNode()
      local count = 0
      rawset(sidebar, "SetItemBadge", function()
        count = count + 1
      end)
      env.ns.UI.Toggle()
      env.ns.UI.LfgChanged()
      assert.are.equal(0, count)
    end)

    it("counts the own post too", function()
      env.open("home")
      env.ns.lfgService:Post({ kind = "quest", title = "Mine", needs = { dps = 2 } })
      env.ns.UI.SelectTab("pvp")
      assert.are.same({ groups = "2" }, badges())
    end)
  end)

  it("redraws when the groups change, at most once per interval, and only on the tabs that show them", function()
    env.open("groups")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.LfgChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    count = #env.ns.Kit.fake.nodes
    env.timers = {}
    env.ns.UI.LfgChanged()
    env.ns.UI.LfgChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
    assert.are.equal(1, #env.timers)
    env.ns.UI.SelectTab("professions")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.LfgChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)

  it("shows the open groups on Home with a link to the tab, and nothing before the feature starts", function()
    env.open("home")
    assert.is_truthy(env.text():find("1 open group", 1, true))
    env.press("Open Groups")
    assert.are.equal("groups", env.ns.UI.CurrentTab())
    env.ns.lfgBoard = nil
    env.open("home")
    assert.is_nil(env.text():find("open group", 1, true))
  end)

  it("redraws Home when the groups change, since Home shows them", function()
    env.open("home")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.LfgChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
  end)
end)

describe("Window redraws and closing", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("closes the menus and pickers of the page on a redraw, but not the settings or a modal", function()
    env = build("GM")
    env.open("home")
    local Kit = env.ns.Kit
    local UI = env.ns.UI

    Kit.fake.menu = { items = {} }
    Kit.Popup.Get(1):Open(nil, 100, function() end, {})
    UI.Redraw()
    assert.is_nil(Kit.fake.menu)
    assert.is_false(Kit.Popup.Get(1):IsOpen())

    UI.ToggleSettings()
    Kit.Modal.Open({ build = function() end })
    UI.Redraw()
    assert.is_true(Kit.Popup.Get(1):IsOpen())
    assert.is_true(Kit.Modal.IsOpen())
  end)

  it(
    "holds back a redraw that came from the guild while an edit box has the keyboard, and runs it afterwards",
    function()
      env = build("GM")
      env.open("pvp")
      env.ns.Kit.fake.editFocus = true
      local count = #env.ns.Kit.fake.nodes
      env.timers = {}
      env.ns.UI.PvPChanged()
      assert.are.equal(count, #env.ns.Kit.fake.nodes)
      assert.are.equal(1, #env.timers)

      -- Still typing: it waits again, once.
      env.timers[1]()
      assert.are.equal(count, #env.ns.Kit.fake.nodes)
      assert.are.equal(2, #env.timers)

      env.ns.Kit.fake.editFocus = nil
      env.timers[2]()
      assert.is_true(#env.ns.Kit.fake.nodes > count)
    end
  )

  it("still redraws at once what the player asked for, committing the box that has the keyboard first", function()
    env = build("GM")
    env.open("pvp")
    env.ns.Kit.fake.editFocus = true
    local count = #env.ns.Kit.fake.nodes
    local commits = env.ns.Kit.fake.commits or 0
    env.ns.UI.Redraw()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    assert.are.equal(commits + 1, env.ns.Kit.fake.commits)
  end)

  it("fans the loot changes out at most once per interval", function()
    env = build("GM")
    local calls = 0
    env.ns.UI.lootListeners = {
      function()
        calls = calls + 1
      end,
    }
    env.timers = {}
    env.ns.UI.LootChanged()
    env.ns.UI.LootChanged()
    env.ns.UI.LootChanged()
    assert.are.equal(1, calls)
    assert.are.equal(1, #env.timers)
    env.ns.Platform.Now = function()
      return 5
    end
    env.timers[1]()
    assert.are.equal(2, calls)
  end)

  it("forgets the banner and the armed action when the window closes", function()
    env = build("GM")
    env.open("home")
    env.ns.UI.Arm("delete-everything")
    env.ns.UI.Notify("success", "stale-banner")
    assert.is_truthy(env.text():find("stale-banner", 1, true))
    env.ns.UI.Toggle()
    assert.is_false(env.ns.UI.IsArmed("delete-everything"))
    env.ns.UI.Toggle()
    assert.is_nil(env.text():find("stale-banner", 1, true))
  end)

  it("treats a tab that is not visible any more like a change of tab", function()
    env = build("Member")
    env.forceTabs = true
    env.open("rules")
    env.forceTabs = false
    env.ns.UI.Arm("delete-everything")
    env.ns.UI.Notify("danger", "stale-banner")
    env.registered = {}
    env.ns.UI.RostersChanged()
    assert.are.equal("home", env.ns.UI.CurrentTab())
    assert.is_false(env.ns.UI.IsArmed("delete-everything"))
    assert.is_nil(env.text():find("stale-banner", 1, true))
    assert.is_true(env.registered.PLAYER_LEVEL_UP)
  end)

  it("stops the sync pill ticker while the window is closed and starts it again on opening", function()
    env = build("GM")
    local tickers = {}
    _G.C_Timer.NewTicker = function(_, fn)
      local ticker = {
        fn = fn,
        Cancel = function(self)
          self.cancelled = true
        end,
      }
      tickers[#tickers + 1] = ticker
      return ticker
    end
    env.open("home")
    assert.are.equal(1, #tickers)
    env.ns.UI.Toggle()
    assert.is_true(tickers[1].cancelled)
    env.ns.UI.Toggle()
    assert.are.equal(2, #tickers)
    assert.is_nil(tickers[2].cancelled)
  end)
end)

describe("Window smoke test: tab regressions", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("shows the reason of an unmapped delete failure in Rules instead of raising", function()
    env = build("GM")
    env.ns.ViewModel.WithoutRule = function()
      return nil, "mystery_reason"
    end
    env.open("rules")
    -- The first click arms the delete, the second one (the same button, now a confirm) deletes.
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    assert.is_truthy(env.banner().opts.text:find("mystery_reason", 1, true))
  end)

  it("does not raise on a PvP reset when there is no comm, and reports it", function()
    env = build("GM")
    env.ns.db.global.pvpStats = { ["Ann-Realm"] = { honor = { world = 3, bg = 0 }, updatedAt = 900, rev = 1 } }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("stats")
    FakeKit.find(env.page(), "Segmented").opts.onChange("ranking")
    env.open("pvpadmin")
    FakeKit.find(env.page(), "Segmented").opts.onChange("season")
    for _, d in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
      if d.opts.placeholder == "Member" then
        d.opts.onChange("Ann-Realm")
      end
    end
    env.press("Reset PvP counters")
    env.ns.comm = nil
    env.press("Confirm: reset")
    assert.is_truthy(env.banner().opts.text:find("Not reset", 1, true))
    assert.are.same({}, env.sent)
  end)

  it("keeps the edit open when the save fails and closes it on success", function()
    env = build("Member")
    env.ns.db.global.blacklist.ann = {
      name = "Ann",
      reason = "ninja",
      addedBy = "Leader-Realm",
      addedAt = 100,
      rev = 1,
      updatedAt = 1,
    }
    env.open("blacklist")
    env.tableRows()[1].cells.edit.opts.onClick()
    env.tableRows()[1].cells.reason.opts.onChange("")
    env.tableRows()[1].cells.edit.opts.onClick()
    assert.are.equal("danger", env.banner().opts.kind)
    assert.are.equal("edit", env.tableRows()[1].cells.reason.widget)
    env.tableRows()[1].cells.reason.opts.onChange("still ninja")
    env.tableRows()[1].cells.edit.opts.onClick()
    assert.are.equal("success", env.banner().opts.kind)
    assert.are.equal("still ninja", env.ns.db.global.blacklist.ann.reason)
    local reason = env.tableRows()[1].cells.reason
    assert.are_not.equal("edit", type(reason) == "table" and reason.widget or nil)
  end)

  it("refills a region by clearing it, drawing it again and relaying out", function()
    env = build("GM")
    local order = {}
    local region = {
      Clear = function()
        order[#order + 1] = "clear"
      end,
    }
    env.ns.UI.Relayout = function()
      order[#order + 1] = "relayout"
    end
    env.ns.UI.Refill(region, function(drawn)
      assert.are.equal(region, drawn)
      order[#order + 1] = "draw"
    end)
    assert.are.same({ "clear", "draw", "relayout" }, order)
  end)
end)

describe("Window smoke test: Intel", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  -- The window for `rank` with the real Intel lists over a fake clock and a fake client.
  local function intel_env(rank)
    env = build(rank or "Member")
    local ns = env.ns
    env.clock = 1000
    env.said = {}
    env.nameplates = true
    env.combat = false
    env.map = 1429
    local platform = ns.Platform
    platform.EnemyNameplatesEnabled = function()
      return env.nameplates
    end
    platform.EnableEnemyNameplates = function()
      env.enabled = (env.enabled or 0) + 1
      env.nameplates = true
      return true
    end
    platform.IsInCombat = function()
      return env.combat
    end
    platform.GetPlayerMapId = function()
      return env.map
    end
    platform.GetMapName = function(map)
      return map == 1429 and "Elwynn Forest" or nil
    end
    platform.GroupDistribution = function()
      return nil
    end
    platform.IsInGuild = function()
      return true
    end
    ns.db.global.intel = { players = {}, kos = {}, ignore = {}, zones = {} }
    ns.db.global.guildKos = {}
    ns.intel = ns.IntelService.New({
      intel = ns.db.global.intel,
      guildKos = ns.db.global.guildKos,
      settings = function()
        return ns.Settings.Intel(ns.db)
      end,
      now = function()
        return env.clock
      end,
      wall = function()
        return 1000
      end,
    })
    ns.IntelNearby = function()
      return ns.intel:Nearby(env.clock)
    end
    ns.intelDirectory = {
      Remove = function() end,
      List = function()
        return {}
      end,
    }
    ns.intelAlerts = {
      AnnounceNow = function(_, name, channel)
        env.announced = name .. ":" .. channel
        if channel == "party" then
          return false, "no_group"
        end
        return true
      end,
    }
    ns.intelCommands = ns.IntelCommands.New({
      service = ns.intel,
      alerts = ns.intelAlerts,
      directory = ns.intelDirectory,
      platform = platform,
      guildKos = ns.db.global.guildKos,
      tombstones = ns.db.global.sync.tombstones,
      comm = function()
        return nil
      end,
      onChange = function() end,
      settings = function()
        return ns.Settings.Intel(ns.db)
      end,
      globals = function()
        return env.globals or {}
      end,
    })
    return ns
  end

  local function seen(ns, name, extra)
    local details = { name = name, class = "MAGE", race = "HUMAN", level = 60, guild = "Wolves" }
    for key, value in pairs(extra or {}) do
      details[key] = value
    end
    return ns.intel:OnSeen(details, { map = 1429, x = 10, y = 20 })
  end

  local function view(name)
    local page = env.page()
    local segmented = FakeKit.find_all(page, "Segmented")[1]
    segmented.opts.onChange(name)
    return env.page()
  end

  local function table_rows(page, index)
    return FakeKit.find_all(page, "Table")[index or 1].opts.rows
  end

  it("is an Intel sub-tab of PvP, and says so when Intel is not running", function()
    env = build("Member")
    env.ns.UI.OpenIntelTab(nil)
    assert.are.equal("pvp", env.ns.UI.CurrentTab())
    assert.is_truthy(env.text():find("Intel is not running", 1, true))
    local strip = FakeKit.find(env.page(), "TabStrip")
    assert.are.equal("intel", strip.opts.value)
    assert.is_false(env.ns.UI.IntelShown() == false)
  end)

  it("lists who is nearby and opens the menu of a row", function()
    local ns = intel_env()
    seen(ns, "Ann")
    seen(ns, "Bob", { guild = "Rats" })
    ns.UI.OpenIntelTab("nearby")
    local page = env.page()
    local rows = table_rows(page)
    assert.are.equal(2, #rows)
    assert.are.equal("Ann", rows[1].cells.name.text)
    assert.are.equal("<Wolves>", rows[1].cells.guild.text)
    assert.is_truthy(env.text():find("2 nearby", 1, true))

    rows[1].onClick({ frame = "row" })
    local menu = ns.Kit.fake.menu
    assert.are.equal("row", menu.anchor)
    menu.onSelect("kos")
    assert.are.equal("personal", ns.intel:IsKos("Ann"))
    assert.is_truthy(env.banner().opts.text:find("added Ann", 1, true))
    -- The menu runs from the tab too: announcing, and refusing when there is nobody to announce to.
    table_rows(env.page())[1].onClick({ frame = "row" })
    ns.Kit.fake.menu.onSelect("say:guild")
    assert.are.equal("Ann:guild", env.announced)
    table_rows(env.page())[1].onClick({ frame = "row" })
    ns.Kit.fake.menu.onSelect("say:party")
    assert.are.equal("danger", env.banner().opts.kind)
    table_rows(env.page())[1].onClick({ frame = "row" })
    ns.Kit.fake.menu.onSelect("remove")
    assert.are.equal(1, #table_rows(env.page()))
  end)

  it("clears who is nearby from a button", function()
    local ns = intel_env()
    seen(ns, "Ann")
    ns.UI.OpenIntelTab("nearby")
    env.press("Clear the list")
    assert.are.equal(0, #table_rows(env.page()))
  end)

  it("draws every view, for every rank, with and without data", function()
    for _, rank in ipairs({ "GM", "CoGM", "Member", "Norost" }) do
      local ns = intel_env(rank)
      for round = 1, 2 do
        ns.UI.OpenIntelTab("nearby")
        for _, item in ipairs(ns.ViewModel.IntelViews()) do
          view(item.value)
          assert.is_truthy(env.page(), rank .. " " .. item.value)
        end
        seen(ns, "Ann")
        ns.intel:AddKos({ name = "Ann" })
        ns.db.global.guildKos.zed = { name = "Zed", category = "gank", addedBy = "Boss-Realm", rev = 1, addedAt = 5 }
        ns.intel:AddIgnore("Una")
        assert.is_truthy(round)
      end
      pcall(env.close)
    end
  end)

  it("shows the players of the last hour", function()
    local ns = intel_env()
    seen(ns, "Ann")
    ns.UI.OpenIntelTab("hour")
    local rows = table_rows(env.page())
    assert.are.equal("Ann", rows[1].cells.name.text)
    assert.are.equal("0s", rows[1].cells.age.text)
  end)

  it("warns that the nameplates are off, with a button when it is allowed", function()
    local ns = intel_env()
    env.nameplates = false
    ns.UI.OpenIntelTab("nearby")
    assert.are.equal("warning", env.banner().opts.kind)
    env.press("Turn on enemy nameplates")
    assert.are.equal(1, env.enabled)
    assert.is_nil(FakeKit.find(env.page(), "Button", "Turn on enemy nameplates"))

    env.nameplates, env.combat = false, true
    ns.UI.Redraw()
    assert.are.equal("warning", env.banner().opts.kind)
    assert.is_nil(FakeKit.find(env.page(), "Button", "Turn on enemy nameplates"))
  end)

  describe("the settings card", function()
    local function find_switch(label)
      return assert(FakeKit.find(env.page(), "Switch", label), label)
    end

    it("opens from the command and from its button", function()
      local ns = intel_env()
      ns.UI.IntelConfig()
      assert.is_truthy(FakeKit.find(env.page(), "Card", "Detection"))
      env.press("Hide settings")
      assert.is_nil(FakeKit.find(env.page(), "Card", "Detection"))
      env.press("Settings")
      assert.is_truthy(FakeKit.find(env.page(), "Card", "Alerts"))
    end)

    it("changes the switches, the choices, the races and the zone", function()
      local ns = intel_env()
      ns.UI.IntelConfig()
      local settings = ns.Settings.Intel(ns.db)
      find_switch("Any new enemy").opts.onChange(true)
      assert.is_true(settings.alertNew)
      find_switch("Share sightings with the guild").opts.onChange(false)
      assert.is_false(settings.share)
      find_switch("Skip this zone").opts.onChange(true)
      assert.is_true(settings.excludedZones[1429])
      assert.are.equal("Elwynn Forest", FakeKit.find(env.page(), "Switch", "Skip this zone").opts.description)

      local dropdowns = FakeKit.find_all(env.page(), "Dropdown")
      local by_value = {}
      for _, dropdown in ipairs(dropdowns) do
        by_value[dropdown.opts.items[1].value] = dropdown
      end
      by_value[0].opts.onChange(10)
      assert.are.equal(10, settings.removeMinutes)
      by_value.window.opts.onChange("error")
      assert.are.equal("error", settings.warnTarget)
      local chip = FakeKit.find(env.page(), "Chip", "Orc")
      chip.opts.onToggle(true)
      assert.is_true(settings.alertRaces.ORC)
      -- The skipped zone is listed by name and let go by switching its chip off.
      FakeKit.find(env.page(), "Chip", "Elwynn Forest").opts.onToggle(false)
      assert.is_nil(settings.excludedZones[1429])
      assert.is_nil(FakeKit.find(env.page(), "Chip", "Elwynn Forest"))
    end)

    it("refreshes the window, the button and the pins after a change", function()
      local ns = intel_env()
      local calls = {}
      ns.IntelWindow = {
        Sync = function()
          calls[#calls + 1] = "sync"
        end,
        Refresh = function()
          calls[#calls + 1] = "refresh"
        end,
      }
      ns.IntelTargetButton = {
        Refresh = function()
          calls[#calls + 1] = "button"
        end,
      }
      ns.intelMapPins = {
        Request = function()
          calls[#calls + 1] = "pins"
        end,
      }
      ns.UI.IntelConfig()
      find_switch("Lock the Intel window").opts.onChange(true)
      assert.are.same({ "sync", "refresh", "button", "pins" }, calls)
    end)

    it("refuses to change the rows of the window in combat", function()
      local ns = intel_env()
      ns.UI.IntelConfig()
      env.combat = true
      local rows
      for _, dropdown in ipairs(FakeKit.find_all(env.page(), "Dropdown")) do
        if dropdown.opts.items[1].value == 4 then
          rows = dropdown
        end
      end
      rows.opts.onChange(12)
      assert.are.equal("danger", env.banner().opts.kind)
      assert.is_truthy(env.banner().opts.text:find("combat", 1, true))
      assert.are.equal(8, ns.Settings.Intel(ns.db).window.rows)
    end)
  end)

  describe("Kill on Sight", function()
    it("adds to the personal list and to the guild list from the form", function()
      local ns = intel_env()
      ns.UI.OpenIntelTab("kos")
      FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Bob")
      env.press("Add to my list")
      assert.is_table(ns.db.global.intel.kos.bob)
      assert.are.equal("success", env.banner().opts.kind)
      -- The form is empty again after an add.
      FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Eve")
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("camp")
      FakeKit.find_all(env.page(), "EditBox")[2].opts.onChange("camps")
      env.press("Add to the guild list")
      assert.are.equal("camp", ns.db.global.guildKos.eve.category)
      assert.are.equal("camps", ns.db.global.guildKos.eve.reason)
      -- A name that is not a name stays in the form and is reported.
      FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("")
      env.press("Add to my list")
      assert.are.equal("danger", env.banner().opts.kind)
    end)

    it("edits, promotes and removes with two clicks", function()
      local ns = intel_env()
      ns.intel:AddKos({ name = "Bob", category = "gank", reason = "ganked me" })
      ns.UI.OpenIntelTab("kos")
      local row = table_rows(env.page())[1]
      assert.are.equal("Bob", row.cells.name.text)
      assert.are.equal("Gank", row.cells.category)

      row.cells.edit.opts.onClick()
      row = table_rows(env.page())[1]
      assert.are.equal("dropdown", row.cells.category.widget)
      row.cells.category.opts.onChange("corpse")
      row.cells.reason.opts.onChange("camps my corpse")
      row.cells.edit.opts.onClick()
      assert.are.equal("corpse", ns.db.global.intel.kos.bob.category)
      assert.are.equal("camps my corpse", ns.db.global.intel.kos.bob.reason)

      -- Cancel leaves the entry as it is.
      row = table_rows(env.page())[1]
      row.cells.edit.opts.onClick()
      table_rows(env.page())[1].cells.remove.opts.onClick()
      assert.are.equal("corpse", ns.db.global.intel.kos.bob.category)

      -- Share it with the guild.
      table_rows(env.page())[1].cells.promote.opts.onClick()
      assert.are.equal("corpse", ns.db.global.guildKos.bob.category)

      -- Remove: the first click arms, the second removes.
      local before = table_rows(env.page())
      assert.are.equal(2, #before)
      before[1].cells.remove.opts.onClick()
      table_rows(env.page())[1].cells.remove.opts.onClick()
      assert.is_nil(ns.db.global.intel.kos.bob)
      -- The guild entry was added by this player: he can remove it too.
      table_rows(env.page())[1].cells.remove.opts.onClick()
      table_rows(env.page())[1].cells.remove.opts.onClick()
      assert.is_nil(ns.db.global.guildKos.bob)
      assert.are.equal(0, #table_rows(env.page()))
    end)

    it("edits an entry of the guild list as the officer", function()
      local ns = intel_env("GM")
      ns.db.global.guildKos.zed = { name = "Zed", category = "gank", addedBy = "Other-Realm", addedAt = 5, rev = 1 }
      ns.UI.OpenIntelTab("kos")
      table_rows(env.page())[1].cells.edit.opts.onClick()
      local row = table_rows(env.page())[1]
      row.cells.category.opts.onChange("insult")
      row.cells.reason.opts.onEnter()
      assert.are.equal("insult", ns.db.global.guildKos.zed.category)
    end)

    it("gives a member no buttons on the guild entry of somebody else", function()
      local ns = intel_env("Member")
      ns.db.global.guildKos.zed = { name = "Zed", category = "gank", addedBy = "Other-Realm", addedAt = 5, rev = 1 }
      ns.UI.OpenIntelTab("kos")
      local row = table_rows(env.page())[1]
      assert.are.equal("", row.cells.edit)
      assert.are.equal("", row.cells.remove)
      assert.are.equal("", row.cells.promote)
    end)

    it("imports names from the box and the lists of Spy", function()
      local ns = intel_env()
      ns.UI.OpenIntelTab("kos")
      FakeKit.find(env.page(), "TextArea").opts.onChange("Bob, Eve")
      FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("ignore")
      env.press("Import")
      assert.is_table(ns.db.global.intel.ignore.bob)
      assert.is_truthy(env.banner().opts.text:find("imported 2", 1, true))
      env.press("Import from Spy")
      assert.is_truthy(env.banner().opts.text:find("were not found", 1, true))
      env.globals = { SpyPerCharDB = { KOSData = { Cid = 1 } } }
      env.press("Import from Spy")
      assert.is_table(ns.db.global.intel.kos.cid)
    end)
  end)

  it("lists and releases the ignored players", function()
    local ns = intel_env()
    ns.intel:AddIgnore("Una")
    ns.UI.OpenIntelTab("ignored")
    local row = table_rows(env.page())[1]
    assert.are.equal("Una", row.cells.name.text)
    row.cells.remove.opts.onClick()
    assert.is_false(ns.intel:IsIgnored("Una"))
  end)

  describe("the statistics", function()
    it("sorts, filters and searches", function()
      local ns = intel_env()
      seen(ns, "Ann", { level = 50 })
      seen(ns, "Bob", { level = 60, guild = "Rats" })
      ns.intel:OnWin("Bob")
      ns.intel:OnLoss("Ann")
      ns.intel:AddKos({ name = "Ann", category = "gank" })
      ns.UI.OpenIntelTab("stats")
      local page = env.page()
      assert.are.equal("Honourable kills", FakeKit.find(page, "StatGrid").opts.stats[4].caption)
      local rows = table_rows(page)
      assert.are.equal(2, #rows)

      local tbl = FakeKit.find_all(page, "Table")[1]
      tbl.opts.onSort("level")
      assert.are.equal("level", FakeKit.find_all(env.page(), "Table")[1].opts.sort.key)
      assert.are.equal("Bob", table_rows(env.page())[1].cells.name.text)
      FakeKit.find_all(env.page(), "Table")[1].opts.onSort("level")
      assert.are.equal("Ann", table_rows(env.page())[1].cells.name.text)

      FakeKit.find(env.page(), "Chip", "Kill on Sight").opts.onToggle(true)
      assert.are.equal(1, #table_rows(env.page()))
      FakeKit.find(env.page(), "Chip", "Kill on Sight").opts.onToggle(false)
      FakeKit.find(env.page(), "Chip", "With wins").opts.onToggle(true)
      assert.are.equal("Bob", table_rows(env.page())[1].cells.name.text)
      FakeKit.find(env.page(), "Chip", "With wins").opts.onToggle(false)
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("gank")
      assert.are.equal("Ann", table_rows(env.page())[1].cells.name.text)
      FakeKit.find_all(env.page(), "Dropdown")[1].opts.onChange("any")

      -- A row opens the menu, and a search redraws the table in place.
      table_rows(env.page())[1].onClick({ frame = "row" })
      assert.are.equal("row", ns.Kit.fake.menu.anchor)
      env.box("Search by name or guild").opts.onChange("rat", true)
      env.box("Search by name or guild").opts.onChange("ignored while it is not typed", false)
    end)

    it("takes the honourable kills from the tracker, and shows a dash without them", function()
      local ns = intel_env()
      ns.pvpTracker = nil
      ns.UI.OpenIntelTab("stats")
      local grid = FakeKit.find(env.page(), "StatGrid")
      assert.are.equal("-", grid.opts.stats[4].value)
    end)

    it("cuts the table when there are too many players", function()
      local ns = intel_env()
      for index = 1, ns.ViewModel.INTEL_STATS_LIMIT + 3 do
        ns.db.global.intel.players["p" .. index] = {
          name = "P" .. index,
          lastSeen = 900,
          wins = 0,
          losses = 0,
          seen = 1,
        }
      end
      ns.UI.OpenIntelTab("stats")
      assert.is_truthy(env.text():find("Showing the first 200 of 203 players.", 1, true))
    end)
  end)

  it("draws the report of the session and of the season", function()
    local ns = intel_env()
    seen(ns, "Ann")
    ns.intel:OnWin("Ann")
    ns.UI.OpenIntelTab("report")
    assert.is_truthy(env.text():find("Intel report of this session", 1, true))
    assert.is_truthy(env.text():find("no PvP season is running.", 1, true))
    ns.pvpSeason = {
      ActiveSeason = function()
        return { name = "S1", startsAt = 0, endsAt = 10 ^ 9 }
      end,
    }
    ns.UI.Redraw()
    assert.is_truthy(env.text():find("Intel report of the season 'S1'", 1, true))
  end)

  describe("what changes the lists", function()
    it("redraws the sub-tab, the window, the button and the pins, at most once per interval", function()
      local ns = intel_env()
      local calls = {}
      ns.IntelWindow = {
        Sync = function() end,
        Refresh = function()
          calls[#calls + 1] = "window"
        end,
      }
      ns.IntelTargetButton = {
        Refresh = function()
          calls[#calls + 1] = "button"
        end,
      }
      ns.intelMapPins = {
        Request = function()
          calls[#calls + 1] = "pins"
        end,
      }
      ns.UI.OpenIntelTab("nearby")
      local before = #ns.Kit.fake.nodes
      ns.UI.IntelChanged()
      assert.are.same({ "window", "button", "pins" }, calls)
      assert.is_true(#ns.Kit.fake.nodes > before)

      -- A second call inside the interval waits for its turn.
      ns.UI.IntelChanged()
      ns.UI.IntelChanged()
      assert.are.same({ "window", "button", "pins" }, calls)
      assert.are.equal(1, #env.timers)
    end)

    it("draws the views that show ages as time passes, and the others only when something changed", function()
      local ns = intel_env()
      ns.UI.OpenIntelTab("stats")
      local before = #ns.Kit.fake.nodes
      ns.UI.IntelChanged(true)
      assert.are.equal(before, #ns.Kit.fake.nodes)
      env.clock = env.clock + 5
      ns.UI.OpenIntelTab("nearby")
      before = #ns.Kit.fake.nodes
      ns.Platform.Now = function()
        return 100
      end
      ns.UI.IntelChanged(true)
      assert.is_true(#ns.Kit.fake.nodes > before)
      ns.UI.OpenIntelTab("stats")
      ns.Platform.Now = function()
        return 200
      end
      before = #ns.Kit.fake.nodes
      ns.UI.IntelChanged()
      assert.is_true(#ns.Kit.fake.nodes > before)
    end)

    it("does not take an open menu away, and draws the sub-tab when the menu is closed", function()
      local ns = intel_env()
      seen(ns, "Ann")
      ns.UI.OpenIntelTab("nearby")
      local popup = ns.Kit.Popup.Get(2)
      popup.open = true
      ns.Platform.Now = function()
        return 100
      end
      local before = #ns.Kit.fake.nodes
      ns.UI.IntelChanged()
      assert.are.equal(before, #ns.Kit.fake.nodes)
      popup.open = false
      ns.Platform.Now = function()
        return 200
      end
      ns.UI.IntelChanged(true)
      assert.is_true(#ns.Kit.fake.nodes > before)
    end)

    it("does not draw the sub-tab when another tab is on screen", function()
      local ns = intel_env()
      ns.UI.OpenTab("home")
      local before = #ns.Kit.fake.nodes
      ns.UI.IntelChanged()
      assert.are.equal(before, #ns.Kit.fake.nodes)
      ns.Platform.Now = function()
        return 500
      end
      ns.UI.IntelChanged(true)
      assert.are.equal(before, #ns.Kit.fake.nodes)
    end)

    it("keeps working with the main window closed and with parts that raise", function()
      local ns = intel_env()
      ns.IntelWindow = {
        Sync = function()
          error("window")
        end,
        Refresh = function()
          error("window")
        end,
      }
      ns.IntelTargetButton = {
        Refresh = function()
          error("button")
        end,
      }
      ns.intelMapPins = {
        Request = function()
          error("pins")
        end,
      }
      assert.is_false(ns.UI.IsOpen())
      assert.has_no.errors(function()
        ns.UI.IntelChanged()
      end)
    end)

    it("hands the window commands to the window", function()
      local ns = intel_env()
      local calls = {}
      ns.IntelWindow = {
        Show = function()
          calls[#calls + 1] = "show"
        end,
        Hide = function()
          calls[#calls + 1] = "hide"
        end,
      }
      ns.UI.IntelShow()
      ns.UI.IntelHide()
      ns.UI.IntelStats()
      assert.are.same({ "show", "hide" }, calls)
      assert.are.equal("stats", FakeKit.find_all(env.page(), "Segmented")[1].opts.value)
      ns.IntelWindow = nil
      assert.has_no.errors(function()
        ns.UI.IntelShow()
        ns.UI.IntelHide()
      end)
    end)
  end)
end)

describe("Announcements tabs", function()
  local env

  local function publish(fields)
    return assert(env.ns.announcements:Publish(fields))
  end

  -- Draws the editor as the guild master.
  local function editor()
    env = build("GM")
    return env.open("announceadmin")
  end

  local function sidebarNode()
    local found
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        found = node
      end
    end
    return found
  end

  local function stored(id, overrides)
    local a = {
      id = id,
      title = "Title " .. id,
      body = "",
      author = "Gm-Realm",
      createdAt = 900,
      updatedAt = 900,
      rev = 1,
      popup = false,
      popupRev = 1,
      pinned = false,
    }
    for key, value in pairs(overrides or {}) do
      a[key] = value
    end
    env.ns.db.global.announcements.items[id] = a
    return a
  end

  after_each(function()
    pcall(env.close)
  end)

  describe("the board", function()
    it("says there is nothing yet", function()
      env = build("Member")
      env.open("announcements")
      assert.is_truthy(env.text():find("No announcements yet", 1, true))
    end)

    it("lists the announcements, pinned first, with who and what, and nothing to edit", function()
      env = build("Member")
      stored("plain", { title = "Plain one", body = "Second body", createdAt = 950 })
      stored("pinned", { title = "Pinned one", body = "First body", pinned = true })
      env.open("announcements")
      local text = env.text()
      assert.is_truthy(text:find("Pinned one", 1, true))
      assert.is_truthy(text:find("Plain one", 1, true))
      assert.is_truthy(text:find("First body", 1, true))
      assert.is_truthy(text:find("Gm-Realm", 1, true))
      assert.is_true(text:find("Pinned one", 1, true) < text:find("Plain one", 1, true))
      assert.is_nil(env.find(env.page(), "Button", "Publish"))
      assert.is_nil(env.find(env.page(), "Button", "Edit"))
      assert.is_nil(env.find(env.page(), "Button", "Delete"))
    end)

    it("hides an announcement that expired", function()
      env = build("Member")
      stored("gone", { title = "Gone", expiresAt = 999 })
      env.open("announcements")
      assert.is_nil(env.text():find("Gone", 1, true))
    end)

    it("escapes what was received", function()
      env = build("Member")
      stored("x", { title = "T|cffff0000", body = "B|r", author = "A|n" })
      env.open("announcements")
      local text = env.text()
      assert.is_truthy(text:find("T||cffff0000", 1, true))
      assert.is_nil(text:find("T|cffff0000", 1, true))
    end)

    it("opening it reads everything, and the count of the sidebar goes", function()
      env = build("Member")
      stored("x")
      assert.are.equal(1, env.ns.announcements:Unread())
      env.open("home")
      local updates = {}
      rawset(sidebarNode(), "SetItemBadge", function(_, value, text)
        updates[#updates + 1] = { value, text }
      end)
      env.ns.UI.AnnouncementsChanged()
      assert.are.same({ { "announcements", "1" } }, updates)
      env.ns.UI.SelectTab("announcements")
      assert.are.equal(0, env.ns.announcements:Unread())
    end)

    it("says it is not available before the service starts", function()
      env = build("Member")
      env.ns.announcements = nil
      env.open("announcements")
      assert.is_truthy(env.text():find("Announcements are not available", 1, true))
    end)
  end)

  describe("the editor", function()
    it("cannot publish without a title, and says why", function()
      editor()
      local button = env.find(env.page(), "Button", "Publish")
      assert.is_true(button.opts.disabled)
      assert.are.equal("The title is not valid", button.opts.tooltip)
    end)

    it("publishes with the popup on by default, and clears the form", function()
      editor()
      env.find(env.page(), "EditBox").opts.onChange("Raid night")
      env.find(env.page(), "TextArea").opts.onChange("Bring flasks\nBe on time")
      env.press("Publish")
      local items = env.ns.db.global.announcements.items
      local id = next(items)
      assert.are.equal("Raid night", items[id].title)
      assert.are.equal("Bring flasks\nBe on time", items[id].body)
      assert.is_true(items[id].popup)
      assert.is_false(items[id].pinned)
      assert.are.same({ "ANN:" .. id }, env.announced)
      assert.are.equal("success", env.banner().opts.kind)
      assert.are.equal("", env.find(env.page(), "EditBox").opts.text)
      assert.is_truthy(env.text():find("Published: 1 of 30", 1, true))
    end)

    it("publishes with the switches and expiry the guild master chose", function()
      editor()
      env.find(env.page(), "EditBox").opts.onChange("Short")
      env.find(env.page(), "Switch", "Send popup").opts.onChange(false)
      env.find(env.page(), "Switch", "Pin").opts.onChange(true)
      env.find(env.page(), "Dropdown").opts.onChange("1d")
      env.press("Publish")
      local items = env.ns.db.global.announcements.items
      local a = items[next(items)]
      assert.is_false(a.popup)
      assert.is_true(a.pinned)
      assert.are.equal(1000 + 86400, a.expiresAt)
    end)

    it("edits an announcement and keeps its expiry when the player did not change it", function()
      editor()
      local a = publish({ title = "Old", expiry = "7d" })
      env.ns.UI.Redraw()
      env.press("Edit")
      env.find(env.page(), "EditBox").opts.onChange("New")
      assert.is_truthy(env.find(env.page(), "Button", "Save changes"))
      env.ns.Platform.ServerTime = function()
        return 5000
      end
      env.press("Save changes")
      local saved = env.ns.db.global.announcements.items[a.id]
      assert.are.equal("New", saved.title)
      assert.are.equal(2, saved.rev)
      assert.are.equal(1000 + 7 * 86400, saved.expiresAt)
    end)

    it("cancels an edit", function()
      editor()
      local a = publish({ title = "Old" })
      env.ns.UI.Redraw()
      env.press("Edit")
      env.press("Cancel")
      assert.is_nil(env.find(env.page(), "Button", "Save changes"))
      assert.are.equal("Old", env.ns.db.global.announcements.items[a.id].title)
    end)

    it("deletes in two clicks", function()
      editor()
      local a = publish({ title = "Doomed" })
      env.ns.UI.Redraw()
      env.press("Delete")
      assert.is_truthy(env.ns.db.global.announcements.items[a.id])
      env.press("Click again to delete")
      assert.is_nil(env.ns.db.global.announcements.items[a.id])
      assert.are.equal("ANN_DEL:" .. a.id, env.announced[#env.announced])
    end)

    it("sends the popup again", function()
      editor()
      local a = publish({ title = "Again", popup = false })
      env.ns.UI.Redraw()
      env.press("Send popup again")
      assert.are.equal(2, env.ns.db.global.announcements.items[a.id].popupRev)
      assert.is_true(env.ns.db.global.announcements.items[a.id].popup)
      assert.are.equal("success", env.banner().opts.kind)
    end)

    it("marks the silent ones in the list", function()
      editor()
      publish({ title = "Silent", popup = false })
      env.ns.UI.Redraw()
      assert.is_truthy(env.find(env.page(), "Badge", "No popup"))
    end)

    it("stops at 30 and says the board is full", function()
      editor()
      for index = 1, 30 do
        publish({ title = "n" .. index })
      end
      env.ns.UI.Redraw()
      env.find(env.page(), "EditBox").opts.onChange("One more")
      env.ns.UI.Redraw()
      assert.is_true(env.find(env.page(), "Button", "Publish").opts.disabled)
      assert.is_truthy(env.text():find("Published: 30 of 30", 1, true))
    end)

    it("is refused by the service for an officer who got in anyway", function()
      env = build("Council")
      env.forceTabs = true
      env.open("announceadmin")
      env.find(env.page(), "EditBox").opts.onChange("Forged")
      env.find(env.page(), "Button", "Publish").opts.onClick()
      assert.is_nil(next(env.ns.db.global.announcements.items))
      assert.are.same({}, env.announced)
      assert.are.equal("warning", env.banner().opts.kind)
      assert.is_truthy(env.banner().opts.text:find("guild master", 1, true))
    end)

    it("is in the sidebar of the guild master and the co-guild master only", function()
      local function sees(rank)
        local other = build(rank)
        other.ns.ViewModel.TabVisible = other.realTabVisible
        local role = other.ns.PermissionService.OwnRole(other.ns.Platform)
        local visible = other.ns.ViewModel.TabVisible("announceadmin", role, "r1")
        pcall(other.close)
        return visible
      end
      for _, rank in ipairs({ "GM", "CoGM" }) do
        assert.is_true(sees(rank), rank)
      end
      for _, rank in ipairs({ "Council", "RL", "Roster", "Member", "Alter" }) do
        assert.is_false(sees(rank), rank)
      end
      env = build("GM")
    end)
  end)

  describe("Home", function()
    it("shows the pinned announcement as a line with a way to the board", function()
      env = build("Member")
      stored("p", { title = "Server restart", pinned = true })
      env.open("home")
      assert.is_truthy(env.text():find("Announcement: Server restart", 1, true))
      env.press("Open board")
      assert.are.equal("announcements", env.ns.UI.CurrentTab())
    end)

    it("shows nothing when no announcement is pinned", function()
      env = build("Member")
      stored("p", { title = "Not pinned" })
      env.open("home")
      assert.is_nil(env.text():find("Not pinned", 1, true))
    end)
  end)

  it("redraws when announcements change, only on the tabs that show them", function()
    env = build("GM")
    env.open("announcements")
    local count = #env.ns.Kit.fake.nodes
    env.ns.UI.AnnouncementsChanged()
    assert.is_true(#env.ns.Kit.fake.nodes > count)
    env.open("professions")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.AnnouncementsChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)
end)

describe("Window smoke test: Modules", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  -- The window with the module service wired as Core/Init.lua wires it.
  local function openModules(rank)
    env = build(rank)
    env.ns.modules = env.ns.ModuleService.New({
      db = function()
        return env.ns.db
      end,
      onChange = function()
        env.ns.UI.ModulesChanged()
      end,
    })
    env.open("modules")
  end

  local function sidebarValues()
    local sidebar
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        sidebar = node
      end
    end
    local values = {}
    for _, group in ipairs(sidebar.opts.groups) do
      for _, item in ipairs(group.items) do
        values[#values + 1] = item.value
      end
    end
    return values
  end

  it("draws one switch per module, checked while the module is on", function()
    openModules("Member")
    assert.is_truthy(env.text():find("Your modules", 1, true))
    assert.is_true(FakeKit.find(env.page(), "Switch", "Professions").opts.checked)
    assert.is_true(FakeKit.find(env.page(), "Switch", "PvP").opts.checked)
    assert.is_truthy(FakeKit.find(env.page(), "Button", "Turn all on"))
  end)

  it("turning a module off hides its tabs in the sidebar at once, and its switch says what else goes", function()
    openModules("GM")
    assert.is_truthy(FakeKit.find(env.page(), "Label", "Turning it off also turns off: Intel."))
    FakeKit.find(env.page(), "Switch", "PvP").opts.onChange(false)
    assert.is_false(env.ns.modules:IsEnabled("intel"))
    local values = sidebarValues()
    for _, value in ipairs(values) do
      assert.is_true(value ~= "pvp" and value ~= "pvpadmin", value)
    end
    assert.is_false(FakeKit.find(env.page(), "Switch", "PvP").opts.checked)
  end)

  it("turn all on switches every module on again", function()
    openModules("Member")
    FakeKit.find(env.page(), "Switch", "PvP").opts.onChange(false)
    FakeKit.find(env.page(), "Button", "Turn all on").opts.onClick()
    assert.is_true(env.ns.modules:IsEnabled("pvp"))
    assert.is_true(env.ns.modules:IsEnabled("intel"))
  end)
end)

describe("Window smoke test: Home and modules", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("leaves the Layers and Groups cards out while their modules are off", function()
    env = build("Member")
    env.ns.modules = env.ns.ModuleService.New({
      db = function()
        return env.ns.db
      end,
    })
    env.ns.lfgBoard = {
      OpenCount = function()
        return 2
      end,
    }
    env.open("home")
    assert.is_truthy(FakeKit.find(env.page(), "Button", "Open Groups"))
    assert.is_truthy(FakeKit.find(env.page(), "Card", "Groups"))
    env.ns.modules:SetEnabled("groups", false)
    env.ns.modules:SetEnabled("layers", false)
    env.open("home")
    assert.is_nil(FakeKit.find(env.page(), "Button", "Open Groups"))
    assert.is_nil(FakeKit.find(env.page(), "Card", "Groups"))
    assert.is_nil(FakeKit.find(env.page(), "Card", "Your layer"))
  end)
end)
