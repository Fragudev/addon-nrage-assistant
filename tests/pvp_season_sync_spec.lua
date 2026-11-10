-- PvP season records on the wire: who may author each type, conflicts, the claim queue, closing a season, the ledger
-- catch-up (digest, paging, relayed authors) and the guarantee that two clients end up with the same standings.
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
    "Domain/PvPSeasonModel",
    "Sync/Codec",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/PvPSeasonSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Protocol, Sync, Model, Constants = ns.Protocol, ns.PvPSeasonSync, ns.PvPSeasonModel, ns.Constants
local codec = ns.Codec.New({
  serialize = _G.LibStub("NrageAssistant-LibSerialize"),
  deflate = _G.LibStub("LibDeflate"),
})

-- Off is a co-guild master. Off2 and Flag are members: Flag has a stored PvP officer flag, which gives no power.
local ROLES = {
  Boss = "gm",
  Rl = "rl",
  Off = "cogm",
  Off2 = "member",
  Flag = "member",
  Ann = "member",
  Bob = "member",
  Cat = "member",
}
-- A catch-up is only believed about other authors when whoever whispered it is a gm or cogm.
local GLOBAL_RELAY = { sender = "Boss", global = true }
local DAY = 86400
local T0 = 1792454400 -- 2026-10-20 00:00 UTC
local SEASON_START, SEASON_END = T0 - 10 * DAY, T0 + 30 * DAY

local function copy(base, change)
  local out = {}
  for key, value in pairs(base) do
    out[key] = value
  end
  for key, value in pairs(change or {}) do
    if value == "__nil" then
      out[key] = nil
    else
      out[key] = value
    end
  end
  return out
end

local function wire(messageType, payload)
  return assert(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")))
end

local function seasonRecord(change)
  return copy({
    id = "s1",
    name = "Season One",
    startsAt = SEASON_START,
    endsAt = SEASON_END,
    state = "active",
    rev = 1,
    updatedAt = T0,
  }, change)
end

local function missionRecord(change)
  return copy({
    id = "m1",
    seasonId = "s1",
    title = "Hunt",
    desc = "",
    points = 10,
    goal = { kind = "kills", count = 2, zones = {}, place = "any", distinct = "none" },
    repeatKind = "daily",
    perPlayer = 2,
    active = true,
    rev = 1,
    updatedAt = T0,
  }, change)
end

local function claimRecord(player, n, at, change)
  at = at or T0 + 100
  return copy({
    id = Model.ClaimId(player, "m1", Model.PeriodKey("daily", at), n),
    missionId = "m1",
    seasonId = "s1",
    periodKey = Model.PeriodKey("daily", at),
    player = player,
    at = at,
    summary = { done = 2, total = 2 },
    evidence = { { at = at - 5, victim = "Grunt", place = "world", mapId = 1424 } },
  }, change)
end

local function grantRecord(id, player, points, at, change)
  return copy(
    { id = id, seasonId = "s1", player = player, missionId = "m1", points = points, at = at or T0 + 200 },
    change
  )
end

local function officerRecord(player, intervals, rev)
  return { player = player, intervals = intervals, rev = rev or 1, updatedAt = T0 }
end

-- A receiving client with its own ledger and its own idea of the clock, the roster and whether it approves claims.
local function new_client(options)
  options = options or {}
  local client = {
    ledger = Sync.NewLedger(),
    clock = T0 + 1000,
    roles = options.roles or ROLES,
    approver = options.approver ~= false,
    closed = {},
  }
  function client.ctx()
    return {
      ledger = client.ledger,
      now = function()
        return client.clock
      end,
      roleOf = function(name)
        return client.roles[name]
      end,
      isApprover = function()
        return client.approver
      end,
      onSeasonClosed = function(seasonId)
        client.closed[#client.closed + 1] = seasonId
      end,
    }
  end
  function client.deliver(messageType, payload, by)
    return Sync.Apply(client.ctx(), wire(messageType, payload), by)
  end
  function client.standings(seasonId)
    seasonId = seasonId or "s1"
    local ctx = client.ctx()
    return Model.Standings(
      client.ledger.grants[seasonId] or {},
      client.ledger.voids,
      client.ledger.officers,
      ctx.roleOf,
      seasonId
    )
  end
  -- Season, mission and the (powerless) officer flag of Flag, the usual starting point.
  function client.setup()
    assert(client.deliver("PVP_SEASON", seasonRecord(), "Boss"))
    assert(client.deliver("PVP_MISSION", missionRecord(), "Boss"))
    assert(client.deliver("PVP_OFFICER", officerRecord("Flag", { { from = T0 } }), "Boss"))
    return client
  end
  return client
end

describe("PvPSeasonSync authority", function()
  local client

  before_each(function()
    client = new_client()
  end)

  it("lets only an admin author a season, a mission, prizes, an officer, a void and a final", function()
    local records = {
      { "PVP_SEASON", seasonRecord() },
      { "PVP_MISSION", missionRecord() },
      { "PVP_PRIZES", { seasonId = "s1", tiers = {}, rev = 1, updatedAt = T0 } },
      { "PVP_OFFICER", officerRecord("Off", { { from = T0 } }) },
      { "PVP_VOID", { grantId = "g1", seasonId = "s1", at = T0 } },
      {
        "PVP_FINAL",
        {
          seasonId = "s1",
          name = "Season One",
          startsAt = SEASON_START,
          endsAt = SEASON_END,
          closedAt = T0,
          standings = {},
          prizes = {},
        },
      },
    }
    for _, entry in ipairs(records) do
      local messageType, payload = entry[1], entry[2]
      for _, who in ipairs({ "Rl", "Ann", "Off2", "Flag" }) do
        local ok, reason = client.deliver(messageType, payload, who)
        assert.is_false(ok, messageType .. " by " .. who)
        assert.are.equal("forbidden", reason, messageType .. " by " .. who)
      end
      local ok, reason = client.deliver(messageType, payload, "Stranger")
      assert.is_false(ok)
      assert.are.equal("unknown_sender", reason, messageType)
    end
    -- Nothing was stored by any of them.
    assert.is_nil(client.ledger.activeId)
    assert.is_nil(next(client.ledger.seasons))
    assert.is_nil(next(client.ledger.officers))
    assert.is_nil(next(client.ledger.finals))
    for _, entry in ipairs(records) do
      assert.is_true(client.deliver(entry[1], entry[2], "Boss"), entry[1])
    end
  end)

  it("lets gm and cogm decide claims, and nobody else, a stored officer flag included", function()
    client.setup()
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 50), "Boss"))
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 10, T0 + 50), "Off"))
    for _, who in ipairs({ "Flag", "Off2", "Rl" }) do
      local ok, reason = client.deliver("PVP_GRANT", grantRecord("Cat:m1:20261020:1", "Cat", 10, T0 + 50), who)
      assert.is_false(ok, who)
      assert.are.equal("forbidden", reason, who)
    end
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("Cat:m1:20261020:1", "Cat", 10, T0 + 50), "Stranger")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({ "Ann", "Bob" }, { client.standings()[1].player, client.standings()[2].player })

    assert.is_true(
      client.deliver("PVP_REJECT", { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 60 }, "Off")
    )
    for _, who in ipairs({ "Ann", "Flag" }) do
      ok, reason = client.deliver("PVP_REJECT", { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 70 }, who)
      assert.is_false(ok, who)
      assert.are.equal("forbidden", reason, who)
    end
  end)

  it("lets gm and cogm make a direct grant or approve their own claim, and nobody else", function()
    client.setup()
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("direct-1", "Ann", 10), "Flag")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = client.deliver("PVP_GRANT", grantRecord("Flag:m1:20261020:1", "Flag", 10), "Flag")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("direct-1", "Ann", 10), "Boss"))
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Boss:m1:20261020:1", "Boss", 10), "Boss"))
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("direct-2", "Ann", 10), "Off"))
  end)

  it("lets gm and cogm mark a delivery, and the sender decides, not the payload", function()
    client.setup()
    local delivery = { seasonId = "s1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 5 }
    assert.is_true(client.deliver("PVP_DELIVERY", delivery, "Off"))
    for _, who in ipairs({ "Ann", "Flag" }) do
      local ok, reason = client.deliver("PVP_DELIVERY", copy(delivery, { rev = 2 }), who)
      assert.is_false(ok, who)
      assert.are.equal("forbidden", reason, who)
    end
    -- A payload that names an author gets no say: the field is dropped by validation.
    local forged = copy(grantRecord("direct-2", "Ann", 10), { by = "Boss" })
    local ok, reason = client.deliver("PVP_GRANT", forged, "Ann")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.is_nil(next(client.ledger.grants))
  end)
end)

