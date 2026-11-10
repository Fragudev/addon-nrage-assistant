local function load_tracker()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PvPSeasonModel",
    "Domain/PvPMissionTracker",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_tracker()
local Tracker, Constants = ns.PvPMissionTracker, ns.Constants

local HOUR, DAY = 3600, 86400
local T0 = 1792454400 -- 2026-10-20 00:00 UTC, a Tuesday
local NOW = T0 + 12 * HOUR
local SEASON = { id = "s1", state = "active", startsAt = T0 - 10 * DAY, endsAt = T0 + 20 * DAY }

local function mission(goal, extra)
  local m = {
    id = "m1",
    seasonId = "s1",
    title = "Hunt",
    points = 10,
    goal = { kind = "kills", count = 3, zones = {}, place = "any", distinct = "none" },
    repeatKind = "daily",
    perPlayer = 1,
    active = true,
  }
  for key, value in pairs(goal or {}) do
    m.goal[key] = value
  end
  for key, value in pairs(extra or {}) do
    m[key] = value
  end
  return m
end

local function kill(at, victim, extra)
  local row = { at = at, victim = victim, place = "world", mapId = 1411 }
  for key, value in pairs(extra or {}) do
    row[key] = value
  end
  return row
end

local function progress(m, log, claims, season)
  return Tracker.Progress(m, log, NOW, claims or {}, season == nil and SEASON or season)
end

