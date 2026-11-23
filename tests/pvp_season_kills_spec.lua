-- Season points from kills: 1 point per world kill, 1 point per 5 battleground kills, counted per season and kept
-- in the all-time total when the season closes. Also the own counters restored from the record the guild holds.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/PvPService",
    "Domain/PvPTracker",
    "Domain/PvPSeasonModel",
    "Domain/PvPSeasonService",
    "Domain/EventModel",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSync",
    "Sync/PvPSeasonSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local PvPService, PvPSync, Protocol, Service, Sync =
  ns.PvPService, ns.PvPSync, ns.Protocol, ns.PvPSeasonService, ns.PvPSeasonSync

local DAY = 86400
local T0 = 1792454400
local ROLES = { Boss = "gm", Ann = "member", Bob = "member" }

describe("PvPService season kills", function()
  it("gives 1 point per world kill and 1 per 5 battleground kills, rounded down", function()
    assert.are.equal(0, PvPService.SeasonPoints(0, 4))
    assert.are.equal(1, PvPService.SeasonPoints(0, 5))
    assert.are.equal(2, PvPService.SeasonPoints(0, 14))
    assert.are.equal(7, PvPService.SeasonPoints(7, 0))
    assert.are.equal(10, PvPService.SeasonPoints(7, 17))
  end)

  it("counts the kills of a season in its own counters, besides the totals", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 3, "world", "2026-10-01", "S1")
    PvPService.RecordHonorKills(stats, 6, "bg", "2026-10-01", "S1")
    local world, bg = PvPService.SeasonKills(stats, "S1")
    assert.are.equal(3, world)
    assert.are.equal(6, bg)
    assert.are.equal(3, PvPService.Totals(stats).honor.world)
  end)

  it("starts the count from zero in a new season and keeps the all-time totals", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 10, "world", "2026-10-01", "S1")
    assert.are.same({ 0, 0 }, { PvPService.SeasonKills(stats, "S2") })
    PvPService.RecordHonorKills(stats, 2, "world", "2026-10-02", "S2")
    assert.are.same({ 2, 0 }, { PvPService.SeasonKills(stats, "S2") })
    assert.are.same({ 0, 0 }, { PvPService.SeasonKills(stats, "S1") })
    assert.are.equal(12, PvPService.Totals(stats).honor.world)
  end)

  it("keeps loading saved data that has no season counters", function()
    local stats = PvPService.Ensure({ honor = { world = 5, bg = 1 }, blows = { world = 0, bg = 0 }, daily = {} })
    assert.is_nil(stats.season)
    assert.are.same({ 0, 0 }, { PvPService.SeasonKills(stats, "S1") })
    PvPService.RecordHonorKills(stats, 1, "world", "2026-10-01")
    assert.is_nil(stats.season)
    assert.are.equal(6, PvPService.Totals(stats).honor.world)
  end)

  it("restores the own counters from the record the guild holds, never lowering them", function()
    local stats = PvPService.Ensure({})
    local record =
      { honor = { world = 150, bg = 40 }, blows = { world = 9, bg = 2 }, season = { id = "S1", world = 20, bg = 10 } }
    assert.is_true(PvPService.Adopt(stats, record))
    local totals = PvPService.Totals(stats)
    assert.are.same({ 150, 40 }, { totals.honor.world, totals.honor.bg })
    assert.are.same({ 9, 2 }, { totals.blows.world, totals.blows.bg })
    assert.are.same({ 20, 10 }, { PvPService.SeasonKills(stats, "S1") })
    stats.honor.world = 200
    assert.is_false(PvPService.Adopt(stats, record))
    assert.are.equal(200, PvPService.Totals(stats).honor.world)
  end)

  it("tells the tracker's kills to the active season", function()
    local stats = PvPService.Ensure({})
    local tracker_kills = 0
    local tracker = ns.PvPTracker.New({
      platform = {
        GetPvPSessionKills = function()
          return tracker_kills
        end,
        IsInBattleground = function()
          return false
        end,
        ServerTime = function()
          return T0
        end,
        ServerDay = function()
          return "2026-10-20"
        end,
      },
      stats = stats,
      seasonId = function()
        return "S1"
      end,
    })
    tracker:Start()
    tracker_kills = 4
    tracker:CheckHonor()
    assert.are.same({ 4, 0 }, { PvPService.SeasonKills(stats, "S1") })
  end)
end)

