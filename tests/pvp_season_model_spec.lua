-- The pure rules of PvP seasons: period keys, claim ids, validation, officer intervals, the ranking and the digest.
local function load_model()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/PvPSeasonModel" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.PvPSeasonModel, ns.Constants
end

local Model, Constants = load_model()

local function copy(base, change)
  local out = {}
  for key, value in pairs(base) do
    out[key] = value
  end
  for key, value in pairs(change or {}) do
    if value == "__nil" then
      out[key] = nil
    else
      out[key] = value
    end
  end
  return out
end

describe("PvPSeasonModel period keys", function()
  it("uses 'all' for a mission that happens once", function()
    assert.are.equal("all", Model.PeriodKey("once", 1792497600))
  end)

  it("uses the UTC day for a daily mission and flips at midnight UTC", function()
    assert.are.equal("20261020", Model.PeriodKey("daily", 1792497600))
    assert.are.equal("20261020", Model.PeriodKey("daily", 1792454400))
    assert.are.equal("20261019", Model.PeriodKey("daily", 1792450800))
    assert.are.equal("20240229", Model.PeriodKey("daily", 1709247600))
    assert.are.equal("20000101", Model.PeriodKey("daily", 946684800))
  end)

  it("uses the ISO week for a weekly mission, weeks starting on Monday", function()
    assert.are.equal("2026W43", Model.PeriodKey("weekly", 1792497600))
    -- Sunday night and Monday midnight of the same date change of week.
    assert.are.equal("2026W43", Model.PeriodKey("weekly", 1792969200))
    assert.are.equal("2026W44", Model.PeriodKey("weekly", 1792972800))
  end)

  it("belongs the days around the new year to the ISO year of their Thursday", function()
    assert.are.equal("2020W53", Model.PeriodKey("weekly", 1609416000))
    assert.are.equal("2020W53", Model.PeriodKey("weekly", 1609502400))
    assert.are.equal("2021W01", Model.PeriodKey("weekly", 1609718400))
    assert.are.equal("2025W01", Model.PeriodKey("weekly", 1735538400))
    assert.are.equal("2026W53", Model.PeriodKey("weekly", 1798977600))
  end)

  it("gives nothing for an unknown repetition", function()
    assert.is_nil(Model.PeriodKey("monthly", 1792497600))
  end)

  it("recognises the three key shapes", function()
    for _, key in ipairs({ "all", "20261020", "2026W43" }) do
      assert.is_true(Model.IsPeriodKey(key))
    end
    for _, key in ipairs({ "", "2026", "20261320", "2026W54", "2026W00", "ALL", 5 }) do
      assert.is_false(Model.IsPeriodKey(key))
    end
  end)

  it("says whether a time is inside the season, both ends included", function()
    local season = { startsAt = 100, endsAt = 200 }
    assert.is_true(Model.Contains(season, 100))
    assert.is_true(Model.Contains(season, 200))
    assert.is_false(Model.Contains(season, 99))
    assert.is_false(Model.Contains(season, 201))
    assert.is_false(Model.Contains(nil, 150))
  end)
end)

describe("PvPSeasonModel claim ids", function()
  it("builds and parses an id, names with spaces included", function()
    local id = Model.ClaimId("Ann Marie", "m-1", "20261020", 2)
    assert.are.equal("Ann Marie:m-1:20261020:2", id)
    assert.are.same({ player = "Ann Marie", missionId = "m-1", periodKey = "20261020", n = 2 }, Model.ParseClaimId(id))
  end)

  it("refuses what is not a claim id", function()
    for _, id in ipairs({
      "m-1",
      "Ann:m-1:20261020",
      "Ann:m-1:soon:1",
      "Ann:m-1:all:0",
      "Ann:m-1:all:11",
      "Ann:bad id:all:1",
      ":m-1:all:1",
      "Ann:x:y:m-1:all:1",
      string.rep("a", 130) .. ":m-1:all:1",
      5,
    }) do
      assert.is_nil(Model.ParseClaimId(id), tostring(id))
    end
    assert.is_true(Model.IsClaimId("Ann:m-1:all:1"))
    assert.is_false(Model.IsClaimId("direct-1"))
  end)
end)

