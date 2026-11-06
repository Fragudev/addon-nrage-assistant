local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/IntelModel",
    "Domain/GuildKosService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/GuildKosSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Sync, Protocol, Constants = ns.GuildKosSync, ns.Protocol, ns.Constants

local NOW = 100000

local function context(overrides)
  local ctx = {
    guildKos = {},
    tombstones = {},
    now = function()
      return NOW
    end,
  }
  for k, v in pairs(overrides or {}) do
    ctx[k] = v
  end
  return ctx
end

local function upsert_payload(overrides)
  local p = {
    key = "yonemongg",
    name = "Yonemon Gg",
    category = "gank",
    reason = "ninja",
    rev = 1,
    updatedAt = NOW - 10,
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

-- A message as it leaves Protocol.Validate, which is what Apply is given.
local function message(messageType, payload)
  local clean, reason = Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
  assert(clean, reason)
  return clean
end

local function upsert(overrides)
  return message("KOS_UPSERT", upsert_payload(overrides))
end

local function delete(overrides)
  local p = { key = "yonemongg", rev = 2 }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return message("KOS_DELETE", p)
end

describe("GuildKosSync KOS_UPSERT", function()
  it("lets any member add a player, with the sender as the author", function()
    for _, role in ipairs({ "alter", "member", "rl", "officer", "gm" }) do
      local ctx = context()
      assert.is_true(Sync.Apply(ctx, upsert(), "Ann-Realm", role), role)
      assert.are.same({
        name = "Yonemon Gg",
        category = "gank",
        reason = "ninja",
        addedBy = "Ann-Realm",
        addedAt = NOW - 10,
        rev = 1,
        updatedAt = NOW - 10,
        updatedBy = "Ann-Realm",
      }, ctx.guildKos.yonemongg)
    end
  end)

  it("accepts an entry without a reason", function()
    local ctx = context()
    local payload = upsert_payload()
    payload.reason = nil
    assert.is_true(Sync.Apply(ctx, message("KOS_UPSERT", payload), "Ann-Realm", "member"))
    assert.is_nil(ctx.guildKos.yonemongg.reason)
  end)

  it("drops a sender the roster does not know", function()
    local ctx = context()
    assert.are.same({ false, "unknown_sender" }, { Sync.Apply(ctx, upsert(), "Stranger-Realm", nil) })
    assert.are.same({}, ctx.guildKos)
  end)

  it("drops a key that is not the one of the name", function()
    local ctx = context()
    assert.are.same({ false, "bad_key" }, { Sync.Apply(ctx, upsert({ key = "other" }), "Ann-Realm", "member") })
  end)

  it("lets only the author, a gm or a cogm change an entry that is already listed", function()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    local change = upsert({ category = "camp", rev = 2 })
    assert.are.same({ false, "forbidden" }, { Sync.Apply(ctx, change, "Cid-Realm", "officer") })
    assert.are.equal("gank", ctx.guildKos.yonemongg.category)
    assert.is_true(Sync.Apply(ctx, change, "Ann-Realm", "member"))
    assert.are.equal("camp", ctx.guildKos.yonemongg.category)
    assert.is_true(Sync.Apply(ctx, upsert({ category = "corpse", rev = 3 }), "Boss-Realm", "gm"))
    assert.are.equal("corpse", ctx.guildKos.yonemongg.category)
    assert.are.equal("Ann-Realm", ctx.guildKos.yonemongg.addedBy)
    assert.are.equal("Boss-Realm", ctx.guildKos.yonemongg.updatedBy)
  end)

  it("orders by revision, then by time, then by sender, and takes an identical message as a no-op", function()
    local ctx = context()
    Sync.Apply(ctx, upsert({ rev = 3 }), "Ann-Realm", "member")
    assert.are.same(
      { false, "stale" },
      { Sync.Apply(ctx, upsert({ rev = 2, category = "camp" }), "Ann-Realm", "member") }
    )
    assert.are.same({ false, "stale" }, { Sync.Apply(ctx, upsert({ rev = 3 }), "Ann-Realm", "member") })
    assert.is_true(Sync.Apply(ctx, upsert({ rev = 3, updatedAt = NOW - 5, category = "camp" }), "Ann-Realm", "member"))
    assert.are.equal("camp", ctx.guildKos.yonemongg.category)
  end)

  it("does not let a time in the future win", function()
    local ctx = context()
    Sync.Apply(ctx, upsert({ updatedAt = NOW + 100000 }), "Ann-Realm", "member")
    assert.are.equal(NOW + 300, ctx.guildKos.yonemongg.updatedAt)
  end)

  it("drops an upsert the tombstone outranks, and takes one above it", function()
    local ctx = context({ tombstones = { ["K:yonemongg"] = { at = 1, rev = 3 } } })
    assert.are.same({ false, "tombstoned" }, { Sync.Apply(ctx, upsert({ rev = 3 }), "Ann-Realm", "member") })
    assert.is_true(Sync.Apply(ctx, upsert({ rev = 4 }), "Ann-Realm", "member"))
    assert.is_nil(ctx.tombstones["K:yonemongg"])
  end)

  it("keeps the list within its limit", function()
    local ctx = context()
    for index = 1, Constants.INTEL_KOS_MAX do
      ctx.guildKos["k" .. index] = { name = "K" .. index, rev = 1 }
    end
    assert.are.same({ false, "limit" }, { Sync.Apply(ctx, upsert(), "Ann-Realm", "member") })
  end)

  it("ignores a message type it does not know", function()
    assert.are.same({ false, "unsupported" }, { Sync.Apply(context(), { t = "PROFILE", p = {} }, "Ann", "member") })
    assert.is_false(Sync.IsGuildKosMessage("BLACKLIST_UPSERT"))
    assert.is_true(Sync.IsGuildKosMessage("KOS_DELETE"))
  end)
end)

describe("GuildKosSync KOS_DELETE", function()
  local function listed()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    return ctx
  end

  it("lets the author remove their entry and leaves the tombstone", function()
    local ctx = listed()
    assert.is_true(Sync.Apply(ctx, delete(), "Ann-Realm", "member"))
    assert.is_nil(ctx.guildKos.yonemongg)
    assert.are.equal(2, ctx.tombstones["K:yonemongg"].rev)
  end)

  it("lets gm and cogm remove any entry", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      local ctx = listed()
      assert.is_true(Sync.Apply(ctx, delete(), "Boss-Realm", role), role)
    end
  end)

  it("refuses another member, whatever the rank below cogm", function()
    for _, role in ipairs({ "member", "rl", "officer", "roster", "alter" }) do
      local ctx = listed()
      assert.are.same({ false, "forbidden" }, { Sync.Apply(ctx, delete(), "Cid-Realm", role) }, role)
      assert.is_table(ctx.guildKos.yonemongg)
    end
  end)

  it("refuses a sender the roster does not know", function()
    assert.are.same({ false, "unknown_sender" }, { Sync.Apply(listed(), delete(), "Stranger-Realm", nil) })
  end)

  it("drops a removal that is not above the revision held", function()
    local ctx = listed()
    assert.are.same({ false, "stale" }, { Sync.Apply(ctx, delete({ rev = 1 }), "Ann-Realm", "member") })
    assert.is_table(ctx.guildKos.yonemongg)
  end)

  it("remembers the removal of an unknown player only from a gm or cogm", function()
    local ctx = context()
    assert.are.same({ false, "forbidden" }, { Sync.Apply(ctx, delete(), "Ann-Realm", "member") })
    assert.is_true(Sync.Apply(ctx, delete({ rev = 4 }), "Boss-Realm", "gm"))
    assert.are.equal(4, ctx.tombstones["K:yonemongg"].rev)
    assert.are.same({ false, "stale" }, { Sync.Apply(ctx, delete({ rev = 4 }), "Boss-Realm", "gm") })
    -- The remembered removal then blocks an older upsert.
    assert.are.same({ false, "tombstoned" }, { Sync.Apply(ctx, upsert({ rev = 3 }), "Ann-Realm", "member") })
  end)
end)

describe("GuildKosSync snapshot items", function()
  local function entry(name, overrides)
    local e = {
      name = name,
      category = "gank",
      reason = "x",
      addedBy = "Ann-Realm",
      addedAt = 500,
      rev = 1,
      updatedAt = 9000,
      updatedBy = "Ann-Realm",
    }
    for k, v in pairs(overrides or {}) do
      e[k] = v
    end
    return e
  end

  it("lists the newest entries with their author and the newest removals", function()
    local entries = {
      old = entry("Old", { updatedAt = 100 }),
      new = entry("New", { updatedAt = 900, addedBy = "Bob-Realm" }),
      broken = "oops",
    }
    local tombstones = {
      ["K:gone"] = { at = 20, rev = 3 },
      ["K:older"] = { at = 10, rev = 2 },
      ["B:other"] = { at = 30, rev = 9 },
    }
    local items = Sync.SnapshotItems(entries, tombstones, 1)
    assert.are.equal(2, #items)
    assert.are.equal("KOS_UPSERT", items[1].t)
    assert.are.equal("new", items[1].p.key)
    assert.are.equal("Bob-Realm", items[1].addedBy)
    assert.are.equal(500, items[1].addedAt)
    assert.are.same({ t = "KOS_DELETE", p = { key = "gone", rev = 3 } }, items[2])
    assert.are.equal(4, #Sync.SnapshotItems(entries, tombstones, 5))
  end)

  it("leaves out what does not validate", function()
    local entries = { bad = entry("Bad", { category = "nope" }), worse = entry("Worse", { addedBy = "x|y" }) }
    assert.are.same({}, Sync.SnapshotItems(entries, {}, 5))
  end)

  it("builds the payloads of a local change", function()
    local e = entry("Bob")
    assert.are.same(
      { key = "bob", name = "Bob", category = "gank", reason = "x", rev = 1, updatedAt = 9000 },
      Sync.UpsertPayload("bob", e)
    )
    assert.are.same({ key = "bob", rev = 4 }, Sync.DeletePayload({ ["K:bob"] = { rev = 4 } }, "bob"))
    assert.is_nil(Sync.DeletePayload({}, "bob"))
  end)
end)

describe("Protocol.Validate KOS_UPSERT and KOS_DELETE", function()
  local function validate(messageType, payload)
    return Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
  end

  it("keeps the fields and drops everything else, such as an author", function()
    local clean =
      validate("KOS_UPSERT", upsert_payload({ addedBy = "Boss-Realm", updatedBy = "Boss-Realm", extra = 1 }))
    assert.are.same(upsert_payload(), clean.p)
    assert.are.same({ key = "ann", rev = 2 }, validate("KOS_DELETE", { key = "ann", rev = 2, extra = true }).p)
  end)

  it("accepts the limits of the name and the reason", function()
    local name = ("n"):rep(Constants.INTEL_NAME_MAX)
    local reason = ("r"):rep(Constants.INTEL_REASON_MAX)
    assert.is_truthy(validate("KOS_UPSERT", upsert_payload({ key = name, name = name, reason = reason })))
  end)

  it("rejects a bad name, key, category or reason", function()
    local long = ("n"):rep(Constants.INTEL_NAME_MAX + 1)
    for _, bad in ipairs({ "", long, 5, true, "A|B", "A\1B", "A:B", " Ann", "Ann-Realm" }) do
      assert.are.equal("bad_payload", select(2, validate("KOS_UPSERT", upsert_payload({ name = bad }))), tostring(bad))
    end
    for _, bad in ipairs({ "", long, 5, "A:B" }) do
      assert.are.equal("bad_payload", select(2, validate("KOS_UPSERT", upsert_payload({ key = bad }))), tostring(bad))
      assert.are.equal("bad_payload", select(2, validate("KOS_DELETE", { key = bad, rev = 1 })), tostring(bad))
    end
    for _, bad in ipairs({ "revenge", 5, false, "" }) do
      assert.are.equal(
        "bad_payload",
        select(2, validate("KOS_UPSERT", upsert_payload({ category = bad }))),
        tostring(bad)
      )
    end
    for _, bad in ipairs({ "", ("r"):rep(101), 5, "a|b", " padded " }) do
      assert.are.equal(
        "bad_payload",
        select(2, validate("KOS_UPSERT", upsert_payload({ reason = bad }))),
        tostring(bad)
      )
    end
  end)

  it("rejects a revision or a time out of range", function()
    for _, bad in ipairs({ 0, -1, 1.5, 2147483648, "1", true }) do
      assert.are.equal("bad_payload", select(2, validate("KOS_UPSERT", upsert_payload({ rev = bad }))), tostring(bad))
      assert.are.equal("bad_payload", select(2, validate("KOS_DELETE", { key = "ann", rev = bad })), tostring(bad))
    end
    for _, bad in ipairs({ -1, 4102444801, 1.5, "1" }) do
      assert.are.equal(
        "bad_payload",
        select(2, validate("KOS_UPSERT", upsert_payload({ updatedAt = bad }))),
        tostring(bad)
      )
    end
  end)

  it("rejects a message with a missing field, except the reason", function()
    for _, field in ipairs({ "key", "name", "category", "rev", "updatedAt" }) do
      local payload = upsert_payload()
      payload[field] = nil
      assert.are.equal("bad_payload", select(2, validate("KOS_UPSERT", payload)), field)
    end
    assert.are.equal("bad_payload", select(2, validate("KOS_DELETE", { key = "ann" })))
    assert.are.equal("bad_payload", select(2, validate("KOS_DELETE", { rev = 2 })))
  end)
end)
