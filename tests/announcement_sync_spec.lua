local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/AnnouncementModel",
    "Domain/AnnouncementService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/AnnouncementSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Sync, Protocol, Constants = ns.AnnouncementSync, ns.Protocol, ns.Constants

local NOW = 10000

local function context()
  local applied = {}
  return {
    store = { items = {}, tombstones = {} },
    now = function()
      return NOW
    end,
    onApplied = function(announcement)
      applied[#applied + 1] = announcement.id
    end,
    applied = applied,
  }
end

local function payload(overrides)
  local p = {
    id = "a-1",
    title = "Raid night",
    body = "Bring flasks",
    createdAt = 9000,
    updatedAt = 9000,
    rev = 1,
    popup = true,
    popupRev = 1,
    pinned = false,
  }
  for key, value in pairs(overrides or {}) do
    p[key] = value
  end
  return p
end

local function message(messageType, p)
  local clean, reason = Protocol.Validate(Protocol.Build(messageType, p, "id-1"))
  assert(clean, reason)
  return clean
end

local function ann(overrides)
  return message("ANN", payload(overrides))
end

describe("AnnouncementSync.Apply authority", function()
  it("keeps an announcement from a gm or a cogm, with the sender as author", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      local ctx = context()
      assert.is_true(Sync.Apply(ctx, ann(), "Boss-Realm", role))
      local a = ctx.store.items["a-1"]
      assert.are.equal("Boss-Realm", a.author)
      assert.are.equal("Boss-Realm", a.updatedBy)
      assert.are.equal("Raid night", a.title)
      assert.are.same({ "a-1" }, ctx.applied)
    end
  end)

  it("drops ANN and ANN_DEL from every role without announce_manage, and from an unknown sender", function()
    for _, role in ipairs({ "officer", "rl", "roster", "member", "alter" }) do
      local ctx = context()
      local ok, reason = Sync.Apply(ctx, ann(), "Someone-Realm", role)
      assert.is_false(ok, role)
      assert.are.equal("forbidden", reason)
      assert.is_nil(next(ctx.store.items))
      ok, reason = Sync.Apply(ctx, message("ANN_DEL", { id = "a-1", rev = 2, updatedAt = 1 }), "Someone-Realm", role)
      assert.is_false(ok, role)
      assert.are.equal("forbidden", reason)
      assert.is_nil(next(ctx.store.tombstones))
    end
    local ctx = context()
    local ok, reason = Sync.Apply(ctx, ann(), "Ghost-Realm", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
  end)

  it("lets an officer's delete leave an existing announcement alone", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann(), "Gm-Realm", "gm"))
    assert.is_false(Sync.Apply(ctx, message("ANN_DEL", { id = "a-1", rev = 9, updatedAt = 1 }), "Off-Realm", "officer"))
    assert.is_truthy(ctx.store.items["a-1"])
  end)
end)