describe("PvPSeasonModel.ValidateSeason", function()
  local good =
    { id = "s-1", name = "Season One", startsAt = 100, endsAt = 200, state = "active", rev = 1, updatedAt = 5 }

  it("accepts a clean season and drops unknown fields", function()
    local clean = assert(Model.ValidateSeason(copy(good, { extra = 1 })))
    assert.are.same(good, clean)
  end)

  it("refuses bad ids, names, dates, states and revisions", function()
    for _, change in ipairs({
      { id = "bad id" },
      { id = 5 },
      { name = "" },
      { name = " padded " },
      { name = "two  spaces" },
      { name = "|cffff0000Red" },
      { name = string.rep("x", Constants.PVP_SEASON_NAME_MAX + 1) },
      { endsAt = 100 },
      { startsAt = -1 },
      { endsAt = 5000000000 },
      { state = "paused" },
      { rev = 0 },
      { updatedAt = 1.5 },
    }) do
      local clean, reason = Model.ValidateSeason(copy(good, change))
      assert.is_nil(clean)
      assert.is_truthy(reason:find("^invalid:"))
    end
    assert.is_nil(Model.ValidateSeason("season"))
  end)
end)

describe("PvPSeasonModel.ValidateMission", function()
  local good = {
    id = "m-1",
    seasonId = "s-1",
    title = "Hillsbrad hunt",
    desc = "Ten kills",
    points = 50,
    goal = { kind = "kills", count = 10, zones = { 1424 }, place = "world", distinct = "name" },
    repeatKind = "daily",
    perPlayer = 2,
    active = true,
    rev = 1,
    updatedAt = 5,
  }

  it("accepts a clean mission", function()
    assert.are.same(good, assert(Model.ValidateMission(good)))
  end)

  it("fills the defaults an older form leaves out", function()
    local fields = copy(good, { desc = "__nil", perPlayer = "__nil", active = "__nil" })
    fields.goal = { kind = "manual" }
    local clean = assert(Model.ValidateMission(fields))
    assert.are.equal("", clean.desc)
    assert.are.equal(1, clean.perPlayer)
    assert.is_true(clean.active)
    assert.are.same({ kind = "manual", count = 1, zones = {}, place = "any", distinct = "none" }, clean.goal)
  end)

  it("refuses each field out of bounds", function()
    local function goal(change)
      return copy(good, { goal = copy(good.goal, change) })
    end
    for _, fields in ipairs({
      copy(good, { id = "a b" }),
      copy(good, { seasonId = "" }),
      copy(good, { title = "" }),
      copy(good, { title = string.rep("x", Constants.PVP_MISSION_TITLE_MAX + 1) }),
      copy(good, { desc = string.rep("x", Constants.PVP_MISSION_DESC_MAX + 1) }),
      copy(good, { desc = "bad|text" }),
      copy(good, { points = 0 }),
      copy(good, { points = Constants.PVP_MISSION_POINTS_MAX + 1 }),
      copy(good, { repeatKind = "monthly" }),
      copy(good, { perPlayer = 0 }),
      copy(good, { perPlayer = Constants.PVP_MISSION_PER_PLAYER_MAX + 1 }),
      copy(good, { active = "yes" }),
      copy(good, { goal = "kills" }),
      copy(good, { rev = 0 }),
      goal({ kind = "dances" }),
      goal({ count = 0 }),
      goal({ count = Constants.PVP_MISSION_COUNT_MAX + 1 }),
      goal({ place = "moon" }),
      goal({ distinct = "gender" }),
      goal({ zones = { 1, 2, 3, 4, 5, 6 } }),
      goal({ zones = { 1, 1 } }),
      goal({ zones = { 0 } }),
      goal({ zones = { "x" } }),
      goal({ zones = 5 }),
    }) do
      local clean, reason = Model.ValidateMission(fields)
      assert.is_nil(clean)
      assert.is_truthy(reason:find("^invalid:"))
    end
  end)
end)

