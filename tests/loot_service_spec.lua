local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Domain/PermissionService", "Domain/LootModel", "Domain/LootService",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Service, Constants = ns.LootService, ns.Constants

local function build_ctx(role, actor)
  local ctx = {
    events = {
      ["ev-1"] = {
        eventId = "ev-1", title = "Molten Core", status = "open", attendance = {}, assignments = {}, loot = {},
      },
    },
    role = role or "council",
    actor = actor or "Boss-Realm",
    clock = 1000,
    locked = false,
  }
  local counter = 0
  ctx.now = function() return ctx.clock end
  ctx.newId = function()
    counter = counter + 1
    return "s" .. counter
  end
  ctx.isLockedDown = function() return ctx.locked end
  return ctx
end

-- Another person acting on the same data.
local function as(ctx, role, actor)
  local other = {}
  for key, value in pairs(ctx) do other[key] = value end
  other.role, other.actor = role, actor
  return other
end

local ITEM = { itemId = 19019, itemName = "Thunderfury" }
local CANDIDATE = { spec = "Fury", need = "main" }

local function open_session(ctx)
  return assert(Service.OpenSession(ctx, "ev-1", ITEM))
end

describe("LootModel", function()
  local Model = ns.LootModel

  it("validates items and drops unknown fields", function()
    assert.are.same(ITEM, Model.ValidateItem({ itemId = 19019, itemName = "Thunderfury", junk = 1 }))
    assert.are.equal("invalid:itemId", select(2, Model.ValidateItem({ itemName = "X" })))
    assert.are.equal("invalid:itemId", select(2, Model.ValidateItem({ itemId = 0, itemName = "X" })))
    assert.are.equal("invalid:itemId", select(2, Model.ValidateItem({ itemId = 1.5, itemName = "X" })))
    assert.are.equal("invalid:itemName", select(2, Model.ValidateItem({ itemId = 1, itemName = "|cffff0000X" })))
    assert.are.equal("invalid:itemName", select(2, Model.ValidateItem({ itemId = 1, itemName = ("n"):rep(61) })))
    assert.are.equal("invalid:fields", select(2, Model.ValidateItem("nope")))
  end)

  it("validates candidate declarations", function()
    assert.are.same({ spec = "Fury", need = "main" }, Model.ValidateCandidate({ spec = "Fury", need = "main" }))
    local declared = Model.ValidateCandidate({ spec = "Fury", need = "off", upgrade = "Better weapon" })
    assert.are.equal("Better weapon", declared.upgrade)
    assert.are.equal("invalid:spec", select(2, Model.ValidateCandidate({ need = "main" })))
    assert.are.equal("invalid:need", select(2, Model.ValidateCandidate({ spec = "Fury", need = "greed" })))
    assert.are.equal("invalid:upgrade", select(2, Model.ValidateCandidate({
      spec = "Fury", need = "main", upgrade = "|Hitem:1|h",
    })))
  end)

  it("accepts only plain text as a reason", function()
    assert.is_true(Model.IsReason("highest need"))
    assert.is_false(Model.IsReason(""))
    assert.is_false(Model.IsReason("|cffff0000red"))
    assert.is_false(Model.IsReason(("r"):rep(101)))
    assert.is_false(Model.IsReason(nil))
  end)
end)

describe("LootService permissions", function()
  it("lets the council and admins open sessions and refuses everyone else", function()
    for _, role in ipairs({ "council", "admin" }) do
      assert.is_truthy(Service.OpenSession(build_ctx(role), "ev-1", ITEM), role)
    end
    for _, role in ipairs({ "member", "rl", "stranger" }) do
      local ctx = build_ctx(role)
      local session, reason = Service.OpenSession(ctx, "ev-1", ITEM)
      assert.is_nil(session)
      assert.are.equal("forbidden", reason)
      assert.is_nil(next(ctx.events["ev-1"].loot))
    end
    local ctx = build_ctx()
    ctx.role = nil
    assert.are.equal("forbidden", select(2, Service.OpenSession(ctx, "ev-1", ITEM)))
  end)

  it("lets every role register, but only the council and admins vote or award", function()
    local council = build_ctx("council")
    local session = open_session(council)
    for _, role in ipairs({ "member", "rl", "council", "admin" }) do
      local ctx = as(council, role, role .. "-Realm")
      assert.is_truthy(Service.Register(ctx, "ev-1", session.sessionId, CANDIDATE), role)
    end
    for _, role in ipairs({ "member", "rl" }) do
      local ctx = as(council, role, role .. "-Realm")
      assert.are.equal("forbidden", select(2, Service.Vote(ctx, "ev-1", session.sessionId, "member-Realm")))
      assert.are.equal("forbidden", select(2, Service.Award(ctx, "ev-1", session.sessionId, "member-Realm", "no")))
      assert.are.equal("forbidden", select(2, Service.Close(ctx, "ev-1", session.sessionId)))
    end
    assert.is_nil(next(session.votes))
    assert.are.equal("open", session.status)
  end)
end)

