-- Intel reports: the session counters, the season figures and the lines.
local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelReport",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

local function build()
  local env =
    { clock = 1000, wall = 5000000, intel = { players = {}, kos = {}, ignore = {}, zones = {} }, guildKos = {} }
  env.service = ns.IntelService.New({
    intel = env.intel,
    guildKos = env.guildKos,
    settings = function()
      return { removeMinutes = 5 }
    end,
    now = function()
      return env.clock
    end,
    wall = function()
      return env.wall
    end,
  })
  return env
end

local function see(env, name, map, times)
  for _ = 1, times or 1 do
    env.service:OnSeen({ name = name, level = 60 }, { map = map })
    env.service:ClearNearby()
  end
end

describe("IntelReport.Session", function()
  it("is empty at the start", function()
    local report = ns.IntelReport.Session(build().service)
    assert.are.equal("session", report.scope)
    assert.are.same({ 0, 0, 0, 0 }, { report.contacts, report.wins, report.losses, report.newKos })
    assert.is_nil(report.mostSeen)
    assert.is_nil(report.nemesis)
    assert.is_nil(report.hottestZone)
  end)

  it("gives the contacts, results, most seen enemy, nemesis and hottest zone", function()
    local env = build()
    see(env, "Bob", 1411, 3)
    see(env, "Eve", 1411, 1)
    see(env, "Una", 1412, 1)
    env.service:OnWin("Eve")
    env.service:OnLoss("Una")
    env.service:OnLoss("Una")
    env.service:OnLoss("Bob")
    env.service:AddKos({ name = "Una" })
    local report = ns.IntelReport.Session(env.service)
    assert.are.same({ 5, 1, 3, 1 }, { report.contacts, report.wins, report.losses, report.newKos })
    assert.are.same({ name = "Bob", count = 3 }, report.mostSeen)
    assert.are.same({ name = "Una", count = 2 }, report.nemesis)
    assert.are.same({ map = 1411, count = 4 }, { map = report.hottestZone.map, count = report.hottestZone.count })
  end)

  it("breaks a tie by name", function()
    local env = build()
    see(env, "Zed", 1, 1)
    see(env, "Abe", 1, 1)
    assert.are.equal("Abe", ns.IntelReport.Session(env.service).mostSeen.name)
  end)
end)

describe("IntelReport.Season", function()
  local season = { name = "Season 1", startsAt = 4000000, endsAt = 6000000 }

  it("counts the players last seen inside the season", function()
    local env = build()
    see(env, "Bob", 1411, 2)
    see(env, "Eve", 1412, 1)
    env.service:OnWin("Bob")
    env.service:OnLoss("Eve")
    env.service:OnLoss("Eve")
    env.wall = 9000000
    see(env, "Late", 1411, 1)
    env.intel.players.old = { name = "Old", lastSeen = 1, seen = 9, wins = 9, losses = 9, lastMap = 5 }
    env.intel.players.broken = { name = "Broken" }
    env.service:AddKos({ name = "Bob" })
    env.intel.kos.bob.addedAt = 5000000
    env.guildKos.eve = { name = "Eve", addedAt = 5500000 }
    env.guildKos.zed = { name = "Zed", addedAt = 1 }
    local report = env.service and ns.IntelReport.Season(env.service, season)
    assert.are.equal("season", report.scope)
    assert.is_true(report.approximate)
    assert.are.same({ 2, 1, 2, 2 }, { report.contacts, report.wins, report.losses, report.newKos })
    assert.are.same({ name = "Bob", count = 2 }, report.mostSeen)
    assert.are.same({ name = "Eve", count = 2 }, report.nemesis)
    assert.are.equal(1, report.hottestZone.count)
  end)

  it("refuses something that is not a season", function()
    assert.are.same({ nil, "no_season" }, { ns.IntelReport.Season(build().service, nil) })
    assert.are.same({ nil, "no_season" }, { ns.IntelReport.Season(build().service, { name = "x" }) })
  end)
end)

describe("IntelReport.Lines", function()
  it("writes the session report with the highlights", function()
    local env = build()
    see(env, "Bob", 1411, 2)
    env.service:OnLoss("Bob")
    local lines = ns.IntelReport.Lines(ns.IntelReport.Session(env.service), function(map)
      return map == 1411 and "Durotar" or nil
    end)
    assert.are.same({
      "Intel report of this session",
      "Enemy players met: 2. Wins: 0. Losses: 1. New Kill on Sight: 0.",
      "Most seen: Bob (2 times)",
      "Nemesis: Bob (1 losses)",
      "Hottest zone: Durotar (2 contacts)",
    }, lines)
  end)

  it("names an unknown map by its number and notes that a season report is approximate", function()
    local env = build()
    see(env, "Bob", 1411, 1)
    local report = ns.IntelReport.Season(env.service, { name = "Season|1", startsAt = 1, endsAt = 9000000 })
    local lines = ns.IntelReport.Lines(report)
    assert.are.equal("Intel report of the season 'Season1'", lines[1])
    assert.are.equal("Hottest zone: map 1411 (1 contacts)", lines[#lines - 1])
    assert.is_truthy(lines[#lines]:find("keep no seasons", 1, true))
  end)

  it("writes the report in Spanish", function()
    ns.Locale.Use("esES")
    local lines = ns.IntelReport.Lines(ns.IntelReport.Session(build().service))
    ns.Locale.Use("enUS")
    assert.are.equal("Informe de Intel de esta sesión", lines[1])
    assert.are.equal("Enemigos vistos: 0. Victorias: 0. Derrotas: 0. Nuevos de Muerte a la vista: 0.", lines[2])
  end)
end)
