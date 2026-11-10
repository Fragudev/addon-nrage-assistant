local function load_store()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Store.lua"))("NrageAssistant", ns)
  return ns.Store, ns.Constants
end

describe("Store.Load", function()
  local Store, Constants = load_store()

  describe("v15 accented blacklist keys", function()
    local A_ACUTE_UPPER, A_ACUTE = "\195\129", "\195\161"

    it("rebuilds a key saved with an accented capital and its removal mark", function()
      local db = Store.Load({
        global = {
          schemaVersion = 14,
          blacklist = {
            [A_ACUTE_UPPER .. "ngel"] = { name = A_ACUTE_UPPER .. "ngel", rev = 2 },
            plain = { name = "Plain", rev = 1 },
          },
          sync = { tombstones = { ["B:" .. A_ACUTE_UPPER .. "lex"] = { rev = 3 }, ["L:x"] = { rev = 1 } } },
        },
      })
      local blacklist = db.global.blacklist
      assert.is_nil(blacklist[A_ACUTE_UPPER .. "ngel"])
      assert.are.equal(A_ACUTE_UPPER .. "ngel", blacklist[A_ACUTE .. "ngel"].name)
      assert.is_table(blacklist.plain)
      local tombstones = db.global.sync.tombstones
      assert.is_nil(tombstones["B:" .. A_ACUTE_UPPER .. "lex"])
      assert.are.equal(3, tombstones["B:" .. A_ACUTE .. "lex"].rev)
      assert.are.equal(1, tombstones["L:x"].rev)
    end)

    it("keeps the higher revision when both keys exist", function()
      local db = Store.Load({
        global = {
          schemaVersion = 14,
          blacklist = {
            [A_ACUTE_UPPER .. "ngel"] = { name = "old", rev = 5 },
            [A_ACUTE .. "ngel"] = { name = "new", rev = 2 },
          },
        },
      })
      assert.are.equal("old", db.global.blacklist[A_ACUTE .. "ngel"].name)
    end)
  end)

  it("turns position sharing on once for an existing account and leaves a notice", function()
    local db = Store.Load({ global = { schemaVersion = 13, settings = { position = { share = false } } } })
    assert.is_true(db.global.settings.position.share)
    assert.is_true(db.global.settings.positionShareNotice)
  end)

  it("leaves no notice when sharing was on or never saved", function()
    local on = Store.Load({ global = { schemaVersion = 13, settings = { position = { share = true } } } })
    assert.is_nil(on.global.settings.positionShareNotice)
    assert.is_nil(Store.Load({}).global.settings.positionShareNotice)
  end)

  describe("v16 intel tables", function()
    it("creates the tables and leaves the share notice once, keeping the other data", function()
      local db = Store.Load({
        global = { schemaVersion = 15, blacklist = { x = { name = "X", rev = 1 } }, settings = { language = "es" } },
      })
      local global = db.global
      assert.are.same({ players = {}, kos = {}, ignore = {}, zones = {} }, global.intel)
      assert.are.same({}, global.guildKos)
      assert.is_true(global.settings.intelShareNotice)
      assert.are.equal("es", global.settings.language)
      assert.are.equal("X", global.blacklist.x.name)
    end)

    it("runs twice with the same result and does not bring the notice back", function()
      local raw = { global = { schemaVersion = 15 } }
      local db = Store.Load(raw)
      db.global.settings.intelShareNotice = nil
      db.global.intel.players.ann = { name = "Ann" }
      db.global.schemaVersion = 15
      local again = Store.Load(db)
      assert.is_nil(again.global.settings.intelShareNotice)
      assert.are.equal("Ann", again.global.intel.players.ann.name)
      assert.are.equal(18, again.global.schemaVersion)
    end)

    it("repairs a damaged intel table without raising", function()
      local db = Store.Load({ global = { schemaVersion = 15, intel = "oops", guildKos = 3 } })
      assert.is_table(db.global.intel.players)
      assert.is_table(db.global.guildKos)
    end)
  end)

  describe("v18 rank maps table", function()
    it("creates an empty table and keeps maps already saved", function()
      assert.are.same({}, Store.Load({ global = { schemaVersion = 17 } }).global.rankMaps)
      local saved = { ["Nrage-Realm"] = { rev = 2, updatedAt = 5, ranks = {} } }
      assert.are.same(saved, Store.Load({ global = { schemaVersion = 17, rankMaps = saved } }).global.rankMaps)
      assert.are.same({}, Store.Load({ global = { schemaVersion = 17, rankMaps = "oops" } }).global.rankMaps)
    end)
  end)

  describe("v17 installs table", function()
    it("creates the table and keeps the other data", function()
      local db = Store.Load({ global = { schemaVersion = 16, guildKos = { k = { name = "K" } } } })
      assert.are.same({}, db.global.installs)
      assert.are.equal("K", db.global.guildKos.k.name)
    end)

    it("keeps installs already saved and repairs a damaged one", function()
      local kept = Store.Load({ global = { schemaVersion = 16, installs = { A = { version = "1.0", seenAt = 5 } } } })
      assert.are.same({ A = { version = "1.0", seenAt = 5 } }, kept.global.installs)
      assert.are.same({}, Store.Load({ global = { schemaVersion = 16, installs = "oops" } }).global.installs)
    end)
  end)

  it("respects sharing turned off after the migration", function()
    local db = Store.Load({ global = { schemaVersion = 14, settings = { position = { share = false } } } })
    assert.is_false(db.global.settings.position.share)
  end)

  it("builds the full layout from an empty database", function()
    local db = Store.Load(nil)
    assert.are.equal(Constants.SCHEMA_VERSION, db.global.schemaVersion)
    assert.is_table(db.global.roster)
    assert.is_table(db.global.events)
    assert.is_table(db.global.loot)
    assert.is_table(db.global.sync.seen)
    assert.is_table(db.global.sync.tombstones)
    assert.is_table(db.chars)
  end)

  it("migrates a v1 database and keeps its content", function()
    local raw = { schemaVersion = 1, keep = "me" }
    local db = Store.Load(raw)
    assert.are.equal(raw, db)
    assert.are.equal("me", db.keep)
    assert.is_nil(db.schemaVersion)
    assert.are.equal(18, db.global.schemaVersion)
  end)

  it("is idempotent", function()
    local db = Store.Load({ schemaVersion = 1 })
    db.global.roster["A-B"] = { level = 60 }
    local again = Store.Load(db)
    assert.are.equal(60, again.global.roster["A-B"].level)
    assert.are.equal(18, again.global.schemaVersion)
  end)

  it("refuses data from a newer schema and leaves it untouched", function()
    local raw = { global = { schemaVersion = 99, roster = { x = 1 } } }
    local db, err = Store.Load(raw)
    assert.is_nil(db)
    assert.are.equal("newer_schema", err)
    assert.are.equal(99, raw.global.schemaVersion)
    assert.are.equal(1, raw.global.roster.x)
  end)

  it("recovers from corrupted values instead of raising", function()
    local db = Store.Load({ schemaVersion = "banana", global = "oops", chars = 5 })
    assert.are.equal(18, db.global.schemaVersion)
    assert.is_table(db.global.roster)
    assert.is_table(db.chars)
  end)

  it("treats a non-table saved variable as empty", function()
    local db = Store.Load("garbage")
    assert.are.equal(18, db.global.schemaVersion)
  end)
end)