describe("PvPSeasonSync seasons, missions, prizes and officers", function()
  local client

  before_each(function()
    client = new_client()
  end)

  it("stores a season and makes it the active one", function()
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord(), "Boss"))
    assert.are.equal("s1", client.ledger.activeId)
    local stored = client.ledger.seasons.s1
    assert.are.equal("Season One", stored.name)
    assert.are.equal("Boss", stored.updatedBy)
  end)

  it("elects one active season among several, the same on every client whatever order they arrived in", function()
    local seasons = {
      { seasonRecord(), "Boss" },
      { seasonRecord({ id = "s2", name = "Two" }), "Boss" },
      { seasonRecord({ id = "s3", name = "Three", rev = 2 }), "Boss" },
      { seasonRecord({ id = "s4", name = "Four", rev = 2, updatedAt = T0 + 5 }), "Off" },
      { seasonRecord({ id = "s5", name = "Five", rev = 2, updatedAt = T0 + 5 }), "Boss" },
    }
    -- Every rotation (and the reverse) of the arrival order ends with the same winner: s4 (rev, then time, then the
    -- larger author, "Off" over "Boss").
    for shift = 0, #seasons - 1 do
      for _, reverse in ipairs({ false, true }) do
        local other = new_client()
        for step = 1, #seasons do
          local index = (step + shift - 1) % #seasons + 1
          if reverse then
            index = #seasons + 1 - index
          end
          assert.is_true(other.deliver("PVP_SEASON", seasons[index][1], seasons[index][2]))
        end
        assert.are.equal("s4", other.ledger.activeId, ("shift %d, reverse %s"):format(shift, tostring(reverse)))
      end
    end
  end)

  it("hands the active season to the one that outranks the rest when the first is closed", function()
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord(), "Boss"))
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ id = "s2", name = "Two", rev = 2 }), "Boss"))
    assert.are.equal("s2", client.ledger.activeId)
    assert.is_true(
      client.deliver("PVP_SEASON", seasonRecord({ id = "s2", rev = 3, state = "closed", updatedAt = T0 + 1 }), "Boss")
    )
    assert.are.equal("s1", client.ledger.activeId)
    assert.is_true(
      client.deliver("PVP_SEASON", seasonRecord({ rev = 2, state = "closed", updatedAt = T0 + 1 }), "Boss")
    )
    assert.is_nil(client.ledger.activeId)
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ id = "s3", name = "Three" }), "Boss"))
    assert.are.equal("s3", client.ledger.activeId)
  end)

  it("follows revisions: a newer edit wins, an older or equal one does not", function()
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ rev = 2, name = "Edited" }), "Boss"))
    local ok, reason = client.deliver("PVP_SEASON", seasonRecord({ rev = 1, name = "Old" }), "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    ok, reason = client.deliver("PVP_SEASON", seasonRecord({ rev = 2, name = "Edited" }), "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal("Edited", client.ledger.seasons.s1.name)
  end)

  it("clamps an update date that lies in the future", function()
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ updatedAt = T0 + 10 * DAY }), "Boss"))
    assert.are.equal(client.clock + 300, client.ledger.seasons.s1.updatedAt)
  end)

  it("limits the number of seasons", function()
    local old = Constants.PVP_SEASONS_MAX
    Constants.PVP_SEASONS_MAX = 2
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ id = "a", state = "closed" }), "Boss"))
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ id = "b", state = "closed" }), "Boss"))
    local ok, reason = client.deliver("PVP_SEASON", seasonRecord({ id = "c" }), "Boss")
    Constants.PVP_SEASONS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)

  it("stores missions, keeps one in its season and limits them per season", function()
    assert.is_true(client.deliver("PVP_MISSION", missionRecord(), "Boss"))
    assert.are.equal("Hunt", client.ledger.missions.m1.title)
    local ok, reason = client.deliver("PVP_MISSION", missionRecord({ rev = 2, seasonId = "s2" }), "Boss")
    assert.is_false(ok)
    assert.are.equal("invalid", reason)
    assert.is_true(client.deliver("PVP_MISSION", missionRecord({ rev = 2, title = "Renamed", active = false }), "Boss"))
    assert.are.equal("Renamed", client.ledger.missions.m1.title)
    assert.is_false(client.ledger.missions.m1.active)

    local old = Constants.PVP_MISSIONS_MAX
    Constants.PVP_MISSIONS_MAX = 1
    ok, reason = client.deliver("PVP_MISSION", missionRecord({ id = "m2" }), "Boss")
    Constants.PVP_MISSIONS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    -- Another season has its own room.
    assert.is_true(client.deliver("PVP_MISSION", missionRecord({ id = "m3", seasonId = "s2" }), "Boss"))
  end)

  it("replaces the whole prize record", function()
    local first = { seasonId = "s1", tiers = { ["1"] = { { kind = "gold", amount = 100 } } }, rev = 1, updatedAt = T0 }
    assert.is_true(client.deliver("PVP_PRIZES", first, "Boss"))
    assert.is_true(
      client.deliver("PVP_PRIZES", { seasonId = "s1", tiers = { ["2"] = {} }, rev = 2, updatedAt = T0 }, "Boss")
    )
    assert.is_nil(client.ledger.prizes.s1.tiers["1"])
    local ok, reason = client.deliver("PVP_PRIZES", first, "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
  end)

  it("stores officers by revision and limits them", function()
    assert.is_true(client.deliver("PVP_OFFICER", officerRecord("Off", { { from = 10 } }), "Boss"))
    assert.is_true(client.deliver("PVP_OFFICER", officerRecord("Off", { { from = 10, to = 20 } }, 2), "Boss"))
    assert.is_false(Model.IsOfficer(client.ledger.officers.Off))
    local ok, reason = client.deliver("PVP_OFFICER", officerRecord("Off", { { from = 10 } }, 1), "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    local old = Constants.PVP_OFFICERS_MAX
    Constants.PVP_OFFICERS_MAX = 1
    ok, reason = client.deliver("PVP_OFFICER", officerRecord("Off2", { { from = 10 } }), "Boss")
    Constants.PVP_OFFICERS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("PvPSeasonSync claims", function()
  local client

  before_each(function()
    client = new_client().setup()
  end)

  it("queues a claim of the sender for an approver", function()
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    local queued = client.ledger.queue["Ann:m1:20261020:1"]
    assert.are.equal("Ann", queued.player)
    assert.are.equal(1, #queued.evidence)
    assert.are.equal(client.clock, queued.receivedAt)
  end)

  it("ignores a claim when this client does not approve claims", function()
    local member = new_client({ approver = false }).setup()
    local ok, reason = member.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann")
    assert.is_false(ok)
    assert.are.equal("not_approver", reason)
    assert.is_nil(next(member.ledger.queue))
  end)

  it("refuses a claim for another player, from an unknown sender", function()
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Ann")
    assert.is_false(ok)
    assert.are.equal("bad_player", reason)
    ok, reason = client.deliver("PVP_CLAIM", claimRecord("Zed", 1), "Zed")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
  end)

  it("keeps the first of a claim sent twice", function()
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 1, nil, { note = "again" }), "Ann")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
    assert.is_nil(client.ledger.queue["Ann:m1:20261020:1"].note)
  end)

  it("refuses claims the season and the mission do not allow", function()
    local function reasonOf(record, who)
      local ok, reason = client.deliver("PVP_CLAIM", record, who or "Ann")
      assert.is_false(ok)
      return reason
    end
    assert.are.equal("limit", reasonOf(claimRecord("Ann", 3)))
    client.clock = SEASON_END + 1000
    assert.are.equal("out_of_season", reasonOf(claimRecord("Ann", 1, SEASON_END + 5)))
    client.clock = T0 + 1000
    assert.are.equal(
      "out_of_season",
      reasonOf(
        claimRecord("Ann", 1, T0 + 100, { evidence = { { at = SEASON_START - 1, victim = "G", place = "world" } } })
      )
    )
    assert.are.equal("future", reasonOf(claimRecord("Ann", 1, T0 + 5 * DAY)))
    assert.are.equal(
      "bad_period",
      reasonOf(claimRecord("Ann", 1, T0 + 100, { periodKey = "all", id = "Ann:m1:all:1" }))
    )
    assert.are.equal(
      "unknown_mission",
      reasonOf(claimRecord("Ann", 1, T0 + 100, { missionId = "m9", id = "Ann:m9:20261020:1" }))
    )
    assert.are.equal("unknown_season", reasonOf(claimRecord("Ann", 1, T0 + 100, { seasonId = "s9" })))
    assert.is_true(client.deliver("PVP_MISSION", missionRecord({ rev = 2, active = false }), "Boss"))
    assert.are.equal("inactive", reasonOf(claimRecord("Ann", 1)))
    assert.is_nil(next(client.ledger.queue))
  end)

  it("refuses a claim for a season that is no longer active", function()
    assert.is_true(client.deliver("PVP_SEASON", seasonRecord({ rev = 2, state = "closed" }), "Boss"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
  end)

  it("does not queue a claim that was decided already", function()
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10), "Boss"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann")
    assert.is_false(ok)
    assert.are.equal("decided", reason)
    assert.is_true(
      client.deliver("PVP_REJECT", { claimId = "Bob:m1:20261020:1", seasonId = "s1", at = T0 + 5 }, "Boss")
    )
    ok, reason = client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob")
    assert.is_false(ok)
    assert.are.equal("decided", reason)
  end)

  it("takes a claim out of the queue when it is granted, and keeps a rejected one for a change of mind", function()
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob"))
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10), "Off"))
    assert.is_true(client.deliver("PVP_REJECT", { claimId = "Bob:m1:20261020:1", seasonId = "s1", at = T0 + 5 }, "Off"))
    assert.is_nil(client.ledger.queue["Ann:m1:20261020:1"])
    assert.is_truthy(client.ledger.queue["Bob:m1:20261020:1"])
    assert.is_truthy(client.ledger.rejects["Bob:m1:20261020:1"])
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 10), "Off"))
    assert.is_nil(next(client.ledger.queue))
  end)

  it("lets rejected claims make room when the queue is full", function()
    local old = Constants.PVP_QUEUE_MAX
    Constants.PVP_QUEUE_MAX = 2
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Cat", 1), "Cat")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_true(client.deliver("PVP_REJECT", { claimId = "Ann:m1:20261020:1", seasonId = "s1", at = T0 + 5 }, "Off"))
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Cat", 1), "Cat"))
    Constants.PVP_QUEUE_MAX = old
    assert.is_nil(client.ledger.queue["Ann:m1:20261020:1"])
    assert.is_truthy(client.ledger.queue["Bob:m1:20261020:1"])
    assert.is_truthy(client.ledger.queue["Cat:m1:20261020:1"])
  end)

  it("limits the queue, and what one player can put in it", function()
    local oldQueue, oldPlayer = Constants.PVP_QUEUE_MAX, Constants.PVP_QUEUE_PER_PLAYER_MAX
    Constants.PVP_QUEUE_PER_PLAYER_MAX = 1
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 2), "Ann")
    Constants.PVP_QUEUE_PER_PLAYER_MAX = oldPlayer
    assert.is_false(ok)
    assert.are.equal("limit", reason)

    Constants.PVP_QUEUE_MAX = 1
    ok, reason = client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob")
    Constants.PVP_QUEUE_MAX = oldQueue
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("PvPSeasonSync claims past maxCompletions", function()
  local client

  before_each(function()
    client = new_client()
    assert(client.deliver("PVP_SEASON", seasonRecord(), "Boss"))
    assert(client.deliver(
      "PVP_MISSION",
      missionRecord({
        goal = { kind = "kills", count = 2, zones = {}, place = "any", distinct = "none", maxCompletions = 1 },
        perPlayer = 5,
      }),
      "Boss"
    ))
  end)

  it("refuses a second claim while the first one waits, and accepts it again once it is rejected", function()
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 2), "Ann")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    -- another member is not affected
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob"))
    assert.is_true(
      client.deliver("PVP_REJECT", { claimId = "Ann:m1:20261020:1", seasonId = "s1", at = T0 + 300 }, "Boss")
    )
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 2), "Ann"))
  end)

  it("counts the approved claims of the player, and not a voided grant", function()
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261019:1", "Ann", 10), "Boss"))
    local ok, reason = client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_true(
      client.deliver(
        "PVP_VOID",
        { grantId = "Ann:m1:20261019:1", seasonId = "s1", reason = "mistake", at = T0 + 400 },
        "Boss"
      )
    )
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
  end)

  it("does not limit a mission without maxCompletions", function()
    assert(client.deliver("PVP_MISSION", missionRecord({ rev = 2, perPlayer = 5 }), "Boss"))
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Ann", 2), "Ann"))
  end)
