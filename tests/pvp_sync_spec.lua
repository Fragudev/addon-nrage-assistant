local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local PvPSync, Protocol, Constants = ns.PvPSync, ns.Protocol, ns.Constants

local NOW = 100000
local HOUR = 3600

local function context(overrides)
  local ctx = {
    pvpStats = {},
    pvpResets = {},
    now = function()
      return NOW
    end,
  }
  for k, v in pairs(overrides or {}) do
    ctx[k] = v
  end
  return ctx
end

local function payload(overrides)
  local p = {
    rev = 1,
    updatedAt = NOW - 10,
    honor = { world = 10, bg = 5 },
    blows = { world = 3, bg = 1 },
    today = { day = "2026-10-01", honor = { world = 2, bg = 1 }, blows = { world = 1, bg = 0 } },
  }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

-- A record with `world` honourable kills in total and none today, so that only the totals matter.
local function totals(world, overrides)
  local p = payload({
    honor = { world = world, bg = 0 },
    blows = { world = 0, bg = 0 },
    today = { day = "2026-10-01", honor = { world = 0, bg = 0 }, blows = { world = 0, bg = 0 } },
  })
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

local function message(messageType, body)
  return assert(Protocol.Validate(Protocol.Build(messageType, body, "id-1")))
end

local function stats(ctx, body, owner, role)
  return PvPSync.Apply(ctx, message("PVP_STATS", body), owner or "Ann", role or "member")
end

local function reset(ctx, target, rev, role)
  return PvPSync.Apply(ctx, message("PVP_RESET", { target = target, rev = rev }), "Boss", role or "admin")
end

