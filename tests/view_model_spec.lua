local function load_view_model()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Domain/PermissionService", "Domain/EventModel", "Domain/EventService",
    "Domain/LootModel", "Domain/LootService", "UI/ViewModel",
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
    local text = table.concat(ViewModel.Home({
      version = "0.1.0",
      readinessText = "1/3 met, 2 unknown",
      syncLines = { "sync paused: encounter in progress", "queued messages: 1" },
    }), "\n")
    assert.is_truthy(text:find("Nrage Assistant 0.1.0", 1, true))
    assert.is_truthy(text:find("Your readiness: 1/3 met, 2 unknown", 1, true))
    assert.is_truthy(text:find("  sync paused: encounter in progress", 1, true))
  end)

  it("escapes sync lines, which can contain sender names", function()
    local text = table.concat(ViewModel.Home({
      version = "dev", readinessText = "0/0 met", syncLines = { "  |cffff0000Evil-Realm - addon 1" },
    }), "\n")
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
        class = "MAGE", level = 1, fields = { role = "|Hitem:1|h" }, receivedAt = now,
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
    for _, tab in ipairs(ViewModel.TABS) do values[tab.value] = true end
    assert.are.same({ home = true, profile = true, ready = true, raid = true, loot = true, roster = true }, values)
  end)

  it("documents every user command in the help", function()
    local text = table.concat(ViewModel.HelpLines(), "\n")
    for _, command in ipairs({
      "role", "profile", "ready", "consent", "publish", "event", "attendance", "assign", "loot", "report",
      "template", "minimap", "export", "import", "debug", "sync", "help", "version",
    }) do
      assert.is_truthy(text:find("/nrage " .. command, 1, true), command)
    end
  end)
end)

describe("ViewModel.Raid", function()
  local function event(overrides)
    local e = {
      eventId = "ev-1", title = "Molten Core", status = "open", startAt = 5000,
      attendance = {}, assignments = {},
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
  end
  local format = function(timestamp) return "date:" .. timestamp end

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
      ["A-Realm"] = { state = "present" }, ["B-Realm"] = { state = "present" }, ["C-Realm"] = { state = "late" },
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
      eventId = id, title = title, status = "open", startAt = 1, attendance = {}, assignments = {}, loot = loot or {},
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
          sessionId = "s1", itemName = "Thunderfury", status = "open",
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
          sessionId = "s1", itemName = "Alpha", status = "closed", candidates = {}, votes = {},
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
          sessionId = "s1", itemName = "|Hitem:1|h[Bad]|h", status = "closed", candidates = {}, votes = {},
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
