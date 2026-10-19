-- A smoke test of the window (UI/Main.lua and the tabs in UI/Tabs) against a fake of the kit's API
-- (tests/support/fake_kit.lua). It cannot say how anything looks, but it draws every tab for each kind of player and
-- presses the buttons, which catches the nil calls and wrong argument orders that are otherwise only found in the game.
local FakeFrames = dofile("tests/support/fake_frames.lua")
local FakeKit = dofile("tests/support/fake_kit.lua")
local Roles = dofile("tests/support/roles.lua")

local ALL_TABS = { "home", "profile", "ready", "raid", "loot", "pvp", "blacklist", "roster", "rules" }

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
    "Domain/RosterService",
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
    "UI/MinimapButton",
    "Commands/RaidCommands",
    "Commands/LootCommands",
    "Commands/TemplateCommands",
    "Commands/BlacklistCommands",
    "Commands/RosterCommands",
    "UI/Main",
    "UI/Tabs/Home",
    "UI/Tabs/Profile",
    "UI/Tabs/Readiness",
    "UI/Tabs/Members",
    "UI/Tabs/Raid",
    "UI/Tabs/Loot",
    "UI/Tabs/PvP",
    "UI/Tabs/Blacklist",
    "UI/Tabs/Rules",
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

-- rank: "GM" | "RL" | "Council" | "Member" | "Norost" (a member with no roster).
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
    GetOwnGuildRank = Roles.ranking(rank == "Norost" and "Member" or rank),
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
        { name = "Alchemy", skill = 300, max = 300 },
        { name = "Cooking", skill = 20, max = 300, secondary = true },
      }
    end,
    GetEquippedEnchants = function() end,
    GetActiveBuffs = function() end,
    IsChatMessagingLockedDown = function()
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
    },
  }
  -- The roles of the players: "GM" is the guild master; the other ranks stand for the role assigned to this character,
  -- in roster r1 (a "Norost" member has no roster at all).
  ns.db.global.members, ns.db.global.rosters = Roles.assignments(rank == "Norost" and "Member" or rank, "Leader-Realm")
  if rank == "Norost" then
    ns.db.global.members["Leader-Realm"].rosterId = nil
  end
  ns.PermissionService.Configure({ members = ns.db.global.members })
  ns.character = {
    profile = { fields = {} },
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

  it(
    "draws every tab for the guild master, a raid leader, a council member, a member and a member with no roster",
    function()
      for _, rank in ipairs({ "GM", "RL", "Council", "Member", "Norost" }) do
        env = build(rank)
        env.ns.db.global.events["e1"] = event("e1", "Molten Core")
        for _, tab in ipairs(ALL_TABS) do
          assert.is_truthy(env.open(tab), rank .. " " .. tab)
        end
        pcall(env.close)
      end
    end
  )

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

  it("offers the rules tab only to the guild master", function()
    for _, rank in ipairs({ "RL", "Council", "Member" }) do
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
    it("shows the readiness, the sync state, the next event and the open loot sessions", function()
      env = build("Member")
      env.ns.db.global.events["e1"] = event("e1", "Molten Core", {
        loot = {
          s1 = {
            sessionId = "s1",
            itemId = 5,
            itemName = "Sword",
            status = "open",
            rev = 1,
            updatedAt = 3,
            candidates = {},
            votes = {},
          },
        },
      })
      local home = env.open("home")
      local text = env.text()
      assert.is_truthy(text:find("Your readiness", 1, true))
      assert.is_truthy(text:find("Members with the addon", 1, true))
      assert.is_truthy(text:find("Molten Core", 1, true))
      assert.is_truthy(text:find("Sword", 1, true))
      assert.is_nil(env.find(home, "Button", "Request a sync"))
    end)

    it("links to the Readiness tab, the event in the Raid tab and the session in the Loot tab", function()
      env = build("Member")
      env.ns.db.global.events["e1"] = event("e1", "Molten Core", {
        loot = {
          s1 = {
            sessionId = "s1",
            itemId = 5,
            itemName = "Sword",
            status = "open",
            rev = 1,
            updatedAt = 3,
            candidates = {},
            votes = {},
          },
        },
      })
      env.open("home")
      env.press("Open in Raid")
      assert.are.equal("raid", env.ns.UI.CurrentTab())
      env.open("home")
      env.press("Open in Loot")
      assert.are.equal("loot", env.ns.UI.CurrentTab())
      env.open("home")
      env.press("See details")
      assert.are.equal("ready", env.ns.UI.CurrentTab())
    end)

    it("says there are no events or sessions, and tells a member with no roster to ask for one", function()
      env = build("Member")
      env.open("home")
      assert.is_truthy(env.text():find("No upcoming events", 1, true))
      assert.is_truthy(env.text():find("No open loot sessions", 1, true))
      pcall(env.close)
      env = build("Norost")
      env.ns.db.global.events["e1"] = event("e1", "Molten Core")
      env.open("home")
      assert.is_truthy(env.text():find("You are not in a roster yet", 1, true))
      assert.is_nil(env.text():find("Molten Core", 1, true))
    end)

    it("shows the events of the own roster only", function()
      env = build("Member")
      env.ns.db.global.events["mine"] = event("mine", "Mine")
      env.ns.db.global.events["theirs"] = event("theirs", "Theirs", { rosterId = "r9" })
      env.open("home")
      assert.is_truthy(env.text():find("Mine", 1, true))
      assert.is_nil(env.text():find("Theirs", 1, true))
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

    it("gives the guild master the Rosters card and a role and roster dropdown on each row but their own", function()
      env = build("GM")
      env.open("roster")
      assert.is_truthy(env.text():find("New roster", 1, true))
      local widgets = 0
      for _, row in ipairs(env.tableRows()) do
        if row.cells.role.widget == "dropdown" then
          widgets = widgets + 1
        end
      end
      assert.are.equal(3, widgets)
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
        if row.cells.role.widget == "dropdown" then
          target = row
        end
      end
      target.cells.role.opts.onChange("rl")
      target.cells.roster.opts.onChange(id)
      local assigned
      for name, record in pairs(env.ns.db.global.members) do
        if record.rosterId == id then
          assigned = name
        end
      end
      assert.is_truthy(assigned)
      assert.are.equal("rl", env.ns.db.global.members[assigned].role)

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

  it("gives a member the answer buttons with the spec from the profile, and no council controls", function()
    local loot = open_loot("Member", true)
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
    open_loot("Member", true)
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
    assert.are.same({ "mine", "ranking", "feed" }, values)
    local grids = FakeKit.find_all(pvp, "StatGrid")
    assert.are.equal(2, #grids)
    assert.are.equal("Open world", grids[1].opts.stats[1].caption)
  end)

  it("says 'Not available' when the client cannot give the figures", function()
    env = build("Member")
    env.ns.pvpTracker.honorAvailable = false
    env.open("pvp")
    assert.is_truthy(env.text():find("Not available", 1, true))
  end)

  it("draws the ranking, sorts by a column and flips on the second click, and searches", function()
    env = build("Member")
    env.ns.db.global.pvpStats = {
      ["Ann-Realm"] = { honor = { world = 30, bg = 20 }, blows = { world = 5, bg = 1 }, updatedAt = 900, rev = 1 },
      ["Gone-Realm"] = { honor = { world = 99, bg = 99 }, updatedAt = 900, rev = 1 },
    }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("ranking")
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
    FakeKit.find(env.page(), "Segmented").opts.onChange("today")
    assert.is_truthy(env.text():find("Today's kills", 1, true))
  end)

  it("offers the reset to the guild master only, with a second click to confirm", function()
    env = build("RL")
    env.ns.db.global.pvpStats = { ["Ann-Realm"] = { honor = { world = 3, bg = 0 }, updatedAt = 900, rev = 1 } }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("ranking")
    assert.is_nil(env.find(env.page(), "Button", "Reset PvP counters"))
    pcall(env.close)
    env = build("GM")
    env.ns.db.global.pvpStats = { ["Ann-Realm"] = { honor = { world = 3, bg = 0 }, updatedAt = 900, rev = 1 } }
    env.open("pvp")
    FakeKit.find(env.page(), "TabStrip").opts.onSelect("ranking")
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

  it("says it is for the guild master when anyone else gets there", function()
    env = build("RL")
    env.open("rules")
    assert.is_truthy(env.text():find("Only the guild master can edit the readiness rules.", 1, true))
    assert.is_nil(env.find(env.page(), "List"))
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

  it("changes the language and draws the window again in it", function()
    local stack = open_settings()
    local dropdown = FakeKit.find_all(stack, "Dropdown")[1]
    assert.are.equal("auto", dropdown.opts.value)
    dropdown.opts.onChange("es")
    assert.are.equal("es", env.ns.Settings.Language(env.ns.db))
    assert.are.equal("Inicio", env.ns.ViewModel.TABS[1].text)
    assert.is_truthy(env.text():find("Tu preparación", 1, true))
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
