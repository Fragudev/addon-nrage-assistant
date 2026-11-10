-- `locale` (optional) is the client locale code to load it for, e.g. "esES".
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/LayerModel",
    "Domain/PermissionService",
    "Domain/ModuleRegistry",
    "Domain/Settings",
    "Domain/ModuleService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/ReadinessRules",
    "Domain/ReadinessService",
    "Domain/ProfileService",
    "Domain/ReportService",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelRaid",
    "UI/ViewModelGuild",
    "UI/ViewModelProfessions",
    "UI/ViewModelLayers",
    "Commands/RaidCommands",
    "Commands/LootCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns.Constants, ns
end

local ViewModel, Constants, viewNs = load_view_model()

describe("ViewModel.Escape", function()
  it("doubles pipes so text cannot start a colour code or link", function()
    assert.are.equal("||cffff0000red||r", ViewModel.Escape("|cffff0000red|r"))
  end)

  it("accepts non-strings", function()
    assert.are.equal("60", ViewModel.Escape(60))
  end)
end)

describe("ViewModel.ReportBanner", function()
  it("says success, warning or danger for what a command returned, escaped", function()
    local kind, text = ViewModel.ReportBanner({ "done |cff" })
    assert.are.equal("success", kind)
    assert.are.equal("done ||cff", text)
    kind, text = ViewModel.ReportBanner({ "saved", "not sent" })
    assert.are.equal("warning", kind)
    assert.are.equal("saved not sent", text)
    assert.are.equal("danger", (ViewModel.ReportBanner(viewNs.Validate.Failure("no"))))
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
      professions = true,
      events = true,
      ready = true,
      loot = true,
      pvp = true,
      groups = true,
      announcements = true,
      modules = true,
      raid = true,
      rules = true,
      roster = true,
      pvpadmin = true,
      installs = true,
      announceadmin = true,
      ranks = true,
    }, values)
  end)

  it("orders the Guild tabs and then the Admin ones, and hides Profile, Layers and Blacklist", function()
    local order, groups = {}, {}
    for _, tab in ipairs(ViewModel.TABS) do
      order[#order + 1] = tab.value
      groups[tab.value] = tab.group
      assert.is_truthy(tab.icon, tab.value)
    end
    assert.are.same({
      "home",
      "professions",
      "events",
      "ready",
      "loot",
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
    }, order)
    for _, value in ipairs({
      "home",
      "professions",
      "events",
      "ready",
      "loot",
      "pvp",
      "groups",
      "announcements",
      "modules",
    }) do
      assert.are.equal("guild", groups[value], value)
    end
    for _, value in ipairs({ "raid", "rules", "roster", "pvpadmin", "installs", "ranks", "announceadmin" }) do
      assert.are.equal("admin", groups[value], value)
    end
    for _, value in ipairs({ "profile", "layers", "blacklist", "me" }) do
      assert.is_nil(groups[value], value)
    end
  end)

  it("labels the tabs: Raid in both groups, Raid check, Roster rules, Members, PvP and Installed check", function()
    local texts = {}
    for _, tab in ipairs(ViewModel.TABS) do
      texts[tab.value] = tab.text
    end
    assert.are.same({
      home = "Home",
      professions = "Professions",
      events = "Raid",
      ready = "Raid check",
      loot = "Loot",
      pvp = "PvP",
      groups = "Groups",
      announcements = "Announcements",
      modules = "Modules",
      raid = "Raid",
      rules = "Roster rules",
      roster = "Members",
      pvpadmin = "PvP",
      installs = "Installed check",
      announceadmin = "Announcements",
      ranks = "Ranks",
    }, texts)
  end)

  it("documents the three commands that are left in the help", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, command in ipairs({ "/nrage  ", "/nrage help", "/nrage debug" }) do
      assert.is_truthy(text:find(command, 1, true), command)
    end
    assert.are.equal(3, #ViewModel.HelpLines())
  end)
end)

describe("ViewModel raid tab helpers", function()
  it("only offers what the role may do, like the commands", function()
    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.are.same({ events = false, attendance = false, assignments = false }, ViewModel.RaidActions(role), role)
    end
    assert.are.same({ events = false, attendance = false, assignments = false }, ViewModel.RaidActions(nil))
    for _, role in ipairs({ "gm", "cogm", "officer", "rl" }) do
      assert.are.same({ events = true, attendance = true, assignments = true }, ViewModel.RaidActions(role), role)
    end
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
  it("offers opening, voting and awarding to rl, officer, cogm and gm, and nothing in the tab to the rest", function()
    local roster = ViewModel.LootActions("roster", "r1")
    assert.is_false(roster.apply or roster.open or roster.vote or roster.award)
    for _, role in ipairs({ "member", "alter" }) do
      local actions = ViewModel.LootActions(role, "r1")
      assert.is_false(actions.apply or actions.open or actions.vote or actions.award, role)
    end
    for _, role in ipairs({ "rl", "officer", "cogm", "gm" }) do
      local actions = ViewModel.LootActions(role, "r1")
      assert.is_true(actions.open and actions.apply and actions.vote and actions.award, role)
    end
    assert.is_false(ViewModel.LootActions(nil).apply)
  end)

  it("limits officer and rl to the events of the own roster, and gm and cogm to none", function()
    local own, other, guildWide = { rosterId = "r1" }, { rosterId = "r2" }, {}
    for _, role in ipairs({ "rl", "officer" }) do
      assert.is_true(ViewModel.LootActions(role, "r1", own).vote, role)
      assert.is_true(ViewModel.LootActions(role, "r1", guildWide).open, role)
      local actions = ViewModel.LootActions(role, "r1", other)
      assert.is_false(actions.open or actions.vote or actions.award or actions.apply, role)
      assert.is_false(ViewModel.LootActions(role, nil, own).open, role)
    end
    for _, role in ipairs({ "gm", "cogm" }) do
      assert.is_true(ViewModel.LootActions(role, nil, other).award, role)
    end
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
end)

describe("ViewModel readiness tab helpers", function()
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

  it("has the tabs of the role, then the Intel toggle and the settings, and no sync request", function()
    local entries = ViewModel.MinimapMenu("member")
    local tabs = ViewModel.TabsFor("member")
    assert.are.equal(#tabs + 2, #entries)
    for index, tab in ipairs(tabs) do
      assert.are.same({ text = tab.text, icon = tab.icon, action = "tab", value = tab.value }, entries[index])
    end
    assert.are.same({ text = "Intel", icon = "search", action = "intel", value = "@intel" }, entries[#entries - 1])
    assert.are.equal("settings", entries[#entries].action)
    for _, entry in ipairs(entries) do
      assert.are_not.equal("sync", entry.action)
    end
    local admin = ViewModel.MinimapMenu("gm")
    assert.are.equal("announceadmin", admin[#admin - 2].value)
    assert.are.equal("@intel", admin[#admin - 1].value)
    assert.are.equal("settings", admin[#admin].action)
    local roster = ViewModel.MinimapMenu("roster", "r1")
    assert.are.equal("ready", roster[4].value)
    assert.are.equal(#ViewModel.TabsFor("roster", "r1") + 2, #roster)
    assert.are.equal("@intel", roster[#roster - 1].value)
  end)

  it("words the result of a sync request made from the troubleshooting command", function()
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
    local pending = ViewModel.PendingLoot(events(), "Me-Realm", {}, "roster", "r1")
    assert.are.equal(2, #pending)
    assert.are.equal("Sulfuras", pending[1].itemName)
    assert.are.equal("Thunderfury", pending[2].itemName)
    assert.are.equal("Molten Core", pending[1].eventTitle)
    assert.are.equal("a", pending[1].eventId)
  end)

  it("leaves out sessions already answered, passed on or closed", function()
    local data = events()
    data.a.loot.s1.candidates["Me-Realm"] = { spec = "Fury", need = "main" }
    local pending = ViewModel.PendingLoot(data, "Me-Realm", { s2 = true }, "roster", "r1")
    assert.are.equal(0, #pending)
  end)

  it("still offers a session someone else applied to", function()
    local data = events()
    data.a.loot.s1.candidates["Other-Realm"] = { spec = "Fury", need = "main" }
    assert.are.equal(2, #ViewModel.PendingLoot(data, "Me-Realm", {}, "roster", "r1"))
  end)

  it("returns nothing to a member and an alter", function()
    for _, role in ipairs({ "member", "alter", "stranger" }) do
      assert.are.equal(0, #ViewModel.PendingLoot(events(), "Me-Realm", {}, role, "r1"), role)
    end
    assert.are.equal(0, #ViewModel.PendingLoot(events(), "Me-Realm", {}, nil, nil))
  end)

  it("returns the sessions of the own roster only to roster, rl and officer", function()
    local data = events()
    data.a.rosterId, data.b.rosterId = "r1", "r2"
    data.b.loot.s3.status = "open"
    for _, role in ipairs({ "roster", "rl", "officer" }) do
      assert.are.equal(2, #ViewModel.PendingLoot(data, "Me-Realm", {}, role, "r1"), role)
      assert.are.equal(0, #ViewModel.PendingLoot(data, "Me-Realm", {}, role, "r3"), role)
      assert.are.equal(0, #ViewModel.PendingLoot(data, "Me-Realm", {}, role, nil), role)
    end
  end)

  it("returns the sessions of every roster to gm and cogm", function()
    local data = events()
    data.a.rosterId, data.b.rosterId = "r1", "r2"
    data.b.loot.s3.status = "open"
    for _, role in ipairs({ "gm", "cogm" }) do
      assert.are.equal(3, #ViewModel.PendingLoot(data, "Me-Realm", {}, role, nil), role)
    end
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
  it("describes the top rank, no rank yet and no ranks configured", function()
    assert.are.equal(
      "Rank: Corporal (40 honourable kills), the highest rank",
      ViewModel.PvPRankLine(40, { { name = "Private", kills = 0 }, { name = "Corporal", kills = 25 } })
    )
    assert.are.equal("Rank: none yet - 3 to Scout", ViewModel.PvPRankLine(2, { { name = "Scout", kills = 5 } }))
    assert.are.equal("Rank: none (no ranks are configured)", ViewModel.PvPRankLine(2, {}))
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

  it("offers the rules tab to who may view the rules: gm and cogm, officer, and rl with a roster", function()
    local function has(role, rosterId, value)
      return ViewModel.TabVisible(value, role, rosterId)
    end
    for _, role in ipairs({ "gm", "cogm", "officer" }) do
      assert.is_true(has(role, nil, "rules"), role)
      assert.is_true(has(role, "r1", "rules"), role)
    end
    assert.is_true(has("rl", "r1", "rules"))
    assert.is_false(has("rl", nil, "rules"))
    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.is_false(has(role, "r1", "rules"), role)
    end
    assert.is_false(has(nil, "r1", "rules"))
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

  it("does not save a skill number alone as the name of a profession", function()
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromInput("profession", "Cook", "300", existing)))
    assert.are.equal(
      "bad_details",
      select(2, ViewModel.RuleFromFields("profession", { label = "Cook", profession = "", min = "300" }, {}))
    )
    local rule = ViewModel.RuleFromInput("profession", "Cook", "Cooking 300", existing)
    assert.are.equal("Cooking", rule.profession)
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
    assert.are.equal("Raid check", texts.ready)
    assert.are.equal("Reglas del roster", texts.rules)
    assert.are.equal("Miembros", texts.roster)
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

describe("ViewModel sidebar, user card and sync pill", function()
  local function navValues(role, rosterId)
    local labels, values = {}, {}
    for _, group in ipairs(ViewModel.NavGroups(role, rosterId)) do
      labels[#labels + 1] = group.label
      local items = {}
      for _, item in ipairs(group.items) do
        items[#items + 1] = item.value
      end
      values[#values + 1] = items
    end
    return labels, values
  end

  local GUILD_ALL = { "home", "professions", "events", "ready", "loot", "pvp", "groups", "announcements", "modules" }

  it("groups the tabs in Guild and Admin, with no unlabeled group", function()
    local labels, values = navValues("gm")
    assert.are.same({ "Guild", "Admin" }, labels)
    assert.are.same(GUILD_ALL, values[1])
    assert.are.same({ "raid", "rules", "roster", "pvpadmin", "installs", "ranks", "announceadmin" }, values[2])
    assert.are.equal("Raid", ViewModel.NavGroups("gm")[2].items[1].text)
    assert.is_truthy(ViewModel.NavGroups("gm")[2].items[1].icon)
  end)

  it("shows each rank the tabs of the matrix, with a roster", function()
    local expected = {
      gm = { GUILD_ALL, { "raid", "rules", "roster", "pvpadmin", "installs", "ranks", "announceadmin" } },
      cogm = { GUILD_ALL, { "raid", "rules", "roster", "pvpadmin", "installs", "ranks", "announceadmin" } },
      officer = { GUILD_ALL, { "raid", "rules", "roster", "ranks" } },
      rl = { GUILD_ALL, { "raid", "rules", "roster", "ranks" } },
      roster = { GUILD_ALL },
      member = { { "home", "professions", "pvp", "groups", "announcements", "modules" } },
      alter = { { "home", "professions", "pvp", "groups", "announcements", "modules" } },
    }
    for role, groups in pairs(expected) do
      local _, values = navValues(role, "r1")
      assert.are.same(groups, values, role)
    end
  end)

  it("shows the ranks that depend on a roster nothing but the Guild basics without one", function()
    local basics = { { "home", "professions", "pvp", "groups", "announcements", "modules" } }
    for _, role in ipairs({ "roster", "member", "alter" }) do
      local labels, values = navValues(role, nil)
      assert.are.same({ "Guild" }, labels, role)
      assert.are.same(basics, values, role)
    end
    -- The Admin group opens with admin_view, but its tabs follow their own scope: rl without a roster has only the
    -- Ranks tab, which every Admin rank reads.
    local _, rl = navValues("rl", nil)
    assert.are.same(
      { { "home", "professions", "pvp", "groups", "announcements", "modules" }, { "ranks" } },
      { rl[1], rl[2] or {} }
    )
    -- gm, cogm and officer reach every roster, so a missing roster of their own changes nothing for them.
    local _, gm = navValues("gm", nil)
    assert.are.same({ GUILD_ALL, { "raid", "rules", "roster", "pvpadmin", "installs", "ranks", "announceadmin" } }, gm)
    local _, officer = navValues("officer", nil)
    assert.are.same(
      { { "home", "professions", "pvp", "groups", "announcements", "modules" }, { "rules", "roster", "ranks" } },
      officer
    )
  end)

  it("keeps the Admin group away from roster, member and alter, and from a player without a rank", function()
    for _, role in ipairs({ "roster", "member", "alter" }) do
      for _, group in ipairs(ViewModel.NavGroups(role, "r1")) do
        assert.are_not.equal("Admin", group.label, role)
      end
    end
    for _, group in ipairs(ViewModel.NavGroups(nil, nil)) do
      assert.are_not.equal("Admin", group.label)
    end
  end)

  it("shows the open groups on the Groups item and on no other", function()
    local function badges(count)
      local found = {}
      for _, group in ipairs(ViewModel.NavGroups("gm", "r1", count)) do
        for _, item in ipairs(group.items) do
          found[item.value] = item.badge
        end
      end
      return found
    end
    assert.are.same({ groups = "4" }, badges(4))
    assert.are.same({}, badges(0))
    assert.are.same({}, badges(nil))
    assert.are.same({ groups = "99+" }, badges(250))
    assert.are.same(
      {},
      (function()
        local found = {}
        for _, group in ipairs(ViewModel.NavGroups("gm", "r1")) do
          for _, item in ipairs(group.items) do
            found[item.value] = item.badge
          end
        end
        return found
      end)()
    )
  end)

  it("counts the open groups for the sidebar", function()
    assert.are.equal("3", ViewModel.GroupsBadge(3))
    assert.are.equal("99+", ViewModel.GroupsBadge(100))
    assert.is_nil(ViewModel.GroupsBadge(0))
    assert.is_nil(ViewModel.GroupsBadge(nil))
    assert.is_nil(ViewModel.GroupsBadge("3"))
  end)

  it("tells which tabs a player sees, hidden and unknown ones never", function()
    assert.is_true(ViewModel.TabVisible("home", "member", nil))
    assert.is_true(ViewModel.TabVisible("pvpadmin", "cogm", nil))
    assert.is_false(ViewModel.TabVisible("pvpadmin", "officer", "r1"))
    assert.is_true(ViewModel.TabVisible("installs", "gm", nil))
    assert.is_true(ViewModel.TabVisible("installs", "cogm", nil))
    for _, role in ipairs({ "officer", "rl", "roster", "member", "alter" }) do
      assert.is_false(ViewModel.TabVisible("installs", role, "r1"), role)
    end
    -- Ranks: every Admin rank reads it; roster, member and alter do not see the Admin group at all.
    for _, role in ipairs({ "gm", "cogm", "officer", "rl" }) do
      assert.is_true(ViewModel.TabVisible("ranks", role, "r1"), role)
    end
    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.is_false(ViewModel.TabVisible("ranks", role, "r1"), role)
    end
    assert.is_false(ViewModel.TabVisible("raid", "roster", "r1"))
    for _, value in ipairs({ "profile", "layers", "blacklist", "nowhere" }) do
      assert.is_false(ViewModel.TabVisible(value, "gm", "r1"), value)
    end
  end)

  it("gives every tab an icon", function()
    for _, tab in ipairs(ViewModel.TabsFor("gm")) do
      assert.is_truthy(tab.icon, tab.value)
    end
  end)

  it("translates the tab names again when the language changes", function()
    local loaded = {}
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
      "Domain/ProfileService",
      "Domain/ReportService",
      "UI/Kit/Theme",
      "UI/Kit/Util",
      "UI/Kit/Calendar",
      "UI/ViewModel",
      "UI/ViewModelHome",
      "UI/ViewModelRaid",
      "UI/ViewModelGuild",
    }) do
      assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", loaded)
    end
    local vm, ns = loaded.ViewModel, loaded
    local tabs = vm.TABS
    assert.are.equal("Home", tabs[1].text)
    ns.Locale.UsePreference("es", "enUS")
    assert.are.equal("Inicio", vm.TABS[1].text)
    assert.are.equal("Inicio", vm.NavGroups("member")[1].items[1].text)
    assert.are.equal("Reglas del roster", vm.TABS[11].text)
    assert.are.equal("cumplido", vm.Word("met"))
    ns.Locale.UsePreference("auto", "enUS")
    assert.are.equal("Home", vm.TABS[1].text)
    assert.are.equal("met", vm.Word("met"))
    -- The rule texts follow too.
    ns.Locale.UsePreference("es", "enUS")
    assert.are.equal("Nivel mínimo", vm.RULE_CHECK_TEXT.level)
  end)

  it("describes the user card with the rank and the addon role", function()
    assert.are.same({ name = "Ann", detail = "Raider \194\183 Raid leader" }, ViewModel.UserCard("Ann", "Raider", "rl"))
    assert.are.same({ name = "Ann", detail = "none" }, ViewModel.UserCard("Ann", nil, nil))
    assert.are.same({ name = "?", detail = "Member" }, ViewModel.UserCard(nil, "", "member"))
  end)

  it("tells the sync state in the pill", function()
    assert.are.same({ text = "Sync off", status = "muted" }, ViewModel.SyncPill(nil))
    assert.are.same(
      { text = "Sync paused", status = "warning" },
      ViewModel.SyncPill({ paused = true, queued = 4, incompatible = {} })
    )
    assert.are.same(
      { text = "3 queued", status = "warning" },
      ViewModel.SyncPill({ paused = false, queued = 3, incompatible = {} })
    )
    assert.are.same(
      { text = "Sync ready", status = "success" },
      ViewModel.SyncPill({ paused = false, queued = 0, incompatible = {} })
    )
  end)
end)

-- The structured rows of the redesigned tabs (plan 3.1 to 3.3, 3.8).
local function fake_clock(parts_by_stamp)
  return {
    date = function(_, stamp)
      return parts_by_stamp[stamp]
    end,
  }
end

describe("ViewModel dates", function()
  it("writes a date as 'Thu 23 Oct · 20:30'", function()
    local clock = fake_clock({ [1] = { year = 2026, month = 10, day = 23, hour = 20, min = 30 } })
    assert.are.equal("Fri 23 Oct \194\183 20:30", ViewModel.DateText(1, clock))
    assert.is_nil(ViewModel.DateText(nil))
    assert.is_nil(ViewModel.DateText("x"))
  end)

  it("keeps the order of the weekdays and the months, in both languages", function()
    assert.are.equal("Mon", ViewModel.WEEKDAYS[1])
    assert.are.equal("Sun", ViewModel.WEEKDAYS[7])
    assert.are.equal(12, #ViewModel.MONTHS)
    assert.are.equal("October", ViewModel.MONTHS_LONG[10])
  end)

  it("says when the profile was last published", function()
    assert.are.equal("Not published yet", ViewModel.LastPublished(nil, 1000))
    assert.are.equal("Last published: just now", ViewModel.LastPublished(990, 1000))
    assert.are.equal("Last published: 3 min ago", ViewModel.LastPublished(820, 1000))
    assert.are.equal("Last published: 2 h ago", ViewModel.LastPublished(1000 - 2 * 3600 - 5, 1000))
    assert.are.equal("Last published: 4 d ago", ViewModel.LastPublished(1000, 1000 + 4 * 86400 + 5))
    -- A publication dated in the future (a clock skew) counts as just now.
    assert.are.equal("Last published: just now", ViewModel.LastPublished(2000, 1000))
  end)
end)

describe("ViewModel.NextEventCard", function()
  local function event(id, title, status, startAt, loot)
    return {
      eventId = id,
      title = title,
      status = status,
      startAt = startAt,
      attendance = {},
      assignments = {},
      loot = loot or {},
    }
  end

  it("picks the soonest upcoming event and ignores past, closed and cancelled ones", function()
    local events = {
      past = event("past", "Past", "planned", 100),
      closed = event("closed", "Closed", "closed", 5000),
      cancelled = event("cancelled", "Cancelled", "cancelled", 5000),
      later = event("later", "Later", "planned", 9000),
      soon = event("soon", "|cffff0000Soon", "open", 6000),
    }
    local card = ViewModel.NextEventCard(events, 1000)
    assert.are.equal("soon", card.eventId)
    assert.are.equal("||cffff0000Soon", card.title)
    assert.are.equal("open", card.status)
    assert.are.equal("success", card.statusToken)
  end)

  it("keeps an open event that already started, and falls back to an undated one", function()
    assert.are.equal("o", ViewModel.NextEventCard({ o = event("o", "Open", "open", 100) }, 1000).eventId)
    assert.are.equal("u", ViewModel.NextEventCard({ u = event("u", "Undated", "planned", nil) }, 1000).eventId)
    assert.is_nil(ViewModel.NextEventCard({}, 1000))
    assert.is_nil(ViewModel.NextEventCard({ p = event("p", "Past", "planned", 1) }, 1000))
  end)
end)

describe("ViewModel profile rows", function()
  it("strips the ruleset suffix from the character name", function()
    assert.are.equal("Yonemon Gg", ViewModel.CharacterName("Yonemon Gg"))
    assert.are.equal("Yonemon", ViewModel.CharacterName("Yonemon-ClassicBetaPvP"))
    assert.are.equal("?", ViewModel.CharacterName(nil))
  end)

  it("writes a class token as a name", function()
    assert.are.equal("Deathknight", ViewModel.ClassText("DEATHKNIGHT"))
    assert.is_nil(ViewModel.ClassText(nil))
    _G.LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mago" }
    assert.are.equal("Mago", ViewModel.ClassText("MAGE"))
    _G.LOCALIZED_CLASS_NAMES_MALE = nil
  end)

  it("builds the identity line, with unknown values said as such", function()
    local stats = ViewModel.IdentityStats({ class = "MAGE", level = 60, ilvl = 100 }, "Ann-Realm")
    assert.are.same({ "Name", "Ann", "Class", "Mage", "Level", "60", "Item level", "100" }, {
      stats[1].caption,
      stats[1].value,
      stats[2].caption,
      stats[2].value,
      stats[3].caption,
      stats[3].value,
      stats[4].caption,
      stats[4].value,
    })
    assert.are.equal("class", stats[2].color)
    assert.are.equal("MAGE", stats[2].classToken)
    local unknown = ViewModel.IdentityStats({}, "Ann")
    assert.are.same({ "unknown", "unknown", "unknown" }, { unknown[2].value, unknown[3].value, unknown[4].value })
    assert.are.equal("muted", unknown[2].color)
  end)

  it("groups the professions, primary first, from the secondary flag", function()
    local groups = ViewModel.ProfessionGroups({
      { name = "Alchemy", skill = 300, max = 300 },
      { name = "Herbalism", skill = 120, max = 300 },
      { name = "Cooking", skill = 75, max = 300, secondary = true },
      { name = "|cffff0000Fishing", skill = 10, secondary = true },
    })
    assert.are.same({ "Alchemy", "Herbalism" }, { groups.primary[1].name, groups.primary[2].name })
    assert.are.equal("300/300", groups.primary[1].text)
    assert.are.equal("||cffff0000Fishing", groups.secondary[2].name)
    assert.are.equal("10", groups.secondary[2].text)
  end)

  it("carries the icon of each profession, its own or the one remembered for its name", function()
    viewNs.Platform = {
      ProfessionIcon = function(name)
        return name == "Mining" and 134708 or nil
      end,
    }
    local groups = ViewModel.ProfessionGroups({
      { name = "Alchemy", icon = 136240, skill = 300, max = 300 },
      { name = "Mining", skill = 120, max = 300 },
      { name = "Herbalism", skill = 5, max = 300 },
    })
    viewNs.Platform = nil
    assert.are.equal(136240, groups.primary[1].icon)
    assert.are.equal(134708, groups.primary[2].icon)
    assert.is_nil(groups.secondary[1].icon)
    assert.is_nil(ViewModel.ProfessionGroups({ { name = "Herbalism", skill = 5, secondary = true } }).secondary[1].icon)
  end)

  it("counts the first two as primary when an older client sent no flags", function()
    local groups = ViewModel.ProfessionGroups({
      { name = "A", skill = 1 },
      { name = "B", skill = 2 },
      { name = "C", skill = 3 },
    })
    assert.are.equal(2, #groups.primary)
    assert.are.equal("C", groups.secondary[1].name)
    assert.are.same({ primary = {}, secondary = {} }, ViewModel.ProfessionGroups(nil))
  end)
end)

describe("ViewModel.ReadinessRows", function()
  local rules = {
    { id = "level", check = "level" },
    { id = "flask", check = "confirm" },
    { id = "ilvl", check = "ilvl" },
  }
  local results = {
    { status = "met", label = "Level 60", detail = "level 60 (needs 60)" },
    { status = "unknown", label = "Flask", detail = "not confirmed" },
    { status = "missing", label = "Item level", detail = "item level 10 (needs 60)" },
  }

  it("makes a row per rule with the status colors, and the manual one carries its status", function()
    local data = ViewModel.ReadinessRows(rules, results, { met = 1, countable = 3, unknown = 1 })
    assert.are.same(
      { "level", "met", "success" },
      { data.rows[1].ruleId, data.rows[1].status, data.rows[1].valueToken }
    )
    assert.are.equal("warning", data.rows[2].valueToken)
    assert.are.equal("danger", data.rows[3].valueToken)
    assert.are.same({ status = "unknown" }, data.rows[2].manual)
    assert.is_nil(data.rows[1].manual)
    assert.are.same({ text = "1 of 3 met", color = "danger" }, data.badge)
  end)

  it("colors the summary badge by state", function()
    local all = { { status = "met", label = "A", detail = "" } }
    assert.are.equal(
      "success",
      ViewModel.ReadinessRows({ { id = "a", check = "level" } }, all, { met = 1, countable = 1 }).badge.color
    )
    local pending = { { status = "unknown", label = "A", detail = "" } }
    assert.are.equal(
      "warning",
      ViewModel.ReadinessRows({ { id = "a", check = "level" } }, pending, { met = 0, countable = 1 }).badge.color
    )
    local waived = { { status = "waived", label = "A", detail = "" } }
    assert.are.equal(
      "muted",
      ViewModel.ReadinessRows({ { id = "a", check = "level" } }, waived, { met = 0, countable = 0 }).rows[1].valueToken
    )
  end)
end)

describe("ViewModel.MemberRows", function()
  local entries = {
    ["Ann-Realm"] = { rankName = "Raid Lider", rankIndex = 3, level = 60, class = "MAGE" },
    ["Bob"] = { rankName = "Oficial", rankIndex = 2, level = 59, class = "WARRIOR" },
    ["Boss"] = { rankName = "Maestro", rankIndex = 0, level = 60, class = "PRIEST" },
    ["Cid"] = { rankName = "Recruit", rankIndex = 7, level = 40, class = "ROGUE" },
  }
  local received = {
    ["Ann-Realm"] = {
      class = "MAGE",
      level = 60,
      ilvl = 120,
      receivedAt = 1000,
      fields = { role = "Dps", role2 = "Heal", main = "Annmain" },
      professions = { { name = "Alchemy", skill = 300 } },
    },
    ["Bob"] = { class = "WARRIOR", level = 59, ilvl = 90, receivedAt = 1000 - 8 * 86400, fields = { role = "Tank" } },
    ["Gone"] = { class = "MAGE", level = 10, receivedAt = 1000 },
  }
  local rosters = { r1 = { id = "r1", name = "Main" }, r2 = { id = "r2", name = "Alts" } }
  local members = { ["Ann-Realm"] = { rosterId = "r1" }, ["Bob"] = { rosterId = "r2" } }

  local function rows(extra)
    local args =
      { entries = entries, received = received, rosters = rosters, members = members, now = 1000, ownKey = "Ann-Realm" }
    for key, value in pairs(extra or {}) do
      args[key] = value
    end
    return ViewModel.MemberRows(args)
  end

  local function names(list)
    local out = {}
    for _, row in ipairs(list) do
      out[#out + 1] = row.key
    end
    return out
  end

  it("lists the whole guild, with the members without the addon marked and nobody who left", function()
    local list, total = rows()
    assert.are.same({ "Ann-Realm", "Bob", "Boss", "Cid" }, names(list))
    assert.are.equal(4, total)
    local byKey = {}
    for _, row in ipairs(list) do
      byKey[row.key] = row
    end
    assert.is_false(byKey["Ann-Realm"].noAddon)
    assert.is_true(byKey["Boss"].noAddon)
    assert.is_true(byKey["Cid"].noAddon)
    assert.is_true(byKey["Ann-Realm"].mine)
  end)

  it("merges the received profile with what the guild roster says", function()
    local ann = rows()[1]
    assert.are.same({ "Mage", 60, 120, "Dps", "Heal" }, { ann.class, ann.level, ann.ilvl, ann.spec, ann.spec2 })
    assert.are.same({ "r1", "Main", "rl" }, { ann.rosterId, ann.rosterName, ann.role })
    local cid = rows()[4]
    assert.are.same({ "Rogue", 40, nil, nil }, { cid.class, cid.level, cid.ilvl, cid.spec })
    assert.are.equal("alter", cid.role)
    assert.are.equal("Alter", cid.roleText)
    assert.are.equal("Officer", rows()[2].roleText)
  end)

  it("flags a profile older than a week as stale, and never shows anything as verified", function()
    local list = rows()
    assert.is_false(list[1].stale)
    assert.is_true(list[2].stale)
    assert.are.equal("1 min ago", rows({ now = 1060 })[1].updated)
    assert.is_nil(list[3].updated)
  end)

  it("has no PvP officer flag: the role is the guild rank", function()
    local list = rows({ pvpOfficers = { Bob = true } })
    for _, row in ipairs(list) do
      assert.is_nil(row.pvpOfficer)
    end
  end)

  it("makes the guild master gm whatever the rank is called, and ignores a stored role", function()
    local list = rows({ members = { Boss = { role = "rl" }, ["Cid"] = { role = "gm" } } })
    assert.are.same({ "gm", true }, { list[3].role, list[3].isGuildMaster })
    assert.are.equal("alter", list[4].role)
  end)

  it("filters by name, roster, spec and the addon", function()
    assert.are.same({ "Ann-Realm" }, names(rows({ search = "ann" })))
    assert.are.same({ "Ann-Realm" }, names(rows({ roster = "r1" })))
    assert.are.same({ "Boss", "Cid" }, names(rows({ roster = "none" })))
    assert.are.same({ "Bob" }, names(rows({ spec = "Tank" })))
    assert.are.same({ "Ann-Realm" }, names(rows({ spec = "Heal" })))
    assert.are.same({ "Ann-Realm", "Bob" }, names(rows({ addonOnly = true })))
    assert.are.same({}, names(rows({ search = "zzz" })))
    assert.are.equal(4, select(2, rows({ search = "zzz" })))
  end)

  it("sorts by a column, with ties by name", function()
    assert.are.same({ "Ann-Realm", "Boss", "Bob", "Cid" }, names(rows({ sort = { key = "level", descending = true } })))
    assert.are.same(
      { "Cid", "Bob", "Ann-Realm", "Boss" },
      names(rows({ sort = { key = "level", descending = false } }))
    )
    assert.are.same(
      { "Boss", "Cid", "Bob", "Ann-Realm" },
      names(rows({ sort = { key = "updated", descending = false } }))
    )
    -- By authority: gm first when ascending.
    assert.are.same({ "Boss", "Bob", "Ann-Realm", "Cid" }, names(rows({ sort = { key = "role", descending = false } })))
    assert.are.same({ "Cid", "Ann-Realm", "Bob", "Boss" }, names(rows({ sort = { key = "role", descending = true } })))
    assert.are.same({ "Ann-Realm", "Bob", "Boss", "Cid" }, names(rows({ sort = { key = "nonsense" } })))
  end)

  it("lists the members that sent a profile when the guild roster has not loaded", function()
    local list = rows({ entries = {} })
    assert.are.same({ "Ann-Realm", "Bob", "Gone" }, names(list))
  end)

  it("escapes what members wrote", function()
    local list = ViewModel.MemberRows({
      entries = { ["|cffff0000X"] = {} },
      received = { ["|cffff0000X"] = { class = "MAGE", level = 1, fields = { role = "Tank", main = "|r" } } },
      rosters = {},
      members = {},
      now = 1,
    })
    assert.are.equal("||cffff0000X", list[1].name)
    assert.are.equal("||r", list[1].main)
  end)

  it("builds the roster chips for whoever sees every roster, a raid leader and a member", function()
    local counts = { r1 = 2, r2 = 1, none = 5 }
    local admin = ViewModel.RosterChips(rosters, counts, "gm", nil)
    assert.are.same({
      { value = "r2", text = "Alts (1)" },
      { value = "r1", text = "Main (2)" },
      { value = "none", text = "No roster (5)" },
    }, admin)
    assert.are.same({ { value = "r1", text = "Main (2)" } }, ViewModel.RosterChips(rosters, counts, "rl", "r1"))
    assert.are.same({}, ViewModel.RosterChips(rosters, counts, "member", "r1"))
    assert.are.same(admin, ViewModel.RosterChips(rosters, counts, "officer", "r1"))
    assert.are.same(admin, ViewModel.RosterChips(rosters, counts, "cogm", nil))
  end)

  it("lists the own roster and the players with no roster for a raid leader's view", function()
    local list = ViewModel.MemberRows({
      entries = { A = {}, B = {}, C = {} },
      rosters = { r1 = { id = "r1", name = "Main" }, r2 = { id = "r2", name = "Alts" } },
      members = { A = { rosterId = "r1" }, B = { rosterId = "r2" } },
      now = 1,
      onlyRoster = "r1",
    })
    assert.are.same({ "A", "C" }, { list[1].key, list[2].key })
    assert.are.equal(2, #list)
  end)

  it("gives the roster dropdown of a row by rank and roster", function()
    local two = { r1 = { id = "r1", name = "Main" }, r2 = { id = "r2", name = "Alts" } }
    local function values(items)
      local out = {}
      for _, item in ipairs(items or {}) do
        out[#out + 1] = tostring(item.value)
      end
      return out
    end
    local free, mine, other = { rosterId = nil }, { rosterId = "r1" }, { rosterId = "r2" }
    assert.are.same({ "false", "r2", "r1" }, values(ViewModel.MemberRosterChoices("gm", nil, free, two)))
    assert.are.same({ "false", "r2", "r1" }, values(ViewModel.MemberRosterChoices("cogm", nil, other, two)))
    assert.is_nil(ViewModel.MemberRosterChoices("gm", nil, { isGuildMaster = true }, two))
    assert.are.same({ "false", "r1" }, values(ViewModel.MemberRosterChoices("rl", "r1", free, two)))
    assert.are.same({ "false", "r1" }, values(ViewModel.MemberRosterChoices("rl", "r1", mine, two)))
    assert.is_nil(ViewModel.MemberRosterChoices("rl", "r1", other, two))
    assert.is_nil(ViewModel.MemberRosterChoices("rl", nil, free, two))
    for _, role in ipairs({ "officer", "roster", "member", "alter" }) do
      assert.is_nil(ViewModel.MemberRosterChoices(role, "r1", free, two), role)
    end
  end)

  it("describes the detail of a row", function()
    local detail = ViewModel.MemberDetail(rows()[1])
    assert.are.same({ "Alchemy 300", "none", "Annmain" }, { detail.primary, detail.secondary, detail.main })
    assert.is_true(detail.hasProfile)
    local none = ViewModel.MemberDetail(rows()[4])
    assert.are.same({ "not declared", "No profile received", false }, { none.main, none.updated, none.hasProfile })
  end)

  it("offers the rosters with an optional none, and no role to pick", function()
    assert.is_nil(ViewModel.RoleChoices)
    local choices = ViewModel.RosterChoices(rosters, true)
    assert.are.same({ false, "r2", "r1" }, { choices[1].value, choices[2].value, choices[3].value })
    assert.are.equal(2, #ViewModel.RosterChoices(rosters, false))
  end)
end)

-- Raid and Loot rows (plan 3.4 and 3.5).
local function ev(id, title, status, startAt, extra)
  local e =
    { eventId = id, title = title, status = status, startAt = startAt, attendance = {}, assignments = {}, loot = {} }
  for key, value in pairs(extra or {}) do
    e[key] = value
  end
  return e
end

describe("ViewModel event list", function()
  local events = {
    a = ev("a", "Later", "planned", 5000),
    b = ev("b", "Soon", "open", 2000, { rosterId = "r1" }),
    c = ev("c", "Done", "closed", 9000),
    d = ev("d", "Old", "planned", 100),
    e = ev("e", "Undated", "planned", nil),
    f = ev("f", "Called off", "cancelled", 8000),
  }

  local function ids(rows)
    local out = {}
    for _, row in ipairs(rows) do
      out[#out + 1] = row.eventId
    end
    return out
  end

  it("splits upcoming from past: started, closed and cancelled events are past", function()
    assert.is_true(ViewModel.IsPastEvent(events.d, 1000))
    assert.is_true(ViewModel.IsPastEvent(events.c, 1000))
    assert.is_true(ViewModel.IsPastEvent(events.f, 1000))
    assert.is_false(ViewModel.IsPastEvent(events.a, 1000))
    assert.is_false(ViewModel.IsPastEvent(events.e, 1000))
  end)

  it("lists the upcoming ones soonest first with the undated last, and the past ones latest first", function()
    assert.are.same({ "b", "a", "e" }, ids(ViewModel.EventListRows(events, { filter = "upcoming", now = 1000 })))
    assert.are.same({ "c", "f", "d" }, ids(ViewModel.EventListRows(events, { filter = "past", now = 1000 })))
    assert.are.same({ "b", "a", "e" }, ids(ViewModel.EventListRows(events, { now = 1000 })))
  end)

  it("gives each row its date, status color and roster name", function()
    local rows = ViewModel.EventListRows(events, { now = 1000, rosters = { r1 = { id = "r1", name = "Main" } } })
    assert.are.same(
      { "Soon", "open", "success", "Main" },
      { rows[1].title, rows[1].status, rows[1].statusToken, rows[1].rosterName }
    )
    assert.are.equal("No date", rows[3].dateText)
    assert.are.equal("planned", rows[2].status)
    assert.are.equal("info", rows[2].statusToken)
    assert.is_nil(rows[2].rosterName)
  end)

  it("describes the header of the selected event", function()
    local header = ViewModel.EventHeader(events.b, { r1 = { id = "r1", name = "Main" } })
    assert.are.same({ "Soon", "open", "Main" }, { header.title, header.status, header.rosterName })
    assert.is_nil(ViewModel.EventHeader(events.a, {}).rosterName)
  end)

  it("offers the statuses and attendance states as dropdown items", function()
    assert.are.same({ "planned", "open", "closed", "cancelled" }, {
      ViewModel.EventStatusChoices()[1].value,
      ViewModel.EventStatusChoices()[2].value,
      ViewModel.EventStatusChoices()[3].value,
      ViewModel.EventStatusChoices()[4].value,
    })
    assert.are.equal(8, #ViewModel.AttendanceStateChoices())
  end)

  it("summarises the attendance in state order and counts the assignments", function()
    local event = ev("x", "X", "open", 1)
    event.attendance = { A = { state = "late" }, B = { state = "present" }, C = { state = "present" } }
    event.assignments = { a = {}, b = {} }
    local summary = ViewModel.EventSummary(event)
    assert.are.same({ "present", "2", "late", "1" }, {
      summary.attendance[1].caption == ViewModel.Word("present") and "present" or "?",
      summary.attendance[1].value,
      summary.attendance[2].caption == ViewModel.Word("late") and "late" or "?",
      summary.attendance[2].value,
    })
    assert.are.equal(2, summary.assignments)
    assert.is_false(ViewModel.EventSummary(ev("y", "Y", "open", 1)).recorded)
  end)
end)

describe("ViewModel attendance and group matching", function()
  local guild = { "Ann", "Bob Smith", "Bob Jones", "Cid Vega", "Dee" }

  it("matches group names to guild names exactly, or by the first word when that is unambiguous", function()
    local matched, unmatched = ViewModel.MatchGroupToGuild({ "Ann", "Cid", "Bob", "Zed", "Dee" }, guild)
    assert.are.same({ "Ann", "Cid Vega", "Dee" }, matched)
    -- Bob matches two guild members: it is a guess, so it is left out; Zed is not in the guild.
    assert.are.equal(2, unmatched)
  end)

  it("counts a member once and handles an empty group", function()
    assert.are.same({ { "Ann" }, 0 }, { ViewModel.MatchGroupToGuild({ "Ann", "Ann" }, guild) })
    assert.are.same({ {}, 0 }, { ViewModel.MatchGroupToGuild({}, guild) })
    assert.are.same({ "Bob Smith" }, (ViewModel.MatchGroupToGuild({ "Bob Smith" }, guild)))
  end)

  it("fills only the members that are not recorded yet and never overwrites", function()
    local event = ev("x", "X", "open", 1)
    event.attendance = { Ann = { state = "absent" } }
    local plan = ViewModel.FillFromGroup(event, { "Ann", "Dee", "Cid" }, guild)
    assert.are.same({ { "Cid Vega", "Dee" }, 1, 0 }, { plan.toMark, plan.alreadyRecorded, plan.unmatched })
  end)

  it("lists the recorded members with who and when", function()
    local event = ev("x", "X", "open", 1)
    event.attendance = {
      ["Zed"] = { state = "late", recordedBy = "Lead", updatedAt = 940 },
      ["Amy"] = { state = "present" },
    }
    local rows = ViewModel.AttendanceRows(event, 1000)
    assert.are.same({ "Amy", "Zed" }, { rows[1].name, rows[2].name })
    assert.are.same({ "Lead", "1 min ago" }, { rows[2].recordedBy, rows[2].recordedAt })
    assert.is_nil(rows[1].recordedAt)
  end)
end)

describe("ViewModel assignments and reports", function()
  it("groups the assignments by encounter and offers the used encounters plus a new one", function()
    local event = ev("x", "X", "open", 1)
    event.assignments = {
      a1 = { assignmentId = "a1", encounter = "Garr", characterKey = "Bob", task = "Tank" },
      a2 = { assignmentId = "a2", encounter = "Garr", characterKey = "Ann" },
      a3 = { assignmentId = "a3", encounter = "Rag", characterKey = "Cid" },
    }
    local groups = ViewModel.AssignmentGroups(event)
    assert.are.same({ "Garr", "Rag" }, { groups[1].encounter, groups[2].encounter })
    assert.are.equal("Ann", groups[1].rows[1].text)
    assert.is_truthy(groups[1].rows[2].text:find("Bob", 1, true))
    assert.is_truthy(groups[1].rows[2].text:find("Tank", 1, true))
    local choices = ViewModel.EncounterChoices(event)
    assert.are.same(
      { "Garr", "Rag", ViewModel.NEW_ENCOUNTER },
      { choices[1].value, choices[2].value, choices[3].value }
    )
    assert.are.same({}, ViewModel.AssignmentGroups(ev("y", "Y", "open", 1)))
  end)

  it("offers members and templates as items, escaped", function()
    assert.are.equal("||x", ViewModel.MemberChoices({ "|x" })[1].text)
    assert.are.equal("T", ViewModel.TemplateChoices({ "T" })[1].value)
  end)

  it("turns the reports into tables with a note when there is nothing", function()
    local event = ev("x", "X", "closed", 1)
    event.attendance = { Ann = { state = "present" }, Bob = { state = "absent" } }
    event.loot = {
      s1 = {
        sessionId = "s1",
        itemId = 1,
        itemName = "Sword",
        status = "closed",
        updatedAt = 5,
        candidates = { Ann = { need = "main", spec = "Fury" } },
        votes = {},
        award = { characterKey = "Ann", reason = "need", awardedBy = "Boss", at = 5 },
      },
    }
    local data = ViewModel.ReportTables({ x = event }, event, true)
    assert.are.same({ "Ann", "1", "1", "100%" }, {
      data.attendance.rows[1].name,
      data.attendance.rows[1].attended,
      data.attendance.rows[1].outcomes,
      data.attendance.rows[1].rate,
    })
    assert.are.equal("0%", data.attendance.rows[2].rate)
    assert.is_nil(data.attendance.note)
    assert.are.same(
      { "Ann", "1", "Sword" },
      { data.loot.rows[1].name, data.loot.rows[1].awards, data.loot.rows[1].items }
    )
    local none = ViewModel.ReportTables({}, ev("p", "P", "planned", 1), true)
    assert.is_truthy(none.attendance.note:find("No events held", 1, true))
    assert.are.equal("No loot sessions yet.", none.loot.note)
    local single = ViewModel.ReportTables({ x = event, y = ev("y", "Y", "closed", 2) }, event, false)
    assert.are.equal(1, single.attendance.held)
  end)

  it("offers the report scopes", function()
    assert.are.same({ "event", "all" }, { ViewModel.REPORT_SCOPES[1].value, ViewModel.REPORT_SCOPES[2].value })
  end)
end)

describe("ViewModel loot rows", function()
  local function session(id, item, status, updatedAt, candidates, extra)
    local s = {
      sessionId = id,
      itemId = 7,
      itemName = item,
      status = status,
      updatedAt = updatedAt,
      candidates = candidates or {},
      votes = {},
    }
    for key, value in pairs(extra or {}) do
      s[key] = value
    end
    return s
  end

  it("opens the Loot tab on the most recent event with an open session, else the most recent", function()
    local events = {
      old = ev("old", "Old", "closed", 100),
      mid = ev("mid", "Mid", "open", 200, { loot = { s = session("s", "Sword", "open", 1) } }),
      new = ev("new", "New", "open", 300),
    }
    assert.are.equal("mid", ViewModel.DefaultLootEvent(events))
    events.mid.loot.s.status = "closed"
    assert.are.equal("new", ViewModel.DefaultLootEvent(events))
    assert.is_nil(ViewModel.DefaultLootEvent({}))
  end)

  it("lists the events most recent first for the selector", function()
    local items = ViewModel.LootEventChoices({ a = ev("a", "A", "open", 100), b = ev("b", "|rB", "open", 200) })
    assert.are.same({ "b", "a" }, { items[1].value, items[2].value })
    assert.is_truthy(items[1].text:find("||rB", 1, true))
    assert.are.equal("A", ViewModel.LootEventChoices({ a = ev("a", "A", "open", nil, { updatedAt = 1 }) })[1].text)
  end)

  it("writes the time left", function()
    assert.are.equal("1:05 left", ViewModel.TimeLeftText(65))
    assert.are.equal("0:00 left", ViewModel.TimeLeftText(-3))
    assert.is_nil(ViewModel.TimeLeftText(nil))
  end)

  it("makes a card per session, newest first, with the candidates and the actions of the role", function()
    local event = ev("x", "Raid", "open", 1)
    event.loot = {
      old = session("old", "Axe", "closed", 1, { Ann = { need = "main", spec = "Fury" } }, {
        award = { characterKey = "Ann", reason = "need", awardedBy = "Boss", at = 5 },
      }),
      cur = session("cur", "Sword", "open", 9, {
        Ann = { need = "main", spec = "Fury", upgrade = "+12" },
        Bob = { need = "off", spec = "Prot" },
      }),
    }
    event.loot.cur.votes = { Boss = { target = "Ann" } }
    local cards = ViewModel.LootSessionCards(event, {
      actor = "Boss",
      rankOf = function()
        return "Raider"
      end,
      actions = { vote = true, award = true, apply = true, open = true },
      timeLeft = function(id)
        return id == "cur" and 30 or nil
      end,
    })
    assert.are.same({ "cur", "old" }, { cards[1].sessionId, cards[2].sessionId })
    local current = cards[1]
    assert.are.same(
      { true, "open", "success", "0:30 left", true },
      { current.open, current.status, current.statusToken, current.timeLeft, current.canClose }
    )
    assert.are.equal("Ann", current.candidates[1].name)
    assert.are.same({ "success", "Main spec", "Fury", "+12", 1, true, true, true }, {
      current.candidates[1].needToken,
      current.candidates[1].responseText,
      current.candidates[1].spec,
      current.candidates[1].upgrade,
      current.candidates[1].votes,
      current.candidates[1].mine,
      current.candidates[1].canVote,
      current.candidates[1].canAward,
    })
    assert.are.equal("warning", current.candidates[2].needToken)
    local closed = cards[2]
    assert.are.same({ false, "muted" }, { closed.open, closed.statusToken })
    assert.are.same({ "Ann", "Main spec", "need" }, { closed.award.winner, closed.award.response, closed.award.reason })
    assert.is_truthy(closed.summary:find("Axe", 1, true))
    assert.is_truthy(closed.summary:find("Ann", 1, true))
    assert.is_false(closed.candidates[1].canVote)
  end)

  it("gives a member no vote or award, and says a session closed without an award", function()
    local event = ev("x", "Raid", "open", 1)
    event.loot = {
      s = session("s", "Ring", "closed", 1),
      o = session("o", "Cape", "open", 2, { Ann = { need = "other", spec = "X" } }),
    }
    local cards = ViewModel.LootSessionCards(event, { actor = "Ann", actions = { apply = true } })
    assert.is_false(cards[1].canClose)
    assert.is_false(cards[1].candidates[1].canVote)
    assert.is_truthy(cards[2].summary:find("closed, not awarded", 1, true))
  end)

  it("builds the minutes with the winner, the response, the reason and the date", function()
    local event = ev("x", "Raid", "open", 1)
    event.loot = {
      b = session("b", "Ring", "closed", 20),
      a = session("a", "Axe", "closed", 10, { Ann = { need = "off", spec = "X" } }, {
        award = { characterKey = "Ann", reason = "|rneed", awardedBy = "Boss", at = 15 },
      }),
      o = session("o", "Open", "open", 5),
    }
    local rows = ViewModel.MinutesTable(event, function(at)
      return "t" .. at
    end)
    assert.are.equal(2, #rows)
    assert.are.same(
      { "Axe", "Ann", "Off spec", "||rneed", "t15" },
      { rows[1].item, rows[1].winner, rows[1].response, rows[1].reason, rows[1].date }
    )
    assert.are.same(
      { "Ring", "-", "-", "not awarded", "t20" },
      { rows[2].item, rows[2].winner, rows[2].response, rows[2].reason, rows[2].date }
    )
  end)

  it("takes the spec of a candidacy from the declared specs", function()
    local profile = { fields = { role = { value = "Tank" }, role2 = { value = "healer" } } }
    assert.are.equal("Tank", ViewModel.LootApplySpec(profile, "main"))
    assert.are.equal("Heal", ViewModel.LootApplySpec(profile, "off"))
    assert.are.equal("Tank", ViewModel.LootApplySpec(profile, "other"))
    assert.are.equal("Tank", ViewModel.LootApplySpec({ fields = { role = { value = "Tank" } } }, "off"))
    assert.is_nil(ViewModel.LootApplySpec({ fields = {} }, "main"))
    assert.is_nil(ViewModel.LootApplySpec({}, "off"))
  end)

  it("reads the quality of a link and previews a pasted item", function()
    local link = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury]|h|r"
    assert.are.equal(4, ViewModel.ItemQuality(link))
    assert.is_nil(ViewModel.ItemQuality("no link"))
    assert.is_nil(ViewModel.ItemQuality(5))
    local preview = ViewModel.ItemPreview(link)
    assert.are.same({ 19019, "Thunderfury", 4 }, { preview.itemId, preview.itemName, preview.quality })
    assert.is_nil(ViewModel.ItemPreview("hello"))
    assert.is_nil(ViewModel.ItemPreview(nil))
  end)

  it("lists the items of the last boss loot that a session accepts", function()
    local items = {
      { link = "|cffffffff|Hitem:1::::|h[One]|h|r", icon = "i1" },
      { link = "gold" },
      { link = "|cff1eff00|Hitem:2::::|h[Two]|h|r", icon = "i2" },
      { link = "|cff0070dd|Hitem:3::::|h[Three]|h|r" },
    }
    local list = ViewModel.BossLootItems(items, 2)
    assert.are.equal(2, #list)
    assert.are.same({ 1, "One", 1, "i1" }, { list[1].itemId, list[1].itemName, list[1].quality, list[1].icon })
    assert.are.equal(2, list[2].itemId)
    assert.are.same({}, ViewModel.BossLootItems(nil))
  end)
end)

-- PvP, Blacklist and Rules rows (plan 3.6, 3.7 and 3.9).
describe("ViewModel PvP rows", function()
  local stats = {
    honor = { world = 4, bg = 6 },
    blows = { world = 1, bg = 2 },
    daily = { ["2026-10-19"] = { honor = { world = 1, bg = 0 }, blows = { world = 0, bg = 0 } } },
  }

  it("builds the Today and Total grids with the rank", function()
    local grids = ViewModel.PvPStatGrids(stats, { day = "2026-10-19", honorAvailable = true, blowsAvailable = true })
    assert.are.same({ "Open world", "1" }, { grids.today[1].caption, grids.today[1].value })
    assert.are.same({ "Honourable kills", "10" }, { grids.total[3].caption, grids.total[3].value })
    assert.are.same({ "Killing blows", "3" }, { grids.total[4].caption, grids.total[4].value })
    assert.are.equal("Rank", grids.total[5].caption)
    assert.is_truthy(grids.total[5].value:find("Private", 1, true))
    assert.are.equal("Private", grids.rank.name)
  end)

  it("says 'Not available' in muted where the client cannot give the figure", function()
    local grids = ViewModel.PvPStatGrids(stats, { day = "2026-10-19", honorAvailable = false, blowsAvailable = false })
    assert.are.same({ "Not available", "muted" }, { grids.total[1].value, grids.total[1].color })
    assert.are.same({ "Not available", "muted" }, { grids.today[4].value, grids.today[4].color })
  end)

  it("positions the ranking rows, colors the top three and cuts at the limit", function()
    local rows = {}
    for index = 1, 5 do
      rows[index] = {
        label = "P" .. index,
        name = "P" .. index,
        rank = "R",
        world = index,
        bg = 0,
        total = index,
        blows = index,
        updated = "-",
        mine = index == 4,
      }
    end
    local data = ViewModel.RankingTable(rows, { limit = 4 })
    assert.are.same({ 4, 5 }, { data.shown, data.total })
    assert.are.same(
      { "gold", "silver", "bronze", "dim" },
      { data.rows[1].positionToken, data.rows[2].positionToken, data.rows[3].positionToken, data.rows[4].positionToken }
    )
    assert.is_true(data.rows[4].mine)
    local found = ViewModel.RankingTable(rows, { search = "p5" })
    assert.are.same({ 1, 1, 5 }, { found.shown, found.total, found.rows[1].position })
    assert.are.equal(
      "-",
      ViewModel.RankingTable({ { label = "A", name = "A", world = 0, bg = 0, total = 0 } }, {}).rows[1].blows
    )
  end)

  it("lists the recent kills with the notice for an unavailable or empty feed", function()
    local entries = { { killers = { "|rAnn", "Bob" }, victim = "Zed", where = "bg", blow = true, time = 5 } }
    local data = ViewModel.FeedRows(entries, {
      available = true,
      formatTime = function(t)
        return "t" .. t
      end,
    })
    assert.are.same({ "t5", "battleground", true }, { data.rows[1].time, data.rows[1].place, data.rows[1].blow })
    assert.is_truthy(data.rows[1].text:find("||rAnn, Bob", 1, true))
    assert.is_nil(data.notice)
    assert.are.equal("empty", ViewModel.FeedRows({}, { available = true }).notice)
    assert.are.equal("unavailable", ViewModel.FeedRows({}, { available = false }).notice)
    assert.are.equal("--:--", ViewModel.FeedRows(entries, { available = true }).rows[1].time)
  end)
end)

describe("ViewModel blacklist rows", function()
  local entries = {
    ann = { name = "Ann", reason = "ninja", addedBy = "Me", addedAt = 100, rev = 1 },
    bob = { name = "Bob Smith", reason = "|rrude", addedBy = "Other", addedAt = 200, rev = 1 },
    cid = { name = "Cid", reason = "afk", addedBy = "Other", addedAt = 300, rev = 1 },
  }
  local function names(rows)
    local out = {}
    for _, row in ipairs(rows) do
      out[#out + 1] = row.key
    end
    return out
  end

  it("lists the players in the group first, then by name", function()
    local rows = ViewModel.BlacklistTable(entries, { role = "member", actor = "Me", groupKeys = { cid = true } })
    assert.are.same({ "cid", "ann", "bob" }, names(rows))
    assert.is_true(rows[1].inGroup)
    assert.is_false(rows[2].inGroup)
  end)

  it("offers the pencil to who added the entry or the guild master, and the trash to the guild master", function()
    local member = ViewModel.BlacklistTable(entries, { role = "member", actor = "Me" })
    assert.are.same({ true, false, false }, { member[1].canEdit, member[2].canEdit, member[3].canEdit })
    assert.is_false(member[1].canRemove)
    local admin = ViewModel.BlacklistTable(entries, { role = "gm", actor = "Boss" })
    assert.are.same({ true, true }, { admin[1].canEdit, admin[1].canRemove })
  end)

  it("searches the name and the reason, escapes text and formats the date", function()
    local rows = ViewModel.BlacklistTable(entries, {
      role = "member",
      actor = "x",
      search = "RUDE",
      formatDate = function(at)
        return "d" .. at
      end,
    })
    assert.are.same({ "bob" }, names(rows))
    assert.are.same(
      { "||rrude", "|rrude", "d200", "Other" },
      { rows[1].reason, rows[1].rawReason, rows[1].added, rows[1].addedBy }
    )
    assert.are.same(
      { "ann" },
      names(ViewModel.BlacklistTable(entries, { role = "member", actor = "x", search = "ann" }))
    )
    assert.are.same(
      { "cid" },
      names(ViewModel.BlacklistTable(entries, { role = "member", actor = "x", search = "afk" }))
    )
    assert.are.equal("-", ViewModel.BlacklistTable(entries, { role = "member", actor = "x" })[1].added)
  end)

  it("finds the listed players that are in the group, even by first word", function()
    local keys = ViewModel.BlacklistGroupKeys(entries, { "Ann", "Bob", "Stranger" })
    assert.are.same({ ann = true, bob = true }, keys)
    assert.are.same({}, ViewModel.BlacklistGroupKeys(entries, {}))
  end)

  it("counts the characters of the reason and warns near the limit", function()
    assert.are.same({ "5 / 100", "muted", false }, {
      ViewModel.ReasonCounter("hello", 100).text,
      ViewModel.ReasonCounter("hello", 100).token,
      ViewModel.ReasonCounter("hello", 100).over,
    })
    assert.are.equal("warning", ViewModel.ReasonCounter(string.rep("x", 95), 100).token)
    assert.is_true(ViewModel.ReasonCounter(string.rep("x", 101), 100).over)
    assert.are.equal("0 / 100", ViewModel.ReasonCounter(nil, 100).text)
  end)
end)

describe("ViewModel rule rows", function()
  local rules = {
    { id = "level", label = "Level 60", check = "level", min = 60, evidenceMode = "observed" },
    { id = "flask", label = "|rFlask", check = "confirm", evidenceMode = "manual" },
    { id = "spec", label = "Spec", check = "field", field = "role", evidenceMode = "manual" },
  }

  it("marks the rules measured by the game as automatic and the rest as manual", function()
    local rows = ViewModel.RuleRows(rules)
    assert.are.same({ true, false, false }, { rows[1].automatic, rows[2].automatic, rows[3].automatic })
    assert.are.same({ "Automatic", "info" }, { rows[1].badge.text, rows[1].badge.color })
    assert.are.same({ "Manual", "warning" }, { rows[2].badge.text, rows[2].badge.color })
    assert.are.same({ "Minimum level", "level 60 or more" }, { rows[1].kindText, rows[1].summary })
    assert.are.equal("||rFlask", rows[2].name)
    assert.are.equal(rules[1], rows[1].rule)
  end)

  it("replaces a rule in place and keeps its id", function()
    local list = ViewModel.ReplaceRule(rules, "flask", { id = "other", label = "Food", check = "confirm" })
    assert.are.same({ "level", "flask", "spec" }, { list[1].id, list[2].id, list[3].id })
    assert.are.equal("Food", list[2].label)
    assert.are.equal("Flask", rules[2].label == "|rFlask" and "Flask" or "?")
    assert.are.same({ nil, "unknown_rule" }, { ViewModel.ReplaceRule(rules, "ghost", {}) })
    assert.are.equal(rules[1], list[1])
  end)

  it("offers the slots in order, the fields and the kinds", function()
    local slots = ViewModel.EnchantSlotChoices()
    assert.are.same({ "head", "shoulders" }, { slots[1].key, slots[2].key })
    assert.are.equal("Head", slots[1].text)
    assert.are.equal("mainhand", slots[#slots - 2].key)
    local fields = ViewModel.FieldChoices()
    assert.are.same(
      { "main", "notes", "role", "role2" },
      { fields[1].value, fields[2].value, fields[3].value, fields[4].value }
    )
    assert.are.equal(#ViewModel.RULE_CHECKS, #ViewModel.RuleKindChoices())
    assert.are.equal("level", ViewModel.RuleKindChoices()[1].value)
  end)

  it("fills the form from a rule and builds the rule back from the form", function()
    local source = { id = "ench", label = "Enchants", check = "enchants", slots = { 1, 16 } }
    local fields = ViewModel.RuleFields(source)
    assert.are.same({ [1] = true, [16] = true }, fields.slots)
    local rule = assert(ViewModel.RuleFromFields("enchants", fields, { source }, "ench"))
    assert.are.same({ "ench", "enchants", 1, 16 }, { rule.id, rule.check, rule.slots[1], rule.slots[2] })
    local buff = ViewModel.RuleFields({ spellIds = { 7, 8 }, names = { "Flask" }, label = "Flask" })
    assert.are.equal("7, 8, Flask", buff.buffs)
  end)

  it("builds each kind of rule from its controls", function()
    local level = assert(ViewModel.RuleFromFields("level", { label = "Level", min = "60" }, {}))
    assert.are.same({ "level", 60 }, { level.check, level.min })
    local ilvl = assert(ViewModel.RuleFromFields("ilvl", { label = "Gear", min = "100" }, {}))
    assert.are.equal(100, ilvl.min)
    local prof =
      assert(ViewModel.RuleFromFields("profession", { label = "Alchemist", profession = "Alchemy", min = "300" }, {}))
    assert.are.same({ "Alchemy", 300 }, { prof.profession, prof.min })
    local anyskill =
      assert(ViewModel.RuleFromFields("profession", { label = "Cook", profession = "Cooking", min = "" }, {}))
    assert.is_nil(anyskill.min)
    local buff = assert(ViewModel.RuleFromFields("buff", { label = "Flask", buffs = "123, Flask of Power" }, {}))
    assert.are.same({ { 123 }, { "Flask of Power" } }, { buff.spellIds, buff.names })
    local field = assert(ViewModel.RuleFromFields("field", { label = "Spec", field = "role" }, {}))
    assert.are.same({ "field", "role" }, { field.check, field.field })
    local confirm = assert(ViewModel.RuleFromFields("confirm", { label = "Ready" }, {}))
    assert.are.equal("confirm", confirm.check)
    local enchants =
      assert(ViewModel.RuleFromFields("enchants", { label = "Gear", slots = { [16] = true, [5] = true } }, {}))
    assert.are.same({ 5, 16 }, enchants.slots)
  end)

  it("keeps the id of an edited rule and gives a new rule a unique id", function()
    local list = { { id = "level", label = "Level", check = "level", min = 1 } }
    assert.are.equal(
      "level",
      assert(ViewModel.RuleFromFields("level", { label = "Level", min = "60" }, list, "level")).id
    )
    assert.are.equal("level_2", assert(ViewModel.RuleFromFields("level", { label = "Level", min = "60" }, list)).id)
  end)

  it("reports what is wrong and which control it belongs under", function()
    assert.are.equal("bad_label", select(2, ViewModel.RuleFromFields("level", { label = "", min = "60" }, {})))
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromFields("level", { label = "L", min = "abc" }, {})))
    assert.are.equal("bad_details", select(2, ViewModel.RuleFromFields("enchants", { label = "E", slots = {} }, {})))
    assert.are.equal("label", ViewModel.RuleErrorField("bad_label"))
    assert.are.equal("label", ViewModel.RuleErrorField("duplicate_id"))
    assert.are.equal("details", ViewModel.RuleErrorField("bad_details"))
  end)
end)

describe("ViewModel recipes", function()
  local function index()
    return {
      professions = { [171] = "Alchemy", [164] = "Blacksmithing" },
      recipes = {
        [10] = { professionId = 171, crafters = { "Zed", "Ann", "Bob", "Cat", "Dan" } },
        [11] = { professionId = 164, crafters = { "Ann" } },
      },
      members = 5,
    }
  end
  local names = { [10] = "Elixir", [11] = "Axe" }
  local function nameOf(id)
    return names[id]
  end
  local function online(name)
    return name == "Zed" or (name == "Dan" and false) or nil
  end

  it("offers all professions first and then each by name", function()
    local items = ViewModel.ProfessionChoices(index())
    assert.is_false(items[1].value)
    assert.are.equal("Alchemy", items[2].text)
    assert.are.equal(164, items[3].value)
  end)

  it("lists recipes by id with every crafter, the online ones first", function()
    local result = ViewModel.RecipeResults({ index = index(), online = online, nameOf = nameOf })
    assert.are.equal(2, result.total)
    assert.are.equal("Elixir", result.rows[1].name)
    assert.are.equal("Zed", result.rows[1].crafters[1].name)
    assert.are.equal(5, #result.rows[1].crafters)
  end)

  it("offers the online and unknown crafters, never the offline ones", function()
    local items = ViewModel.CrafterChoices({
      { name = "Zed Gg", label = "Zed Gg", online = true },
      { name = "Ann", label = "Ann", online = nil },
      { name = "Dan", label = "Dan", online = false },
    })
    assert.are.same({ { value = "Zed Gg", text = "Zed Gg" }, { value = "Ann", text = "Ann" } }, items)
  end)

  it("names the first offline crafters and counts the rest", function()
    local crafters = {}
    for position = 1, Constants.RECIPE_OFFLINE_NAMES_MAX + 2 do
      crafters[position] = { label = "C" .. position }
    end
    assert.are.equal("C1, C2, C3, C4, C5 and 2 more", ViewModel.OfflineCraftersText(crafters))
    assert.are.equal("C1, C2", ViewModel.OfflineCraftersText({ crafters[1], crafters[2] }))
  end)

  it("searches by name or id, filters by profession and hides offline crafters", function()
    local base = { index = index(), online = online, nameOf = nameOf }
    base.search = "AXE"
    assert.are.equal(11, ViewModel.RecipeResults(base).rows[1].recipeId)
    base.search = "10"
    assert.are.equal(10, ViewModel.RecipeResults(base).rows[1].recipeId)
    base.search = ""
    base.professionId = 164
    assert.are.equal(1, ViewModel.RecipeResults(base).total)
    base.professionId = false
    base.onlineOnly = true
    local result = ViewModel.RecipeResults(base)
    assert.are.equal(1, result.total)
    assert.are.equal(1, #result.rows[1].crafters)
  end)

  it("names a recipe the client does not know and caps the rows", function()
    local result = ViewModel.RecipeResults({ index = index(), online = online, nameOf = function() end, limit = 1 })
    assert.are.equal("Recipe 10", result.rows[1].name)
    assert.are.equal(1, result.shown)
    assert.are.equal(2, result.total)
    local searched = ViewModel.RecipeResults({
      index = index(),
      online = online,
      nameOf = function() end,
      search = "recipe",
      limit = 1,
    })
    assert.are.equal(1, searched.shown)
    assert.are.equal(2, searched.total)
  end)

  it("writes the whisper for the Ask button", function()
    assert.are.equal("/w Ann Could you craft me [Elixir]?", ViewModel.AskText("Ann", "[Elixir]"))
  end)

  it("describes the own professions with their last scan", function()
    local rows = ViewModel.MyProfessionRows(
      { { name = "Alchemy", skill = 150, max = 300 }, { name = "Cooking", skill = 5, secondary = true } },
      { [171] = { name = "Alchemy", ids = { 1, 2 }, at = 900, skill = 150 } },
      1000
    )
    assert.are.equal("150/300", rows[1].skillText)
    assert.is_false(rows[1].needsScan)
    assert.are.equal(2, rows[1].count)
    assert.are.equal("Never scanned", rows[2].scanText)
    assert.is_true(rows[2].needsScan)
    assert.is_true(rows[2].secondary)
  end)
end)

describe("ViewModel.RosterSelector", function()
  local rosters = {
    r1 = { id = "r1", name = "Main" },
    r2 = { id = "r2", name = "Alts" },
    r3 = { id = "r3", name = "Zeta" },
  }

  it("shows a selector to who has the action on every roster, with the rosters by name", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      local data = ViewModel.RosterSelector(role, "raid_manage", nil, rosters, nil)
      assert.is_true(data.visible, role)
      assert.are.same({ "r2", "r1", "r3" }, {
        data.options[1].value,
        data.options[2].value,
        data.options[3].value,
      })
      assert.are.same({ "Alts", "Main", "Zeta" }, { data.options[1].text, data.options[2].text, data.options[3].text })
      assert.is_nil(data.label)
    end
    local officer = ViewModel.RosterSelector("officer", "rules_view", "r1", rosters, nil)
    assert.is_true(officer.visible)
  end)

  it("starts on the own roster, else on the first by name, and keeps a valid pick", function()
    assert.are.equal("r3", ViewModel.RosterSelector("gm", "raid_manage", "r3", rosters, nil).selected)
    assert.are.equal("r2", ViewModel.RosterSelector("gm", "raid_manage", nil, rosters, nil).selected)
    assert.are.equal("r1", ViewModel.RosterSelector("gm", "raid_manage", "r3", rosters, "r1").selected)
    -- A pick that no longer exists, or an own roster that was deleted, falls back to the first by name.
    assert.are.equal("r3", ViewModel.RosterSelector("gm", "raid_manage", "r3", rosters, "gone").selected)
    assert.are.equal("r2", ViewModel.RosterSelector("gm", "raid_manage", "gone", rosters, nil).selected)
  end)

  it("fixes who has the action on the own roster only to it, shown as a label", function()
    for _, role in ipairs({ "officer", "rl" }) do
      local data = ViewModel.RosterSelector(role, "raid_manage", "r1", rosters, "r3")
      assert.is_false(data.visible, role)
      assert.are.equal("r1", data.selected, role)
      assert.are.equal("Main", data.label, role)
      assert.are.same({}, data.options, role)
    end
    -- The same rank can have the action on every roster in one tab and on its own in another.
    assert.is_false(ViewModel.RosterSelector("rl", "members_view", "r2", rosters, nil).visible)
    assert.is_true(ViewModel.RosterSelector("officer", "members_view", "r2", rosters, nil).visible)
  end)

  it("shows nothing to who has no roster or no access to the action", function()
    local noRoster = ViewModel.RosterSelector("rl", "raid_manage", nil, rosters, nil)
    assert.is_false(noRoster.visible)
    assert.is_nil(noRoster.selected)
    assert.is_nil(noRoster.label)
    local denied = ViewModel.RosterSelector("member", "raid_manage", "r1", rosters, "r2")
    assert.is_false(denied.visible)
    assert.is_nil(denied.selected)
    assert.is_nil(ViewModel.RosterSelector(nil, "raid_manage", "r1", rosters, nil).selected)
  end)

  it("has no selector for a guild without rosters", function()
    local data = ViewModel.RosterSelector("gm", "raid_manage", nil, {}, nil)
    assert.is_false(data.visible)
    assert.is_nil(data.selected)
  end)

  it("escapes the roster names", function()
    local data = ViewModel.RosterSelector("gm", "raid_manage", nil, { r1 = { id = "r1", name = "|cffff0000Red" } }, nil)
    assert.are.equal("||cffff0000Red", data.options[1].text)
  end)
end)

describe("ViewModel.UpcomingEventRows", function()
  local rosters = { r1 = { id = "r1", name = "Main" } }
  local function event(id, title, startAt, extra)
    local e = { eventId = id, title = title, status = "planned", startAt = startAt, rosterId = "r1" }
    for key, value in pairs(extra or {}) do
      e[key] = value
    end
    return e
  end

  it("lists the upcoming events soonest first, with the roster name or Guild", function()
    local events = {
      late = event("late", "Late", 9000),
      soon = event("soon", "Soon", 5000),
      all = event("all", "Everybody", 7000, { rosterId = false }),
    }
    events.all.rosterId = nil
    local rows = ViewModel.UpcomingEventRows(events, 1000, rosters)
    assert.are.same({ "soon", "all", "late" }, { rows[1].eventId, rows[2].eventId, rows[3].eventId })
    assert.are.same({ "Main", "Guild", "Main" }, { rows[1].rosterText, rows[2].rosterText, rows[3].rosterText })
    assert.are.equal("Soon", rows[1].title)
    assert.is_string(rows[1].dateText)
  end)

  it("leaves out past, closed and cancelled events", function()
    local events = {
      past = event("past", "Past", 500),
      closed = event("closed", "Closed", 5000, { status = "closed" }),
      cancelled = event("cancelled", "Cancelled", 5000, { status = "cancelled" }),
      ok = event("ok", "Ok", 5000),
    }
    local rows = ViewModel.UpcomingEventRows(events, 1000, rosters)
    assert.are.equal(1, #rows)
    assert.are.equal("ok", rows[1].eventId)
  end)

  it("gives no rows when there is nothing to show, and escapes the titles", function()
    assert.are.same({}, ViewModel.UpcomingEventRows({}, 1000, rosters))
    local rows = ViewModel.UpcomingEventRows({ a = event("a", "|cffff0000Red", 5000) }, 1000, rosters)
    assert.are.equal("||cffff0000Red", rows[1].title)
  end)
end)

describe("ViewModel module switches", function()
  local db

  before_each(function()
    db = { global = {} }
    viewNs.modules = viewNs.ModuleService.New({
      db = function()
        return db
      end,
    })
  end)

  after_each(function()
    viewNs.modules = nil
  end)

  local roles = { "gm", "cogm", "officer", "rl", "roster", "member", "alter" }

  it("shows every tab when no module is off", function()
    local values = {}
    for _, tab in ipairs(ViewModel.TabsFor("gm", "r1")) do
      values[tab.value] = true
    end
    for _, value in ipairs({ "home", "professions", "events", "loot", "pvp", "groups", "pvpadmin", "installs" }) do
      assert.is_true(values[value] == true, value)
    end
  end)

  it("hides the tabs of a module that is off, for every role, admin tabs included", function()
    viewNs.modules:SetEnabled("pvp", false)
    for _, role in ipairs(roles) do
      assert.is_false(ViewModel.TabVisible("pvp", role, "r1"), role)
      assert.is_false(ViewModel.TabVisible("pvpadmin", role, "r1"), role)
    end
  end)

  it("keeps the tabs of the other modules", function()
    viewNs.modules:SetEnabled("pvp", false)
    assert.is_true(ViewModel.TabVisible("professions", "member", "r1"))
    assert.is_true(ViewModel.TabVisible("home", "member", "r1"))
  end)

  it("hides the Raid tabs and the Loot tab, which needs Raid, when Raid is off", function()
    viewNs.modules:SetEnabled("raid", false)
    assert.is_false(ViewModel.TabVisible("events", "gm", "r1"))
    assert.is_false(ViewModel.TabVisible("roster", "gm", "r1"))
    assert.is_false(ViewModel.TabVisible("loot", "gm", "r1"))
    assert.is_true(ViewModel.TabVisible("pvp", "gm", "r1"))
  end)

  it("keeps every tab when the module service does not exist yet", function()
    viewNs.modules = nil
    assert.is_true(ViewModel.TabVisible("pvp", "member", "r1"))
  end)

  it("lists the Modules tab for everybody, in the Guild group", function()
    for _, role in ipairs(roles) do
      assert.is_true(ViewModel.TabVisible("modules", role, "r1"), role)
    end
    local guild = ViewModel.NavGroups("member", "r1")[1].items
    assert.are.equal("modules", guild[#guild].value)
  end)
end)
