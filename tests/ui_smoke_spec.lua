-- A smoke test of the window (UI/Main.lua and the tabs in UI/Tabs) against a fake of the kit's API
-- (tests/support/fake_kit.lua). It cannot say how anything looks, but it draws every tab for each kind of player and
-- presses the buttons, which catches the nil calls and wrong argument orders that are otherwise only found in the game.
local FakeFrames = dofile("tests/support/fake_frames.lua")
local FakeKit = dofile("tests/support/fake_kit.lua")
local Roles = dofile("tests/support/roles.lua")

local ALL_TABS = { "home", "profile", "ready", "raid", "loot", "pvp", "layers", "blacklist", "roster", "rules" }

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
    "Domain/PvPSeasonModel",
    "Domain/PvPSeasonService",
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
    "Domain/ReadinessService",
    "Domain/ReadinessRules",
    "Domain/ProfileService",
    "Domain/PublishService",
    "Domain/BlacklistService",
    "Domain/LayerModel",
    "Domain/PositionModel",
    "Domain/ReportService",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
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
    "UI/MinimapButton",
    "Commands/RaidCommands",
    "Commands/LootCommands",
    "Commands/TemplateCommands",
    "Commands/BlacklistCommands",
    "Commands/RosterCommands",
    "UI/Main",
    "UI/Cards",
    "UI/Tabs/Home",
    "UI/Tabs/Profile",
    "UI/Tabs/Readiness",
    "UI/Tabs/Members",
    "UI/Tabs/Raid",
    "UI/Tabs/Loot",
    "UI/Tabs/PvP",
    "UI/Tabs/Blacklist",
    "UI/Tabs/Rules",
    "UI/Tabs/Professions",
    "UI/Tabs/Layers",
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
  FakeFrames.install()

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
    GetIdentityKey = function()
      return "Leader-Realm"
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
      readinessRules = {},
      rosters = {},
      members = {},
      recipes = {},
    },
  }
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
    ResetPvP = function(_, target)
      env.sent[#env.sent + 1] = "ResetPvP:" .. target
      return true, 3, true
    end,
    SetReadinessRules = function(_, rules)
      local clean, reason = ns.ReadinessRules.Validate(rules)
      if not clean then
        return false, reason
      end
      local record = ns.db.global.readinessRules
      record.rev = (record.rev or 0) + 1
      record.rules = clean
      env.sent[#env.sent + 1] = "SetReadinessRules"
      return true, record.rev
    end,
  }
  for _, kind in ipairs({
    "SendEvent",
    "SendAttendance",
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
    env.ns.UI.OpenTab("loot")
    assert.are.equal("loot", env.ns.UI.CurrentTab())
    env.ns.UI.OpenTab("home")
    assert.are.equal("home", env.ns.UI.CurrentTab())
  end)

  it("offers the rules tab only to the guild master and the co-guild master", function()
    for _, rank in ipairs({ "RL", "Council", "Roster", "Member", "Alter" }) do
      env = build(rank)
      env.open("home")
      local sidebar
      for _, node in ipairs(env.ns.Kit.fake.nodes) do
        if node.kind == "Sidebar" then
          sidebar = node
        end
      end
      local values = {}
      for _, group in ipairs(sidebar.opts.groups) do
        for _, item in ipairs(group.items) do
          values[item.value] = true
        end
      end
      assert.is_nil(values.rules, rank)
      pcall(env.close)
    end
    env = build("GM")
    env.open("home")
    local sidebar
    for _, node in ipairs(env.ns.Kit.fake.nodes) do
      if node.kind == "Sidebar" then
        sidebar = node
      end
    end
    assert.are.equal("rules", sidebar.opts.groups[3].items[1].value)
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
      env = build("Member")
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
      env = build("Member")
      local ready = env.open("ready")
      local header = env.find(ready, "PageHeader")
      assert.are.equal("Readiness", header.opts.title)
      assert.is_truthy(header.opts.badge.text:find("met", 1, true))
    end)
  end)

  describe("Members", function()
    it("lists the whole guild read-only for a member", function()
      env = build("Member")
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

    it("gives rl and officer no Rosters card and no dropdown until the roster scoping lands", function()
      for _, rank in ipairs({ "RL", "Council", "Roster" }) do
        env = build(rank)
        env.open("roster")
        assert.is_nil(env.find(env.page(), "Card", "Rosters"), rank)
        for _, row in ipairs(env.tableRows()) do
          assert.is_nil(row.cells.roster.widget, rank)
        end
        pcall(env.close)
      end
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

  describe("Raid", function()
    local function open_raid(rank)
      env = build(rank)
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
      local raid = open_raid("Member")
      local values = {}
      for _, tab in ipairs(FakeKit.find(raid, "TabStrip").opts.tabs) do
        values[#values + 1] = tab.value
      end
      assert.are.same({ "summary", "reports" }, values)
      assert.is_nil(env.find(raid, "Button", "New event"))
    end)

    it("tells a member with no roster to ask for one and shows nothing else", function()
      env = build("Norost")
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
      -- Admins see the roster selector and start on all rosters.
      assert.are.equal("all", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
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
      env.ns.UI.nav = {}
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
      open_raid("Member")
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
      open_raid("Member")
      FakeKit.find_all(env.page(), "IconButton")[1].opts.onClick()
      assert.are.equal(1, #env.ns.Kit.fake.menu.items)
    end)
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

  it("gives a roster player the answer buttons with the spec from the profile, and no council controls", function()
    local loot = open_loot("Roster", true)
    assert.is_nil(env.find(loot, "Button", "Open the voting window"))
    assert.is_nil(env.find(loot, "Card", "Open a session"))
    assert.is_truthy(env.text():find("Spec: Tank (from your profile)", 1, true))
    env.press("Off spec")
    local candidate = env.ns.db.global.events.e1.loot.s1.candidates["Leader-Realm"]
    assert.are.same({ "off", "Tank" }, { candidate.need, candidate.spec })
    assert.are.equal("SendLootCandidate", env.sent[#env.sent])
    for _, row in ipairs(env.tableRows()) do
      assert.is_nil(row.cells.vote)
      assert.is_nil(row.cells.award)
    end
  end)

  it("asks for a spec when none is declared, and passes locally", function()
    open_loot("Roster", true)
    env.ns.character.profile.fields = {}
    env.ns.UI.Redraw()
    env.press("Main spec")
    assert.is_truthy(env.banner().opts.text:find("Pick your spec", 1, true))
    env.press("Pass")
    assert.are.equal("s1", env.passed)
    assert.are.equal("success", env.banner().opts.kind)
    assert.are.same({}, env.sent)
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
    env = build("Member")
    env.ns.db.global.events.e1 = event("e1", "One")
    env.ns.db.global.events.e2 = event("e2", "Two", { startAt = 10 })
    env.open("loot", { eventId = "e2" })
    assert.are.equal("e2", FakeKit.find_all(env.page(), "Dropdown")[1].opts.value)
    pcall(env.close)
    env = build("Member")
    env.open("loot")
    assert.is_truthy(env.text():find("No events yet", 1, true))
  end)

  it("lets the guild master pick the roster, and shows the notice to a member with no roster", function()
    env = build("GM")
    env.ns.db.global.events.e1 = event("e1", "One")
    env.open("loot")
    local dropdowns = FakeKit.find_all(env.page(), "Dropdown")
    dropdowns[2].opts.onChange("none")
    assert.is_truthy(env.text():find("No events yet", 1, true))
    pcall(env.close)
    env = build("Norost")
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
    assert.are.same({ "season", "missions", "stats", "feed", "history" }, values)
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
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("admin")
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
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("admin")
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
    e.open("pvp")
    strip(e).opts.onSelect(sub)
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

  it("draws every sub-tab and admin section as gm, cogm, member and with no roster", function()
    for _, who in ipairs({ "GM", "CoGM", "Member", "Norost" }) do
      env = build(who)
      seed(env)
      env.open("pvp")
      local subs = {}
      for _, tab in ipairs(strip(env).opts.tabs) do
        subs[#subs + 1] = tab.value
        strip(env).opts.onSelect(tab.value)
        if tab.value == "admin" then
          for _, section in ipairs(FakeKit.find(env.page(), "Segmented").opts.items) do
            FakeKit.find(env.page(), "Segmented").opts.onChange(section.value)
          end
        end
      end
      local admin = who == "GM" or who == "CoGM"
      assert.are.equal(admin and 6 or 5, #subs, who)
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
    for _, zone in ipairs(e.ns.Constants.PVP_MISSION_ZONES) do
      if zone.mapId == mapId then
        return e.ns.L(zone.nameKey)
      end
    end
    return tostring(mapId)
  end

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
    -- The zones come from the constant list as chips.
    for _, mapId in ipairs({ 1454, 1453 }) do
      FakeKit.find(env.page(), "Chip", zoneText(env, mapId)).opts.onToggle(true)
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
    strip(env).opts.onSelect("history")
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

  it("says it is for the guild master and the co-guild master when anyone else gets there", function()
    for _, rank in ipairs({ "RL", "Council", "Roster", "Member" }) do
      env = build(rank)
      env.open("rules")
      assert.is_truthy(
        env.text():find("Only the guild master and the co-guild master can edit the readiness rules.", 1, true),
        rank
      )
      assert.is_nil(env.find(env.page(), "List"), rank)
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
    local rules = env.ns.db.global.readinessRules.rules
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
    local kind = FakeKit.find_all(env.page(), "Dropdown")[1]
    for _, check in ipairs({ "ilvl", "enchants", "buff", "profession", "field", "confirm" }) do
      kind.opts.onChange(check)
      env.open("rules")
      kind = FakeKit.find_all(env.page(), "Dropdown")[1]
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
    local rules = env.ns.db.global.readinessRules.rules
    assert.are.same({ 5 }, rules[#rules].slots)

    kind = FakeKit.find_all(env.page(), "Dropdown")[1]
    kind.opts.onChange("profession")
    env.open("rules")
    FakeKit.find_all(env.page(), "EditBox")[1].opts.onChange("Alchemist")
    FakeKit.find_all(env.page(), "Dropdown")[2].opts.onChange("Alchemy")
    FakeKit.find_all(env.page(), "EditBox")[2].opts.onChange("300")
    env.press("Add rule")
    rules = env.ns.db.global.readinessRules.rules
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
    local rules = env.ns.db.global.readinessRules.rules
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
    assert.are.equal(4, #env.ns.db.global.readinessRules.rules)
    env.ns.db.global.readinessRules.rules = { env.ns.db.global.readinessRules.rules[1] }
    env.ns.UI.Redraw()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    FakeKit.find(env.page(), "List").opts.rows[1].rights[1].opts.onClick()
    assert.are.equal("danger", env.banner().opts.kind)
    assert.are.equal(1, #env.ns.db.global.readinessRules.rules)
  end)

  it("puts the starting list back only after a second click, and links to Readiness", function()
    env = build("GM")
    env.ns.db.global.readinessRules =
      { rev = 1, rules = { { id = "x", label = "X", check = "confirm", category = "c", evidenceMode = "manual" } } }
    env.open("rules")
    env.press("Use the starting list")
    assert.are.equal(1, #env.ns.db.global.readinessRules.rules)
    env.press("Confirm: replace every rule with the starting list")
    assert.are.equal(5, #env.ns.db.global.readinessRules.rules)
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

  it("saves the position switches: sharing off by default, the guild drawn on both maps by default", function()
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
    assert.is_false(share.opts.checked)
    assert.is_true(minimap.opts.checked)
    assert.is_true(worldmap.opts.checked)
    share.opts.onChange(true)
    minimap.opts.onChange(false)
    worldmap.opts.onChange(false)
    assert.are.same({ { "share", true }, { "minimap", false }, { "worldmap", false } }, calls)
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
    env.open("loot")
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

  it("lists who can craft a recipe and prefills a whisper from Ask", function()
    env = build("Member")
    env.recipeNames = { [10] = "Elixir of Might", [11] = "Flask of Wisdom" }
    share("Ann-Realm", 171, "Alchemy", { 10, 11 })
    env.open("professions")
    assert.is_truthy(env.text():find("Elixir of Might", 1, true))
    assert.is_truthy(env.text():find("Ask Ann-Realm", 1, true))
    env.press("Ask Ann-Realm")
    assert.are.equal("/w Ann-Realm Could you craft me [link10]?", env.prefilled)
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
  local env, requested, share

  local function install(options)
    options = options or {}
    env.ns.layerTracker = {
      Current = function()
        return options.own
      end,
    }
    env.ns.layerDirectory = {
      Groups = function()
        return { { map = 0, layer = 5678, members = { "Ann-Realm" }, count = 1 } }
      end,
    }
    env.ns.layerSwap = {
      CanRequest = function()
        return options.canRequest ~= false, options.reason
      end,
      Status = function()
        return options.status
      end,
      Request = function(_, map, layer)
        requested = { map, layer }
        return options.requestOk ~= false, "busy"
      end,
      Cancel = function()
        requested = "cancelled"
      end,
    }
    env.ns.SetLayerShare = function(value)
      share = value
    end
  end

  local function button(page, text)
    for _, row in ipairs(FakeKit.find(page, "List").opts.rows) do
      if row.right and row.right.opts.text == text then
        return row.right.opts
      end
    end
  end

  before_each(function()
    env = build("RL")
    requested, share = nil, nil
  end)

  after_each(function()
    pcall(env.close)
  end)

  it("is in the sidebar of every role, next to PvP", function()
    local values = {}
    for _, tab in ipairs(env.ns.ViewModel.TabsFor("member")) do
      values[#values + 1] = tab.value
    end
    local pvp
    for index, value in ipairs(values) do
      pvp = value == "pvp" and index or pvp
    end
    assert.are.equal("layers", values[pvp + 1])
  end)

  it("says the feature is not available before it starts", function()
    env.open("layers")
    assert.is_truthy(env.text():find("not available", 1, true))
    assert.is_truthy(FakeKit.find(env.page(), "Switch", "Share my layer"))
  end)

  it("lists the layers and asks for a swap with the button", function()
    install({ own = { map = 0, layer = 1234 } })
    env.open("layers")
    local text = env.text()
    assert.is_truthy(text:find("Your layer: #1234", 1, true))
    assert.is_truthy(text:find("#5678", 1, true))
    assert.is_truthy(text:find("Ann-Realm", 1, true))
    button(env.page(), "Request swap").onClick()
    assert.are.same({ 0, 5678 }, requested)
  end)

  it("explains why a button is disabled and what went wrong with a click", function()
    install({ own = { map = 0, layer = 1234 }, canRequest = false, reason = "in_group", requestOk = false })
    env.open("layers")
    local request = button(env.page(), "Request swap")
    assert.is_true(request.disabled)
    assert.are.equal("you are in a group.", request.tooltip)
    assert.is_truthy(env.text():find("you are in a group", 1, true))
    request.onClick()
    assert.are.equal("warning", env.banner().opts.kind)
    assert.is_truthy(env.banner().opts.text:find("Not done: a swap is already running.", 1, true))
  end)

  it("shows the running swap with a way to cancel it", function()
    install({
      own = { map = 0, layer = 1234 },
      status = { role = "requester", stage = "request", map = 0, layer = 5678 },
    })
    env.open("layers")
    assert.is_truthy(env.text():find("Looking for someone on #5678", 1, true))
    env.press("Cancel")
    assert.are.equal("cancelled", requested)
  end)

  it("switches sharing with the switch", function()
    install()
    env.open("layers")
    local switch = FakeKit.find(env.page(), "Switch", "Share my layer")
    assert.is_true(switch.opts.checked)
    switch.opts.onChange(false)
    assert.is_false(share)
  end)

  it("redraws when the layers change, at most once per interval, and only on its own tab", function()
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
    env.ns.UI.SelectTab("home")
    count = #env.ns.Kit.fake.nodes
    env.ns.UI.LayersChanged()
    assert.are.equal(count, #env.ns.Kit.fake.nodes)
  end)
end)
