local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/LootModel",
    "Domain/LootService",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local EventSync, LootSync, LootService, Protocol, Constants =
  ns.EventSync, ns.LootSync, ns.LootService, ns.Protocol, ns.Constants

local ITEM = { itemId = 19019, itemName = "Thunderfury" }
local CANDIDATE = { spec = "Fury", need = "main" }

-- One simulated client with a single raid event.
local function client(name)
  local c = { name = name, clock = 10000, counter = 0 }
  c.events = {
    ["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = {},
      loot = {},
    },
  }
  function c.apply_ctx()
    return {
      events = c.events,
      tombstones = {},
      -- Everybody is in roster r1 unless a test says otherwise.
      rosterOf = c.rosterOf or function()
        return "r1"
      end,
      now = function()
        return c.clock
      end,
    }
  end
  function c.local_ctx(role, actor)
    return {
      events = c.events,
      role = role,
      actor = actor or name,
      rosterId = "r1",
      now = function()
        return c.clock
      end,
      newId = function()
        c.counter = c.counter + 1
        return name .. "-" .. c.counter
      end,
      isLockedDown = function()
        return false
      end,
    }
  end
  return c
end

-- The message as the receiver would see it after the protocol validation.
local function on_wire(messageType, payload)
  return assert(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")))
end

local function deliver(receiver, messageType, payload, sender, role)
  return EventSync.Apply(receiver.apply_ctx(), on_wire(messageType, payload), sender, role)
end

local function session_of(receiver, sessionId)
  return receiver.events["ev-1"].loot[sessionId]
end

-- An open session on `origin`, already announced to `receiver`.
local function open_and_announce(origin, receiver)
  local session = assert(LootService.OpenSession(origin.local_ctx("officer", "Boss-Realm"), "ev-1", ITEM))
  assert(deliver(receiver, "LOOT_SESSION", LootSync.SessionPayload("ev-1", session), "Boss-Realm", "officer"))
  return session
end

local function register(origin, receiver, sessionId, actor)
  local candidate = assert(LootService.Register(origin.local_ctx("roster", actor), "ev-1", sessionId, CANDIDATE))
  assert(deliver(receiver, "LOOT_CANDIDATE", LootSync.CandidatePayload("ev-1", sessionId, candidate), actor, "roster"))
  return candidate
end

describe("LootSync LOOT_SESSION", function()
  it("creates the session on the receiver, authored by the sender", function()
    local origin, receiver = client("Origin"), client("Receiver")
    local session = open_and_announce(origin, receiver)

    local stored = session_of(receiver, session.sessionId)
    assert.are.equal(19019, stored.itemId)
    assert.are.equal("Thunderfury", stored.itemName)
    assert.are.equal("open", stored.status)
    assert.are.equal("Boss-Realm", stored.updatedBy)
    assert.are.equal("received", stored.source)
    assert.are.same({}, stored.candidates)
    assert.are.same({}, stored.votes)
  end)

  it("refuses anyone who cannot open sessions, unknown senders and unknown events", function()
    local origin, receiver = client("Origin"), client("Receiver")
    local session = assert(LootService.OpenSession(origin.local_ctx("officer"), "ev-1", ITEM))
    local payload = LootSync.SessionPayload("ev-1", session)

    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.are.equal("forbidden", select(2, deliver(receiver, "LOOT_SESSION", payload, "X-Realm", role)))
    end
    assert.are.equal("unknown_sender", select(2, deliver(receiver, "LOOT_SESSION", payload, "X-Realm", nil)))

    payload.eventId = "nope"
    assert.are.equal("unknown_event", select(2, deliver(receiver, "LOOT_SESSION", payload, "Boss-Realm", "officer")))
    assert.is_nil(next(receiver.events["ev-1"].loot))
  end)

  it("ignores an older revision and lets a newer one replace the session", function()
    local origin, receiver = client("Origin"), client("Receiver")
    local session = open_and_announce(origin, receiver)
    local first = LootSync.SessionPayload("ev-1", session)

    LootService.Close(origin.local_ctx("officer", "Boss-Realm"), "ev-1", session.sessionId)
    assert.is_true(deliver(receiver, "LOOT_SESSION", LootSync.SessionPayload("ev-1", session), "Boss-Realm", "officer"))
    assert.are.equal("closed", session_of(receiver, session.sessionId).status)

    assert.are.equal("stale", select(2, deliver(receiver, "LOOT_SESSION", first, "Boss-Realm", "officer")))
    assert.are.equal("closed", session_of(receiver, session.sessionId).status)
  end)

  it("stops at the session limit", function()
    local origin, receiver = client("Origin"), client("Receiver")
    local session = assert(LootService.OpenSession(origin.local_ctx("officer"), "ev-1", ITEM))
    for i = 1, Constants.LOOT_SESSIONS_MAX do
      receiver.events["ev-1"].loot["x" .. i] = { status = "closed", rev = 1 }
    end
    local payload = LootSync.SessionPayload("ev-1", session)
    local ok, reason = deliver(receiver, "LOOT_SESSION", payload, "Boss-Realm", "officer")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)

  it("clamps a timestamp dated far in the future", function()
    local receiver = client("Receiver")
    local payload = {
      eventId = "ev-1",
      sessionId = "s-1",
      rev = 1,
      updatedAt = 4000000000,
      itemId = 1,
      itemName = "X",
      status = "open",
    }
    assert.is_true(deliver(receiver, "LOOT_SESSION", payload, "Boss-Realm", "officer"))
    assert.are.equal(receiver.clock + 300, session_of(receiver, "s-1").updatedAt)
  end)
end)

describe("LootSync LOOT_CANDIDATE", function()
  local origin, receiver, session

  before_each(function()
    origin, receiver = client("Origin"), client("Receiver")
    session = open_and_announce(origin, receiver)
  end)

  it("registers the sender, and only the sender, whatever the payload says", function()
    local candidate = assert(LootService.Register(origin.local_ctx("roster", "Ann-Realm"), "ev-1", session.sessionId, {
      spec = "Fury",
      need = "main",
      upgrade = "Replaces my axe",
    }))
    local payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)
    payload.characterKey, payload.candidate = "Fake-Realm", "Fake-Realm"

    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", payload, "Ann-Realm", "roster"))
    local candidates = session_of(receiver, session.sessionId).candidates
    assert.is_nil(candidates["Fake-Realm"])
    assert.are.equal("Fury", candidates["Ann-Realm"].spec)
    assert.are.equal("main", candidates["Ann-Realm"].need)
    assert.are.equal("Replaces my axe", candidates["Ann-Realm"].upgrade)
    assert.are.equal("Ann-Realm", candidates["Ann-Realm"].updatedBy)
    assert.are.equal("received", candidates["Ann-Realm"].source)
  end)

  it("refuses a member and an alter: loot_apply starts at roster", function()
    local candidate =
      LootService.Register(origin.local_ctx("roster", "Ann-Realm"), "ev-1", session.sessionId, CANDIDATE)
    local payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)
    for _, role in ipairs({ "member", "alter" }) do
      assert.are.equal("forbidden", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "Ann-Realm", role)), role)
    end
    assert.is_nil(next(session_of(receiver, session.sessionId).candidates))
  end)

  it("accepts every known role from roster up and refuses a sender the roster does not know", function()
    for _, role in ipairs({ "roster", "rl", "officer", "cogm", "gm" }) do
      local actor = role .. "-Realm"
      local candidate = LootService.Register(origin.local_ctx(role, actor), "ev-1", session.sessionId, CANDIDATE)
      local payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)
      assert.is_true(deliver(receiver, "LOOT_CANDIDATE", payload, actor, role), role)
    end
    local stranger = origin.local_ctx("roster", "Stranger-Realm")
    local candidate = LootService.Register(stranger, "ev-1", session.sessionId, CANDIDATE)
    local payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)
    assert.are.equal("unknown_sender", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "Stranger-Realm", nil)))
  end)

  it("needs a known, open session", function()
    local ann = origin.local_ctx("roster", "Ann-Realm")
    local candidate = LootService.Register(ann, "ev-1", session.sessionId, CANDIDATE)
    local payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)

    payload.sessionId = "nope"
    assert.are.equal("unknown_session", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "Ann-Realm", "roster")))
    payload.eventId = "nope"
    assert.are.equal("unknown_event", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "Ann-Realm", "roster")))

    session_of(receiver, session.sessionId).status = "closed"
    payload = LootSync.CandidatePayload("ev-1", session.sessionId, candidate)
    assert.are.equal("closed", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "Ann-Realm", "roster")))
  end)

  it("keeps the newest declaration of a candidate", function()
    local ctx = origin.local_ctx("roster", "Ann-Realm")
    local first = LootSync.CandidatePayload(
      "ev-1",
      session.sessionId,
      LootService.Register(ctx, "ev-1", session.sessionId, CANDIDATE)
    )
    local first_copy = {}
    for k, v in pairs(first) do
      first_copy[k] = v
    end
    local second = LootSync.CandidatePayload(
      "ev-1",
      session.sessionId,
      LootService.Register(ctx, "ev-1", session.sessionId, { spec = "Arms", need = "off" })
    )

    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", second, "Ann-Realm", "roster"))
    assert.are.equal("stale", select(2, deliver(receiver, "LOOT_CANDIDATE", first_copy, "Ann-Realm", "roster")))
    assert.are.equal("Arms", session_of(receiver, session.sessionId).candidates["Ann-Realm"].spec)
  end)

  it("stops at the candidate limit but still updates an existing candidate", function()
    local candidates = session_of(receiver, session.sessionId).candidates
    for i = 1, Constants.LOOT_CANDIDATES_MAX do
      candidates["P" .. i .. "-Realm"] = { spec = "X", need = "main", rev = 1 }
    end

    local newcomer = LootService.Register(origin.local_ctx("roster", "New-Realm"), "ev-1", session.sessionId, CANDIDATE)
    local payload = LootSync.CandidatePayload("ev-1", session.sessionId, newcomer)
    assert.are.equal("limit", select(2, deliver(receiver, "LOOT_CANDIDATE", payload, "New-Realm", "roster")))

    local existing = LootService.Register(origin.local_ctx("roster", "P1-Realm"), "ev-1", session.sessionId, CANDIDATE)
    payload = LootSync.CandidatePayload("ev-1", session.sessionId, existing)
    payload.rev = 5
    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", payload, "P1-Realm", "roster"))
  end)
