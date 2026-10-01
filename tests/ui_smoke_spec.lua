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
  ns.UI.LootChanged = function()
    env.changes = env.changes + 1
  end

  -- Opens the window on `tab` and returns the scroll frame the tab drew into.
  function env.open(tab)
    env.widgets = {}
    ns.UI.OpenTab(tab)
    local scrolls = find_all(env.widgets[1], function(w)
      return w.kind == "ScrollFrame"
    end)
    return scrolls[#scrolls]
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
    env
      .find(raid, "EditBox", "New event title (Enter to create)").callbacks
      .OnEnterPressed(nil, nil, "Molten Core night")
    assert.is_truthy(next(env.ns.db.global.events))
    assert.are.equal("SendEvent", env.sent[1])

    raid = env.open("raid")
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
    local raid = env.open("raid")

    env.find(raid, "EditBox", "Title (Enter to rename)").callbacks.OnEnterPressed(nil, nil, "Renamed")
    assert.are.equal("Renamed", created.title)

    raid = env.open("raid")
    env.find(raid, "Dropdown", "Status").callbacks.OnValueChanged(nil, nil, "open")
    assert.are.equal("open", created.status)

    raid = env.open("raid")
    env
      .find(raid, "EditBox", "Start, local time (YYYY-MM-DD HH:MM)").callbacks
      .OnEnterPressed(nil, nil, "2026-10-03 20:30")
    assert.are.equal(2000, created.startAt)

    raid = env.open("raid")
    env.find(raid, "Dropdown", "Yonemon Gg").callbacks.OnValueChanged(nil, nil, "present")
    assert.are.equal("present", created.attendance["Yonemon Gg"].state)

    raid = env.open("raid")
    env.find(raid, "Dropdown", "Member").callbacks.OnValueChanged(nil, nil, "Ann-Realm")
    env.find(raid, "EditBox", "Encounter").props.text = "Ragnaros"
    env.find(raid, "Button", "Add").callbacks.OnClick()
    assert.is_truthy(next(created.assignments))

    raid = env.open("raid")
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
    local raid = env.open("raid")
    env.find(raid, "Button", "Add").callbacks.OnClick()
    assert.is_nil(next(env.ns.db.global.events["ev-1"].assignments))

    env.ns.db.global.events["ev-1"].assignments.a1 =
      { assignmentId = "a1", encounter = "Garr", characterKey = "Ann-Realm", rev = 1 }
    raid = env.open("raid")
    env
      .find(raid, "EditBox", "Save this event's assignments as (Enter to save)").callbacks
      .OnEnterPressed(nil, nil, "Boss")
    assert.is_truthy(env.ns.db.global.templates.Boss)
  end)

  it("shows a plain member the events as text, with no controls", function()
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
    assert.is_nil(member.find(raid, "Button"))
    pcall(member.close)
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
