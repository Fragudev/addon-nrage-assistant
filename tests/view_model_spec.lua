local function load_view_model()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "UI/ViewModel",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
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
    assert.is_truthy(ViewModel.PublishError("no_consent"):find("consent", 1, true))
    assert.are.equal("something_new", ViewModel.PublishError("something_new"))
  end)

  it("offers a tab for each view", function()
    local values = {}
    for _, tab in ipairs(ViewModel.TABS) do
      values[tab.value] = true
    end
    assert.are.same({ home = true, profile = true, ready = true, raid = true, loot = true, roster = true }, values)
  end)

  it("documents every user command in the help", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, command in ipairs({
      "role",
      "profile",
      "ready",
      "consent",
      "publish",
      "event",
      "attendance",
      "assign",
      "loot",
      "report",
      "template",
      "minimap",
      "export",
      "import",
      "debug",
      "sync",
      "help",
      "version",
    }) do
      assert.is_truthy(text:find("/nrage " .. command, 1, true), command)
    end
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

  describe("AttendanceRows", function()
    local event = {
      attendance = { ["Zed-Realm"] = { state = "late" }, ["Gone-Realm"] = { state = "absent" } },
    }
    local members = { "Ann-Realm", "Zed-Realm", "Yonemon Gg-Realm" }

    it("merges the roster with recorded members, sorted, with nil for no record", function()
      local rows, matched = ViewModel.AttendanceRows(event, members, "", 10)
      assert.are.equal(4, matched)
      assert.are.same({ "Ann-Realm", "Gone-Realm", "Yonemon Gg-Realm", "Zed-Realm" }, {
        rows[1].name,
        rows[2].name,
        rows[3].name,
        rows[4].name,
      })
      assert.is_nil(rows[1].state)
      assert.are.equal("absent", rows[2].state)
      assert.are.equal("late", rows[4].state)
    end)

    it("filters by part of a name, ignoring case, including names with spaces", function()
      local rows, matched = ViewModel.AttendanceRows(event, members, "yonemon g", 10)
      assert.are.equal(1, matched)
      assert.are.equal("Yonemon Gg-Realm", rows[1].name)
    end)

    it("cuts at the limit but still reports how many matched", function()
      local rows, matched = ViewModel.AttendanceRows(event, members, "", 2)
      assert.are.equal(2, #rows)
      assert.are.equal(4, matched)
    end)
  end)
end)

describe("ViewModel loot tab helpers", function()
  it("offers apply to everyone and council actions only to the council and admins", function()
    local member = ViewModel.LootActions("member")
    assert.is_true(member.apply)
    assert.is_false(member.open or member.vote or member.award)
    local rl = ViewModel.LootActions("rl")
    assert.is_false(rl.open or rl.vote or rl.award)
    for _, role in ipairs({ "council", "admin" }) do
      local actions = ViewModel.LootActions(role)
      assert.is_true(actions.open and actions.apply and actions.vote and actions.award)
    end
    assert.is_false(ViewModel.LootActions(nil).apply)
  end)

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