end)

describe("LootSync LOOT_VOTE", function()
  local origin, receiver, session

  local function vote(actor, target)
    local record = assert(LootService.Vote(origin.local_ctx("officer", actor), "ev-1", session.sessionId, target))
    return LootSync.VotePayload("ev-1", session.sessionId, record)
  end

  before_each(function()
    origin, receiver = client("Origin"), client("Receiver")
    session = open_and_announce(origin, receiver)
    register(origin, receiver, session.sessionId, "Ann-Realm")
    register(origin, receiver, session.sessionId, "Bob-Realm")
  end)

  it("records the vote under the sender, whatever the payload says", function()
    local payload = vote("Boss-Realm", "Ann-Realm")
    payload.voter = "Fake-Realm"
    assert.is_true(deliver(receiver, "LOOT_VOTE", payload, "Boss-Realm", "officer"))
    local votes = session_of(receiver, session.sessionId).votes
    assert.is_nil(votes["Fake-Realm"])
    assert.are.equal("Ann-Realm", votes["Boss-Realm"].target)
    assert.are.equal("Boss-Realm", votes["Boss-Realm"].updatedBy)
  end)

  it("refuses members and unknown senders", function()
    local payload = vote("Boss-Realm", "Ann-Realm")
    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.are.equal("forbidden", select(2, deliver(receiver, "LOOT_VOTE", payload, "X-Realm", role)))
    end
    assert.are.equal("unknown_sender", select(2, deliver(receiver, "LOOT_VOTE", payload, "X-Realm", nil)))
    assert.is_nil(next(session_of(receiver, session.sessionId).votes))
  end)

  it("only accepts votes for known candidates in an open session", function()
    local payload = vote("Boss-Realm", "Ann-Realm")
    payload.target = "Nobody-Realm"
    assert.are.equal("not_candidate", select(2, deliver(receiver, "LOOT_VOTE", payload, "Boss-Realm", "officer")))

    payload.target = "Ann-Realm"
    session_of(receiver, session.sessionId).status = "closed"
    assert.are.equal("closed", select(2, deliver(receiver, "LOOT_VOTE", payload, "Boss-Realm", "officer")))
    payload.sessionId = "nope"
    assert.are.equal("unknown_session", select(2, deliver(receiver, "LOOT_VOTE", payload, "Boss-Realm", "officer")))
  end)

  it("keeps a voter's newest choice", function()
    local first = vote("Boss-Realm", "Ann-Realm")
    local first_copy = {}
    for k, v in pairs(first) do
      first_copy[k] = v
    end
    local second = vote("Boss-Realm", "Bob-Realm")

    assert.is_true(deliver(receiver, "LOOT_VOTE", second, "Boss-Realm", "officer"))
    assert.are.equal("stale", select(2, deliver(receiver, "LOOT_VOTE", first_copy, "Boss-Realm", "officer")))
    assert.are.equal("Bob-Realm", session_of(receiver, session.sessionId).votes["Boss-Realm"].target)
  end)

  it("stops at the vote limit but still lets a voter change theirs", function()
    local votes = session_of(receiver, session.sessionId).votes
    for i = 1, Constants.LOOT_VOTES_MAX do
      votes["V" .. i .. "-Realm"] = { target = "Ann-Realm", rev = 1 }
    end

    local payload = vote("Boss-Realm", "Ann-Realm")
    assert.are.equal("limit", select(2, deliver(receiver, "LOOT_VOTE", payload, "Boss-Realm", "officer")))
    payload.rev = 4
    assert.is_true(deliver(receiver, "LOOT_VOTE", payload, "V1-Realm", "officer"))
  end)
end)

