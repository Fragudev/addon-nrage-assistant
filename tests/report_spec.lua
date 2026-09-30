local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Domain/PermissionService", "Domain/EventModel", "Domain/EventService",
    "Domain/LootModel", "Domain/LootService", "Domain/ReportService", "Commands/ReportCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Report = ns.ReportService

local function event(id, status, startAt, attendance, loot)
  return {
    eventId = id, title = "Raid " .. id, status = status, startAt = startAt,
    attendance = attendance or {}, assignments = {}, loot = loot or {},
  }
end

local function records(states)
  local result = {}
  for key, state in pairs(states) do result[key] = { state = state } end
  return result
end

describe("ReportService.Attendance", function()
  it("counts present, late and left early as attended, and absent as missed", function()
    local rows, held = Report.Attendance({
      a = event("a", "closed", 1, records({ ["Ann-Realm"] = "present", ["Bob-Realm"] = "absent" })),
      b = event("b", "closed", 2, records({ ["Ann-Realm"] = "late", ["Bob-Realm"] = "leftEarly" })),
      c = event("c", "open", 3, records({ ["Ann-Realm"] = "absent", ["Bob-Realm"] = "present" })),
    })
    assert.are.equal(3, held)
    assert.are.equal(2, #rows)

    local by = {}
    for _, row in ipairs(rows) do by[row.characterKey] = row end
    assert.are.equal(2, by["Ann-Realm"].attended)
    assert.are.equal(3, by["Ann-Realm"].outcomes)
    assert.are.near(2 / 3, by["Ann-Realm"].rate, 0.0001)
    assert.are.equal(2, by["Bob-Realm"].attended)
    assert.are.equal(3, by["Bob-Realm"].outcomes)
  end)

  it("keeps unknown, invited, confirmed and excused out of the rate", function()
    local rows = Report.Attendance({
      a = event("a", "closed", 1, records({ ["Ann-Realm"] = "present" })),
      b = event("b", "closed", 2, records({ ["Ann-Realm"] = "unknown" })),
      c = event("c", "closed", 3, records({ ["Ann-Realm"] = "invited" })),
      d = event("d", "closed", 4, records({ ["Ann-Realm"] = "confirmed" })),
      e = event("e", "closed", 5, records({ ["Ann-Realm"] = "excused" })),
    })
    assert.are.equal(1, rows[1].attended)
    assert.are.equal(1, rows[1].outcomes)
    assert.are.equal(1, rows[1].rate)
    assert.are.equal(4, rows[1].other)
  end)

  it("gives no rate, and sorts last, when nobody has a definite outcome", function()
    local rows = Report.Attendance({
      a = event("a", "closed", 1, records({ ["Zed-Realm"] = "present", ["Mia-Realm"] = "unknown" })),
    })
    assert.are.equal("Zed-Realm", rows[1].characterKey)
    assert.are.equal("Mia-Realm", rows[2].characterKey)
    assert.is_nil(rows[2].rate)
  end)

  it("ignores planned and cancelled events", function()
    local rows, held = Report.Attendance({
      a = event("a", "planned", 1, records({ ["Ann-Realm"] = "present" })),
      b = event("b", "cancelled", 2, records({ ["Ann-Realm"] = "absent" })),
    })
    assert.are.equal(0, held)
    assert.are.same({}, rows)
  end)

  it("sorts by rate, then by name", function()
    local rows = Report.Attendance({
      a = event("a", "closed", 1, records({
        ["Bob-Realm"] = "present", ["Ann-Realm"] = "present", ["Cid-Realm"] = "absent",
      })),
    })
    assert.are.same({ "Ann-Realm", "Bob-Realm", "Cid-Realm" }, {
      rows[1].characterKey, rows[2].characterKey, rows[3].characterKey,
    })
  end)
end)

describe("ReportService.DescribeAttendance", function()
  it("shows the rate with its denominator and every state", function()
    local rows, held = Report.Attendance({
      a = event("a", "closed", 1, records({ ["Ann-Realm"] = "present" })),
      b = event("b", "closed", 2, records({ ["Ann-Realm"] = "late" })),
      c = event("c", "closed", 3, records({ ["Ann-Realm"] = "absent" })),
      d = event("d", "closed", 4, records({ ["Ann-Realm"] = "excused" })),
    })
    local lines = Report.DescribeAttendance(rows, held)
    assert.are.equal("Attendance over 4 event(s) held:", lines[1])
    assert.are.equal("  Ann-Realm: 2/3 (67%) - present 1, late 1, absent 1, excused 1", lines[2])
  end)

  it("says so when nothing was recorded", function()
    assert.is_truthy(Report.DescribeAttendance({}, 0)[1]:find("No events held yet", 1, true))
    assert.is_truthy(Report.DescribeAttendance({}, 2)[1]:find("no attendance recorded", 1, true))
  end)

  it("does not turn a missing outcome into a percentage", function()
    local rows, held = Report.Attendance({ a = event("a", "closed", 1, records({ ["Mia-Realm"] = "unknown" })) })
    local lines = Report.DescribeAttendance(rows, held)
    assert.are.equal("  Mia-Realm: no outcome recorded - unknown 1", lines[2])
  end)
end)

describe("ReportService loot", function()
  local function session(id, itemName, status, award)
    return {
      sessionId = id, itemName = itemName, status = status, candidates = {}, votes = {},
      award = award, updatedAt = tonumber(id:match("%d+")),
    }
  end
  local function awarded(target, by)
    return { characterKey = target, reason = "why", awardedBy = by or "Boss-Realm" }
  end

  local events = {
    a = event("a", "closed", 1, nil, {
      s1 = session("s1", "Alpha", "closed", awarded("Ann-Realm")),
      s2 = session("s2", "Beta", "closed", awarded("Bob-Realm")),
      s3 = session("s3", "Gamma", "closed", awarded("Ann-Realm")),
      s4 = session("s4", "Delta", "closed"),
    }),
    b = event("b", "closed", 2, nil, {
      s5 = session("s5", "Epsilon", "open"),
    }),
  }

  it("counts awards per character, most first, with the items in order", function()
    local rows, totals = Report.Loot(events)
    assert.are.equal("Ann-Realm", rows[1].characterKey)
    assert.are.equal(2, rows[1].awards)
    assert.are.same({ "Alpha", "Gamma" }, rows[1].items)
    assert.are.equal("Bob-Realm", rows[2].characterKey)
    assert.are.equal(1, rows[2].awards)
    assert.are.same({ sessions = 5, awarded = 3, notAwarded = 1, open = 1 }, totals)
  end)

  it("describes the totals and each character", function()
    local rows, totals = Report.Loot(events)
    local lines = Report.DescribeLoot(rows, totals)
    assert.are.equal("Loot: 5 session(s), 3 awarded, 1 closed without an award, 1 still open.", lines[1])
    assert.are.equal("  Ann-Realm: 2 - Alpha, Gamma", lines[2])
    assert.are.equal("  Bob-Realm: 1 - Beta", lines[3])
  end)

  it("says so when there are no sessions", function()
    local rows, totals = Report.Loot({ a = event("a", "closed", 1) })
    assert.are.same({}, rows)
    assert.are.same({ "No loot sessions yet." }, Report.DescribeLoot(rows, totals))
  end)
end)

describe("ReportCommands", function()
  local ReportCommands = ns.ReportCommands
  local function build()
    return ReportCommands.New({
      events = {
        a = event("a", "closed", 1, records({ ["Ann-Realm"] = "present" })),
        b = event("b", "closed", 2, records({ ["Bob-Realm"] = "absent" })),
      },
    })
  end
  local function text(lines) return table.concat(lines, "\n") end

  it("reports attendance over every event, or over a single one by number", function()
    local commands = build()
    local all = text(commands:Report("attendance"))
    assert.is_truthy(all:find("Ann-Realm", 1, true))
    assert.is_truthy(all:find("Bob-Realm", 1, true))

    local first = text(commands:Report("attendance 1"))
    assert.is_truthy(first:find("Ann-Realm", 1, true))
    assert.is_nil(first:find("Bob-Realm", 1, true))
  end)

  it("reports loot", function()
    assert.is_truthy(text(build():Report("loot")):find("No loot sessions yet", 1, true))
  end)

  it("gives the usage for anything else and a clear error for a bad event number", function()
    local commands = build()
    assert.is_truthy(text(commands:Report("")):find("usage:", 1, true))
    assert.is_truthy(text(commands:Report("weather")):find("usage:", 1, true))
    assert.is_truthy(text(commands:Report("attendance 9")):find("give the event number", 1, true))
    assert.is_truthy(text(commands:Report("loot x")):find("give the event number", 1, true))
  end)
end)