describe("PvPSeasonModel.ValidateClaim", function()
  local id = "Ann:m-1:20261020:1"
  local good = {
    id = id,
    missionId = "m-1",
    seasonId = "s-1",
    periodKey = "20261020",
    player = "Ann",
    at = 50,
    summary = { done = 2, total = 2 },
    evidence = {
      { at = 10, victim = "Grunt", mapId = 1424, place = "world", class = "WARRIOR", race = "ORC" },
      { at = 11, bgWin = true, mapId = 1459 },
    },
    note = "by hand",
  }

  it("accepts a clean claim", function()
    assert.are.same(good, assert(Model.ValidateClaim(good)))
  end)

  it("accepts a claim with no evidence, summary or note", function()
    local clean = assert(Model.ValidateClaim(copy(good, { evidence = "__nil", summary = "__nil", note = "__nil" })))
    assert.are.same({}, clean.evidence)
    assert.are.same({}, clean.summary)
    assert.is_nil(clean.note)
  end)

  it("needs the id to agree with the player, mission and period", function()
    for _, change in ipairs({
      { player = "Bob" },
      { missionId = "m-2" },
      { periodKey = "all" },
      { id = "plain-id" },
      { seasonId = "bad id" },
    }) do
      assert.is_nil(Model.ValidateClaim(copy(good, change)))
    end
  end)

  it("refuses bad time, summary, note and evidence", function()
    local function row(change)
      return copy(good, { evidence = { copy(good.evidence[1], change) } })
    end
    for _, fields in ipairs({
      copy(good, { at = -1 }),
      copy(good, { summary = { done = -1 } }),
      copy(good, { summary = "x" }),
      copy(good, { note = string.rep("x", Constants.PVP_NOTE_MAX + 1) }),
      copy(good, { evidence = "x" }),
      copy(good, { evidence = { "x" } }),
      row({ victim = "" }),
      row({ victim = "a|b" }),
      row({ victim = string.rep("x", Constants.PVP_FEED_VICTIM_MAX + 1) }),
      row({ place = "sky" }),
      row({ place = "__nil" }),
      row({ class = "warrior" }),
      row({ race = "Night Elf" }),
      row({ mapId = -1 }),
      row({ at = "x" }),
      copy(good, { evidence = { { at = 1, bgWin = false } } }),
      copy(good, { evidence = { { at = 1, bgWin = true, victim = "Grunt" } } }),
    }) do
      assert.is_nil(Model.ValidateClaim(fields))
    end
  end)

  it("refuses more evidence rows than a claim may carry", function()
    local rows = {}
    for index = 1, Constants.PVP_CLAIM_EVIDENCE_MAX + 1 do
      rows[index] = { at = index, victim = "V" .. index, place = "world" }
    end
    assert.is_nil(Model.ValidateClaim(copy(good, { evidence = rows })))
    rows[#rows] = nil
    assert.is_truthy(Model.ValidateClaim(copy(good, { evidence = rows })))
  end)
end)

describe("PvPSeasonModel.ValidateGrant, ValidateVoid and ValidateReject", function()
  local grant = { id = "Ann:m-1:all:1", seasonId = "s-1", player = "Ann", missionId = "m-1", points = 10, at = 5 }

  it("accepts the approval of a claim and a direct grant", function()
    assert.are.same(grant, assert(Model.ValidateGrant(copy(grant, { extra = true }))))
    local direct = copy(grant, { id = "g-1" })
    assert.are.same(direct, assert(Model.ValidateGrant(direct)))
  end)

  it("needs a claim id to name the player and the mission of the grant", function()
    assert.is_nil(Model.ValidateGrant(copy(grant, { player = "Bob" })))
    assert.is_nil(Model.ValidateGrant(copy(grant, { missionId = "m-2" })))
  end)

  it("refuses bad ids, points and times", function()
    for _, change in ipairs({
      { id = "bad id" },
      { seasonId = "" },
      { player = "A:b" },
      { points = 0 },
      { points = Constants.PVP_MISSION_POINTS_MAX + 1 },
      { at = -2 },
    }) do
      assert.is_nil(Model.ValidateGrant(copy(grant, change)))
    end
  end)

  it("validates a void and a reject", function()
    local void = { grantId = "Ann:m-1:all:1", seasonId = "s-1", reason = "abuse", at = 9 }
    assert.are.same(void, assert(Model.ValidateVoid(void)))
    assert.is_nil(assert(Model.ValidateVoid(copy(void, { reason = "__nil" }))).reason)
    assert.is_nil(Model.ValidateVoid(copy(void, { reason = string.rep("x", 101) })))
    assert.is_nil(Model.ValidateVoid(copy(void, { grantId = "bad id" })))

    local reject = { claimId = "Ann:m-1:all:1", seasonId = "s-1", reason = "no proof", at = 9 }
    assert.are.same(reject, assert(Model.ValidateReject(reject)))
    -- A reject names a claim, so a plain id is not enough.
    assert.is_nil(Model.ValidateReject(copy(reject, { claimId = "g-1" })))
    assert.is_nil(Model.ValidateReject(copy(reject, { at = "x" })))
  end)
end)

describe("PvPSeasonModel prizes", function()
  local good = {
    seasonId = "s-1",
    tiers = {
      ["1"] = { { kind = "gold", amount = 500 }, { kind = "item", itemId = 19019, name = "Thunderfury", count = 1 } },
      ["4-6"] = { { kind = "gold", amount = 50 } },
      ["7-10"] = {},
    },
    rev = 2,
    updatedAt = 5,
  }

  it("accepts gold and items per tier and drops unknown tiers", function()
    local fields = copy(good, { tiers = copy(good.tiers, { ["11-20"] = { { kind = "gold", amount = 1 } } }) })
    assert.are.same(good, assert(Model.ValidatePrizes(fields)))
  end)

  it("refuses rewards out of bounds", function()
    local function with(rewards)
      return copy(good, { tiers = { ["1"] = rewards } })
    end
    local entries = {}
    for index = 1, Constants.PVP_PRIZE_ENTRIES_MAX + 1 do
      entries[index] = { kind = "gold", amount = 1 }
    end
    for _, fields in ipairs({
      with(entries),
      with({ { kind = "gold", amount = 0 } }),
      with({ { kind = "gold", amount = Constants.PVP_PRIZE_GOLD_MAX + 1 } }),
      with({ { kind = "item", itemId = 0, name = "x", count = 1 } }),
      with({ { kind = "item", itemId = 5, name = "", count = 1 } }),
      with({ { kind = "item", itemId = 5, name = "x", count = 201 } }),
      with({ { kind = "silver", amount = 1 } }),
      with({ "gold" }),
      with("gold"),
      copy(good, { tiers = "x" }),
      copy(good, { seasonId = "a b" }),
      copy(good, { rev = 0 }),
    }) do
      assert.is_nil(Model.ValidatePrizes(fields))
    end
  end)
end)

describe("PvPSeasonModel officers", function()
  local good = {
    player = "Ann",
    intervals = { { from = 10, to = 20 }, { from = 30 } },
    rev = 1,
    updatedAt = 5,
  }

  it("accepts closed intervals followed by at most one open one", function()
    assert.are.same(good, assert(Model.ValidateOfficer(good)))
    assert.are.same({}, assert(Model.ValidateOfficer(copy(good, { intervals = {} }))).intervals)
  end)

  it("refuses overlapping, reversed, misplaced and too many intervals", function()
    local many = {}
    for index = 1, Constants.PVP_OFFICER_INTERVALS_MAX + 1 do
      many[index] = { from = index * 10, to = index * 10 + 1 }
    end
    for _, intervals in ipairs({
      { { from = 10 }, { from = 30 } },
      { { from = 10, to = 20 }, { from = 15, to = 25 } },
      { { from = 10, to = 5 } },
      { { from = "x" } },
      { "x" },
      many,
    }) do
      assert.is_nil(Model.ValidateOfficer(copy(good, { intervals = intervals })))
    end
    assert.is_nil(Model.ValidateOfficer(copy(good, { player = "a:b" })))
    assert.is_nil(Model.ValidateOfficer(copy(good, { intervals = "x" })))
  end)

  it("knows whether somebody was an officer at a time, ends included", function()
    local officer = assert(Model.ValidateOfficer(good))
    assert.is_false(Model.IsOfficerAt(officer, 9))
    assert.is_true(Model.IsOfficerAt(officer, 10))
    assert.is_true(Model.IsOfficerAt(officer, 20))
    assert.is_false(Model.IsOfficerAt(officer, 21))
    assert.is_true(Model.IsOfficerAt(officer, 30))
    assert.is_true(Model.IsOfficerAt(officer, 9999))
    assert.is_false(Model.IsOfficerAt(nil, 10))
    assert.is_false(Model.IsOfficerAt(officer, "x"))
  end)

  it("tells an open interval from a closed one", function()
    assert.is_true(Model.IsOfficer({ intervals = { { from = 1, to = 2 }, { from = 5 } } }))
    assert.is_false(Model.IsOfficer({ intervals = { { from = 1, to = 2 } } }))
    assert.is_false(Model.IsOfficer({ intervals = {} }))
    assert.is_false(Model.IsOfficer(nil))
  end)

  it("opens and closes intervals and says when nothing changes", function()
    local opened = assert(Model.ToggleIntervals({}, true, 100))
    assert.are.same({ { from = 100 } }, opened)
    assert.are.equal("unchanged", select(2, Model.ToggleIntervals(opened, true, 101)))
    local closed = assert(Model.ToggleIntervals(opened, false, 150))
    assert.are.same({ { from = 100, to = 150 } }, closed)
    assert.are.equal("unchanged", select(2, Model.ToggleIntervals(closed, false, 160)))
    assert.are.same({ { from = 100, to = 150 }, { from = 200 } }, assert(Model.ToggleIntervals(closed, true, 200)))
  end)

  it("drops intervals that ended before the season to make room, and says 'limit' otherwise", function()
    local full = {}
    for index = 1, Constants.PVP_OFFICER_INTERVALS_MAX do
      full[index] = { from = index * 10, to = index * 10 + 5 }
    end
    assert.are.equal("limit", select(2, Model.ToggleIntervals(full, true, 500)))
    -- Everything that ended before 62 is gone; the intervals that end later stay.
    local result = assert(Model.ToggleIntervals(full, true, 500, 62))
    assert.are.equal(6, #result)
    assert.are.same({ from = 500 }, result[#result])
    assert.are.same({ from = 60, to = 65 }, result[1])
  end)
end)

describe("PvPSeasonModel tiers", function()
  it("maps the positions to the five tiers", function()
    local expected = { "1", "2", "3", "4-6", "4-6", "4-6", "7-10", "7-10", "7-10", "7-10" }
    for position, tier in ipairs(expected) do
      assert.are.equal(tier, Model.TierOf(position))
    end
    assert.is_nil(Model.TierOf(0))
    assert.is_nil(Model.TierOf(11))
    assert.is_nil(Model.TierOf(2.5))
    assert.is_nil(Model.TierOf("x"))
  end)

  it("gives the positions a tier covers", function()
    assert.are.same({ 1, 1 }, { Model.TierRange("1") })
    assert.are.same({ 3, 3 }, { Model.TierRange("3") })
    assert.are.same({ 4, 6 }, { Model.TierRange("4-6") })
    assert.are.same({ 7, 10 }, { Model.TierRange("7-10") })
    assert.is_nil(Model.TierRange("4"))
    assert.is_true(Model.IsTier("4-6"))
    assert.is_false(Model.IsTier("11-20"))
  end)
end)

describe("PvPSeasonModel.Standings", function()
  local roles = { Boss = "admin", Ann = "member", Bob = "member", Cat = "member", Off = "member" }
  local function roleOf(name)
    return roles[name]
  end
  local officers = { Off = { player = "Off", intervals = { { from = 100, to = 200 } } } }

  local function grant(id, player, points, at, by, seasonId)
    return { id = id, seasonId = seasonId or "s-1", player = player, points = points, at = at, by = by or "Boss" }
  end

  it("sums the points per player and ranks them", function()
    local grants = { grant("g1", "Ann", 10, 1), grant("g2", "Bob", 30, 2), grant("g3", "Ann", 25, 3) }
    local rows = Model.Standings(grants, {}, officers, roleOf)
    assert.are.equal(2, #rows)
    assert.are.same({ pos = 1, player = "Ann", points = 35, lastAt = 3, tier = "1" }, rows[1])
    assert.are.same({ pos = 2, player = "Bob", points = 30, lastAt = 2, tier = "2" }, rows[2])
  end)

  it("reads grants stored in a map as well as in a list", function()
    local map = { g1 = grant("g1", "Ann", 10, 1) }
    assert.are.equal(1, #Model.Standings(map, {}, officers, roleOf))
  end)

  it("breaks a tie by whoever reached the total first, then by name", function()
    local grants = {
      grant("g1", "Bob", 10, 5),
      grant("g2", "Ann", 10, 9),
      grant("g3", "Cat", 10, 5),
    }
    local rows = Model.Standings(grants, {}, officers, roleOf)
    assert.are.same({ "Bob", "Cat", "Ann" }, { rows[1].player, rows[2].player, rows[3].player })
  end)

  it("uses the time of the last counted grant, so a void that removes the late one lets the player move up", function()
    local grants = { grant("g1", "Ann", 10, 1), grant("g2", "Ann", 5, 50), grant("g3", "Bob", 10, 10) }
    assert.are.equal("Bob", Model.Standings(grants, {}, officers, roleOf)[2].player)
    local voids = { g2 = { grantId = "g2", by = "Boss", at = 60 } }
    local rows = Model.Standings(grants, voids, officers, roleOf)
    assert.are.same({ "Ann", "Bob" }, { rows[1].player, rows[2].player })
    assert.are.equal(10, rows[1].points)
  end)

  it("ignores a void that an admin did not write", function()
    local grants = { grant("g1", "Ann", 10, 1) }
    local voids = { g1 = { grantId = "g1", by = "Bob", at = 60 } }
    assert.are.equal(1, #Model.Standings(grants, voids, officers, roleOf))
    assert.are.equal(0, #Model.Standings(grants, { g1 = { grantId = "g1", by = "Boss", at = 60 } }, officers, roleOf))
  end)

  it("counts a claim approved by an officer only while their flag was on", function()
    local grants = {
      grant("Ann:m-1:all:1", "Ann", 10, 150, "Off"),
      grant("Bob:m-1:all:1", "Bob", 10, 250, "Off"),
      grant("Cat:m-1:all:1", "Cat", 10, 50, "Off"),
    }
    local rows = Model.Standings(grants, {}, officers, roleOf)
    assert.are.equal(1, #rows)
    assert.are.equal("Ann", rows[1].player)
  end)

  it("does not count a direct grant, or a grant for themselves, from an officer", function()
    local grants = {
      grant("direct-1", "Ann", 10, 150, "Off"),
      grant("Off:m-1:all:1", "Off", 10, 150, "Off"),
    }
    assert.are.equal(0, #Model.Standings(grants, {}, officers, roleOf))
    -- An admin may do both.
    grants = { grant("direct-1", "Ann", 10, 150, "Boss"), grant("Boss:m-1:all:1", "Boss", 10, 150, "Boss") }
    assert.are.equal(2, #Model.Standings(grants, {}, officers, roleOf))
  end)

  it("ignores grants from members, from nobody and with no role lookup", function()
    local grants =
      { grant("g1", "Ann", 10, 1, "Bob"), grant("g2", "Ann", 10, 1, "Ghost"), { id = "g3", player = "Ann" } }
    assert.are.equal(0, #Model.Standings(grants, {}, officers, roleOf))
    assert.are.equal(0, #Model.Standings({ grant("g1", "Ann", 10, 1) }, {}, officers, nil))
  end)

  it("can be limited to one season", function()
    local grants = { grant("g1", "Ann", 10, 1, "Boss", "s-1"), grant("g2", "Bob", 10, 1, "Boss", "s-2") }
    local rows = Model.Standings(grants, {}, officers, roleOf, "s-2")
    assert.are.equal(1, #rows)
    assert.are.equal("Bob", rows[1].player)
    assert.are.equal(2, #Model.Standings(grants, {}, officers, roleOf))
  end)

  it("gives no tier past position ten and ranks nobody without points", function()
    local grants = {}
    for index = 1, 12 do
      grants[index] = grant("g" .. index, "P" .. string.format("%02d", index), 100 - index, index)
    end
    roles.P01 = "member"
    local rows = Model.Standings(grants, {}, officers, roleOf)
    assert.are.equal(12, #rows)
    assert.are.equal("7-10", rows[10].tier)
    assert.is_nil(rows[11].tier)
    assert.is_nil(rows[12].tier)
    assert.are.equal(0, #Model.Standings({}, {}, officers, roleOf))
    assert.are.equal(0, #Model.Standings(nil, nil, nil, roleOf))
  end)
end)

describe("PvPSeasonModel.Cumulative", function()
  local function final(id, ...)
    local standings = {}
    for position, row in ipairs({ ... }) do
      standings[position] = { pos = position, player = row[1], points = row[2], lastAt = 1 }
    end
    return { seasonId = id, standings = standings }
  end

  it("adds points, seasons played and podiums over every final", function()
    local finals = {
      s1 = final("s1", { "Ann", 100 }, { "Bob", 80 }, { "Cat", 60 }, { "Dan", 10 }),
      s2 = final("s2", { "Bob", 120 }, { "Ann", 50 }),
    }
    local rows = Model.Cumulative(finals)
    assert.are.same({ pos = 1, player = "Bob", points = 200, seasons = 2, podiums = 2 }, rows[1])
    assert.are.same({ pos = 2, player = "Ann", points = 150, seasons = 2, podiums = 2 }, rows[2])
    assert.are.same({ pos = 3, player = "Cat", points = 60, seasons = 1, podiums = 1 }, rows[3])
    assert.are.same({ pos = 4, player = "Dan", points = 10, seasons = 1, podiums = 0 }, rows[4])
  end)

  it("breaks ties by podiums and then by name, and handles no finals", function()
    local rows = Model.Cumulative({
      s1 = final("s1", { "Zed", 50 }, { "Amy", 50 }, { "Bea", 50 }, { "Cid", 50 }),
    })
    assert.are.equal(4, #rows)
    -- Equal points: the podium holders first, in name order, then the rest.
    assert.are.same({ "Amy", "Bea", "Zed", "Cid" }, { rows[1].player, rows[2].player, rows[3].player, rows[4].player })
    assert.are.equal(0, #Model.Cumulative({}))
    assert.are.equal(0, #Model.Cumulative(nil))
  end)
end)

describe("PvPSeasonModel.Digest", function()
  it("is the same for the same tokens in any order", function()
    local a = Model.Digest({ "g:1", "g:2", "v:3" })
    assert.are.equal(a, Model.Digest({ "v:3", "g:1", "g:2" }))
    assert.are.equal(8, #a)
    assert.is_truthy(a:find("^%x+$"))
  end)

  it("changes when a token is added, removed or different", function()
    local base = Model.Digest({ "g:1", "g:2" })
    assert.are_not.equal(base, Model.Digest({ "g:1" }))
    assert.are_not.equal(base, Model.Digest({ "g:1", "g:2", "g:3" }))
    assert.are_not.equal(base, Model.Digest({ "g:1", "g:3" }))
    assert.are_not.equal(Model.Digest({}), base)
  end)

  it("does not change the list it is given", function()
    local tokens = { "b", "a" }
    Model.Digest(tokens)
    assert.are.same({ "b", "a" }, tokens)
  end)
end)

describe("PvPSeasonModel.ValidateFinal and ValidateDelivery", function()
  local final = {
    seasonId = "s-1",
    name = "Season One",
    startsAt = 100,
    endsAt = 200,
    closedAt = 210,
    standings = {
      { pos = 1, player = "Ann", points = 50, lastAt = 9 },
      { pos = 2, player = "Bob", points = 40, lastAt = 8 },
    },
    prizes = { ["1"] = { { kind = "gold", amount = 10 } } },
  }

  it("accepts a clean final", function()
    assert.are.same(final, assert(Model.ValidateFinal(final)))
  end)

  it("refuses a final whose standings are out of order, repeated or too long", function()
    local long = {}
    for index = 1, Constants.PVP_FINAL_STANDINGS_MAX + 1 do
      long[index] = { pos = index, player = "P" .. index, points = 1, lastAt = 1 }
    end
    for _, change in ipairs({
      { standings = { { pos = 2, player = "Ann", points = 5, lastAt = 1 } } },
      { standings = { { pos = 1, player = "Ann", points = 0, lastAt = 1 } } },
      {
        standings = {
          { pos = 1, player = "Ann", points = 5, lastAt = 1 },
          { pos = 2, player = "Ann", points = 4, lastAt = 1 },
        },
      },
      { standings = long },
      { standings = "x" },
      { name = "" },
      { endsAt = 50 },
      { closedAt = "x" },
      { prizes = "x" },
      { seasonId = "a b" },
    }) do
      assert.is_nil(Model.ValidateFinal(copy(final, change)))
    end
  end)

  it("validates a delivery", function()
    local delivery = { seasonId = "s-1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = 5 }
    assert.are.same(delivery, assert(Model.ValidateDelivery(delivery)))
    for _, change in ipairs({
      { tier = "9" },
      { delivered = "yes" },
      { player = "a:b" },
      { rev = 0 },
      { seasonId = "" },
    }) do
      assert.is_nil(Model.ValidateDelivery(copy(delivery, change)))
    end
  end)
end)
