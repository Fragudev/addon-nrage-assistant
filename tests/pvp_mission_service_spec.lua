-- The detection side of the PvP missions: the kill log, battleground wins, progress, claims and their announcements,
-- on top of the real season service. Two clients stand in for the guild: an admin and a member.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/PvPSeasonModel",
    "Domain/IntelModel",
    "Domain/PvPSeasonService",
    "Domain/PvPUnitCache",
    "Domain/PvPMissionTracker",
    "Domain/PvPMissionService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSeasonSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Constants, Protocol, Sync = ns.Constants, ns.Protocol, ns.PvPSeasonSync

local DAY = 86400
local T0 = 1792454400 -- 2026-10-20 00:00 UTC
local ROLES = { Boss = "gm", Ann = "member" }

local function new_world()
  return { clock = T0 + 12 * 3600, mono = 0, ids = 0 }
end

-- A client: the season service plus, for `mission = true`, the mission service. `sent` is what went to the guild.
local function new_client(world, name, withMissions)
  local client = { name = name, sent = {}, changes = 0, timers = {}, cursor = 0 }
  client.season = ns.PvPSeasonService.New({
    ledger = Sync.NewLedger(),
    now = function()
      return world.clock
    end,
    newId = function()
      world.ids = world.ids + 1
      return "id-" .. world.ids
    end,
    ownName = function()
      return name
    end,
    ownRole = function()
      return ROLES[name]
    end,
    roleOf = function(who)
      return ROLES[who]
    end,
    send = function(messageType, payload, key)
      client.sent[#client.sent + 1] = { t = messageType, p = payload, key = key }
      return true
    end,
  })
  if withMissions then
    client.char = { pvpLog = { events = {}, version = 1 }, pvpClaims = {} }
    client.cache = ns.PvPUnitCache.New({
      now = function()
        return world.mono
      end,
    })
    client.world = {
      mapId = 1411,
      winner = nil,
      faction = "Alliance",
      inBg = true,
      bgInstance = 489,
      scoreRequests = 0,
      enemy = {},
    }
    client.active = true
    client.kosList = {}
    client.autoClaims = {}
    client.missions = ns.PvPMissionService.New({
      season = client.season,
      log = function()
        return client.char and client.char.pvpLog
      end,
      claims = function()
        return client.char and client.char.pvpClaims
      end,
      cache = client.cache,
      now = function()
        return world.clock
      end,
      platform = {
        GetPlayerMapId = function()
          return client.world.mapId
        end,
        GetEnemyPlayerInfo = function(unit)
          return client.world.enemy[unit]
        end,
        GetBattlegroundWinner = function()
          return client.world.winner
        end,
        GetPlayerFaction = function()
          return client.world.faction
        end,
        IsInBattleground = function()
          return client.world.inBg
        end,
        GetBattlegroundInstance = function()
          return client.world.inBg and client.world.bgInstance or nil
        end,
        RequestBattlegroundScore = function()
          client.world.scoreRequests = client.world.scoreRequests + 1
          return true
        end,
        HasBattlegroundWinner = function()
          return client.world.winnerApi ~= false
        end,
      },
      killsAvailable = function()
        return client.world.killsApi ~= false
      end,
      schedule = function(delay, fn)
        client.timers[#client.timers + 1] = { delay = delay, fn = fn }
      end,
      random = function(min)
        return min
      end,
      isActive = function()
        return client.active
      end,
      isGuildKos = function(victim)
        return client.kosList[victim] == true
      end,
      guildInGroup = function()
        return client.world.guildInGroup
      end,
      onAutoClaim = function(mission, claim)
        client.autoClaims[#client.autoClaims + 1] = { mission = mission.id, claim = claim.id }
      end,
      onChange = function()
        client.changes = client.changes + 1
      end,
    })
    client.missions.unitSource = true
    client.missions.winSource = true
  end
  return client
end

-- Delivers to `to` what `from` has sent since the last time, as the guild channel would.
local function relay(from, to)
  while from.cursor < #from.sent do
    from.cursor = from.cursor + 1
    local entry = from.sent[from.cursor]
    local message = assert(Protocol.Validate(Protocol.Build(entry.t, entry.p, "wire")))
    Sync.Apply(to.season:Context(), message, from.name)
  end
end

-- Runs the oldest timer of `client` (the timers are one shot).
local function fire(client)
  local timer = table.remove(client.timers, 1)
  timer.fn()
  return timer.delay
end

local function goal(extra)
  local base = { kind = "kills", count = 3, zones = {}, place = "any", distinct = "none" }
  for key, value in pairs(extra or {}) do
    base[key] = value
  end
  return base
end

-- The saved claims of `client` for the active season.
local function claims_of(client)
  return client.char.pvpClaims[client.season:ActiveSeason().id] or {}
end

local function kill(client, victim, where)
  return client.missions:OnHonorKill({ victim = victim, where = where or "world", time = client.season.now() })
end

-- An admin and a member with an active season and one mission each can claim.
local function setup(missionGoal, mission)
  local world = new_world()
  local admin = new_client(world, "Boss")
  local member = new_client(world, "Ann", true)
  assert(admin.season:CreateSeason({ name = "S1", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
  local fields = { id = "m1", title = "Hunt", points = 10, goal = goal(missionGoal), repeatKind = "daily" }
  for key, value in pairs(mission or {}) do
    fields[key] = value
  end
  assert(admin.season:UpsertMission(fields))
  relay(admin, member)
  return world, admin, member
end

describe("PvPMissionService bounties", function()
  it("saves the guild KOS flag with the kill and keeps it when the list changes", function()
    local _, admin, member = setup({ kind = "kos", count = 1, target = "Zed" })
    member.kosList.Zed = true
    assert.is_true(kill(member, "Zed"))
    assert.is_true(kill(member, "Amy"))
    member.kosList.Zed = nil
    assert.is_true(member.char.pvpLog.events[1].kos)
    assert.is_nil(member.char.pvpLog.events[2].kos)
    local claim = assert(member.missions:Claim("m1"))
    assert.is_true(claim.evidence[1].kos)
    relay(member, admin)
    assert.are.equal(1, #admin.season:Queue())
  end)

  it("does not complete a bounty for a victim that was not listed", function()
    local _, _, member = setup({ kind = "kos", count = 1, target = "Zed" })
    kill(member, "Zed")
    assert.is_false(member.missions:Progress("m1").complete)
  end)

  it("syncs the target to a member", function()
    local _, _, member = setup({ kind = "kos", count = 1, target = "Zed" })
    assert.are.equal("Zed", member.season:Mission("m1").goal.target)
  end)
end)

describe("PvPMissionService kill log", function()
  it("logs an honour kill with the map id, the place and the class and race the cache knows", function()
    local _, _, member = setup()
    member.cache:Remember("Zed", "MAGE", "ORC")
    assert.is_true(kill(member, "Zed", "bg"))
    local row = member.char.pvpLog.events[1]
    assert.are.same({
      kind = "kill",
      honor = true,
      at = T0 + 12 * 3600,
      victim = "Zed",
      mapId = 1411,
      place = "bg",
      class = "MAGE",
      race = "ORC",
    }, row)
    assert.are.equal(1, member.changes)
  end)

  it("leaves class, race and map id unknown when they are not readable", function()
    local _, _, member = setup()
    member.world.mapId = nil
    assert.is_true(kill(member, "Zed"))
    local row = member.char.pvpLog.events[1]
    assert.is_nil(row.mapId)
    assert.is_nil(row.class)
    assert.is_nil(row.race)
  end)

  it("logs a kill without an active season and counts it once the season arrives (backfill)", function()
    local world = new_world()
    local admin = new_client(world, "Boss")
    local member = new_client(world, "Ann", true)
    assert.is_true(kill(member, "Zed"))
    assert.is_true(kill(member, "Amy"))
    assert.are.equal(2, #member.char.pvpLog.events)
    assert(admin.season:CreateSeason({ name = "S1", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
    assert(admin.season:UpsertMission({ id = "m1", title = "Hunt", points = 10, goal = goal(), repeatKind = "daily" }))
    relay(admin, member)
    assert.are.equal(2, member.missions:Progress("m1").bars[1].done)
  end)

  it("keeps the kills when the season changes, and the claims stay with their season", function()
    local world, admin, member = setup()
    kill(member, "Zed")
    local first = member.season:ActiveSeason().id
    member.char.pvpClaims[first] = { c = { claim = { id = "c" }, state = "pending" } }
    assert(admin.season:CloseSeason(first))
    relay(admin, member)
    assert(admin.season:CreateSeason({ name = "S2", startsAt = T0 - DAY, endsAt = T0 + 60 * DAY }))
    relay(admin, member)
    world.clock = world.clock + 5
    assert.are_not.equal(first, member.season:ActiveSeason().id)
    kill(member, "Amy")
    assert.are.equal(2, #member.char.pvpLog.events)
    assert.are.equal("Zed", member.char.pvpLog.events[1].victim)
    assert.is_table(member.char.pvpClaims[first].c)
  end)

  it("counts two kills of the same victim seconds apart (the log is written before any merge)", function()
    local _, _, member = setup()
    kill(member, "Zed")
    kill(member, "Zed")
    assert.are.equal(2, #member.char.pvpLog.events)
    assert.are.equal(2, member.missions:Progress("m1").bars[1].done)
  end)

  it("rejects an unusable entry and a character without a saved log", function()
    local _, _, member = setup()
    assert.is_false(member.missions:OnHonorKill(nil))
    assert.is_false(member.missions:OnHonorKill({ victim = "Zed" }))
    assert.is_false(member.missions:OnHonorKill({ time = T0 }))
    assert.are.equal(0, #member.char.pvpLog.events)
    member.char = nil
    assert.is_false(kill(member, "Zed"))
    assert.are.same({}, member.missions:Events())
  end)

  it("logs a kill outside the season dates but does not count it", function()
    local _, _, member = setup()
    assert.is_true(member.missions:OnHonorKill({ victim = "Zed", where = "world", time = T0 - 5 * DAY }))
    assert.are.equal(1, #member.char.pvpLog.events)
    assert.are.equal(0, member.missions:Progress("m1").bars[1].done)
  end)

  it("keeps at most PVP_LOG_EVENTS_MAX rows, dropping the oldest", function()
    local _, _, member = setup()
    for index = 1, Constants.PVP_LOG_EVENTS_MAX + 3 do
      member.missions:OnHonorKill({ victim = "V" .. index, where = "world", time = T0 + index })
    end
    assert.are.equal(Constants.PVP_LOG_EVENTS_MAX, #member.char.pvpLog.events)
    assert.are.equal("V4", member.char.pvpLog.events[1].victim)
  end)

  it("drops rows older than the retention", function()
    local _, _, member = setup()
    local now = T0 + 12 * 3600
    member.char.pvpLog.events = {
      { kind = "kill", at = now - (Constants.PVP_LOG_RETENTION_DAYS + 1) * DAY, victim = "Old", place = "world" },
      { kind = "kill", at = now - 5 * DAY, victim = "Recent", place = "world" },
    }
    kill(member, "Zed")
    assert.are.equal(2, #member.char.pvpLog.events)
    assert.are.equal("Recent", member.char.pvpLog.events[1].victim)
    assert.are.equal("Zed", member.char.pvpLog.events[2].victim)
  end)
end)

describe("PvPMissionService unit cache feed", function()
  it("remembers the enemy players it sees, also before a season is known", function()
    local world = new_world()
    local lone = new_client(world, "Ann", true)
    lone.world.enemy.target = { name = "Zed", class = "MAGE", race = "ORC" }
    assert.is_true(lone.missions:OnUnit("target"))
    kill(lone, "Zed")
    assert.are.equal("MAGE", lone.char.pvpLog.events[1].class)

    local _, _, member = setup()
    member.world.enemy.target = { name = "Zed", class = "MAGE", race = "ORC" }
    assert.is_true(member.missions:OnUnit("target"))
    assert.is_false(member.missions:OnUnit("mouseover"))
    kill(member, "Zed")
    assert.are.equal("MAGE", member.char.pvpLog.events[1].class)
    assert.are.equal("ORC", member.char.pvpLog.events[1].race)
  end)
end)

describe("PvPMissionService battleground results", function()
  local function results(member)
    local list = {}
    for _, row in ipairs(member.char.pvpLog.events) do
      if row.kind == "bg" then
        list[#list + 1] = row.result
      end
    end
    return list
  end

  it("logs a win of the own side once per battleground", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = "Alliance"
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.is_false(member.missions:OnBattlegroundStatus())
    assert.are.same(
      { kind = "bg", result = "win", bg = "wsg", at = T0 + 12 * 3600, mapId = 1411 },
      member.char.pvpLog.events[1]
    )
    assert.are.equal(1, #member.char.pvpLog.events)
    assert.is_true(member.missions:Progress("m1").complete)
  end)

  it("logs a loss as a loss (it does not count as a win), and nothing for an undecided battleground", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = nil
    assert.is_false(member.missions:OnBattlegroundStatus())
    member.world.winner = "Horde"
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.are.same({ "loss" }, results(member))
    assert.is_false(member.missions:Progress("m1").complete)
  end)

  it("ignores a unit outside a battleground and an unknown faction", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = "Alliance"
    member.world.inBg = false
    assert.is_false(member.missions:OnBattlegroundStatus())
    member.world.inBg = true
    member.world.faction = nil
    assert.is_false(member.missions:OnBattlegroundStatus())
    assert.are.equal(0, #member.char.pvpLog.events)
  end)

  it("works for a Horde player too: the winner is compared with the own faction", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.faction = "Horde"
    member.world.winner = "Horde"
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.are.same({ "win" }, results(member))
  end)

  it("takes the result from the score update when the status did not give it", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = "Alliance"
    assert.is_true(member.missions:OnBattlegroundScore())
    assert.is_false(member.missions:OnBattlegroundStatus())
    assert.are.same({ "win" }, results(member))
  end)

  it("logs a winner that was seen but never logged when the player leaves", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.missions:OnWorldEntered(false, false)
    -- the faction could not be read while inside: the winner is remembered but nothing is logged
    member.world.faction = nil
    member.world.winner = "Alliance"
    assert.is_false(member.missions:OnBattlegroundStatus())
    assert.are.equal(0, #member.char.pvpLog.events)
    member.world.faction = "Alliance"
    member.world.inBg = false
    member.missions:OnWorldEntered(false, false)
    assert.are.same({ "win" }, results(member))
    assert.is_nil(member.char.pvpLog.bg)
  end)

  it("logs nothing on leaving when no winner was ever seen", function()
    local _, _, member = setup()
    member.missions:OnWorldEntered(false, false)
    member.world.inBg = false
    member.missions:OnWorldEntered(false, false)
    assert.are.equal(0, #member.char.pvpLog.events)
  end)

  it("does not log twice after a reload or a login in the same battleground, but does for the next one", function()
    local world, _, member = setup({ kind = "bg_wins", count = 1 })
    member.missions:OnWorldEntered(false, false)
    member.world.winner = "Alliance"
    assert.is_true(member.missions:OnBattlegroundStatus())
    member.missions:OnWorldEntered(false, true)
    assert.is_false(member.missions:OnBattlegroundStatus())
    member.missions:OnWorldEntered(true, false)
    assert.is_false(member.missions:OnBattlegroundStatus())
    assert.are.equal(1, #member.char.pvpLog.events)
    -- a loading screen into another world and back into a battleground is a new one
    member.missions:OnWorldEntered(false, false)
    world.clock = world.clock + 60
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.are.equal(2, #member.char.pvpLog.events)
  end)

  it("counts two wins 20 minutes apart", function()
    local world, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = "Alliance"
    assert.is_true(member.missions:OnBattlegroundStatus())
    member.missions:OnWorldEntered(false, false)
    world.clock = world.clock + 20 * 60
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.are.equal(2, #member.char.pvpLog.events)
  end)

  it("tells a battleground type from another by the map id of the instance", function()
    local _, _, member = setup()
    member.world.winner = "Alliance"
    member.world.bgInstance = 529
    member.missions:OnWorldEntered(false, false)
    member.missions:OnBattlegroundStatus()
    assert.are.equal("ab", member.char.pvpLog.events[1].bg)
    member.world.inBg = false
    member.missions:OnWorldEntered(false, false)
    member.world.inBg = true
    member.world.bgInstance = 30
    member.missions:OnWorldEntered(false, false)
    member.missions:OnBattlegroundStatus()
    assert.are.equal("av", member.char.pvpLog.events[2].bg)
  end)

  it("logs a result without a season too (kept for when the season arrives)", function()
    local lone = new_client(new_world(), "Ann", true)
    lone.world.winner = "Alliance"
    assert.is_true(lone.missions:OnBattlegroundStatus())
    assert.are.equal(1, #lone.char.pvpLog.events)
  end)

  it("keeps working when the client cannot name the instance", function()
    local _, _, member = setup()
    member.missions.deps.platform.GetBattlegroundInstance = nil
    member.world.winner = "Alliance"
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.is_nil(member.char.pvpLog.events[1].bg)
    assert.is_false(member.missions:OnBattlegroundStatus())
  end)

  describe("score requests", function()
    it("asks for the score after combat only inside a battleground whose result is not logged", function()
      local _, _, member = setup()
      assert.is_true(member.missions:OnCombatEnded())
      assert.are.equal(1, member.world.scoreRequests)
      member.world.inBg = false
      assert.is_false(member.missions:OnCombatEnded())
      member.world.inBg = true
      member.world.winner = "Alliance"
      member.missions:OnBattlegroundStatus()
      assert.is_false(member.missions:OnCombatEnded())
      assert.are.equal(1, member.world.scoreRequests)
    end)

    it("asks every 30 seconds while inside a battleground, once per loop, and stops when it ends", function()
      local _, _, member = setup()
      member.missions:OnWorldEntered(false, false)
      member.missions:OnWorldEntered(false, false)
      assert.are.equal(1, member.world.scoreRequests)
      assert.are.equal(1, #member.timers)
      assert.are.equal(Constants.PVP_BG_SCORE_POLL_SECONDS, member.timers[1].delay)
      fire(member)
      assert.are.equal(2, member.world.scoreRequests)
      assert.are.equal(1, #member.timers)
      member.world.inBg = false
      fire(member)
      assert.are.equal(2, member.world.scoreRequests)
      assert.are.equal(0, #member.timers)
      assert.is_false(member.missions.scoring)
    end)

    it("stops the loop when the addon is no longer active", function()
      local _, _, member = setup()
      member.missions:OnWorldEntered(false, false)
      member.active = false
      fire(member)
      assert.are.equal(0, #member.timers)
    end)
  end)

  it("counts a class mission with the enemy classes of the other side for a Horde player", function()
    local _, _, member = setup({ kind = "kills", distinct = "class", count = 1 }, { repeatKind = "once" })
    member.world.faction = "Horde"
    local classes = Constants.PVP_ENEMY_CLASSES_BY_FACTION.Horde
    assert.is_truthy(classes)
    for index, class in ipairs(classes) do
      member.cache:Remember("C" .. index, class, "HUMAN")
      kill(member, "C" .. index)
    end
    local bar = member.missions:Progress("m1").bars[1]
    assert.are.same({ label = "Classes", done = #classes, total = #classes }, bar)
    member.world.faction = "Alliance"
    -- the same kills read against the other side's list: the paladin is not an enemy class there
    assert.are.equal(#classes - 1, member.missions:Progress("m1").bars[1].done)
  end)
end)

describe("PvPMissionService availability", function()
  it("says which sources this client has", function()
    local _, _, member = setup()
    assert.are.same({ kills = true, zones = true, classRace = true, bgWins = true }, member.missions:Availability())
    member.world.killsApi = false
    member.world.winnerApi = false
    member.missions.unitSource = false
    assert.are.same({ kills = false, zones = false, classRace = false, bgWins = false }, member.missions:Availability())
    member.world.killsApi = true
    member.world.mapId = nil
    member.missions.winSource = false
    local availability = member.missions:Availability()
    assert.is_true(availability.kills)
    assert.is_false(availability.zones)
    assert.is_false(availability.bgWins)
  end)
end)

describe("PvPMissionService progress and claims", function()
  local function kills(member, count)
    for index = 1, count do
      kill(member, "Victim" .. index)
    end
  end

  it("gives nothing for an unknown mission or a mission of another season", function()
    local _, _, member = setup()
    assert.is_nil(member.missions:Progress("nope"))
    assert.are.equal("none", member.missions:ClaimState("nope"))
    local nobody = new_client(new_world(), "Ann", true)
    assert.is_nil(nobody.missions:Progress("m1"))
  end)

  it("reports the progress of a mission", function()
    local _, _, member = setup()
    kills(member, 2)
    local progress = member.missions:Progress("m1")
    assert.are.same({ { label = "Kills", done = 2, total = 3 } }, progress.bars)
    assert.are.equal(0, progress.unknown)
    assert.is_false(progress.complete)
    assert.is_false(progress.claimable)
    assert.are.equal("20261020", progress.periodKey)
    assert.are.equal(2, #progress.evidence)
    assert.are.equal("none", member.missions:ClaimState("m1"))
  end)

  it("refuses a claim that is not complete, paused or beyond the limit", function()
    local _, admin, member = setup()
    kills(member, 2)
    assert.are.same({ nil, "not_complete" }, { member.missions:Claim("m1") })
    assert.are.same({ nil, "unknown_mission" }, { member.missions:Claim("nope") })
    kills(member, 3)
    assert.is_truthy(member.missions:Claim("m1"))
    assert.are.same({ nil, "limit" }, { member.missions:Claim("m1") })
    assert(admin.season:SetMissionActive("m1", false))
    relay(admin, member)
    assert.are.same({ nil, "inactive" }, { member.missions:Claim("m1") })
  end)

  it("sends a claim with the evidence and the summary, and keeps it pending", function()
    local _, admin, member = setup()
    kills(member, 3)
    local claim, queued = member.missions:Claim("m1", "  ")
    assert.is_truthy(claim)
    assert.is_true(queued)
    assert.are.equal("Ann:m1:20261020:1", claim.id)
    local sent = member.sent[#member.sent]
    assert.are.equal("PVP_CLAIM", sent.t)
    assert.are.equal(3, #sent.p.evidence)
    assert.are.equal(3, sent.p.summary.done)
    assert.are.equal(3, sent.p.summary.total)
    assert.are.equal("pending", member.missions:ClaimState("m1"))
    assert.are.equal("pending", claims_of(member)[claim.id].state)
    relay(member, admin)
    assert.are.equal(1, #admin.season:Queue())
    assert.is_true(member.changes >= 4)
  end)

  it("follows the decision of the approver", function()
    local _, admin, member = setup()
    kills(member, 3)
    local claim = member.missions:Claim("m1")
    relay(member, admin)
    assert(admin.season:Reject(claim.id, "no"))
    relay(admin, member)
    assert.are.equal("rejected", member.missions:ClaimState("m1"))
    -- a grant beats a rejection
    assert(admin.season:Approve(claim.id))
    relay(admin, member)
    assert.are.equal("approved", member.missions:ClaimState("m1"))
    assert.are.equal("approved", claims_of(member)[claim.id].state)
    -- the approved claim is not announced again
    assert.are.equal(0, member.missions:Reannounce())
  end)

  it("takes the best state when a period has several claims", function()
    local _, admin, member = setup({}, { perPlayer = 2 })
    kills(member, 3)
    local first = member.missions:Claim("m1")
    local second = member.missions:Claim("m1")
    assert.are.equal("Ann:m1:20261020:2", second.id)
    relay(member, admin)
    assert(admin.season:Reject(first.id))
    relay(admin, member)
    assert.are.equal("pending", member.missions:ClaimState("m1"))
  end)

  it("claims a class mission when the unknown ones could complete it, with the unknown ones as evidence", function()
    local _, _, member = setup({ kind = "kills", distinct = "class", count = 1 }, { repeatKind = "once" })
    local classes = Constants.PVP_ENEMY_CLASSES
    for index = 1, #classes - 1 do
      member.cache:Remember("C" .. index, classes[index], "ORC")
      kill(member, "C" .. index)
    end
    assert.are.same({ nil, "not_complete" }, { member.missions:Claim("m1") })
    kill(member, "Mystery")
    local progress = member.missions:Progress("m1")
    assert.are.equal(1, progress.unknown)
    assert.is_true(progress.claimable)
    local claim = assert(member.missions:Claim("m1"))
    assert.are.equal(#classes - 1, claim.summary.classes)
    assert.are.equal(#classes, claim.summary.classesTotal)
    assert.are.equal(1, claim.summary.unknown)
    assert.are.equal("Mystery", claim.evidence[#claim.evidence].victim)
  end)

  it("needs a note for a manual mission", function()
    local _, _, member = setup({ kind = "manual", count = 1 })
    assert.are.same({ nil, "invalid:note" }, { member.missions:Claim("m1") })
    assert.are.same({ nil, "invalid:note" }, { member.missions:Claim("m1", "") })
    local claim = assert(member.missions:Claim("m1", "Won the duel tournament"))
    assert.are.equal("Won the duel tournament", claim.note)
    assert.are.equal(0, #claim.evidence)
  end)

  it("claims a battleground mission with the win as evidence", function()
    local _, _, member = setup({ kind = "bg_wins", count = 1 })
    member.world.winner = "Alliance"
    member.missions:OnBattlegroundStatus()
    local claim = assert(member.missions:Claim("m1"))
    assert.are.same({ at = T0 + 12 * 3600, bgWin = true, mapId = 1411, bg = "wsg" }, claim.evidence[1])
  end)

  it("sends the largest evidence a client can build", function()
    local _, admin, member = setup({ count = 500 }, { repeatKind = "once" })
    local name = string.rep("n", Constants.PVP_FEED_VICTIM_MAX)
    for index = 1, Constants.PVP_CLAIM_EVIDENCE_MAX + 40 do
      member.cache:Remember(name .. index, "WARRIOR", "TAUREN")
      member.missions:OnHonorKill({
        victim = (name .. index):sub(1, Constants.PVP_FEED_VICTIM_MAX),
        where = "bg",
        time = T0 + index,
      })
    end
    -- 500 are needed: top the log up with distinct victims
    for index = 1, 500 do
      member.missions:OnHonorKill({ victim = "Fill" .. index, where = "world", time = T0 + 1000 + index })
    end
    local claim = assert(member.missions:Claim("m1"))
    assert.are.equal(Constants.PVP_CLAIM_EVIDENCE_MAX, #claim.evidence)
    assert.are.equal(Constants.PVP_CLAIM_EVIDENCE_MAX, #member.sent[#member.sent].p.evidence)
    relay(member, admin)
    assert.are.equal(1, #admin.season:Queue())
  end)
end)

describe("PvPMissionService mission options", function()
  it("saves the guild members in the group with the kill, and counts it for a group mission", function()
    local _, _, member = setup({ count = 2, minGuildInGroup = 3 })
    member.world.guildInGroup = 3
    kill(member, "A")
    member.world.guildInGroup = 1
    kill(member, "B")
    member.world.guildInGroup = nil
    kill(member, "C")
    assert.are.equal(3, member.char.pvpLog.events[1].guildInGroup)
    assert.are.equal(1, member.char.pvpLog.events[2].guildInGroup)
    assert.is_nil(member.char.pvpLog.events[3].guildInGroup)
    local progress = member.missions:Progress("m1")
    assert.are.equal(1, progress.bars[1].done)
    assert.are.equal(3, progress.evidence[1].guild)
  end)

  it("keeps logging when the group cannot be read", function()
    local _, _, member = setup()
    member.missions.deps.guildInGroup = function()
      error("restricted")
    end
    assert.is_true(kill(member, "A"))
    assert.is_nil(member.char.pvpLog.events[1].guildInGroup)
  end)

  it("claims the mission by itself when the log completes it, once, and tells the wiring", function()
    local _, admin, member = setup({ count = 2, autoClaim = true })
    kill(member, "A")
    assert.are.equal(0, #member.autoClaims)
    kill(member, "B")
    assert.are.same({ { mission = "m1", claim = "Ann:m1:20261020:1" } }, member.autoClaims)
    assert.are.equal("pending", member.missions:ClaimState("m1"))
    kill(member, "C")
    assert.are.equal(1, #member.autoClaims)
    relay(member, admin)
    assert.are.equal(1, #admin.season:Queue())
  end)

  it("does not claim by itself without the option, and never for a manual mission", function()
    local _, _, member = setup({ count = 1 })
    kill(member, "A")
    assert.are.equal(0, #member.autoClaims)
    assert.are.equal("none", member.missions:ClaimState("m1"))
    local _, _, other = setup({ kind = "manual", autoClaim = true })
    assert.are.equal(0, other.missions:AutoClaim())
  end)

  it("claims a battleground mission by itself when the result arrives", function()
    local _, _, member = setup({ kind = "bg_played", count = 1, autoClaim = true })
    member.world.winner = "Horde"
    assert.is_true(member.missions:OnBattlegroundStatus())
    assert.are.equal(1, #member.autoClaims)
  end)

  it("refuses a claim past maxCompletions", function()
    local _, _, member = setup({ count = 1, maxCompletions = 1 }, { perPlayer = 3 })
    kill(member, "A")
    assert(member.missions:Claim("m1"))
    assert.are.same({ nil, "limit" }, { member.missions:Claim("m1") })
    assert.is_true(member.missions:Progress("m1").maxedOut)
  end)

  it("does not count a rejected claim against maxCompletions", function()
    local _, admin, member = setup({ count = 1, maxCompletions = 1 }, { perPlayer = 3 })
    kill(member, "A")
    local claim = assert(member.missions:Claim("m1"))
    relay(member, admin)
    assert(admin.season:Reject(claim.id, "no"))
    relay(admin, member)
    claims_of(member)[claim.id].state = "rejected"
    assert.is_truthy(member.missions:Claim("m1"))
  end)
end)

describe("PvPMissionService approver HELLO", function()
  local function pending_claim()
    local world, admin, member = setup()
    for index = 1, 3 do
      kill(member, "Victim" .. index)
    end
    local claim = assert(member.missions:Claim("m1"))
    member.timers = {}
    member.missions.looping = false
    return world, admin, member, claim
  end

  it("sends the pending claims again after the login delay when a gm or cogm shows up", function()
    local _, admin, member, claim = pending_claim()
    local before = #member.sent
    assert.is_true(member.missions:OnApproverSeen())
    assert.are.equal(1, #member.timers)
    assert.are.equal(Constants.PVP_LOGIN_SEND_DELAY_MIN, member.timers[1].delay)
    assert.are.equal(before, #member.sent)
    fire(member)
    assert.are.equal(before + 1, #member.sent)
    assert.are.equal("PC:" .. claim.id, member.sent[#member.sent].key)
    relay(member, admin)
    assert.are.equal(1, #admin.season:Queue())
  end)

  it("does it at most once per cooldown, and again after it", function()
    local world, _, member = pending_claim()
    assert.is_true(member.missions:OnApproverSeen())
    assert.is_false(member.missions:OnApproverSeen())
    world.clock = world.clock + Constants.PVP_CLAIM_HELLO_COOLDOWN_SECONDS
    assert.is_true(member.missions:OnApproverSeen())
  end)

  it("does nothing without a pending claim, once decided, or when the addon is off", function()
    local _, admin, member, claim = pending_claim()
    member.active = false
    assert.is_false(member.missions:OnApproverSeen())
    member.active = true
    relay(member, admin)
    assert(admin.season:Approve(claim.id))
    relay(admin, member)
    assert.is_false(member.missions:OnApproverSeen())
    local _, _, other = setup()
    assert.is_false(other.missions:OnApproverSeen())
  end)

  it("sends nothing if the addon went off during the delay", function()
    local _, _, member = pending_claim()
    member.missions:OnApproverSeen()
    member.active = false
    local before = #member.sent
    fire(member)
    assert.are.equal(before, #member.sent)
  end)
end)

describe("PvPMissionService announcements", function()
  local function pending_claim()
    local world, admin, member = setup()
    for index = 1, 3 do
      kill(member, "Victim" .. index)
    end
    local claim = assert(member.missions:Claim("m1"))
    member.timers = {}
    member.missions.looping = false
    return world, admin, member, claim
  end

  it("announces the pending claims again after the login delay, then every interval while any is pending", function()
    local _, admin, member, claim = pending_claim()
    member.missions:StartAnnouncing()
    member.missions:StartAnnouncing()
    assert.are.equal(1, #member.timers)
    assert.are.equal(Constants.PVP_LOGIN_SEND_DELAY_MIN, member.timers[1].delay)
    local before = #member.sent
    fire(member)
    assert.are.equal(before + 1, #member.sent)
    assert.are.equal("PC:" .. claim.id, member.sent[#member.sent].key)
    assert.are.same(member.sent[before].p, member.sent[#member.sent].p)
    -- still pending: the next round is planned
    assert.are.equal(1, #member.timers)
    assert.are.equal(Constants.PVP_CLAIM_REANNOUNCE_SECONDS, member.timers[1].delay)
    -- an approver who was offline gets it from the repeat, and decides
    relay(member, admin)
    assert(admin.season:Approve(claim.id))
    relay(admin, member)
    fire(member)
    assert.are.equal(before + 1, #member.sent)
    assert.are.equal(0, #member.timers)
    assert.is_false(member.missions:HasPending())
  end)

  it("plans the repeat when a claim is made, once", function()
    local _, _, member = setup()
    for index = 1, 3 do
      kill(member, "Victim" .. index)
    end
    member.timers = {}
    assert(member.missions:Claim("m1"))
    assert.are.equal(1, #member.timers)
    assert.are.equal(Constants.PVP_CLAIM_REANNOUNCE_SECONDS, member.timers[1].delay)
    member.missions:KeepAnnouncing()
    assert.are.equal(1, #member.timers)
  end)

  it("stops when the addon is no longer active", function()
    local _, _, member = pending_claim()
    member.missions:StartAnnouncing()
    member.active = false
    local before = #member.sent
    fire(member)
    assert.are.equal(before, #member.sent)
    assert.are.equal(0, #member.timers)
    assert.is_false(member.missions.looping)
  end)

  it("stops announcing a claim the season refuses for good", function()
    local _, admin, member = pending_claim()
    member.missions:StartAnnouncing()
    assert(admin.season:SetMissionActive("m1", false))
    relay(admin, member)
    member.timers = { member.timers[1] }
    fire(member)
    assert.are.equal(0, #member.timers)
    assert.is_false(member.missions:HasPending())
    assert.is_false(member.missions.looping)
  end)

  it("sends nothing when there is no season or nothing pending", function()
    local lone = new_client(new_world(), "Ann", true)
    assert.are.equal(0, lone.missions:Reannounce())
    assert.is_false(lone.missions:HasPending())
    local _, _, member = setup()
    assert.are.equal(0, member.missions:Reannounce())
    member.missions:StartAnnouncing()
    fire(member)
    assert.are.equal(0, #member.timers)
  end)

  it("skips a claim of a season that is no longer the active one", function()
    local _, _, member, claim = pending_claim()
    claims_of(member)[claim.id].claim.seasonId = "other"
    assert.are.equal(0, member.missions:Reannounce())
  end)
end)