describe("PvPSync.Apply PVP_STATS", function()
  it("stores the record under the sender, never under a name in the payload", function()
    local ctx = context()
    local body = payload()
    body.owner = "Victim"
    body.target = "Victim"
    assert.is_true(stats(ctx, body, "Ann"))
    assert.is_nil(ctx.pvpStats.Victim)
    local record = ctx.pvpStats.Ann
    assert.are.same({ world = 10, bg = 5 }, record.honor)
    assert.are.same({ world = 3, bg = 1 }, record.blows)
    assert.are.equal("2026-10-01", record.today.day)
    assert.are.equal(1, record.rev)
    assert.are.equal(NOW - 10, record.updatedAt)
    assert.are.equal(NOW, record.receivedAt)
  end)

  it("accepts every role and refuses a sender the roster does not know", function()
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      assert.is_true(stats(context(), payload(), "Ann", role))
    end
    local ctx = context()
    local ok, reason = PvPSync.Apply(ctx, message("PVP_STATS", payload()), "Stranger", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(ctx.pvpStats.Stranger)
  end)

  it("lets the newer record win and ignores a replay or an older one", function()
    local ctx = context()
    assert.is_true(stats(ctx, payload({ rev = 1 })))
    assert.is_true(stats(ctx, payload({ rev = 2, honor = { world = 12, bg = 5 } })))
    local ok, reason = stats(ctx, payload({ rev = 2, honor = { world = 12, bg = 5 } }))
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    ok, reason = stats(ctx, payload({ rev = 1 }))
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal(12, ctx.pvpStats.Ann.honor.world)
  end)

  it("ends in the same state whatever the order of arrival", function()
    local first = context()
    stats(first, payload({ rev = 1 }))
    stats(first, payload({ rev = 2, honor = { world = 14, bg = 5 } }))
    local second = context()
    stats(second, payload({ rev = 2, honor = { world = 14, bg = 5 } }))
    stats(second, payload({ rev = 1 }))
    assert.are.same(first.pvpStats, second.pvpStats)
  end)

  it("breaks a tie on the revision with the time, and clamps a time in the future", function()
    local ctx = context()
    assert.is_true(stats(ctx, payload({ rev = 3, updatedAt = NOW - 100 })))
    assert.is_true(stats(ctx, payload({ rev = 3, updatedAt = NOW - 50 })))
    assert.is_false(stats(ctx, payload({ rev = 3, updatedAt = NOW - 90 })))
    assert.is_true(stats(ctx, payload({ rev = 3, updatedAt = NOW + 5 * HOUR })))
    assert.are.equal(NOW + 300, ctx.pvpStats.Ann.updatedAt)
  end)

  it("accepts a first record within the maximum and nothing above it", function()
    local ctx = context()
    assert.is_true(stats(ctx, totals(Constants.PVP_MAX_KILLS)))
    local ok, reason = stats(context(), payload({ honor = { world = 600000, bg = 600000 } }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
    ok, reason = stats(context(), payload({ blows = { world = 600000, bg = 600000 } }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
  end)

  it("rejects a day that holds more than the total", function()
    local ctx = context()
    local ok, reason = stats(ctx, payload({ today = { day = "2026-10-01", honor = { world = 11, bg = 0 } } }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
    ok, reason = stats(
      ctx,
      payload({ today = { day = "2026-10-01", honor = { world = 1, bg = 0 }, blows = { world = 4, bg = 0 } } })
    )
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
    assert.is_nil(ctx.pvpStats.Ann)
  end)

  it("rejects totals that go down, in any bucket", function()
    local ctx = context()
    assert.is_true(stats(ctx, payload({ rev = 1 })))
    local lowered = {
      { honor = { world = 9, bg = 5 } },
      { honor = { world = 10, bg = 4 } },
      { blows = { world = 2, bg = 1 } },
      { blows = { world = 3, bg = 0 } },
    }
    for _, overrides in ipairs(lowered) do
      overrides.rev = 2
      local ok, reason = stats(ctx, payload(overrides))
      assert.is_false(ok)
      assert.are.equal("implausible", reason)
    end
    assert.are.equal(1, ctx.pvpStats.Ann.rev)
  end)

  it("limits the growth to the maximum per hour, with at least one hour's worth", function()
    local per_hour = Constants.PVP_MAX_KILLS_PER_HOUR
    local ctx = context()
    assert.is_true(stats(ctx, totals(100, { rev = 1, updatedAt = NOW - 100 })))
    -- Ten seconds later one hour's worth is allowed, not more.
    assert.is_true(stats(ctx, totals(100 + per_hour, { rev = 2, updatedAt = NOW - 90 })))
    local ok, reason = stats(ctx, totals(100 + 2 * per_hour + 1, { rev = 3, updatedAt = NOW - 80 }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)

    -- Ten hours after the stored record ten hours' worth is allowed.
    local later = context()
    assert.is_true(stats(later, totals(0, { rev = 1, updatedAt = NOW - 11 * HOUR })))
    ok, reason = stats(later, totals(10 * per_hour + 1, { rev = 2, updatedAt = NOW - HOUR }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
    assert.is_true(stats(later, totals(10 * per_hour, { rev = 2, updatedAt = NOW - HOUR })))
  end)

  it("keeps the known killing blows when a record comes without them", function()
    local ctx = context()
    assert.is_true(stats(ctx, payload({ rev = 1 })))
    local body = payload({
      rev = 2,
      honor = { world = 11, bg = 5 },
      today = { day = "2026-10-01", honor = { world = 3, bg = 1 } },
    })
    body.blows = nil
    assert.is_true(stats(ctx, body))
    assert.are.same({ world = 3, bg = 1 }, ctx.pvpStats.Ann.blows)
    assert.is_nil(ctx.pvpStats.Ann.today.blows)
  end)

  it("keeps the table within the guild roster maximum by dropping the record updated longest ago", function()
    local ctx = context()
    for index = 1, Constants.GUILD_ROSTER_MAX do
      ctx.pvpStats["Old" .. index] = { rev = 1, updatedAt = 1000 + index, honor = { world = 0, bg = 0 } }
    end
    assert.is_true(stats(ctx, payload(), "Newcomer"))
    local count = 0
    for _ in pairs(ctx.pvpStats) do
      count = count + 1
    end
    assert.are.equal(Constants.GUILD_ROSTER_MAX, count)
    assert.is_nil(ctx.pvpStats.Old1)
    assert.is_truthy(ctx.pvpStats.Old2)
    assert.is_truthy(ctx.pvpStats.Newcomer)
    -- A member who already has a record never evicts anybody.
    assert.is_true(stats(ctx, payload({ rev = 2 }), "Newcomer"))
    assert.is_truthy(ctx.pvpStats.Old2)
  end)
end)

describe("PvPSync.Apply PVP_RESET", function()
  local function populated()
    local ctx = context()
    assert.is_true(stats(ctx, payload({ rev = 5 })))
    return ctx
  end

  it("is refused to everyone but an admin", function()
    for _, role in ipairs({ "member", "rl", "council" }) do
      local ctx = populated()
      local ok, reason = reset(ctx, "Ann", 6, role)
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.are.equal(10, ctx.pvpStats.Ann.honor.world)
      assert.is_nil(ctx.pvpResets.Ann)
    end
    local ctx = populated()
    local ok, reason = PvPSync.Apply(ctx, message("PVP_RESET", { target = "Ann", rev = 6 }), "Stranger", nil)
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
  end)

  it("zeroes the record and raises the minimum revision", function()
    local ctx = populated()
    assert.is_true(reset(ctx, "Ann", 6))
    assert.are.same({ rev = 6 }, ctx.pvpResets.Ann)
    local record = ctx.pvpStats.Ann
    assert.are.same({ world = 0, bg = 0 }, record.honor)
    assert.is_nil(record.blows)
    assert.are.same({ world = 0, bg = 0 }, record.today.honor)
    assert.are.equal(6, record.rev)
  end)

  it("rejects the older records that come after it, but takes the next revision", function()
    local ctx = populated()
    assert.is_true(reset(ctx, "Ann", 6))
    for _, rev in ipairs({ 5, 6 }) do
      local ok, reason = stats(ctx, payload({ rev = rev }))
      assert.is_false(ok)
      assert.are.equal("reset", reason)
    end
    assert.is_true(stats(ctx, totals(20, { rev = 7 })))
    assert.are.equal(20, ctx.pvpStats.Ann.honor.world)
  end)

  it("does not let the old totals come back through a higher revision", function()
    local ctx = populated()
    assert.is_true(reset(ctx, "Ann", 4))
    -- The zeroed record starts the member from nothing at a believable pace.
    local ok, reason = stats(ctx, totals(5000, { rev = 9 }))
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
  end)

  it("remembers the floor of a member without a record, and keeps the highest one", function()
    local ctx = context()
    assert.is_true(reset(ctx, "Ghost", 8))
    assert.is_nil(ctx.pvpStats.Ghost)
    local ok, reason = reset(ctx, "Ghost", 3)
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    ok, reason = reset(ctx, "Ghost", 8)
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal(8, ctx.pvpResets.Ghost.rev)
    assert.is_true(reset(ctx, "Ghost", 9))
    assert.are.equal(9, ctx.pvpResets.Ghost.rev)
    local rejected
    ok, rejected = stats(ctx, payload({ rev = 9 }), "Ghost")
    assert.is_false(ok)
    assert.are.equal("reset", rejected)
  end)

  it("tells this client when its own counters were reset", function()
    local told = {}
    local ctx = context({
      ownKey = function()
        return "Me"
      end,
      onOwnReset = function(rev)
        told[#told + 1] = rev
      end,
    })
    assert.is_true(reset(ctx, "Ann", 3))
    assert.are.same({}, told)
    assert.is_true(reset(ctx, "Me", 4))
    assert.are.same({ 4 }, told)
    -- A replay changes nothing and does not zero the counters again.
    assert.is_false(reset(ctx, "Me", 4))
    assert.are.same({ 4 }, told)
  end)

  it("is refused for a non-admin even when it names this client", function()
    local told = 0
    local ctx = context({
      ownKey = function()
        return "Me"
      end,
      onOwnReset = function()
        told = told + 1
      end,
    })
    assert.is_false(reset(ctx, "Me", 4, "rl"))
    assert.are.equal(0, told)
  end)

  it("bounds the remembered floors", function()
    local ctx = context()
    for index = 1, Constants.GUILD_ROSTER_MAX do
      ctx.pvpResets["M" .. index] = { rev = 1 }
    end
    local ok, reason = reset(ctx, "OneMore", 2)
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_true(reset(ctx, "M1", 2))
  end)

  it("picks a revision above everything seen of the member", function()
    local ctx = populated()
    assert.are.equal(6, PvPSync.NextResetRev(ctx, "Ann"))
    assert.are.equal(1, PvPSync.NextResetRev(ctx, "Nobody"))
    ctx.pvpResets.Ann = { rev = 9 }
    assert.are.equal(10, PvPSync.NextResetRev(ctx, "Ann"))
  end)
end)

describe("PvPSync.Apply", function()
  it("does not handle other message types", function()
    local ok, reason = PvPSync.Apply(context(), { t = "HELLO", p = {} }, "Ann", "admin")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    assert.is_true(PvPSync.IsPvPMessage("PVP_STATS"))
    assert.is_true(PvPSync.IsPvPMessage("PVP_RESET"))
    assert.is_false(PvPSync.IsPvPMessage("PROFILE"))
  end)
end)

describe("PvPSync payloads", function()
  local own = {
    honor = { world = 4, bg = 6 },
    blows = { world = 1, bg = 2 },
    daily = { ["2026-10-01"] = { honor = { world = 1, bg = 2 }, blows = { world = 0, bg = 1 } } },
  }

  it("builds the own payload with the killing blows when they are available", function()
    local p = PvPSync.OwnPayload(own, 3, 500, "2026-10-01", true)
    assert.are.same({
      rev = 3,
      updatedAt = 500,
      honor = { world = 4, bg = 6 },
      blows = { world = 1, bg = 2 },
      today = { day = "2026-10-01", honor = { world = 1, bg = 2 }, blows = { world = 0, bg = 1 } },
    }, p)
    assert.is_truthy(Protocol.Validate(Protocol.Build("PVP_STATS", p, "id")))
  end)

  it("leaves the killing blows out when they are not available", function()
    local p = PvPSync.OwnPayload(own, 3, 500, "2026-10-01", false)
    assert.is_nil(p.blows)
    assert.is_nil(p.today.blows)
    assert.is_truthy(Protocol.Validate(Protocol.Build("PVP_STATS", p, "id")))
  end)

  it("lists the newest records and the highest resets for a snapshot, resets first", function()
    local ctx = context()
    for index, name in ipairs({ "Ann", "Bob", "Cid" }) do
      assert.is_true(stats(ctx, payload({ updatedAt = NOW - index * 10 }), name))
    end
    ctx.pvpResets = { Zed = { rev = 2 }, Yan = { rev = 5 } }
    ctx.pvpStats.Broken = "not a record"
    ctx.pvpStats.Hollow = { updatedAt = NOW, rev = 1 }

    local items = PvPSync.SnapshotItems(ctx, 2)
    assert.are.equal(4, #items)
    assert.are.same({ t = "PVP_RESET", p = { target = "Yan", rev = 5 } }, items[1])
    assert.are.same({ t = "PVP_RESET", p = { target = "Zed", rev = 2 } }, items[2])
    assert.are.equal("PVP_STATS", items[3].t)
    assert.are.equal("Ann", items[3].owner)
    assert.are.equal("Bob", items[4].owner)
    assert.is_nil(items[3].p.receivedAt)
    assert.is_truthy(Protocol.Validate(Protocol.Build("PVP_STATS", items[3].p, "id")))
  end)
end)