describe("Store.GetChar", function()
  local Store = load_store()

  it("creates profile and readiness once per identity key", function()
    local db = Store.Load(nil)
    local char = Store.GetChar(db, "Nrager-ClassicBetaPvP")
    char.profile.level = 60
    assert.is_table(char.readiness)
    assert.is_nil(char.consent)
    assert.is_table(char.publish)
    assert.is_table(char.pvp)
    assert.are.equal(60, Store.GetChar(db, "Nrager-ClassicBetaPvP").profile.level)
  end)
end)

describe("Store migration to schema 3", function()
  local Store = load_store()

  it("adds the templates table to a v2 database and keeps everything else", function()
    local raw = {
      global = {
        schemaVersion = 2,
        roster = { ["A-B"] = { level = 60 } },
        events = { e = { title = "Raid" } },
        loot = {},
        sync = { seen = {}, tombstones = { t = { at = 1, rev = 2 } } },
      },
      chars = { ["Me-Realm"] = { profile = { level = 60 } } },
    }
    local db = Store.Load(raw)
    assert.are.equal(raw, db)
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.templates)
    assert.are.equal(60, db.global.roster["A-B"].level)
    assert.are.equal("Raid", db.global.events.e.title)
    assert.are.equal(2, db.global.sync.tombstones.t.rev)
    assert.are.equal(60, db.chars["Me-Realm"].profile.level)
  end)

  it("does not touch templates that already exist", function()
    local db = Store.Load({ global = { schemaVersion = 3, templates = { Boss = { slots = {} } } } })
    assert.is_table(db.global.templates.Boss)
  end)

  it("creates the templates table for a fresh database", function()
    assert.are.same({}, Store.Load(nil).global.templates)
  end)
