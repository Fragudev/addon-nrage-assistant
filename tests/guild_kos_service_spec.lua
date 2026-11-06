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
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Constants = ns.GuildKosService, ns.Constants

local function context(role, overrides)
  local ctx = {
    guildKos = {},
    tombstones = {},
    role = role or "member",
    actor = "Ann-Realm",
    now = function()
      return 1000
    end,
  }
  for k, v in pairs(overrides or {}) do
    ctx[k] = v
  end
  return ctx
end

describe("GuildKosService.Add", function()
  it("lets any member add a player with the actor as the author", function()
    for _, role in ipairs({ "alter", "member", "rl", "officer", "gm" }) do
      local ctx = context(role)
      local entry, key = Service.Add(ctx, { name = "Yonemon Gg-Realm", category = "gank", reason = " ninja " })
      assert.are.equal("yonemongg", key, role)
      assert.are.same({
        name = "Yonemon Gg",
        category = "gank",
        reason = "ninja",
        addedBy = "Ann-Realm",
        addedAt = 1000,
        rev = 1,
        updatedAt = 1000,
        updatedBy = "Ann-Realm",
      }, entry)
    end
  end)

  it("refuses a sender without a role", function()
    assert.are.same({ nil, "forbidden" }, { Service.Add(context(nil, { role = false }), { name = "Bob" }) })
  end)

  it("refuses what does not validate", function()
    assert.are.same({ nil, "bad_name" }, { Service.Add(context(), { name = "" }) })
    assert.are.same({ nil, "bad_category" }, { Service.Add(context(), { name = "Bob", category = "x" }) })
    assert.are.same({ nil, "long_reason" }, { Service.Add(context(), { name = "Bob", reason = ("r"):rep(101) }) })
  end)

  it("lets the author change the category and reason, bumping the revision and keeping who added it", function()
    local ctx = context("member")
    Service.Add(ctx, { name = "Bob", category = "gank" })
    ctx.now = function()
      return 2000
    end
    local entry, key, updated = Service.Add(ctx, { name = "Bob", category = "camp", reason = "afk" })
    assert.is_true(updated)
    assert.are.equal("bob", key)
    assert.are.equal(2, entry.rev)
    assert.are.equal("camp", entry.category)
    assert.are.equal(1000, entry.addedAt)
    assert.are.equal(2000, entry.updatedAt)
  end)

  it("stops another member from changing the entry, but not a gm or cogm", function()
    local ctx = context("member")
    Service.Add(ctx, { name = "Bob" })
    ctx.actor = "Cid-Realm"
    assert.are.same({ nil, "not_author" }, { Service.Add(ctx, { name = "Bob", category = "camp" }) })
    for _, role in ipairs({ "gm", "cogm" }) do
      ctx.role = role
      assert.is_table(Service.Add(ctx, { name = "Bob", category = "camp" }))
      assert.are.equal("Ann-Realm", ctx.guildKos.bob.addedBy)
      assert.are.equal("Cid-Realm", ctx.guildKos.bob.updatedBy)
    end
  end)

  it("needs the revision above the removal that is remembered", function()
    local ctx = context("member")
    ctx.tombstones["K:bob"] = { at = 1, rev = 4 }
    local entry = Service.Add(ctx, { name = "Bob" })
    assert.are.equal(5, entry.rev)
    assert.is_nil(ctx.tombstones["K:bob"])
  end)

  it("keeps the list within its limit", function()
    local ctx = context("member")
    for index = 1, Constants.INTEL_KOS_MAX do
      ctx.guildKos["k" .. index] = { name = "K" .. index, rev = 1, addedBy = "Ann-Realm" }
    end
    assert.are.same({ nil, "limit" }, { Service.Add(ctx, { name = "Late" }) })
    assert.is_table(Service.Add(ctx, { name = "K1", category = "camp" }))
  end)
end)

describe("GuildKosService.Remove", function()
  local function listed(role)
    local ctx = context("member")
    Service.Add(ctx, { name = "Bob" })
    ctx.role = role or "member"
    return ctx
  end

  it("lets the author remove the entry and leaves a tombstone above its revision", function()
    local ctx = listed()
    local ok, rev = Service.Remove(ctx, "bob")
    assert.is_true(ok)
    assert.are.equal(2, rev)
    assert.is_nil(ctx.guildKos.bob)
    assert.are.equal(2, ctx.tombstones["K:bob"].rev)
  end)

  it("lets gm and cogm remove any entry, and nobody else", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      local ctx = listed(role)
      ctx.actor = "Cid-Realm"
      assert.is_true(Service.Remove(ctx, "bob"), role)
    end
    for _, role in ipairs({ "member", "officer", "rl" }) do
      local ctx = listed(role)
      ctx.actor = "Cid-Realm"
      assert.are.same({ false, "forbidden" }, { Service.Remove(ctx, "bob") }, role)
      assert.is_table(ctx.guildKos.bob)
    end
  end)

  it("says when the player is not listed or the sender has no role", function()
    assert.are.same({ false, "not_found" }, { Service.Remove(context("member"), "bob") })
    assert.are.same({ false, "forbidden" }, { Service.Remove(context(nil, { role = false }), "bob") })
  end)
end)

describe("GuildKosService lists", function()
  it("lists copies by name and finds a player by name", function()
    local entries = {
      zed = { name = "zed" },
      amy = { name = "Amy" },
      broken = "oops",
    }
    local list = Service.List(entries)
    assert.are.same({ "amy", "zed" }, { list[1].key, list[2].key })
    list[1].name = "changed"
    assert.are.equal("Amy", entries.amy.name)
    local entry, key = Service.Find(entries, "AMY-Realm")
    assert.are.equal(entries.amy, entry)
    assert.are.equal("amy", key)
    assert.is_nil(Service.Find(entries, "Nobody"))
    assert.is_nil(Service.Find(entries, nil))
  end)
end)
