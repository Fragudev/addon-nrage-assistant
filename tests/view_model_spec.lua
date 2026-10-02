-- `locale` (optional) is the client locale code to load it for, e.g. "esES".
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/ReadinessRules",
    "Domain/ReadinessService",
    "UI/ViewModel",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns.Constants
end

local ViewModel, Constants = load_view_model()

describe("ViewModel.Escape", function()
  it("doubles pipes so text cannot start a colour code or link", function()
    assert.are.equal("||cffff0000red||r", ViewModel.Escape("|cffff0000red|r"))
  end)

  it("accepts non-strings", function()
    assert.are.equal("60", ViewModel.Escape(60))
  end)
end)

describe("ViewModel.Home", function()
  it("shows version, readiness and sync state", function()
    local text = table.concat(
      ViewModel.Home({
        version = "0.1.0",
        readinessText = "1/3 met, 2 unknown",
        syncLines = { "sync paused: encounter in progress", "queued messages: 1" },
      }),
      "\n"
    )
    assert.is_truthy(text:find("Nrage Assistant 0.1.0", 1, true))
    assert.is_truthy(text:find("Your readiness: 1/3 met, 2 unknown", 1, true))
    assert.is_truthy(text:find("  sync paused: encounter in progress", 1, true))
  end)

  it("escapes sync lines, which can contain sender names", function()
    local text = table.concat(
      ViewModel.Home({
        version = "dev",
        readinessText = "0/0 met",
        syncLines = { "  |cffff0000Evil-Realm - addon 1" },
      }),
      "\n"
    )
    assert.is_nil(text:find("[^|]|c"))
    assert.is_truthy(text:find("||cffff0000Evil-Realm", 1, true))
  end)
end)

describe("ViewModel.Roster", function()
  local now = 1000000

  it("explains an empty roster", function()
    local lines = ViewModel.Roster({}, now)
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("No profiles received yet", 1, true))
  end)

  it("lists profiles sorted by name and labelled as received", function()
    local lines = ViewModel.Roster({
      ["Zed-Realm"] = { class = "MAGE", level = 60, receivedAt = now - 10 },
      ["Ann-Realm"] = { class = "WARRIOR", level = 58, ilvl = 190, fields = { role = "tank" }, receivedAt = now - 10 },
    }, now)
    assert.are.equal("2 profile(s) received:", lines[1])
    assert.are.equal("  Ann-Realm - WARRIOR 58, ilvl 190, role tank [received]", lines[2])
    assert.are.equal("  Zed-Realm - MAGE 60 [received]", lines[3])
  end)

  it("labels old data as stale, never as received", function()
    local lines = ViewModel.Roster({
      ["Old-Realm"] = { class = "MAGE", level = 60, receivedAt = now - Constants.ROSTER_STALE_SECONDS - 1 },
    }, now)
    assert.is_truthy(lines[2]:find("[stale]", 1, true))
    assert.is_nil(lines[2]:find("[received]", 1, true))
  end)

  it("treats a missing timestamp as stale", function()
    local lines = ViewModel.Roster({ ["X-Realm"] = { class = "MAGE", level = 1 } }, now)
    assert.is_truthy(lines[2]:find("[stale]", 1, true))
  end)

  it("escapes received text", function()
    local lines = ViewModel.Roster({
      ["|cffff0000Bad-Realm"] = {
        class = "MAGE",
        level = 1,
        fields = { role = "|Hitem:1|h" },
        receivedAt = now,
      },
    }, now)
    assert.is_truthy(lines[2]:find("||cffff0000Bad-Realm", 1, true))
    assert.is_truthy(lines[2]:find("||Hitem:1||h", 1, true))
  end)
end)

