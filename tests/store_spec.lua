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
    assert.are.equal(2, db.global.schemaVersion)
  end)

  it("is idempotent", function()
    local db = Store.Load({ schemaVersion = 1 })
    db.global.roster["A-B"] = { level = 60 }
    local again = Store.Load(db)
    assert.are.equal(60, again.global.roster["A-B"].level)
    assert.are.equal(2, again.global.schemaVersion)
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
    assert.are.equal(2, db.global.schemaVersion)
    assert.is_table(db.global.roster)
    assert.is_table(db.chars)
  end)

  it("treats a non-table saved variable as empty", function()
    local db = Store.Load("garbage")
    assert.are.equal(2, db.global.schemaVersion)
  end)
end)

describe("Store.GetChar", function()
  local Store = load_store()

  it("creates profile and readiness once per identity key", function()
    local db = Store.Load(nil)
    local char = Store.GetChar(db, "Nrager-ClassicBetaPvP")
    char.profile.level = 60
    assert.is_table(char.readiness)
    assert.are.equal(60, Store.GetChar(db, "Nrager-ClassicBetaPvP").profile.level)
  end)
end)