describe("LootService.OpenSession", function()
  it("creates an open, stamped session for the item", function()
    local ctx = build_ctx()
    local session = open_session(ctx)
    assert.are.equal("s1", session.sessionId)
    assert.are.equal(19019, session.itemId)
    assert.are.equal("Thunderfury", session.itemName)
    assert.are.equal("open", session.status)
    assert.are.equal(1, session.rev)
    assert.are.equal("Boss-Realm", session.updatedBy)
    assert.are.equal("declared", session.source)
    assert.are.same({}, session.candidates)
    assert.are.equal(session, ctx.events["ev-1"].loot["s1"])
  end)

  it("refuses to open a session during a lockdown", function()
    local ctx = build_ctx()
    ctx.locked = true
    local session, reason = Service.OpenSession(ctx, "ev-1", ITEM)
    assert.is_nil(session)
    assert.are.equal("locked_down", reason)
    assert.is_nil(next(ctx.events["ev-1"].loot))
  end)

  it("reports a missing event and invalid items", function()
    local ctx = build_ctx()
    assert.are.equal("not_found", select(2, Service.OpenSession(ctx, "nope", ITEM)))
    assert.are.equal("invalid:itemId", select(2, Service.OpenSession(ctx, "ev-1", { itemName = "X" })))
    assert.is_nil(next(ctx.events["ev-1"].loot))
  end)

  it("stops at the session limit", function()
    local ctx = build_ctx()
    for i = 1, Constants.LOOT_SESSIONS_MAX do ctx.events["ev-1"].loot["x" .. i] = { status = "closed" } end
    assert.are.equal("limit", select(2, Service.OpenSession(ctx, "ev-1", ITEM)))
  end)

  it("works on an event saved before loot existed", function()
    local ctx = build_ctx()
    ctx.events["ev-1"].loot = nil
    assert.is_truthy(Service.OpenSession(ctx, "ev-1", ITEM))
  end)
end)

describe("LootService.Register", function()
  local council, session

  before_each(function()
    council = build_ctx("council")
    session = open_session(council)
  end)

  it("registers the actor, and only the actor, as a candidate", function()
    local member = as(council, "member", "Ann-Realm")
    local candidate = assert(Service.Register(member, "ev-1", session.sessionId, {
      spec = "Fury", need = "main", upgrade = "Replaces my 60 axe", extra = "ignored",
    }))
    assert.are.equal("Fury", candidate.spec)
    assert.are.equal("main", candidate.need)
    assert.are.equal("Replaces my 60 axe", candidate.upgrade)
    assert.are.equal("Ann-Realm", candidate.updatedBy)
    assert.is_nil(candidate.extra)
    assert.are.equal(candidate, session.candidates["Ann-Realm"])
  end)

  it("updates an existing declaration and bumps its revision", function()
    local member = as(council, "member", "Ann-Realm")
    Service.Register(member, "ev-1", session.sessionId, CANDIDATE)
    Service.Register(member, "ev-1", session.sessionId, { spec = "Arms", need = "off" })
    assert.are.equal("Arms", session.candidates["Ann-Realm"].spec)
    assert.are.equal(2, session.candidates["Ann-Realm"].rev)
    assert.is_nil(session.candidates["Ann-Realm"].upgrade)
  end)

  it("rejects invalid declarations and unusable sessions", function()
    local member = as(council, "member", "Ann-Realm")
    assert.are.equal("invalid:spec", select(2, Service.Register(member, "ev-1", session.sessionId, { need = "main" })))
    assert.are.equal("invalid:need", select(2, Service.Register(member, "ev-1", session.sessionId, {
      spec = "Fury", need = "greed",
    })))
    assert.are.equal("not_found", select(2, Service.Register(member, "ev-1", "nope", CANDIDATE)))
    assert.are.equal("not_found", select(2, Service.Register(member, "nope", session.sessionId, CANDIDATE)))
    assert.is_nil(next(session.candidates))

    Service.Close(council, "ev-1", session.sessionId)
    assert.are.equal("closed", select(2, Service.Register(member, "ev-1", session.sessionId, CANDIDATE)))
  end)

  it("stops at the candidate limit but still lets existing candidates update", function()
    for i = 1, Constants.LOOT_CANDIDATES_MAX do
      session.candidates["P" .. i .. "-Realm"] = { spec = "X", need = "main", rev = 1 }
    end
    local newcomer = as(council, "member", "New-Realm")
    assert.are.equal("limit", select(2, Service.Register(newcomer, "ev-1", session.sessionId, CANDIDATE)))
    local existing = as(council, "member", "P1-Realm")
    assert.is_truthy(Service.Register(existing, "ev-1", session.sessionId, CANDIDATE))
  end)
end)