describe("ViewModel misc", function()
  it("turns a publish failure reason into a sentence", function()
    assert.is_truthy(ViewModel.PublishError("cooldown"):find("moment ago", 1, true))
    assert.are.equal("something_new", ViewModel.PublishError("something_new"))
  end)

  it("offers a tab for each view", function()
    local values = {}
    for _, tab in ipairs(ViewModel.TABS) do
      values[tab.value] = true
    end
    assert.are.same({
      home = true,
      profile = true,
      ready = true,
      raid = true,
      loot = true,
      pvp = true,
      blacklist = true,
      roster = true,
    }, values)
  end)

  it("puts the Blacklist tab after PvP and before Roster", function()
    local order = {}
    for _, tab in ipairs(ViewModel.TABS) do
      order[#order + 1] = tab.value
    end
    local function index_of(value)
      for index, name in ipairs(order) do
        if name == value then
          return index
        end
      end
    end
    assert.are.equal(index_of("pvp") + 1, index_of("blacklist"))
    assert.are.equal(index_of("blacklist") + 1, index_of("roster"))
    assert.are.equal("Blacklist", ViewModel.TABS[index_of("blacklist")].text)
  end)

  it("documents the three commands that are left in the help", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, command in ipairs({ "/nrage  ", "/nrage help", "/nrage debug" }) do
      assert.is_truthy(text:find(command, 1, true), command)
    end
    assert.are.equal(3, #ViewModel.HelpLines())
  end)
end)

describe("ViewModel.Raid", function()
  local function event(overrides)
    local e = {
      eventId = "ev-1",
      title = "Molten Core",
      status = "open",
      startAt = 5000,
      attendance = {},
      assignments = {},
    }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end
  local format = function(timestamp)
    return "date:" .. timestamp
  end

  it("explains an empty list", function()
    assert.is_truthy(ViewModel.Raid({}, format)[1]:find("No events yet", 1, true))
  end)

  it("numbers events like /nrage event and shows status and date", function()
    local lines = ViewModel.Raid({
      later = event({ eventId = "later", title = "Later", startAt = 9000 }),
      sooner = event({ eventId = "sooner", title = "Sooner", startAt = 1000, status = "planned" }),
    }, format)
    assert.are.equal("1. Sooner [planned] - date:1000", lines[1])
    assert.are.equal("    Attendance: none recorded", lines[2])
    assert.are.equal("2. Later [open] - date:9000", lines[4])
  end)

  it("summarises attendance by state and lists assignments in order", function()
    local e = event()
    e.attendance = {
      ["A-Realm"] = { state = "present" },
      ["B-Realm"] = { state = "present" },
      ["C-Realm"] = { state = "late" },
    }
    e.assignments = {
      a1 = { encounter = "Ragnaros", characterKey = "Zed-Realm", task = "Healer" },
      a2 = { encounter = "Garr", characterKey = "Bob-Realm" },
      a3 = { encounter = "Ragnaros", characterKey = "Ann-Realm" },
    }
    local lines = ViewModel.Raid({ ["ev-1"] = e }, format)
    assert.are.equal("    Attendance: 1 late, 2 present", lines[2])
    assert.are.equal("    Garr: Bob-Realm", lines[3])
    assert.are.equal("    Ragnaros: Ann-Realm", lines[4])
    assert.are.equal("    Ragnaros: Zed-Realm - Healer", lines[5])
  end)

  it("leaves out the date of an undated event", function()
    local lines = ViewModel.Raid({ ["ev-1"] = event({ startAt = false }) }, format)
    assert.are.equal("1. Molten Core [open]", lines[1])
  end)

  it("escapes everything that came from the guild", function()
    local e = event({ title = "|cffff0000Evil" })
    e.attendance["|Hx|h"] = { state = "|cff00ff00late" }
    e.assignments.a1 = { encounter = "|cffffffffBoss", characterKey = "|Hplayer:x|h", task = "|rTank" }
    local text = table.concat(ViewModel.Raid({ ["ev-1"] = e }, format), "\n")
    assert.is_nil(text:find("[^|]|[cHr]"))
    assert.is_truthy(text:find("||cffff0000Evil", 1, true))
    assert.is_truthy(text:find("||cff00ff00late", 1, true))
    assert.is_truthy(text:find("||Hplayer:x||h", 1, true))
  end)
end)

describe("ViewModel.Loot", function()
  local function event(id, title, loot)
    return {
      eventId = id,
      title = title,
      status = "open",
      startAt = 1,
      attendance = {},
      assignments = {},
      loot = loot or {},
    }
  end

  it("explains that there are no sessions and always warns that messages are not private", function()
    local lines = ViewModel.Loot({ ["ev-1"] = event("ev-1", "Raid") })
    assert.is_truthy(lines[1]:find("No loot sessions yet", 1, true))
    assert.is_truthy(lines[#lines]:find("not private", 1, true))
  end)

  it("shows open sessions with aggregate counts only, never who voted for whom", function()
    local lines = ViewModel.Loot({
      ["ev-1"] = event("ev-1", "Molten Core", {
        s1 = {
          sessionId = "s1",
          itemName = "Thunderfury",
          status = "open",
          candidates = { ["Ann-Realm"] = {}, ["Bob-Realm"] = {} },
          votes = { ["Boss-Realm"] = { target = "Ann-Realm" }, ["Two-Realm"] = { target = "Ann-Realm" } },
        },
      }),
    })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("Molten Core", 1, true))
    assert.is_truthy(text:find("Thunderfury [open] - 2 candidate(s), 2 vote(s) cast", 1, true))
    assert.is_nil(text:find("Boss-Realm", 1, true))
  end)

  it("shows the decision and reason of an awarded session, and closed sessions without award", function()
    local lines = ViewModel.Loot({
      ["ev-1"] = event("ev-1", "Molten Core", {
        s1 = {
          sessionId = "s1",
          itemName = "Alpha",
          status = "closed",
          candidates = {},
          votes = {},
          award = { characterKey = "Ann-Realm", reason = "Highest need", awardedBy = "Boss-Realm" },
        },
        s2 = { sessionId = "s2", itemName = "Beta", status = "closed", candidates = {}, votes = {} },
      }),
    })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("Alpha [closed] - awarded to Ann-Realm - Highest need", 1, true))
    assert.is_truthy(text:find("Beta [closed] - closed, not awarded", 1, true))
  end)

  it("lists only the events that have sessions, in event order", function()
    local lines = ViewModel.Loot({
      a = event("a", "Has loot", {
        s1 = { sessionId = "s1", itemName = "X", status = "open", candidates = {}, votes = {} },
      }),
      b = event("b", "No loot"),
    })
    local text = table.concat(lines, "\n")
    assert.is_truthy(text:find("Has loot", 1, true))
    assert.is_nil(text:find("No loot", 1, true))
  end)

  it("escapes everything that came from the guild", function()
    local lines = ViewModel.Loot({
      ["ev-1"] = event("ev-1", "|cffff0000Evil", {
        s1 = {
          sessionId = "s1",
          itemName = "|Hitem:1|h[Bad]|h",
          status = "closed",
          candidates = {},
          votes = {},
          award = { characterKey = "|cff00ff00Ann", reason = "|rwhy" },
        },
      }),
    })
    local text = table.concat(lines, "\n")
    assert.is_nil(text:find("[^|]|[cHr]"))
    assert.is_truthy(text:find("||cffff0000Evil", 1, true))
    assert.is_truthy(text:find("||cff00ff00Ann", 1, true))
  end)
end)

describe("ViewModel raid tab helpers", function()
  it("only offers what the role may do, like the commands", function()
    assert.are.same({ events = false, attendance = false, assignments = false }, ViewModel.RaidActions("member"))
    assert.are.same({ events = false, attendance = false, assignments = false }, ViewModel.RaidActions("council"))
    assert.are.same({ events = false, attendance = false, assignments = false }, ViewModel.RaidActions(nil))
    assert.are.same({ events = true, attendance = true, assignments = true }, ViewModel.RaidActions("rl"))
    assert.are.same({ events = true, attendance = true, assignments = true }, ViewModel.RaidActions("admin"))
  end)

  it("offers every status and attendance state the model accepts, and only those", function()
    local function set(list)
      local out = {}
      for _, value in ipairs(list) do
        out[value] = true
      end
      return out
    end
    local ns = {}
    for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/EventModel" }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    end
    assert.are.same(ns.EventModel.EVENT_STATUSES, set(ViewModel.EVENT_STATUSES))
    assert.are.same(ns.EventModel.ATTENDANCE_STATES, set(ViewModel.ATTENDANCE_STATES))
  end)

  it("lists events in command order, escaped", function()
    local list, order = ViewModel.EventChoices({
      b = { eventId = "b", title = "Later", status = "open", startAt = 20 },
      a = { eventId = "a", title = "|cffff0000Sooner", status = "planned", startAt = 10 },
    })
    assert.are.same({ "a", "b" }, order)
    assert.are.equal("1. ||cffff0000Sooner [planned]", list.a)
    assert.are.equal("2. Later [open]", list.b)
  end)

  describe("AttendanceView", function()
    local function event()
      return {
        attendance = { ["Zed-Realm"] = { state = "late" }, ["Gone-Realm"] = { state = "absent" } },
      }
    end
    local members = { "Ann-Realm", "Zed-Realm", "Yonemon Gg", "Anya-Realm" }

    it("lists only who is recorded, sorted, and nobody else without a filter", function()
      local recorded, matches, matched = ViewModel.AttendanceView(event(), members, "", 8)
      assert.are.equal(2, #recorded)
      assert.are.equal("Gone-Realm", recorded[1].name)
      assert.are.equal("absent", recorded[1].state)
      assert.are.equal("Zed-Realm", recorded[2].name)
      assert.are.same({}, matches)
      assert.are.equal(0, matched)
    end)

    it("matches unrecorded members by part of a name, ignoring case, names with spaces included", function()
      local _, matches = ViewModel.AttendanceView(event(), members, "yonemon g", 8)
      assert.are.equal(1, #matches)
      assert.are.equal("Yonemon Gg", matches[1].name)

      _, matches = ViewModel.AttendanceView(event(), members, "AN", 8)
      assert.are.same({ "Ann-Realm", "Anya-Realm" }, { matches[1].name, matches[2].name })
    end)

    it("does not offer someone already recorded", function()
      local _, matches, matched = ViewModel.AttendanceView(event(), members, "zed", 8)
      assert.are.same({}, matches)
      assert.are.equal(0, matched)
    end)

    it("cuts the matches at the limit but says how many there were", function()
      local _, matches, matched = ViewModel.AttendanceView(event(), members, "an", 1)
      assert.are.equal(1, #matches)
      assert.are.equal(2, matched)
    end)

    it("keeps a guild of hundreds from becoming hundreds of rows", function()
      local many = {}
      for index = 1, 300 do
        many[index] = ("Member%03d-Realm"):format(index)
      end
      local recorded, matches, matched = ViewModel.AttendanceView(event(), many, "member", 8)
      assert.are.equal(2, #recorded)
      assert.are.equal(8, #matches)
      assert.are.equal(300, matched)
    end)

    it("escapes the names", function()
      local data = { attendance = { ["|cffff0000Evil"] = { state = "present" } } }
      local recorded, matches = ViewModel.AttendanceView(data, { "|rOther" }, "other", 8)
      assert.are.equal("||cffff0000Evil", recorded[1].label)
      assert.are.equal("||rOther", matches[1].label)
    end)
  end)
end)

describe("ViewModel loot tab helpers", function()
  it(
    "offers apply to everyone, voting to raid leaders, council and admins, and opening to council and admins",
    function()
      local member = ViewModel.LootActions("member")
      assert.is_true(member.apply)
      assert.is_false(member.open or member.vote or member.award)
      local rl = ViewModel.LootActions("rl")
      assert.is_true(rl.apply and rl.vote and rl.award)
      assert.is_false(rl.open)
      for _, role in ipairs({ "council", "admin" }) do
        local actions = ViewModel.LootActions(role)
        assert.is_true(actions.open and actions.apply and actions.vote and actions.award)
      end
      assert.is_false(ViewModel.LootActions(nil).apply)
    end
  )

  it("offers every need the model accepts, and only those", function()
    local ns = {}
    for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LootModel" }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    end
    local offered = {}
    for _, need in ipairs(ViewModel.LOOT_NEEDS) do
      offered[need] = true
    end
    assert.are.same(ns.LootModel.NEEDS, offered)
  end)

  local function session(overrides)
    local s = {
      sessionId = "s1",
      itemName = "Thunderfury",
      status = "open",
      candidates = {
        ["Ann-Realm"] = { spec = "Fury", need = "main", upgrade = "+12" },
        ["Bob-Realm"] = { spec = "Prot", need = "off" },
      },
      votes = { ["Zed-Realm"] = { target = "Ann-Realm" } },
    }
    for k, v in pairs(overrides or {}) do
      s[k] = v
    end
    return s
  end

  it("shows the candidates, and vote counts only as far as the visibility policy allows", function()
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "secret"
    local hidden = table.concat(ViewModel.LootSession(session()), "\n")
    Constants.VOTE_VISIBILITY = "open"
    local open = table.concat(ViewModel.LootSession(session()), "\n")
    Constants.VOTE_VISIBILITY = saved

    assert.is_truthy(hidden:find("Ann-Realm: Fury, main - +12", 1, true))
    assert.is_truthy(hidden:find("Bob-Realm: Prot, off", 1, true))
    assert.is_truthy(hidden:find("1 vote(s) cast (hidden until the session closes)", 1, true))
    assert.is_nil(hidden:find("votes: Ann-Realm", 1, true))
    assert.is_truthy(open:find("votes: Ann-Realm 1", 1, true))
  end)

  it("shows the tally and the decision once closed", function()
    local text = table.concat(
      ViewModel.LootSession(session({
        status = "closed",
        award = { characterKey = "Ann-Realm", awardedBy = "Leader-Realm", reason = "highest need" },
      })),
      "\n"
    )
    assert.is_truthy(text:find("votes: Ann-Realm 1", 1, true))
    assert.is_truthy(text:find("awarded to Ann-Realm by Leader-Realm: highest need", 1, true))
    assert.is_truthy(
      table.concat(ViewModel.LootSession(session({ status = "closed" })), "\n"):find("closed, not awarded", 1, true)
    )
  end)

  it("escapes everything that came from the guild", function()
    local text = table.concat(
      ViewModel.LootSession(session({
        itemName = "|cffff0000Evil",
        candidates = { ["|cff00ff00Ann"] = { spec = "|rSpec", need = "main" } },
      })),
      "\n"
    )
    assert.is_nil(text:find("[^|]|[cHr]"))
  end)

  it("lists candidates sorted for the dropdowns", function()
    local list, order = ViewModel.CandidateChoices(session())
    assert.are.same({ "Ann-Realm", "Bob-Realm" }, order)
    assert.are.equal("Ann-Realm (Fury, main)", list["Ann-Realm"])
  end)
end)

describe("ViewModel readiness tab helpers", function()
  local rules = {
    { id = "role", label = "Role declared", check = "field" },
    { id = "consumables", label = "Consumables |cffff0000ready", check = "confirm" },
    { id = "enchants", label = "Enchants done", check = "confirm" },
  }
  local results = {
    { status = "met" },
    { status = "unknown" },
    { status = "waived" },
  }

  it("lists only the items confirmed by hand, with their current status", function()
    local items = ViewModel.ManualItems(rules, results)
    assert.are.equal(2, #items)
    assert.are.equal("consumables", items[1].ruleId)
    assert.are.equal("unknown", items[1].status)
    assert.are.equal("enchants", items[2].ruleId)
    assert.are.equal("waived", items[2].status)
  end)

  it("escapes the labels", function()
    assert.are.equal("Consumables ||cffff0000ready", ViewModel.ManualItems(rules, results)[1].label)
  end)

  it("offers exactly the statuses SetManual accepts", function()
    local ns = {}
    for _, path in ipairs({ "Core/Constants", "Core/Locale", "Core/Validate", "Domain/ReadinessService" }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    end
    local platform = {
      ServerTime = function()
        return 1
      end,
    }
    local manual = { { id = "x", check = "confirm" } }
    for _, status in ipairs(ViewModel.READY_STATUSES) do
      assert.is_true(ns.ReadinessService.SetManual(platform, manual, {}, "x", status))
    end
    assert.are.equal("invalid_status", select(2, ns.ReadinessService.SetManual(platform, manual, {}, "x", "partial")))
  end)

  it("explains every way setting an item can fail", function()
    for _, reason in ipairs({ "unknown_rule", "not_manual", "invalid_status" }) do
      assert.is_string(ViewModel.READY_SET_ERRORS[reason])
    end
  end)
end)

describe("ViewModel minimap helpers", function()
  local function event(id, title, status, startAt)
    return { eventId = id, title = title, status = status, startAt = startAt, attendance = {}, assignments = {} }
  end

  it("picks the soonest planned or open event that has not started", function()
    local events = {
      past = event("past", "Past", "planned", 50),
      closed = event("closed", "Closed", "closed", 120),
      soon = event("soon", "Soon", "planned", 200),
      later = event("later", "Later", "planned", 300),
    }
    assert.are.equal("soon", ViewModel.NextEvent(events, 100).eventId)
  end)

  it("keeps an open event that already started, and falls back to an undated one", function()
    assert.are.equal("live", ViewModel.NextEvent({ live = event("live", "Live", "open", 50) }, 100).eventId)
    assert.are.equal("tbd", ViewModel.NextEvent({ tbd = event("tbd", "TBD", "planned", nil) }, 100).eventId)
    assert.is_nil(ViewModel.NextEvent({ old = event("old", "Old", "planned", 50) }, 100))
    assert.is_nil(ViewModel.NextEvent({}, 100))
  end)

  local function args(overrides)
    local a = {
      events = { e = event("e", "Molten Core", "planned", 200) },
      now = 100,
      formatDate = function(timestamp)
        return "date:" .. timestamp
      end,
      readinessText = "1/3 met, 2 unknown",
      pending = 0,
      paused = false,
    }
    for k, v in pairs(overrides or {}) do
      a[k] = v
    end
    return a
  end

  it("shows the next event, the readiness score and the sync queue", function()
    local lines = ViewModel.MinimapTooltip(args())
    assert.are.same({
      "Next event: Molten Core - date:200",
      "Readiness: 1/3 met, 2 unknown",
      "Sync queue: empty",
    }, lines)
  end)

  it("says when nothing is planned and when messages are waiting or held back", function()
    local lines = ViewModel.MinimapTooltip(args({ events = {}, pending = 3, paused = true }))
    assert.are.equal("Next event: none planned", lines[1])
    assert.are.equal("Sync queue: 3 message(s) waiting (held back: encounter in progress)", lines[3])
    assert.are.equal("Sync queue: 2 message(s) waiting", ViewModel.MinimapTooltip(args({ pending = 2 }))[3])
  end)

  it("escapes the event title", function()
    local lines = ViewModel.MinimapTooltip(args({ events = { e = event("e", "|cffff0000Evil", "planned", 200) } }))
    assert.is_truthy(lines[1]:find("||cffff0000Evil", 1, true))
  end)

  it("has a menu entry for every tab plus a sync request", function()
    local entries = ViewModel.MinimapMenu()
    assert.are.equal(#ViewModel.TABS + 1, #entries)
    for index, tab in ipairs(ViewModel.TABS) do
      assert.are.same({ text = tab.text, action = "tab", value = tab.value }, entries[index])
    end
    assert.are.equal("sync", entries[#entries].action)
  end)

  it("words the result of a sync request", function()
    assert.is_truthy(ViewModel.SyncRequestResult(true):find("asked the guild", 1, true))
    assert.is_truthy(ViewModel.SyncRequestResult(false, "cooldown"):find("wait a little", 1, true))
    assert.are.equal("not requested: weird", ViewModel.SyncRequestResult(false, "weird"))
  end)
end)

describe("ViewModel.SelfTestFailures", function()
  it("says what failed, escaped, and where to see the rest", function()
    local lines = ViewModel.SelfTestFailures({
      { name = "C_Club.GetGuildClubId", status = "missing", detail = "not available on this client" },
      { name = "|cffff0000x", status = "error", detail = "boom" },
    })
    assert.are.equal("Self test: 2 check(s) failed", lines[1])
    assert.are.equal("  [missing] C_Club.GetGuildClubId - not available on this client", lines[2])
    assert.is_truthy(lines[3]:find("||cffff0000x", 1, true))
    assert.are.equal("Type /nrage debug selftest for the full result.", lines[4])
  end)
end)

describe("ViewModel loot popup helpers", function()
  local function session(id, name, status, candidates)
    return { sessionId = id, itemName = name, status = status or "open", candidates = candidates or {}, votes = {} }
  end

  local function events()
    return {
      a = {
        eventId = "a",
        title = "Molten Core",
        loot = { s1 = session("s1", "Thunderfury"), s2 = session("s2", "Sulfuras") },
      },
      b = { eventId = "b", title = "Onyxia", loot = { s3 = session("s3", "Drake", "closed") } },
    }
  end

  it("lists the open sessions the player has not answered, in a stable order", function()
    local pending = ViewModel.PendingLoot(events(), "Me-Realm", {})
    assert.are.equal(2, #pending)
    assert.are.equal("Sulfuras", pending[1].itemName)
    assert.are.equal("Thunderfury", pending[2].itemName)
    assert.are.equal("Molten Core", pending[1].eventTitle)
    assert.are.equal("a", pending[1].eventId)
  end)

  it("leaves out sessions already answered, passed on or closed", function()
    local data = events()
    data.a.loot.s1.candidates["Me-Realm"] = { spec = "Fury", need = "main" }
    local pending = ViewModel.PendingLoot(data, "Me-Realm", { s2 = true })
    assert.are.equal(0, #pending)
  end)

  it("still offers a session someone else applied to", function()
    local data = events()
    data.a.loot.s1.candidates["Other-Realm"] = { spec = "Fury", need = "main" }
    assert.are.equal(2, #ViewModel.PendingLoot(data, "Me-Realm", {}))
  end)

  it("picks the spec for a one-click candidacy: declared role, else class, else a placeholder", function()
    assert.are.equal("Tank", ViewModel.DefaultSpec({ class = "WARRIOR", fields = { role = { value = "Tank" } } }))
    assert.are.equal("WARRIOR", ViewModel.DefaultSpec({ class = "WARRIOR" }))
    assert.are.equal("WARRIOR", ViewModel.DefaultSpec({ class = "WARRIOR", fields = { role = { value = "  " } } }))
    assert.are.equal("unknown", ViewModel.DefaultSpec({}))
  end)
end)

describe("ViewModel voting window helpers", function()
  local function session(id, name, status, overrides)
    local s = { sessionId = id, itemName = name, status = status or "open", candidates = {}, votes = {} }
    for k, v in pairs(overrides or {}) do
      s[k] = v
    end
    return s
  end

  it("lists the open sessions plus the selected one even when closed, escaped and in order", function()
    local events = {
      a = {
        eventId = "a",
        title = "Molten Core",
        loot = {
          s1 = session("s1", "Thunderfury"),
          s2 = session("s2", "|cffff0000Sulfuras"),
          s3 = session("s3", "Done", "closed"),
          s4 = session("s4", "Old", "closed"),
        },
      },
    }
    local list = ViewModel.VotingSessions(events, "s3")
    assert.are.equal(3, #list)
    assert.are.equal("s3", list[1].sessionId)
    assert.is_true(list[1].selected)
    assert.are.equal("s1", list[2].sessionId)
    assert.is_false(list[2].selected)
    assert.are.equal("||cffff0000Sulfuras", list[3].itemName)
    assert.are.equal(2, #ViewModel.VotingSessions(events, nil))
  end)

  it("says where a session stands", function()
    local open = session("s1", "Item", "open", {
      candidates = { A = { spec = "x", need = "main" }, B = { spec = "y", need = "off" } },
      votes = { C = { target = "A" } },
    })
    assert.are.equal("Voting is open: 2 candidate(s), 1 vote(s) cast", ViewModel.VotingStatus(open))
    assert.are.equal("Closed without an award", ViewModel.VotingStatus(session("s2", "Item", "closed")))
    local awarded = session("s3", "Item", "closed", {
      award = { characterKey = "A", awardedBy = "Boss", reason = "|rneed" },
    })
    assert.are.equal("Awarded to A by Boss: ||rneed", ViewModel.VotingStatus(awarded))
  end)

  local function candidates_session()
    return session("s1", "Item", "open", {
      candidates = {
        ["Ann-Realm"] = { spec = "Fury", need = "main", upgrade = "+12" },
        ["Bob-Realm"] = { spec = "Prot", need = "off" },
        ["Cy-Realm"] = { spec = "Mage", need = "other" },
      },
      votes = {
        ["Me-Realm"] = { target = "Bob-Realm" },
        ["Zed-Realm"] = { target = "Bob-Realm" },
        ["Yan-Realm"] = { target = "Cy-Realm" },
      },
    })
  end

  local function rank_of(name)
    return name == "Ann-Realm" and "Raider" or nil
  end

  it("builds one row per candidate, most votes first, with rank, response and my vote", function()
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "open"
    local rows = ViewModel.VotingRows(candidates_session(), "Me-Realm", rank_of)
    Constants.VOTE_VISIBILITY = saved

    assert.are.equal(3, #rows)
    assert.are.equal("Bob-Realm", rows[1].name)
    assert.are.equal(2, rows[1].votes)
    assert.is_true(rows[1].mine)
    assert.are.equal("Off spec (Prot)", rows[1].response)
    assert.are.equal("Cy-Realm", rows[2].name)
    assert.is_false(rows[2].mine)
    assert.are.equal("Ann-Realm", rows[3].name)
    assert.are.equal(0, rows[3].votes)
    assert.are.equal("Raider", rows[3].rank)
    assert.are.equal("?", rows[1].rank)
    assert.are.equal("+12", rows[3].upgrade)
    assert.are.equal("", rows[1].upgrade)
  end)

  it("hides the vote counts and sorts by name while the policy says so", function()
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "secret"
    local rows = ViewModel.VotingRows(candidates_session(), "Me-Realm", rank_of)
    Constants.VOTE_VISIBILITY = saved

    assert.are.equal("Ann-Realm", rows[1].name)
    for _, row in ipairs(rows) do
      assert.is_nil(row.votes)
    end
  end)

  it("escapes what came from the guild", function()
    local data = session("s1", "Item", "open", {
      candidates = { ["|cffff0000Evil"] = { spec = "|rspec", need = "main", upgrade = "|Hx" } },
    })
    local row = ViewModel.VotingRows(data, "Me-Realm", function()
      return "|cff00ff00Rank"
    end)[1]
    for _, text in ipairs({ row.label, row.rank, row.response, row.upgrade }) do
      assert.is_nil(text:find("[^|]|[cHr]"), text)
    end
  end)
end)

describe("ViewModel raid tab layout helpers", function()
  it("gives every role the summary and each group of controls its own sub-tab", function()
    local function values(actions)
      local out = {}
      for _, tab in ipairs(ViewModel.RaidSubTabs(actions)) do
        out[#out + 1] = tab.value
      end
      return out
    end
    assert.are.same({ "summary", "reports" }, values({ events = false, attendance = false, assignments = false }))
    assert.are.same(
      { "summary", "details", "attendance", "assignments", "templates", "reports" },
      values({ events = true, attendance = true, assignments = true })
    )
    assert.are.same(
      { "summary", "attendance", "reports" },
      values({ events = false, attendance = true, assignments = false })
    )
  end)

  it("describes one event with its number, attendance counts and assignments, escaped", function()
    local lines = ViewModel.RaidEventLines(
      {
        title = "|cffff0000Raid",
        status = "open",
        startAt = 7,
        attendance = { a = { state = "present" }, b = { state = "present" }, c = { state = "late" } },
        assignments = { x = { encounter = "Garr", characterKey = "Ann-Realm", task = "Tank" } },
      },
      3,
      function(timestamp)
        return "date:" .. timestamp
      end
    )
    assert.are.equal("3. ||cffff0000Raid [open] - date:7", lines[1])
    assert.are.equal("    Attendance: 1 late, 2 present", lines[2])
    assert.are.equal("    Garr: Ann-Realm - Tank", lines[3])
  end)
end)

describe("ViewModel voting table sort and filter", function()
  local function session()
    return {
      sessionId = "s1",
      itemName = "Item",
      status = "open",
      candidates = {
        ["Zed-Realm"] = { spec = "Arms", need = "main" },
        ["amy-Realm"] = { spec = "Prot", need = "off" },
        ["Bob-Realm"] = { spec = "Fury", need = "other" },
      },
      votes = {
        ["V1"] = { target = "Bob-Realm" },
        ["V2"] = { target = "Bob-Realm" },
        ["V3"] = { target = "Zed-Realm" },
      },
    }
  end

  local ranks = { ["Zed-Realm"] = "Officer", ["amy-Realm"] = "Raider", ["Bob-Realm"] = "Alt" }
  local function rank_of(name)
    return ranks[name]
  end

  local function names(options)
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "open"
    local rows = ViewModel.VotingRows(session(), "Me", rank_of, options)
    Constants.VOTE_VISIBILITY = saved
    local out = {}
    for _, row in ipairs(rows) do
      out[#out + 1] = row.name
    end
    return out
  end

  it("defaults to most votes first", function()
    assert.are.same({ "Bob-Realm", "Zed-Realm", "amy-Realm" }, names())
  end)

  it("sorts by name ignoring case, either way", function()
    assert.are.same({ "amy-Realm", "Bob-Realm", "Zed-Realm" }, names({ sort = { key = "name", descending = false } }))
    assert.are.same({ "Zed-Realm", "Bob-Realm", "amy-Realm" }, names({ sort = { key = "name", descending = true } }))
  end)

  it("sorts by rank and by response (main, off, other)", function()
    assert.are.same({ "Bob-Realm", "Zed-Realm", "amy-Realm" }, names({ sort = { key = "rank", descending = false } }))
    assert.are.same(
      { "Zed-Realm", "amy-Realm", "Bob-Realm" },
      names({ sort = { key = "response", descending = false } })
    )
  end)

  it("shows only one kind of response when asked", function()
    assert.are.same({ "amy-Realm" }, names({ need = "off" }))
    assert.are.same({ "Zed-Realm" }, names({ need = "main" }))
  end)

  it("sorts by name instead of by votes while the votes are hidden", function()
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "secret"
    local rows = ViewModel.VotingRows(session(), "Me", rank_of, { sort = { key = "votes", descending = true } })
    Constants.VOTE_VISIBILITY = saved
    assert.are.equal("amy-Realm", rows[1].name)
  end)

  it("flips the direction on the same column and starts a new one in its natural direction", function()
    assert.are.same({ key = "name", descending = false }, ViewModel.NextSort(nil, "name"))
    assert.are.same(
      { key = "name", descending = true },
      ViewModel.NextSort({ key = "name", descending = false }, "name")
    )
    assert.are.same(
      { key = "votes", descending = true },
      ViewModel.NextSort({ key = "name", descending = true }, "votes")
    )
    assert.are.same(
      { key = "rank", descending = false },
      ViewModel.NextSort({ key = "votes", descending = true }, "rank")
    )
  end)
end)

describe("ViewModel item details and won items", function()
  it("writes the item line from what the client reported, escaped", function()
    assert.are.equal("ilvl 213 - Two-Hand", ViewModel.ItemDetailsLine({ level = 213, slot = "Two-Hand" }))
    assert.are.equal("ilvl 100", ViewModel.ItemDetailsLine({ level = 100 }))
    assert.are.equal("||cffff0000x", ViewModel.ItemDetailsLine({ slot = "|cffff0000x" }))
    assert.is_nil(ViewModel.ItemDetailsLine(nil))
    assert.is_nil(ViewModel.ItemDetailsLine({}))
  end)

  local function events()
    local function won(id, item, who, at)
      return { sessionId = id, itemName = item, award = { characterKey = who, reason = "need", at = at } }
    end
    return {
      a = { title = "Week 1", loot = { s1 = won("s1", "Sulfuras", "Ann", 10), s2 = won("s2", "Boots", "Bob", 20) } },
      b = { title = "Week 2", loot = { s3 = won("s3", "Ring", "Ann", 30), s4 = { itemName = "Open", award = nil } } },
    }
  end

  it("lists what a character has won, newest first, across events", function()
    local won = ViewModel.WonItems(events(), "Ann", 8)
    assert.are.equal(2, #won)
    assert.are.equal("Ring", won[1].itemName)
    assert.are.equal("Week 2", won[1].eventTitle)
    assert.are.equal("Sulfuras", won[2].itemName)
    assert.are.same({}, ViewModel.WonItems(events(), "Nobody", 8))
  end)

  it("cuts the list at the limit", function()
    assert.are.equal(1, #ViewModel.WonItems(events(), "Ann", 1))
  end)

  it("copes with an event that has no loot table", function()
    assert.are.same({}, ViewModel.WonItems({ x = { title = "Empty" } }, "Ann", 8))
  end)
end)

describe("ViewModel PvP", function()
  local function stats()
    local pvp = { honor = { world = 4, bg = 6 }, blows = { world = 1, bg = 2 }, daily = {} }
    pvp.daily["2026-10-01"] = { honor = { world = 1, bg = 2 }, blows = { world = 0, bg = 1 } }
    return pvp
  end

  it("has the own counters, the ranking and the recent kills as sub-tabs", function()
    assert.are.same({
      { value = "mine", text = "My stats" },
      { value = "ranking", text = "Ranking" },
      { value = "feed", text = "Recent kills" },
    }, ViewModel.PvPSubTabs())
  end)

  it("lists honourable kills and killing blows with totals and today", function()
    local pvp = stats()
    local text =
      table.concat(ViewModel.PvPStats(pvp, { day = "2026-10-01", honorAvailable = true, blowsAvailable = true }), "\n")
    assert.is_truthy(text:find("Honourable kills\n  Open world: 4\n  Battleground: 6\n  Total: 10", 1, true))
    assert.is_truthy(text:find("Today: 3 (open world 1, battleground 2)", 1, true))
    assert.is_truthy(text:find("Killing blows\n  Open world: 1\n  Battleground: 2\n  Total: 3", 1, true))
    assert.is_truthy(text:find("Today: 1 (open world 0, battleground 1)", 1, true))
    assert.is_nil(text:find("not available", 1, true))
  end)

  it("leaves the killing blows out when the client does not allow them", function()
    local pvp = stats()
    local text = table.concat(ViewModel.PvPStats(pvp, { day = "2026-10-01", honorAvailable = true }), "\n")
    assert.is_nil(text:find("Killing blows", 1, true))
    assert.is_truthy(text:find("Honourable kills", 1, true))
  end)

  it("starts with the rank and the progress to the next one", function()
    local ranks = { { name = "Private", kills = 0 }, { name = "Corporal", kills = 25 } }
    local lines = ViewModel.PvPStats(stats(), { day = "2026-10-01", honorAvailable = true, ranks = ranks })
    assert.are.equal("Rank: Private (10 honourable kills) - 15 to Corporal", lines[1])
  end)

  it("uses the configured ranks by default", function()
    local lines = ViewModel.PvPStats(stats(), { day = "2026-10-01", honorAvailable = true })
    assert.are.equal("Rank: Private (10 honourable kills) - 15 to Corporal", lines[1])
  end)

  it("describes the top rank, no rank yet and no ranks configured", function()
    assert.are.equal(
      "Rank: Corporal (40 honourable kills), the highest rank",
      ViewModel.PvPRankLine(40, { { name = "Private", kills = 0 }, { name = "Corporal", kills = 25 } })
    )
    assert.are.equal("Rank: none yet - 3 to Scout", ViewModel.PvPRankLine(2, { { name = "Scout", kills = 5 } }))
    assert.are.equal("Rank: none (no ranks are configured)", ViewModel.PvPRankLine(2, {}))
  end)

  it("says so when honourable kills cannot be read", function()
    local text = table.concat(ViewModel.PvPStats(nil, { blowsAvailable = true }), "\n")
    assert.is_truthy(text:find("Honourable kills are not available on this client.", 1, true))
    assert.is_truthy(text:find("Today: 0 (open world 0, battleground 0)", 1, true))
  end)
end)

describe("ViewModel.PvPRanking", function()
  local RANKS = { { name = "Private", kills = 0 }, { name = "Corporal", kills = 25 } }

  local function record(world, bg, blows, updatedAt)
    return {
      honor = { world = world, bg = bg },
      blows = blows and { world = blows, bg = 0 } or nil,
      updatedAt = updatedAt or 900,
      rev = 1,
    }
  end

  local function names(rows)
    local list = {}
    for _, row in ipairs(rows) do
      list[#list + 1] = row.name
    end
    return list
  end

  local function options(overrides)
    local o = {
      own = { name = "Me", stats = { honor = { world = 5, bg = 5 }, blows = { world = 2, bg = 0 }, daily = {} } },
      rosterNames = { Ann = true, Bob = true, Cid = true, Me = true },
      ranks = RANKS,
      now = 1000,
    }
    for k, v in pairs(overrides or {}) do
      o[k] = v
    end
    return o
  end

  local records = {
    Ann = record(20, 10, 4, 940),
    Bob = record(5, 0, nil, 1000 - 7200),
    Cid = record(15, 15, nil, 1000 - 3 * 86400),
  }

  it("orders by total honourable kills, highest first, then by name", function()
    local rows = ViewModel.PvPRanking(records, options())
    assert.are.same({ "Ann", "Cid", "Me", "Bob" }, names(rows))
    local tied = ViewModel.PvPRanking({ Bob = record(10, 0), Ann = record(5, 5), Cid = record(2, 2) }, options())
    assert.are.same({ "Ann", "Bob", "Me", "Cid" }, names(tied))
  end)

  it("fills each row with the counters, the rank name and the age of the last update", function()
    local rows = ViewModel.PvPRanking(records, options())
    assert.are.equal(20, rows[1].world)
    assert.are.equal(10, rows[1].bg)
    assert.are.equal(30, rows[1].total)
    assert.are.equal(4, rows[1].blows)
    assert.are.equal("Corporal", rows[1].rank)
    assert.are.equal("1 min ago", rows[1].updated)
    assert.are.equal("3 d ago", rows[2].updated)
    assert.are.equal("2 h ago", rows[4].updated)
    assert.are.equal("Private", rows[4].rank)
    assert.is_nil(rows[4].blows)
  end)

  it("always lists the own row, from the local counters, and marks it", function()
    local synced = { Me = record(999, 999) }
    local rows = ViewModel.PvPRanking(synced, options({ blowsAvailable = true }))
    assert.are.equal(1, #rows)
    assert.are.equal("Me", rows[1].name)
    assert.is_true(rows[1].mine)
    assert.are.equal(10, rows[1].total)
    assert.are.equal(2, rows[1].blows)
    assert.are.equal("now", rows[1].updated)
    -- Even when the roster does not list this character yet.
    rows = ViewModel.PvPRanking({}, options({ rosterNames = {} }))
    assert.are.same({ "Me" }, names(rows))
  end)

  it("hides the records of members who are not in the roster", function()
    local rows = ViewModel.PvPRanking(records, options({ rosterNames = { Ann = true } }))
    assert.are.same({ "Ann", "Me" }, names(rows))
    rows = ViewModel.PvPRanking(records, options({ rosterNames = false }))
    assert.are.same({ "Me" }, names(rows))
    local without = options()
    without.rosterNames = nil
    rows = ViewModel.PvPRanking(records, without)
    assert.are.same({ "Me" }, names(rows))
  end)

  it("skips damaged records", function()
    local damaged = { Ann = "oops", Bob = { honor = "x" }, Cid = { honor = { world = 1 } }, [5] = record(1, 1) }
    local rows = ViewModel.PvPRanking(damaged, options({ rosterNames = { Ann = true, Bob = true, Cid = true } }))
    assert.are.same({ "Me" }, names(rows))
  end)

  it("sorts by the chosen column, in the chosen direction", function()
    local rows = ViewModel.PvPRanking(records, options({ sort = { key = "name", descending = false } }))
    assert.are.same({ "Ann", "Bob", "Cid", "Me" }, names(rows))
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "name", descending = true } }))
    assert.are.same({ "Me", "Cid", "Bob", "Ann" }, names(rows))
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "world", descending = false } }))
    assert.are.same({ "Bob", "Me", "Cid", "Ann" }, names(rows))
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "bg", descending = true } }))
    assert.are.same({ "Cid", "Ann", "Me", "Bob" }, names(rows))
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "rank", descending = true } }))
    assert.are.equal("Corporal", rows[1].rank)
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "updated", descending = true } }))
    assert.are.same({ "Me", "Ann", "Bob", "Cid" }, names(rows))
  end)

  it("sorts members without killing blows last when sorting by them", function()
    local rows = ViewModel.PvPRanking(records, options({ sort = { key = "blows", descending = true } }))
    assert.are.equal("Ann", rows[1].name)
    assert.is_nil(rows[#rows].blows)
    rows = ViewModel.PvPRanking(records, options({ sort = { key = "nonsense", descending = false } }))
    assert.are.same({ "Ann", "Cid", "Me", "Bob" }, names(rows))
  end)

  it("toggles the direction with NextSort and starts the numbers high to low", function()
    local first = ViewModel.NextSort(nil, "total", ViewModel.PVP_FIRST_DESCENDING)
    assert.are.same({ key = "total", descending = true }, first)
    assert.are.same(
      { key = "total", descending = false },
      ViewModel.NextSort(first, "total", ViewModel.PVP_FIRST_DESCENDING)
    )
    assert.are.same(
      { key = "name", descending = false },
      ViewModel.NextSort(first, "name", ViewModel.PVP_FIRST_DESCENDING)
    )
  end)

  it("shows the killing blows column only when they are available or somebody sent them", function()
    local _, columns = ViewModel.PvPRanking({ Bob = records.Bob }, options())
    assert.is_false(columns.blows)
    _, columns = ViewModel.PvPRanking({ Bob = records.Bob }, options({ blowsAvailable = true }))
    assert.is_true(columns.blows)
    _, columns = ViewModel.PvPRanking({ Ann = records.Ann }, options())
    assert.is_true(columns.blows)
  end)

  it("escapes names and ranks", function()
    local rows = ViewModel.PvPRanking(
      { ["|cffff0000Eve"] = record(1, 1) },
      options({ rosterNames = { ["|cffff0000Eve"] = true }, ranks = { { name = "Ra|nk", kills = 0 } } })
    )
    for _, row in ipairs(rows) do
      assert.are.equal("Ra||nk", row.rank)
    end
    local labels = {}
    for _, row in ipairs(rows) do
      labels[row.name] = row.label
    end
    assert.are.equal("||cffff0000Eve", labels["|cffff0000Eve"])
  end)

  it("uses the configured ranks by default", function()
    local plain = options()
    plain.ranks = nil
    local rows = ViewModel.PvPRanking({}, plain)
    assert.are.equal("Private", rows[1].rank)
  end)

  it("shows a dash for a missing last update", function()
    local noClock = options()
    noClock.now = nil
    local rows = ViewModel.PvPRanking({ Bob = { honor = { world = 1, bg = 1 } } }, noClock)
    local bob
    for _, row in ipairs(rows) do
      bob = row.name == "Bob" and row or bob
    end
    assert.are.equal("-", bob.updated)
  end)

  describe("today", function()
    local function today_record(world, bg, day, todayHonor, todayBlows)
      local r = record(world, bg, todayBlows and 9 or nil)
      r.today = { day = day, honor = todayHonor, blows = todayBlows }
      return r
    end

    local function by_name(rows)
      local found = {}
      for _, row in ipairs(rows) do
        found[row.name] = row
      end
      return found
    end

    it("shows today's counters of records sent today and zero for the rest", function()
      local synced = {
        Ann = today_record(20, 10, "2026-10-02", { world = 3, bg = 1 }, { world = 2, bg = 0 }),
        Bob = today_record(40, 0, "2026-10-01", { world = 7, bg = 0 }),
        Cid = record(15, 15),
      }
      local rows = by_name(ViewModel.PvPRanking(synced, options({ period = "today", day = "2026-10-02" })))
      assert.are.same({ 3, 1, 4, 2 }, { rows.Ann.world, rows.Ann.bg, rows.Ann.total, rows.Ann.blows })
      assert.are.same({ 0, 0, 0 }, { rows.Bob.world, rows.Bob.bg, rows.Bob.total })
      assert.are.equal(0, rows.Cid.total)
      assert.is_nil(rows.Cid.blows)
    end)

    it("keeps the all-time rank while showing today", function()
      local synced = { Ann = today_record(20, 10, "2026-10-02", { world = 1, bg = 0 }) }
      local rows = by_name(ViewModel.PvPRanking(synced, options({ period = "today", day = "2026-10-02" })))
      assert.are.equal("Corporal", rows.Ann.rank)
      assert.are.equal(1, rows.Ann.total)
    end)

    it("uses the own counters of today", function()
      local own = {
        name = "Me",
        stats = {
          honor = { world = 50, bg = 0 },
          blows = { world = 4, bg = 0 },
          daily = { ["2026-10-02"] = { honor = { world = 2, bg = 3 }, blows = { world = 1, bg = 0 } } },
        },
      }
      local rows = by_name(
        ViewModel.PvPRanking({}, options({ own = own, period = "today", day = "2026-10-02", blowsAvailable = true }))
      )
      assert.are.same({ 2, 3, 5, 1 }, { rows.Me.world, rows.Me.bg, rows.Me.total, rows.Me.blows })
      assert.are.equal("Corporal", rows.Me.rank)
    end)

    it("orders by today's total, and an unknown day counts as zero", function()
      local synced = {
        Ann = today_record(100, 0, "2026-10-02", { world = 1, bg = 0 }),
        Bob = today_record(1, 0, "2026-10-02", { world = 1, bg = 4 }),
      }
      local rows = ViewModel.PvPRanking(synced, options({ period = "today", day = "2026-10-02" }))
      assert.are.same({ "Bob", "Ann", "Me" }, names(rows))
      rows = by_name(ViewModel.PvPRanking(synced, options({ period = "today" })))
      assert.are.equal(0, rows.Bob.total)
    end)

    it("still sorts by the all-time rank", function()
      local synced = {
        Ann = today_record(30, 0, "2026-10-02", { world = 0, bg = 0 }),
        Bob = today_record(1, 0, "2026-10-02", { world = 9, bg = 0 }),
      }
      local rows = ViewModel.PvPRanking(
        synced,
        options({ period = "today", day = "2026-10-02", sort = { key = "rank", descending = true } })
      )
      assert.are.equal("Ann", rows[1].name)
    end)
  end)
end)

describe("ViewModel PvP feed", function()
  local function entry(overrides)
    local e = { victim = "Zed", where = "world", blow = false, killers = { "Ann" }, time = 100 }
    for k, val in pairs(overrides or {}) do
      e[k] = val
    end
    return e
  end

  local function options(overrides)
    local o = {
      available = true,
      formatTime = function(seconds)
        return "t" .. seconds
      end,
    }
    for k, val in pairs(overrides or {}) do
      o[k] = val
    end
    return o
  end

  it("lists the entries in the order given, with the killers and the place", function()
    local lines = ViewModel.PvPFeed({
      entry({ killers = { "Ann", "Bob" }, blow = true, time = 200 }),
      entry({ victim = "Yan", where = "bg", time = 100 }),
    }, options())
    assert.are.same({
      "t200  Ann, Bob killed Zed (open world, killing blow)",
      "t100  Ann killed Yan (battleground)",
    }, lines)
  end)

  it("escapes every name", function()
    local lines = ViewModel.PvPFeed({ entry({ victim = "|cffff0000Z|r", killers = { "|Hlink|h", "B|n" } }) }, options())
    assert.are.equal("t100  ||Hlink||h, B||n killed ||cffff0000Z||r (open world)", lines[1])
  end)

  it("says so when there are no kills yet", function()
    local lines = ViewModel.PvPFeed({}, options())
    assert.are.equal(1, #lines)
    assert.is_truthy(lines[1]:find("No kills yet", 1, true))
  end)

  it("says when the client cannot give victim names", function()
    local lines = ViewModel.PvPFeed({}, options({ available = false }))
    assert.is_truthy(lines[1]:find("not available on this client", 1, true))
    assert.is_truthy(lines[#lines]:find("No kills yet", 1, true))
  end)

  it("does not need a time formatter", function()
    local lines = ViewModel.PvPFeed({ entry() }, { available = true })
    assert.are.equal("--:--  Ann killed Zed (open world)", lines[1])
  end)
end)

describe("ViewModel.BlacklistRows", function()
  local function entry(name, reason, overrides)
    local e = { name = name, reason = reason, addedBy = "Ann-Realm", addedAt = 500, rev = 1, updatedAt = 500 }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end

  it("lists the entries sorted by name with the author and the date", function()
    local rows = ViewModel.BlacklistRows({
      zed = entry("Zed", "ninja"),
      ann = entry("ann", "scammer", { addedBy = "Bob-Realm" }),
      yonemongg = entry("Yonemon Gg", "afk"),
    }, {
      canRemove = true,
      formatDate = function(timestamp)
        return "date:" .. timestamp
      end,
    })
    assert.are.equal(3, #rows)
    assert.are.same({ "ann", "Yonemon Gg", "Zed" }, { rows[1].name, rows[2].name, rows[3].name })
    assert.are.same({ "ann", "yonemongg", "zed" }, { rows[1].key, rows[2].key, rows[3].key })
    assert.are.equal("scammer", rows[1].reason)
    assert.are.equal("Bob-Realm", rows[1].addedBy)
    assert.are.equal("date:500", rows[1].added)
    assert.is_true(rows[1].canRemove)
  end)

  it("only offers Remove when the role may remove", function()
    local entries = { ann = entry("Ann", "x") }
    assert.is_false(ViewModel.BlacklistRows(entries, { canRemove = false })[1].canRemove)
    assert.is_false(ViewModel.BlacklistRows(entries)[1].canRemove)
  end)

  it("escapes names, reasons and authors", function()
    local rows = ViewModel.BlacklistRows({ x = entry("|cffff0000Bad", "|Hurl|hclick", { addedBy = "|rEvil" }) })
    assert.are.equal("||cffff0000Bad", rows[1].name)
    assert.are.equal("||Hurl||hclick", rows[1].reason)
    assert.are.equal("||rEvil", rows[1].addedBy)
  end)

  it("shows a dash where a date or an author is missing", function()
    local rows = ViewModel.BlacklistRows({ x = entry("Ann", "x", { addedAt = false, addedBy = false }) }, {
      formatDate = function()
        return "never"
      end,
    })
    assert.are.equal("-", rows[1].added)
    assert.are.equal("-", rows[1].addedBy)
  end)

  it("is empty for an empty blacklist", function()
    assert.are.same({}, ViewModel.BlacklistRows({}))
  end)
end)

describe("ViewModel.BlacklistAlertLine", function()
  it("names the player and the reason", function()
    local line = ViewModel.BlacklistAlertLine({ member = "Ann", entry = { name = "Ann", reason = "ninja" } })
    assert.are.equal("Ann is on the blacklist: ninja", line)
  end)

  it("says it is a guess when only the first word matched", function()
    local line = ViewModel.BlacklistAlertLine({
      member = "Yonemon",
      approximate = true,
      entry = { name = "Yonemon Gg", reason = "ninja" },
    })
    assert.are.equal("Yonemon may be Yonemon Gg, who is on the blacklist: ninja", line)
  end)

  it("escapes what it shows", function()
    local line = ViewModel.BlacklistAlertLine({ member = "|rA", entry = { name = "|cB", reason = "|Hc" } })
    assert.is_nil(line:find("[^|]|[^|]"))
  end)
end)

describe("ViewModel help", function()
  it("does not list a command that no longer exists", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, gone in ipairs({ "blacklist", "event", "loot", "report", "minimap", "sync", "publish" }) do
      assert.is_nil(text:find("/nrage " .. gone, 1, true), gone)
    end
  end)
end)

describe("ViewModel readiness rules editor", function()
  local existing = { { id = "level", label = "Level 60", check = "level", min = 60 } }

  it("offers the rules tab only to those who may edit the rules", function()
    local function values(role)
      local found = {}
      for _, tab in ipairs(ViewModel.TabsFor(role)) do
        found[#found + 1] = tab.value
      end
      return found
    end
    for _, role in ipairs({ "member", "rl", "council" }) do
      assert.are.equal(#ViewModel.TABS, #values(role))
    end
    assert.are.equal(#ViewModel.TABS, #values(nil))
    local admin = values("admin")
    assert.are.equal("rules", admin[#admin])
    assert.are.equal(#ViewModel.TABS + 1, #admin)
  end)

  it("reads a level or item level", function()
    local rule = ViewModel.RuleFromInput("ilvl", "Item level 100", " 100 ", existing)
    assert.are.same(
      { id = "item_level_100", label = "Item level 100", check = "ilvl", min = 100, evidenceMode = "observed" },
      rule
    )
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("level", "Level", "abc", existing)))
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("level", "Level", "", existing)))
  end)

  it("reads enchant slots by name or number", function()
    local rule = ViewModel.RuleFromInput("enchants", "Enchants", "Mainhand, chest , 15", existing)
    assert.are.same({ 16, 5, 15 }, rule.slots)
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("enchants", "E", "mainhand, nowhere", existing)))
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("enchants", "E", "", existing)))
  end)

  it("reads buffs as spell ids and names", function()
    local rule = ViewModel.RuleFromInput("buff", "Flask", "17538, Well Fed, 18125", existing)
    assert.are.same({ 17538, 18125 }, rule.spellIds)
    assert.are.same({ "Well Fed" }, rule.names)
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("buff", "Flask", "", existing)))
  end)

  it("reads a profession with or without a minimum skill", function()
    local with = ViewModel.RuleFromInput("profession", "Alchemy", "Alchemy 300", existing)
    assert.are.equal("Alchemy", with.profession)
    assert.are.equal(300, with.min)
    local without = ViewModel.RuleFromInput("profession", "Mining", "Mining", existing)
    assert.are.equal("Mining", without.profession)
    assert.is_nil(without.min)
  end)

  it("reads a declared field and a rule confirmed by hand", function()
    assert.are.equal("role", ViewModel.RuleFromInput("field", "Role", "Role", existing).field)
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("field", "X", "nonsense", existing)))
    assert.are.equal("manual", ViewModel.RuleFromInput("confirm", "Food", "", existing).evidenceMode)
  end)

  it("refuses an empty or unsafe name", function()
    assert.are.equal("bad_label", select(2, ViewModel.RuleFromInput("confirm", "   ", "", existing)))
    assert.are.equal("bad_label", select(2, ViewModel.RuleFromInput("confirm", "|cffff0000x|r", "", existing)))
  end)

  it("gives every rule a name that no other rule has", function()
    local first = ViewModel.RuleFromInput("confirm", "Level 60", "", existing)
    assert.are.equal("level_60", first.id)
    local second = ViewModel.RuleFromInput("confirm", "Level 60", "", ViewModel.WithRule(existing, first))
    assert.are.equal("level_60_2", second.id)
    assert.are.equal("rule", ViewModel.RuleFromInput("confirm", "???", "", {}).id)
  end)

  it("adds and removes a rule without touching the list it was given", function()
    local added = ViewModel.WithRule(existing, { id = "b", label = "B", check = "confirm" })
    assert.are.equal(2, #added)
    assert.are.equal(1, #existing)
    local removed = ViewModel.WithoutRule(added, "level")
    assert.are.equal("b", removed[1].id)
    assert.are.equal("unknown_rule", select(2, ViewModel.WithoutRule(added, "nope")))
    assert.are.equal("last_rule", select(2, ViewModel.WithoutRule(existing, "level")))
  end)

  it("summarises each kind of rule", function()
    local function summary(check, details)
      return ViewModel.RuleSummary(ViewModel.RuleFromInput(check, "R", details, {}))
    end
    assert.are.equal("level 60 or more", summary("level", "60"))
    assert.are.equal("item level 100 or more", summary("ilvl", "100"))
    assert.are.equal("Alchemy 300 or more", summary("profession", "Alchemy 300"))
    assert.are.equal("enchanted slots: 16, 5", summary("enchants", "16, chest"))
    assert.are.equal("any buff of: 17538, Well Fed", summary("buff", "17538, Well Fed"))
    assert.are.equal("declared: role", summary("field", "role"))
    assert.are.equal("confirmed by the player", summary("confirm", ""))
  end)

  it("has a sentence for every reason the editor can show", function()
    for _, reason in ipairs({
      "forbidden",
      "empty",
      "too_many",
      "bad_label",
      "bad_details",
      "duplicate_id",
      "last_rule",
    }) do
      assert.is_string(ViewModel.RULE_ERRORS[reason], reason)
    end
  end)
end)

describe("ViewModel in Spanish", function()
  local Spanish = load_view_model("esES")

  it("shows the tabs in Spanish", function()
    local texts = {}
    for _, tab in ipairs(Spanish.TABS) do
      texts[tab.value] = tab.text
    end
    assert.are.equal("Inicio", texts.home)
    assert.are.equal("Lista negra", texts.blacklist)
    assert.are.equal("PvP", texts.pvp)
  end)

  it("translates the words of the states but keeps the data as it is", function()
    assert.are.equal("planificado", Spanish.Word("planned"))
    assert.are.equal("presente", Spanish.Word("present"))
    assert.are.equal("something_new", Spanish.Word("something_new"))
  end)

  it("keeps the placeholders working in a translated sentence", function()
    assert.are.equal("nivel 60 o más", Spanish.RuleSummary({ check = "level", min = 60 }))
    local ranks = { { name = "Knight", kills = 100 }, { name = "Knight-Lieutenant", kills = 800 } }
    local line = Spanish.PvPRankLine(512, ranks)
    assert.are.equal("Rango: Knight (512 bajas con honor) - 288 para Knight-Lieutenant", line)
  end)

  it("translates the help lines and the error sentences", function()
    assert.is_truthy(Spanish.HelpLines()[1]:find("abre la ventana", 1, true))
    assert.is_truthy(Spanish.RULE_ERRORS.empty:find("deja al menos una regla", 1, true))
  end)

  it("stays in English for a client that is not Spanish", function()
    local English = load_view_model("deDE")
    assert.are.equal("Home", English.TABS[1].text)
    assert.are.equal("planned", English.Word("planned"))
  end)
end)
