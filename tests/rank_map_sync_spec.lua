-- RANK_MAP on the wire: who may send a rank map, the guards for a co-guild master, conflicts and the snapshot item.
-- The receiver authorizes the sender with the map it holds BEFORE applying the incoming one (part D.4).
local function load_addon()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RankMapModel",
    "Sync/Codec",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/RankMapSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Sync, Protocol, Model = ns.RankMapSync, ns.Protocol, ns.RankMapModel

local NOW = 1792454400
local GUILD = "Nrage-Realm"

-- The guild roster of the receiver: name -> rank name and index.
local ENTRIES = {
  Boss = { rankName = "Emperador", rankIndex = 0 },
  Co = { rankName = "Comandante", rankIndex = 1 },
  Off = { rankName = "Oficial", rankIndex = 2 },
  Mem = { rankName = "Soldado", rankIndex = 5 },
  -- Rank 3 was renamed in the game; only a saved map still knows it is a co-guild master rank.
  Renamed = { rankName = "Capitana", rankIndex = 3 },
  -- A rank that is called like the guild master's but is not rank 0.
  Fake = { rankName = "Emperador", rankIndex = 4 },
}

local function ctx_of(maps, extra)
  local ctx = {
    maps = maps,
    guildKey = GUILD,
    now = function()
      return NOW
    end,
    entryOf = function(name)
      return ENTRIES[name]
    end,
  }
  for key, value in pairs(extra or {}) do
    ctx[key] = value
  end
  return ctx
end

local function payload(rows, change)
  local p = { rev = 1, updatedAt = NOW - 10, ranks = rows }
  for key, value in pairs(change or {}) do
    p[key] = value
  end
  return p
end

local function message(p)
  return Protocol.Validate(Protocol.Build("RANK_MAP", p, "m1"))
end

local function apply(ctx, p, sender)
  local m = message(p)
  assert(m, "the test payload must validate")
  return Sync.Apply(ctx, m, sender)
end

-- Rows that keep today's roles for the ranks the tests use.
local KEEP = {
  { i = 1, r = "cogm", n = "Comandante" },
  { i = 2, r = "officer", n = "Oficial" },
  { i = 5, r = "member", n = "Soldado" },
}

