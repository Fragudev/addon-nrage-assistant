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
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Constants = ns.BlacklistService, ns.Constants

local function context(role, overrides)
  local ctx = {
    blacklist = {},
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

describe("BlacklistService.Key", function()
  it("lowercases and drops spaces, so multi-word names have one key", function()
    assert.are.equal("yonemongg", Service.Key("Yonemon Gg"))
    assert.are.equal("yonemongg", Service.Key("  YONEMON   gg "))
    assert.are.equal("blackcoffee", Service.Key("Black Coffee"))
  end)

  it("drops a realm suffix", function()
    assert.are.equal("ann", Service.Key("Ann-ClassicBetaPvP"))
    assert.are.equal("yonemongg", Service.Key("Yonemon Gg-ClassicBetaPvP"))
  end)

  it("gives nil when nothing is left", function()
    assert.is_nil(Service.Key(""))
    assert.is_nil(Service.Key("   "))
    assert.is_nil(Service.Key("-Realm"))
    assert.is_nil(Service.Key(nil))
    assert.is_nil(Service.Key(5))
  end)
end)

describe("BlacklistService.CleanName and FirstWord", function()
  it("trims, joins runs of spaces and drops the realm", function()
    assert.are.equal("Yonemon Gg", Service.CleanName("  Yonemon    Gg-Realm "))
    assert.is_nil(Service.CleanName("  "))
    assert.is_nil(Service.CleanName(false))
  end)

  it("gives the first word only of a name with several", function()
    assert.are.equal("Yonemon", Service.FirstWord("Yonemon Gg"))
    assert.is_nil(Service.FirstWord("Ann"))
  end)
end)

describe("BlacklistService.Validate", function()
  it("returns the clean name, the reason and the key", function()
    local clean = Service.Validate("  Yonemon   Gg-Realm", "  stole loot ")
    assert.are.same({ name = "Yonemon Gg", reason = "stole loot", key = "yonemongg" }, clean)
  end)

  it("needs a name and a reason", function()
    assert.are.equal("empty_name", select(2, Service.Validate("", "x")))
    assert.are.equal("empty_name", select(2, Service.Validate(nil, "x")))
    assert.are.equal("empty_reason", select(2, Service.Validate("Ann", "")))
    assert.are.equal("empty_reason", select(2, Service.Validate("Ann", "   ")))
    assert.are.equal("empty_reason", select(2, Service.Validate("Ann", nil)))
  end)

  it("keeps the limits", function()
    local name = ("n"):rep(Constants.BLACKLIST_NAME_MAX)
    local reason = ("r"):rep(Constants.BLACKLIST_REASON_MAX)
    assert.is_truthy(Service.Validate(name, reason))
    assert.are.equal("long_name", select(2, Service.Validate(name .. "n", "x")))
    assert.are.equal("long_reason", select(2, Service.Validate("Ann", reason .. "r")))
  end)

  it("refuses text that could carry escapes or break a key", function()
    assert.are.equal("bad_name", select(2, Service.Validate("An|n", "x")))
    assert.are.equal("bad_name", select(2, Service.Validate("An:n", "x")))
    assert.are.equal("bad_name", select(2, Service.Validate("An\1n", "x")))
    assert.are.equal("bad_reason", select(2, Service.Validate("Ann", "|cffff0000red")))
    assert.are.equal("bad_reason", select(2, Service.Validate("Ann", "two\nlines")))
  end)
end)

describe("BlacklistService.Add", function()
  it("adds an entry stamped with the actor and the time", function()
    local ctx = context()
    local entry, key = Service.Add(ctx, "Yonemon Gg", "ninja")
    assert.are.equal("yonemongg", key)
    assert.are.same({
      name = "Yonemon Gg",
      reason = "ninja",
      addedBy = "Ann-Realm",
      addedAt = 1000,
      rev = 1,
      updatedAt = 1000,
      updatedBy = "Ann-Realm",
    }, entry)
    assert.are.equal(entry, ctx.blacklist.yonemongg)
  end)

  it("is open to every role that has one", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      assert.is_truthy(Service.Add(context(role), "Ann", "x"), role)
    end
    local entry, reason = Service.Add(context("stranger"), "Ann", "x")
    assert.is_nil(entry)
    assert.are.equal("forbidden", reason)
  end)

  it("reports invalid input and does not store it", function()
    local ctx = context()
    assert.are.equal("empty_reason", select(2, Service.Add(ctx, "Ann", "")))
    assert.is_nil(next(ctx.blacklist))
  end)

  it("lets the one who added a player change the reason, in any spelling", function()
    local ctx = context()
    Service.Add(ctx, "Yonemon Gg", "x")
    ctx.now = function()
      return 2000
    end
    local entry, key, updated = Service.Add(ctx, "yonemongg-Realm", "y")
    assert.are.equal("yonemongg", key)
    assert.is_true(updated)
    assert.are.equal(entry, ctx.blacklist.yonemongg)
    assert.are.same({
      name = "Yonemon Gg",
      reason = "y",
      addedBy = "Ann-Realm",
      addedAt = 1000,
      rev = 2,
      updatedAt = 2000,
      updatedBy = "Ann-Realm",
    }, ctx.blacklist.yonemongg)
  end)

  it("refuses to change the reason of a player somebody else added", function()
    local ctx = context()
    Service.Add(ctx, "Yonemon Gg", "x")
    ctx.actor = "Bob-Realm"
    local entry, reason = Service.Add(ctx, "yonemongg", "y")
    assert.is_nil(entry)
    assert.are.equal("not_author", reason)
    assert.are.equal("x", ctx.blacklist.yonemongg.reason)
    assert.are.equal(1, ctx.blacklist.yonemongg.rev)
  end)

  it("lets an admin change the reason of any entry and keeps who added it", function()
    local ctx = context()
    Service.Add(ctx, "Yonemon Gg", "x")
    ctx.actor, ctx.role = "Boss-Realm", "admin"
    local entry, _, updated = Service.Add(ctx, "yonemongg", "y")
    assert.is_true(updated)
    assert.are.equal("y", entry.reason)
    assert.are.equal("Ann-Realm", entry.addedBy)
    assert.are.equal("Boss-Realm", entry.updatedBy)
  end)

  it("tells who may edit an entry", function()
    local entry = { addedBy = "Ann-Realm" }
    assert.is_true(Service.CanEdit(entry, "ann-realm", "member"))
    assert.is_true(Service.CanEdit(entry, "Boss-Realm", "admin"))
    assert.is_false(Service.CanEdit(entry, "Bob-Realm", "member"))
    assert.is_false(Service.CanEdit(entry, "Bob-Realm", "rl"))
    assert.is_false(Service.CanEdit({}, "Bob-Realm", "member"))
    assert.is_false(Service.CanEdit(entry, nil, "member"))
  end)

  it("stops at the limit", function()
    local ctx = context()
    for index = 1, Constants.BLACKLIST_MAX do
      ctx.blacklist["p" .. index] = { name = "P" .. index }
    end
    local entry, reason = Service.Add(ctx, "One More", "x")
    assert.is_nil(entry)
    assert.are.equal("limit", reason)
  end)

  it("needs a revision above the removal it follows, and forgets the tombstone", function()
    local ctx = context("admin")
    Service.Add(ctx, "Ann", "x")
    Service.Remove(ctx, "ann")
    assert.are.equal(2, ctx.tombstones["B:ann"].rev)
    local entry = Service.Add(ctx, "Ann", "again")
    assert.are.equal(3, entry.rev)
    assert.is_nil(ctx.tombstones["B:ann"])
  end)
end)

describe("BlacklistService.Remove", function()
  it("removes the entry and leaves a tombstone above its revision", function()
    local ctx = context("admin")
    Service.Add(ctx, "Ann", "x")
    local ok, rev = Service.Remove(ctx, "ann")
    assert.is_true(ok)
    assert.are.equal(2, rev)
    assert.is_nil(ctx.blacklist.ann)
    assert.are.equal(2, ctx.tombstones["B:ann"].rev)
    assert.are.equal(1000, ctx.tombstones["B:ann"].at)
  end)

  it("is for admins only", function()
    for _, role in ipairs({ "member", "rl", "council" }) do
      local ctx = context(role)
      ctx.blacklist.ann = { name = "Ann", rev = 1 }
      local ok, reason = Service.Remove(ctx, "ann")
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.is_truthy(ctx.blacklist.ann)
      assert.is_nil(next(ctx.tombstones))
    end
  end)

  it("reports a player who is not listed", function()
    local ok, reason = Service.Remove(context("admin"), "ghost")
    assert.is_false(ok)
    assert.are.equal("not_found", reason)
  end)
end)

describe("BlacklistService.List and Find", function()
  local entries = {
    zed = { name = "Zed", reason = "a" },
    ann = { name = "ann", reason = "b" },
    yonemongg = { name = "Yonemon Gg", reason = "c" },
    broken = "oops",
  }

  it("lists copies sorted by name, skipping what is not an entry", function()
    local list = Service.List(entries)
    assert.are.same({ "ann", "Yonemon Gg", "Zed" }, { list[1].name, list[2].name, list[3].name })
    assert.are.equal("yonemongg", list[2].key)
    list[1].reason = "changed"
    assert.are.equal("b", entries.ann.reason)
  end)

  it("breaks ties between equal names by key", function()
    local list = Service.List({ b = { name = "Ann" }, a = { name = "ann" } })
    assert.are.same({ "a", "b" }, { list[1].key, list[2].key })
  end)

  it("finds a player by name in any spelling", function()
    local entry, key = Service.Find(entries, "YONEMON gg-Realm")
    assert.are.equal(entries.yonemongg, entry)
    assert.are.equal("yonemongg", key)
    assert.is_nil(Service.Find(entries, "ghost"))
    assert.is_nil(Service.Find(entries, ""))
  end)
end)

describe("BlacklistService.Match", function()
  local entries = {
    ann = { name = "Ann", reason = "a" },
    yonemongg = { name = "Yonemon Gg", reason = "b" },
  }

  it("matches the whole name, ignoring case, spaces and realm", function()
    local matches = Service.Match(entries, { "ANN-ClassicBetaPvP", "Yonemon Gg", "Other" })
    assert.are.equal(2, #matches)
    assert.are.equal("ann", matches[1].key)
    assert.are.equal("ANN-ClassicBetaPvP", matches[1].member)
    assert.is_false(matches[1].approximate)
    assert.are.equal(entries.ann, matches[1].entry)
    assert.are.equal("yonemongg", matches[2].key)
    assert.is_false(matches[2].approximate)
  end)

  it("matches the first word of a listed multi-word name as an approximate match", function()
    local matches = Service.Match(entries, { "Yonemon" })
    assert.are.equal(1, #matches)
    assert.are.equal("yonemongg", matches[1].key)
    assert.is_true(matches[1].approximate)
    assert.are.equal(entries.yonemongg, matches[1].entry)
  end)

  it("does not match a multi-word member on its first word, or the second word of a listed name", function()
    assert.are.same({}, Service.Match(entries, { "Yonemon Other", "Gg", "Yonemo" }))
  end)

  it("prefers the exact entry over a first-word guess", function()
    local both = { yonemon = { name = "Yonemon", reason = "x" }, yonemongg = entries.yonemongg }
    local matches = Service.Match(both, { "Yonemon" })
    assert.are.equal(1, #matches)
    assert.are.equal("yonemon", matches[1].key)
    assert.is_false(matches[1].approximate)
  end)

  it("names the alphabetically first listed name when several share the first word", function()
    local shared = {
      yonemonzz = { name = "Yonemon Zz", reason = "z" },
      yonemonaa = { name = "Yonemon Aa", reason = "a" },
    }
    local matches = Service.Match(shared, { "Yonemon" })
    assert.are.equal("yonemonaa", matches[1].key)
  end)

  it("ignores members that are not names, and entries that are not entries", function()
    assert.are.same({}, Service.Match({ broken = "oops", ann = false }, { "Ann", "", 5 }))
    assert.are.same({}, Service.Match({}, { "Ann" }))
    assert.are.same({}, Service.Match(entries, {}))
  end)
end)