end)

describe("Store migration to schema 4", function()
  local Store = load_store()

  it("adds the settings table with the minimap section to a v3 database and keeps everything else", function()
    local raw = {
      global = { schemaVersion = 3, templates = { Boss = { slots = {} } }, events = { e = { title = "Raid" } } },
      chars = { ["Me-Realm"] = { profile = { level = 60 } } },
    }
    local db = Store.Load(raw)
    assert.are.equal(raw, db)
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({ minimap = {}, pvp = {}, intelShareNotice = true }, db.global.settings)
    assert.is_table(db.global.templates.Boss)
    assert.are.equal("Raid", db.global.events.e.title)
    assert.are.equal(60, db.chars["Me-Realm"].profile.level)
  end)

  it("does not touch settings that already exist", function()
    local db = Store.Load({ global = { schemaVersion = 3, settings = { minimap = { angle = 90, hide = true } } } })
    assert.are.same({ angle = 90, hide = true }, db.global.settings.minimap)
  end)

  it("creates the settings for a fresh database", function()
    assert.are.same({ minimap = {}, pvp = {}, intelShareNotice = true }, Store.Load(nil).global.settings)
  end)
end)

describe("Store migration to schema 5", function()
  local Store = load_store()

  it("gives the characters already saved a pvp table and keeps everything else", function()
    local raw = {
      global = { schemaVersion = 4, settings = { minimap = {} } },
      chars = { ["Me-Realm"] = { profile = { level = 60 } }, ["Broken-Realm"] = "oops" },
    }
    local db = Store.Load(raw)
    assert.are.equal(raw, db)
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.chars["Me-Realm"].pvp)
    assert.are.equal(60, db.chars["Me-Realm"].profile.level)
    assert.are.equal("oops", db.chars["Broken-Realm"])
  end)

  it("does not touch counters that already exist", function()
    local pvp = { honor = { world = 3, bg = 1 } }
    local db = Store.Load({ global = { schemaVersion = 4 }, chars = { ["Me-Realm"] = { pvp = pvp } } })
    assert.are.equal(pvp, db.chars["Me-Realm"].pvp)
    assert.are.equal(3, db.chars["Me-Realm"].pvp.honor.world)
  end)

  it("repairs a pvp value that is not a table", function()
    local db = Store.Load({ global = { schemaVersion = 4 }, chars = { ["Me-Realm"] = { pvp = 5 } } })
    assert.are.same({}, db.chars["Me-Realm"].pvp)
  end)

  it("is idempotent", function()
    local db = Store.Load({ global = { schemaVersion = 4 }, chars = { ["Me-Realm"] = {} } })
    db.chars["Me-Realm"].pvp.honor = { world = 2, bg = 0 }
    local again = Store.Load(db)
    assert.are.equal(2, again.chars["Me-Realm"].pvp.honor.world)
  end)
end)

describe("Store migration to schema 6", function()
  local Store = load_store()

  it("creates the received PvP counters and the reset floors", function()
    local db = Store.Load({ global = { schemaVersion = 5 } })
    assert.are.same({}, db.global.pvpStats)
    assert.are.same({}, db.global.pvpResets)
  end)

  it("keeps what is already there and repairs what is not a table", function()
    local stats = { ["Ann-Realm"] = { rev = 2 } }
    local db = Store.Load({ global = { schemaVersion = 5, pvpStats = stats, pvpResets = 7 } })
    assert.are.equal(stats, db.global.pvpStats)
    assert.are.same({}, db.global.pvpResets)
  end)

  it("gives every character a revision for its PvP record", function()
    local db = Store.Load({})
    assert.are.equal(0, Store.GetChar(db, "Me-Realm").pvpSync.rev)
    db.chars["Me-Realm"].pvpSync.rev = 4
    assert.are.equal(4, Store.GetChar(db, "Me-Realm").pvpSync.rev)
    db.chars["Me-Realm"].pvpSync = { rev = -3 }
    assert.are.equal(0, Store.GetChar(db, "Me-Realm").pvpSync.rev)
    db.chars["Me-Realm"].pvpSync = { rev = "x" }
    assert.are.equal(0, Store.GetChar(db, "Me-Realm").pvpSync.rev)
  end)
end)