describe("AnnouncementSync.Apply conflicts", function()
  it("the higher revision wins, an older one is stale and an identical one is a no-op", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ rev = 2, title = "Second" }), "Gm-Realm", "gm"))
    local ok, reason = Sync.Apply(ctx, ann({ rev = 1, title = "First" }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal("Second", ctx.store.items["a-1"].title)
    ok, reason = Sync.Apply(ctx, ann({ rev = 2, title = "Second" }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_true(Sync.Apply(ctx, ann({ rev = 3, title = "Third" }), "Gm-Realm", "gm"))
    assert.are.equal("Third", ctx.store.items["a-1"].title)
  end)

  it("on equal revisions the later update wins, then the larger sender", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ rev = 2, updatedAt = 9100, title = "Later" }), "A-Realm", "gm"))
    assert.is_false(Sync.Apply(ctx, ann({ rev = 2, updatedAt = 9050, title = "Earlier" }), "Z-Realm", "gm"))
    assert.are.equal("Later", ctx.store.items["a-1"].title)
    assert.is_true(Sync.Apply(ctx, ann({ rev = 2, updatedAt = 9100, title = "Tie" }), "B-Realm", "cogm"))
    assert.are.equal("Tie", ctx.store.items["a-1"].title)
    assert.are.equal("B-Realm", ctx.store.items["a-1"].author)
  end)

  it("clamps a timestamp from the future", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ updatedAt = NOW + 1000000, createdAt = NOW + 1000000 }), "Gm-Realm", "gm"))
    assert.are.equal(NOW + 300, ctx.store.items["a-1"].updatedAt)
    assert.are.equal(NOW + 300, ctx.store.items["a-1"].createdAt)
  end)

  it("keeps the creation date of an announcement already known", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ createdAt = 5000 }), "Gm-Realm", "gm"))
    assert(Sync.Apply(ctx, ann({ rev = 2, createdAt = 9500 }), "Gm-Realm", "gm"))
    assert.are.equal(5000, ctx.store.items["a-1"].createdAt)
  end)

  it("an upsert replaces the whole announcement, so a field left out is cleared", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ expiresAt = NOW + 100 }), "Gm-Realm", "gm"))
    assert.are.equal(NOW + 100, ctx.store.items["a-1"].expiresAt)
    assert(Sync.Apply(ctx, ann({ rev = 2 }), "Gm-Realm", "gm"))
    assert.is_nil(ctx.store.items["a-1"].expiresAt)
  end)

  it("does not store a new announcement that has already expired", function()
    local ctx = context()
    local ok, reason = Sync.Apply(ctx, ann({ expiresAt = NOW - 1 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("expired", reason)
    assert.is_nil(next(ctx.store.items))
  end)
end)

describe("AnnouncementSync.Apply deletes", function()
  it("removes the announcement and a late stale upsert cannot bring it back", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann(), "Gm-Realm", "gm"))
    assert.is_true(Sync.Apply(ctx, message("ANN_DEL", { id = "a-1", rev = 2, updatedAt = 9100 }), "Gm-Realm", "gm"))
    assert.is_nil(ctx.store.items["a-1"])
    assert.are.equal(2, ctx.store.tombstones["a-1"].rev)
    local ok, reason = Sync.Apply(ctx, ann({ rev = 2 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("tombstoned", reason)
    ok, reason = Sync.Apply(ctx, ann({ rev = 1 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("tombstoned", reason)
    assert.is_nil(ctx.store.items["a-1"])
  end)

  it("a newer revision than the tombstone is a new life of the id", function()
    local ctx = context()
    assert(Sync.Apply(ctx, message("ANN_DEL", { id = "a-1", rev = 2, updatedAt = 9100 }), "Gm-Realm", "gm"))
    assert.is_true(Sync.Apply(ctx, ann({ rev = 3 }), "Gm-Realm", "gm"))
    assert.is_truthy(ctx.store.items["a-1"])
    assert.are.equal(3, ctx.store.items["a-1"].rev)
  end)

  it("remembers a delete of an announcement it does not know, so a late upsert is dropped", function()
    local ctx = context()
    assert.is_true(Sync.Apply(ctx, message("ANN_DEL", { id = "x-1", rev = 4, updatedAt = 9100 }), "Gm-Realm", "gm"))
    assert.are.equal(4, ctx.store.tombstones["x-1"].rev)
    assert.is_false(Sync.Apply(ctx, ann({ id = "x-1", rev = 3 }), "Gm-Realm", "gm"))
  end)

  it("ignores a delete that is not above the revision held", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ rev = 5 }), "Gm-Realm", "gm"))
    local ok, reason = Sync.Apply(ctx, message("ANN_DEL", { id = "a-1", rev = 5, updatedAt = 9100 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_truthy(ctx.store.items["a-1"])
  end)

  it("keeps the tombstones bounded", function()
    local ctx = context()
    for index = 1, Constants.ANNOUNCE_TOMBSTONE_MAX + 5 do
      ctx.now = function()
        return NOW + index
      end
      assert(Sync.Apply(ctx, message("ANN_DEL", { id = "d-" .. index, rev = 2, updatedAt = 9100 }), "Gm-Realm", "gm"))
    end
    assert.are.equal(Constants.ANNOUNCE_TOMBSTONE_MAX, ns.SyncRules.CountKeys(ctx.store.tombstones))
    assert.is_truthy(ctx.store.tombstones["d-" .. (Constants.ANNOUNCE_TOMBSTONE_MAX + 5)])
    assert.is_nil(ctx.store.tombstones["d-1"])
  end)
end)

describe("AnnouncementSync.Apply cap", function()
  local function fill(ctx, count, pinnedFrom)
    for index = 1, count do
      assert(
        Sync.Apply(
          ctx,
          ann({ id = "n-" .. index, createdAt = 1000 + index, pinned = pinnedFrom ~= nil and index >= pinnedFrom }),
          "Gm-Realm",
          "gm"
        )
      )
    end
  end

  it("drops the oldest unpinned one to take a newer announcement, and remembers it", function()
    local ctx = context()
    fill(ctx, Constants.ANNOUNCE_MAX)
    assert.is_true(Sync.Apply(ctx, ann({ id = "newest", createdAt = 5000 }), "Gm-Realm", "gm"))
    assert.are.equal(Constants.ANNOUNCE_MAX, ns.SyncRules.CountKeys(ctx.store.items))
    assert.is_nil(ctx.store.items["n-1"])
    assert.is_truthy(ctx.store.tombstones["n-1"])
    assert.is_truthy(ctx.store.items["newest"])
  end)

  it("never pushes out a pinned announcement", function()
    local ctx = context()
    fill(ctx, Constants.ANNOUNCE_MAX, 1)
    local ok, reason = Sync.Apply(ctx, ann({ id = "newest", createdAt = 5000 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_nil(ctx.store.items["newest"])
  end)

  it("does not let an older announcement push out newer ones", function()
    local ctx = context()
    fill(ctx, Constants.ANNOUNCE_MAX)
    local ok, reason = Sync.Apply(ctx, ann({ id = "ancient", createdAt = 10 }), "Gm-Realm", "gm")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_truthy(ctx.store.items["n-1"])
  end)

  it("a pinned newcomer takes the room of the oldest unpinned one", function()
    local ctx = context()
    fill(ctx, Constants.ANNOUNCE_MAX)
    assert.is_true(Sync.Apply(ctx, ann({ id = "pin", createdAt = 10, pinned = true }), "Gm-Realm", "gm"))
    assert.is_nil(ctx.store.items["n-1"])
  end)
end)

describe("AnnouncementSync snapshot", function()
  it("lists the live announcements newest first with their author, then the removals", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ id = "a", createdAt = 100 }), "Gm-Realm", "gm"))
    assert(Sync.Apply(ctx, ann({ id = "b", createdAt = 200 }), "Co-Realm", "cogm"))
    assert(Sync.Apply(ctx, ann({ id = "gone", createdAt = 300, expiresAt = NOW + 10 }), "Gm-Realm", "gm"))
    assert(Sync.Apply(ctx, message("ANN_DEL", { id = "x", rev = 3, updatedAt = 9100 }), "Gm-Realm", "gm"))
    local items = Sync.SnapshotItems(ctx.store, NOW + 20, 10)
    local seen = {}
    for _, item in ipairs(items) do
      seen[#seen + 1] = item.t .. ":" .. item.p.id
    end
    assert.are.same({ "ANN:b", "ANN:a", "ANN_DEL:x" }, seen)
    assert.are.equal("Co-Realm", items[1].author)
    assert.are.equal("Gm-Realm", items[2].author)
  end)

  it("respects the limit", function()
    local ctx = context()
    for index = 1, 5 do
      assert(Sync.Apply(ctx, ann({ id = "n-" .. index, createdAt = index }), "Gm-Realm", "gm"))
    end
    assert.are.equal(3, #Sync.SnapshotItems(ctx.store, NOW, 3))
    assert.are.equal(0, #Sync.SnapshotItems(ctx.store, NOW, 0))
  end)

  it("builds payloads that survive the protocol", function()
    local ctx = context()
    assert(Sync.Apply(ctx, ann({ expiresAt = NOW + 100 }), "Gm-Realm", "gm"))
    local built = Sync.UpsertPayload(ctx.store.items["a-1"])
    assert.is_nil(built.author)
    local clean = message("ANN", built)
    assert.are.equal(NOW + 100, clean.p.expiresAt)
    assert.is_nil(Sync.DeletePayload(ctx.store, "a-1"))
  end)
end)
