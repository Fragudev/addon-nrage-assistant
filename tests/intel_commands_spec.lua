-- The /nrage intel commands: they turn text into service calls and the answers into lines.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelDetector",
    "Domain/IntelDirectory",
    "Domain/GuildKosService",
    "Domain/IntelAlerts",
    "Domain/IntelReport",
    "Domain/IntelImport",
    "Commands/IntelCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()

local function build(overrides)
  local env = {
    clock = 1000,
    settings = {
      removeMinutes = 5,
      sound = true,
      alertKos = true,
      alertKosGuild = true,
      alertStealth = true,
      alertNew = false,
      alertGuildReports = true,
      alertRaces = {},
      warnTarget = "error",
      announce = "none",
    },
    intel = { players = {}, kos = {}, ignore = {}, zones = {} },
    guildKos = {},
    tombstones = {},
    rank = { "Guild Master", 0 },
    errors = {},
    upserts = {},
    deletes = {},
    changes = 0,
    ui = {},
    sendResult = true,
    hidden = false,
    allowed = true,
    season = nil,
  }
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  env.service = ns.IntelService.New({
    intel = env.intel,
    guildKos = env.guildKos,
    settings = function()
      return env.settings
    end,
    now = function()
      return env.clock
    end,
    wall = function()
      return 5000000
    end,
  })
  env.alerts = ns.IntelAlerts.New({
    settings = function()
      return env.settings
    end,
    service = env.service,
    now = function()
      return env.clock
    end,
    mapId = function()
      return 1411
    end,
    errorText = function(text)
      env.errors[#env.errors + 1] = text
    end,
  })
  env.directory = ns.IntelDirectory.New({
    now = function()
      return env.clock
    end,
  })
  env.detector = ns.IntelDetector.New({
    reader = {
      GetEnemyDetails = function()
        return nil
      end,
    },
    service = env.service,
    now = function()
      return env.clock
    end,
    allowed = function()
      return true
    end,
    where = function()
      return {}
    end,
  })
  env.comm = {
    SendGuildKosUpsert = function(_, key, entry)
      env.upserts[#env.upserts + 1] = { key = key, entry = entry }
      return env.sendResult, "queue full"
    end,
    SendGuildKosDelete = function(_, key)
      env.deletes[#env.deletes + 1] = key
      return env.sendResult, "queue full"
    end,
  }
  env.commands = ns.IntelCommands.New({
    service = env.service,
    detector = env.detector,
    publisher = { sent = 3, drops = { lockdown = 2 } },
    sync = { received = 4, drops = { bad_format = 1 } },
    alerts = env.alerts,
    directory = env.directory,
    platform = {
      GetOwnGuildRank = function()
        return env.rank[1], env.rank[2]
      end,
      GetIdentityKey = function()
        return "Me"
      end,
      ServerTime = function()
        return 5000000
      end,
      EnemyNameplatesEnabled = function()
        return env.nameplates
      end,
    },
    settings = function()
      return env.settings
    end,
    guildKos = env.guildKos,
    tombstones = env.tombstones,
    comm = function()
      return not env.noComm and env.comm or nil
    end,
    onChange = function()
      env.changes = env.changes + 1
    end,
    ui = function()
      return env.ui
    end,
    events = function()
      return { NAME_PLATE_UNIT_ADDED = true, PLAYER_DEAD = false }
    end,
    zone = function()
      return { instance = "none", pvpType = "contested", mapId = 1411 }, env.allowed, env.allowed and nil or "sanctuary"
    end,
    season = function()
      return env.season
    end,
    zoneName = function(map)
      return map == 1411 and "Durotar" or nil
    end,
    globals = function()
      return env.globals or {}
    end,
    toggleMinimap = function()
      env.hidden = not env.hidden
      return env.hidden
    end,
  })
  function env.run(text)
    return env.commands:Run(text)
  end
  return env
end

local function text(lines)
  return table.concat(lines, "\n")
end

describe("/nrage intel", function()
  local env

  before_each(function()
    env = build()
  end)

  it("lists the commands when asked for help or given nothing, and for an unknown word", function()
    assert.is_truthy(text(env.run("")):find("/nrage intel show", 1, true))
    assert.are.same(env.run(""), env.run("help"))
    local lines = env.run("frobnicate now")
    assert.are.equal("unknown Intel command 'frobnicate'.", lines[1])
    assert.is_true(#lines > 3)
  end)

  describe("window hooks", function()
    it("calls the hooks of the interface when they exist", function()
      local called = {}
      for _, name in ipairs({ "IntelShow", "IntelHide", "IntelConfig", "IntelStats" }) do
        env.ui[name] = function()
          called[#called + 1] = name
        end
      end
      assert.are.same({}, env.run("show"))
      assert.are.same({}, env.run("hide"))
      assert.are.same({}, env.run("config"))
      env.run("stats")
      assert.are.same({ "IntelShow", "IntelHide", "IntelConfig", "IntelStats" }, called)
    end)

    it("says clearly when the interface is not there yet", function()
      assert.are.same({ "the Intel window is not available in this version yet." }, env.run("show"))
      assert.are.same({ "the Intel window is not available in this version yet." }, env.run("hide"))
      assert.are.same({ "the Intel settings is not available in this version yet." }, env.run("config"))
      env.commands.deps.ui = nil
      assert.are.same({ "the Intel window is not available in this version yet." }, env.run("show"))
    end)

    it("reports a hook that raises", function()
      env.ui.IntelShow = function()
        error("boom", 0)
      end
      local lines = env.run("show")
      assert.is_truthy(lines[1]:find("failed: boom", 1, true))
    end)
  end)

  describe("clear and reset", function()
    it("clears Nearby and the sightings of the guild", function()
      env.service:OnSeen({ name = "Bob" }, { map = 1411 })
      env.directory:Apply("Ann", { name = "Eve", map = 1411, x = 1, y = 1 })
      assert.are.same({ "Nobody is listed as nearby now." }, env.run("clear"))
      assert.are.equal(0, env.service:Counts().nearby)
      assert.are.same({}, env.directory:List())
      assert.are.equal(1, env.changes)
      assert.is_table(env.intel.players.bob)
    end)

    it("asks for confirmation and keeps the personal lists", function()
      env.service:OnSeen({ name = "Bob" }, { map = 1411 })
      env.service:AddKos({ name = "Eve" })
      env.service:AddIgnore("Una")
      local lines = env.run("reset")
      assert.is_truthy(lines[2]:find("reset confirm", 1, true))
      assert.is_table(env.intel.players.bob)
      assert.are.same({ "Intel records cleared." }, env.run("RESET Confirm"))
      assert.are.same({}, env.intel.players)
      assert.is_table(env.intel.kos.eve)
      assert.is_table(env.intel.ignore.una)
    end)
  end)

  describe("personal Kill On Sight", function()
    it("adds with a category and a reason, or with the default category", function()
      assert.are.same({ "added Bob to your Kill on Sight list." }, env.run("kos Bob"))
      assert.are.equal("other", env.intel.kos.bob.category)
      env.run("kos Eve gank he ganks at the flight path")
      assert.are.equal("gank", env.intel.kos.eve.category)
      assert.are.equal("he ganks at the flight path", env.intel.kos.eve.reason)
      env.run("kos Una just a reason")
      assert.are.equal("other", env.intel.kos.una.category)
      assert.are.equal("just a reason", env.intel.kos.una.reason)
      assert.are.same({ "changed Bob on your Kill on Sight list." }, env.run("kos Bob camp"))
      assert.are.equal("camp", env.intel.kos.bob.category)
    end)

    it("lists, removes and refuses bad input", function()
      assert.are.same({ "your Kill on Sight list is empty." }, env.run("kos"))
      env.run("kos Bob gank reason here")
      local lines = env.run("kos list")
      assert.are.same({ "your Kill on Sight (1):", "  Bob [gank]: reason here" }, lines)
      assert.are.same({ "removed Bob from your Kill on Sight list." }, env.run("kos remove Bob"))
      assert.are.same({ "that player is not on the list." }, env.run("kos remove Bob"))
      assert.are.same({ "that player is not on the list." }, env.run("kos remove"))
      assert.are.same({ "that is not a valid name." }, env.run("kos a:b"))
      env.changes = 0
      env.run("kos Bob")
      assert.are.equal(1, env.changes)
    end)

    it("refuses a reason with a pipe and a list that is full", function()
      assert.are.same({ "the reason cannot contain | or control characters." }, env.run("kos Bob gank a|b"))
      for index = 1, ns.Constants.INTEL_KOS_MAX do
        env.intel.kos["k" .. index] = { name = "K" .. index }
      end
      assert.are.same({ "that list is full." }, env.run("kos Late"))
    end)
  end)

  describe("guild Kill On Sight", function()
    it("adds, sends the entry to the guild and reports a change", function()
      assert.are.same({ "added Bob to the guild Kill on Sight list." }, env.run("kos guild Bob gank near the bridge"))
      assert.are.equal("gank", env.guildKos.bob.category)
      assert.are.equal("Me", env.guildKos.bob.addedBy)
      assert.are.equal("bob", env.upserts[1].key)
      assert.are.equal(1, env.changes)
      assert.are.same({ "changed Bob on the guild Kill on Sight list." }, env.run("kos guild Bob camp"))
      assert.are.equal(2, #env.upserts)
    end)

    it("promotes a player of the personal list with what it holds", function()
      env.run("kos Eve corpse camps my corpse")
      env.run("kos guild Eve")
      assert.are.equal("corpse", env.guildKos.eve.category)
      assert.are.equal("camps my corpse", env.guildKos.eve.reason)
    end)

    it("notes that the entry was saved here but not sent", function()
      env.sendResult = false
      local lines = env.run("kos guild Bob")
      assert.are.equal("saved here, but not sent to the guild (queue full).", lines[2])
      env.noComm = true
      lines = env.run("kos guild Eve")
      assert.are.equal("saved here, but not sent to the guild (no connection).", lines[2])
    end)

    it("lists, removes with a tombstone and tells the guild", function()
      assert.are.same({ "the guild Kill on Sight list is empty." }, env.run("kos guild"))
      env.run("kos guild Bob camp")
      assert.are.same({ "guild Kill on Sight (1):", "  Bob [camp]" }, env.run("kos guild list"))
      local lines = env.run("kos guild remove Bob")
      assert.are.equal("removed Bob from the guild Kill on Sight list.", lines[1])
      assert.is_nil(env.guildKos.bob)
      assert.is_table(env.tombstones["K:bob"])
      assert.are.same({ "bob" }, env.deletes)
      assert.are.same({ "that player is not on the list." }, env.run("kos guild remove Bob"))
      env.noComm = true
      env.run("kos guild Eve")
      lines = env.run("kos guild del Eve")
      assert.are.equal("saved here, but not sent to the guild (no connection).", lines[2])
    end)

    it("applies the permissions of the guild list", function()
      env.rank = { "Miembro", 5 }
      env.run("kos guild Bob")
      env.guildKos.bob.addedBy = "Someone"
      assert.are.same(
        { "that player is on the guild list already; only who added them or an officer can change it." },
        env.run("kos guild Bob camp")
      )
      assert.are.same({ "you are not allowed to do that." }, env.run("kos guild remove Bob"))
      env.rank = { nil, nil }
      assert.are.same({ "you are not allowed to do that." }, env.run("kos guild Eve"))
    end)
  end)

  describe("ignore", function()
    it("adds, lists and removes", function()
      assert.are.same({ "your Ignore list is empty." }, env.run("ignore"))
      assert.are.same({ "ignoring Bob: no alerts, not listed nearby, nothing shared." }, env.run("ignore Bob"))
      env.run("ignore Eve")
      assert.are.same({ "ignored (2): Bob, Eve" }, env.run("ignore list"))
      assert.are.same({ "Bob is not ignored any more." }, env.run("ignore remove Bob"))
      assert.are.same({ "that player is not on the list." }, env.run("ignore remove Bob"))
      assert.are.same({ "that player is not on the list." }, env.run("ignore remove"))
      assert.are.same({ "that is not a valid name." }, env.run("ignore a:b"))
    end)
  end)

  describe("stats", function()
    it("prints the session report and the saved totals", function()
      env.service:OnSeen({ name = "Bob", level = 60 }, { map = 1411 })
      env.service:AddKos({ name = "Eve" })
      local lines = env.run("stats")
      assert.are.equal("Intel report of this session", lines[1])
      assert.are.equal("Enemy players met: 1. Wins: 0. Losses: 0. New Kill on Sight: 1.", lines[2])
      assert.is_truthy(text(lines):find("Hottest zone: Durotar (1 contacts)", 1, true))
      assert.is_truthy(text(lines):find("Saved: 1 players met, 1 on your Kill on Sight list, 0 ignored.", 1, true))
      assert.is_truthy(text(lines):find("statistics is not available", 1, true))
    end)

    it("prints the report of the running season", function()
      assert.are.same({ "no PvP season is running." }, env.run("stats season"))
      env.season = { name = "Season 1", startsAt = 1, endsAt = 9000000 }
      env.service:OnSeen({ name = "Bob", level = 60 }, { map = 1411 })
      assert.are.equal("Intel report of the season 'Season 1'", env.run("stats season")[1])
      env.season = { name = "Broken" }
      assert.are.same({ "no PvP season is running." }, env.run("stats season"))
    end)
  end)

  it("fires a test alert that shares nothing", function()
    local lines = env.run("test")
    assert.are.same({ "Test alert shown. Nothing was shared." }, lines)
    assert.are.equal(1, #env.errors)
  end)

  it("toggles the minimap button", function()
    assert.are.equal("The minimap button is hidden. Type the command again to show it.", env.run("minimap")[1])
    assert.are.equal("The minimap button is shown.", env.run("minimap")[1])
  end)

  describe("import", function()
    it("explains itself without arguments", function()
      assert.is_truthy(env.run("import")[1]:find("usage:", 1, true))
    end)

    it("imports names from text into the chosen list", function()
      assert.are.same(
        { "imported 2, skipped 0 (already listed, not valid, or over the limit)." },
        env.run("import kos Bob, Eve")
      )
      assert.is_table(env.intel.kos.bob)
      env.run("import ignore Una")
      assert.is_table(env.intel.ignore.una)
      env.run("import Zed Yan")
      assert.is_table(env.intel.kos["zed yan"] or env.intel.kos.zedyan)
      assert.are.equal(3, env.changes)
    end)

    it("imports the lists of Spy when they are there and says so when they are not", function()
      assert.is_truthy(env.run("import spy")[1]:find("were not found", 1, true))
      env.globals = { SpyPerCharDB = { KOSData = { Bob = 1 } } }
      assert.are.same(
        { "imported 1, skipped 0 (already listed, not valid, or over the limit)." },
        env.run("import spy")
      )
      assert.is_table(env.intel.kos.bob)
    end)
  end)

  describe("debug", function()
    it("prints what the detection did, in English", function()
      env.nameplates = false
      env.detector.contacts, env.detector.reads = 5, 9
      env.detector.drops.error = 2
      env.service:AddKos({ name = "Bob" })
      local out = text(env.run("debug"))
      for _, expected in ipairs({
        "enemy nameplates: OFF",
        "NAME_PLATE_UNIT_ADDED=registered, PLAYER_DEAD=REFUSED",
        "zone: instance=none pvpType=contested map=1411 detection=allowed",
        "detections this session: 5 new, 9 re-reads",
        "sightings: 3 sent, 4 received",
        "drops detector: error=2",
        "drops publisher: lockdown=2",
        "drops receiver: bad_format=1",
        "drops alerts: none",
        "loss sources: recap=0, target=0, targeting=0, unknown=0",
        "records: 0 players, 1 kos, 0 ignore, 0 zones, 0 guild kos, 0 nearby",
      }) do
        assert.is_truthy(out:find(expected, 1, true), expected)
      end
    end)

    it("says when detection is refused and when the nameplates are unknown or on", function()
      env.allowed = false
      assert.is_truthy(text(env.run("debug")):find("detection=refused (sanctuary)", 1, true))
      assert.is_truthy(text(env.run("debug")):find("enemy nameplates: unknown", 1, true))
      env.nameplates = true
      assert.is_truthy(text(env.run("debug")):find("enemy nameplates: on", 1, true))
    end)

    it("copes with parts that are not there", function()
      env.commands.deps.detector, env.commands.deps.publisher, env.commands.deps.sync = nil, nil, nil
      env.commands.deps.alerts, env.commands.deps.events, env.commands.deps.zone = nil, nil, nil
      local out = text(env.run("debug"))
      assert.is_truthy(out:find("events: none", 1, true))
      assert.is_truthy(out:find("detection=refused", 1, true))
    end)
  end)

  it("speaks Spanish when the client does", function()
    ns.Locale.Use("esES")
    local lines = {}
    local ok, err = pcall(function()
      lines = env.run("kos Bob")
    end)
    ns.Locale.Use("enUS")
    assert.is_true(ok, err)
    assert.are.same({ "se añadió a Bob a tu lista de Muerte a la vista." }, lines)
  end)
end)