end)

describe("PvPSeasonSync grants, voids and rejections", function()
  local client

  before_each(function()
    client = new_client().setup()
  end)

  it("stores a grant once: a replay with the same id is a no-op", function()
    local grant = grantRecord("Ann:m1:20261020:1", "Ann", 10)
    assert.is_true(client.deliver("PVP_GRANT", grant, "Boss"))
    local ok, reason = client.deliver("PVP_GRANT", copy(grant, { points = 999 }), "Boss")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
    assert.are.equal(10, client.ledger.grants.s1["Ann:m1:20261020:1"].points)
    assert.are.equal(10, client.standings()[1].points)
  end)

  it("lets a second approver approve the same claim without counting it twice", function()
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 200), "Boss"))
    local ok = client.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 205), "Off")
    assert.is_false(ok)
    assert.are.equal(10, client.standings()[1].points)
  end)

  it("lets a grant beat a rejection of the same claim in either order", function()
    local reject = { claimId = "Ann:m1:20261020:1", seasonId = "s1", at = T0 + 100 }
    local grant = grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 200)
    assert.is_true(client.deliver("PVP_REJECT", reject, "Boss"))
    assert.is_true(client.deliver("PVP_GRANT", grant, "Boss"))
    assert.are.equal(10, client.standings()[1].points)

    local other = new_client().setup()
    assert.is_true(other.deliver("PVP_GRANT", grant, "Boss"))
    assert.is_true(other.deliver("PVP_REJECT", reject, "Boss"))
    assert.are.equal(10, other.standings()[1].points)
    assert.are.same(Sync.Summary(client.ledger, "s1"), Sync.Summary(other.ledger, "s1"))
  end)

  it("keeps the latest rejection of a claim and the same one whatever the order", function()
    local first = { claimId = "Ann:m1:20261020:1", seasonId = "s1", reason = "first", at = T0 + 10 }
    local second = copy(first, { reason = "second", at = T0 + 20 })
    assert.is_true(client.deliver("PVP_REJECT", first, "Boss"))
    assert.is_true(client.deliver("PVP_REJECT", second, "Boss"))
    local ok, reason = client.deliver("PVP_REJECT", first, "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    ok, reason = client.deliver("PVP_REJECT", second, "Boss")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
    assert.are.equal("second", client.ledger.rejects["Ann:m1:20261020:1"].reason)
    -- Same instant, two authors: the larger one wins on every client.
    local a, b = new_client().setup(), new_client().setup()
    local one, two = copy(first, { reason = "by boss" }), copy(first, { reason = "by off" })
    a.deliver("PVP_REJECT", one, "Boss")
    a.deliver("PVP_REJECT", two, "Off")
    b.deliver("PVP_REJECT", two, "Off")
    b.deliver("PVP_REJECT", one, "Boss")
    assert.are.equal(a.ledger.rejects["Ann:m1:20261020:1"].by, b.ledger.rejects["Ann:m1:20261020:1"].by)
  end)

  it("lets a void take a grant out of the standings, even one that arrives after it", function()
    local grant = grantRecord("Ann:m1:20261020:1", "Ann", 10)
    assert.is_true(
      client.deliver("PVP_VOID", { grantId = grant.id, seasonId = "s1", reason = "abuse", at = T0 + 300 }, "Boss")
    )
    assert.is_true(client.deliver("PVP_GRANT", grant, "Boss"))
    assert.are.equal(0, #client.standings())
    local ok, reason = client.deliver("PVP_VOID", { grantId = grant.id, seasonId = "s1", at = T0 + 400 }, "Boss")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
  end)

  it("refuses a grant stamped far in the future and one for a closed season", function()
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("g-1", "Ann", 10, T0 + 9 * DAY), "Boss")
    assert.is_false(ok)
    assert.are.equal("future", reason)
    assert.is_true(client.deliver("PVP_FINAL", {
      seasonId = "s1",
      name = "Season One",
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0 + 500,
      standings = {},
      prizes = {},
    }, "Boss"))
    ok, reason = client.deliver("PVP_GRANT", grantRecord("g-1", "Ann", 10), "Boss")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
    ok, reason = client.deliver("PVP_VOID", { grantId = "g-1", seasonId = "s1", at = T0 + 1 }, "Boss")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
    ok, reason = client.deliver("PVP_REJECT", { claimId = "Ann:m1:20261020:1", seasonId = "s1", at = T0 + 1 }, "Boss")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
  end)

  it("limits the grants of a season but never evicts one", function()
    local old = Constants.PVP_GRANTS_MAX
    Constants.PVP_GRANTS_MAX = 2
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("g-1", "Ann", 10), "Boss"))
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("g-2", "Bob", 10), "Boss"))
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("g-3", "Cat", 10), "Boss")
    Constants.PVP_GRANTS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_truthy(client.ledger.grants.s1["g-1"])
    assert.is_truthy(client.ledger.grants.s1["g-2"])
  end)

  it("limits the voids and the rejections", function()
    local oldVoids, oldRejects = Constants.PVP_VOIDS_MAX, Constants.PVP_REJECTS_MAX
    Constants.PVP_VOIDS_MAX, Constants.PVP_REJECTS_MAX = 1, 1
    assert.is_true(client.deliver("PVP_VOID", { grantId = "g-1", seasonId = "s1", at = T0 }, "Boss"))
    local ok, reason = client.deliver("PVP_VOID", { grantId = "g-2", seasonId = "s1", at = T0 }, "Boss")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_true(client.deliver("PVP_REJECT", { claimId = "Ann:m1:20261020:1", seasonId = "s1", at = T0 }, "Boss"))
    ok, reason = client.deliver("PVP_REJECT", { claimId = "Bob:m1:20261020:1", seasonId = "s1", at = T0 }, "Boss")
    Constants.PVP_VOIDS_MAX, Constants.PVP_REJECTS_MAX = oldVoids, oldRejects
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)

  it("limits the seasons that hold grants", function()
    local old = Constants.PVP_SEASONS_MAX
    Constants.PVP_SEASONS_MAX = 1
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("g-1", "Ann", 10), "Boss"))
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("g-2", "Ann", 10, T0 + 1, { seasonId = "s2" }), "Boss")
    Constants.PVP_SEASONS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("PvPSeasonSync closing a season", function()
  local client
  local function finalPayload(standings)
    return {
      seasonId = "s1",
      name = "Season One",
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0 + 900,
      standings = standings,
      prizes = { ["1"] = { { kind = "gold", amount = 50 } } },
    }
  end

  before_each(function()
    client = new_client().setup()
  end)

  it("freezes the standing, forgets the detail and creates a delivery for each prize winner", function()
    assert.is_true(client.deliver("PVP_GRANT", grantRecord("g-1", "Ann", 30), "Boss"))
    assert.is_true(client.deliver("PVP_VOID", { grantId = "g-1", seasonId = "s1", at = T0 + 300 }, "Boss"))
    assert.is_true(
      client.deliver("PVP_REJECT", { claimId = "Bob:m1:20261020:1", seasonId = "s1", at = T0 + 5 }, "Boss")
    )
    assert.is_true(client.deliver("PVP_CLAIM", claimRecord("Cat", 1), "Cat"))
    local standings = {}
    for position = 1, 12 do
      standings[position] = { pos = position, player = "P" .. position, points = 100 - position, lastAt = T0 }
    end
    assert.is_true(client.deliver("PVP_FINAL", finalPayload(standings), "Boss"))

    local ledger = client.ledger
    assert.are.equal("Boss", ledger.finals.s1.closedBy)
    assert.are.equal(12, #ledger.finals.s1.standings)
    assert.are.equal("closed", ledger.seasons.s1.state)
    assert.is_nil(ledger.activeId)
    assert.is_nil(ledger.grants.s1)
    assert.is_nil(next(ledger.voids))
    assert.is_nil(next(ledger.rejects))
    assert.is_nil(next(ledger.queue))
    assert.are.same({ "s1" }, client.closed)
    -- Ten deliveries, none marked, in the right tier; positions 11 and 12 have none.
    local deliveries = ledger.deliveries.s1
    local count = 0
    for _ in pairs(deliveries) do
      count = count + 1
    end
    assert.are.equal(10, count)
    assert.are.same(
      { tier = "1", delivered = false },
      { tier = deliveries.P1.tier, delivered = deliveries.P1.delivered }
    )
    assert.are.equal("4-6", deliveries.P5.tier)
    assert.are.equal("7-10", deliveries.P10.tier)
    assert.is_nil(deliveries.P11)
    -- The missions and the prizes stay.
    assert.is_truthy(ledger.missions.m1)
  end)

  it("is authoritative: a grant received afterwards is ignored", function()
    assert.is_true(
      client.deliver("PVP_FINAL", finalPayload({ { pos = 1, player = "Ann", points = 50, lastAt = T0 } }), "Boss")
    )
    local ok, reason = client.deliver("PVP_GRANT", grantRecord("g-9", "Bob", 999), "Boss")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
    assert.is_nil(client.ledger.grants.s1)
    ok, reason = client.deliver("PVP_SEASON", seasonRecord({ rev = 5 }), "Boss")
    assert.is_false(ok)
    assert.are.equal("closed", reason)
  end)

  it("still takes the missions and prizes of a closed season, which may reach a client after its final", function()
    assert.is_true(
      client.deliver("PVP_FINAL", finalPayload({ { pos = 1, player = "Ann", points = 50, lastAt = T0 } }), "Boss")
    )
    assert.is_true(client.deliver("PVP_MISSION", missionRecord({ rev = 5, title = "Late" }), "Boss"))
    assert.is_true(client.deliver("PVP_PRIZES", { seasonId = "s1", tiers = {}, rev = 5, updatedAt = T0 }, "Boss"))
    assert.are.equal("Late", client.ledger.missions.m1.title)
  end)

  it("keeps the first final of a season", function()
    local first = finalPayload({ { pos = 1, player = "Ann", points = 50, lastAt = T0 } })
    assert.is_true(client.deliver("PVP_FINAL", first, "Boss"))
    local ok, reason =
      client.deliver("PVP_FINAL", finalPayload({ { pos = 1, player = "Bob", points = 99, lastAt = T0 } }), "Boss")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
    assert.are.equal("Ann", client.ledger.finals.s1.standings[1].player)
  end)

  it("keeps a season the client never saw as history", function()
    local fresh = new_client()
    assert.is_true(
      fresh.deliver("PVP_FINAL", finalPayload({ { pos = 1, player = "Ann", points = 50, lastAt = T0 } }), "Boss")
    )
    assert.are.equal("closed", fresh.ledger.seasons.s1.state)
    assert.are.equal("Season One", fresh.ledger.seasons.s1.name)
    -- The season message that comes later cannot reopen it.
    local ok = fresh.deliver("PVP_SEASON", seasonRecord(), "Boss")
    assert.is_false(ok)
    assert.is_nil(fresh.ledger.activeId)
  end)

  it("limits the number of finals", function()
    local old = Constants.PVP_FINALS_MAX
    Constants.PVP_FINALS_MAX = 0
    local ok, reason = client.deliver("PVP_FINAL", finalPayload({}), "Boss")
    Constants.PVP_FINALS_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)

  it("marks deliveries by revision, only for a prize winner and in their tier once the final is known", function()
    assert.is_true(client.deliver(
      "PVP_FINAL",
      finalPayload({
        { pos = 1, player = "Ann", points = 50, lastAt = T0 },
        { pos = 2, player = "Bob", points = 40, lastAt = T0 },
      }),
      "Boss"
    ))
    local delivery = { seasonId = "s1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 2000 }
    assert.is_true(client.deliver("PVP_DELIVERY", delivery, "Boss"))
    assert.is_true(client.ledger.deliveries.s1.Ann.delivered)
    local ok, reason = client.deliver("PVP_DELIVERY", copy(delivery, { delivered = false }), "Boss")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.is_true(client.deliver("PVP_DELIVERY", copy(delivery, { delivered = false, rev = 2 }), "Off"))
    assert.is_false(client.ledger.deliveries.s1.Ann.delivered)
    ok, reason = client.deliver("PVP_DELIVERY", copy(delivery, { player = "Cat" }), "Boss")
    assert.is_false(ok)
    assert.are.equal("invalid", reason)
    ok, reason = client.deliver("PVP_DELIVERY", copy(delivery, { tier = "2", rev = 3 }), "Boss")
    assert.is_false(ok)
    assert.are.equal("invalid", reason)
  end)

  it("keeps a delivery that arrived before the final and drops the ones the final does not rank", function()
    local early = { seasonId = "s1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 5 }
    assert.is_true(client.deliver("PVP_DELIVERY", early, "Boss"))
    assert.is_true(client.deliver("PVP_DELIVERY", copy(early, { player = "Ghost" }), "Boss"))
    assert.is_true(
      client.deliver("PVP_FINAL", finalPayload({ { pos = 1, player = "Ann", points = 50, lastAt = T0 } }), "Boss")
    )
    assert.is_true(client.ledger.deliveries.s1.Ann.delivered)
    assert.is_nil(client.ledger.deliveries.s1.Ghost)
  end)

  it("limits the deliveries of a season", function()
    local old = Constants.PVP_DELIVERIES_MAX
    Constants.PVP_DELIVERIES_MAX = 1
    local delivery = { seasonId = "s1", player = "Ann", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 5 }
    assert.is_true(client.deliver("PVP_DELIVERY", delivery, "Boss"))
    local ok, reason = client.deliver("PVP_DELIVERY", copy(delivery, { player = "Bob" }), "Boss")
    Constants.PVP_DELIVERIES_MAX = old
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("PvPSeasonSync.Apply", function()
  it("does not apply what it does not know", function()
    local client = new_client()
    local ok, reason = Sync.Apply(client.ctx(), { t = "PVP_LEDGER_DATA", p = {} }, "Boss")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
    assert.is_true(Sync.IsSeasonMessage("PVP_LEDGER_REQ"))
    assert.is_false(Sync.IsRecordMessage("PVP_LEDGER_REQ"))
    assert.is_false(Sync.IsSeasonMessage("PVP_LEDGER_DATA"))
    assert.is_false(Sync.IsSeasonMessage("PROFILE"))
  end)
end)

-- A complete ledger to move from one client to another.
local function seeded_admin()
  local admin = new_client().setup()
  assert(
    admin.deliver(
      "PVP_PRIZES",
      { seasonId = "s1", tiers = { ["1"] = { { kind = "gold", amount = 5 } } }, rev = 1, updatedAt = T0 },
      "Boss"
    )
  )
  assert(admin.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 10), "Boss"))
  assert(admin.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 20, T0 + 20), "Off"))
  assert(admin.deliver("PVP_GRANT", grantRecord("direct-1", "Cat", 5, T0 + 30), "Boss"))
  assert(admin.deliver("PVP_VOID", { grantId = "direct-1", seasonId = "s1", reason = "oops", at = T0 + 40 }, "Boss"))
  assert(
    admin.deliver(
      "PVP_REJECT",
      { claimId = "Cat:m1:20261020:1", seasonId = "s1", reason = "no proof", at = T0 + 50 },
      "Off"
    )
  )
  return admin
end

local function fits_one_whisper(page)
  return codec:Encode(
    Protocol.Build("PVP_LEDGER_DATA", { seasonId = "s1", page = 1, pages = 1, items = page }, "id"),
    Constants.SYNC_MAX_ENCODED_BYTES
  ) ~= nil
end

describe("PvPSeasonSync ledger catch-up", function()
  it("describes a ledger by a count and a digest that do not depend on the order it was built in", function()
    local first = seeded_admin()
    local second = new_client()
    -- The same records, delivered in the reverse order of what is stored here (officer flag first).
    second.deliver("PVP_OFFICER", officerRecord("Flag", { { from = T0 } }), "Boss")
    second.deliver(
      "PVP_REJECT",
      { claimId = "Cat:m1:20261020:1", seasonId = "s1", reason = "no proof", at = T0 + 50 },
      "Off"
    )
    second.deliver("PVP_VOID", { grantId = "direct-1", seasonId = "s1", reason = "oops", at = T0 + 40 }, "Boss")
    second.deliver("PVP_GRANT", grantRecord("direct-1", "Cat", 5, T0 + 30), "Boss")
    second.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 20, T0 + 20), "Off")
    second.deliver("PVP_GRANT", grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 10), "Boss")
    second.deliver(
      "PVP_PRIZES",
      { seasonId = "s1", tiers = { ["1"] = { { kind = "gold", amount = 5 } } }, rev = 1, updatedAt = T0 },
      "Boss"
    )
    second.deliver("PVP_MISSION", missionRecord(), "Boss")
    second.deliver("PVP_SEASON", seasonRecord(), "Boss")
    assert.are.same(Sync.Summary(first.ledger, "s1"), Sync.Summary(second.ledger, "s1"))
    assert.is_false(Sync.Differs(second.ledger, Sync.RequestPayload(first.ledger, "s1")))
  end)

  it("notices a missing grant, a different officer revision and a finished season", function()
    local full = seeded_admin()
    local partial = seeded_admin()
    partial.ledger.grants.s1["Ann:m1:20261020:1"] = nil
    assert.is_true(Sync.Differs(full.ledger, Sync.RequestPayload(partial.ledger, "s1")))
    local officer = seeded_admin()
    officer.ledger.officers.Flag.rev = 2
    assert.is_true(Sync.Differs(full.ledger, Sync.RequestPayload(officer.ledger, "s1")))
    local nothing = Sync.RequestPayload(new_client().ledger, nil)
    assert.are.equal(0, nothing.count)
    assert.is_true(Sync.Differs(full.ledger, nothing))
    assert.is_nil(nothing.seasonId)
  end)

  it("rebuilds a ledger from the items of a relay, officers first", function()
    local relay = seeded_admin()
    local items = Sync.LedgerItems(relay.ledger, Sync.ScopeFor(relay.ledger, { seasonId = "s1" }))
    assert.are.equal("PVP_OFFICER", items[1].t)
    local seen = {}
    for _, entry in ipairs(items) do
      seen[entry.t] = true
      assert.is_string(entry.by)
    end
    for _, messageType in ipairs({
      "PVP_OFFICER",
      "PVP_SEASON",
      "PVP_MISSION",
      "PVP_PRIZES",
      "PVP_GRANT",
      "PVP_VOID",
      "PVP_REJECT",
    }) do
      assert.is_true(seen[messageType], messageType)
    end

    local fresh = new_client()
    local summary = Sync.ApplyItems(fresh.ctx(), items, GLOBAL_RELAY)
    assert.are.equal(#items, summary.total)
    assert.are.equal(#items, summary.applied)
    assert.are.same(Sync.Summary(relay.ledger, "s1"), Sync.Summary(fresh.ledger, "s1"))
    assert.are.same(relay.standings(), fresh.standings())
  end)

  it("takes the author from the item, but only as far as that author could have written the record", function()
    local relay = seeded_admin()
    local fresh = new_client()
    local items = Sync.LedgerItems(relay.ledger, { "s1" })
    -- A relay that names a member as the author of an admin's record gets nothing applied for it.
    for _, entry in ipairs(items) do
      if entry.t == "PVP_SEASON" or entry.t == "PVP_MISSION" then
        entry.by = "Ann"
      end
    end
    local summary = Sync.ApplyItems(fresh.ctx(), items, GLOBAL_RELAY)
    assert.is_true(summary.applied < summary.total)
    assert.is_nil(fresh.ledger.activeId)
    assert.is_nil(next(fresh.ledger.missions))
  end)

  it("only believes an author other than the relay when the relay is a gm or cogm", function()
    local relay = seeded_admin()
    local items = Sync.LedgerItems(relay.ledger, { "s1" })

    -- An officer (rl) naming the guild master as the author of a season, a grant and a final: nothing is applied.
    local forged = new_client()
    local summary = Sync.ApplyItems(forged.ctx(), items, { sender = "Rl", global = false })
    assert.are.equal(0, summary.applied)
    assert.are.equal(#items, summary.forged)
    assert.is_nil(forged.ledger.activeId)
    assert.is_nil(next(forged.ledger.seasons))
    assert.is_nil(next(forged.ledger.grants))

    local finals = new_client()
    local final = {
      t = "PVP_FINAL",
      by = "Boss",
      p = {
        seasonId = "s1",
        name = "Season One",
        startsAt = SEASON_START,
        endsAt = SEASON_END,
        closedAt = T0 + 900,
        standings = { { pos = 1, player = "Ann", points = 10, lastAt = T0 + 10 } },
        prizes = {},
      },
    }
    summary = Sync.ApplyItems(finals.ctx(), { final }, { sender = "Rl", global = false })
    assert.are.equal(0, summary.applied)
    assert.is_nil(next(finals.ledger.finals))

    -- A relay that is not global is believed for records it authored itself, if its role allows them (it does not
    -- for an admin record), and without a relay nothing is believed.
    local own = new_client()
    local entry = { t = "PVP_SEASON", p = seasonRecord(), by = "Rl" }
    summary = Sync.ApplyItems(own.ctx(), { entry }, { sender = "Rl", global = false })
    assert.are.equal(0, summary.forged)
    assert.are.equal(0, summary.applied)
    assert.are.equal(0, Sync.ApplyItems(new_client().ctx(), items).applied)

    -- A gm or cogm relays them all.
    local trusted = new_client()
    summary = Sync.ApplyItems(trusted.ctx(), items, { sender = "Off", global = true })
    assert.are.equal(#items, summary.applied)
    assert.are.equal(0, summary.forged)
  end)

  it("skips items that are not records, have no author or do not validate", function()
    local fresh = new_client()
    local good = { t = "PVP_SEASON", p = seasonRecord(), by = "Boss" }
    local summary = Sync.ApplyItems(fresh.ctx(), {
      "text",
      { t = "PROFILE", p = {}, by = "Boss" },
      { t = "PVP_CLAIM", p = claimRecord("Ann", 1), by = "Ann" },
      { t = "PVP_SEASON", p = seasonRecord({ name = "" }), by = "Boss" },
      { t = "PVP_SEASON", p = seasonRecord() },
      { t = "PVP_SEASON", p = seasonRecord(), by = "a:b" },
      good,
    }, GLOBAL_RELAY)
    assert.are.equal(7, summary.total)
    assert.are.equal(1, summary.applied)
  end)

  it("only sends the detail of the season asked for and of the relay's active one", function()
    local relay = seeded_admin()
    assert.are.same({ "s1" }, Sync.ScopeFor(relay.ledger, { seasonId = "s1" }))
    assert.are.same({ "s1" }, Sync.ScopeFor(relay.ledger, {}))
    -- A season the relay does not hold is not sent.
    assert.are.same({ "s1" }, Sync.ScopeFor(relay.ledger, { seasonId = "old" }))
    relay.ledger.seasons.old = { id = "old", rev = 1, state = "closed" }
    assert.are.same({ "old", "s1" }, Sync.ScopeFor(relay.ledger, { seasonId = "old" }))
    assert.are.same({ "s1" }, Sync.ScopeFor(new_client().setup().ledger, { seasonId = "unknown" }))
    assert.are.same({}, Sync.ScopeFor(new_client().ledger, { seasonId = "s1" }))
  end)

  it("sends the finals and their deliveries, and not the grants of a closed season", function()
    local relay = seeded_admin()
    assert.is_true(relay.deliver("PVP_FINAL", {
      seasonId = "s1",
      name = "Season One",
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0 + 900,
      standings = {
        { pos = 1, player = "Bob", points = 20, lastAt = T0 + 20 },
        { pos = 2, player = "Ann", points = 10, lastAt = T0 + 10 },
      },
      prizes = {},
    }, "Boss"))
    assert.is_true(
      relay.deliver(
        "PVP_DELIVERY",
        { seasonId = "s1", player = "Bob", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 2000 },
        "Off"
      )
    )
    local items = Sync.LedgerItems(relay.ledger, { "s1" })
    local seen = {}
    for _, entry in ipairs(items) do
      seen[entry.t] = (seen[entry.t] or 0) + 1
    end
    assert.are.equal(1, seen.PVP_FINAL)
    assert.are.equal(1, seen.PVP_DELIVERY)
    assert.is_nil(seen.PVP_GRANT)
    assert.is_nil(seen.PVP_VOID)

    local fresh = new_client()
    Sync.ApplyItems(fresh.ctx(), items, GLOBAL_RELAY)
    assert.are.equal("Bob", fresh.ledger.finals.s1.standings[1].player)
    assert.is_true(fresh.ledger.deliveries.s1.Bob.delivered)
    assert.are.same(Sync.Summary(relay.ledger, "s1"), Sync.Summary(fresh.ledger, "s1"))
  end)

  it("splits a ledger into pages that each fit and hold a bounded number of items", function()
    local items = {}
    for index = 1, 25 do
      items[index] = { index = index }
    end
    local pages = Sync.Paginate(items, function(page)
      return #page <= 7
    end, 20)
    local total = 0
    for _, page in ipairs(pages) do
      assert.is_true(#page <= 7)
      total = total + #page
    end
    assert.are.equal(25, total)
    assert.are.equal(1, pages[1][1].index)
    assert.are.equal(25, pages[#pages][#pages[#pages]].index)
    -- The cap on items wins when everything would fit.
    assert.are.equal(3, #Sync.Paginate(items, function()
      return true
    end, 10))
    assert.are.same(
      {},
      Sync.Paginate({}, function()
        return true
      end, 10)
    )
  end)

  it("leaves out an item that does not fit a page on its own", function()
    local items = { { size = 1 }, { size = 100 }, { size = 1 } }
    local pages = Sync.Paginate(items, function(page)
      for _, entry in ipairs(page) do
        if entry.size > 10 then
          return false
        end
      end
      return true
    end, 10)
    local total = 0
    for _, page in ipairs(pages) do
      total = total + #page
    end
    assert.are.equal(2, total)
  end)

  it("pages a big ledger through the real codec, each page under the snapshot limit", function()
    local relay = seeded_admin()
    for index = 1, 400 do
      local id = "bulk-" .. index
      relay.deliver("PVP_GRANT", grantRecord(id, "Player" .. (index % 40), 1 + index % 50, T0 + index), "Boss")
    end
    local items = Sync.LedgerItems(relay.ledger, { "s1" })
    assert.is_true(#items > 400)
    local pages = Sync.Paginate(items, fits_one_whisper, Constants.PVP_LEDGER_PAGE_ITEMS)
    local total = 0
    local fresh = new_client()
    for number, page in ipairs(pages) do
      local text = assert(
        codec:Encode(
          Protocol.Build("PVP_LEDGER_DATA", { seasonId = "s1", page = number, pages = #pages, items = page }, "id"),
          Constants.SYNC_MAX_ENCODED_BYTES
        )
      )
      assert.is_true(#text <= Constants.SYNC_MAX_ENCODED_BYTES)
      local decoded = assert(
        codec:Decode(
          text,
          { encoded = Constants.SYNC_MAX_ENCODED_BYTES, decompressed = Constants.SYNC_MAX_DECOMPRESSED_BYTES }
        )
      )
      local message = assert(Protocol.Validate(decoded))
      assert.are.equal("PVP_LEDGER_DATA", message.t)
      assert.is_true(#message.p.items <= Constants.PVP_LEDGER_PAGE_ITEMS)
      total = total + #message.p.items
      Sync.ApplyItems(fresh.ctx(), message.p.items, GLOBAL_RELAY)
    end
    assert.are.equal(#items, total)
    assert.are.same(Sync.Summary(relay.ledger, "s1"), Sync.Summary(fresh.ledger, "s1"))
    assert.are.same(relay.standings(), fresh.standings())
  end)
end)

-- A tiny deterministic shuffle, so a failing order can be reproduced.
local function shuffled(list, seed)
  local state = seed
  local function nextInt(n)
    state = (state * 1103515245 + 12345) % 2147483648
    return state % n + 1
  end
  local out = {}
  for index, value in ipairs(list) do
    out[index] = value
  end
  for index = #out, 2, -1 do
    local other = nextInt(index)
    out[index], out[other] = out[other], out[index]
  end
  return out
end

local function deliverAll(client, records)
  for _, record in ipairs(records) do
    client.deliver(record.t, record.p, record.by)
  end
end

-- The catch-up exchange of the plan: `to` asks, `from` answers if its ledger differs, in pages through the codec.
local function catchUp(from, to)
  local request = Sync.RequestPayload(to.ledger, to.ledger.activeId)
  if not Sync.Differs(from.ledger, request) then
    return false
  end
  local items = Sync.LedgerItems(from.ledger, Sync.ScopeFor(from.ledger, request))
  for _, page in ipairs(Sync.Paginate(items, fits_one_whisper, Constants.PVP_LEDGER_PAGE_ITEMS)) do
    Sync.ApplyItems(to.ctx(), page, GLOBAL_RELAY)
  end
  return true
end

local function progressRecord(change)
  return copy({ seasonId = "s1", rows = { { missionId = "m1", count = 1, goal = 2 } } }, change)
end

describe("PvPSeasonSync progress summaries", function()
  local client

  before_each(function()
    client = new_client().setup()
  end)

  it("keeps the last summary of a member, for an approver", function()
    assert.is_true(client.deliver("PVP_PROGRESS", progressRecord(), "Ann"))
    local held = client.ledger.progress.Ann
    assert.are.equal("s1", held.seasonId)
    assert.are.same({ { missionId = "m1", count = 1, goal = 2 } }, held.rows)
    assert.are.equal(client.clock, held.at)
    -- the next summary replaces it, an empty one clears it
    assert.is_true(
      client.deliver("PVP_PROGRESS", progressRecord({ rows = { { missionId = "m1", count = 2, goal = 2 } } }), "Ann")
    )
    assert.are.equal(2, client.ledger.progress.Ann.rows[1].count)
    assert.is_true(client.deliver("PVP_PROGRESS", progressRecord({ rows = {} }), "Ann"))
    assert.are.same({}, client.ledger.progress.Ann.rows)
  end)

  it("is ignored by a client that does not approve claims", function()
    local member = new_client({ approver = false }).setup()
    local ok, reason = member.deliver("PVP_PROGRESS", progressRecord(), "Ann")
    assert.is_false(ok)
    assert.are.equal("not_approver", reason)
    assert.is_nil(member.ledger.progress.Ann)
  end)

  it("needs a known sender, the active season and drops the rows of unknown missions", function()
    local ok, reason = client.deliver("PVP_PROGRESS", progressRecord(), "Stranger")
    assert.are.same({ false, "unknown_sender" }, { ok, reason })
    ok, reason = client.deliver("PVP_PROGRESS", progressRecord({ seasonId = "s9" }), "Ann")
    assert.are.same({ false, "unknown_season" }, { ok, reason })
    assert.is_true(client.deliver(
      "PVP_PROGRESS",
      progressRecord({
        rows = { { missionId = "m1", count = 1, goal = 2 }, { missionId = "ghost", count = 1, goal = 2 } },
      }),
      "Ann"
    ))
    assert.are.equal(1, #client.ledger.progress.Ann.rows)
    assert.is_true(
      client.deliver("PVP_SEASON", seasonRecord({ state = "closed", rev = 2, updatedAt = T0 + 1 }), "Boss")
    )
    ok, reason = client.deliver("PVP_PROGRESS", progressRecord(), "Bob")
    assert.are.same({ false, "closed" }, { ok, reason })
  end)

  it("limits how many members it keeps", function()
    local old = Constants.PVP_PROGRESS_MEMBERS_MAX
    Constants.PVP_PROGRESS_MEMBERS_MAX = 1
    assert.is_true(client.deliver("PVP_PROGRESS", progressRecord(), "Ann"))
    local ok, reason = client.deliver("PVP_PROGRESS", progressRecord(), "Bob")
    -- a member already held can still update
    local again = client.deliver("PVP_PROGRESS", progressRecord(), "Ann")
    Constants.PVP_PROGRESS_MEMBERS_MAX = old
    assert.are.same({ false, "limit" }, { ok, reason })
    assert.is_true(again)
  end)

  it("is forgotten when the season closes", function()
    assert.is_true(client.deliver("PVP_PROGRESS", progressRecord(), "Ann"))
    assert.is_true(client.deliver("PVP_FINAL", {
      seasonId = "s1",
      name = "Season One",
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0 + 500,
      standings = {},
      prizes = {},
    }, "Boss"))
    assert.is_nil(client.ledger.progress.Ann)
  end)

  it("is validated on the wire: a count past the goal, repeated missions and bad ids are refused", function()
    for _, record in ipairs({
      progressRecord({ rows = { { missionId = "m1", count = 3, goal = 2 } } }),
      progressRecord({
        rows = { { missionId = "m1", count = 1, goal = 2 }, { missionId = "m1", count = 1, goal = 2 } },
      }),
      progressRecord({ rows = { { missionId = "a b", count = 1, goal = 2 } } }),
      progressRecord({ rows = { { missionId = "m1", count = -1, goal = 2 } } }),
      progressRecord({ rows = { { missionId = "m1", count = 0, goal = 0 } } }),
      progressRecord({ rows = "x" }),
      progressRecord({ seasonId = "" }),
    }) do
      local message, reason = Protocol.Validate(Protocol.Build("PVP_PROGRESS", record, "id-1"))
      assert.is_nil(message)
      assert.are.equal("bad_payload", reason)
    end
    local too_many = {}
    for index = 1, Constants.PVP_MISSIONS_MAX + 1 do
      too_many[index] = { missionId = "m" .. index, count = 0, goal = 1 }
    end
    assert.is_nil((Protocol.Validate(Protocol.Build("PVP_PROGRESS", progressRecord({ rows = too_many }), "id-1"))))
  end)

  it("never travels in a ledger catch-up", function()
    local fresh = new_client().setup()
    local summary =
      Sync.ApplyItems(fresh.ctx(), { { t = "PVP_PROGRESS", p = progressRecord(), by = "Ann" } }, GLOBAL_RELAY)
    assert.are.equal(0, summary.applied)
    assert.is_nil(fresh.ledger.progress.Ann)
  end)
end)

describe("PvPSeasonSync claim queue in the ledger catch-up", function()
  local relay

  before_each(function()
    relay = new_client().setup()
    assert.is_true(relay.deliver("PVP_CLAIM", claimRecord("Ann", 1), "Ann"))
    assert.is_true(relay.deliver("PVP_CLAIM", claimRecord("Bob", 1), "Bob"))
    assert.is_true(relay.deliver("PVP_CLAIM", claimRecord("Cat", 1), "Cat"))
    -- Bob's was approved and Cat's rejected: only Ann's is still waiting
    assert.is_true(relay.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 10), "Boss"))
    assert.is_true(
      relay.deliver("PVP_REJECT", { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 300 }, "Boss")
    )
  end)

  it("compares the queue only when the requester approves claims", function()
    local other = new_client().setup()
    other.deliver("PVP_GRANT", grantRecord("Bob:m1:20261020:1", "Bob", 10), "Boss")
    other.deliver("PVP_REJECT", { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 300 }, "Boss")
    assert.is_false(Sync.Differs(relay.ledger, Sync.RequestPayload(other.ledger, "s1")))
    local asking = Sync.RequestPayload(other.ledger, "s1", true)
    assert.is_true(asking.queue)
    assert.is_true(Sync.Differs(relay.ledger, asking))
    assert.is_nil(Sync.RequestPayload(other.ledger, "s1").queue)
  end)

  it("sends the claims still waiting, last, and a requester that approves queues them", function()
    local items = Sync.LedgerItems(relay.ledger, { "s1" }, true)
    local claims = {}
    for index, entry in ipairs(items) do
      if entry.t == "PVP_CLAIM" then
        claims[#claims + 1] = entry
        assert.are.equal(#items, index)
      end
    end
    assert.are.equal(1, #claims)
    assert.are.equal("Ann", claims[1].by)
    assert.are.equal("Ann:m1:20261020:1", claims[1].p.id)
    for _, entry in ipairs(Sync.LedgerItems(relay.ledger, { "s1" })) do
      assert.are_not.equal("PVP_CLAIM", entry.t)
    end

    local requester = new_client()
    local summary = Sync.ApplyItems(requester.ctx(), items, GLOBAL_RELAY)
    assert.are.equal(#items, summary.applied)
    assert.is_truthy(requester.ledger.queue["Ann:m1:20261020:1"])
    assert.is_false(Sync.Differs(relay.ledger, Sync.RequestPayload(requester.ledger, "s1", true)))
  end)

  it("does not queue a claim for a client that does not approve, or from a relay that is not a gm or cogm", function()
    local items = Sync.LedgerItems(relay.ledger, { "s1" }, true)
    local member = new_client({ approver = false })
    Sync.ApplyItems(member.ctx(), items, GLOBAL_RELAY)
    assert.is_nil(next(member.ledger.queue))
    local officer = new_client()
    Sync.ApplyItems(officer.ctx(), items, { sender = "Rl", global = false })
    assert.is_nil(next(officer.ledger.queue))
  end)

  it("leaves a claim out when the claim of the season already closed", function()
    assert.is_true(relay.deliver("PVP_FINAL", {
      seasonId = "s1",
      name = "Season One",
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0 + 500,
      standings = {},
      prizes = {},
    }, "Boss"))
    for _, entry in ipairs(Sync.LedgerItems(relay.ledger, { "s1" }, true)) do
      assert.are_not.equal("PVP_CLAIM", entry.t)
    end
  end)
end)

describe("PvPSeasonSync convergence", function()
  -- Records whose authority does not depend on other records: an admin wrote them all.
  local ADMIN_ONLY = {
    { t = "PVP_SEASON", p = seasonRecord(), by = "Boss" },
    { t = "PVP_MISSION", p = missionRecord(), by = "Boss" },
    { t = "PVP_MISSION", p = missionRecord({ id = "m2", title = "Second" }), by = "Boss" },
    { t = "PVP_OFFICER", p = officerRecord("Off", { { from = T0 } }), by = "Boss" },
    {
      t = "PVP_PRIZES",
      p = { seasonId = "s1", tiers = { ["1"] = { { kind = "gold", amount = 9 } } }, rev = 1, updatedAt = T0 },
      by = "Boss",
    },
    { t = "PVP_GRANT", p = grantRecord("Ann:m1:20261020:1", "Ann", 10, T0 + 10), by = "Boss" },
    { t = "PVP_GRANT", p = grantRecord("Bob:m1:20261020:1", "Bob", 30, T0 + 20), by = "Boss" },
    { t = "PVP_GRANT", p = grantRecord("direct-1", "Ann", 25, T0 + 30), by = "Boss" },
    { t = "PVP_GRANT", p = grantRecord("direct-2", "Cat", 40, T0 + 40), by = "Boss" },
    { t = "PVP_VOID", p = { grantId = "direct-2", seasonId = "s1", at = T0 + 50 }, by = "Boss" },
    { t = "PVP_REJECT", p = { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 60 }, by = "Boss" },
    {
      t = "PVP_REJECT",
      p = { claimId = "Cat:m1:20261020:1", seasonId = "s1", at = T0 + 70, reason = "later" },
      by = "Boss",
    },
    { t = "PVP_GRANT", p = grantRecord("Cat:m1:20261020:1", "Cat", 10, T0 + 80), by = "Boss" },
  }
  -- Records an officer wrote: they need the officer record to have arrived first.
  local WITH_OFFICER = {}
  for _, record in ipairs(ADMIN_ONLY) do
    WITH_OFFICER[#WITH_OFFICER + 1] = record
  end
  WITH_OFFICER[#WITH_OFFICER + 1] =
    { t = "PVP_GRANT", p = grantRecord("Off2:m1:20261020:1", "Off2", 15, T0 + 90), by = "Off" }
  WITH_OFFICER[#WITH_OFFICER + 1] =
    { t = "PVP_REJECT", p = { claimId = "Ann:m1:20261020:2", seasonId = "s1", at = T0 + 95 }, by = "Off" }
  WITH_OFFICER[#WITH_OFFICER + 1] =
    { t = "PVP_GRANT", p = grantRecord("Ann:m1:20261020:2", "Ann", 12, T0 + 99), by = "Off" }

  it("gives the same ledger and the same standings from any delivery order of admin records", function()
    local reference = new_client()
    deliverAll(reference, ADMIN_ONLY)
    local expected = reference.standings()
    assert.is_true(#expected >= 3)
    for seed = 1, 60 do
      local other = new_client()
      deliverAll(other, shuffled(ADMIN_ONLY, seed))
      assert.are.same(expected, other.standings(), "seed " .. seed)
      assert.are.same(Sync.Summary(reference.ledger, "s1"), Sync.Summary(other.ledger, "s1"), "seed " .. seed)
    end
  end)

  it("converges from any delivery order once the missed records are caught up", function()
    local reference = new_client()
    deliverAll(reference, WITH_OFFICER)
    local expected = reference.standings()
    for seed = 1, 60 do
      local other = new_client()
      deliverAll(other, shuffled(WITH_OFFICER, seed))
      -- A record that reached the client before the one that authorises it is refused, and the catch-up brings it.
      catchUp(reference, other)
      catchUp(other, reference)
      assert.are.same(expected, other.standings(), "seed " .. seed)
      assert.are.same(Sync.Summary(reference.ledger, "s1"), Sync.Summary(other.ledger, "s1"), "seed " .. seed)
    end
  end)

  it("converges when each of two clients saw a different half", function()
    local left, right = new_client(), new_client()
    local first, second = {}, {}
    for index, record in ipairs(WITH_OFFICER) do
      if index % 2 == 0 then
        first[#first + 1] = record
      else
        second[#second + 1] = record
      end
    end
    deliverAll(left, first)
    deliverAll(right, second)
    for _ = 1, 3 do
      catchUp(left, right)
      catchUp(right, left)
    end
    assert.are.same(left.standings(), right.standings())
    assert.are.same(Sync.Summary(left.ledger, "s1"), Sync.Summary(right.ledger, "s1"))
    assert.is_true(#left.standings() >= 3)
  end)

  it("converges on the final standing and the deliveries", function()
    local standings = {
      { pos = 1, player = "Bob", points = 30, lastAt = T0 + 20 },
      { pos = 2, player = "Ann", points = 10, lastAt = T0 + 10 },
    }
    local records = {}
    for _, record in ipairs(ADMIN_ONLY) do
      records[#records + 1] = record
    end
    records[#records + 1] = {
      t = "PVP_FINAL",
      p = {
        seasonId = "s1",
        name = "Season One",
        startsAt = SEASON_START,
        endsAt = SEASON_END,
        closedAt = T0 + 900,
        standings = standings,
        prizes = {},
      },
      by = "Boss",
    }
    records[#records + 1] = {
      t = "PVP_DELIVERY",
      p = { seasonId = "s1", player = "Bob", tier = "1", delivered = true, rev = 1, updatedAt = T0 + 1000 },
      by = "Off",
    }
    local reference = new_client()
    deliverAll(reference, records)
    assert.is_true(reference.ledger.deliveries.s1.Bob.delivered)
    for seed = 1, 40 do
      local other = new_client()
      deliverAll(other, shuffled(records, seed))
      catchUp(reference, other)
      assert.are.equal("Bob", other.ledger.finals.s1.standings[1].player, "seed " .. seed)
      assert.is_nil(other.ledger.grants.s1, "seed " .. seed)
      assert.is_true(other.ledger.deliveries.s1.Bob.delivered, "seed " .. seed)
      assert.are.same(Sync.Summary(reference.ledger, "s1"), Sync.Summary(other.ledger, "s1"), "seed " .. seed)
    end
  end)
end)

describe("PvPSeasonSync claim size", function()
  -- Names a client can really produce are far shorter than the limit; this is the worst case the validator allows.
  local function randomName(state, length)
    local letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = {}
    for index = 1, length do
      state.seed = (state.seed * 1103515245 + 12345) % 2147483648
      local pick = state.seed % #letters + 1
      out[index] = letters:sub(pick, pick)
    end
    return table.concat(out)
  end

  it("encodes the largest possible claim under the guild message limit", function()
    local state = { seed = 7 }
    local evidence = {}
    for index = 1, Constants.PVP_CLAIM_EVIDENCE_MAX do
      evidence[index] = {
        at = T0 + 1000 + index * 37,
        victim = randomName(state, Constants.PVP_FEED_VICTIM_MAX),
        mapId = 100000 + index * 977,
        place = index % 2 == 0 and "world" or "bg",
        class = "WARRIOR",
        race = "NIGHTELF",
      }
    end
    local playerName = randomName(state, 64)
    local at = T0 + 100
    local record = claimRecord(playerName, 10, at, {
      evidence = evidence,
      summary = { done = 500, total = 500, classes = 8, classesTotal = 8, races = 4, racesTotal = 4, unknown = 99999 },
      note = randomName(state, Constants.PVP_NOTE_MAX),
    })
    local message = assert(Protocol.Validate(Protocol.Build("PVP_CLAIM", record, "x-1234567-abcdef")))
    assert.are.equal(Constants.PVP_CLAIM_EVIDENCE_MAX, #message.p.evidence)
    local text, reason = codec:Encode(message)
    assert.is_truthy(text, reason)
    assert.is_true(#text <= Constants.MAX_ENCODED_BYTES)
  end)

  it("encodes the largest possible final under the guild message limit once it is trimmed", function()
    local state = { seed = 11 }
    local standings = {}
    for position = 1, Constants.PVP_FINAL_STANDINGS_MAX do
      standings[position] = {
        pos = position,
        player = randomName(state, 12),
        points = 3000000 - position,
        lastAt = T0 + position,
      }
    end
    local final = {
      seasonId = "s1",
      name = randomName(state, Constants.PVP_SEASON_NAME_MAX),
      startsAt = SEASON_START,
      endsAt = SEASON_END,
      closedAt = T0,
      standings = standings,
      prizes = {},
    }
    local function fits(candidate)
      return codec:Encode(Protocol.Build("PVP_FINAL", candidate, "x-1234567-abcdef")) ~= nil
    end
    local trimmed, whole = Model.FitFinal(final, fits)
    assert.is_true(fits(trimmed))
    assert.is_true(#trimmed.standings >= 10)
    -- The cut keeps the best positions.
    assert.are.equal(standings[1].player, trimmed.standings[1].player)
    assert.are.equal(whole, #trimmed.standings == #standings)
    -- The input is not touched.
    assert.are.equal(Constants.PVP_FINAL_STANDINGS_MAX, #final.standings)
  end)
end)