describe("LootSync LOOT_AWARD", function()
  local origin, receiver, session

  local function award(target, reason)
    local council = origin.local_ctx("officer", "Boss-Realm")
    local awarded = assert(LootService.Award(council, "ev-1", session.sessionId, target, reason))
    return LootSync.AwardPayload("ev-1", awarded)
  end

  before_each(function()
    origin, receiver = client("Origin"), client("Receiver")
    session = open_and_announce(origin, receiver)
    register(origin, receiver, session.sessionId, "Ann-Realm")
  end)

  it("closes the session with the decision, the reason and the sender as who awarded it", function()
    local payload = award("Ann-Realm", "Highest need")
    payload.awardedBy = "Fake-Realm"
    assert.is_true(deliver(receiver, "LOOT_AWARD", payload, "Boss-Realm", "officer"))

    local stored = session_of(receiver, session.sessionId)
    assert.are.equal("closed", stored.status)
    assert.are.equal("Ann-Realm", stored.award.characterKey)
    assert.are.equal("Highest need", stored.award.reason)
    assert.are.equal("Boss-Realm", stored.award.awardedBy)
    assert.are.equal(2, stored.rev)
  end)

  it("refuses everyone who cannot award and unknown senders", function()
    local payload = award("Ann-Realm", "Highest need")
    for _, role in ipairs({ "roster", "member", "alter" }) do
      assert.are.equal("forbidden", select(2, deliver(receiver, "LOOT_AWARD", payload, "X-Realm", role)))
    end
    assert.are.equal("unknown_sender", select(2, deliver(receiver, "LOOT_AWARD", payload, "X-Realm", nil)))
    assert.are.equal("open", session_of(receiver, session.sessionId).status)
  end)

  it("creates the session when the receiver never saw it, because the award carries the item", function()
    local fresh = client("Fresh")
    assert.is_true(deliver(fresh, "LOOT_AWARD", award("Ann-Realm", "Highest need"), "Boss-Realm", "officer"))
    local stored = session_of(fresh, session.sessionId)
    assert.are.equal("Thunderfury", stored.itemName)
    assert.are.equal("closed", stored.status)
    assert.are.equal("Ann-Realm", stored.award.characterKey)
    assert.are.same({}, stored.candidates)
  end)

  it("is not undone by an older session record or a replay, and closes the session for good", function()
    local opening = LootSync.SessionPayload("ev-1", session)
    local payload = award("Ann-Realm", "Highest need")
    assert.is_true(deliver(receiver, "LOOT_AWARD", payload, "Boss-Realm", "officer"))

    assert.are.equal("stale", select(2, deliver(receiver, "LOOT_AWARD", payload, "Boss-Realm", "officer")))
    assert.are.equal("stale", select(2, deliver(receiver, "LOOT_SESSION", opening, "Boss-Realm", "officer")))
    assert.are.equal("Ann-Realm", session_of(receiver, session.sessionId).award.characterKey)

    local late = LootService.Register(origin.local_ctx("roster", "Late-Realm"), "ev-1", "x", CANDIDATE)
    assert.is_nil(late)
    local candidate = {
      eventId = "ev-1",
      sessionId = session.sessionId,
      rev = 1,
      updatedAt = 10,
      spec = "Fury",
      need = "main",
    }
    assert.are.equal("closed", select(2, deliver(receiver, "LOOT_CANDIDATE", candidate, "Late-Realm", "roster")))
  end)

  it("lets a newer session record that closes without an award replace the award", function()
    assert.is_true(deliver(receiver, "LOOT_AWARD", award("Ann-Realm", "Highest need"), "Boss-Realm", "officer"))
    local closing = LootSync.SessionPayload("ev-1", session)
    closing.rev, closing.status = 9, "closed"
    assert.is_true(deliver(receiver, "LOOT_SESSION", closing, "Boss-Realm", "officer"))
    local stored = session_of(receiver, session.sessionId)
    assert.is_nil(stored.award)
    assert.are.equal("closed", stored.status)
  end)

  it("converges when two council members award at once, whatever the arrival order", function()
    local a, b = client("A"), client("B")
    for _, c in ipairs({ a, b }) do
      c.events["ev-1"].loot[session.sessionId] = {
        sessionId = session.sessionId,
        itemId = 19019,
        itemName = "Thunderfury",
        status = "open",
        candidates = {},
        votes = {},
        rev = 1,
        updatedAt = 10,
        updatedBy = "Boss-Realm",
      }
    end
    local base = { eventId = "ev-1", sessionId = session.sessionId, rev = 2, itemId = 19019, itemName = "Thunderfury" }
    local function payload(updatedAt, target, reason)
      local p = {}
      for k, v in pairs(base) do
        p[k] = v
      end
      p.updatedAt, p.characterKey, p.reason = updatedAt, target, reason
      return p
    end
    local from_aaa, from_bbb = payload(100, "Ann-Realm", "Mine"), payload(105, "Bob-Realm", "Theirs")

    deliver(a, "LOOT_AWARD", from_aaa, "Aaa-Realm", "officer")
    deliver(a, "LOOT_AWARD", from_bbb, "Bbb-Realm", "officer")
    deliver(b, "LOOT_AWARD", from_bbb, "Bbb-Realm", "officer")
    deliver(b, "LOOT_AWARD", from_aaa, "Aaa-Realm", "officer")

    for _, c in ipairs({ a, b }) do
      local stored = session_of(c, session.sessionId)
      assert.are.equal("Bob-Realm", stored.award.characterKey)
      assert.are.equal("Bbb-Realm", stored.award.awardedBy)
    end
  end)

  it("stops at the session limit", function()
    local fresh = client("Fresh")
    for i = 1, Constants.LOOT_SESSIONS_MAX do
      fresh.events["ev-1"].loot["x" .. i] = { status = "closed", rev = 1 }
    end
    local ok, reason = deliver(fresh, "LOOT_AWARD", award("Ann-Realm", "Highest need"), "Boss-Realm", "officer")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)

describe("LootSync payloads and items", function()
  it("build payloads the protocol accepts", function()
    local origin = client("Origin")
    local council = origin.local_ctx("officer", "Boss-Realm")
    local session = assert(LootService.OpenSession(council, "ev-1", ITEM))
    local candidate = assert(LootService.Register(origin.local_ctx("roster", "Ann-Realm"), "ev-1", session.sessionId, {
      spec = "Fury",
      need = "main",
      upgrade = "Better weapon",
    }))
    local vote = assert(LootService.Vote(council, "ev-1", session.sessionId, "Ann-Realm"))
    local awarded = assert(LootService.Award(council, "ev-1", session.sessionId, "Ann-Realm", "Highest need"))

    local payloads = {
      LOOT_SESSION = LootSync.SessionPayload("ev-1", awarded),
      LOOT_CANDIDATE = LootSync.CandidatePayload("ev-1", session.sessionId, candidate),
      LOOT_VOTE = LootSync.VotePayload("ev-1", session.sessionId, vote),
      LOOT_AWARD = LootSync.AwardPayload("ev-1", awarded),
    }
    for messageType, payload in pairs(payloads) do
      assert.is_truthy(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")), messageType)
    end
  end)

  it("describe sessions as awards or session records, in a stable order, without candidates or votes", function()
    local origin = client("Origin")
    local council = origin.local_ctx("officer", "Boss-Realm")
    local awarded = assert(LootService.OpenSession(council, "ev-1", ITEM))
    LootService.Register(origin.local_ctx("roster", "Ann-Realm"), "ev-1", awarded.sessionId, CANDIDATE)
    LootService.Award(council, "ev-1", awarded.sessionId, "Ann-Realm", "Highest need")
    local open = assert(LootService.OpenSession(council, "ev-1", { itemId = 2, itemName = "Other" }))
    local skipped = assert(LootService.OpenSession(council, "ev-1", { itemId = 3, itemName = "Junk" }))
    LootService.Close(council, "ev-1", skipped.sessionId)

    local items = LootSync.SessionItems("ev-1", origin.events["ev-1"])
    assert.are.equal(3, #items)
    assert.are.equal("LOOT_AWARD", items[1].t)
    assert.are.equal(awarded.sessionId, items[1].p.sessionId)
    assert.are.equal("LOOT_SESSION", items[2].t)
    assert.are.equal(open.sessionId, items[2].p.sessionId)
    assert.are.equal("LOOT_SESSION", items[3].t)
    assert.are.equal("closed", items[3].p.status)
    for _, item in ipairs(items) do
      assert.is_nil(item.p.candidates)
      assert.is_nil(item.p.votes)
    end
  end)

  it("are empty for an event without loot", function()
    assert.are.same({}, LootSync.SessionItems("ev-1", {}))
    assert.are.same({}, LootSync.SessionItems("ev-1", { loot = {} }))
  end)
end)

describe("LootSync rosters", function()
  -- A receiver with an open session of an event of roster r1.
  local function setup(rosterOfSender)
    local origin, receiver = client("Boss-Realm"), client("Receiver-Realm")
    origin.events["ev-1"].rosterId, receiver.events["ev-1"].rosterId = "r1", "r1"
    receiver.rosterOf = function(sender)
      return rosterOfSender[sender]
    end
    local session = assert(LootService.OpenSession(origin.local_ctx("officer", "Boss-Realm"), "ev-1", ITEM))
    assert(deliver(receiver, "LOOT_SESSION", LootSync.SessionPayload("ev-1", session), "Boss-Realm", "gm"))
    return origin, receiver, session
  end

  it("accepts the council member, the candidate and the voter of the roster of the event", function()
    local origin, receiver, session = setup({ ["Boss-Realm"] = "r1", ["Ann-Realm"] = "r1", ["Cid-Realm"] = "r1" })
    local candidate =
      { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, spec = "Fury", need = "main" }
    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", candidate, "Ann-Realm", "roster"))
    local vote = { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, target = "Ann-Realm" }
    assert.is_true(deliver(receiver, "LOOT_VOTE", vote, "Cid-Realm", "officer"))
    assert.is_truthy(origin)
  end)

  it("refuses a candidacy, a vote, a session and an award from the council of another roster", function()
    local _, receiver, session = setup({ ["Ann-Realm"] = "r1", ["Other-Realm"] = "r2" })
    local candidate =
      { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, spec = "Fury", need = "main" }
    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", candidate, "Ann-Realm", "roster"))
    assert.are.equal("other_roster", select(2, deliver(receiver, "LOOT_CANDIDATE", candidate, "Other-Realm", "roster")))
    local vote = { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, target = "Ann-Realm" }
    assert.are.equal("other_roster", select(2, deliver(receiver, "LOOT_VOTE", vote, "Other-Realm", "officer")))
    local opened = { eventId = "ev-1", sessionId = "s-x", rev = 1, updatedAt = 1, status = "open" }
    opened.itemId, opened.itemName = ITEM.itemId, ITEM.itemName
    assert.are.equal("other_roster", select(2, deliver(receiver, "LOOT_SESSION", opened, "Other-Realm", "officer")))
    local award =
      { eventId = "ev-1", sessionId = session.sessionId, rev = 5, updatedAt = 5, characterKey = "Ann-Realm" }
    award.itemId, award.itemName, award.reason = ITEM.itemId, ITEM.itemName, "need"
    assert.are.equal("other_roster", select(2, deliver(receiver, "LOOT_AWARD", award, "Other-Realm", "officer")))
    assert.are.equal("open", receiver.events["ev-1"].loot[session.sessionId].status)
  end)

  it("refuses everybody with no roster, and lets the guild master act on any roster", function()
    local _, receiver, session = setup({ ["Ann-Realm"] = "r1" })
    local candidate =
      { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, spec = "Fury", need = "main" }
    assert.are.equal("other_roster", select(2, deliver(receiver, "LOOT_CANDIDATE", candidate, "Loner-Realm", "roster")))
    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", candidate, "Boss-Realm", "gm"))
  end)

  it("keeps the loot of an event no roster owns open to the members who have a roster", function()
    local _, receiver, session = setup({ ["Ann-Realm"] = "r2" })
    receiver.events["ev-1"].rosterId = nil
    local candidate =
      { eventId = "ev-1", sessionId = session.sessionId, rev = 1, updatedAt = 1, spec = "Fury", need = "main" }
    assert.is_true(deliver(receiver, "LOOT_CANDIDATE", candidate, "Ann-Realm", "roster"))
  end)
end)
