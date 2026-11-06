-- ViewModelIntel: the rows of every Intel list, the menu of a row, what its choices do and the settings card. Pure
-- functions: plain data in, plain data out.
local function load_view_model(locale)
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/GuildKosService",
    "Domain/IntelReport",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelIntel",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
    if path == "Locales/esES" and locale then
      ns.Locale.Use(locale)
    end
  end
  return ns.ViewModel, ns
end

local ViewModel, ns = load_view_model()

local function values(items)
  local list = {}
  for _, item in ipairs(items) do
    list[#list + 1] = item.value
  end
  return list
end

-- A service with a settable clock.
local function new_service(overrides)
  local env = { now = 1000, wall = 100000, delay = 5 }
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  env.intel = { players = {}, kos = {}, ignore = {}, zones = {} }
  env.guildKos = {}
  env.service = ns.IntelService.New({
    intel = env.intel,
    guildKos = env.guildKos,
    settings = function()
      return { removeMinutes = env.delay }
    end,
    now = function()
      return env.now
    end,
    wall = function()
      return env.wall
    end,
  })
  return env
end

local function seen(env, name, extra)
  local details = { name = name, class = "MAGE", race = "HUMAN", level = 60, guild = "Wolves" }
  for key, value in pairs(extra or {}) do
    details[key] = value
  end
  return env.service:OnSeen(details, { map = 1, x = 10, y = 20 })
end

describe("ViewModel.IntelViews", function()
  it("lists the six views in order, and the four modes of the window", function()
    assert.are.same({ "nearby", "hour", "kos", "ignored", "stats", "report" }, values(ViewModel.IntelViews()))
    assert.are.same({ "nearby", "hour", "ignored", "kos" }, values(ViewModel.IntelWindowModes()))
  end)
end)

describe("text of a row", function()
  it("writes the age in the shortest form", function()
    assert.are.equal("0s", ViewModel.IntelAge(0))
    assert.are.equal("0s", ViewModel.IntelAge(-5))
    assert.are.equal("59s", ViewModel.IntelAge(59.9))
    assert.are.equal("1m", ViewModel.IntelAge(60))
    assert.are.equal("59m", ViewModel.IntelAge(3599))
    assert.are.equal("2h", ViewModel.IntelAge(7300))
    assert.are.equal("?", ViewModel.IntelAge(nil))
    assert.are.equal("?", ViewModel.IntelAge(0 / 0))
  end)

  it("marks an estimated level and an unknown one", function()
    assert.are.equal("60", ViewModel.IntelLevel(60))
    assert.are.equal("70?", ViewModel.IntelLevel(70, true))
    assert.are.equal("??", ViewModel.IntelLevel(nil))
    assert.are.equal("??", ViewModel.IntelLevel(0))
  end)

  it("names the categories and gives them as choices", function()
    assert.are.equal("Gank", ViewModel.IntelCategoryName("gank"))
    assert.are.equal("Other", ViewModel.IntelCategoryName("nonsense"))
    assert.are.same(ns.Constants.INTEL_KOS_CATEGORIES, values(ViewModel.IntelCategoryChoices()))
  end)

  it("badges the scope of a Kill on Sight entry", function()
    assert.are.equal("Guild", ViewModel.IntelKosBadge("guild").text)
    assert.are.equal("danger", ViewModel.IntelKosBadge("guild").color)
    assert.are.equal("Mine", ViewModel.IntelKosBadge("personal").text)
    assert.is_nil(ViewModel.IntelKosBadge(nil))
  end)

  it("builds a row with escaped text and the short name of the reporter", function()
    local row = ViewModel.IntelRow({
      key = "ann",
      name = "Ann",
      class = "MAGE",
      race = "HUMAN",
      level = 70,
      levelEstimated = true,
      guild = "Wolf|cffff0000s",
      faded = true,
      kos = "guild",
      stealth = true,
      source = "Bob-Realm",
      wins = 2,
      losses = 1,
    }, 125)
    assert.are.equal("Ann", row.name)
    assert.are.equal("Mage", row.classText)
    assert.are.equal("70?", row.levelText)
    assert.are.equal("Wolfcffff0000s", row.guild)
    assert.are.equal("<Wolfcffff0000s>", row.guildText)
    assert.are.equal("2m", row.ageText)
    assert.is_true(row.faded)
    assert.are.equal("guild", row.kos)
    assert.are.equal("Bob", row.sourceText)
    assert.is_false(row.ignored)
  end)

  it("builds a row with nothing known", function()
    local row = ViewModel.IntelRow({ key = "x", name = "X|y" }, nil)
    assert.are.equal("X||y", row.nameText)
    assert.are.equal("??", row.levelText)
    assert.are.equal("", row.guildText)
    assert.are.equal("", row.ageText)
    assert.is_nil(row.classText)
    assert.is_nil(row.sourceText)
  end)
end)

describe("the lists", function()
  it("gives the rows of who is nearby, of the last hour and of the Ignore list", function()
    local env = new_service()
    seen(env, "Ann")
    env.now = 1030
    local nearby = ViewModel.IntelNearbyRows(env.service:Nearby(env.now))
    assert.are.equal(1, #nearby)
    assert.are.equal("30s", nearby[1].ageText)

    local hour = ViewModel.IntelHourRows(env.service:LastHour(env.wall + 90), env.wall + 90)
    assert.are.equal("1m", hour[1].ageText)

    env.service:AddIgnore("Zed")
    local ignored = ViewModel.IntelIgnoreRows(env.service:IgnoreList(), function(at)
      return "d" .. at
    end)
    assert.are.equal("Zed", ignored[1].name)
    assert.are.equal("d100000", ignored[1].added)
    assert.is_true(ignored[1].ignored)
    assert.are.equal("", ViewModel.IntelIgnoreRows({ { key = "k", name = "K" } })[1].added)
  end)

  it("lists both Kill on Sight lists by name and tells what the player may do", function()
    local env = new_service()
    env.service:AddKos({ name = "Bob", category = "gank", reason = "ganked me" })
    env.service:AddKos({ name = "Ann" })
    env.guildKos.ann = { name = "Ann", category = "camp", addedBy = "Cid-Realm", addedAt = 5, rev = 1 }
    env.guildKos.dan = { name = "Dan", category = "other", addedBy = "Me-Realm", addedAt = 6, rev = 1 }
    local ctx = { role = "member", actor = "Me-Realm", formatDate = tostring }
    local rows = ViewModel.IntelKosRows(env.service, ctx)
    local order = {}
    for _, row in ipairs(rows) do
      order[#order + 1] = row.scope .. ":" .. row.key
    end
    assert.are.same({ "personal:ann", "guild:ann", "personal:bob", "guild:dan" }, order)

    local personalAnn, guildAnn, personalBob, guildDan = rows[1], rows[2], rows[3], rows[4]
    assert.is_true(personalAnn.canEdit and personalAnn.canRemove)
    assert.is_false(personalAnn.canPromote) -- she is on the guild list already
    assert.is_true(personalBob.canPromote)
    assert.are.equal("ganked me", personalBob.reasonText)
    assert.are.equal("Gank", personalBob.categoryText)
    assert.are.equal("You", personalBob.author)
    -- Somebody else's guild entry: a member can neither edit nor remove it. His own, he can.
    assert.is_false(guildAnn.canEdit)
    assert.is_false(guildAnn.canRemove)
    assert.are.equal("Cid", guildAnn.author)
    assert.is_true(guildDan.canEdit and guildDan.canRemove)
    assert.is_false(guildDan.canPromote)
    assert.are.equal("Guild", guildDan.badge.text)

    -- An officer can change any entry.
    local gm = ViewModel.IntelKosRows(env.service, { role = "gm", actor = "Boss-Realm" })
    assert.is_true(gm[2].canEdit and gm[2].canRemove)
    assert.are.equal("", gm[2].added)
  end)

  it("cuts the statistics and gives the figures of each player", function()
    local list = {}
    for index = 1, ViewModel.INTEL_STATS_LIMIT + 5 do
      list[index] = { key = "k" .. index, name = "P" .. index, lastSeen = 900, wins = 1, seen = 3 }
    end
    local data = ViewModel.IntelStatsRows(list, 1000, function(at)
      return "date" .. at
    end)
    assert.are.equal(ViewModel.INTEL_STATS_LIMIT, data.shown)
    assert.are.equal(ViewModel.INTEL_STATS_LIMIT + 5, data.total)
    assert.are.equal("date900", data.rows[1].lastSeenText)
    assert.are.equal("1m", data.rows[1].agoText)
    assert.are.equal(1, data.rows[1].wins)
    assert.are.equal(0, data.rows[1].losses)
    assert.are.equal(3, data.rows[1].seen)
    assert.are.equal(
      "900",
      ViewModel.IntelStatsRows({ { key = "a", name = "A", lastSeen = 900 } }, 1000).rows[1].lastSeenText
    )
  end)

  it("turns the filters of the tab into the filters of the service", function()
    assert.are.same(
      { text = "ab", kos = true, wins = false, losses = true, category = "gank" },
      ViewModel.IntelStatsFilter({ text = "ab", kos = true, losses = true, category = "gank" })
    )
    assert.is_nil(ViewModel.IntelStatsFilter({ category = "any" }).category)
    assert.is_nil(ViewModel.IntelStatsFilter({}).category)
    assert.are.same({ "kos", "wins", "losses" }, values(ViewModel.IntelStatsFilters()))
    assert.are.equal("any", ViewModel.IntelStatsCategoryChoices()[1].value)
    assert.are.equal(7, #ViewModel.IntelStatsCategoryChoices())
  end)

  it("sums the wins and losses for the figures over the statistics", function()
    local env = new_service()
    seen(env, "Ann")
    env.service:OnWin("Ann")
    env.service:OnWin("Bob")
    env.service:OnLoss("Ann")
    env.intel.players.broken = "not a record"
    env.intel.players.hurt = { wins = "x" }
    local stats = ViewModel.IntelStatsSummary(env.service, 12)
    assert.are.equal("Enemies met", stats[1].caption)
    assert.are.equal("2", stats[1].value)
    assert.are.equal("2", stats[2].value)
    assert.are.equal("1", stats[3].value)
    assert.are.equal("danger", stats[3].color)
    assert.are.equal("12", stats[4].value)
    local without = ViewModel.IntelStatsSummary(new_service().service, nil)
    assert.are.equal("-", without[4].value)
    assert.are.equal("muted", without[4].color)
    assert.is_nil(without[3].color)
  end)

  it("makes a card for the session and one for the season", function()
    local env = new_service()
    seen(env, "Ann")
    env.service:OnWin("Ann")
    local session = ns.IntelReport.Session(env.service)
    local cards = ViewModel.IntelReportCards(session, nil)
    assert.are.equal("Intel report of this session", cards[1].title)
    assert.are.equal("1", cards[1].stats[1].value)
    assert.are.equal("1", cards[1].stats[2].value)
    assert.are.equal("Season", cards[2].title)
    assert.are.same({ "no PvP season is running." }, cards[2].lines)
    assert.are.equal(0, #cards[2].stats)

    local season = ns.IntelReport.Season(env.service, { name = "S1", startsAt = 0, endsAt = 10 ^ 9 })
    local withSeason = ViewModel.IntelReportCards(session, season)
    assert.are.equal("Intel report of the season 'S1'", withSeason[2].title)
    assert.are.equal(4, #withSeason[2].stats)
  end)
end)

describe("ViewModel.IntelWindowView", function()
  it("draws each list of the window, limited to the rows it has", function()
    local env = new_service()
    seen(env, "Ann")
    seen(env, "Bob")
    seen(env, "Cid")
    env.service:AddIgnore("Zed")
    env.service:AddKos({ name = "Dan", category = "camp" })
    local ctx = {
      service = env.service,
      nearby = env.service:Nearby(env.now),
      now = env.wall,
      limit = 2,
      role = "member",
      actor = "Me-Realm",
    }
    local nearby = ViewModel.IntelWindowView("nearby", ctx)
    assert.are.equal(2, #nearby.rows)
    assert.are.equal(1, nearby.more)
    assert.are.equal(3, nearby.total)
    assert.are.equal("Nobody nearby.", nearby.empty)

    ctx.limit = 8
    assert.are.equal(3, #ViewModel.IntelWindowView("hour", ctx).rows)
    local ignored = ViewModel.IntelWindowView("ignored", ctx)
    assert.are.equal("Zed", ignored.rows[1].name)
    assert.are.equal("Nobody is ignored.", ignored.empty)
    local kos = ViewModel.IntelWindowView("kos", ctx)
    assert.are.equal("Dan", kos.rows[1].name)
    assert.are.equal("Mine", kos.rows[1].guildText)
    assert.are.equal("Camper", kos.rows[1].ageText)
    -- A mode nobody knows shows who is nearby.
    assert.are.equal(3, #ViewModel.IntelWindowView("other", ctx).rows)
  end)
end)

describe("ViewModel.IntelClick", function()
  it("follows the Spy controls", function()
    assert.are.equal("target", ViewModel.IntelClick("LeftButton", false, false))
    assert.are.equal("kos", ViewModel.IntelClick("LeftButton", true, false))
    assert.are.equal("kos", ViewModel.IntelClick("LeftButton", true, true))
    assert.are.equal("ignore", ViewModel.IntelClick("LeftButton", false, true))
    assert.are.equal("menu", ViewModel.IntelClick("RightButton", true, true))
    assert.is_nil(ViewModel.IntelClick("MiddleButton", false, false))
  end)
end)

describe("ViewModel.IntelMenu", function()
  local function by_value(items)
    local map = {}
    for _, item in ipairs(items) do
      map[item.value] = item
    end
    return map
  end

  it("offers the actions of a player nearby", function()
    local items = ViewModel.IntelMenu({ name = "Ann", key = "ann" }, { role = "member", actor = "Me-Realm" })
    local map = by_value(items)
    assert.are.equal("Remove from the list", map.remove.text)
    assert.are.equal("Add to my Kill on Sight", map.kos.text)
    assert.are.equal("Ignore", map.ignore.text)
    assert.is_true(map["-guild"].disabled)
    assert.is_nil(map["gkos:gank"].disabled or nil)
    assert.is_nil(map.gremove)
    -- No group, no raid: only the channels that can work are enabled.
    assert.is_true(map["say:party"].disabled)
    assert.is_true(map["say:raid"].disabled)
    assert.is_nil(map["say:guild"].disabled or nil)
    assert.is_nil(map["say:self"].disabled or nil)
    assert.is_nil(map["say:localdefense"].disabled or nil)
    for _, category in ipairs(ns.Constants.INTEL_KOS_CATEGORIES) do
      assert.is_truthy(map["gkos:" .. category])
    end
  end)

  it("follows the group, the guild and the lists of the player", function()
    local ctx = { role = "member", actor = "Me-Realm", group = "PARTY", inGuild = false }
    local map = by_value(ViewModel.IntelMenu({ name = "Ann", kos = "personal", ignored = true }, ctx))
    assert.are.equal("Remove from my Kill on Sight", map.kos.text)
    assert.are.equal("Stop ignoring", map.ignore.text)
    assert.is_nil(map.remove) -- an ignored player is not in Nearby
    assert.is_nil(map["say:party"].disabled or nil)
    assert.is_true(map["say:raid"].disabled)
    assert.is_true(map["say:guild"].disabled)
    ctx.group = "RAID"
    assert.is_nil(by_value(ViewModel.IntelMenu({ name = "Ann" }, ctx))["say:raid"].disabled or nil)
    ctx.group = "INSTANCE_CHAT"
    assert.is_nil(by_value(ViewModel.IntelMenu({ name = "Ann" }, ctx))["say:raid"].disabled or nil)
  end)

  it("lets only the author or an officer change a guild entry", function()
    local entry = { addedBy = "Cid-Realm", rev = 1 }
    local member =
      by_value(ViewModel.IntelMenu({ name = "Ann" }, { role = "member", actor = "Me-Realm", guildEntry = entry }))
    assert.is_true(member["gkos:gank"].disabled)
    assert.is_nil(member.gremove)
    local author =
      by_value(ViewModel.IntelMenu({ name = "Ann" }, { role = "member", actor = "Cid-Realm", guildEntry = entry }))
    assert.is_nil(author["gkos:gank"].disabled or nil)
    assert.is_truthy(author.gremove)
    local gm =
      by_value(ViewModel.IntelMenu({ name = "Ann" }, { role = "gm", actor = "Boss-Realm", guildEntry = entry }))
    assert.is_truthy(gm.gremove)
  end)
end)

describe("ViewModel.IntelRun", function()
  local calls, deps

  before_each(function()
    calls = {}
    local function record(name)
      return function(_, ...)
        calls[#calls + 1] = { name, ... }
        return { name }
      end
    end
    deps = {
      commands = {
        KosAdd = record("KosAdd"),
        KosRemove = record("KosRemove"),
        GuildAdd = record("GuildAdd"),
        GuildRemove = record("GuildRemove"),
        IgnoreAdd = record("IgnoreAdd"),
        IgnoreRemove = record("IgnoreRemove"),
        Changed = record("Changed"),
      },
      service = {
        RemoveNearby = function(_, key)
          calls[#calls + 1] = { "RemoveNearby", key }
        end,
      },
      directory = {
        Remove = function(_, key)
          calls[#calls + 1] = { "Remove", key }
        end,
      },
      alerts = {
        AnnounceNow = function(_, name, channel)
          calls[#calls + 1] = { "AnnounceNow", name, channel }
          return channel ~= "party", "no_group"
        end,
      },
    }
  end)

  it("takes a player out of Nearby and out of the shared sightings", function()
    assert.are.same({}, ViewModel.IntelRun("remove", { name = "Ann", key = "ann" }, deps))
    assert.are.same({ { "RemoveNearby", "ann" }, { "Remove", "ann" }, { "Changed" } }, calls)
    deps.directory = nil
    ViewModel.IntelRun("remove", { name = "Ann", key = "ann" }, deps)
  end)

  it("toggles the personal Kill on Sight mark and Ignore", function()
    ViewModel.IntelRun("kos", { name = "Ann" }, deps)
    ViewModel.IntelRun("kos", { name = "Ann", kos = "guild" }, deps)
    ViewModel.IntelRun("kos", { name = "Ann", kos = "personal" }, deps)
    ViewModel.IntelRun("ignore", { name = "Ann" }, deps)
    ViewModel.IntelRun("ignore", { name = "Ann", ignored = true }, deps)
    local names = {}
    for _, call in ipairs(calls) do
      names[#names + 1] = call[1]
    end
    assert.are.same({ "KosAdd", "KosAdd", "KosRemove", "IgnoreAdd", "IgnoreRemove" }, names)
  end)

  it("adds to and removes from the guild list", function()
    ViewModel.IntelRun("gkos:camp", { name = "Ann" }, deps)
    assert.are.same({ "GuildAdd", "Ann", "camp", nil }, calls[1])
    ViewModel.IntelRun("gremove", { name = "Ann" }, deps)
    assert.are.same({ "GuildRemove", "Ann" }, calls[2])
  end)

  it("announces from the click, and says why it could not", function()
    assert.are.same({}, ViewModel.IntelRun("say:localdefense", { name = "Ann" }, deps))
    assert.are.same({ "AnnounceNow", "Ann", "localdefense" }, calls[1])
    local refused = ViewModel.IntelRun("say:party", { name = "Ann" }, deps)
    assert.is_true(ns.Validate.IsFailure(refused))
    assert.are.equal("you are not in a group for that.", refused[1])
    deps.alerts.AnnounceNow = function()
      return false, "odd"
    end
    assert.are.equal("odd", ViewModel.IntelRun("say:guild", { name = "Ann" }, deps)[1])
  end)

  it("does nothing for what it does not know", function()
    assert.are.same({}, ViewModel.IntelRun("nonsense", { name = "Ann" }, deps))
    assert.are.same({}, ViewModel.IntelRun(nil, { name = "Ann" }, deps))
    assert.are.same({}, ViewModel.IntelRun("kos", nil, deps))
    assert.are.same({}, ViewModel.IntelRun("kos", { name = 5 }, deps))
    assert.are.same(0, #calls)
  end)
end)

describe("the settings", function()
  local function settings()
    return ns.Settings and ns.Settings.Intel({ global = {} })
  end

  local function fresh()
    assert(loadfile("NrageAssistant/Domain/Settings.lua"))("NrageAssistant", ns)
    return settings()
  end

  it("lists every setting of the plan in five groups", function()
    local current = fresh()
    local groups = ViewModel.IntelSettingsGroups(current, { mapId = 1429, mapName = "Elwynn" })
    local titles, keys = {}, {}
    for _, group in ipairs(groups) do
      titles[#titles + 1] = group.title
      for _, item in ipairs(group.items) do
        keys[item.key] = item
      end
    end
    assert.are.same({ "Detection", "Alerts", "Sharing", "Maps", "Window" }, titles)
    for _, key in ipairs({
      "enabled",
      "share",
      "removeMinutes",
      "sound",
      "alertNew",
      "alertKos",
      "alertKosGuild",
      "alertStealth",
      "alertRaces",
      "alertGuildReports",
      "warnTarget",
      "announce",
      "inSanctuary",
      "inBattleground",
      "inArena",
      "zone",
      "mapMode",
      "mapFollow",
      "minimapTooltip",
      "minimapFeed",
      "window.shown",
      "window.locked",
      "window.rows",
      "targetButton",
    }) do
      assert.is_truthy(keys[key], key)
    end
    assert.are.equal("Elwynn", keys.zone.description)
    assert.is_false(keys.zone.value)
    assert.is_true(keys.enabled.value)
    assert.are.equal(10, #keys.alertRaces.choices)
    assert.are.equal("Human", keys.alertRaces.choices[1].text)
  end)

  it("shows the zone, the usual choices and a value that is not usual", function()
    local current = fresh()
    current.excludedZones[1429] = true
    current.alertRaces.ORC = true
    current.removeMinutes = 4
    current.window.rows = 5
    local groups = ViewModel.IntelSettingsGroups(current, { mapId = 1429 })
    local keys = {}
    for _, group in ipairs(groups) do
      for _, item in ipairs(group.items) do
        keys[item.key] = item
      end
    end
    assert.are.equal("map 1429", keys.zone.description)
    assert.is_true(keys.zone.value)
    assert.is_true(keys.alertRaces.choices[6].active)
    local minutes = {}
    for _, choice in ipairs(keys.removeMinutes.choices) do
      minutes[#minutes + 1] = choice.text
    end
    assert.are.same({ "Never", "1 min", "2 min", "3 min", "4 min", "5 min", "10 min", "15 min" }, minutes)
    assert.are.same({ 4, 5, 6, 8, 10, 12, 15, 20 }, values(keys["window.rows"].choices))

    local unknown = ViewModel.IntelSettingsGroups(current, {})
    assert.is_true(unknown[1].items[5].disabled)
    assert.is_false(unknown[1].items[5].value)
    assert.is_nil(unknown[1].items[5].description)

    -- The zones that are skipped are listed by name, in order, and only when there are any.
    assert.is_nil(keys.excludedZones.choices[2])
    current.excludedZones[1411] = true
    local named = ViewModel.IntelSettingsGroups(current, {
      zoneName = function(map)
        return map == 1411 and "Durotar" or nil
      end,
    })
    local zones
    for _, item in ipairs(named[1].items) do
      if item.key == "excludedZones" then
        zones = item
      end
    end
    assert.are.equal("zones", zones.kind)
    assert.are.same({ 1411, 1429 }, values(zones.choices))
    assert.are.same({ "Durotar", "map 1429" }, { zones.choices[1].text, zones.choices[2].text })
    current.excludedZones = {}
    for _, item in ipairs(ViewModel.IntelSettingsGroups(current, {})[1].items) do
      assert.are_not.equal("excludedZones", item.key)
    end
  end)

  it("applies a valid change and refuses a damaged one", function()
    local current = fresh()
    local apply = ViewModel.IntelApplySetting
    assert.is_true(apply(current, "alertNew", true))
    assert.is_true(current.alertNew)
    assert.are.same({ false, "invalid" }, { apply(current, "alertNew", "yes") })
    assert.is_true(apply(current, "removeMinutes", 10))
    assert.are.equal(10, current.removeMinutes)
    assert.are.same({ false, "invalid" }, { apply(current, "removeMinutes", 7) })
    assert.is_true(apply(current, "warnTarget", "none"))
    assert.are.same({ false, "invalid" }, { apply(current, "warnTarget", "nowhere") })
    assert.is_true(apply(current, "announce", "guild"))
    assert.is_true(apply(current, "mapMode", "continent"))
    assert.are.same({ false, "invalid" }, { apply(current, "nothing", true) })
    assert.are.same({ false, "invalid" }, { apply(current, nil, true) })
  end)

  it("sets the races, the zone and the window", function()
    local current = fresh()
    local apply = ViewModel.IntelApplySetting
    assert.is_true(apply(current, "alertRaces:ORC", true))
    assert.is_true(current.alertRaces.ORC)
    assert.is_true(apply(current, "alertRaces:ORC", false))
    assert.is_nil(current.alertRaces.ORC)
    assert.are.same({ false, "invalid" }, { apply(current, "alertRaces:ELF", true) })
    assert.are.same({ false, "invalid" }, { apply(current, "alertRaces:ORC", "x") })

    assert.is_true(apply(current, "zone", true, { mapId = 1429 }))
    assert.is_true(current.excludedZones[1429])
    assert.is_true(apply(current, "zone", false, { mapId = 1429 }))
    assert.is_nil(current.excludedZones[1429])
    assert.are.same({ false, "invalid" }, { apply(current, "zone", true, {}) })
    assert.are.same({ false, "invalid" }, { apply(current, "zone", 1, { mapId = 1 }) })

    assert.is_true(apply(current, "excludedZone:1429", true))
    assert.is_true(current.excludedZones[1429])
    assert.is_true(apply(current, "excludedZone:1429", false))
    assert.is_nil(current.excludedZones[1429])
    assert.are.same({ false, "invalid" }, { apply(current, "excludedZone:0", true) })
    assert.are.same({ false, "invalid" }, { apply(current, "excludedZone:99999", true) })
    assert.are.same({ false, "invalid" }, { apply(current, "excludedZone:5", "x") })

    assert.is_true(apply(current, "window.shown", false))
    assert.is_false(current.window.shown)
    assert.is_true(apply(current, "window.locked", true))
    assert.is_true(current.window.locked)
    assert.are.same({ false, "invalid" }, { apply(current, "window.locked", 1) })
    assert.is_true(apply(current, "window.rows", 12))
    assert.are.equal(12, current.window.rows)
    assert.are.same({ false, "invalid" }, { apply(current, "window.rows", 21) })
    assert.are.same({ false, "invalid" }, { apply(current, "window.rows", 2.5) })
  end)

  it("refuses to change the rows of the window in combat", function()
    local current = fresh()
    assert.are.same(
      { false, "combat" },
      { ViewModel.IntelApplySetting(current, "window.rows", 6, { inCombat = true }) }
    )
    assert.are.equal(8, current.window.rows)
    assert.are.equal("that cannot change during combat.", ViewModel.INTEL_SETTING_ERRORS.combat)
    -- The rest can change in combat: nothing protected moves.
    assert.is_true(ViewModel.IntelApplySetting(current, "sound", false, { inCombat = true }))
  end)
end)

describe("notices", function()
  it("tells about the nameplates only when they are off and detection is on", function()
    local base = { enabled = true, nameplates = false, inCombat = false }
    local notice = ViewModel.IntelNameplateNotice(base)
    assert.is_truthy(notice.text:find("nameplates", 1, true))
    assert.is_true(notice.canEnable)
    assert.is_false(ViewModel.IntelNameplateNotice({ enabled = true, nameplates = false, inCombat = true }).canEnable)
    assert.is_nil(ViewModel.IntelNameplateNotice({ enabled = true, nameplates = true }))
    assert.is_nil(ViewModel.IntelNameplateNotice({ enabled = true, nameplates = nil }))
    assert.is_nil(ViewModel.IntelNameplateNotice({ enabled = false, nameplates = false }))
  end)

  it("counts the enemies nearby and the Kill on Sight ones for the minimap", function()
    assert.are.same({}, ViewModel.IntelMinimapLines(nil))
    assert.are.same({}, ViewModel.IntelMinimapLines({}))
    local lines = ViewModel.IntelMinimapLines({ { kos = "personal" }, {}, { kos = "guild" } })
    assert.are.same({ "Intel: 3 enemies nearby, 2 Kill on Sight" }, lines)
  end)

  it("colours the warning by the kind of the alert", function()
    assert.are.equal("danger", ViewModel.IntelWarnColor("kos"))
    assert.are.equal("danger", ViewModel.IntelWarnColor("kosGuild"))
    assert.are.equal("warning", ViewModel.IntelWarnColor("stealth"))
    assert.are.equal("info", ViewModel.IntelWarnColor("new"))
    assert.are.equal("info", ViewModel.IntelWarnColor(nil))
  end)

  it("writes the tooltip of a row", function()
    local row = ViewModel.IntelRow({
      key = "ann",
      name = "Ann",
      class = "ROGUE",
      level = 60,
      guild = "Wolves",
      source = "Bob-Realm",
    }, 5)
    local lines = ViewModel.IntelRowTooltip(row, { category = "gank", reason = "ganked me" })
    assert.are.equal("Ann", lines[1].text)
    assert.are.equal("Level 60 Rogue", lines[2].text)
    assert.are.equal("<Wolves>", lines[3].text)
    assert.are.equal("Reported by Bob", lines[4].text)
    assert.are.equal("Kill on Sight: Gank - ganked me", lines[5].text)
    assert.are.equal("Right click: menu.", lines[#lines].text)

    local bare = ViewModel.IntelRowTooltip(ViewModel.IntelRow({ key = "x", name = "X" }, nil), { category = "camp" })
    assert.are.equal("Kill on Sight: Camper", bare[2].text)
    assert.are.equal(4, #bare)
    assert.are.equal(4, #ViewModel.IntelRowTooltip(ViewModel.IntelRow({ key = "x", name = "X", level = 5 }, nil)))
  end)
end)

describe("in Spanish", function()
  it("names the views, the categories and the settings", function()
    local es = load_view_model("esES")
    assert.are.equal("Cercanos", es.IntelViews()[1].text)
    assert.are.equal("Estadísticas", es.IntelViews()[5].text)
    assert.are.equal("Acampador", es.IntelCategoryName("camp"))
    assert.are.equal(
      "Detección",
      es.IntelSettingsGroups({
        enabled = true,
        alertRaces = {},
        excludedZones = {},
        window = { rows = 8 },
      }, {})[1].title
    )
    assert.are.equal(
      "Nivel 60 Mago",
      es.IntelRowTooltip(es.IntelRow({ key = "a", name = "A", class = "MAGE", level = 60 }))[2].text
    )
  end)
end)
