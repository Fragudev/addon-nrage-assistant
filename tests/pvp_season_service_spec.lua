-- The local side of PvP seasons: permission checks, producing payloads, applying them to the own ledger, sending, and
-- the read helpers the interface uses. Two services stand for two clients and exchange what they send.
local function load_addon()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/PvPSeasonModel",
    "Domain/PvPSeasonService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSeasonSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Service, Sync, Model, Protocol, Constants =
  ns.PvPSeasonService, ns.PvPSeasonSync, ns.PvPSeasonModel, ns.Protocol, ns.Constants

local DAY = 86400
local T0 = 1792454400 -- 2026-10-20 00:00 UTC

local ROLES = { Boss = "admin", Off = "member", Ann = "member", Bob = "member", Cat = "member", Dan = "member" }

-- One world: a clock, a roster and a counter for ids, shared by the services made in it.
local function new_world()
  return { clock = T0 + 100, ids = 0, roles = ROLES, queued = true }
end

local function new_service(world, name, options)
  options = options or {}
  local service
  local sent, changes, closed = {}, {}, {}
  service = Service.New({
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
      return options.role or world.roles[name]
    end,
    roleOf = function(who)
      return world.roles[who]
    end,
    send = function(messageType, payload, key)
      sent[#sent + 1] = { t = messageType, p = payload, key = key, from = name }
      return world.queued
    end,
    onChange = function(messageType)
      changes[#changes + 1] = messageType
    end,
    onSeasonClosed = function(seasonId)
      closed[#closed + 1] = seasonId
    end,
    fits = options.fits,
  })
  service.sent, service.changes, service.closed, service.name = sent, changes, closed, name
  return service
end

-- Delivers to `to` what `from` sent since the last time, as the guild channel would.
local function relay(from, to)
  local delivered = 0
  from.cursors = from.cursors or {}
  local cursor = from.cursors[to.name] or 0
  while cursor < #from.sent do
    cursor = cursor + 1
    local entry = from.sent[cursor]
    local message = assert(Protocol.Validate(Protocol.Build(entry.t, entry.p, "wire")))
    if Sync.Apply(to:Context(), message, from.name) then
      delivered = delivered + 1
    end
  end
  from.cursors[to.name] = cursor
  return delivered
end

local function lastSent(service)
  return service.sent[#service.sent]
end

local GOAL = { kind = "kills", count = 5, zones = {}, place = "any", distinct = "none" }

-- An admin with an active season and one daily mission worth 10 points.
local function admin_with_season(world)
  local admin = new_service(world, "Boss")
  assert(admin:CreateSeason({ name = "Season One", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
  assert(
    admin:UpsertMission({ id = "m1", title = "Hunt", points = 10, goal = GOAL, repeatKind = "daily", perPlayer = 2 })
  )
  return admin
end

describe("PvPSeasonService permissions", function()
  it("tells the admin, an officer and a member apart", function()
    local world = new_world()
    local admin = new_service(world, "Boss")
    local member = new_service(world, "Ann")
    assert.is_true(admin:CanPvP("pvp_season_manage"))
    assert.is_true(admin:IsApprover())
    assert.is_false(member:CanPvP("pvp_season_manage"))
    assert.is_false(member:IsApprover())
    assert.is_true(member:CanPvP("pvp_claim"))

    assert(admin:CreateSeason({ name = "S", endsAt = T0 + DAY }))
    assert(admin:SetOfficer("Ann", true))
    relay(admin, member)
    assert.is_true(member:IsOfficer("Ann"))
    assert.is_true(member:IsApprover())
    assert.is_true(member:CanPvP("pvp_delivery_mark"))
    assert.is_false(member:CanPvP("pvp_season_manage"))
    assert.is_false(member:CanPvP("pvp_officer_assign"))
    assert.is_false(member:CanPvP("pvp_grant_direct"))
  end)

  it("gives nothing to a player who is not in a guild", function()
    local world = new_world()
    local nobody = new_service(world, "Ann", { role = false })
    nobody.ownRole = function()
      return nil
    end
    assert.is_false(nobody:CanPvP("pvp_claim"))
    assert.is_false(nobody:IsApprover())
  end)
end)

describe("PvPSeasonService seasons", function()
  local world, admin

  before_each(function()
    world = new_world()
    admin = new_service(world, "Boss")
  end)

  it("creates the first season, starting now when no date is given", function()
    local season, queued = admin:CreateSeason({ name = "  Season   One ", endsAt = T0 + 30 * DAY })
    assert.is_truthy(season)
    assert.is_true(queued)
    assert.are.equal("Season One", season.name)
    assert.are.equal(world.clock, season.startsAt)
    assert.are.equal("active", season.state)
    assert.are.equal(season.id, admin:ActiveSeason().id)
    local entry = lastSent(admin)
    assert.are.equal("PVP_SEASON", entry.t)
    assert.are.equal("PS:" .. season.id, entry.key)
    assert.are.same({ "PVP_SEASON" }, admin.changes)
    -- The payload carries no author.
    assert.is_nil(entry.p.updatedBy)
    assert.are.equal("Boss", season.updatedBy)
  end)

  it("says when the season was saved here but not queued", function()
    world.queued = false
    local season, queued = admin:CreateSeason({ name = "Season One", endsAt = T0 + DAY })
    assert.is_truthy(season)
    assert.is_false(queued)
  end)

  it("refuses a second active season, bad data and anybody but an admin", function()
    assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + DAY }))
    local season, reason = admin:CreateSeason({ name = "Two", endsAt = T0 + DAY })
    assert.is_nil(season)
    assert.are.equal("active_exists", reason)

    local fresh = new_service(world, "Boss")
    assert.are.equal("invalid:name", select(2, fresh:CreateSeason({ name = "", endsAt = T0 + DAY })))
    assert.are.equal("invalid:dates", select(2, fresh:CreateSeason({ name = "S", startsAt = T0, endsAt = T0 })))
    assert.are.equal("invalid:dates", select(2, fresh:CreateSeason({ name = "S" })))
    assert.is_nil(fresh:ActiveSeason())
    assert.are.equal("forbidden", select(2, new_service(world, "Ann"):CreateSeason({ name = "S", endsAt = T0 + DAY })))
  end)

  it("edits the name and the dates of an open season with a new revision", function()
    local season = assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + DAY }))
    world.clock = world.clock + 10
    local edited = assert(admin:EditSeason(season.id, { name = "Renamed", endsAt = T0 + 5 * DAY }))
    assert.are.equal("Renamed", edited.name)
    assert.are.equal(T0 + 5 * DAY, edited.endsAt)
    assert.are.equal(2, edited.rev)
    assert.are.equal(2, lastSent(admin).p.rev)
    assert.are.equal("invalid:dates", select(2, admin:EditSeason(season.id, { endsAt = season.startsAt })))
    assert.are.equal("not_found", select(2, admin:EditSeason("nope", { name = "x" })))
    assert.are.equal("forbidden", select(2, new_service(world, "Ann"):EditSeason(season.id, { name = "x" })))
  end)

  it("lists seasons newest first", function()
    local first = assert(admin:CreateSeason({ name = "One", startsAt = T0, endsAt = T0 + DAY }))
    assert(admin:CloseSeason(first.id))
    local second = assert(admin:CreateSeason({ name = "Two", startsAt = T0 + 2 * DAY, endsAt = T0 + 3 * DAY }))
    local list = admin:Seasons()
    assert.are.same({ second.id, first.id }, { list[1].id, list[2].id })
    assert.are.equal("One", admin:Season(first.id).name)
  end)
end)

describe("PvPSeasonService missions and prizes", function()
  local world, admin

  before_each(function()
    world = new_world()
    admin = new_service(world, "Boss")
  end)

  it("needs an active season", function()
    local mission, reason = admin:UpsertMission({ title = "Hunt", points = 10, goal = GOAL, repeatKind = "daily" })
    assert.is_nil(mission)
    assert.are.equal("no_season", reason)
  end)

  it("creates a mission with the defaults, edits it keeping the rest and pauses it", function()
    assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + 30 * DAY }))
    local mission = assert(admin:UpsertMission({ title = "  Hunt ", points = 10, goal = GOAL, repeatKind = "daily" }))
    assert.are.equal("Hunt", mission.title)
    assert.are.equal(1, mission.perPlayer)
    assert.is_true(mission.active)
    assert.are.equal(admin:ActiveSeason().id, mission.seasonId)
    assert.are.equal("PVP_MISSION", lastSent(admin).t)
    assert.are.equal("PM:" .. mission.id, lastSent(admin).key)

    local edited = assert(admin:UpsertMission({ id = mission.id, points = 25 }))
    assert.are.equal(25, edited.points)
    assert.are.equal("Hunt", edited.title)
    assert.are.equal(2, edited.rev)

    assert(admin:SetMissionActive(mission.id, false))
    assert.is_false(admin:Mission(mission.id).active)
    assert.are.equal(0, #admin:Missions(mission.seasonId))
    assert.are.equal(1, #admin:Missions(mission.seasonId, true))
    assert(admin:SetMissionActive(mission.id, true))
    assert.are.equal(1, #admin:Missions(mission.seasonId))
    assert.are.equal("not_found", select(2, admin:SetMissionActive("nope", true)))
  end)

  it("refuses an invalid mission, a mission of a closed season and anybody but an admin", function()
    local season = assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + 30 * DAY }))
    assert.are.equal(
      "invalid:points",
      select(2, admin:UpsertMission({ title = "Hunt", points = 0, goal = GOAL, repeatKind = "daily" }))
    )
    assert.are.equal(
      "invalid:goal",
      select(2, admin:UpsertMission({ title = "Hunt", points = 1, goal = { kind = "x" }, repeatKind = "daily" }))
    )
    assert.are.equal(
      "invalid:title",
      select(2, admin:UpsertMission({ title = "", points = 1, goal = GOAL, repeatKind = "daily" }))
    )
    assert.are.equal(
      "invalid:id",
      select(2, admin:UpsertMission({ id = "bad id", title = "T", points = 1, goal = GOAL, repeatKind = "daily" }))
    )
    local mission = assert(admin:UpsertMission({ title = "Hunt", points = 1, goal = GOAL, repeatKind = "daily" }))
    assert(admin:CloseSeason(season.id))
    assert.are.equal("closed", select(2, admin:UpsertMission({ id = mission.id, points = 5 })))
    assert.are.equal(
      "no_season",
      select(2, admin:UpsertMission({ title = "New", points = 5, goal = GOAL, repeatKind = "daily" }))
    )
    local member = new_service(world, "Ann")
    assert.are.equal(
      "forbidden",
      select(2, member:UpsertMission({ title = "Hunt", points = 1, goal = GOAL, repeatKind = "daily" }))
    )
    assert.are.equal("forbidden", select(2, member:SetMissionActive(mission.id, false)))
  end)

  it("sets the prizes of an open season and replaces them as a whole", function()
    local season = assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + 30 * DAY }))
    local prizes = assert(
      admin:SetPrizes(
        season.id,
        { ["1"] = { { kind = "gold", amount = 500 } }, ["2"] = { { kind = "gold", amount = 200 } } }
      )
    )
    assert.are.equal(1, prizes.rev)
    assert.are.equal("PVP_PRIZES", lastSent(admin).t)
    prizes = assert(
      admin:SetPrizes(season.id, { ["1"] = { { kind = "item", itemId = 19019, name = "Thunderfury", count = 1 } } })
    )
    assert.are.equal(2, prizes.rev)
    assert.is_nil(prizes.tiers["2"])
    assert.are.equal("Thunderfury", admin:Prizes(season.id).tiers["1"][1].name)
    assert.are.equal(
      "invalid:tiers",
      select(2, admin:SetPrizes(season.id, { ["1"] = { { kind = "gold", amount = 0 } } }))
    )
    assert.are.equal("not_found", select(2, admin:SetPrizes("nope", {})))
    assert.are.equal("forbidden", select(2, new_service(world, "Ann"):SetPrizes(season.id, {})))
  end)

  it("freezes the prizes with the season", function()
    local season = assert(admin:CreateSeason({ name = "Season One", endsAt = T0 + 30 * DAY }))
    assert(admin:SetPrizes(season.id, { ["1"] = { { kind = "gold", amount = 500 } } }))
    assert(admin:CloseSeason(season.id))
    assert.are.equal("closed", select(2, admin:SetPrizes(season.id, {})))
    local prizes = admin:Prizes(season.id)
    assert.is_true(prizes.closed)
    assert.are.equal(500, prizes.tiers["1"][1].amount)
  end)