describe("PvPMissionTracker count", function()
  it("counts the kills of the period and clamps the bar", function()
    local log = { kill(NOW - 3, "A"), kill(NOW - 2, "B"), kill(NOW - 1, "C"), kill(NOW, "D") }
    local result = progress(mission(), log)
    assert.are.same({ { label = "Kills", done = 3, total = 3 } }, result.bars)
    assert.is_true(result.complete)
    assert.is_true(result.claimable)
    assert.are.equal("20261020", result.periodKey)
    assert.are.equal(4, #result.evidence)
    assert.are.equal("A", result.evidence[1].victim)
  end)

  it("is not complete below the count and then not claimable", function()
    local result = progress(mission(), { kill(NOW - 2, "A"), kill(NOW - 1, "B") })
    assert.are.same({ { label = "Kills", done = 2, total = 3 } }, result.bars)
    assert.is_false(result.complete)
    assert.is_false(result.claimable)
  end)

  it("keeps a daily mission to today, a weekly one to this week and a once mission to the season", function()
    local log = { kill(NOW - DAY, "A"), kill(NOW - 3 * DAY, "B"), kill(NOW - 8 * DAY, "C"), kill(NOW, "D") }
    assert.are.equal(1, progress(mission({ count = 5 }), log).bars[1].done)
    -- Tuesday: the week started on Monday, one day back
    assert.are.equal(2, progress(mission({ count = 5 }, { repeatKind = "weekly" }), log).bars[1].done)
    local once = progress(mission({ count = 5 }, { repeatKind = "once" }), log)
    assert.are.equal(4, once.bars[1].done)
    assert.are.equal("all", once.periodKey)
  end)

  it("ignores kills outside the season dates", function()
    local season = { id = "s1", state = "active", startsAt = NOW - HOUR, endsAt = T0 + 20 * DAY }
    local log = { kill(NOW - 2 * HOUR, "A"), kill(NOW - 10, "B") }
    assert.are.equal(1, progress(mission({ count = 5 }), log, nil, season).bars[1].done)
    assert.are.equal(2, progress(mission({ count = 5 }), log, nil, false).bars[1].done)
  end)

  it("filters by place", function()
    local log = { kill(NOW - 3, "A"), kill(NOW - 2, "B", { place = "bg" }), kill(NOW - 1, "C", { place = "bg" }) }
    assert.are.equal(1, progress(mission({ count = 5, place = "world" }), log).bars[1].done)
    assert.are.equal(2, progress(mission({ count = 5, place = "bg" }), log).bars[1].done)
    assert.are.equal(3, progress(mission({ count = 5, place = "any" }), log).bars[1].done)
  end)

  it("filters by zone, and a kill without a map id never matches one", function()
    local log = {
      kill(NOW - 4, "A", { mapId = 1411 }),
      kill(NOW - 3, "B", { mapId = 1453 }),
      kill(NOW - 2, "C"),
      kill(NOW - 1, "D"),
    }
    log[3].mapId = nil
    log[4].mapId = nil
    assert.are.equal(1, progress(mission({ count = 5, zones = { 1411 } }), log).bars[1].done)
    assert.are.equal(2, progress(mission({ count = 5, zones = { 1411, 1453 } }), log).bars[1].done)
    assert.are.equal(4, progress(mission({ count = 5, zones = {} }), log).bars[1].done)
  end)

  it("does not claim when the mission is paused, the season ended or the period has no free claim", function()
    local log = { kill(NOW - 3, "A"), kill(NOW - 2, "B"), kill(NOW - 1, "C") }
    assert.is_false(progress(mission({}, { active = false }), log).claimable)
    local ended = { id = "s1", state = "active", startsAt = T0 - DAY, endsAt = NOW - 1 }
    assert.is_false(progress(mission(), log, nil, ended).claimable)
    local closed = { id = "s1", state = "closed", startsAt = T0 - DAY, endsAt = T0 + DAY }
    assert.is_false(progress(mission(), log, nil, closed).claimable)
    local claims =
      { ["Me:m1:20261020:1"] = { claim = { missionId = "m1", periodKey = "20261020" }, state = "pending" } }
    local used = progress(mission(), log, claims)
    assert.are.equal(2, used.nextN)
    assert.is_false(used.claimable)
    assert.is_true(progress(mission({}, { perPlayer = 2 }), log, claims).claimable)
    -- a claim of another period or mission does not count
    local other = {
      a = { claim = { missionId = "m1", periodKey = "20261019" } },
      b = { claim = { missionId = "m2", periodKey = "20261020" } },
    }
    assert.are.equal(1, progress(mission(), log, other).nextN)
  end)

  it("limits the evidence to PVP_CLAIM_EVIDENCE_MAX rows and keeps the first ones", function()
    local log = {}
    for index = 1, Constants.PVP_CLAIM_EVIDENCE_MAX + 20 do
      log[index] = kill(T0 + index, "V" .. index)
    end
    local result = progress(mission({ count = 500 }, { repeatKind = "once" }), log)
    assert.are.equal(Constants.PVP_CLAIM_EVIDENCE_MAX, #result.evidence)
    assert.are.equal("V1", result.evidence[1].victim)
    assert.are.equal(Constants.PVP_CLAIM_EVIDENCE_MAX + 20, result.bars[1].done)
  end)
end)

describe("PvPMissionTracker bounties", function()
  it("counts only the kills flagged as guild KOS, with or without a target", function()
    local log = {
      kill(NOW - 4, "Zed", { kos = true }),
      kill(NOW - 3, "Amy", { kos = true }),
      kill(NOW - 2, "Bob"),
      kill(NOW - 1, "Cal", { kos = true }),
    }
    local any = progress(mission({ kind = "kos", count = 3 }), log)
    assert.are.same({ { label = "Kills", done = 3, total = 3 } }, any.bars)
    assert.is_true(any.complete)
    assert.is_true(any.evidence[1].kos)
    local named = progress(mission({ kind = "kos", count = 1, target = "zed" }), log)
    assert.is_true(named.complete)
    assert.are.equal(1, #named.evidence)
    assert.are.equal("Zed", named.evidence[1].victim)
  end)

  it("does not count a target kill that was not on the KOS at that moment", function()
    local result = progress(mission({ kind = "kos", count = 1, target = "Bob" }), { kill(NOW - 1, "Bob") })
    assert.is_false(result.complete)
    assert.is_false(result.claimable)
  end)

  it("applies place and zones as for kills, and plain kills ignore the flag", function()
    local log = { kill(NOW - 1, "Zed", { kos = true, place = "bg", mapId = 1 }) }
    assert.is_false(progress(mission({ kind = "kos", count = 1, place = "world" }), log).complete)
    assert.is_false(progress(mission({ kind = "kos", count = 1, zones = { 1411 } }), log).complete)
    assert.is_true(progress(mission({ kind = "kills", count = 1 }), log).complete)
  end)
end)

describe("PvPMissionTracker victim cap", function()
  it("counts one victim at most three times per server day, in time order", function()
    local log = {}
    for index = 1, 5 do
      log[index] = kill(NOW - 10 + index, index % 2 == 0 and "ZED" or "Zed")
    end
    assert.are.equal(Constants.PVP_VICTIM_DAILY_CAP, progress(mission({ count = 10 }), log).bars[1].done)
    assert.are.equal(3, #Tracker.CapVictims(log))
  end)

  it("starts again the next day", function()
    local log = {}
    for index = 1, 4 do
      log[#log + 1] = kill(T0 - 2 * HOUR + index, "Zed")
      log[#log + 1] = kill(T0 + 2 * HOUR + index, "Zed")
    end
    assert.are.equal(6, #Tracker.CapVictims(log))
    assert.are.equal(6, progress(mission({ count = 10 }, { repeatKind = "once" }), log).bars[1].done)
  end)

  it("applies before the mission filters, so a capped kill is gone for every mission", function()
    local log = {
      kill(NOW - 5, "Zed", { mapId = 1453 }),
      kill(NOW - 4, "Zed", { mapId = 1453 }),
      kill(NOW - 3, "Zed", { mapId = 1453 }),
      kill(NOW - 2, "Zed", { mapId = 1411 }),
    }
    assert.are.equal(0, progress(mission({ count = 5, zones = { 1411 } }), log).bars[1].done)
    assert.are.equal(3, progress(mission({ count = 5, zones = { 1453 } }), log).bars[1].done)
  end)

  it("never drops battleground wins and does not change the log it is given", function()
    local log = { kill(NOW - 2, "Zed"), { at = NOW - 1, bgWin = true }, kill(NOW - 3, "Zed") }
    local capped = Tracker.CapVictims(log, 1)
    assert.are.equal(2, #capped)
    assert.are.equal(3, #log)
    assert.is_true(capped[2].bgWin)
  end)
end)

describe("PvPMissionTracker distinct names", function()
  it("counts each player once, without case", function()
    local log = { kill(NOW - 5, "Zed"), kill(NOW - 4, "ZED"), kill(NOW - 3, "Yan"), kill(NOW - 2, "zed") }
    local result = progress(mission({ distinct = "name", count = 2 }), log)
    assert.are.same({ { label = "Distinct players", done = 2, total = 2 } }, result.bars)
    assert.is_true(result.complete)
    assert.are.equal(2, #result.evidence)
    assert.are.equal("Zed", result.evidence[1].victim)
    assert.are.equal("Yan", result.evidence[2].victim)
  end)

  it("is not complete with fewer distinct players than the count", function()
    local log = { kill(NOW - 3, "Zed"), kill(NOW - 2, "Zed") }
    local result = progress(mission({ distinct = "name", count = 2 }), log)
    assert.are.equal(1, result.bars[1].done)
    assert.is_false(result.claimable)
  end)
end)

describe("PvPMissionTracker class and race", function()
  local function seen(classes, races)
    local log = {}
    for index = 1, math.max(#classes, #races) do
      log[index] = kill(NOW - 100 + index, "P" .. index, { class = classes[index] or nil, race = races[index] or nil })
    end
    return log
  end

  it("fills the class bar with the distinct classes and ignores repeats and unknown tokens", function()
    local log = seen({ "MAGE", "MAGE", "ROGUE", "PALADIN" }, {})
    local result = progress(mission({ distinct = "class" }), log)
    assert.are.same({ { label = "Classes", done = 2, total = #Constants.PVP_ENEMY_CLASSES } }, result.bars)
    assert.is_false(result.complete)
    assert.are.equal(0, result.unknown)
  end)

  it("completes with every enemy class", function()
    local result =
      progress(mission({ distinct = "class" }, { repeatKind = "once" }), seen(Constants.PVP_ENEMY_CLASSES, {}))
    assert.is_true(result.complete)
    assert.is_true(result.claimable)
    assert.are.equal(#Constants.PVP_ENEMY_CLASSES, #result.evidence)
  end)

  it("counts the kills without a class as unknown, lists them, and allows a claim the approver decides", function()
    local classes = { unpack(Constants.PVP_ENEMY_CLASSES, 1, #Constants.PVP_ENEMY_CLASSES - 1) }
    local log = seen(classes, {})
    assert.is_false(progress(mission({ distinct = "class" }, { repeatKind = "once" }), log).claimable)
    log[#log + 1] = kill(NOW - 1, "Mystery")
    local result = progress(mission({ distinct = "class" }, { repeatKind = "once" }), log)
    assert.is_false(result.complete)
    assert.are.equal(1, result.unknown)
    assert.is_true(result.couldComplete)
    assert.is_true(result.claimable)
    assert.are.equal("Mystery", result.evidence[#result.evidence].victim)
    assert.is_nil(result.evidence[#result.evidence].class)
  end)

  it("counts one unknown victim once for the could-complete test", function()
    local classes = { unpack(Constants.PVP_ENEMY_CLASSES, 1, #Constants.PVP_ENEMY_CLASSES - 2) }
    local log = seen(classes, {})
    log[#log + 1] = kill(NOW - 3, "Mystery")
    log[#log + 1] = kill(NOW - 2, "Mystery")
    local result = progress(mission({ distinct = "class" }, { repeatKind = "once" }), log)
    assert.are.equal(2, result.unknown)
    assert.is_false(result.couldComplete)
    log[#log + 1] = kill(NOW - 1, "Other")
    assert.is_true(progress(mission({ distinct = "class" }, { repeatKind = "once" }), log).couldComplete)
  end)

  it("fills the race bar on its own", function()
    local result = progress(mission({ distinct = "race" }), seen({}, { "ORC", "TROLL", "ORC" }))
    assert.are.same({ { label = "Races", done = 2, total = #Constants.PVP_ENEMY_RACES } }, result.bars)
  end)

  it("needs both sets for class_race and shows two bars", function()
    local log = {}
    for index, class in ipairs(Constants.PVP_ENEMY_CLASSES) do
      log[#log + 1] = kill(NOW - 100 + index, "C" .. index, { class = class })
    end
    local m = mission({ distinct = "class_race" }, { repeatKind = "once" })
    local result = progress(m, log)
    assert.are.equal(2, #result.bars)
    assert.are.equal("Classes", result.bars[1].label)
    assert.are.equal("Races", result.bars[2].label)
    assert.are.equal(#Constants.PVP_ENEMY_CLASSES, result.bars[1].done)
    assert.are.equal(0, result.bars[2].done)
    assert.is_false(result.complete)
    assert.are.equal(#Constants.PVP_ENEMY_CLASSES, result.unknown)
    -- the unknown races could still fill the bar, so the approver decides
    assert.is_true(result.couldComplete)
    for index, race in ipairs(Constants.PVP_ENEMY_RACES) do
      log[#log + 1] = kill(NOW - 50 + index, "R" .. index, { class = "MAGE", race = race })
    end
    log[#log + 1] = kill(NOW - 10, "Late", { class = "MAGE", race = "ORC" })
    result = progress(m, log)
    assert.is_true(result.complete)
    assert.is_true(result.claimable)
  end)

  it("keeps the evidence in time order, each row once", function()
    local log = {
      kill(NOW - 3, "A", { class = "MAGE", race = "ORC" }),
      kill(NOW - 2, "B", { class = "ROGUE" }),
      kill(NOW - 1, "C", { race = "TROLL" }),
    }
    local result = progress(mission({ distinct = "class_race" }), log)
    assert.are.same({ "A", "B", "C" }, {
      result.evidence[1].victim,
      result.evidence[2].victim,
      result.evidence[3].victim,
    })
    assert.are.equal(2, result.unknown)
  end)
end)

describe("PvPMissionTracker battleground wins and manual missions", function()
  local function win(at, mapId)
    return { at = at, bgWin = true, mapId = mapId }
  end

  it("counts the wins of the period, filtered by zone, and not the kills", function()
    local log = { win(NOW - 3, 1459), win(NOW - 2, 1460), kill(NOW - 1, "Zed"), win(NOW - 2 * DAY, 1459) }
    local m = mission({ kind = "bg_wins", count = 2 })
    local result = progress(m, log)
    assert.are.same({ { label = "Victories", done = 2, total = 2 } }, result.bars)
    assert.is_true(result.complete)
    assert.are.same({ at = NOW - 3, bgWin = true, mapId = 1459 }, result.evidence[1])
    local zoned = progress(mission({ kind = "bg_wins", count = 2, zones = { 1459 } }), log)
    assert.are.equal(1, zoned.bars[1].done)
    assert.is_false(zoned.claimable)
  end)

  it("does not count wins as kills", function()
    assert.are.equal(0, progress(mission({ count = 5 }), { win(NOW - 1, 1459) }).bars[1].done)
  end)

  it("has no bars for a manual mission and is claimable while the period allows", function()
    local m = mission({ kind = "manual" })
    local result = progress(m, { kill(NOW - 1, "Zed") })
    assert.are.same({}, result.bars)
    assert.is_true(result.complete)
    assert.is_true(result.claimable)
    assert.are.same({}, result.evidence)
    local claims = { x = { claim = { missionId = "m1", periodKey = "20261020" } } }
    assert.is_false(progress(m, {}, claims).claimable)
  end)
end)

describe("PvPMissionTracker faction and battleground rows", function()
  it("derives the enemy classes and races from the faction of the player", function()
    local classes, races = Tracker.EnemySets("Alliance")
    assert.are.same(Constants.PVP_ENEMY_CLASSES_BY_FACTION.Alliance, classes)
    assert.are.same(Constants.PVP_ENEMY_RACES_BY_FACTION.Alliance, races)
    assert.are.same({ "DWARF", "GNOME", "HUMAN", "NIGHTELF" }, select(2, Tracker.EnemySets("Horde")))
    -- an unreadable faction falls back to the lists of an Alliance guild
    assert.are.same(Constants.PVP_ENEMY_CLASSES, (Tracker.EnemySets(nil)))
    assert.are.same(Constants.PVP_ENEMY_RACES, select(2, Tracker.EnemySets("Neutral")))
  end)

  it("fills the race bar with the races of the other side for a Horde player", function()
    local log = {
      kill(NOW - 3, "A", { race = "HUMAN" }),
      kill(NOW - 2, "B", { race = "ORC" }),
      kill(NOW - 1, "C", { race = "GNOME" }),
    }
    local m = mission({ distinct = "race" })
    local horde = Tracker.Progress(m, log, NOW, {}, SEASON, "Horde")
    assert.are.same({ { label = "Races", done = 2, total = 4 } }, horde.bars)
    local alliance = Tracker.Progress(m, log, NOW, {}, SEASON, "Alliance")
    assert.are.same({ { label = "Races", done = 1, total = 4 } }, alliance.bars)
  end)

  it("counts a battleground result of the log by its kind, and a loss is not a win or a kill", function()
    local log = {
      { kind = "bg", result = "win", bg = "wsg", at = NOW - 3, mapId = 1459 },
      { kind = "bg", result = "loss", bg = "wsg", at = NOW - 2, mapId = 1459 },
      kill(NOW - 1, "Zed"),
    }
    local result = progress(mission({ kind = "bg_wins", count = 2 }), log)
    assert.are.equal(1, result.bars[1].done)
    assert.are.same({ at = NOW - 3, bgWin = true, mapId = 1459 }, result.evidence[1])
    assert.are.equal(1, progress(mission({ count = 5 }), log).bars[1].done)
  end)
end)

describe("PvPMissionTracker texts", function()
  it("translates the bar labels and the zone names, and passes unknown ones through", function()
    ns.Locale.Use("esES")
    assert.are.equal("Bajas", Tracker.LabelText("Kills"))
    assert.are.equal("Clases", Tracker.LabelText("Classes"))
    assert.are.equal("Razas", Tracker.LabelText("Races"))
    assert.are.equal("Jugadores distintos", Tracker.LabelText("Distinct players"))
    assert.are.equal("Victorias", Tracker.LabelText("Victories"))
    assert.are.equal("Otra cosa", Tracker.LabelText("Otra cosa"))
    assert.are.equal("Ventormenta", Tracker.ZoneName(1453))
    assert.is_nil(Tracker.ZoneName(1))
    ns.Locale.Use("enUS")
    assert.are.equal("Kills", Tracker.LabelText("Kills"))
    assert.are.equal("Stormwind City", Tracker.ZoneName(1453))
  end)

  it("names every zone of the list", function()
    for _, zone in ipairs(Constants.PVP_MISSION_ZONES) do
      assert.is_string(Tracker.ZoneName(zone.mapId))
    end
  end)
end)
