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
    "Domain/BlacklistService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/BlacklistSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Sync, Protocol, Constants = ns.BlacklistSync, ns.Protocol, ns.Constants

local NOW = 100000

local function context(overrides)
  local ctx = {
    blacklist = {},
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
  local p = { key = "yonemongg", name = "Yonemon Gg", reason = "ninja", rev = 1, updatedAt = NOW - 10 }
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
  return message("BLACKLIST_UPSERT", upsert_payload(overrides))
end

local function delete(overrides)
  local p = { key = "yonemongg", rev = 2 }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return message("BLACKLIST_DELETE", p)
end

describe("BlacklistSync BLACKLIST_UPSERT", function()
  it("lets any member add a player, with the sender as the author", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      local ctx = context()
      assert.is_true(Sync.Apply(ctx, upsert(), "Ann-Realm", role), role)
      assert.are.same({
        name = "Yonemon Gg",
        reason = "ninja",
        addedBy = "Ann-Realm",
        addedAt = NOW - 10,
        rev = 1,
        updatedAt = NOW - 10,
        updatedBy = "Ann-Realm",
      }, ctx.blacklist.yonemongg)
    end
  end)

  it("drops a sender the roster does not know", function()
    local ctx = context()
    local ok, reason = Sync.Apply(ctx, upsert(), "Stranger-Realm", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(next(ctx.blacklist))
  end)

  it("never takes an author from the payload", function()
    local ctx = context()
    local forged = upsert_payload({ addedBy = "Boss-Realm", updatedBy = "Boss-Realm", addedAt = 1 })
    assert.is_true(Sync.Apply(ctx, message("BLACKLIST_UPSERT", forged), "Ann-Realm", "member"))
    assert.are.equal("Ann-Realm", ctx.blacklist.yonemongg.addedBy)
    assert.are.equal("Ann-Realm", ctx.blacklist.yonemongg.updatedBy)
    assert.are.equal(NOW - 10, ctx.blacklist.yonemongg.addedAt)
  end)

  it("works the key out from the name and drops a message whose key is another one", function()
    local ctx = context()
    local ok, reason = Sync.Apply(ctx, upsert({ key = "someoneelse" }), "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("bad_key", reason)
    assert.is_nil(next(ctx.blacklist))
  end)

  it("keeps the original author when an admin's later edit wins", function()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    assert.is_true(Sync.Apply(ctx, upsert({ rev = 2, reason = "afk" }), "Boss-Realm", "admin"))
    local entry = ctx.blacklist.yonemongg
    assert.are.equal("afk", entry.reason)
    assert.are.equal("Ann-Realm", entry.addedBy)
    assert.are.equal("Boss-Realm", entry.updatedBy)
  end)

  it("lets the member who added a player edit the entry", function()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    assert.is_true(Sync.Apply(ctx, upsert({ rev = 2, reason = "afk" }), "Ann-Realm", "member"))
    assert.are.equal("afk", ctx.blacklist.yonemongg.reason)
    assert.are.equal("Ann-Realm", ctx.blacklist.yonemongg.updatedBy)
  end)

  it("refuses an edit of a listed player from anyone else but an admin", function()
    for _, role in ipairs({ "member", "rl", "council" }) do
      local ctx = context()
      Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
      local before = { reason = ctx.blacklist.yonemongg.reason, rev = ctx.blacklist.yonemongg.rev }
      local ok, reason = Sync.Apply(ctx, upsert({ rev = 9, reason = "harmless" }), "Bob-Realm", role)
      assert.is_false(ok, role)
      assert.are.equal("forbidden", reason, role)
      assert.are.same(before, { reason = ctx.blacklist.yonemongg.reason, rev = ctx.blacklist.yonemongg.rev })
    end
  end)

  it("follows the conflict order: rev, then updatedAt, then the larger sender", function()
    -- Only the member who added the entry and admins can edit it, so the conflicts are between them.
    local ctx = context()
    Sync.Apply(ctx, upsert({ rev = 2, updatedAt = NOW - 50, reason = "base" }), "Bob-Realm", "member")

    local ok, reason =
      Sync.Apply(ctx, upsert({ rev = 1, updatedAt = NOW - 5, reason = "older rev" }), "Bob-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("stale", reason)

    assert.is_true(
      Sync.Apply(ctx, upsert({ rev = 2, updatedAt = NOW - 40, reason = "later time" }), "Bob-Realm", "member")
    )
    assert.are.equal("later time", ctx.blacklist.yonemongg.reason)

    -- Same rev and time: the larger sender wins, the smaller one does not.
    assert.is_false(Sync.Apply(ctx, upsert({ rev = 2, updatedAt = NOW - 40, reason = "small" }), "Aaa-Realm", "admin"))
    assert.is_true(Sync.Apply(ctx, upsert({ rev = 2, updatedAt = NOW - 40, reason = "large" }), "Zed-Realm", "admin"))
    assert.are.equal("large", ctx.blacklist.yonemongg.reason)

    assert.is_true(
      Sync.Apply(ctx, upsert({ rev = 3, updatedAt = NOW - 90, reason = "newer rev" }), "Bob-Realm", "member")
    )
    assert.are.equal("newer rev", ctx.blacklist.yonemongg.reason)
  end)

  it("clamps a timestamp from the future", function()
    local ctx = context()
    Sync.Apply(ctx, upsert({ updatedAt = NOW + 100000 }), "Ann-Realm", "member")
    assert.are.equal(NOW + 300, ctx.blacklist.yonemongg.updatedAt)
  end)

  it("treats a replay as a no-op", function()
    local ctx = context()
    assert.is_true(Sync.Apply(ctx, upsert(), "Ann-Realm", "member"))
    local before = {}
    for k, v in pairs(ctx.blacklist.yonemongg) do
      before[k] = v
    end
    local ok, reason = Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.same(before, ctx.blacklist.yonemongg)
  end)

  it("stops at the limit for a new player, but still updates one that is listed", function()
    local ctx = context()
    for index = 1, Constants.BLACKLIST_MAX do
      ctx.blacklist["p" .. index] = { name = "P" .. index, rev = 1, updatedAt = 1 }
    end
    local ok, reason = Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_nil(ctx.blacklist.yonemongg)

    assert.is_true(
      Sync.Apply(
        ctx,
        message("BLACKLIST_UPSERT", upsert_payload({ key = "p1", name = "P1", rev = 2 })),
        "Boss-Realm",
        "admin"
      )
    )
    assert.are.equal(2, ctx.blacklist.p1.rev)
  end)
end)

describe("BlacklistSync BLACKLIST_DELETE", function()
  local function listed()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    return ctx
  end

  it("lets an admin remove a player and leaves a tombstone", function()
    local ctx = listed()
    assert.is_true(Sync.Apply(ctx, delete(), "Boss-Realm", "admin"))
    assert.is_nil(ctx.blacklist.yonemongg)
    assert.are.equal(2, ctx.tombstones["B:yonemongg"].rev)
    assert.are.equal(NOW, ctx.tombstones["B:yonemongg"].at)
  end)

  it("forbids everyone else", function()
    for _, role in ipairs({ "member", "rl", "council" }) do
      local ctx = listed()
      local ok, reason = Sync.Apply(ctx, delete(), "Ann-Realm", role)
      assert.is_false(ok)
      assert.are.equal("forbidden", reason, role)
      assert.is_truthy(ctx.blacklist.yonemongg)
      assert.is_nil(next(ctx.tombstones))
    end
  end)

  it("drops a sender the roster does not know", function()
    local ctx = listed()
    local ok, reason = Sync.Apply(ctx, delete(), "Stranger-Realm", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_truthy(ctx.blacklist.yonemongg)
  end)

  it("does not remove an entry that has a newer revision", function()
    local ctx = listed()
    local ok, reason = Sync.Apply(ctx, delete({ rev = 1 }), "Boss-Realm", "admin")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_truthy(ctx.blacklist.yonemongg)
  end)

  it("remembers a removal of a player this client never saw", function()
    local ctx = context()
    assert.is_true(Sync.Apply(ctx, delete({ rev = 5 }), "Boss-Realm", "admin"))
    assert.are.equal(5, ctx.tombstones["B:yonemongg"].rev)
  end)

  it("treats a replay as a no-op", function()
    local ctx = listed()
    assert.is_true(Sync.Apply(ctx, delete(), "Boss-Realm", "admin"))
    local at = ctx.tombstones["B:yonemongg"].at
    ctx.now = function()
      return NOW + 50
    end
    local ok, reason = Sync.Apply(ctx, delete(), "Boss-Realm", "admin")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal(at, ctx.tombstones["B:yonemongg"].at)
  end)
end)

describe("BlacklistSync tombstones", function()
  it("blocks an older upsert and allows rev + 1 to add the player again", function()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    Sync.Apply(ctx, delete(), "Boss-Realm", "admin")

    local ok, reason = Sync.Apply(ctx, upsert({ rev = 1 }), "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("tombstoned", reason)
    ok, reason = Sync.Apply(ctx, upsert({ rev = 2 }), "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("tombstoned", reason)
    assert.is_nil(ctx.blacklist.yonemongg)

    assert.is_true(Sync.Apply(ctx, upsert({ rev = 3, reason = "back again" }), "Bob-Realm", "member"))
    assert.are.equal("back again", ctx.blacklist.yonemongg.reason)
    assert.is_nil(ctx.tombstones["B:yonemongg"])

    -- An admin can remove the new entry again.
    assert.is_true(Sync.Apply(ctx, delete({ rev = 4 }), "Boss-Realm", "admin"))
    assert.is_nil(ctx.blacklist.yonemongg)
  end)

  it("gives the same result whatever order the messages arrive in", function()
    local messages = {
      { upsert({ rev = 1 }), "Ann-Realm", "member" },
      { upsert({ rev = 3, reason = "again" }), "Ann-Realm", "member" },
      { delete({ rev = 2 }), "Boss-Realm", "admin" },
    }
    local orders = {
      { 1, 2, 3 },
      { 1, 3, 2 },
      { 2, 1, 3 },
      { 2, 3, 1 },
      { 3, 1, 2 },
      { 3, 2, 1 },
    }
    for _, order in ipairs(orders) do
      local ctx = context()
      for _, index in ipairs(order) do
        local item = messages[index]
        Sync.Apply(ctx, item[1], item[2], item[3])
      end
      assert.are.equal(3, ctx.blacklist.yonemongg.rev, table.concat(order, ","))
      assert.are.equal("again", ctx.blacklist.yonemongg.reason, table.concat(order, ","))
    end
  end)
end)

describe("BlacklistSync origin of a relayed entry", function()
  it("keeps the author and the date of an item of a snapshot", function()
    local ctx = context()
    local origin = { addedBy = "Ann-Realm", addedAt = 500 }
    assert.is_true(Sync.Apply(ctx, upsert(), "Lead-Realm", "rl", origin))
    assert.are.equal("Ann-Realm", ctx.blacklist.yonemongg.addedBy)
    assert.are.equal(500, ctx.blacklist.yonemongg.addedAt)
    assert.are.equal("Lead-Realm", ctx.blacklist.yonemongg.updatedBy)
  end)

  it("drops an origin that is not a name and a date", function()
    for _, origin in ipairs({
      { addedBy = "Ann-Realm" },
      { addedAt = 500 },
      { addedBy = "|cffff0000Evil", addedAt = 500 },
      { addedBy = "Ann-Realm", addedAt = "yesterday" },
      { addedBy = "Ann-Realm", addedAt = -1 },
      "Ann-Realm",
    }) do
      local ctx = context()
      local ok, reason = Sync.Apply(ctx, upsert(), "Lead-Realm", "rl", origin)
      assert.is_false(ok)
      assert.are.equal("bad_origin", reason)
      assert.is_nil(next(ctx.blacklist))
    end
  end)

  it("does not let an origin change an entry that is already listed", function()
    local ctx = context()
    Sync.Apply(ctx, upsert(), "Ann-Realm", "member")
    local ok, reason = Sync.Apply(ctx, upsert({ rev = 2 }), "Lead-Realm", "rl", { addedBy = "Evil-Realm", addedAt = 1 })
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.are.equal("Ann-Realm", ctx.blacklist.yonemongg.addedBy)
    assert.are.equal(1, ctx.blacklist.yonemongg.rev)
  end)
end)

describe("BlacklistSync misc", function()
  it("knows its own message types", function()
    assert.is_true(Sync.IsBlacklistMessage("BLACKLIST_UPSERT"))
    assert.is_true(Sync.IsBlacklistMessage("BLACKLIST_DELETE"))
    assert.is_false(Sync.IsBlacklistMessage("PVP_STATS"))
    local ok, reason = Sync.Apply(context(), { t = "PVP_STATS", p = {} }, "Ann-Realm", "member")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
  end)

  it("builds payloads that validate", function()
    local entry = { name = "Yonemon Gg", reason = "ninja", rev = 4, updatedAt = 900, addedBy = "x", addedAt = 1 }
    local payload = Sync.UpsertPayload("yonemongg", entry)
    assert.are.same({ key = "yonemongg", name = "Yonemon Gg", reason = "ninja", rev = 4, updatedAt = 900 }, payload)
    assert.is_truthy(Protocol.Validate(Protocol.Build("BLACKLIST_UPSERT", payload, "id")))

    assert.are.same({ key = "ann", rev = 3 }, Sync.DeletePayload({ ["B:ann"] = { rev = 3, at = 1 } }, "ann"))
    assert.is_nil(Sync.DeletePayload({}, "ann"))
  end)

  it("lists the newest entries and removals for a snapshot, with the author kept", function()
    local entries = {}
    for index = 1, 5 do
      entries["p" .. index] = {
        name = "P" .. index,
        reason = "r",
        rev = 1,
        updatedAt = 100 + index,
        addedBy = "Ann-Realm",
        addedAt = 50 + index,
      }
    end
    entries.broken = "oops"
    entries.noauthor = { name = "No Author", reason = "r", rev = 1, updatedAt = 999 }
    local tombstones = {
      ["B:old"] = { rev = 2, at = 10 },
      ["B:new"] = { rev = 3, at = 20 },
      ["E:event"] = { rev = 9, at = 99 },
      ["B:bad|key"] = { rev = 1, at = 30 },
    }
    local items = Sync.SnapshotItems(entries, tombstones, 3)
    assert.are.equal(5, #items)
    assert.are.same(
      { "BLACKLIST_UPSERT", "BLACKLIST_UPSERT", "BLACKLIST_UPSERT" },
      { items[1].t, items[2].t, items[3].t }
    )
    assert.are.same({ "p5", "p4", "p3" }, { items[1].p.key, items[2].p.key, items[3].p.key })
    assert.are.equal("Ann-Realm", items[1].addedBy)
    assert.are.equal(55, items[1].addedAt)
    assert.are.same({ t = "BLACKLIST_DELETE", p = { key = "new", rev = 3 } }, items[4])
    assert.are.same({ t = "BLACKLIST_DELETE", p = { key = "old", rev = 2 } }, items[5])
  end)
end)
