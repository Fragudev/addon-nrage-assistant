-- A smoke test of the window (UI/Main.lua) against a fake AceGUI. It cannot say how anything looks, but it
-- draws every tab for each kind of player and presses the buttons, which catches the nil calls and wrong
-- argument orders that are otherwise only found in the game.

-- A widget that accepts any method. Containers record their children; text, value and callbacks are kept
-- so the test can read them and press things.
local function new_widget(kind, registry)
  local widget = { kind = kind, children = {}, callbacks = {}, props = {} }
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

local function find_all(root, predicate)
  local found = {}
  walk(root, function(widget)
    if predicate(widget) then
      found[#found + 1] = widget
    end
  end)
  return found
end

local function load_window()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Core/Args",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/TemplateService",
    "Domain/ReadinessService",
    "Domain/ProfileService",
    "Domain/PublishService",
    "UI/ViewModel",
    "Commands/RaidCommands",
    "Commands/LootCommands",
    "Commands/TemplateCommands",
    "UI/Main",
    "UI/VotingFrame",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local function build(rank)
  local ns = load_window()
  local env = { ns = ns, widgets = {}, sent = {}, counter = 0, changes = 0 }

  _G.LibStub = function()
    return {
      Create = function(_, kind)
        return new_widget(kind, env.widgets)
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
    IsChatMessagingLockedDown = function()
      return false
    end,
  }
  ns.db = { global = { events = {}, roster = {}, templates = {}, sync = { tombstones = {} } } }
  ns.character = { profile = { fields = {} }, consent = {}, readiness = {}, publish = {} }
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
  }
  for _, kind in ipairs({
    "SendEvent",
    "SendAttendance",
    "SendAssignment",
    "SendDeleteAssignment",
    "SendLootSession",
    "SendLootCandidate",
    "SendLootVote",
    "SendLootAward",
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
    local scrolls = find_all(env.widgets[1], function(w)
      return w.kind == "ScrollFrame"
    end)
    return scrolls[#scrolls]
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
    assert.are.same({ { value = "summary", text = "Summary" } }, sub.props.tabs)
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
    assert.are.equal(5, #sub.props.tabs)

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
    assert.is_truthy(council.find(window, "Button", "> Thunderfury"))

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
    council.find(window(), "Button", "Thunderfury").callbacks.OnClick()
    council.find(window(), "EditBox", "Reason for the award (used by the Award buttons)").props.text = "highest need"
    council.find(window(), "Button", "Award").callbacks.OnClick()
    assert.are.equal("closed", by_name.Thunderfury.status)
    assert.are.equal("Leader-Realm", by_name.Thunderfury.award.characterKey)
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