end)

describe("PvPSeasonService officers", function()
  local world, admin, member

  before_each(function()
    world = new_world()
    admin = new_service(world, "Boss")
    member = new_service(world, "Ann")
    assert(admin:CreateSeason({ name = "Season One", startsAt = T0 - DAY, endsAt = T0 + 30 * DAY }))
  end)

  it("turns the flag on and off, keeping the intervals", function()
    local officer = assert(admin:SetOfficer("Off", true))
    assert.are.same({ { from = world.clock } }, officer.intervals)
    assert.is_true(admin:IsOfficer("Off"))
    assert.are.equal("PVP_OFFICER", lastSent(admin).t)
    assert.are.equal("PO:Off", lastSent(admin).key)

    world.clock = world.clock + 1000
    officer = assert(admin:SetOfficer("Off", false))
    assert.are.same({ { from = T0 + 100, to = T0 + 1100 } }, officer.intervals)
    assert.is_false(admin:IsOfficer("Off"))
    assert.are.equal(2, officer.rev)
    world.clock = world.clock + 1000
    officer = assert(admin:SetOfficer("Off", true))
    assert.are.equal(2, #officer.intervals)
    assert.are.equal(3, officer.rev)
  end)

  it("says 'unchanged' for a flag that is already in that state, and refuses a stranger to switch on", function()
    assert(admin:SetOfficer("Off", true))
    assert.are.equal("unchanged", select(2, admin:SetOfficer("Off", true)))
    assert.are.equal("unchanged", select(2, admin:SetOfficer("Cat", false)))
    assert.are.equal("unknown_player", select(2, admin:SetOfficer("Stranger", true)))
    assert.are.equal("invalid:player", select(2, admin:SetOfficer("a:b", true)))
    -- A player who left can still be switched off.
    world.roles = {}
    for key, value in pairs(ROLES) do
      world.roles[key] = value
    end
    world.roles.Off = nil
    assert.is_truthy(admin:SetOfficer("Off", false))
  end)

  it("is for the admin only, and an officer cannot appoint another", function()
    assert.are.equal("forbidden", select(2, member:SetOfficer("Off", true)))
    assert(admin:SetOfficer("Off", true))
    local officer = new_service(world, "Off")
    relay(admin, officer)
    assert.is_true(officer:IsOfficer("Off"))
    assert.are.equal("forbidden", select(2, officer:SetOfficer("Cat", true)))
  end)

  it("limits the number of officers", function()
    local old = Constants.PVP_OFFICERS_MAX
    Constants.PVP_OFFICERS_MAX = 1
    assert(admin:SetOfficer("Off", true))
    local record, reason = admin:SetOfficer("Cat", true)
    Constants.PVP_OFFICERS_MAX = old
    assert.is_nil(record)
    assert.are.equal("limit", reason)
  end)

  it("lists the officers by name with whether the flag is on", function()
    assert(admin:SetOfficer("Off", true))
    assert(admin:SetOfficer("Cat", true))
    world.clock = world.clock + 5
    assert(admin:SetOfficer("Cat", false))
    assert.are.same({
      { player = "Cat", active = false, since = T0 + 100 },
      { player = "Off", active = true, since = T0 + 100 },
    }, admin:Officers())
  end)
end)

describe("PvPSeasonService claims", function()
  local world, admin, officer, member

  before_each(function()
    world = new_world()
    admin = admin_with_season(world)
    assert(admin:SetOfficer("Off", true))
    officer = new_service(world, "Off")
    member = new_service(world, "Ann")
    relay(admin, officer)
    relay(admin, member)
  end)

  it("builds the claim of the local player and sends it", function()
    local claim, queued = member:SubmitClaim({
      missionId = "m1",
      summary = { done = 5, total = 5 },
      evidence = { { at = T0 + 50, victim = "Grunt", place = "world", mapId = 1424 } },
      note = "all of them",
    })
    assert.is_truthy(claim)
    assert.is_true(queued)
    assert.are.equal("Ann:m1:" .. Model.PeriodKey("daily", world.clock) .. ":1", claim.id)
    assert.are.equal("Ann", claim.player)
    assert.are.equal(world.clock, claim.at)
    local entry = lastSent(member)
    assert.are.equal("PVP_CLAIM", entry.t)
    assert.are.equal("PC:" .. claim.id, entry.key)
    -- A member keeps no queue: others' clients do.
    assert.is_nil(next(member.ledger.queue))
    assert.are.equal(1, relay(member, officer))
    assert.are.equal(1, #officer:Queue())
    assert.are.equal("pending", officer:ClaimState(claim.id))
  end)

  it("sends the same claim id for the same claim and a different one for the second", function()
    local first = assert(member:SubmitClaim({ missionId = "m1" }))
    local again = assert(member:SubmitClaim({ missionId = "m1" }))
    local second = assert(member:SubmitClaim({ missionId = "m1", n = 2 }))
    assert.are.equal(first.id, again.id)
    assert.are_not.equal(first.id, second.id)
    assert.are.equal("limit", select(2, member:SubmitClaim({ missionId = "m1", n = 3 })))
    relay(member, officer)
    assert.are.equal(2, #officer:Queue())
  end)

  it("keeps an admin's own claims in the admin's queue", function()
    local claim = assert(admin:SubmitClaim({ missionId = "m1" }))
    assert.is_truthy(admin.ledger.queue[claim.id])
    local grant = assert(admin:Approve(claim.id))
    assert.are.equal(10, grant.points)
  end)

  it("refuses a claim the mission or the season does not allow", function()
    assert.are.equal("unknown_mission", select(2, member:SubmitClaim({ missionId = "m9" })))
    assert.are.equal("out_of_season", select(2, member:SubmitClaim({ missionId = "m1", at = T0 - 5 * DAY })))
    assert.are.equal(
      "invalid:evidence",
      select(2, member:SubmitClaim({ missionId = "m1", evidence = { { victim = "x" } } }))
    )
    assert.are.equal("invalid:summary", select(2, member:SubmitClaim({ missionId = "m1", summary = { done = -1 } })))
    assert(admin:UpsertMission({ id = "m1", active = false }))
    relay(admin, member)
    assert.are.equal("inactive", select(2, member:SubmitClaim({ missionId = "m1" })))
    assert(
      admin:UpsertMission({ id = "man", title = "Manual", points = 5, goal = { kind = "manual" }, repeatKind = "once" })
    )
    relay(admin, member)
    assert.are.equal("invalid:note", select(2, member:SubmitClaim({ missionId = "man" })))
    local claim = assert(member:SubmitClaim({ missionId = "man", note = "I did it" }))
    assert.are.equal("Ann:man:all:1", claim.id)
    local nobody = new_service(world, "Ann", { role = "member" })
    nobody.ownRole = function()
      return nil
    end
    assert.are.equal("forbidden", select(2, nobody:SubmitClaim({ missionId = "m1" })))
  end)

  it("refuses a claim when there is no active season", function()
    assert(admin:CloseSeason())
    relay(admin, member)
    assert.are.equal("no_season", select(2, member:SubmitClaim({ missionId = "m1" })))
  end)

  it("stores a received claim only on a client that approves, and checks the sender", function()
    local claim = assert(member:SubmitClaim({ missionId = "m1" }))
    local payload = lastSent(member).p
    assert.is_true(officer:ReceiveClaim(payload, "Ann"))
    local ok, reason = member:ReceiveClaim(payload, "Ann")
    assert.is_false(ok)
    assert.are.equal("not_approver", reason)
    ok, reason = officer:ReceiveClaim(payload, "Bob")
    assert.is_false(ok)
    assert.are.equal("bad_player", reason)
    ok, reason = officer:ReceiveClaim({ id = "bad" }, "Ann")
    assert.is_false(ok)
    assert.are.equal("invalid:claim", reason)
    assert.is_truthy(officer.ledger.queue[claim.id])
    assert.are.same({ "PVP_CLAIM" }, { officer.changes[#officer.changes] })
  end)
end)

describe("PvPSeasonService deciding claims", function()
  local world, admin, officer, other, member, claimId

  before_each(function()
    world = new_world()
    admin = admin_with_season(world)
    assert(admin:SetOfficer("Off", true))
    assert(admin:SetOfficer("Dan", true))
    officer = new_service(world, "Off")
    other = new_service(world, "Dan")
    member = new_service(world, "Ann")
    relay(admin, officer)
    relay(admin, other)
    relay(admin, member)
    claimId = assert(member:SubmitClaim({ missionId = "m1" })).id
    relay(member, officer)
    relay(member, other)
    relay(member, admin)
  end)

  it("approves a claim with the points of the mission and sends the grant", function()
    world.clock = world.clock + 60
    local grant, queued = officer:Approve(claimId)
    assert.is_truthy(grant)
    assert.is_true(queued)
    assert.are.equal(claimId, grant.id)
    assert.are.equal(10, grant.points)
    assert.are.equal("Off", grant.by)
    assert.are.equal(world.clock, grant.at)
    assert.are.equal("PVP_GRANT", lastSent(officer).t)
    assert.are.equal("PG:" .. claimId, lastSent(officer).key)
    assert.are.equal(0, #officer:Queue())
    assert.are.equal("approved", officer:ClaimState(claimId))
    assert.are.equal(10, officer:StandingOf("Ann").points)
    assert.are.equal(1, officer:StandingOf("Ann").pos)
  end)

  it("copies the points when approved: editing the mission later does not change past grants", function()
    assert(officer:Approve(claimId))
    assert(admin:UpsertMission({ id = "m1", points = 999 }))
    relay(admin, officer)
    assert.are.equal(10, officer:StandingOf("Ann").points)
  end)

  it("makes a double approval by two approvers count once", function()
    assert(officer:Approve(claimId))
    assert(other:Approve(claimId))
    relay(officer, other)
    relay(other, officer)
    relay(officer, admin)
    relay(other, admin)
    for _, client in ipairs({ officer, other, admin }) do
      local rows = client:Standings()
      assert.are.equal(1, #rows)
      assert.are.equal(10, rows[1].points)
    end
  end)

  it("tells a second approval on the same client that the claim was decided", function()
    assert(officer:Approve(claimId))
    local grant, reason = officer:Approve(claimId)
    assert.is_nil(grant)
    assert.are.equal("decided", reason)
    assert.are.equal("not_found", select(2, officer:Approve("Nobody:m1:all:1")))
  end)

  it("rejects a claim with a reason, and an approver can still change their mind", function()
    local reject = assert(officer:Reject(claimId, "  no   proof "))
    assert.are.equal("no proof", reject.reason)
    assert.are.equal("PVP_REJECT", lastSent(officer).t)
    assert.are.equal("PR:" .. claimId, lastSent(officer).key)
    assert.are.equal("rejected", officer:ClaimState(claimId))
    assert.are.equal(0, #officer:Queue())
    local rejected = officer:Rejected()
    assert.are.equal(1, #rejected)
    assert.are.same({ claimId, "Off", "no proof" }, { rejected[1].id, rejected[1].rejectedBy, rejected[1].reason })
    relay(officer, other)
    assert.are.equal("rejected", other:ClaimState(claimId))
    assert.are.equal(0, #other:Queue())

    world.clock = world.clock + 10
    assert(other:Approve(claimId))
    assert.are.equal("approved", other:ClaimState(claimId))
    assert.are.equal(0, #other:Rejected())
    relay(other, officer)
    assert.are.equal("approved", officer:ClaimState(claimId))
    assert.are.equal(10, officer:StandingOf("Ann").points)
    assert.are.equal(0, #officer:Rejected())
  end)

  it("refuses a member, an officer approving their own claim and a claim of a closed season", function()
    assert.are.equal("forbidden", select(2, member:Approve(claimId)))
    assert.are.equal("forbidden", select(2, member:Reject(claimId)))
    assert(officer:SubmitClaim({ missionId = "m1" }))
    local payload = lastSent(officer).p
    local own = payload.id
    -- The officer's own client does not queue it, so it is put there as if another client had relayed it.
    assert(officer:ReceiveClaim(payload, "Off"))
    assert.are.equal("self_grant", select(2, officer:Approve(own)))
    relay(officer, other)
    assert.is_truthy(other:Approve(own))
    assert(admin:CloseSeason())
    relay(admin, officer)
    assert.are.equal("not_found", select(2, officer:Approve(claimId)))
  end)

  it("lets the admin approve their own claim", function()
    local own = assert(admin:SubmitClaim({ missionId = "m1" }))
    assert.is_truthy(admin:Approve(own.id))
  end)

  it("needs the mission to be known", function()
    officer.ledger.missions.m1 = nil
    assert.are.equal("unknown_mission", select(2, officer:Approve(claimId)))
  end)
end)

describe("PvPSeasonService direct grants, voids and the grant list", function()
  local world, admin, officer

  before_each(function()
    world = new_world()
    admin = admin_with_season(world)
    assert(admin:SetOfficer("Off", true))
    officer = new_service(world, "Off")
    relay(admin, officer)
  end)

  it("lets only an admin grant without a claim, with the mission's points unless told otherwise", function()
    local grant = assert(admin:DirectGrant("Ann", "m1"))
    assert.are.equal(10, grant.points)
    assert.is_false(grant.id:find(":", 1, true) ~= nil)
    assert.are.equal(25, assert(admin:DirectGrant("Bob", "m1", 25)).points)
    assert.are.equal("forbidden", select(2, officer:DirectGrant("Ann", "m1")))
    assert.are.equal("unknown_mission", select(2, admin:DirectGrant("Ann", "m9")))
    assert.are.equal("invalid:points", select(2, admin:DirectGrant("Ann", "m1", 5000)))
    assert.are.equal("invalid:ref", select(2, admin:DirectGrant("a:b", "m1")))
    assert.are.equal("Bob", admin:Standings()[1].player)
  end)

  it("voids a grant: it stays on record but leaves the standings, and only an admin may", function()
    local grant = assert(admin:DirectGrant("Ann", "m1"))
    assert.are.equal("forbidden", select(2, officer:Void(grant.id, "no")))
    local void = assert(admin:Void(grant.id, "  abuse "))
    assert.are.equal("abuse", void.reason)
    assert.are.equal("PVP_VOID", lastSent(admin).t)
    assert.are.equal(0, #admin:Standings())
    local rows = admin:Grants()
    assert.are.equal(1, #rows)
    assert.is_true(rows[1].voided)
    assert.are.equal("Hunt", rows[1].missionTitle)
    assert.are.equal("decided", select(2, admin:Void(grant.id)))
    assert.are.equal("not_found", select(2, admin:Void("nope")))
  end)

  it("lists the grants newest first with whether they count", function()
    assert(admin:DirectGrant("Ann", "m1"))
    world.clock = world.clock + 10
    assert(admin:DirectGrant("Bob", "m1"))
    local rows = admin:Grants()
    assert.are.same({ "Bob", "Ann" }, { rows[1].player, rows[2].player })
    assert.is_true(rows[1].counts)
    assert.is_false(rows[1].voided)
    assert.are.same({}, admin:Grants("nope"))
  end)
end)

describe("PvPSeasonService closing a season", function()
  local world, admin, officer, member

  local function grantTo(player, points)
    assert(admin:DirectGrant(player, "m1", points))
    world.clock = world.clock + 1
  end

  before_each(function()
    world = new_world()
    admin = admin_with_season(world)
    assert(admin:SetOfficer("Off", true))
    officer = new_service(world, "Off")
    member = new_service(world, "Ann")
    relay(admin, officer)
    relay(admin, member)
  end)

  it("freezes the standing, copies the prizes, sends the final and then the closed season", function()
    local season = admin:ActiveSeason()
    assert(admin:SetPrizes(season.id, { ["1"] = { { kind = "gold", amount = 500 } } }))
    grantTo("Ann", 30)
    grantTo("Bob", 50)
    grantTo("Cat", 30)
    local before = #admin.sent
    local final, expired, queued = admin:CloseSeason()
    assert.is_truthy(final)
    assert.are.equal(0, expired)
    assert.is_true(queued)
    assert.are.same(
      { "Bob", "Ann", "Cat" },
      { final.standings[1].player, final.standings[2].player, final.standings[3].player }
    )
    assert.are.equal(50, final.standings[1].points)
    assert.are.equal(500, final.prizes["1"][1].amount)
    assert.are.equal("Boss", final.closedBy)
    assert.are.equal(world.clock, final.closedAt)
    assert.are.equal("PVP_FINAL", admin.sent[before + 1].t)
    assert.are.equal("PVP_SEASON", admin.sent[before + 2].t)
    assert.are.equal("closed", admin.sent[before + 2].p.state)
    assert.is_nil(admin:ActiveSeason())
    assert.are.same({ season.id }, admin.closed)
    -- The detail went away; the standing and the deliveries remain.
    assert.is_nil(admin.ledger.grants[season.id])
    assert.are.equal(3, #admin:Standings(season.id))
    assert.are.equal(3, #admin:Deliveries(season.id))
    assert.are.equal(1, #admin:Finals())
  end)

  it("makes every client agree on the closed season", function()
    local season = admin:ActiveSeason()
    grantTo("Ann", 30)
    grantTo("Bob", 50)
    assert(admin:CloseSeason())
    -- The two grants, the final and the closed season.
    assert.are.equal(4, relay(admin, officer))
    assert.are.equal(4, relay(admin, member))
    for _, client in ipairs({ admin, officer, member }) do
      assert.is_nil(client:ActiveSeason())
      assert.are.same(
        { "Bob", "Ann" },
        { client:Standings(season.id)[1].player, client:Standings(season.id)[2].player }
      )
      assert.are.equal("closed", client:Season(season.id).state)
      assert.are.equal(2, client:Season(season.id).rev)
    end
    assert.are.same({ season.id }, officer.closed)
  end)

  it("lets the claims that were waiting expire and says how many", function()
    assert(member:SubmitClaim({ missionId = "m1" }))
    assert(member:SubmitClaim({ missionId = "m1", n = 2 }))
    relay(member, admin)
    assert.are.equal(2, #admin:Queue())
    local _, expired = admin:CloseSeason()
    assert.are.equal(2, expired)
    assert.are.equal(0, #admin:Queue())
    assert.is_nil(next(admin.ledger.queue))
  end)

  it("ranks nobody without points: a season where few players scored has few rows and fewer deliveries", function()
    grantTo("Ann", 30)
    local final = assert(admin:CloseSeason())
    assert.are.equal(1, #final.standings)
    assert.are.equal(1, #admin:Deliveries(final.seasonId))
    local empty = admin_with_season(new_world())
    local none = assert(empty:CloseSeason())
    assert.are.equal(0, #none.standings)
  end)

  it("gives a tie at a tier boundary to whoever reached the total first", function()
    for index = 1, 7 do
      grantTo("P" .. index, 100)
    end
    world.roles = setmetatable({}, { __index = ROLES })
    local final = assert(admin:CloseSeason())
    -- Equal points: the order of the grants decides, then the name, and positions 4 to 6 share a tier.
    assert.are.equal("P1", final.standings[1].player)
    assert.are.equal("4-6", admin:Standings(final.seasonId)[5].tier)
    assert.are.equal("7-10", admin:Standings(final.seasonId)[7].tier)
    local deliveries = admin:Deliveries(final.seasonId)
    assert.are.equal("P4", deliveries[4].player)
    assert.are.equal("4-6", deliveries[4].tier)
  end)

  it("cuts a standing that does not fit one message, keeping the best positions and never below ten", function()
    local cut = new_service(world, "Boss", {
      fits = function(_, payload)
        return #payload.standings <= 25
      end,
    })
    assert(cut:CreateSeason({ name = "Cut", startsAt = T0 - DAY, endsAt = T0 + DAY }))
    assert(cut:UpsertMission({ id = "m1", title = "Hunt", points = 10, goal = GOAL, repeatKind = "daily" }))
    for index = 1, 40 do
      assert(cut:DirectGrant("Player" .. index, "m1", 10 + index))
    end
    local final = assert(cut:CloseSeason())
    assert.are.equal(20, #final.standings)
    assert.are.equal("Player40", final.standings[1].player)

    local tight = new_service(world, "Boss", {
      fits = function()
        return false
      end,
    })
    assert(tight:CreateSeason({ name = "Tight", startsAt = T0 - DAY, endsAt = T0 + DAY }))
    assert(tight:UpsertMission({ id = "m2", title = "Hunt", points = 10, goal = GOAL, repeatKind = "daily" }))
    for index = 1, 15 do
      assert(tight:DirectGrant("Player" .. index, "m2", 10 + index))
    end
    assert.are.equal(10, #assert(tight:CloseSeason()).standings)
  end)

  it("cannot be closed twice, without a season or by anybody but an admin", function()
    local season = admin:ActiveSeason()
    assert.are.equal("forbidden", select(2, officer:CloseSeason()))
    assert.are.equal("forbidden", select(2, member:CloseSeason(season.id)))
    assert(admin:CloseSeason())
    assert.are.equal("no_season", select(2, admin:CloseSeason()))
    assert.are.equal("closed", select(2, admin:CloseSeason(season.id)))
    assert.are.equal("no_season", select(2, admin:CloseSeason("nope")))
  end)

  it("marks deliveries, as an admin or an officer, and every client sees them", function()
    local season = admin:ActiveSeason()
    assert(admin:SetPrizes(season.id, { ["1"] = { { kind = "gold", amount = 500 } } }))
    grantTo("Ann", 30)
    grantTo("Bob", 50)
    assert(admin:CloseSeason())
    relay(admin, officer)
    relay(admin, member)
    local rows = officer:Deliveries(season.id)
    assert.are.equal("Bob", rows[1].player)
    assert.are.equal("1", rows[1].tier)
    assert.are.equal(500, rows[1].rewards[1].amount)
    assert.is_false(rows[1].delivered)
    assert.is_nil(rows[1].updatedBy)

    world.clock = world.clock + 5
    local delivery = assert(officer:MarkDelivery(season.id, "Bob", true))
    assert.is_true(delivery.delivered)
    assert.are.equal("Off", delivery.updatedBy)
    assert.are.equal("PVP_DELIVERY", lastSent(officer).t)
    relay(officer, admin)
    relay(officer, member)
    for _, client in ipairs({ officer, admin, member }) do
      local first = client:Deliveries(season.id)[1]
      assert.is_true(first.delivered)
      assert.are.equal("Off", first.updatedBy)
    end
    -- And back.
    assert(admin:MarkDelivery(season.id, "Bob", false))
    assert.is_false(admin:Deliveries(season.id)[1].delivered)
    assert.are.equal("forbidden", select(2, member:MarkDelivery(season.id, "Bob", true)))
    assert.are.equal("not_found", select(2, officer:MarkDelivery(season.id, "Cat", true)))
    assert.are.equal("not_found", select(2, officer:MarkDelivery("nope", "Bob", true)))
  end)

  it("adds up the seasons for the all-time ranking", function()
    grantTo("Ann", 30)
    grantTo("Bob", 50)
    assert(admin:CloseSeason())
    assert(admin:CreateSeason({ name = "Two", startsAt = T0, endsAt = T0 + 20 * DAY }))
    assert(admin:UpsertMission({ id = "m2", title = "Again", points = 10, goal = GOAL, repeatKind = "daily" }))
    assert(admin:DirectGrant("Ann", "m2", 40))
    assert(admin:CloseSeason())
    local rows = admin:Cumulative()
    assert.are.same({ pos = 1, player = "Ann", points = 70, seasons = 2, podiums = 2 }, rows[1])
    assert.are.same({ pos = 2, player = "Bob", points = 50, seasons = 1, podiums = 1 }, rows[2])
  end)
end)

describe("PvPSeasonService reading", function()
  it("answers with nothing before any season exists", function()
    local service = new_service(new_world(), "Ann")
    assert.is_nil(service:ActiveSeason())
    assert.are.same({}, service:Standings())
    assert.is_nil(service:StandingOf("Ann"))
    assert.are.same({}, service:Queue())
    assert.are.same({}, service:Finals())
    assert.are.same({}, service:Deliveries("nope"))
    assert.are.same({}, service:Cumulative())
    assert.are.same({}, service:Officers())
    assert.are.same({}, service:Seasons())
    assert.is_nil(service:ClaimState("Ann:m1:all:1"))
    assert.is_nil(service:Prizes("nope"))
    assert.is_nil(service:Final("nope"))
  end)

  it("orders the missions by title and the queue oldest first", function()
    local world = new_world()
    local admin = admin_with_season(world)
    assert(admin:UpsertMission({ id = "a1", title = "alpha", points = 1, goal = GOAL, repeatKind = "once" }))
    assert(admin:UpsertMission({ id = "z1", title = "Zulu", points = 1, goal = GOAL, repeatKind = "once" }))
    local titles = {}
    for _, mission in ipairs(admin:Missions(admin:ActiveSeason().id)) do
      titles[#titles + 1] = mission.title
    end
    assert.are.same({ "alpha", "Hunt", "Zulu" }, titles)

    local ann, bob = new_service(world, "Ann"), new_service(world, "Bob")
    relay(admin, ann)
    relay(admin, bob)
    assert(bob:SubmitClaim({ missionId = "m1", at = world.clock }))
    assert(ann:SubmitClaim({ missionId = "m1", at = world.clock - 50 }))
    relay(bob, admin)
    relay(ann, admin)
    local queue = admin:Queue()
    assert.are.same({ "Ann", "Bob" }, { queue[1].player, queue[2].player })
  end)
end)

describe("PvPSeasonService two clients", function()
  it("end up with the same standings whichever of them approved what", function()
    local world = new_world()
    local admin = admin_with_season(world)
    assert(admin:SetOfficer("Off", true))
    assert(admin:SetOfficer("Dan", true))
    local off, dan, ann, bob =
      new_service(world, "Off"), new_service(world, "Dan"), new_service(world, "Ann"), new_service(world, "Bob")
    local everyone = { admin, off, dan, ann, bob }
    for _, client in ipairs(everyone) do
      if client ~= admin then
        relay(admin, client)
      end
    end
    local annClaim = assert(ann:SubmitClaim({ missionId = "m1" }))
    local bobClaim = assert(bob:SubmitClaim({ missionId = "m1", n = 1 }))
    for _, client in ipairs({ admin, off, dan }) do
      relay(ann, client)
      relay(bob, client)
    end
    world.clock = world.clock + 30
    assert(off:Approve(annClaim.id))
    assert(dan:Approve(annClaim.id))
    assert(dan:Approve(bobClaim.id))
    assert(admin:DirectGrant("Bob", "m1", 7))
    for _, from in ipairs(everyone) do
      for _, to in ipairs(everyone) do
        if from ~= to then
          relay(from, to)
        end
      end
    end
    local expected = admin:Standings()
    assert.are.equal(2, #expected)
    assert.are.equal(17, expected[1].points)
    for _, client in ipairs(everyone) do
      assert.are.same(expected, client:Standings(), client.name)
    end
  end)
end)
