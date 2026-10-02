local function load_store()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Store.lua"))("NrageAssistant", ns)
  return ns.Store, ns.Constants
end

describe("Store.Load", function()
  local Store, Constants = load_store()

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
    assert.are.equal(8, db.global.schemaVersion)
  end)

  it("is idempotent", function()
    local db = Store.Load({ schemaVersion = 1 })
    db.global.roster["A-B"] = { level = 60 }
    local again = Store.Load(db)
    assert.are.equal(60, again.global.roster["A-B"].level)
    assert.are.equal(8, again.global.schemaVersion)
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
    assert.are.equal(8, db.global.schemaVersion)
    assert.is_table(db.global.roster)
    assert.is_table(db.chars)
  end)

  it("treats a non-table saved variable as empty", function()
    local db = Store.Load("garbage")
    assert.are.equal(8, db.global.schemaVersion)
  end)
end)

describe("Store.GetChar", function()
  local Store = load_store()

  it("creates profile and readiness once per identity key", function()
    local db = Store.Load(nil)
    local char = Store.GetChar(db, "Nrager-ClassicBetaPvP")
    char.profile.level = 60
    assert.is_table(char.readiness)
    assert.is_table(char.consent)
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
    assert.are.equal(8, db.global.schemaVersion)
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
    assert.are.equal(8, db.global.schemaVersion)
    assert.are.same({ minimap = {}, pvp = {} }, db.global.settings)
    assert.is_table(db.global.templates.Boss)
    assert.are.equal("Raid", db.global.events.e.title)
    assert.are.equal(60, db.chars["Me-Realm"].profile.level)
  end)

  it("does not touch settings that already exist", function()
    local db = Store.Load({ global = { schemaVersion = 3, settings = { minimap = { angle = 90, hide = true } } } })
    assert.are.same({ angle = 90, hide = true }, db.global.settings.minimap)
  end)

  it("creates the settings for a fresh database", function()
    assert.are.same({ minimap = {}, pvp = {} }, Store.Load(nil).global.settings)
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
    assert.are.equal(8, db.global.schemaVersion)
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
    assert.are.equal(8, db.global.schemaVersion)
    assert.are.same({}, db.global.settings.pvp)
    assert.are.equal(90, db.global.settings.minimap.angle)
  end)

  it("is idempotent and keeps the choices already made", function()
    local raw = { global = { schemaVersion = 6, settings = { pvp = { feedWorld = false, feedBg = true } } } }
    local db = Store.Load(raw)
    assert.are.same({ feedWorld = false, feedBg = true }, db.global.settings.pvp)
    local again = Store.Load(db, 8)
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
    assert.are.equal(8, db.global.schemaVersion)
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
