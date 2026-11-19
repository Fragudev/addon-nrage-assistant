-- ViewModelPvP: the rows of the PvP seasons (season card, standings, mission cards, approvals, the mission form,
-- prizes, deliveries and history). Pure functions: plain data in, plain data out.
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/PermissionService",
    "Domain/ModuleRegistry",
    "Domain/Settings",
    "Domain/ModuleService",
    "Domain/PvPSeasonModel",
    "Domain/PvPMissionTracker",
    "Domain/IntelModel",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/ReadinessRules",
    "Domain/Professions",
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
    "UI/ViewModelPvP",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns
end

local ViewModel, ns = load_view_model()

local DAY = 86400
local T0 = 1792454400 -- 2026-10-20 00:00 UTC

-- A clock that reads dates in UTC, so the dates in the tests do not depend on the machine.
local utc = {
  date = function(format, timestamp)
    return os.date("!" .. format, timestamp)
  end,
}

local function values(items)
  local list = {}
  for _, item in ipairs(items) do
    list[#list + 1] = item.value
  end
  return list
end

local function texts(items)
  local list = {}
  for _, item in ipairs(items) do
    list[#list + 1] = item.text
  end
  return list
end

describe("ViewModel.PvPSubTabs", function()
  it("has the six player sub-tabs and no Admin one, whoever asks", function()
    assert.are.same({ "season", "missions", "stats", "feed", "history", "intel" }, values(ViewModel.PvPSubTabs()))
    assert.are.same(
      { "season", "missions", "stats", "feed", "history", "intel" },
      values(ViewModel.PvPSubTabs({ admin = true }))
    )
    assert.are.same(
      { "Season", "Missions", "Stats", "Recent kills", "History", "Intel" },
      texts(ViewModel.PvPSubTabs())
    )
  end)

  it("lists the views of Stats and History", function()
    assert.are.same({ "mine", "ranking" }, values(ViewModel.PvPStatsViews()))
    assert.are.same({ "season", "total" }, values(ViewModel.PvPHistoryViews()))
  end)

  it("gives an admin all the admin sections and an officer only approvals and deliveries", function()
    local admin = ViewModel.PvPAdminSections({ manage = true, pending = 3 })
    assert.are.same({ "approvals", "progress", "missions", "season", "prizes", "deliveries" }, values(admin))
    assert.are.equal("Approvals (3)", admin[1].text)
    local officer = ViewModel.PvPAdminSections({ manage = false, pending = 0 })
    assert.are.same({ "approvals", "progress", "deliveries" }, values(officer))
    assert.are.equal("Approvals", officer[1].text)
  end)

  it("keeps a section that exists and falls back to the first", function()
    local tabs = ViewModel.PvPSubTabs()
    assert.are.equal("history", ViewModel.PvPPick(tabs, "history"))
    assert.are.equal("season", ViewModel.PvPPick(tabs, "admin"))
    assert.is_nil(ViewModel.PvPPick({}, "x"))
  end)

  it("speaks Spanish when the client does", function()
    local es = load_view_model("esES")
    assert.are.same(
      { "Temporada", "Misiones", "Estadísticas", "Bajas recientes", "Histórico", "Intel" },
      texts(es.PvPSubTabs())
    )
    assert.are.equal("Aprobaciones (2)", es.PvPAdminSections({ manage = false, pending = 2 })[1].text)
  end)
end)

describe("ViewModel.PvPError", function()
  it("says why in words, and names the field of an invalid value", function()
    assert.are.equal("Not saved: you are not allowed to do that.", ViewModel.PvPError("forbidden"))
    assert.are.equal("Not saved: the value of 'points' is not valid.", ViewModel.PvPError("invalid:points"))
    assert.are.equal("Not saved: something odd", ViewModel.PvPError("something odd"))
  end)
end)

describe("ViewModel rewards and tiers", function()
  it("writes gold and items, with the count when it is more than one", function()
    assert.are.equal("500 gold", ViewModel.PvPRewardText({ kind = "gold", amount = 500 }))
    assert.are.equal("Flask", ViewModel.PvPRewardText({ kind = "item", itemId = 1, name = "Flask", count = 1 }))
    assert.are.equal(
      "Flask \195\1513",
      ViewModel.PvPRewardText({ kind = "item", itemId = 1, name = "Flask", count = 3 })
    )
    assert.are.equal("||cffAbc", ViewModel.PvPRewardText({ kind = "item", itemId = 1, name = "|cffAbc", count = 1 }))
  end)

  it("lists the five tiers with their colors and what they give", function()
    local rows = ViewModel.PvPPrizeRows({ ["1"] = { { kind = "gold", amount = 500 }, { kind = "gold", amount = 5 } } })
    assert.are.same(
      { "1", "2", "3", "4-6", "7-10" },
      (function()
        local list = {}
        for _, row in ipairs(rows) do
          list[#list + 1] = row.tier
        end
        return list
      end)()
    )
    assert.are.same({ "1st", "gold", "500 gold + 5 gold" }, { rows[1].label, rows[1].token, rows[1].text })
    assert.are.same({ "2nd", "silver", "-" }, { rows[2].label, rows[2].token, rows[2].text })
    assert.are.same({ "bronze", "accent", "muted" }, { rows[3].token, rows[4].token, rows[5].token })
    assert.are.equal("-", ViewModel.PvPPrizeRows(nil)[1].text)
  end)

  it("copies, adds to and removes from the tiers without touching the original", function()
    local tiers = { ["1"] = { { kind = "gold", amount = 1 } } }
    local added = ViewModel.PvPAddReward(tiers, "2", { kind = "gold", amount = 2 })
    assert.are.equal(1, #added["1"])
    assert.are.equal(2, added["2"][1].amount)
    assert.is_nil(tiers["2"])
    local removed = ViewModel.PvPRemoveReward(added, "1", 1)
    assert.are.same({}, removed["1"])
    assert.are.equal(1, #added["1"])
    assert.are.same({}, ViewModel.PvPRemoveReward(nil, "9", 1)["3"])
  end)

  it("refuses a sixth reward in a tier and an unknown tier", function()
    local tiers = { ["1"] = {} }
    for index = 1, ns.Constants.PVP_PRIZE_ENTRIES_MAX do
      tiers["1"][index] = { kind = "gold", amount = index }
    end
    assert.are.same({ nil, "invalid:limit" }, { ViewModel.PvPAddReward(tiers, "1", { kind = "gold", amount = 9 }) })
    assert.are.same({ nil, "invalid:tiers" }, { ViewModel.PvPAddReward(tiers, "9", { kind = "gold", amount = 9 }) })
  end)

  it("reads a gold amount", function()
    assert.are.same({ kind = "gold", amount = 250 }, ViewModel.PvPGoldReward(" 250 "))
    for _, bad in ipairs({ "", "0", "-5", "1.5", "abc", "100001", false }) do
      assert.are.same({ nil, "invalid:gold" }, { ViewModel.PvPGoldReward(bad) }, tostring(bad))
    end
  end)

  it("reads an item from a pasted link, keeping only the id and the name", function()
    local link = "|cffa335ee|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade]|h|r"
    assert.are.same(
      { kind = "item", itemId = 19019, name = "Thunderfury, Blessed Blade", count = 1 },
      ViewModel.PvPItemReward(link)
    )
    assert.are.equal(10, ViewModel.PvPItemReward(link, "10").count)
    assert.are.same({ nil, "invalid:item" }, { ViewModel.PvPItemReward("just text") })
    assert.are.same({ nil, "invalid:count" }, { ViewModel.PvPItemReward(link, "0") })
    assert.are.same({ nil, "invalid:count" }, { ViewModel.PvPItemReward(link, "x") })
    assert.are.same({ nil, "invalid:count" }, { ViewModel.PvPItemReward(link, "201") })
    local long = ViewModel.PvPItemReward("|Hitem:5|h[" .. ("n"):rep(200) .. "]|h")
    assert.are.equal(ns.Constants.PVP_PRIZE_ITEM_NAME_MAX, #long.name)
  end)
end)

describe("ViewModel.PvPSeasonSummary", function()
  local season = { id = "s1", name = "Autumn", startsAt = T0, endsAt = T0 + 30 * DAY, state = "active" }
  local standings = {
    { pos = 1, player = "A", points = 300 },
    { pos = 2, player = "B", points = 200 },
    { pos = 3, player = "C", points = 150 },
    { pos = 4, player = "Me", points = 100 },
  }

  local function summary(extra)
    local args = { season = season, standings = standings, player = "Me", now = T0 + 10 * DAY, clock = utc }
    for key, value in pairs(extra or {}) do
      args[key] = value
    end
    return ViewModel.PvPSeasonSummary(args)
  end

  it("shows the name, the dates, the days left and the own figures", function()
    local card = summary()
    assert.are.same({ "Autumn", "20 Oct \226\128\147 19 Nov", "ends in 20 day(s)", false }, {
      card.name,
      card.range,
      card.status,
      card.ended,
    })
    assert.are.same({ "Your position", "#4" }, { card.stats[1].caption, card.stats[1].value })
    assert.are.same({ "Your points", "100" }, { card.stats[2].caption, card.stats[2].value })
    -- To pass the 3rd place (150) from 100 points one needs 51 more (a tie loses to who got there first).
    assert.are.same({ "To the 3rd place", "+51" }, { card.stats[3].caption, card.stats[3].value })
  end)

  it("says when the player is on the podium", function()
    local card = summary({ player = "B" })
    assert.are.same({ "On the podium", "success" }, { card.stats[3].value, card.stats[3].color })
  end)

  it("asks for one point when nobody is ranked yet, and for 'Me' with no points", function()
    local card = summary({ standings = {} })
    assert.are.same({ "-", "0", "+1" }, { card.stats[1].value, card.stats[2].value, card.stats[3].value })
    assert.are.equal("+151", summary({ player = "Nobody" }).stats[3].value)
  end)

  it("tells a season that did not start, ends today or ended", function()
    assert.are.equal("starts in 2 day(s)", summary({ now = T0 - 2 * DAY + 1 }).status)
    assert.are.equal("ends today", summary({ now = T0 + 30 * DAY - 60 }).status)
    local ended = summary({ now = T0 + 31 * DAY })
    assert.are.same({ "ended, waiting to be closed", true }, { ended.status, ended.ended })
  end)

  it("escapes the name", function()
    assert.are.equal("||x", summary({ season = { id = "s", name = "|x", startsAt = T0, endsAt = T0 + DAY } }).name)
  end)
end)

describe("ViewModel.PvPStandingRows", function()
  local function standings(count)
    local list = {}
    for index = 1, count do
      list[index] = {
        pos = index,
        player = "P" .. index,
        points = 1000 - index,
        lastAt = T0 - index * 60,
        tier = ns.PvPSeasonModel.TierOf(index),
      }
    end
    return list
  end

  it("draws the tier chip, the figures and the own row", function()
    local data =
      ViewModel.PvPStandingRows(standings(3), { player = "P2", missions = { P1 = 4 }, now = T0, limit = 100 })
    assert.are.same({ 3, 3 }, { data.shown, data.total })
    local first, second = data.rows[1], data.rows[2]
    assert.are.same({ 1, "gold", "1st", "gold", "4", "999", "1 min ago", false }, {
      first.pos,
      first.positionToken,
      first.tier.text,
      first.tier.color,
      first.missions,
      first.points,
      first.last,
      first.mine,
    })
    assert.are.same({ "silver", true, "0" }, { second.positionToken, second.mine, second.missions })
  end)

  it("puts a separator row under position 10 and gives no tier below it", function()
    local data = ViewModel.PvPStandingRows(standings(12), { player = "x", now = T0 })
    assert.are.equal(13, #data.rows)
    assert.is_true(data.rows[11].separator)
    assert.are.equal(11, data.rows[12].pos)
    assert.is_nil(data.rows[12].tier)
    assert.are.equal(12, data.shown)
    assert.are.same({ "4th-6th", "accent" }, { data.rows[4].tier.text, data.rows[4].tier.color })
    assert.are.same({ "7th-10th", "muted" }, { data.rows[10].tier.text, data.rows[10].tier.color })
  end)

  it("has no separator for exactly ten, and cuts at the limit", function()
    local data = ViewModel.PvPStandingRows(standings(10), { player = "x", now = T0 })
    assert.are.equal(10, #data.rows)
    local cut = ViewModel.PvPStandingRows(standings(12), { player = "x", now = T0, limit = 5 })
    assert.are.same({ 5, 12 }, { cut.shown, cut.total })
    assert.is_nil(ViewModel.PvPStandingRows(standings(1), { player = "x" }).rows[1].tier == nil and 0 or nil)
  end)

  it("counts only the grants that count and are not voided", function()
    local counts = ViewModel.PvPGrantCounts({
      { player = "A", counts = true, voided = false },
      { player = "A", counts = true, voided = true },
      { player = "A", counts = false, voided = false },
      { player = "B", counts = true, voided = false },
    })
    assert.are.same({ A = 1, B = 1 }, counts)
    assert.are.same({}, ViewModel.PvPGrantCounts(nil))
  end)
end)

describe("ViewModel mission criteria and cards", function()
  local function mission(goal, extra)
    local m = {
      id = "m1",
      seasonId = "s1",
      title = "Hunt",
      desc = "Kill them",
      points = 50,
      goal = goal,
      repeatKind = "once",
      perPlayer = 1,
      active = true,
    }
    for key, value in pairs(extra or {}) do
      m[key] = value
    end
    return m
  end
  local kills = { kind = "kills", count = 10, zones = { 1454 }, place = "any", distinct = "none" }

  it("describes the criteria as chips", function()
    assert.are.same(
      { "Zone 1454", "10 kills", "Once" },
      (function()
        local chips = ViewModel.PvPCriteriaChips(mission(kills))
        chips[1] = chips[1]:gsub("Zone: ", "Zone ")
        return chips
      end)()
    )
    local named = ViewModel.PvPCriteriaChips(mission(kills), function(mapId)
      return mapId == 1454 and "Orgrimmar" or nil
    end)
    assert.are.same({ "Zone: Orgrimmar", "10 kills", "Once" }, named)
    local two = ViewModel.PvPCriteriaChips(mission({ kind = "kills", count = 5, zones = { 1, 2 } }), function(id)
      return "Z" .. id
    end)
    assert.are.equal("Zones: Z1, Z2", two[1])
  end)

  it("describes distinct, place, repetition and the number per player", function()
    local chips = ViewModel.PvPCriteriaChips(
      mission({ kind = "kills", count = 50, zones = {}, place = "world", distinct = "name" }, {
        repeatKind = "weekly",
        perPlayer = 3,
      })
    )
    assert.are.same({ "Distinct names", "50 kills", "Open world", "Weekly", "3 times each" }, chips)
    assert.are.same(
      { "Distinct classes and races", "Daily" },
      ViewModel.PvPCriteriaChips(
        mission({ kind = "kills", count = 1, zones = {}, distinct = "class_race" }, { repeatKind = "daily" })
      )
    )
    assert.are.same(
      { "Battleground", "3 wins", "Daily" },
      ViewModel.PvPCriteriaChips(mission({ kind = "bg_wins", count = 3, zones = {} }, { repeatKind = "daily" }))
    )
    assert.are.same({ "Manual", "Once" }, ViewModel.PvPCriteriaChips(mission({ kind = "manual", count = 1 })))
  end)

  it("knows which goals the client can detect", function()
    assert.is_true(ViewModel.PvPGoalAvailable(kills, nil))
    assert.is_true(ViewModel.PvPGoalAvailable(kills, { kills = true, zones = true }))
    assert.is_false(ViewModel.PvPGoalAvailable(kills, { kills = true, zones = false }))
    assert.is_false(
      ViewModel.PvPGoalAvailable({ kind = "kills", zones = {}, distinct = "race" }, { classRace = false })
    )
    assert.is_false(ViewModel.PvPGoalAvailable({ kind = "bg_wins", zones = {} }, { bgWins = false }))
    assert.is_true(ViewModel.PvPGoalAvailable({ kind = "manual" }, { kills = false, bgWins = false }))
    assert.is_false(ViewModel.PvPGoalAvailable({ kind = "kills" }, { kills = false }))
  end)

  local function cards(list, options)
    local base = {
      tracker = true,
      progressOf = function()
        return nil
      end,
      claimStateOf = function()
        return "none"
      end,
    }
    for key, value in pairs(options or {}) do
      base[key] = value
    end
    return ViewModel.PvPMissionCards(list, base)
  end

  it("shows progress bars and lets a complete mission be claimed", function()
    local list = cards({ mission(kills) }, {
      progressOf = function()
        return { bars = { { label = "Kills", done = 10, total = 10 } }, unknown = 0, complete = true, claimable = true }
      end,
    })
    local card = list[1]
    assert.are.same({ "Hunt", "Kill them", "+50 pts", true, false }, {
      card.title,
      card.desc,
      card.points,
      card.canClaim,
      card.noteRequired,
    })
    assert.are.same({ label = "Kills", text = "10 / 10", ratio = 1, complete = true }, card.bars[1])
    assert.are.same({ text = "Ready to claim", color = "accent" }, card.status)
    assert.is_nil(card.note)
  end)

  it("shows a mission in progress, and its ratio, and cannot claim it", function()
    local card = cards({ mission(kills) }, {
      progressOf = function()
        return {
          bars = { { label = "Kills", done = 3, total = 12 } },
          unknown = 0,
          complete = false,
          claimable = false,
        }
      end,
    })[1]
    assert.are.same({ "In progress", "muted" }, { card.status.text, card.status.color })
    assert.are.equal(0.25, card.bars[1].ratio)
    assert.is_false(card.canClaim)
  end)

  it("shows the state of a claim and hides the claim button while it waits or is approved", function()
    local function with(state)
      return cards({ mission(kills) }, {
        progressOf = function()
          return { bars = {}, unknown = 0, complete = true, claimable = true }
        end,
        claimStateOf = function()
          return state
        end,
      })[1]
    end
    assert.are.same({ "Pending approval", "warning", false }, {
      with("pending").status.text,
      with("pending").status.color,
      with("pending").canClaim,
    })
    assert.are.same({ "Approved", "success", false }, {
      with("approved").status.text,
      with("approved").status.color,
      with("approved").canClaim,
    })
    -- A rejected claim can be made again when the mission still is claimable.
    assert.are.same({ "Rejected", "danger", true }, {
      with("rejected").status.text,
      with("rejected").status.color,
      with("rejected").canClaim,
    })
  end)

  it("adds the note about kills without a known class", function()
    local card = cards({ mission(kills) }, {
      progressOf = function()
        local bars = { { label = "Classes", done = 5, total = 8 } }
        return { bars = bars, unknown = 2, complete = false, claimable = true }
      end,
    })[1]
    assert.is_truthy(card.note:find("2 kill(s) without a known class", 1, true))
    assert.is_truthy(card.note:find("the approver decides", 1, true))
  end)

  it("claims a manual mission with a note, also when the tracker has no progress for it", function()
    local card = cards({ mission({ kind = "manual", count = 1, zones = {} }) })[1]
    assert.are.same({ true, true }, { card.canClaim, card.noteRequired })
    assert.are.same({}, card.bars)
  end)

  it("does not offer a claim after the season ended", function()
    local card = cards({ mission({ kind = "manual", count = 1, zones = {} }) }, { ended = true })[1]
    assert.is_false(card.canClaim)
  end)

  it("says 'Not available' without a tracker or when the client cannot detect the criterion", function()
    local none = ViewModel.PvPMissionCards({ mission(kills) }, { tracker = false })[1]
    assert.are.same({ "Not available on this client", false, {} }, { none.unavailable, none.canClaim, none.bars })
    local blocked = cards({ mission(kills) }, {
      availability = { kills = true, zones = false },
      progressOf = function()
        error("must not be asked")
      end,
    })[1]
    assert.are.same({ "Not available on this client", false }, { blocked.unavailable, blocked.canClaim })
  end)

  it("rows the admin table with criteria and a status", function()
    local rows =
      ViewModel.PvPMissionRows({ mission(kills), mission({ kind = "manual" }, { id = "m2", active = false }) })
    assert.are.same({ "m1", "Hunt", "50", "Active", "success", true }, {
      rows[1].id,
      rows[1].title,
      rows[1].points,
      rows[1].status,
      rows[1].token,
      rows[1].active,
    })
    assert.are.equal("Zone 1454 \194\183 10 kills \194\183 Once", rows[1].criteria:gsub("Zone: ", "Zone "))
    assert.are.same({ "Paused", "muted" }, { rows[2].status, rows[2].token })
  end)
end)

describe("ViewModel bounties", function()
  it("saves and reopens the kind and the target, and drops the target for other kinds", function()
    local draft = ViewModel.PvPMissionDraft(nil)
    draft.kind, draft.target, draft.count, draft.distinct = "kos", "  Zed ", "2", "name"
    local fields = ViewModel.PvPMissionFields(draft)
    assert.are.same({ "kos", "Zed", "none", "any" }, {
      fields.goal.kind,
      fields.goal.target,
      fields.goal.distinct,
      fields.goal.place,
    })
    draft.target = "  "
    assert.is_nil(ViewModel.PvPMissionFields(draft).goal.target)
    local reopened = ViewModel.PvPMissionDraft({
      id = "m1",
      title = "T",
      points = 5,
      goal = { kind = "kos", count = 1, zones = {}, place = "any", distinct = "none", target = "Zed" },
      repeatKind = "once",
    })
    assert.are.same({ "kos", "Zed" }, { reopened.kind, reopened.target })
    draft.kind, draft.target = "kills", "Zed"
    assert.is_nil(ViewModel.PvPMissionFields(draft).goal.target)
  end)

  it("shows the target as a chip, offers the kind and needs the kill source", function()
    local m = { repeatKind = "once", goal = { kind = "kos", count = 1, zones = {}, target = "Zed" } }
    assert.are.equal("Bounty: Zed", ViewModel.PvPCriteriaChips(m)[1])
    m.goal.target = nil
    assert.are.equal("Kill on Sight", ViewModel.PvPCriteriaChips(m)[1])
    local kinds = {}
    for _, item in ipairs(ViewModel.PvPGoalChoices()) do
      kinds[item.value] = true
    end
    assert.is_true(kinds.kos)
    assert.is_false(ViewModel.PvPGoalAvailable(m.goal, { kills = false }))
    assert.is_true(ViewModel.PvPGoalAvailable(m.goal, { kills = true }))
  end)

  it("lists the targets of the active bounties by key", function()
    local keys = ViewModel.PvPBountyKeys({
      { active = true, goal = { kind = "kos", target = "Zed-Realm" } },
      { active = false, goal = { kind = "kos", target = "Paused" } },
      { active = true, goal = { kind = "kos" } },
      { active = true, goal = { kind = "kills", target = "Nope" } },
    })
    assert.are.same({ zed = true }, keys)
    assert.are.same({}, ViewModel.PvPBountyKeys(nil))
  end)
end)

describe("ViewModel mission form", function()
  it("starts a new mission with sensible values, and the form values of an existing one", function()
    local draft = ViewModel.PvPMissionDraft(nil)
    assert.are.same({ "", "kills", "10", "once", "1", true }, {
      draft.title,
      draft.kind,
      draft.count,
      draft.repeatKind,
      draft.perPlayer,
      draft.active,
    })
    local existing = ViewModel.PvPMissionDraft({
      id = "m9",
      title = "T",
      desc = nil,
      points = 25,
      goal = { kind = "kills", count = 7, zones = { 1, 2 }, place = "bg", distinct = "race" },
      repeatKind = "daily",
      perPlayer = 2,
      active = false,
    })
    assert.are.same({ "m9", "T", "", "7", "25", "1, 2", "bg", "race", "daily", "2", false }, {
      existing.id,
      existing.title,
      existing.desc,
      existing.count,
      existing.points,
      existing.zones,
      existing.place,
      existing.distinct,
      existing.repeatKind,
      existing.perPlayer,
      existing.active,
    })
  end)

  it("turns the draft into the fields of the service", function()
    local draft = ViewModel.PvPMissionDraft(nil)
    draft.title, draft.points, draft.zones, draft.place, draft.distinct = "Hunt", "50", "1454, 1453", "world", "name"
    local fields = ViewModel.PvPMissionFields(draft)
    assert.are.same({ "Hunt", 50, 10, { 1454, 1453 }, "world", "name", "once", 1, true }, {
      fields.title,
      fields.points,
      fields.goal.count,
      fields.goal.zones,
      fields.goal.place,
      fields.goal.distinct,
      fields.repeatKind,
      fields.perPlayer,
      fields.active,
    })
  end)

  it("ignores the goal fields of a manual mission and the place of a battleground one", function()
    local draft = ViewModel.PvPMissionDraft(nil)
    draft.kind, draft.count, draft.zones, draft.points = "manual", "abc", "x", "5"
    local manual = ViewModel.PvPMissionFields(draft)
    assert.are.same({ "manual", 1, {}, "any", "none" }, {
      manual.goal.kind,
      manual.goal.count,
      manual.goal.zones,
      manual.goal.place,
      manual.goal.distinct,
    })
    draft.kind, draft.count, draft.zones, draft.place = "bg_wins", "3", "", "world"
    local wins = ViewModel.PvPMissionFields(draft)
    assert.are.same({ "any", "none", 3 }, { wins.goal.place, wins.goal.distinct, wins.goal.count })
  end)

  it("names the field that is not a number or a zone list", function()
    local draft = ViewModel.PvPMissionDraft(nil)
    draft.points = "many"
    assert.are.same({ nil, "invalid:points" }, { ViewModel.PvPMissionFields(draft) })
    draft.points, draft.perPlayer = "5", "1.5"
    assert.are.same({ nil, "invalid:perPlayer" }, { ViewModel.PvPMissionFields(draft) })
    draft.perPlayer, draft.count = "1", "ten"
    assert.are.same({ nil, "invalid:count" }, { ViewModel.PvPMissionFields(draft) })
    draft.count, draft.zones = "10", "1454, nowhere"
    assert.are.same({ nil, "invalid:zones" }, { ViewModel.PvPMissionFields(draft) })
  end)

  it("parses zone lists", function()
    assert.are.same({ 1, 2, 3 }, ViewModel.PvPParseZones("1, 2;3"))
    assert.are.same({}, ViewModel.PvPParseZones(""))
    assert.are.same({}, ViewModel.PvPParseZones(nil))
    assert.is_nil(ViewModel.PvPParseZones("1.5"))
  end)

  it("offers the goal kinds, hiding battleground wins when the client cannot read them", function()
    assert.are.same(
      { "kills", "kos", "bg_wins", "manual", "bg_played", "duel_wins" },
      values(ViewModel.PvPGoalChoices(nil))
    )
    assert.are.same(
      { "kills", "kos", "bg_wins", "manual", "bg_played", "duel_wins" },
      values(ViewModel.PvPGoalChoices({ bgWins = true }))
    )
    assert.are.same({ "kills", "kos", "manual", "duel_wins" }, values(ViewModel.PvPGoalChoices({ bgWins = false })))
    assert.are.same({ "any", "world", "bg" }, values(ViewModel.PvPPlaceChoices()))
    assert.are.same({ "none", "name", "class", "race", "class_race" }, values(ViewModel.PvPDistinctChoices()))
    assert.are.same({ "once", "daily", "weekly" }, values(ViewModel.PvPRepeatChoices()))
    assert.are.same({ true, false }, values(ViewModel.PvPActiveChoices()))
  end)

  it("offers the other seasons that have missions to copy from", function()
    local seasons = { { id = "s3", name = "Now" }, { id = "s2", name = "Summer" }, { id = "s1", name = "Empty" } }
    local items = ViewModel.PvPCloneChoices(seasons, "s3", function(id)
      return id == "s2" and 4 or 0
    end)
    assert.are.same({ { value = "s2", text = "Summer (4)" } }, items)
  end)
end)

describe("ViewModel mission options (Advanced section)", function()
  local function draft(change)
    local d = ViewModel.PvPMissionDraft(nil)
    d.title = "Event"
    for key, value in pairs(change or {}) do
      d[key] = value
    end
    return d
  end

  local function validates(fields)
    return ns.PvPSeasonModel.ValidateMission({
      id = "m1",
      seasonId = "s1",
      title = fields.title,
      points = fields.points,
      goal = fields.goal,
      repeatKind = fields.repeatKind,
      rev = 1,
      updatedAt = 1,
    })
  end

  it(
    "builds a duel mission: the place is forced, only names can be distinct and the kill-only fields stay out",
    function()
      local fields = assert(ViewModel.PvPMissionFields(draft({
        kind = "duel_wins",
        count = "10",
        place = "world",
        distinct = "class",
        target = "Zed",
        victimClasses = { "MAGE" },
        victimRaces = { "ORC" },
        minGuild = "2",
        bgs = { "wsg" },
        victimCap = "3",
        maxCompletions = "2",
        autoClaim = true,
      })))
      assert.are.same(
        { kind = "duel_wins", count = 10, zones = {}, place = "any", distinct = "none", victimCapPerDay = 3 },
        {
          kind = fields.goal.kind,
          count = fields.goal.count,
          zones = fields.goal.zones,
          place = fields.goal.place,
          distinct = fields.goal.distinct,
          victimCapPerDay = fields.goal.victimCapPerDay,
        }
      )
      for _, field in ipairs({ "target", "victimClasses", "victimRaces", "minGuildInGroup", "bgs" }) do
        assert.is_nil(fields.goal[field], field)
      end
      assert.are.equal(2, fields.goal.maxCompletions)
      assert.is_true(fields.goal.autoClaim)
      assert.is_truthy(validates(fields))
      local named = assert(ViewModel.PvPMissionFields(draft({ kind = "duel_wins", distinct = "name" })))
      assert.are.equal("name", named.goal.distinct)
    end
  )

  it("offers only the names as the distinct choice of a duel", function()
    assert.are.same({ "none", "name" }, values(ViewModel.PvPDuelDistinctChoices()))
    assert.are.equal(5, #ViewModel.PvPDistinctChoices())
  end)

  it("offers the duel kind last, labelled, and needs no kill source", function()
    local kinds = values(ViewModel.PvPGoalChoices())
    assert.are.equal("duel_wins", kinds[#kinds])
    assert.are.equal("Duels won", ViewModel.PVP_GOAL_KINDS.duel_wins)
    local goal = { kind = "duel_wins", count = 1, zones = {} }
    assert.is_true(ViewModel.PvPGoalAvailable(goal, { kills = false, duels = true }))
    assert.is_false(ViewModel.PvPGoalAvailable(goal, { kills = true, duels = false }))
    kinds = values(ViewModel.PvPGoalChoices({ bgWins = false }))
    assert.are.equal("duel_wins", kinds[#kinds])
  end)

  it("describes a duel mission as chips and in one sentence", function()
    local m = {
      repeatKind = "weekly",
      goal = { kind = "duel_wins", count = 10, zones = {}, victimCapPerDay = 3, distinct = "none" },
    }
    assert.are.same({ "10 duels won", "Max 3 per victim per day", "Weekly" }, ViewModel.PvPCriteriaChips(m))
    local fields = assert(ViewModel.PvPMissionFields(draft({ kind = "duel_wins", count = "10", victimCap = "3" })))
    assert.are.equal(
      "Counts duels won, 10 times, max 3 per victim per day, 10 points, once.",
      ViewModel.PvPMissionSummary(fields, {})
    )
  end)

  it("writes no optional field for a plain draft, so the goal stays as before", function()
    local fields = assert(ViewModel.PvPMissionFields(draft()))
    assert.are.same({ kind = "kills", count = 10, zones = {}, place = "any", distinct = "none" }, fields.goal)
    assert.is_false(ViewModel.PvPHasAdvanced(draft()))
  end)

  it("turns the Advanced draft into goal fields", function()
    local fields = assert(ViewModel.PvPMissionFields(draft({
      victimClasses = { "MAGE" },
      victimRaces = { "ORC", "TROLL" },
      victimCap = "1",
      minGuild = "3",
      windowOn = true,
      windowStart = 100,
      windowEnd = 200,
      maxCompletions = "2",
      autoClaim = true,
    })))
    local goal = fields.goal
    assert.are.same({ "MAGE" }, goal.victimClasses)
    assert.are.same({ "ORC", "TROLL" }, goal.victimRaces)
    assert.are.equal(1, goal.victimCapPerDay)
    assert.are.equal(3, goal.minGuildInGroup)
    assert.are.same({ startsAt = 100, endsAt = 200 }, goal.window)
    assert.are.equal(2, goal.maxCompletions)
    assert.is_true(goal.autoClaim)
    assert.is_true(ViewModel.PvPHasAdvanced(draft({ autoClaim = true })))
    -- the service accepts what the form writes
    assert.is_truthy(validates(fields))
  end)

  it("keeps the cap 0 (no cap) and leaves an empty cap out", function()
    assert.are.equal(0, assert(ViewModel.PvPMissionFields(draft({ victimCap = "0" }))).goal.victimCapPerDay)
    assert.is_nil(assert(ViewModel.PvPMissionFields(draft({ victimCap = "  " }))).goal.victimCapPerDay)
  end)

  it("only writes the fields that apply to the kind", function()
    local wins = assert(ViewModel.PvPMissionFields(draft({
      kind = "bg_played",
      bgs = { "wsg", "av" },
      victimClasses = { "MAGE" },
      minGuild = "3",
      victimCap = "2",
    })))
    assert.are.same({ "wsg", "av" }, wins.goal.bgs)
    assert.is_nil(wins.goal.victimClasses)
    assert.is_nil(wins.goal.minGuildInGroup)
    assert.is_nil(wins.goal.victimCapPerDay)
    local manual = assert(ViewModel.PvPMissionFields(draft({ kind = "manual", autoClaim = true, windowOn = true })))
    assert.is_nil(manual.goal.autoClaim)
    assert.is_nil(manual.goal.window)
  end)

  it("refuses numbers that are not numbers and a window with a missing date", function()
    assert.are.same({ nil, "invalid:victimCapPerDay" }, { ViewModel.PvPMissionFields(draft({ victimCap = "x" })) })
    assert.are.same({ nil, "invalid:minGuildInGroup" }, { ViewModel.PvPMissionFields(draft({ minGuild = "1.5" })) })
    assert.are.same({ nil, "invalid:maxCompletions" }, { ViewModel.PvPMissionFields(draft({ maxCompletions = "z" })) })
    assert.are.same(
      { nil, "invalid:window" },
      { ViewModel.PvPMissionFields(draft({ windowOn = true, windowStart = 5 })) }
    )
  end)

  it("edits a saved mission with its options and writes them back unchanged", function()
    local mission = {
      id = "m1",
      title = "Event",
      desc = "",
      points = 20,
      repeatKind = "weekly",
      perPlayer = 1,
      active = true,
      goal = {
        kind = "kills",
        count = 4,
        zones = {},
        place = "any",
        distinct = "none",
        victimClasses = { "ROGUE" },
        victimCapPerDay = 0,
        minGuildInGroup = 2,
        window = { startsAt = 10, endsAt = 20 },
        maxCompletions = 3,
        autoClaim = true,
      },
    }
    local edited = ViewModel.PvPMissionDraft(mission)
    assert.is_true(ViewModel.PvPHasAdvanced(edited))
    assert.are.same(mission.goal, assert(ViewModel.PvPMissionFields(edited)).goal)
  end)

  it("toggles tokens in a draft list without repeats", function()
    local d = draft()
    ViewModel.PvPToggleToken(d, "victimClasses", "MAGE", true)
    ViewModel.PvPToggleToken(d, "victimClasses", "ROGUE", true)
    ViewModel.PvPToggleToken(d, "victimClasses", "MAGE", true)
    assert.are.same({ "ROGUE", "MAGE" }, d.victimClasses)
    ViewModel.PvPToggleToken(d, "victimClasses", "ROGUE", false)
    assert.are.same({ "MAGE" }, d.victimClasses)
  end)

  it("offers the battlegrounds and the enemy classes and races of the other side", function()
    assert.are.same({ "wsg", "ab", "av" }, values(ViewModel.PvPBattlegroundChoices()))
    local classes, races = ViewModel.PvPEnemyChoices("Alliance")
    assert.are.same(ns.Constants.PVP_ENEMY_CLASSES_BY_FACTION.Alliance, values(classes))
    assert.are.same({ "ORC", "SCOURGE", "TAUREN", "TROLL" }, values(races))
    assert.are.equal("Undead", races[2].text)
    local _, hordeRaces = ViewModel.PvPEnemyChoices("Horde")
    assert.are.equal("Night Elf", hordeRaces[4].text)
  end)

  it("fills the form from each template with a mission the service accepts", function()
    local choices = ViewModel.PvPPresetChoices()
    assert.are.equal(6, #choices)
    for _, choice in ipairs(choices) do
      local d = draft({ title = "old", victimClasses = { "MAGE" }, autoClaim = true })
      assert.is_true(ViewModel.PvPApplyPreset(d, choice.value))
      assert.are_not.equal("old", d.title)
      assert.is_nil(d.id)
      local fields = assert(ViewModel.PvPMissionFields(d))
      assert.is_truthy(validates(fields), choice.value)
      -- the template starts from the blank form: nothing of the previous choices is left
      assert.is_nil(fields.goal.victimClasses)
      assert.is_nil(fields.goal.autoClaim)
    end
    assert.is_false(ViewModel.PvPApplyPreset(draft(), "nope"))
  end)

  it("has a Duelist template: 10 duels won, weekly, 3 per opponent per day", function()
    local found
    for _, choice in ipairs(ViewModel.PvPPresetChoices()) do
      if choice.text == "Duelist: win 10 duels" then
        found = choice.value
      end
    end
    local d = draft()
    assert.is_true(ViewModel.PvPApplyPreset(d, assert(found)))
    local fields = assert(ViewModel.PvPMissionFields(d))
    assert.are.same(
      { "duel_wins", 10, "weekly", 3 },
      { fields.goal.kind, fields.goal.count, fields.repeatKind, fields.goal.victimCapPerDay }
    )
    assert.is_truthy(validates(fields))
  end)

  it("describes a mission in one sentence", function()
    local wins = assert(ViewModel.PvPMissionFields(draft({
      kind = "bg_wins",
      count = "10",
      bgs = { "ab" },
      points = "50",
      repeatKind = "weekly",
    })))
    assert.are.equal(
      "Counts battleground wins in Arathi Basin, 10 times, 50 points, weekly.",
      ViewModel.PvPMissionSummary(wins, {})
    )
    local kills = assert(ViewModel.PvPMissionFields(draft({
      count = "5",
      place = "world",
      victimClasses = { "MAGE" },
      victimCap = "1",
      minGuild = "3",
      maxCompletions = "2",
      autoClaim = true,
      repeatKind = "daily",
    })))
    assert.are.equal(
      "Counts honourable kills in Open world, 5 times, victims of class Mage, max 1 per victim per day,"
        .. " with at least 3 guildmates in the group, 10 points, daily, at most 2 completions per member,"
        .. " claimed automatically.",
      ViewModel.PvPMissionSummary(kills, {})
    )
    local manual = assert(ViewModel.PvPMissionFields(draft({ kind = "manual" })))
    assert.is_truthy(ViewModel.PvPMissionSummary(manual, {}):find("claims it with a note", 1, true))
    local windowed =
      assert(ViewModel.PvPMissionFields(draft({ windowOn = true, windowStart = T0, windowEnd = T0 + DAY })))
    local text = ViewModel.PvPMissionSummary(windowed, {
      dateText = function(timestamp)
        return "t" .. (timestamp - T0)
      end,
    })
    assert.is_truthy(text:find("only from t0 to t86400", 1, true))
  end)

  it("shows the chips of the new options and the battleground kinds", function()
    local mission = {
      repeatKind = "weekly",
      goal = {
        kind = "kills",
        count = 3,
        zones = {},
        victimClasses = { "MAGE" },
        victimRaces = { "ORC" },
        victimCapPerDay = 0,
        minGuildInGroup = 2,
        window = { startsAt = 1, endsAt = 2 },
        maxCompletions = 2,
        autoClaim = true,
      },
    }
    local chips = table.concat(ViewModel.PvPCriteriaChips(mission), "|")
    for _, part in ipairs({
      "Classes: Mage",
      "Races: Orc",
      "No cap per victim",
      "2+ guildmates",
      "Event window",
      "Max 2 completions",
      "Auto-claim",
    }) do
      assert.is_truthy(chips:find(part, 1, true), part)
    end
    local played = table.concat(
      ViewModel.PvPCriteriaChips({
        repeatKind = "daily",
        goal = { kind = "bg_played", count = 4, bgs = { "wsg", "av" } },
      }),
      "|"
    )
    assert.is_truthy(played:find("4 played", 1, true))
    assert.is_truthy(played:find("Warsong Gulch, Alterac Valley", 1, true))
  end)

  it("needs the class and race detection for a filter, and the winner for battlegrounds played", function()
    assert.is_false(ViewModel.PvPGoalAvailable({ kind = "kills", victimClasses = { "MAGE" } }, { classRace = false }))
    assert.is_true(ViewModel.PvPGoalAvailable({ kind = "kills", victimClasses = {} }, { classRace = false }))
    assert.is_false(ViewModel.PvPGoalAvailable({ kind = "bg_played" }, { bgWins = false }))
  end)
end)

describe("ViewModel mission cards: rules, since when and state", function()
  local mission = {
    id = "m1",
    title = "Hunt",
    desc = "",
    points = 20,
    repeatKind = "weekly",
    perPlayer = 1,
    active = true,
    goal = { kind = "kills", count = 5, zones = {}, place = "any", distinct = "none", victimCapPerDay = 1 },
  }
  local function card(progress, state, extra)
    local options = {
      tracker = true,
      progressOf = function()
        return progress
      end,
      claimStateOf = function()
        return state or "none"
      end,
      now = T0 + 12 * 3600,
      season = { startsAt = T0 - 10 * DAY },
    }
    for key, value in pairs(extra or {}) do
      options[key] = value
    end
    return ViewModel.PvPMissionCards({ mission }, options)[1]
  end

  it("says the rules in plain words", function()
    local c = card({ bars = {}, complete = false, claimable = false })
    assert.are.equal("Counts honourable kills, 5 times, max 1 per victim per day, 20 points, weekly.", c.rules)
  end)

  it("says since when it counts: the day, the week (from Monday), the season or the event window", function()
    -- 2026-10-20 is a Tuesday: the week counts from Monday the 19th at 00:00
    local weekly = card({ bars = {}, complete = false, claimable = false }).countsFrom
    assert.is_truthy(weekly:find("Counts from Mon 19 Oct", 1, true))
    mission.repeatKind = "daily"
    assert.is_truthy(card({ bars = {}, complete = false, claimable = false }).countsFrom:find("Tue 20 Oct", 1, true))
    mission.repeatKind = "once"
    assert.is_truthy(card({ bars = {}, complete = false, claimable = false }).countsFrom:find("Sat 10 Oct", 1, true))
    mission.goal.window = { startsAt = T0 + 3600, endsAt = T0 + 7200 }
    assert.is_truthy(card({ bars = {}, complete = false, claimable = false }).countsFrom:find("Tue 20 Oct", 1, true))
    mission.goal.window = nil
    mission.repeatKind = "weekly"
    assert.is_nil(card({ bars = {}, complete = false, claimable = false }, "none", { now = "x" }).countsFrom)
  end)

  it("tells in progress, ready to claim, claimed (pending) and approved apart", function()
    local progress = { bars = { { label = "Kills", done = 2, total = 5 } }, complete = false, claimable = false }
    assert.are.equal("In progress", card(progress).status.text)
    local ready = { bars = { { label = "Kills", done = 5, total = 5 } }, complete = true, claimable = true }
    assert.are.equal("Ready to claim", card(ready).status.text)
    assert.are.equal("Pending approval", card(ready, "pending").status.text)
    assert.are.equal("Approved", card(ready, "approved").status.text)
    -- a manual mission has no "ready": the member decides
    mission.goal.kind = "manual"
    assert.is_nil(card({ bars = {}, complete = true, claimable = true }).status)
    mission.goal.kind = "kills"
  end)
end)

describe("ViewModel.PvPProgressBlocks", function()
  local missions = {
    { id = "m1", title = "Hunt", goal = { kind = "kills" } },
    { id = "m2", title = "Wins", goal = { kind = "bg_wins" } },
  }

  it("blocks the missions somebody reported on, with the closest member first and a state per member", function()
    local board = {
      m1 = {
        { player = "Bob", count = 5, goal = 5, ready = true, claimed = true, at = T0 },
        { player = "Ann", count = 5, goal = 5, ready = true, claimed = false, at = T0 - 600 },
        { player = "Cat", count = 1, goal = 5, ready = false, claimed = false, at = T0 - 7200 },
      },
    }
    local blocks = ViewModel.PvPProgressBlocks(board, missions, { now = T0 + 60 })
    assert.are.equal(1, #blocks)
    assert.are.equal("Hunt", blocks[1].title)
    assert.are.same({ "Bob", "Ann", "Cat" }, {
      blocks[1].rows[1].player,
      blocks[1].rows[2].player,
      blocks[1].rows[3].player,
    })
    assert.are.same({ "Claimed", "Ready to claim", "In progress" }, {
      blocks[1].rows[1].status.text,
      blocks[1].rows[2].status.text,
      blocks[1].rows[3].status.text,
    })
    assert.are.same(
      { "5 / 5", 1, "1 min ago" },
      { blocks[1].rows[1].text, blocks[1].rows[1].ratio, blocks[1].rows[1].updated }
    )
    assert.are.equal("11 min ago", blocks[1].rows[2].updated)
    assert.are.equal(0.2, blocks[1].rows[3].ratio)
  end)

  it("is empty when nobody reported, and escapes the names", function()
    assert.are.same({}, ViewModel.PvPProgressBlocks({}, missions, {}))
    local blocks = ViewModel.PvPProgressBlocks(
      { m2 = { { player = "|cffff0000Eve", count = 0, goal = 2, ready = false, claimed = false, at = T0 } } },
      missions,
      {}
    )
    assert.are.equal("||cffff0000Eve", blocks[1].rows[1].player)
    assert.are.equal("", blocks[1].rows[1].updated)
  end)
end)

describe("ViewModel.PvPClaimRows", function()
  local missions = { m1 = { id = "m1", title = "Hunt", points = 50 } }
  local function rows(claims, extra)
    local options = {
      missionOf = function(id)
        return missions[id]
      end,
      now = T0 + 720,
      formatClock = function(at)
        return "t" .. at
      end,
      zoneName = function(mapId)
        return mapId == 1454 and "Orgrimmar" or nil
      end,
    }
    for key, value in pairs(extra or {}) do
      options[key] = value
    end
    return ViewModel.PvPClaimRows(claims, options)
  end

  it("describes the claim and its evidence, with the unknown class marked", function()
    local list = rows({
      {
        id = "c1",
        player = "Ann",
        missionId = "m1",
        at = T0,
        summary = { done = 10, total = 10, classes = 8, classesTotal = 8, races = 4, racesTotal = 4, unknown = 1 },
        evidence = {
          { at = 1, victim = "Zed", mapId = 1454, place = "world", class = "WARRIOR", race = "Orc" },
          { at = 2, victim = "Quux", mapId = 99, place = "world" },
          { at = 3, victim = "Baz", place = "bg", class = "MAGE" },
          { at = 4, bgWin = true, mapId = 1454 },
        },
      },
    })
    local row = list[1]
    assert.are.same(
      { "c1", "Ann", "Hunt", "+50 pts", "12 min ago" },
      { row.id, row.who, row.mission, row.points, row.when }
    )
    assert.are.equal(
      "10 of 10 kills \194\183 8 of 8 classes \194\183 4 of 4 races \194\183 1 without a known class",
      row.summary
    )
    assert.are.same({ "t1", "Zed", "Orgrimmar", "Warrior \194\183 Orc", false }, {
      row.evidence[1].time,
      row.evidence[1].victim,
      row.evidence[1].zone,
      row.evidence[1].info,
      row.evidence[1].unknown,
    })
    assert.are.same(
      { "Zone 99", "Unknown class", true },
      { row.evidence[2].zone, row.evidence[2].info, row.evidence[2].unknown }
    )
    assert.are.same({ "Battleground", "Mage" }, { row.evidence[3].zone, row.evidence[3].info })
    assert.are.same(
      { "-", "Battleground win", false },
      { row.evidence[4].victim, row.evidence[4].info, row.evidence[4].unknown }
    )
    assert.is_nil(row.more)
    assert.is_nil(row.note)
  end)

  it("reads a duel claim as duels won, its evidence rows as duel wins and not as an unknown class", function()
    missions.d1 = { id = "d1", title = "Duelist", points = 20, goal = { kind = "duel_wins" } }
    local row = rows({
      {
        id = "c9",
        player = "Ann",
        missionId = "d1",
        at = T0,
        summary = { done = 3, total = 3 },
        evidence = { { at = 1, victim = "Zed", mapId = 1454, duel = true } },
      },
    })[1]
    assert.are.equal("3 of 3 duels won", row.summary)
    assert.are.same({ "t1", "Zed", "Orgrimmar", "Duel win", false }, {
      row.evidence[1].time,
      row.evidence[1].victim,
      row.evidence[1].zone,
      row.evidence[1].info,
      row.evidence[1].unknown,
    })
    missions.d1 = nil
  end)

  it("cuts a long evidence list and says how many more there are", function()
    local evidence = {}
    for index = 1, 20 do
      evidence[index] = { at = index, victim = "V" .. index, place = "world", class = "MAGE" }
    end
    local row = rows({ { id = "c", player = "A", missionId = "m1", at = T0, evidence = evidence } })[1]
    assert.are.equal(8, #row.evidence)
    assert.are.equal("and 12 more", row.more)
  end)

  it("shows the note of a manual claim and survives a mission that is gone", function()
    local row =
      rows({ { id = "c", player = "A|", missionId = "gone", at = T0, note = "see |cffff0000", summary = {} } })[1]
    assert.are.same({ "Manual mission", "?", "", "A||", "see ||cffff0000" }, {
      row.summary,
      row.mission,
      row.points,
      row.who,
      row.note,
    })
    assert.are.same({}, row.evidence)
  end)

  it("names a race token it knows and shows the token it does not", function()
    assert.are.equal("Undead", ViewModel.PvPRaceText("Scourge"))
    assert.are.equal("Zandalari", ViewModel.PvPRaceText("Zandalari"))
  end)
end)

describe("ViewModel closing, deliveries and history", function()
  it("warns about the claims that expire when the season closes", function()
    local with = ViewModel.PvPCloseWarning(3)
    assert.is_truthy(with:find("3 claim(s) are still pending", 1, true))
    assert.is_truthy(with:find("The ranking is frozen", 1, true))
    assert.is_nil(ViewModel.PvPCloseWarning(0):find("pending", 1, true))
  end)

  local deliveries = {
    {
      pos = 1,
      player = "A",
      tier = "1",
      rewards = { { kind = "gold", amount = 500 } },
      delivered = true,
      updatedBy = "GM",
      updatedAt = T0,
    },
    { pos = 2, player = "B", tier = "2", rewards = {}, delivered = false },
    { pos = 7, player = "C", tier = "7-10", rewards = { { kind = "gold", amount = 1 } }, delivered = true },
  }

  it("lists the deliveries with who delivered and when, and counts them", function()
    local data = ViewModel.PvPDeliveryRows(deliveries, utc)
    assert.are.equal(2, data.delivered)
    assert.are.equal(3, data.total)
    local first, second, third = data.rows[1], data.rows[2], data.rows[3]
    assert.are.same({ "gold", "1st", "500 gold", "Delivered \194\183 GM \194\183 20 Oct" }, {
      first.positionToken,
      first.tier.text,
      first.reward,
      first.delivered,
    })
    assert.are.same({ "-", nil, "B" }, { second.reward, second.delivered, second.raw })
    assert.are.equal("Delivered", third.delivered)
  end)

  it("writes the header of a closed season", function()
    local text = ViewModel.PvPDeliveryHeader({ closedAt = T0 }, 7, 10, utc)
    assert.are.equal("Closed on 20 Oct, 7 of 10 delivered", text)
  end)

  local final = {
    seasonId = "s1",
    name = "Summer",
    startsAt = T0 - 90 * DAY,
    endsAt = T0,
    closedAt = T0 + DAY,
    standings = {
      { pos = 1, player = "A", points = 640, lastAt = 1 },
      { pos = 2, player = "B", points = 590, lastAt = 1 },
      { pos = 3, player = "C", points = 512, lastAt = 1 },
      { pos = 4, player = "D", points = 100, lastAt = 1 },
    },
    prizes = {},
  }

  it("offers the closed seasons to choose from", function()
    assert.are.same({ { value = "s1", text = "Summer" } }, ViewModel.PvPFinalChoices({ final }))
  end)

  it("makes a card per closed season with a podium and the delivery progress", function()
    local cards = ViewModel.PvPHistoryCards({ final }, function()
      return deliveries
    end, utc)
    local card = cards[1]
    assert.are.same({ "s1", "Summer", "22 Jul \226\128\147 20 Oct" }, { card.seasonId, card.name, card.dates })
    assert.are.equal(3, #card.podium)
    assert.are.same({ "#1", "gold", "A", "640 pts" }, {
      card.podium[1].pos,
      card.podium[1].token,
      card.podium[1].name,
      card.podium[1].points,
    })
    assert.are.same({ "Deliveries 2 / 3", "warning" }, { card.delivery.text, card.delivery.color })
  end)

  it("marks the deliveries as done when all of them are, and has none when nothing was won", function()
    local done = ViewModel.PvPHistoryCards({ final }, function()
      return { { pos = 1, player = "A", tier = "1", rewards = {}, delivered = true } }
    end, utc)[1]
    assert.are.same({ "Deliveries 1 / 1", "success" }, { done.delivery.text, done.delivery.color })
    local none = ViewModel.PvPHistoryCards({ final }, function()
      return {}
    end, utc)[1]
    assert.is_nil(none.delivery)
  end)

  it("lists the full final standing with the tier of each position", function()
    local rows = ViewModel.PvPFinalRows(final)
    assert.are.same({ 4, "4th-6th", "100" }, { rows[4].pos, rows[4].tier.text, rows[4].points })
    assert.are.same({ "1st", "gold" }, { rows[1].tier.text, rows[1].positionToken })
  end)

  it("rows the cumulative ranking and flags the own row", function()
    local rows = ViewModel.PvPCumulativeRows({
      { pos = 1, player = "A", points = 1000, seasons = 2, podiums = 2 },
      { pos = 2, player = "Me", points = 662, seasons = 2, podiums = 1 },
    }, "Me")
    assert.are.same(
      { "A", "2", "2", "1000", false },
      { rows[1].name, rows[1].seasons, rows[1].podiums, rows[1].points, rows[1].mine }
    )
    assert.is_true(rows[2].mine)
  end)

  it("formats a short date", function()
    assert.are.equal("20 Oct", ViewModel.PvPShortDate(T0, utc))
  end)
end)

describe("ViewModel.PvPSubTabs with the Intel module off", function()
  local db
  before_each(function()
    db = { global = {} }
    ns.modules = ns.ModuleService.New({
      db = function()
        return db
      end,
    })
  end)
  after_each(function()
    ns.modules = nil
  end)

  it("drops the Intel sub-tab and keeps the others", function()
    ns.modules:SetEnabled("intel", false)
    assert.are.same({ "season", "missions", "stats", "feed", "history" }, values(ViewModel.PvPSubTabs()))
  end)
end)