describe("Store migration to schema 7", function()
  local Store = load_store()

  it("creates the PvP settings table and keeps the other settings", function()
    local raw = { global = { schemaVersion = 6, settings = { minimap = { angle = 90 }, pvp = nil } } }
    local db = Store.Load(raw)
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.settings.pvp)
    assert.are.equal(90, db.global.settings.minimap.angle)
  end)

  it("is idempotent and keeps the choices already made", function()
    local raw = { global = { schemaVersion = 6, settings = { pvp = { feedWorld = false, feedBg = true } } } }
    local db = Store.Load(raw)
    assert.are.same({ feedWorld = false, feedBg = true }, db.global.settings.pvp)
    local again = Store.Load(db, 18)
    assert.are.same({ feedWorld = false, feedBg = true }, again.global.settings.pvp)
    -- Running the migration again over an already migrated database changes nothing.
    db.global.schemaVersion = 6
    assert.are.same({ feedWorld = false, feedBg = true }, Store.Load(db).global.settings.pvp)
  end)

  it("repairs a settings value that is not a table", function()
    local db = Store.Load({ global = { schemaVersion = 6, settings = { pvp = "oops" } } })
    assert.are.same({}, db.global.settings.pvp)
  end)
end)

describe("Store migration to schema 8", function()
  local Store = load_store()

  it("creates the blacklist and keeps the rest", function()
    local raw =
      { global = { schemaVersion = 7, roster = { x = 1 }, sync = { tombstones = { ["B:x"] = { rev = 2 } } } } }
    local db = Store.Load(raw)
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.blacklist)
    assert.are.same({ x = 1 }, db.global.roster)
    assert.are.equal(2, db.global.sync.tombstones["B:x"].rev)
  end)

  it("is idempotent and keeps the entries already saved", function()
    local entry = { name = "Bad Guy", reason = "ninja", rev = 1 }
    local db = Store.Load({ global = { schemaVersion = 7, blacklist = { badguy = entry } } })
    assert.are.equal(entry, db.global.blacklist.badguy)
    -- Running the migration again over an already migrated database changes nothing.
    db.global.schemaVersion = 7
    assert.are.equal(entry, Store.Load(db).global.blacklist.badguy)
  end)

  it("repairs a blacklist that is not a table", function()
    local db = Store.Load({ global = { schemaVersion = 7, blacklist = "oops" } })
    assert.are.same({}, db.global.blacklist)
  end)

  it("gives a new database an empty blacklist", function()
    assert.are.same({}, Store.Load(nil).global.blacklist)
  end)
end)

describe("Store migration to schema 9", function()
  local Store = load_store()

  it("adds an empty readinessRules table and keeps what is there", function()
    local db = Store.Load({ global = { schemaVersion = 8, blacklist = { x = { name = "X" } } } })
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.readinessRules)
    assert.are.equal("X", db.global.blacklist.x.name)
  end)

  it("keeps rules that were already saved", function()
    local rules = { rev = 2, rules = { { id = "level" } } }
    local db = Store.Load({ global = { schemaVersion = 8, readinessRules = rules } })
    assert.are.equal(2, db.global.readinessRules.rev)
  end)
end)

describe("Store migration to schema 10", function()
  local Store = load_store()

  it("adds the empty rosters and members tables and keeps what is there", function()
    local db = Store.Load({ global = { schemaVersion = 9, events = { e = { title = "Raid" } } } })
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.rosters)
    assert.are.same({}, db.global.members)
    assert.are.equal("Raid", db.global.events.e.title)
  end)

  it("keeps rosters and assignments that were already saved", function()
    local rosters = { r1 = { id = "r1", name = "Main" } }
    local members = { ["Ann-Realm"] = { role = "rl", rosterId = "r1" } }
    local db = Store.Load({ global = { schemaVersion = 9, rosters = rosters, members = members } })
    assert.are.equal("Main", db.global.rosters.r1.name)
    assert.are.equal("rl", db.global.members["Ann-Realm"].role)
  end)

  it("leaves the events without a roster: they are legacy events", function()
    local db = Store.Load({ global = { schemaVersion = 9, events = { e = { title = "Raid" } } } })
    assert.is_nil(db.global.events.e.rosterId)
  end)
end)

describe("Store migration to schema 11", function()
  local Store = load_store()

  it("adds the received recipes table and gives every saved character a recipes table", function()
    local db = Store.Load({ global = { schemaVersion = 10 }, chars = { ["Ann-Realm"] = { profile = {} } } })
    assert.are.equal(18, db.global.schemaVersion)
    assert.are.same({}, db.global.recipes)
    assert.are.same({}, db.chars["Ann-Realm"].recipes)
  end)

  it("keeps recipes that were already saved", function()
    local recipes = { ["Ann-Realm"] = { [171] = { name = "Alchemy", ids = { 1 }, rev = 1 } } }
    local db = Store.Load({ global = { schemaVersion = 10, recipes = recipes }, chars = {} })
    assert.are.equal("Alchemy", db.global.recipes["Ann-Realm"][171].name)
  end)

  it("creates the recipes table of a new character", function()
    local db = Store.Load({})
    assert.are.same({}, Store.GetChar(db, "New-Realm").recipes)
  end)
end)

