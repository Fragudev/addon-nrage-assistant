-- A smoke test of the window (UI/Main.lua) against a fake of the kit (tests/support/fake_kit.lua) and, for the tabs
-- that have not moved to the kit yet, a fake AceGUI. It cannot say how anything looks, but it draws every tab for each
-- kind of player and presses the buttons, which catches the nil calls and wrong argument orders that are otherwise
-- only found in the game.
local FakeFrames = dofile("tests/support/fake_frames.lua")
local FakeKit = dofile("tests/support/fake_kit.lua")

-- A widget that accepts any method. Containers record their children; text, value and callbacks are kept
-- so the test can read them and press things.
local function new_widget(kind, registry)
  local widget = { kind = kind, children = {}, callbacks = {}, props = {} }
  widget.frame = setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
  local methods = {
    AddChild = function(self, child)
      self.children[#self.children + 1] = child
    end,
    ReleaseChildren = function(self)
      self.children = {}
    end,
    SetCallback = function(self, name, fn)
      self.callbacks[name] = fn
    end,
    SetText = function(self, text)
      self.props.text = text
    end,
    GetText = function(self)
      return self.props.text or ""
    end,
    SetStatusTable = function(self, status)
      self.props.status = status
    end,
    SetImage = function(self, image)
      self.props.image = image
    end,
    SetLabel = function(self, label)
      self.props.label = label
    end,
    SetValue = function(self, value)
      self.props.value = value
    end,
    SetList = function(self, list, order)
      self.props.list, self.props.order = list, order
    end,
    SetTabs = function(self, tabs)
      self.props.tabs = tabs
    end,
    SelectTab = function(self, value)
      self.callbacks.OnGroupSelected(self, "OnGroupSelected", value)
    end,
  }
  setmetatable(widget, {
    __index = function(_, name)
      return methods[name] or function() end
    end,
  })
  registry[#registry + 1] = widget
  return widget
end

local function walk(widget, visit)
  visit(widget)
  for _, child in ipairs(widget.children) do
    walk(child, visit)
  end
end

-- The candidate names in the order the voting table lists them (they are the labels ending in "-Realm").
local function walk_labels(root, out)
  walk(root, function(widget)
    local text = (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text
    if text and text:match("^%a+%-Realm$") then
      out[#out + 1] = text
    end
  end)
end

local function find_all(root, predicate)
  local found = {}
  walk(root, function(widget)
    if predicate(widget) then
      found[#found + 1] = widget
    end
  end)
  return found
end

-- `locale` (optional) is the client locale code the window is built for, e.g. "esES".
local function load_window(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/Settings",
    "Domain/PvPService",
    "Domain/PvPFeed",
    "Domain/PermissionService",
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
    "UI/MinimapButton",
    "Commands/RaidCommands",
    "Commands/LootCommands",
    "Commands/TemplateCommands",
    "Commands/BlacklistCommands",
    "UI/Main",
    "UI/VotingFrame",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
    if path == "UI/Kit/Icons" then
      ns.Kit = FakeKit.new(ns.Kit)
    end
  end
  return ns
end

local function build(rank, locale)
  local ns = load_window(locale)
  local env = { ns = ns, widgets = {}, sent = {}, counter = 0, changes = 0 }
  env.fakeKit = FakeKit
  FakeFrames.install()

  _G.LibStub = function()
    return {
      Create = function(_, kind)
        local widget = new_widget(kind, env.widgets)
        -- The window draws every tab into one scroll frame, made the first time a tab is drawn.
        if kind == "ScrollFrame" and not env.scroll then
          env.scroll = widget
        end
        return widget
      end,
      Release = function() end,
    }
  end
  _G.GameFontNormalLarge = {}

  ns.active = true
  ns.GetVersion = function()
    return "test"
  end
  ns.Platform = {
    GetLocale = function()
      return locale or "enUS"
    end,
    GetOwnGuildRank = function()
      return rank
    end,
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
      return {}
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
  }
  env.tooltip = { shown = false }
  _G.GameTooltip = {
    SetOwner = function(_, frame, anchor)
      env.tooltip.owner, env.tooltip.anchor = frame, anchor
    end,
    SetHyperlink = function(_, link)
      env.tooltip.link = link
      if env.tooltip.refuse then
        error("unknown item")
      end
    end,
    Show = function()
      env.tooltip.shown = true
    end,
    Hide = function()
      env.tooltip.shown = false
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
    },
  }
  ns.character = {
    profile = { fields = {} },
    readiness = {},
    publish = {},
    pvp = { honor = { world = 4, bg = 6 }, blows = { world = 1, bg = 2 }, daily = {} },
  }
  ns.guildRoster = {
    Names = function()
      return { "Ann-Realm", "Yonemon Gg" }
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
      return { paused = false, queued = 0, peers = 0, incompatible = {} }
    end,
  }
  -- What the profile publication sends; kept apart from env.sent so the other tests do not see it.
  env.messages = {}
  ns.comm.Send = function(_, messageType)
    env.messages[#env.messages + 1] = messageType
    return true
  end
  ns.comm.RequestSync = function()
    env.sent[#env.sent + 1] = "RequestSync"
    return true
  end
  ns.comm.ResetPvP = function(_, target)
    env.sent[#env.sent + 1] = "ResetPvP:" .. target
    return true, 3, true
  end
  -- The admin's way to set the rules: what Comm does, without the sending.
  ns.comm.SetReadinessRules = function(_, rules)
    local clean, reason = ns.ReadinessRules.Validate(rules)
    if not clean then
      return false, reason
    end
    local record = ns.db.global.readinessRules
    record.rev = (record.rev or 0) + 1
    record.rules = clean
    env.sent[#env.sent + 1] = "SetReadinessRules"
    return true, record.rev
  end
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
  }) do
    ns.comm[kind] = function()
      env.sent[#env.sent + 1] = kind
      return true
    end
  end
  table.insert(ns.UI.lootListeners, function()
    env.changes = env.changes + 1
  end)
  _G.C_Timer = {
    After = function(_, fn)
      env.timers = env.timers or {}
      env.timers[#env.timers + 1] = fn
    end,
  }
  ns.VotingFrame.Start()

  -- Opens the window on `tab` and returns the scroll frame the tab drew into.
  function env.open(tab)
    env.widgets = {}
    ns.UI.OpenTab(tab)
    return env.scroll
  end
  -- Opens the Raid tab on one of its sub-tabs (summary, details, attendance, assignments, templates).
  function env.raid(subtab)
    local scroll = env.open("raid")
    local sub = env.find(scroll, "TabGroup")
    if sub then
      sub:SelectTab(subtab)
    end
    return scroll
  end
  function env.close()
    -- Toggle closes an open window; OpenTab leaves one open.
    ns.UI.Toggle()
    FakeFrames.uninstall()
  end
  function env.find(root, kind, label)
    return find_all(root, function(w)
      return w.kind == kind and (label == nil or w.props.label == label or w.props.text == label)
    end)[1]
  end
  return env
end

describe("Window smoke test", function()
  local env

  before_each(function()
    env = build("RL")
  end)

  after_each(function()
    pcall(env.close)
  end)

  it("draws every tab without errors", function()
    for _, tab in ipairs(env.ns.ViewModel.TABS) do
      assert.is_truthy(env.open(tab.value), tab.value)
    end
  end)

  it("draws the PvP tab with the counters and redraws it when they change", function()
    local pvp = env.open("pvp")
    assert.are.same({
      { value = "mine", text = "My stats" },
      { value = "ranking", text = "Ranking" },
      { value = "feed", text = "Recent kills" },
    }, env.find(pvp, "TabGroup").props.tabs)
    local function texts(root)
      local found = {}
      walk(root, function(widget)
        if widget.kind == "Label" and widget.props.text then
          found[#found + 1] = widget.props.text
        end
      end)
      return table.concat(found, "\n")
    end
    local text = texts(pvp)
    assert.is_truthy(text:find("Honourable kills", 1, true))
    assert.is_truthy(text:find("Honourable kills are not available on this client.", 1, true))
    assert.is_nil(text:find("Killing blows", 1, true))

    env.ns.pvpTracker = { honorAvailable = true, blowsAvailable = true, Day = function() end }
    env.widgets = {}
    env.ns.UI.PvPChanged()
    local scrolls = { env.scroll }
    text = texts(scrolls[#scrolls])
    assert.is_truthy(text:find("Killing blows", 1, true))
    assert.is_nil(text:find("not available", 1, true))
  end)

  describe("PvP ranking", function()
    local function cells(root)
      local found = {}
      walk(root, function(widget)
        if (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text then
          found[#found + 1] = widget.props.text
        end
      end)
      return found
    end

    local function open_ranking()
      env.ns.db.global.pvpStats = {
        ["Ann-Realm"] = {
          honor = { world = 30, bg = 20 },
          blows = { world = 5, bg = 1 },
          updatedAt = 900,
          rev = 1,
        },
        ["Gone-Realm"] = { honor = { world = 99, bg = 99 }, updatedAt = 900, rev = 1 },
      }
      local pvp = env.open("pvp")
      env.find(pvp, "TabGroup"):SelectTab("ranking")
      return pvp
    end

    it("draws the members in the roster and the own row, hiding those who left", function()
      local text = table.concat(cells(open_ranking()), "\n")
      assert.is_truthy(text:find("Ann-Realm", 1, true))
      assert.is_truthy(text:find("ff33ff99Leader-Realm", 1, true))
      assert.is_nil(text:find("Gone-Realm", 1, true))
      assert.is_truthy(text:find("Blows", 1, true))
      assert.is_truthy(text:find("Total", 1, true))
    end)

    it("switches between all-time and today's counters", function()
      local pvp = open_ranking()
      assert.is_truthy(table.concat(cells(pvp), "\n"):find("\n50\n", 1, true))
      env.widgets = {}
      env.find(pvp, "Dropdown", "Show").callbacks.OnValueChanged(nil, nil, "today")
      local scrolls = { env.scroll }
      local text = table.concat(cells(scrolls[#scrolls]), "\n")
      assert.is_nil(text:find("\n50\n", 1, true))
      assert.is_truthy(text:find("Today's kills", 1, true))
      env.find(scrolls[#scrolls], "Dropdown", "Show").callbacks.OnValueChanged(nil, nil, "total")
    end)

    it("leaves out the killing blows column when nobody has them", function()
      env.ns.db.global.pvpStats = {}
      local pvp = env.open("pvp")
      env.find(pvp, "TabGroup"):SelectTab("ranking")
      local text = table.concat(cells(pvp), "\n")
      assert.is_nil(text:find("Blows", 1, true))
      assert.is_truthy(text:find("Leader-Realm", 1, true))
    end)

    it("sorts by a column when its title is clicked, and flips on the second click", function()
      local pvp = open_ranking()
      local function order()
        local list = {}
        for _, text in ipairs(cells(pvp)) do
          local name = text:match("(%a+%-Realm)")
          if name then
            list[#list + 1] = name
          end
        end
        return list
      end
      assert.are.same({ "Ann-Realm", "Leader-Realm" }, order())

      local function click(title)
        local header = find_all(pvp, function(w)
          return w.kind == "InteractiveLabel" and w.props.text and w.props.text:find(title, 1, true)
        end)[1]
        env.widgets = {}
        header.callbacks.OnClick()
        local scrolls = { env.scroll }
        pvp = scrolls[#scrolls]
      end
      click("Name")
      assert.are.same({ "Ann-Realm", "Leader-Realm" }, order())
      click("Name")
      assert.are.same({ "Leader-Realm", "Ann-Realm" }, order())
    end)

    it("redraws when a record arrives, but not more than once per interval", function()
      local clock = 100
      env.ns.Platform.Now = function()
        return clock
      end
      open_ranking()
      env.timers = nil
      env.widgets = {}
      env.ns.UI.PvPChanged()
      assert.is_true(#env.widgets > 0)
      -- A second change in the same instant waits for the timer instead of redrawing.
      env.widgets = {}
      env.ns.UI.PvPChanged()
      env.ns.UI.PvPChanged()
      assert.are.equal(0, #env.widgets)
      assert.are.equal(1, #env.timers)
      clock = clock + env.ns.Constants.PVP_REDRAW_SECONDS
      env.timers[1]()
      assert.is_true(#env.widgets > 0)
    end)
  end)

  describe("PvP recent kills", function()
    local function labels(root)
      local found = {}
      walk(root, function(widget)
        if widget.kind == "Label" and widget.props.text then
          found[#found + 1] = widget.props.text
        end
      end)
      return table.concat(found, "\n")
    end

    local function open_feed()
      local pvp = env.open("pvp")
      env.find(pvp, "TabGroup"):SelectTab("feed")
      return pvp
    end

    local function feed_with(entries, available)
      env.ns.pvpFeed = {
        Entries = function()
          return entries
        end,
        Available = function()
          return available
        end,
      }
    end

    it("has no switches: every kill is shared", function()
      feed_with({}, true)
      local pvp = open_feed()
      local boxes = 0
      walk(pvp, function(widget)
        if widget.kind == "CheckBox" then
          boxes = boxes + 1
        end
      end)
      assert.are.equal(0, boxes)
    end)

    it("lists the recent kills with escaped names", function()
      feed_with({
        { victim = "|cffff0000Zed|r", where = "world", blow = true, killers = { "Ann", "Bob" }, time = 77 },
      }, true)
      local text = labels(open_feed())
      assert.is_truthy(text:find("clock:77  Ann, Bob killed ||cffff0000Zed||r (open world, killing blow)", 1, true))
      assert.is_nil(text:find("not available", 1, true))
    end)

    it("says when the feed is not available on this client, or not started", function()
      feed_with({}, false)
      assert.is_truthy(labels(open_feed()):find("not available on this client", 1, true))
      env.ns.pvpFeed = nil
      local text = labels(open_feed())
      assert.is_truthy(text:find("not available on this client", 1, true))
      assert.is_truthy(text:find("No kills yet", 1, true))
    end)
  end)

  it("does not redraw when the PvP tab is not the one on screen", function()
    env.open("home")
    env.widgets = {}
    env.ns.UI.PvPChanged()
    assert.are.equal(0, #env.widgets)
  end)

  it("creates an event from the Raid tab, opens it and offers a matching template", function()
    env.ns.db.global.templates["Molten Core"] = {
      name = "Molten Core",
      slots = { { encounter = "Garr", characterKey = "Ann-Realm" } },
    }
    local raid = env.open("raid")
    env.find(raid, "EditBox", "New event (Enter to create)").callbacks.OnEnterPressed(nil, nil, "Molten Core night")
    assert.is_truthy(next(env.ns.db.global.events))
    assert.are.equal("SendEvent", env.sent[1])

    -- The new event is opened on its summary; its matching template is offered under Templates.
    raid = env.open("raid")
    assert.is_truthy(env.find(raid, "Button", "> 1. Molten Core night [planned]"))
    raid = env.raid("templates")
    assert.is_truthy(env.find(raid, "Button", "Apply: Molten Core"))
    env.find(raid, "Button", "Apply: Molten Core").callbacks.OnClick()
    local event = env.ns.EventService.List({ events = env.ns.db.global.events })[1]
    assert.is_truthy(next(event.assignments))
  end)

  it("edits an event, records attendance and adds then removes an assignment", function()
    env.open("raid")
    local created = env.ns.EventService.Create({
      events = env.ns.db.global.events,
      role = "rl",
      actor = "Leader-Realm",
      now = env.ns.Platform.ServerTime,
      newId = function()
        return "ev-1"
      end,
    }, { title = "Raid" })

    local raid = env.raid("details")
    env.find(raid, "EditBox", "Title (Enter to rename)").callbacks.OnEnterPressed(nil, nil, "Renamed")
    assert.are.equal("Renamed", created.title)

    raid = env.raid("details")
    env.find(raid, "Dropdown", "Status").callbacks.OnValueChanged(nil, nil, "open")
    assert.are.equal("open", created.status)

    raid = env.raid("details")
    env
      .find(raid, "EditBox", "Start, local time (YYYY-MM-DD HH:MM)").callbacks
      .OnEnterPressed(nil, nil, "2026-10-03 20:30")
    assert.are.equal(2000, created.startAt)

    -- Attendance lists only who is recorded; somebody else is found by typing part of the name.
    raid = env.raid("attendance")
    assert.is_nil(env.find(raid, "Dropdown", "Yonemon Gg"))
    assert.is_nil(env.find(raid, "Button", "Yonemon Gg"))
    env.find(raid, "EditBox", "Type part of a name and press Enter").callbacks.OnEnterPressed(nil, nil, "yonemon")
    raid = env.raid("attendance")
    env.find(raid, "Dropdown", "Record as").callbacks.OnValueChanged(nil, nil, "late")
    env.find(raid, "Button", "Yonemon Gg").callbacks.OnClick()
    assert.are.equal("late", created.attendance["Yonemon Gg"].state)

    raid = env.raid("attendance")
    assert.is_nil(env.find(raid, "Button", "Yonemon Gg"))
    env.find(raid, "Dropdown", "Yonemon Gg").callbacks.OnValueChanged(nil, nil, "present")
    assert.are.equal("present", created.attendance["Yonemon Gg"].state)

    raid = env.raid("assignments")
    env.find(raid, "Dropdown", "Member").callbacks.OnValueChanged(nil, nil, "Ann-Realm")
    env.find(raid, "EditBox", "Encounter").props.text = "Ragnaros"
    env.find(raid, "Button", "Add").callbacks.OnClick()
    assert.is_truthy(next(created.assignments))

    raid = env.raid("assignments")
    env.find(raid, "Button", "Remove").callbacks.OnClick()
    assert.is_nil(next(created.assignments))
  end)

  it("asks for a member before adding an assignment, and saves a template", function()
    env.ns.EventService.Create({
      events = env.ns.db.global.events,
      role = "rl",
      actor = "Leader-Realm",
      now = env.ns.Platform.ServerTime,
      newId = function()
        return "ev-1"
      end,
    }, { title = "Raid" })
    local raid = env.raid("assignments")
    env.find(raid, "Button", "Add").callbacks.OnClick()
    assert.is_nil(next(env.ns.db.global.events["ev-1"].assignments))

    env.ns.db.global.events["ev-1"].assignments.a1 =
      { assignmentId = "a1", encounter = "Garr", characterKey = "Ann-Realm", rev = 1 }
    raid = env.raid("templates")
    env
      .find(raid, "EditBox", "Save this event's assignments as (Enter to save)").callbacks
      .OnEnterPressed(nil, nil, "Boss")
    assert.is_truthy(env.ns.db.global.templates.Boss)
  end)

  it("shows a plain member the events and a read-only summary, with no controls", function()
    local member = build("Soldado")
    member.ns.db.global.events["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      attendance = {},
      assignments = {},
      loot = {},
    }
    local raid = member.open("raid")
    assert.is_nil(member.find(raid, "EditBox"))
    local sub = member.find(raid, "TabGroup")
    assert.are.same(
      { { value = "summary", text = "Summary" }, { value = "reports", text = "Reports" } },
      sub.props.tabs
    )
    pcall(member.close)
  end)

  it("offers a raid leader every sub-tab, and remembers the one in use across redraws", function()
    env.ns.EventService.Create({
      events = env.ns.db.global.events,
      role = "rl",
      actor = "Leader-Realm",
      now = env.ns.Platform.ServerTime,
      newId = function()
        return "ev-1"
      end,
    }, { title = "Raid" })
    local raid = env.raid("attendance")
    local sub = env.find(raid, "TabGroup")
    assert.are.equal(6, #sub.props.tabs)

    -- Redrawing the window (as every action does) comes back on the same sub-tab.
    raid = env.open("raid")
    assert.is_truthy(env.find(raid, "EditBox", "Type part of a name and press Enter"))
  end)

  it("lists the events on the left and switches the selected one", function()
    for _, id in ipairs({ "ev-1", "ev-2" }) do
      env.ns.EventService.Create({
        events = env.ns.db.global.events,
        role = "rl",
        actor = "Leader-Realm",
        now = env.ns.Platform.ServerTime,
        newId = function()
          return id
        end,
      }, { title = "Event " .. id })
    end
    local raid = env.raid("summary")
    local first = env.find(raid, "Button", "> 1. Event ev-1 [planned]")
    assert.is_truthy(first)
    env.find(raid, "Button", "2. Event ev-2 [planned]").callbacks.OnClick()
    raid = env.raid("summary")
    assert.is_truthy(env.find(raid, "Button", "> 2. Event ev-2 [planned]"))
  end)

  it("applies, votes, awards and closes from the Loot tab", function()
    local ns = env.ns
    ns.db.global.events["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      attendance = {},
      assignments = {},
      loot = {},
    }
    local loot = env.open("loot")
    local item = env.find(loot, "EditBox", "Item link (shift-click the item into this box)")
    assert.is_nil(item, "an RL cannot open sessions")

    local council = build("Council")
    council.ns.db.global.events["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      attendance = {},
      assignments = {},
      loot = {},
    }
    loot = council.open("loot")
    council.find(loot, "EditBox", "Item link (shift-click the item into this box)").props.text =
      "|cffa335ee|Hitem:19019::::|h[Thunderfury]|h|r"
    council.find(loot, "Button", "Open").callbacks.OnClick()
    local event = council.ns.db.global.events["ev-1"]
    local session = council.ns.LootService.Sessions(event)[1]
    assert.are.equal("Thunderfury", session.itemName)

    loot = council.open("loot")
    council.find(loot, "EditBox", "Spec").props.text = "Fury"
    council.find(loot, "Button", "Apply: main").callbacks.OnClick()
    assert.is_truthy(session.candidates["Leader-Realm"])

    loot = council.open("loot")
    council.find(loot, "Button", "Vote").callbacks.OnClick()
    assert.are.equal("Pick a candidate first.", council.find(council.open("loot"), "Label").props.text)

    loot = council.open("loot")
    council.find(loot, "Dropdown", "Candidate").callbacks.OnValueChanged(nil, nil, "Leader-Realm")
    council.find(loot, "Button", "Vote").callbacks.OnClick()
    assert.is_truthy(next(session.votes))

    loot = council.open("loot")
    council.find(loot, "Dropdown", "Candidate").callbacks.OnValueChanged(nil, nil, "Leader-Realm")
    council.find(loot, "EditBox", "Reason for the award").props.text = "highest need"
    council.find(loot, "Button", "Award").callbacks.OnClick()
    assert.are.equal("closed", session.status)
    assert.is_true(council.changes >= 3)
    pcall(council.close)
  end)

  it("opens the voting window by itself for a voter when a session opens, and not for a member", function()
    local function event()
      return { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    end
    local council = build("Council")
    council.ns.db.global.events["ev-1"] = event()
    local before = #council.widgets
    council.ns.LootCommands
      .New({
        events = council.ns.db.global.events,
        platform = council.ns.Platform,
        comm = council.ns.comm,
        onChange = council.ns.UI.LootChanged,
      })
      :OpenItem(council.ns.db.global.events["ev-1"], { itemId = 19019, itemName = "Thunderfury" })
    assert.is_true(#council.widgets > before)
    local window = council.find(council.widgets[before + 1], "Frame") or council.widgets[before + 1]
    assert.are.equal("Frame", window.kind)
    assert.is_truthy(council.find(window, "InteractiveLabel", "|cffffd100Thunderfury|r"))

    local member = build("Soldado")
    member.ns.db.global.events["ev-1"] = event()
    local widgets = #member.widgets
    member.ns.LootCommands
      .New({
        events = member.ns.db.global.events,
        platform = member.ns.Platform,
        comm = member.ns.comm,
        onChange = member.ns.UI.LootChanged,
      })
      :OpenItem(member.ns.db.global.events["ev-1"], { itemId = 1, itemName = "Item" })
    assert.are.equal(widgets, #member.widgets)
  end)

  it("votes, awards and closes from the voting window", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    local event = ns.db.global.events["ev-1"]
    local commands = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      onChange = ns.UI.LootChanged,
    })
    commands:OpenItem(event, { itemId = 19019, itemName = "Thunderfury" })
    commands:OpenItem(event, { itemId = 1, itemName = "Sulfuras" })
    local by_name = {}
    for _, session in ipairs(ns.LootService.Sessions(event)) do
      by_name[session.itemName] = session
    end
    commands:Apply(event, by_name.Thunderfury, { spec = "Fury", need = "main", upgrade = "+12" })
    commands:Apply(event, by_name.Sulfuras, { spec = "Fury", need = "off" })

    council.widgets = {}
    ns.VotingFrame.Show()
    -- Each redraw puts a fresh scroll frame in the (reused) window: the last one is what is on screen.
    local function window()
      for index = #council.widgets, 1, -1 do
        if council.widgets[index].kind == "ScrollFrame" then
          return council.widgets[index]
        end
      end
    end
    assert.is_truthy(window())

    -- The window opens on the first item (Sulfuras): vote for the only candidate, then close it unawarded.
    council.find(window(), "Button", "Vote").callbacks.OnClick()
    assert.is_truthy(next(by_name.Sulfuras.votes))
    council.find(window(), "Button", "Close without awarding").callbacks.OnClick()
    assert.are.equal("closed", by_name.Sulfuras.status)

    -- Switch to Thunderfury, give a reason, and award it.
    council.find(window(), "InteractiveLabel", "Thunderfury").callbacks.OnClick()
    council.find(window(), "EditBox", "Reason for the award (used by the Award buttons)").props.text = "highest need"
    -- The first click only asks to confirm; nothing is given away yet.
    council.find(window(), "Button", "Award").callbacks.OnClick()
    assert.are.equal("open", by_name.Thunderfury.status)
    assert.is_truthy(
      council.find(window(), "Label", "Award Thunderfury to Leader-Realm? Click Confirm to give it away.")
    )
    council.find(window(), "Button", "Confirm").callbacks.OnClick()
    assert.are.equal("closed", by_name.Thunderfury.status)
    assert.are.equal("Leader-Realm", by_name.Thunderfury.award.characterKey)
  end)

  it("drops a pending award confirmation when something else is done", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    local event = ns.db.global.events["ev-1"]
    local commands = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      onChange = ns.UI.LootChanged,
    })
    commands:OpenItem(event, { itemId = 1, itemName = "Sulfuras" })
    local session = ns.LootService.Sessions(event)[1]
    commands:Apply(event, session, { spec = "Fury", need = "main" })
    council.widgets = {}
    ns.VotingFrame.Show()
    local function window()
      for index = #council.widgets, 1, -1 do
        if council.widgets[index].kind == "ScrollFrame" then
          return council.widgets[index]
        end
      end
    end
    council.find(window(), "Button", "Award").callbacks.OnClick()
    assert.is_truthy(council.find(window(), "Button", "Confirm"))
    council.find(window(), "Button", "Vote").callbacks.OnClick()
    assert.is_nil(council.find(window(), "Button", "Confirm"))
    assert.are.equal("open", session.status)
  end)

  it("sorts and filters the candidates from the voting window", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    local event = ns.db.global.events["ev-1"]
    local commands = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      onChange = ns.UI.LootChanged,
    })
    commands:OpenItem(event, { itemId = 1, itemName = "Sulfuras" })
    local session = ns.LootService.Sessions(event)[1]
    commands:Apply(event, session, { spec = "Fury", need = "main" })
    for name, need in pairs({ ["Zed-Realm"] = "off", ["Amy-Realm"] = "other" }) do
      ns.LootService.Register({
        events = ns.db.global.events,
        role = "member",
        actor = name,
        now = ns.Platform.ServerTime,
        newId = function() end,
      }, "ev-1", session.sessionId, { spec = "Spec", need = need })
    end
    council.widgets = {}
    ns.VotingFrame.Show()
    local function window()
      for index = #council.widgets, 1, -1 do
        if council.widgets[index].kind == "ScrollFrame" then
          return council.widgets[index]
        end
      end
    end
    local function names()
      local out = {}
      walk_labels(window(), out)
      return out
    end

    -- Click "Name": ascending, then again: descending.
    council.find(window(), "InteractiveLabel", "|cffffd100Name|r").callbacks.OnClick()
    assert.are.same({ "Amy-Realm", "Leader-Realm", "Zed-Realm" }, names())
    council.find(window(), "InteractiveLabel", "|cffffd100Name ^|r").callbacks.OnClick()
    assert.are.same({ "Zed-Realm", "Leader-Realm", "Amy-Realm" }, names())

    -- Only one kind of answer.
    council.find(window(), "Dropdown", "Show").callbacks.OnValueChanged(nil, nil, "off")
    assert.are.same({ "Zed-Realm" }, names())
    council.find(window(), "Dropdown", "Show").callbacks.OnValueChanged(nil, nil, "all")
    assert.are.equal(3, #names())
  end)

  it("shows the item level and slot, and what a candidate has already won", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    ns.db.global.events["ev-0"] = {
      eventId = "ev-0",
      title = "Last week",
      status = "closed",
      attendance = {},
      assignments = {},
      loot = {
        old = {
          sessionId = "old",
          itemName = "Sulfuras",
          status = "closed",
          candidates = {},
          votes = {},
          award = { characterKey = "Leader-Realm", reason = "need", awardedBy = "Boss", at = 5 },
        },
      },
    }
    local event = ns.db.global.events["ev-1"]
    local commands = ns.LootCommands.New({
      events = ns.db.global.events,
      platform = ns.Platform,
      comm = ns.comm,
      onChange = ns.UI.LootChanged,
    })
    commands:OpenItem(event, { itemId = 19019, itemName = "Thunderfury" })
    commands:Apply(event, ns.LootService.Sessions(event)[1], { spec = "Fury", need = "main" })

    council.widgets = {}
    ns.VotingFrame.Show()
    local scroll
    for index = #council.widgets, 1, -1 do
      if council.widgets[index].kind == "ScrollFrame" then
        scroll = council.widgets[index]
        break
      end
    end
    assert.is_truthy(council.find(scroll, "Label", "ilvl 213 - Two-Hand"))

    local name = council.find(scroll, "InteractiveLabel", "Leader-Realm")
    local lines = {}
    _G.GameTooltip.AddLine = function(_, text)
      lines[#lines + 1] = text
    end
    name.callbacks.OnEnter(name)
    assert.are.same({ "Leader-Realm", "Sulfuras (Last week)" }, lines)
    name.callbacks.OnLeave()
    assert.is_false(council.tooltip.shown)
  end)

  it("remembers where the windows are left", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    ns.VotingFrame.Show()
    local saved = ns.db.global.settings.windows.voting
    assert.are.equal(760, saved.width)
    assert.are.equal(460, saved.height)

    -- A size the player chose is kept, not replaced by the default.
    saved.width = 900
    pcall(council.close)
    ns.UI.ApplyWindowStatus(council.widgets[#council.widgets], "voting", 760, 460)
    assert.are.equal(900, ns.db.global.settings.windows.voting.width)

    ns.UI.OpenTab("home")
    assert.are.equal(1000, ns.db.global.settings.windows.mainWindow.width)
    assert.are.equal(640, ns.db.global.settings.windows.mainWindow.height)
  end)

  it("shows the loot items with their icon and tooltip instead of buttons", function()
    local council = build("Council")
    local ns = council.ns
    ns.db.global.events["ev-1"] =
      { eventId = "ev-1", title = "Raid", status = "open", attendance = {}, assignments = {}, loot = {} }
    local event = ns.db.global.events["ev-1"]
    ns.LootCommands
      .New({ events = ns.db.global.events, platform = ns.Platform, comm = ns.comm, onChange = ns.UI.LootChanged })
      :OpenItem(event, { itemId = 19019, itemName = "Thunderfury" })

    council.widgets = {}
    ns.VotingFrame.Show()
    local scroll
    for index = #council.widgets, 1, -1 do
      if council.widgets[index].kind == "ScrollFrame" then
        scroll = council.widgets[index]
        break
      end
    end
    assert.is_nil(council.find(scroll, "Button", "Thunderfury"))
    local item = council.find(scroll, "InteractiveLabel", "|cffffd100Thunderfury|r")
    assert.is_truthy(item)
    assert.are.equal("icon:19019", item.props.image)

    item.callbacks.OnEnter(item)
    assert.are.equal("item:19019", council.tooltip.link)
    assert.is_true(council.tooltip.shown)
    item.callbacks.OnLeave()
    assert.is_false(council.tooltip.shown)

    council.tooltip.refuse = true
    item.callbacks.OnEnter(item)
    assert.is_false(council.tooltip.shown)
  end)

  it("confirms a manual readiness item and asks for the Home tab too", function()
    local ready = env.open("ready")
    env.find(ready, "Dropdown", "Consumables ready").callbacks.OnValueChanged(nil, nil, "met")
    assert.are.equal("met", env.ns.character.readiness.consumables.status)
  end)

  it("opens the window on a given tab and closes it on the second toggle", function()
    assert.is_truthy(env.open("roster"))
    env.ns.UI.OpenTab("loot")
    env.close()
  end)
end)

describe("Blacklist tab", function()
  local env

  local function labels(root)
    local found = {}
    walk(root, function(widget)
      if (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text then
        found[#found + 1] = widget.props.text
      end
    end)
    return table.concat(found, "\n")
  end

  local function add_entry(key, name, reason)
    env.ns.db.global.blacklist[key] = {
      name = name,
      reason = reason,
      addedBy = "Ann-Realm",
      addedAt = 500,
      rev = 1,
      updatedAt = 500,
      updatedBy = "Ann-Realm",
    }
  end

  after_each(function()
    pcall(env.close)
  end)

  it("draws the form, and says so when the list is empty", function()
    env = build("Member")
    local tab = env.open("blacklist")
    assert.is_truthy(env.find(tab, "EditBox", "Name"))
    assert.is_truthy(env.find(tab, "EditBox", "Reason"))
    assert.is_truthy(env.find(tab, "Button", "Add"))
    assert.is_truthy(labels(tab):find("Nobody is on the blacklist.", 1, true))
  end)

  it("adds a player from the form and sends it", function()
    env = build("Member")
    local tab = env.open("blacklist")
    env.find(tab, "EditBox", "Name"):SetText("Yonemon Gg")
    env.find(tab, "EditBox", "Reason"):SetText("stole loot")
    env.find(tab, "Button", "Add").callbacks.OnClick()

    assert.are.equal("stole loot", env.ns.db.global.blacklist.yonemongg.reason)
    assert.are.same({ "SendBlacklistUpsert" }, env.sent)
    tab = env.open("blacklist")
    assert.is_truthy(labels(tab):find("Yonemon Gg", 1, true))
    assert.is_truthy(labels(tab):find("stole loot", 1, true))
    assert.is_truthy(labels(tab):find("Leader-Realm, date:1000", 1, true))
  end)

  it("shows a validation error and sends nothing", function()
    env = build("Member")
    local tab = env.open("blacklist")
    env.find(tab, "EditBox", "Name"):SetText("Ann")
    env.find(tab, "Button", "Add").callbacks.OnClick()
    tab = env.open("blacklist")
    assert.is_truthy(labels(tab):find("enter a reason", 1, true))
    assert.are.same({}, env.sent)
    assert.is_nil(next(env.ns.db.global.blacklist))
  end)

  it("hides Remove from everyone but the guild master and officers", function()
    for _, rank in ipairs({ "Member", "RL", "Council" }) do
      env = build(rank)
      add_entry("ann", "Ann", "ninja")
      local tab = env.open("blacklist")
      assert.is_truthy(labels(tab):find("ninja", 1, true))
      assert.is_nil(env.find(tab, "Button", "Remove"), rank)
      env.close()
    end
  end)

  it("lets an officer remove a player", function()
    env = build("Officer")
    add_entry("ann", "Ann", "ninja")
    add_entry("zed", "Zed", "afk")
    local tab = env.open("blacklist")
    env.find(tab, "Button", "Remove").callbacks.OnClick()
    assert.is_nil(env.ns.db.global.blacklist.ann)
    assert.is_truthy(env.ns.db.global.blacklist.zed)
    assert.are.same({ "SendBlacklistDelete" }, env.sent)
    assert.is_truthy(env.ns.db.global.sync.tombstones["B:ann"])
  end)

  it("sorts the list by name and escapes it", function()
    env = build("GM")
    add_entry("zed", "Zed", "afk")
    add_entry("ann", "Ann", "|Hbad|h")
    local text = labels(env.open("blacklist"))
    assert.is_truthy(text:find("||Hbad||h", 1, true))
    assert.is_true(text:find("Ann", 1, true) < text:find("Zed", 1, true))
  end)

  it("redraws when an entry arrives, but not more than once per interval, and only on its own tab", function()
    env = build("Member")
    local clock = 100
    env.ns.Platform.Now = function()
      return clock
    end
    env.open("blacklist")
    env.timers = nil
    env.widgets = {}
    env.ns.UI.BlacklistChanged()
    assert.is_true(#env.widgets > 0)
    env.widgets = {}
    env.ns.UI.BlacklistChanged()
    env.ns.UI.BlacklistChanged()
    assert.are.equal(0, #env.widgets)
    assert.are.equal(1, #env.timers)
    clock = clock + env.ns.Constants.BLACKLIST_REDRAW_SECONDS
    env.timers[1]()
    assert.is_true(#env.widgets > 0)

    env.open("home")
    env.widgets = {}
    env.ns.UI.BlacklistChanged()
    assert.are.equal(0, #env.widgets)
  end)

  it("does nothing when the window is closed", function()
    env = build("Member")
    assert.has_no.errors(function()
      env.ns.UI.BlacklistChanged()
    end)
  end)
end)

local function vim_has(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

describe("Loot minutes button", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  local function event_with_a_decision()
    return {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      attendance = {},
      assignments = {},
      loot = {
        s1 = {
          sessionId = "s1",
          itemId = 19019,
          itemName = "Thunderfury",
          status = "closed",
          updatedAt = 5,
          candidates = {},
          votes = {},
          award = { characterKey = "Ann-Realm", awardedBy = "Boss-Realm", reason = "Highest need" },
        },
      },
    }
  end

  local function labels(root)
    local found = {}
    walk(root, function(widget)
      if (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text then
        found[#found + 1] = widget.props.text
      end
    end)
    return table.concat(found, "\n")
  end

  it("shows the minutes of the event after a click, and hides them after another", function()
    env = build("Member")
    env.ns.db.global.events["ev-1"] = event_with_a_decision()
    local loot = env.open("loot")
    assert.is_nil(labels(loot):find("Loot minutes", 1, true))
    env.find(loot, "Button", "Show the minutes").callbacks.OnClick()
    loot = env.open("loot")
    local text = labels(loot)
    assert.is_truthy(text:find("Loot minutes for 'Raid':", 1, true))
    assert.is_truthy(text:find("Thunderfury -> Ann-Realm (by Boss-Realm): Highest need", 1, true))
    env.find(loot, "Button", "Hide the minutes").callbacks.OnClick()
    assert.is_nil(labels(env.open("loot")):find("Loot minutes", 1, true))
  end)

  it("is in Spanish on a Spanish client", function()
    env = build("Member", "esES")
    env.ns.db.global.events["ev-1"] = event_with_a_decision()
    local loot = env.open("loot")
    env.find(loot, "Button", "Mostrar el acta").callbacks.OnClick()
    local text = labels(env.open("loot"))
    assert.is_truthy(text:find("Acta del loot de 'Raid':", 1, true))
    assert.is_truthy(text:find("Thunderfury -> Ann-Realm (por Boss-Realm): Highest need", 1, true))
  end)
end)

describe("Rules tab", function()
  local env

  local function labels(root)
    local found = {}
    walk(root, function(widget)
      if (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text then
        found[#found + 1] = widget.props.text
      end
    end)
    return table.concat(found, "\n")
  end

  after_each(function()
    pcall(env.close)
  end)

  local function tab_values()
    -- The entries of the sidebar the window drew last.
    local nodes, sidebar = env.ns.Kit.fake.nodes, nil
    for _, node in ipairs(nodes) do
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

  it("is offered only to the guild master and officers", function()
    for _, rank in ipairs({ "Member", "RL", "Council" }) do
      env = build(rank)
      env.open("home")
      assert.is_false(vim_has(tab_values(), "rules"), rank)
      pcall(env.close)
    end
    env = build("GM")
    env.open("home")
    assert.is_true(vim_has(tab_values(), "rules"))
  end)

  it("says it is for admins when anyone else gets there", function()
    env = build("Member")
    local tab = env.open("rules")
    assert.is_truthy(labels(tab):find("Only the guild master and officers", 1, true))
    assert.is_nil(env.find(tab, "Button", "Add rule"))
  end)

  it("lists the rules in force and the form to add one", function()
    env = build("GM")
    local tab = env.open("rules")
    assert.is_truthy(labels(tab):find("Starting rules", 1, true))
    assert.is_truthy(labels(tab):find("level 60 or more", 1, true))
    assert.is_truthy(env.find(tab, "Button", "Add rule"))
    assert.is_truthy(env.find(tab, "Button", "Use the starting list"))
    assert.is_truthy(env.find(tab, "EditBox", "Name"))
  end)

  it("adds a rule from the form, as a new set for the guild", function()
    env = build("GM")
    local tab = env.open("rules")
    env.find(tab, "EditBox", "Name"):SetText("Item level 100")
    env.find(tab, "EditBox", "Details: a number, e.g. 60"):SetText("100")
    env.find(tab, "Button", "Add rule").callbacks.OnClick()
    assert.are.same({ "SetReadinessRules" }, env.sent)
    local rules = env.ns.db.global.readinessRules.rules
    assert.are.equal(#env.ns.Constants.DEFAULT_RULES + 1, #rules)
    assert.are.equal("item_level_100", rules[#rules].id)
    tab = env.open("rules")
    assert.is_truthy(labels(tab):find("revision 1", 1, true))
  end)

  it("shows why a rule was not saved and sends nothing", function()
    env = build("GM")
    local tab = env.open("rules")
    env.find(tab, "EditBox", "Name"):SetText("Level")
    env.find(tab, "EditBox", "Details: a number, e.g. 60"):SetText("abc")
    env.find(tab, "Button", "Add rule").callbacks.OnClick()
    tab = env.open("rules")
    assert.is_truthy(labels(tab):find("Not saved", 1, true))
    assert.are.same({}, env.sent)
  end)

  it("removes a rule, but not the last one", function()
    env = build("GM")
    env.ns.db.global.readinessRules.rules = { { id = "a", label = "A", check = "confirm" } }
    env.ns.db.global.readinessRules.rev = 1
    local tab = env.open("rules")
    env.find(tab, "Button", "Remove").callbacks.OnClick()
    tab = env.open("rules")
    assert.is_truthy(labels(tab):find("keep at least one rule", 1, true))
    assert.are.equal(1, #env.ns.db.global.readinessRules.rules)
  end)
end)

describe("Window in Spanish", function()
  local env

  after_each(function()
    pcall(env.close)
  end)

  it("draws every tab, for an admin, without a formatting error", function()
    env = build("GM", "esES")
    local tabs = env.ns.ViewModel.TabsFor("admin")
    for _, tab in ipairs(tabs) do
      assert.is_truthy(env.open(tab.value), tab.value)
    end
  end)

  it("shows the Spanish texts", function()
    env = build("GM", "esES")
    local tab = env.open("rules")
    assert.is_truthy(env.find(tab, "Button", "Añadir regla"))
    assert.is_truthy(env.find(tab, "Button", "Usar la lista inicial"))
    tab = env.open("blacklist")
    assert.is_truthy(env.find(tab, "EditBox", "Motivo"))
  end)

  it("keeps the window in English for a client that is not Spanish", function()
    env = build("GM", "frFR")
    local tab = env.open("rules")
    assert.is_truthy(env.find(tab, "Button", "Add rule"))
  end)
end)

describe("Controls that replace the slash commands", function()
  local env

  local function labels(root)
    local found = {}
    walk(root, function(widget)
      if (widget.kind == "Label" or widget.kind == "InteractiveLabel") and widget.props.text then
        found[#found + 1] = widget.props.text
      end
    end)
    return table.concat(found, "\n")
  end

  after_each(function()
    pcall(env.close)
  end)

  describe("on the Home tab", function()
    it("shows the guild rank and the addon role, and asks the guild for a sync", function()
      env = build("GM")
      local home = env.open("home")
      assert.is_truthy(labels(home):find("guild rank: GM", 1, true))
      assert.is_truthy(labels(home):find("addon role: admin", 1, true))
      env.find(home, "Button", "Request a sync").callbacks.OnClick()
      assert.are.same({ "RequestSync" }, env.sent)
    end)

    it("has the settings behind the gear of the header, not on the Home tab", function()
      env = build("Member")
      local home = env.open("home")
      assert.is_nil(env.find(home, "CheckBox"))
      assert.is_nil(env.find(home, "Button", "Reset the button position"))
      assert.is_truthy(env.ns.UI.IsOpen())
    end)
  end)

  describe("in the settings popover", function()
    local function open_settings()
      env = build("Member")
      env.open("home")
      env.ns.UI.ToggleSettings()
      return env.ns.Kit.Popup.Get(1).stack
    end

    it("hides and shows the minimap button, and puts it back in its place", function()
      local stack = open_settings()
      local switch = env.fakeKit.find(stack, "Switch", "Show the minimap button")
      assert.is_true(switch.opts.checked)
      switch.opts.onChange(false)
      assert.is_true(env.ns.MinimapButton.Settings(env.ns.db).hide)
      switch.opts.onChange(true)
      assert.is_false(env.ns.MinimapButton.Settings(env.ns.db).hide)
      env.ns.MinimapButton.Settings(env.ns.db).angle = 10
      env.fakeKit.press(env.fakeKit.find(stack, "Button", "Reset"))
      assert.are.equal(env.ns.Constants.MINIMAP_DEFAULT_ANGLE, env.ns.MinimapButton.Settings(env.ns.db).angle)
    end)

    it("saves the blacklist alert sound switch, on by default", function()
      local stack = open_settings()
      local switch = env.fakeKit.find(stack, "Switch", "Blacklist alert sound")
      assert.is_true(switch.opts.checked)
      switch.opts.onChange(false)
      assert.is_false(env.ns.Settings.BlacklistSound(env.ns.db))
    end)

    it("changes the language and draws the window again in it", function()
      local stack = open_settings()
      local dropdown = env.fakeKit.find_all(stack, "Dropdown")[1]
      assert.are.equal("auto", dropdown.opts.value)
      dropdown.opts.onChange("es")
      assert.are.equal("es", env.ns.Settings.Language(env.ns.db))
      assert.are.equal("es", env.ns.Locale.Language())
      assert.are.equal("Inicio", env.ns.ViewModel.TABS[1].text)
      dropdown.opts.onChange("en")
      assert.are.equal("Home", env.ns.ViewModel.TABS[1].text)
    end)

    it("closes on the second press of the gear", function()
      open_settings()
      assert.is_true(env.ns.Kit.Popup.Get(1):IsOpen())
      env.ns.UI.ToggleSettings()
      assert.is_false(env.ns.Kit.Popup.Get(1):IsOpen())
    end)
  end)

  describe("on the Profile tab", function()
    it("saves the declared role, main and notes", function()
      env = build("Member")
      local profile = env.open("profile")
      env.find(profile, "Dropdown", "Main spec").callbacks.OnValueChanged(nil, nil, "Tank")
      assert.are.equal("Tank", env.ns.character.profile.fields.role.value)
      profile = env.open("profile")
      env.find(profile, "Dropdown", "Second spec").callbacks.OnValueChanged(nil, nil, "Heal")
      assert.are.equal("Heal", env.ns.character.profile.fields.role2.value)
      profile = env.open("profile")
      env.find(profile, "Dropdown", "Second spec").callbacks.OnValueChanged(nil, nil, "")
      assert.is_nil(env.ns.character.profile.fields.role2)
      profile = env.open("profile")
      env.find(profile, "EditBox", "Notes (these stay on this computer)").callbacks.OnEnterPressed(nil, nil, "weekends")
      assert.are.equal("weekends", env.ns.character.profile.fields.notes.value)
    end)

    it("shows a legacy role as selected when unambiguous and as unselected otherwise", function()
      env = build("Member")
      env.ns.character.profile.fields = { role = { value = "healer", source = "declared", at = 1 } }
      assert.are.equal("Heal", env.find(env.open("profile"), "Dropdown", "Main spec").props.value)
      env.ns.character.profile.fields.role.value = "wizard"
      assert.is_nil(env.find(env.open("profile"), "Dropdown", "Main spec").props.value)
    end)

    it("says why a value was not saved", function()
      env = build("Member")
      local profile = env.open("profile")
      env.find(profile, "EditBox", "Main character").callbacks.OnEnterPressed(nil, nil, string.rep("x", 500))
      profile = env.open("profile")
      assert.is_truthy(labels(profile):find("Not saved: value is too long.", 1, true))
      assert.is_nil(env.ns.character.profile.fields.main)
    end)
  end)

  describe("on the Raid tab", function()
    it("offers Export to everyone and Import only to who may manage events", function()
      env = build("Member")
      local raid = env.open("raid")
      assert.is_truthy(env.find(raid, "Button", "Export"))
      assert.is_nil(env.find(raid, "Button", "Import"))
      pcall(env.close)
      env = build("RL")
      raid = env.open("raid")
      assert.is_truthy(env.find(raid, "Button", "Export"))
      assert.is_truthy(env.find(raid, "Button", "Import"))
    end)

    it("opens the export and import windows from the buttons", function()
      env = build("RL")
      local opened = {}
      env.ns.UI.ShowTransfer = function(mode)
        opened[#opened + 1] = mode
      end
      local raid = env.open("raid")
      env.find(raid, "Button", "Export").callbacks.OnClick()
      env.find(raid, "Button", "Import").callbacks.OnClick()
      assert.are.same({ "export", "import" }, opened)
    end)

    it("has a Reports sub-tab for every role with the attendance and loot reports", function()
      env = build("Member")
      env.ns.EventService.Create({
        events = env.ns.db.global.events,
        role = "rl",
        actor = "Leader-Realm",
        now = env.ns.Platform.ServerTime,
        newId = function()
          return "ev-1"
        end,
      }, { title = "Raid" })
      local raid = env.raid("reports")
      local text = labels(raid)
      assert.is_truthy(text:find("ttendance", 1, true))
      assert.is_truthy(text:find("oot", 1, true))
      assert.is_truthy(env.find(raid, "Dropdown", "Scope"))
      env.find(raid, "Dropdown", "Scope").callbacks.OnValueChanged(nil, nil, "all")
    end)
  end)

  describe("on the Raid tab, for the commands that deleted things", function()
    local function create_event()
      env.ns.EventService.Create({
        events = env.ns.db.global.events,
        role = "rl",
        actor = "Leader-Realm",
        now = env.ns.Platform.ServerTime,
        newId = function()
          return "ev-1"
        end,
      }, { title = "Raid night" })
    end

    it("deletes an event only after a second click on the button", function()
      env = build("RL")
      create_event()
      local raid = env.raid("details")
      env.find(raid, "Button", "Delete this event").callbacks.OnClick()
      assert.is_truthy(env.ns.db.global.events["ev-1"])
      assert.are.same({}, env.sent)
      raid = env.raid("details")
      assert.is_truthy(labels(raid):find("Delete 'Raid night'?", 1, true))
      env.find(raid, "Button", "Confirm: delete this event").callbacks.OnClick()
      assert.is_nil(env.ns.db.global.events["ev-1"])
      assert.are.same({ "SendDeleteEvent" }, env.sent)
    end)

    it("deletes a saved template", function()
      env = build("RL")
      create_event()
      env.ns.db.global.templates.Boss =
        { name = "Boss", slots = { { encounter = "Garr", characterKey = "Bob-Realm" } } }
      local raid = env.raid("templates")
      env.find(raid, "Dropdown", "Saved templates").callbacks.OnValueChanged(nil, nil, "Boss")
      env.find(raid, "Button", "Delete template").callbacks.OnClick()
      assert.is_nil(env.ns.db.global.templates.Boss)
    end)
  end)

  describe("on the PvP ranking", function()
    local function open_ranking()
      env.ns.db.global.pvpStats = {
        ["Ann-Realm"] = { honor = { world = 30, bg = 20 }, updatedAt = 900, rev = 1 },
      }
      local pvp = env.open("pvp")
      env.find(pvp, "TabGroup"):SelectTab("ranking")
      return pvp
    end

    it("offers the reset to an admin only", function()
      env = build("Member")
      assert.is_nil(env.find(open_ranking(), "Button", "Reset PvP counters"))
      pcall(env.close)
      env = build("GM")
      assert.is_truthy(env.find(open_ranking(), "Button", "Reset PvP counters"))
    end)

    it("asks to confirm before it resets a member", function()
      env = build("GM")
      local pvp = open_ranking()
      env.find(pvp, "Dropdown", "Member").callbacks.OnValueChanged(nil, nil, "Ann-Realm")
      env.find(pvp, "Button", "Reset PvP counters").callbacks.OnClick()
      assert.are.same({}, env.sent)
      pvp = env.open("pvp")
      env.find(pvp, "TabGroup"):SelectTab("ranking")
      assert.is_truthy(labels(pvp):find("Reset the PvP counters of Ann-Realm?", 1, true))
      env.find(pvp, "Button", "Confirm").callbacks.OnClick()
      assert.are.same({ "ResetPvP:Ann-Realm" }, env.sent)
    end)
  end)
end)