describe("LootService.Vote", function()
  local council, session

  before_each(function()
    council = build_ctx("council", "Boss-Realm")
    session = open_session(council)
    Service.Register(as(council, "member", "Ann-Realm"), "ev-1", session.sessionId, CANDIDATE)
    Service.Register(as(council, "member", "Bob-Realm"), "ev-1", session.sessionId, CANDIDATE)
  end)

  it("records one vote per voter and lets them change it", function()
    local vote = assert(Service.Vote(council, "ev-1", session.sessionId, "Ann-Realm"))
    assert.are.equal("Ann-Realm", vote.target)
    assert.are.equal(1, vote.rev)

    Service.Vote(council, "ev-1", session.sessionId, "Bob-Realm")
    assert.are.equal("Bob-Realm", session.votes["Boss-Realm"].target)
    assert.are.equal(2, session.votes["Boss-Realm"].rev)
    assert.are.equal(1, next(session.votes) and 1 or 0)
  end)

  it("only accepts votes for registered candidates", function()
    assert.are.equal("not_candidate", select(2, Service.Vote(council, "ev-1", session.sessionId, "Nobody-Realm")))
    assert.are.equal("not_candidate", select(2, Service.Vote(council, "ev-1", session.sessionId, nil)))
    assert.is_nil(next(session.votes))
  end)

  it("refuses votes on a closed or missing session", function()
    Service.Close(council, "ev-1", session.sessionId)
    assert.are.equal("closed", select(2, Service.Vote(council, "ev-1", session.sessionId, "Ann-Realm")))
    assert.are.equal("not_found", select(2, Service.Vote(council, "ev-1", "nope", "Ann-Realm")))
  end)

  it("stops at the vote limit but still lets a voter change theirs", function()
    for i = 1, Constants.LOOT_VOTES_MAX do session.votes["V" .. i .. "-Realm"] = { target = "Ann-Realm", rev = 1 } end
    assert.are.equal("limit", select(2, Service.Vote(council, "ev-1", session.sessionId, "Ann-Realm")))
    local existing = as(council, "council", "V1-Realm")
    assert.is_truthy(Service.Vote(existing, "ev-1", session.sessionId, "Bob-Realm"))
  end)
end)