describe("PvP stats payload with season counters", function()
  local function context()
    return {
      pvpStats = {},
      pvpResets = {},
      now = function()
        return T0
      end,
    }
  end
  local function body(extra)
    local p = {
      rev = 1,
      updatedAt = T0 - 10,
      honor = { world = 30, bg = 10 },
      today = { day = "2026-10-20", honor = { world = 0, bg = 0 } },
    }
    for k, v in pairs(extra or {}) do
      p[k] = v
    end
    return p
  end

  it("carries the season counters of the sender and stores them", function()
    local ctx = context()
    local message = assert(
      Protocol.Validate(Protocol.Build("PVP_STATS", body({ season = { id = "S1", world = 12, bg = 7 } }), "id-1"))
    )
    assert.is_true(PvPSync.Apply(ctx, message, "Ann", "member"))
    assert.are.same({ id = "S1", world = 12, bg = 7 }, ctx.pvpStats.Ann.season)
  end)

  it("rejects season counters above the totals", function()
    local message =
      Protocol.Validate(Protocol.Build("PVP_STATS", body({ season = { id = "S1", world = 31, bg = 0 } }), "id-1"))
    local ok = message and PvPSync.Apply(context(), message, "Ann", "member")
    assert.is_falsy(ok)
  end)

  it("builds the own payload with the season counters", function()
    local stats = PvPService.Ensure({})
    PvPService.RecordHonorKills(stats, 4, "world", "2026-10-20", "S1")
    local payload = PvPSync.OwnPayload(stats, 1, T0, "2026-10-20", false)
    assert.are.same({ id = "S1", world = 4, bg = 0 }, payload.season)
  end)

  it("hands the own record that arrives from the guild to onOwnRecord", function()
    local ctx = context()
    local seen
    ctx.ownKey = function()
      return "Ann"
    end
    ctx.onOwnRecord = function(record)
      seen = record
    end
    local message = assert(Protocol.Validate(Protocol.Build("PVP_STATS", body(), "id-1")))
    assert.is_true(PvPSync.Apply(ctx, message, "Ann", "member", true))
    assert.are.equal(30, seen.honor.world)
    seen = nil
    PvPSync.Apply(ctx, message, "Bob", "member", true)
    assert.is_nil(seen)
  end)
end)

local function new_service(extra)
  local world = { clock = T0 + 100, ids = 0 }
  local kills = extra and extra.kills or {}
  local service = Service.New({
    ledger = Sync.NewLedger(),
    now = function()
      return world.clock
    end,
    newId = function()
      world.ids = world.ids + 1
      return "id-" .. world.ids
    end,
    ownName = function()
      return "Boss"
    end,
    ownRole = function()
      return "gm"
    end,
    roleOf = function(who)
      return ROLES[who]
    end,
    send = function()
      return true
    end,
    killPoints = function(seasonId)
      return kills[seasonId] or {}
    end,
  })
  service.world, service.kills = world, kills
  return service
end

describe("PvPSeasonService standings with kill points", function()
  it("adds the kill points to the points of the missions", function()
    local service = new_service()
    local season = assert(service:CreateSeason({ name = "One", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
    assert(service:UpsertMission({
      id = "m1",
      title = "Hunt",
      points = 10,
      goal = { kind = "manual" },
      repeatKind = "daily",
      perPlayer = 2,
    }))
    assert(service:DirectGrant("Boss", "m1", 10))
    service.kills[season.id] = { Boss = { points = 3, at = T0 }, Ann = { points = 8, at = T0 } }
    local rows = service:Standings()
    assert.are.same({ "Boss", "Ann" }, { rows[1].player, rows[2].player })
    assert.are.same({ 13, 8 }, { rows[1].points, rows[2].points })
  end)

  it("still ranks by missions alone when nobody has kills", function()
    local service = new_service()
    assert(service:CreateSeason({ name = "One", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
    assert(service:UpsertMission({
      id = "m1",
      title = "Hunt",
      points = 10,
      goal = { kind = "manual" },
      repeatKind = "daily",
      perPlayer = 2,
    }))
    assert(service:DirectGrant("Ann", "m1", 10))
    local rows = service:Standings()
    assert.are.same({ "Ann", 10 }, { rows[1].player, rows[1].points })
  end)

  it("keeps the points of a closed season in the all-time total and starts the next from zero", function()
    local service = new_service()
    local first = assert(service:CreateSeason({ name = "One", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
    service.kills[first.id] = { Ann = { points = 6, at = T0 } }
    assert(service:CloseSeason())
    local second = assert(service:CreateSeason({ name = "Two", startsAt = T0, endsAt = T0 + 60 * DAY }))
    -- The kills of the first season are not in the second one.
    assert.are.same({}, service:Standings(second.id))
    local cumulative = service:Cumulative()
    assert.are.same({ "Ann", 6 }, { cumulative[1].player, cumulative[1].points })
    assert.are.same({ "Ann", 6 }, { service:Standings(first.id)[1].player, service:Standings(first.id)[1].points })
  end)
end)