local function rows_with(change)
  local rows = {}
  for _, row in ipairs(KEEP) do
    rows[#rows + 1] = { i = row.i, r = change[row.i] or row.r, n = row.n }
  end
  return rows
end

describe("RankMapSync.Apply authority", function()
  it("accepts a rank map from rank index 0 and keeps it for the guild", function()
    local maps = {}
    local ok = apply(ctx_of(maps), payload(rows_with({ [2] = "member" })), "Boss")
    assert.is_true(ok)
    local saved = maps[GUILD]
    assert.are.equal(1, saved.rev)
    assert.are.equal("Boss", saved.by)
    assert.are.equal("member", saved.ranks[2].role)
    assert.are.equal("Oficial", saved.ranks[2].name)
  end)

  it("accepts a rank map from a co-guild master by name when no map is saved", function()
    local maps = {}
    assert.is_true((apply(ctx_of(maps), payload(rows_with({ [2] = "rl" })), "Co")))
    assert.are.equal("rl", maps[GUILD].ranks[2].role)
  end)

  it("accepts a rank map from a co-guild master by the map the receiver holds", function()
    local maps = { [GUILD] = { rev = 1, updatedAt = NOW - 100, by = "Boss", ranks = { [3] = { role = "cogm" } } } }
    local rows = rows_with({})
    rows[#rows + 1] = { i = 3, r = "cogm", n = "Capitana" }
    local ok = apply(ctx_of(maps), payload(rows, { rev = 2 }), "Renamed")
    assert.is_true(ok)
    assert.are.equal(2, maps[GUILD].rev)
  end)

  it("drops a rank map from an officer, a member and somebody the roster does not know", function()
    local maps = {}
    local ctx = ctx_of(maps)
    assert.are.same({ false, "forbidden" }, { apply(ctx, payload(rows_with({})), "Off") })
    assert.are.same({ false, "forbidden" }, { apply(ctx, payload(rows_with({})), "Mem") })
    assert.are.same({ false, "unknown_sender" }, { apply(ctx, payload(rows_with({})), "Stranger") })
    assert.is_nil(maps[GUILD])
  end)

  it("never lets the incoming map authorize its own sender", function()
    local maps = {}
    -- The officer's own rank (2) is made co-guild master by the very map the officer sends.
    local ok, why = apply(ctx_of(maps), payload(rows_with({ [2] = "cogm" })), "Off")
    assert.is_false(ok)
    assert.are.equal("forbidden", why)
    -- Nor does a map that makes a renamed rank cogm authorize somebody who is only that by the incoming map.
    local rows = rows_with({})
    rows[#rows + 1] = { i = 3, r = "cogm", n = "Capitana" }
    ok, why = apply(ctx_of(maps), payload(rows), "Renamed")
    assert.is_false(ok)
    assert.are.equal("forbidden", why)
    assert.is_nil(maps[GUILD])
  end)

  it("recognises the guild master by the rank index and never by the name", function()
    local maps = {}
    local ok, why = apply(ctx_of(maps), payload(rows_with({})), "Fake")
    assert.is_false(ok)
    assert.are.equal("forbidden", why)
  end)

  it("ignores a rank map for a guild it does not know", function()
    local maps = {}
    local ok, why = apply(ctx_of(maps, { guildKey = false }), payload(rows_with({})), "Boss")
    assert.is_false(ok)
    assert.are.equal("no_guild", why)
    assert.are.same({}, maps)
  end)

  it("refuses a message that is not a rank map", function()
    local ok, why = Sync.Apply(ctx_of({}), { t = "HELLO", p = {} }, "Boss")
    assert.is_false(ok)
    assert.are.equal("unsupported", why)
  end)
end)

describe("RankMapSync.Apply guards for a co-guild master", function()
  it("drops the whole message when the sender changes the row of their own rank", function()
    local maps = {}
    local ok, why = apply(ctx_of(maps), payload(rows_with({ [1] = "officer", [2] = "rl" })), "Co")
    assert.is_false(ok)
    assert.are.equal("self_row", why)
    assert.is_nil(maps[GUILD])
  end)

  it("drops a map that leaves the sender's own rank to the name lookup when that is not cogm", function()
    local maps = { [GUILD] = { rev = 1, updatedAt = NOW - 100, by = "Boss", ranks = { [3] = { role = "cogm" } } } }
    local ok, why = apply(ctx_of(maps), payload(rows_with({}), { rev = 2 }), "Renamed")
    assert.is_false(ok)
    assert.are.equal("self_row", why)
    assert.are.equal(1, maps[GUILD].rev)
  end)

  it("lets a co-guild master change other ranks, even to cogm, by design", function()
    local maps = {}
    assert.is_true((apply(ctx_of(maps), payload(rows_with({ [2] = "cogm", [5] = "alter" })), "Co")))
    assert.are.equal("cogm", maps[GUILD].ranks[2].role)
    assert.are.equal("alter", maps[GUILD].ranks[5].role)
  end)

  it("lets the guild master change any row, the co-guild master's included", function()
    local maps = {}
    assert.is_true((apply(ctx_of(maps), payload(rows_with({ [1] = "officer" })), "Boss")))
    assert.are.equal("officer", maps[GUILD].ranks[1].role)
  end)

  it("never accepts gm as a role of a rank, from anybody", function()
    local maps = {}
    local bad = { rev = 1, updatedAt = NOW - 10, ranks = { { i = 1, r = "gm", n = "Comandante" } } }
    assert.is_nil(message(bad))
    local ok, why = Sync.Apply(ctx_of(maps), { t = "RANK_MAP", p = bad }, "Boss")
    assert.is_false(ok)
    assert.are.equal("invalid", why)
    local fixed = { rev = 1, updatedAt = NOW - 10, ranks = { { i = 0, r = "alter", n = "Emperador" } } }
    ok, why = Sync.Apply(ctx_of(maps), { t = "RANK_MAP", p = fixed }, "Boss")
    assert.is_false(ok)
    assert.are.equal("invalid", why)
    assert.is_nil(maps[GUILD])
  end)
end)

describe("RankMapSync.Apply conflicts", function()
  local function held(rev, updatedAt, by)
    return {
      [GUILD] = { rev = rev, updatedAt = updatedAt, by = by, ranks = { [2] = { role = "officer", name = "O" } } },
    }
  end

  it("keeps the newer revision and drops an older or equal one", function()
    local maps = held(3, NOW - 50, "Boss")
    local ctx = ctx_of(maps)
    assert.are.same({ false, "stale" }, { apply(ctx, payload(rows_with({ [2] = "rl" }), { rev = 2 }), "Boss") })
    assert.are.same(
      { false, "stale" },
      { apply(ctx, payload(rows_with({ [2] = "rl" }), { rev = 3, updatedAt = NOW - 50 }), "Boss") }
    )
    assert.are.equal("officer", maps[GUILD].ranks[2].role)
    assert.is_true((apply(ctx, payload(rows_with({ [2] = "rl" }), { rev = 4 }), "Boss")))
    assert.are.equal("rl", maps[GUILD].ranks[2].role)
  end)

  it("breaks a tie on the revision by the later time, then by the sender", function()
    local maps = held(3, NOW - 50, "Co")
    local ctx = ctx_of(maps)
    assert.is_true((apply(ctx, payload(rows_with({ [2] = "rl" }), { rev = 3, updatedAt = NOW - 40 }), "Boss")))
    assert.are.equal("Boss", maps[GUILD].by)
    -- Same revision and time: the larger sender name wins ("Co" > "Boss"), a replay of the held one does not.
    assert.is_true((apply(ctx, payload(rows_with({ [2] = "member" }), { rev = 3, updatedAt = NOW - 40 }), "Co")))
    assert.are.equal("Co", maps[GUILD].by)
    assert.are.same(
      { false, "stale" },
      { apply(ctx, payload(rows_with({ [2] = "member" }), { rev = 3, updatedAt = NOW - 40 }), "Co") }
    )
  end)

  it("clamps a time that claims to be in the future", function()
    local maps = {}
    apply(ctx_of(maps), payload(rows_with({}), { updatedAt = NOW + 100000 }), "Boss")
    assert.are.equal(NOW + 300, maps[GUILD].updatedAt)
  end)

  it("keeps the maps of other guilds apart", function()
    local maps = { ["Other-Realm"] = { rev = 9, updatedAt = 1, ranks = {} } }
    assert.is_true((apply(ctx_of(maps), payload(rows_with({})), "Boss")))
    assert.are.equal(9, maps["Other-Realm"].rev)
    assert.are.equal(1, maps[GUILD].rev)
  end)
end)

local function saved_with_row_3()
  return { rev = 1, updatedAt = 1, ranks = { [3] = { role = "cogm", name = "C" } } }
end

describe("RankMapSync payloads and snapshot", function()
  local saved = {
    rev = 4,
    updatedAt = NOW - 5,
    by = "Boss",
    ranks = { [1] = { role = "cogm", name = "Comandante" }, [2] = { role = "officer", name = "Oficial" } },
  }

  it("builds the payload of a saved map", function()
    local p = Sync.Payload(saved)
    assert.are.equal(4, p.rev)
    assert.are.same({ { i = 1, r = "cogm", n = "Comandante" }, { i = 2, r = "officer", n = "Oficial" } }, p.ranks)
    assert.is_nil(Sync.Payload(nil))
    assert.is_nil(Sync.Payload({ rev = 0, ranks = {} }))
  end)

  it("builds a snapshot item that a receiver applies under the sender of the snapshot", function()
    local item = Sync.SnapshotItem(saved)
    assert.are.equal("RANK_MAP", item.t)
    local maps = {}
    local ok = Sync.ApplyItem(ctx_of(maps), item, "Boss")
    assert.is_true(ok)
    assert.are.equal(4, maps[GUILD].rev)
    maps = {}
    local denied, why = Sync.ApplyItem(ctx_of(maps), item, "Off")
    assert.is_false(denied)
    assert.are.equal("forbidden", why)
    assert.is_nil(Sync.SnapshotItem(nil))
  end)

  it("tells who may author it: rank index 0 and a co-guild master", function()
    assert.is_true(Sync.MayAuthor({ rankName = "Anything", rankIndex = 0 }, nil))
    assert.is_true(Sync.MayAuthor({ rankName = "Comandante", rankIndex = 1 }, nil))
    assert.is_true(Sync.MayAuthor({ rankName = "Capitana", rankIndex = 3 }, saved_with_row_3()))
    assert.is_false(Sync.MayAuthor({ rankName = "Oficial", rankIndex = 2 }, nil))
    assert.is_false(Sync.MayAuthor({ rankName = "Emperador", rankIndex = 4 }, nil))
    assert.is_false(Sync.MayAuthor(nil, nil))
  end)
end)

describe("Model consistency", function()
  it("keeps the wire limit of rows in step with the guild rank limit", function()
    assert.are.equal(9, Model.MAX_INDEX)
  end)
end)