describe("Store migration to schema 12", function()
  local Store = load_store()

  it("adds the empty PvP season ledger and gives every saved character a mission log", function()
    local db = Store.Load({ global = { schemaVersion = 11 }, chars = { ["Ann-Realm"] = { profile = {} } } })
    assert.are.equal(18, db.global.schemaVersion)
    local season = db.global.pvpSeason
    for _, name in ipairs({
      "seasons",
      "missions",
      "prizes",
      "officers",
      "grants",
      "voids",
      "rejects",
      "queue",
      "finals",
      "deliveries",
    }) do
      assert.are.same({}, season[name])
    end
    assert.is_nil(season.activeId)
    assert.are.same({}, db.chars["Ann-Realm"].pvpMissions)
  end)

  it("is idempotent and keeps a ledger that was already saved", function()
    local ledger = { seasons = { s1 = { id = "s1", name = "One" } }, activeId = "s1", grants = { s1 = { g1 = {} } } }
    local db = Store.Load({ global = { schemaVersion = 11, pvpSeason = ledger }, chars = {} })
    assert.are.equal("One", db.global.pvpSeason.seasons.s1.name)
    assert.are.equal("s1", db.global.pvpSeason.activeId)
    assert.are.same({ g1 = {} }, db.global.pvpSeason.grants.s1)
    db.global.schemaVersion = 11
    assert.are.equal("One", Store.Load(db).global.pvpSeason.seasons.s1.name)
  end)

  it("creates the mission log of a new character", function()
    local db = Store.Load({})
    local char = Store.GetChar(db, "New-Realm")
    assert.are.same({}, char.pvpMissions.kills)
    assert.are.same({}, char.pvpMissions.claims)
  end)
end)

describe("Store migration to schema 13", function()
  local Store, Constants = load_store()

  local function rosters()
    return { r1 = { id = "r1", name = "A" }, r2 = { id = "r2", name = "B" } }
  end

  it("copies the guild rules into every existing roster and leaves the old key alone", function()
    local old =
      { rev = 4, updatedAt = 90, updatedBy = "Boss-Realm", rules = { { id = "level", check = "level", min = 60 } } }
    local db = Store.Load({ global = { schemaVersion = 12, rosters = rosters(), readinessRules = old } })
    assert.are.equal(18, db.global.schemaVersion)
    for _, id in ipairs({ "r1", "r2" }) do
      local record = db.global.readinessRulesByRoster[id]
      assert.are.same({ 4, 90, "Boss-Realm" }, { record.rev, record.updatedAt, record.updatedBy })
      assert.are.same(old.rules, record.rules)
    end
    assert.are_not.equal(db.global.readinessRulesByRoster.r1.rules, db.global.readinessRulesByRoster.r2.rules)
    assert.are.equal(old, db.global.readinessRules)
  end)

  it("gives the starting list to the rosters when the guild never set rules", function()
    local db = Store.Load({ global = { schemaVersion = 12, rosters = rosters(), readinessRules = {} } })
    assert.are.same(Constants.DEFAULT_RULES, db.global.readinessRulesByRoster.r1.rules)
    assert.are.equal(0, db.global.readinessRulesByRoster.r1.rev)
  end)

  it("adds an empty table without rosters, and a roster created later has no record", function()
    local db = Store.Load({ global = { schemaVersion = 12 } })
    assert.are.same({}, db.global.readinessRulesByRoster)
    db.global.rosters.r3 = { id = "r3", name = "C" }
    assert.is_nil(db.global.readinessRulesByRoster.r3)
  end)

  it("is idempotent and keeps a record that was already there", function()
    local mine = { rev = 9, rules = { { id = "x" } } }
    local db = Store.Load({
      global = { schemaVersion = 12, rosters = rosters(), readinessRulesByRoster = { r1 = mine } },
    })
    assert.are.equal(mine, db.global.readinessRulesByRoster.r1)
    assert.is_table(db.global.readinessRulesByRoster.r2)
    db.global.schemaVersion = 12
    assert.are.equal(mine, Store.Load(db).global.readinessRulesByRoster.r1)
  end)
end)