describe("LootService.Award and Close", function()
  local council, session

  before_each(function()
    council = build_ctx("council", "Boss-Realm")
    session = open_session(council)
    Service.Register(as(council, "member", "Ann-Realm"), "ev-1", session.sessionId, CANDIDATE)
  end)

  it("awards to a candidate, records why and by whom, and closes the session", function()
    council.clock = 2000
    local awarded = assert(Service.Award(council, "ev-1", session.sessionId, "Ann-Realm", "Highest need"))
    assert.are.equal("closed", awarded.status)
    assert.are.same(
      { characterKey = "Ann-Realm", reason = "Highest need", awardedBy = "Boss-Realm", at = 2000 },
      awarded.award)
    assert.is_true(awarded.rev > 1)
  end)

  it("needs a candidate and a plain-text reason, and changes nothing otherwise", function()
    local id = session.sessionId
    assert.are.equal("not_candidate", select(2, Service.Award(council, "ev-1", id, "Nobody-Realm", "why")))
    assert.are.equal("invalid:reason", select(2, Service.Award(council, "ev-1", id, "Ann-Realm", "")))
    assert.are.equal("invalid:reason", select(2, Service.Award(council, "ev-1", id, "Ann-Realm", "|cffff0000x")))
    assert.are.equal("open", session.status)
    assert.is_nil(session.award)
  end)

  it("cannot be awarded twice, and a closed session accepts nothing more", function()
    Service.Award(council, "ev-1", session.sessionId, "Ann-Realm", "First")
    assert.are.equal("closed", select(2, Service.Award(council, "ev-1", session.sessionId, "Ann-Realm", "Second")))
    assert.are.equal("closed", select(2, Service.Close(council, "ev-1", session.sessionId)))
    assert.are.equal("First", session.award.reason)
  end)

  it("can close a session without awarding anything", function()
    local closed = assert(Service.Close(council, "ev-1", session.sessionId))
    assert.are.equal("closed", closed.status)
    assert.is_nil(closed.award)
  end)
end)

describe("LootService.Tally", function()
  local function session_with(votes, status)
    local session = { status = status or "open", votes = {} }
    for voter, target in pairs(votes) do session.votes[voter] = { target = target } end
    return session
  end

  local votes = {
    ["C1-Realm"] = "Bob-Realm", ["C2-Realm"] = "Ann-Realm", ["C3-Realm"] = "Bob-Realm", ["C4-Realm"] = "Cid-Realm",
  }

  it("counts votes, most first, ties by name, with voters while the policy is open", function()
    local tally = Service.Tally(session_with(votes))
    assert.are.equal("Bob-Realm", tally[1].characterKey)
    assert.are.equal(2, tally[1].count)
    assert.are.same({ "C1-Realm", "C3-Realm" }, tally[1].voters)
    assert.are.equal("Ann-Realm", tally[2].characterKey)
    assert.are.equal("Cid-Realm", tally[3].characterKey)
  end)

  it("hides who voted for whom while open under a secret policy, but not after closing", function()
    local saved = Constants.VOTE_VISIBILITY
    Constants.VOTE_VISIBILITY = "secret"
    local open = Service.Tally(session_with(votes, "open"))
    local closed = Service.Tally(session_with(votes, "closed"))
    Constants.VOTE_VISIBILITY = saved

    assert.are.equal(2, open[1].count)
    assert.is_nil(open[1].voters)
    assert.are.same({ "C1-Realm", "C3-Realm" }, closed[1].voters)
  end)

  it("returns nothing for a session without votes", function()
    assert.are.same({}, Service.Tally(session_with({})))
  end)
end)

describe("LootService.Acta", function()
  it("lists closed sessions oldest first with the decision, the reason and the votes", function()
    local council = build_ctx("council", "Boss-Realm")
    local first = open_session(council)
    Service.Register(as(council, "member", "Ann-Realm"), "ev-1", first.sessionId, CANDIDATE)
    Service.Vote(council, "ev-1", first.sessionId, "Ann-Realm")
    council.clock = 1100
    Service.Award(council, "ev-1", first.sessionId, "Ann-Realm", "Highest need")

    council.clock = 1200
    local second = assert(Service.OpenSession(council, "ev-1", { itemId = 1, itemName = "Junk" }))
    council.clock = 1300
    Service.Close(council, "ev-1", second.sessionId)

    council.clock = 1400
    open_session(council)

    local acta = Service.Acta(council.events["ev-1"])
    assert.are.equal(2, #acta)
    assert.are.equal("Thunderfury", acta[1].itemName)
    assert.are.equal("Ann-Realm", acta[1].awardedTo)
    assert.are.equal("Highest need", acta[1].reason)
    assert.are.equal("Boss-Realm", acta[1].awardedBy)
    assert.are.equal(1, acta[1].votes[1].count)
    assert.are.same({ "Boss-Realm" }, acta[1].votes[1].voters)
    assert.are.equal("Junk", acta[2].itemName)
    assert.is_nil(acta[2].awardedTo)
  end)

  it("is empty for an event without loot", function()
    assert.are.same({}, Service.Acta({}))
    assert.are.same({}, Service.Acta({ loot = {} }))
  end)
end)
