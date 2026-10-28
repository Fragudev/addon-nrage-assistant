-- Exercises the whole receive/send pipeline with the real codec, protocol, inbox and queue.
-- Only the client (AceComm, timers, platform) is faked.
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
    "Domain/RosterService",
    "Domain/PvPSeasonModel",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/ReadinessRules",
    "Sync/Codec",
    "Sync/Protocol",
    "Sync/Inbox",
    "Sync/OutboundQueue",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
    "Sync/PvPSync",
    "Sync/BlacklistSync",
    "Sync/ReadinessRulesSync",
    "Sync/RosterSync",
    "Sync/PvPSeasonSync",
    "Sync/RecipeSync",
    "Sync/LayerSync",
    "Sync/Transfer",
    "Sync/Comm",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Protocol = ns.Protocol

local function build_env()
  local env = {
    clock = 0,
    locked = false,
    sent = {},
    targets = {},
    scheduled = {},
    roster = {},
    events = {},
    tombstones = {},
    roles = {},
    pvpStats = {},
    pvpResets = {},
    pvpChanges = {},
    pvpKills = {},
    blacklist = {},
    blacklistChanges = {},
    readinessRules = {},
    rulesChanges = {},
    ownResets = {},
    rosterChanges = {},
    pvpSeason = ns.PvPSeasonSync.NewLedger(),
    seasonChanges = {},
    seasonClosed = {},
    -- Everybody is a member of roster r1 unless a test sets their entry.
    rosters = { r1 = { id = "r1", name = "Main", rev = 1, updatedAt = 1 } },
    members = setmetatable({}, {
      __index = function()
        return { role = "member", rosterId = "r1" }
      end,
    }),
  }

  env.platform = {
    GetIdentityKey = function()
      return "Me-Realm"
    end,
    NormalizeName = function(name)
      return name
    end,
    ServerTime = function()
      return 5000
    end,
  }
  env.codec = ns.Codec.New({
    serialize = _G.LibStub("NrageAssistant-LibSerialize"),
    deflate = _G.LibStub("LibDeflate"),
  })
  env.guard = {}
  function env.guard.CanSend()
    return not env.locked
  end
  env.queue = ns.OutboundQueue.New({
    guard = env.guard,
    now = function()
      return env.clock
    end,
    send = function(text, target)
      env.sent[#env.sent + 1] = text
      env.targets[#env.sent] = target
    end,
    jitter = function()
      return 0
    end,
  })
  env.comm = ns.Comm.New({
    platform = env.platform,
    codec = env.codec,
    inbox = ns.Inbox.New(),
    queue = env.queue,
    roster = env.roster,
    events = env.events,
    tombstones = env.tombstones,
    pvpStats = env.pvpStats,
    pvpResets = env.pvpResets,
    onPvPChange = function(messageType)
      env.pvpChanges[#env.pvpChanges + 1] = messageType
    end,
    onPvPKill = function(sender, payload)
      env.pvpKills[#env.pvpKills + 1] = { sender = sender, payload = payload }
    end,
    onPvPReset = function(rev)
      env.ownResets[#env.ownResets + 1] = rev
    end,
    blacklist = env.blacklist,
    onBlacklistChange = function(messageType)
      env.blacklistChanges[#env.blacklistChanges + 1] = messageType
    end,
    readinessRules = env.readinessRules,
    onRulesChange = function(messageType)
      env.rulesChanges[#env.rulesChanges + 1] = messageType
    end,
    pvpSeason = env.pvpSeason,
    onPvPSeasonChange = function(messageType)
      env.seasonChanges[#env.seasonChanges + 1] = messageType
    end,
    onPvPSeasonClosed = function(seasonId)
      env.seasonClosed[#env.seasonClosed + 1] = seasonId
    end,
    rosters = env.rosters,
    members = env.members,
    onRosterChange = function(messageType)
      env.rosterChanges[#env.rosterChanges + 1] = messageType
    end,
    roleOf = function(sender)
      return env.roles[sender]
    end,
    ownRole = function()
      return env.ownRole
    end,
    version = "0.1.0",
    now = function()
      return env.clock
    end,
    schedule = function(delay, fn)
      env.scheduled[#env.scheduled + 1] = { delay = delay, fn = fn }
    end,
    random = function(low)
      return low
    end,
  })

  function env.wire(messageType, payload, id)
    return env.codec:Encode(Protocol.Build(messageType, payload, id or "id-1"))
  end
  return env
end

local function profile(rev, overrides)
  local p = { rev = rev, class = "WARRIOR", level = 60, ilvl = 200 }
  for k, v in pairs(overrides or {}) do
    p[k] = v
  end
  return p
end

describe("Comm receiving", function()
  local env

  before_each(function()
    env = build_env()
  end)

  it("stores a received profile with the sender as identity and source received", function()
    local text = env.wire("PROFILE", profile(1, { fields = { role = "tank" } }))
    assert.is_true(env.comm:HandleMessage(text, "Other-Realm", "GUILD"))

    local entry = env.roster["Other-Realm"]
    assert.are.equal("Other-Realm", entry.identityKey)
    assert.are.equal("received", entry.source)
    assert.are.equal("WARRIOR", entry.class)
    assert.are.equal(60, entry.level)
    assert.are.equal("tank", entry.fields.role)
    assert.are.equal(5000, entry.receivedAt)
  end)

  it("ignores an older or equal revision and accepts a newer one", function()
    env.comm:HandleMessage(env.wire("PROFILE", profile(2), "a"), "Other-Realm", "GUILD")

    local older = env.wire("PROFILE", profile(1, { level = 10 }), "b")
    local ok, reason = env.comm:HandleMessage(older, "Other-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("stale_rev", reason)
    local equal = env.wire("PROFILE", profile(2, { level = 10 }), "c")
    ok, reason = env.comm:HandleMessage(equal, "Other-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("stale_rev", reason)
    assert.are.equal(60, env.roster["Other-Realm"].level)

    assert.is_true(env.comm:HandleMessage(env.wire("PROFILE", profile(3, { level = 61 }), "d"), "Other-Realm", "GUILD"))
    assert.are.equal(61, env.roster["Other-Realm"].level)
  end)

  it("does not let a duplicate message id count twice", function()
    local text = env.wire("HELLO", { version = "0.1.0" }, "same-id")
    assert.is_true(env.comm:HandleMessage(text, "Other-Realm", "GUILD"))
    local ok, reason = env.comm:HandleMessage(text, "Other-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
  end)

  it("only accepts the GUILD and WHISPER channels", function()
    for _, channel in ipairs({ "SAY", "PARTY", "RAID", "CHANNEL", "" }) do
      local ok, reason = env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }), "Other-Realm", channel)
      assert.is_false(ok)
      assert.are.equal("wrong_channel", reason)
    end
  end)

  it("does not take guild messages from a whisper", function()
    local ok, reason = env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }), "Other-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are_not.equal(true, ok)
    assert.is_nil(env.comm.peers["Other-Realm"])
    assert.is_string(reason)
  end)

  it("ignores its own messages and missing senders", function()
    local text = env.wire("HELLO", { version = "0.1.0" })
    assert.are.equal("own_message", select(2, env.comm:HandleMessage(text, "Me-Realm", "GUILD")))
    assert.are.equal("bad_sender", select(2, env.comm:HandleMessage(text, nil, "GUILD")))
    assert.are.equal("bad_sender", select(2, env.comm:HandleMessage(text, "", "GUILD")))
  end)

  it("drops garbage and invalid payloads without raising or storing anything", function()
    assert.is_false(env.comm:HandleMessage("not a real frame", "Other-Realm", "GUILD"))
    assert.is_false(env.comm:HandleMessage(nil, "Other-Realm", "GUILD"))

    local bad = env.wire("PROFILE", profile(1, { level = 9999 }))
    local ok, reason = env.comm:HandleMessage(bad, "Other-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("bad_payload", reason)
    assert.is_nil(next(env.roster))
  end)

  it("rate limits a flooding sender before decoding", function()
    local decoded = 0
    local original = env.codec.Decode
    env.codec.Decode = function(...)
      decoded = decoded + 1
      return original(...)
    end

    local limit = ns.Constants.INBOX_MAX_PER_WINDOW
    for i = 1, limit + 5 do
      env.comm:HandleMessage("garbage " .. i, "Spammer-Realm", "GUILD")
    end
    assert.are.equal(limit, decoded)
    assert.are.equal("rate_limited", select(2, env.comm:HandleMessage("x", "Spammer-Realm", "GUILD")))
  end)

  it("marks a peer on an incompatible protocol and keeps local data", function()
    env.roster["Keep-Realm"] = { rev = 1 }
    local message = Protocol.Build("HELLO", { version = "9.0.0" }, "id-1")
    message.v = ns.Constants.PROTOCOL_MAJOR + 1
    local text = env.codec:Encode(message)

    local ok, reason = env.comm:HandleMessage(text, "Future-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("incompatible_version", reason)
    assert.is_true(env.comm.peers["Future-Realm"].incompatible)
    assert.is_truthy(env.roster["Keep-Realm"])
  end)

  it("refuses new roster entries beyond the cap but still updates existing ones", function()
    for i = 1, ns.Constants.ROSTER_MAX_ENTRIES do
      env.roster["P" .. i .. "-Realm"] = { rev = 1 }
    end
    local ok, reason = env.comm:HandleMessage(env.wire("PROFILE", profile(1), "a"), "New-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("roster_full", reason)

    assert.is_true(env.comm:HandleMessage(env.wire("PROFILE", profile(2), "b"), "P1-Realm", "GUILD"))
  end)
end)

describe("Comm HELLO", function()
  local env

  before_each(function()
    env = build_env()
  end)

  it("records the peer version", function()
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.2.0" }), "Other-Realm", "GUILD")
    assert.are.equal("0.2.0", env.comm.peers["Other-Realm"].version)
  end)

  it("replies once, delayed, when a new peer appears", function()
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "a"), "A-Realm", "GUILD")
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "b"), "B-Realm", "GUILD")
    assert.are.equal(1, #env.scheduled)
    assert.are.equal(ns.Constants.HELLO_REPLY_DELAY_MIN, env.scheduled[1].delay)
    assert.are.equal(0, #env.sent)

    env.scheduled[1].fn()
    assert.are.equal(1, #env.sent)
    local decoded = Protocol.Validate(env.codec:Decode(env.sent[1]))
    assert.are.equal("HELLO", decoded.t)
    assert.are.equal("0.1.0", decoded.p.version)
  end)

  it("does not reply again to an already known peer or inside the cooldown", function()
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "a"), "A-Realm", "GUILD")
    env.scheduled[1].fn()

    env.clock = 5
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "b"), "A-Realm", "GUILD")
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "c"), "C-Realm", "GUILD")
    assert.are.equal(1, #env.scheduled)

    env.clock = ns.Constants.HELLO_REPLY_COOLDOWN_SECONDS + 1
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "d"), "D-Realm", "GUILD")
    assert.are.equal(2, #env.scheduled)
  end)

  it("holds HELLO during a lockdown and sends it afterwards", function()
    env.locked = true
    assert.is_true(env.comm:SendHello())
    assert.are.equal(0, #env.sent)
    assert.are.same({ "sync paused: encounter in progress" }, { env.comm:Status()[1] })

    env.locked = false
    env.comm:Flush()
    assert.are.equal(1, #env.sent)
  end)

  it("sends a valid HELLO with a fresh id each time", function()
    env.comm:SendHello()
    env.comm:SendHello()
    local first = Protocol.Validate(env.codec:Decode(env.sent[1]))
    local second = Protocol.Validate(env.codec:Decode(env.sent[2]))
    assert.are_not.equal(first.id, second.id)
  end)
end)

describe("Comm status", function()
  it("lists peers and flags incompatible ones", function()
    local env = build_env()
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }), "A-Realm", "GUILD")
    env.comm:RememberPeer("Z-Realm", { incompatible = true })
    local text = table.concat(env.comm:Status(), "\n")
    assert.is_truthy(text:find("peers seen: 2", 1, true))
    assert.is_truthy(text:find("A-Realm - addon 0.1.0", 1, true))
    assert.is_truthy(text:find("Z-Realm - incompatible protocol version", 1, true))
  end)
end)

describe("Comm raid operations", function()
  local env

  before_each(function()
    env = build_env()
    env.roles["Lead-Realm"] = "rl"
    env.roles["Raider-Realm"] = "member"
  end)

  local function event_text(id)
    return env.wire(
      "EVENT_UPSERT",
      { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 10, title = "Molten Core" },
      id
    )
  end

  it("applies an event sent by someone whose roster rank allows it", function()
    assert.is_true(env.comm:HandleMessage(event_text("m-1"), "Lead-Realm", "GUILD"))
    assert.are.equal("Molten Core", env.events["ev-1"].title)
    assert.are.equal("Lead-Realm", env.events["ev-1"].updatedBy)
  end)

  it("refuses a member and a sender the roster does not know", function()
    local ok, reason = env.comm:HandleMessage(event_text("m-1"), "Raider-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = env.comm:HandleMessage(event_text("m-2"), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(next(env.events))
  end)

  it("does not apply the same message twice", function()
    local text = event_text("m-1")
    assert.is_true(env.comm:HandleMessage(text, "Lead-Realm", "GUILD"))
    assert.are.equal("duplicate", select(2, env.comm:HandleMessage(text, "Lead-Realm", "GUILD")))
  end)

  it("sends local changes as valid, keyed messages that a receiver accepts", function()
    local event =
      { eventId = "ev-1", rosterId = "r1", rev = 1, updatedAt = 10, title = "Molten Core", status = "planned" }
    assert.is_true(env.comm:SendEvent(event))
    assert.is_true(env.comm:SendAttendance("ev-1", "A-Realm", { state = "present", rev = 1, updatedAt = 10 }))
    assert.is_true(env.comm:SendAssignment("ev-1", {
      assignmentId = "as-1",
      rev = 1,
      updatedAt = 10,
      encounter = "Ragnaros",
      characterKey = "A-Realm",
    }))
    assert.are.equal(3, #env.sent)

    local receiver = build_env()
    receiver.roles["Sender-Realm"] = "rl"
    for _, text in ipairs(env.sent) do
      assert.is_true(receiver.comm:HandleMessage(text, "Sender-Realm", "GUILD"))
    end
    assert.are.equal("present", receiver.events["ev-1"].attendance["A-Realm"].state)
    assert.are.equal("Ragnaros", receiver.events["ev-1"].assignments["as-1"].encounter)
  end)

  it("replaces a queued edit of the same record during a lockdown", function()
    env.locked = true
    env.comm:SendAttendance("ev-1", "A-Realm", { state = "present", rev = 1, updatedAt = 10 })
    env.comm:SendAttendance("ev-1", "A-Realm", { state = "late", rev = 2, updatedAt = 11 })
    env.comm:SendAttendance("ev-1", "B-Realm", { state = "present", rev = 1, updatedAt = 10 })
    assert.are.equal(2, env.queue:Pending())
  end)

  it("sends a delete only when a tombstone exists", function()
    assert.are.equal("no_tombstone", select(2, env.comm:SendDeleteEvent("ev-1")))
    assert.are.equal("no_tombstone", select(2, env.comm:SendDeleteAssignment("ev-1", "as-1")))

    env.tombstones["E:ev-1"] = { at = 10, rev = 3 }
    env.tombstones["A:ev-1:as-1"] = { at = 10, rev = 2 }
    assert.is_true(env.comm:SendDeleteEvent("ev-1"))
    assert.is_true(env.comm:SendDeleteAssignment("ev-1", "as-1"))
    assert.are.equal(2, #env.sent)
  end)
end)

describe("Comm snapshot for late joiners", function()
  local leader, joiner

  -- Fills `env` with one full event plus a deletion, as a leader would have it.
  local function seed(env)
    env.events["ev-1"] = {
      eventId = "ev-1",
      rosterId = "r1",
      title = "Molten Core",
      status = "open",
      startAt = 5000,
      rev = 3,
      updatedAt = 100,
      updatedBy = "Lead-Realm",
      source = "declared",
      attendance = { ["Ann-Realm"] = { state = "present", rev = 1, updatedAt = 100 } },
      assignments = {
        ["as-1"] = {
          assignmentId = "as-1",
          encounter = "Ragnaros",
          characterKey = "Ann-Realm",
          group = 1,
          rev = 1,
          updatedAt = 100,
        },
      },
    }
    env.tombstones["E:ev-0"] = { at = 50, rev = 2 }
  end

  -- A fresh SYNC_REQ frame each time, sent straight through Send so RequestSync's own cooldown
  -- does not get in the way of tests about the responder.
  local requests = 0
  local function request_text(env)
    requests = requests + 1
    assert.is_true(env.comm:Send("SYNC_REQ", {}, "req-" .. requests))
    return env.sent[#env.sent]
  end

  before_each(function()
    leader, joiner = build_env(), build_env()
    leader.ownRole = "rl"
    seed(leader)
    joiner.roles["Lead-Realm"] = "rl"
  end)

  it("brings a late joiner up to date through request, whisper and apply", function()
    local request = request_text(joiner)
    assert.is_nil(joiner.targets[1])

    assert.is_true(leader.comm:HandleMessage(request, "Joiner-Realm", "GUILD"))
    assert.are.equal(ns.Constants.SYNC_RESPONSE_DELAY_MIN, leader.scheduled[1].delay)
    assert.are.equal(0, #leader.sent)

    leader.scheduled[1].fn()
    assert.are.equal(1, #leader.sent)
    assert.are.equal("Joiner-Realm", leader.targets[1])

    assert.is_true(joiner.comm:HandleMessage(leader.sent[1], "Lead-Realm", "WHISPER"))
    local event = joiner.events["ev-1"]
    assert.are.equal("Molten Core", event.title)
    assert.are.equal("present", event.attendance["Ann-Realm"].state)
    assert.are.equal("Ragnaros", event.assignments["as-1"].encounter)
    assert.are.equal("Lead-Realm", event.updatedBy)
    assert.are.equal("received", event.source)
    -- A leader cannot make this client remember the deletion of an event it never saw: only the guild master can.
    assert.is_nil(joiner.tombstones["E:ev-0"])

    local status = table.concat(joiner.comm:Status(), "\n")
    assert.is_truthy(status:find("last snapshot: 3 of 4 record(s) applied, from Lead-Realm", 1, true))
  end)

  it("does not answer unless the responder is a leader", function()
    for _, role in ipairs({ "member", "" }) do
      leader.ownRole = role ~= "" and role or nil
      local ok, reason = leader.comm:HandleMessage(request_text(joiner), "Joiner-Realm", "GUILD")
      assert.is_false(ok)
      assert.are.equal("not_leader", reason)
    end
    assert.are.equal(0, #leader.scheduled)
  end)

  it("serves each requester at most once per cooldown", function()
    assert.is_true(leader.comm:HandleMessage(request_text(joiner), "A-Realm", "GUILD"))
    local ok, reason = leader.comm:HandleMessage(request_text(joiner), "A-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("cooldown", reason)

    assert.is_true(leader.comm:HandleMessage(request_text(joiner), "B-Realm", "GUILD"))
    assert.are.equal(2, #leader.scheduled)

    leader.clock = ns.Constants.SYNC_SERVE_COOLDOWN_SECONDS
    assert.is_true(leader.comm:HandleMessage(request_text(joiner), "A-Realm", "GUILD"))
  end)

  it("stops serving new requesters when its tracker is full of recent ones", function()
    local max = ns.Constants.SYNC_SERVED_MAX_ENTRIES
    for i = 1, max do
      leader.comm.served["R" .. i .. "-Realm"] = 0
    end
    leader.comm.servedCount = max

    local ok, reason = leader.comm:HandleSyncRequest("Late-Realm")
    assert.is_false(ok)
    assert.are.equal("busy", reason)

    leader.clock = ns.Constants.SYNC_SERVE_COOLDOWN_SECONDS
    assert.is_true(leader.comm:HandleSyncRequest("Late-Realm"))
    assert.are.equal(1, leader.comm.servedCount)
  end)

  it("limits how often a joiner asks", function()
    assert.is_true(joiner.comm:RequestSync())
    local ok, reason = joiner.comm:RequestSync()
    assert.is_false(ok)
    assert.are.equal("cooldown", reason)
    joiner.clock = ns.Constants.SYNC_REQUEST_COOLDOWN_SECONDS
    assert.is_true(joiner.comm:RequestSync())
  end)

  it("sends nothing when there is nothing to send", function()
    leader.events, leader.tombstones = {}, {}
    leader.comm.events, leader.comm.tombstones = leader.events, leader.tombstones
    local ok, reason = leader.comm:SendSnapshot("Joiner-Realm")
    assert.is_false(ok)
    assert.are.equal("empty", reason)
    assert.are.equal(0, #leader.sent)
  end)

  it("sends fewer, newer events when the snapshot would not fit", function()
    local saved = ns.Constants.SYNC_MAX_ENCODED_BYTES
    ns.Constants.SYNC_MAX_ENCODED_BYTES = 700
    math.randomseed(7)
    leader.events, leader.tombstones = {}, {}
    leader.comm.events, leader.comm.tombstones = leader.events, leader.tombstones
    for i = 1, 20 do
      local noise = {}
      for j = 1, 60 do
        noise[j] = string.char(math.random(97, 122))
      end
      local id = "ev-" .. i
      leader.events[id] = {
        eventId = id,
        rosterId = "r1",
        title = table.concat(noise),
        status = "planned",
        startAt = 1000 * i,
        rev = 1,
        updatedAt = 10,
        attendance = {},
        assignments = {},
      }
    end

    local ok = leader.comm:SendSnapshot("Joiner-Realm")
    ns.Constants.SYNC_MAX_ENCODED_BYTES = saved
    assert.is_true(ok)

    joiner.roles["Lead-Realm"] = "rl"
    assert.is_true(joiner.comm:HandleMessage(leader.sent[1], "Lead-Realm", "WHISPER"))
    local received = 0
    for _ in pairs(joiner.events) do
      received = received + 1
    end
    assert.is_true(received >= 1 and received < 20, received)
    assert.is_truthy(joiner.events["ev-20"])
  end)
end)

describe("Comm whisper guards", function()
  local env

  local function snapshot_text(id, items)
    return env.wire("SYNC_DATA", { items = items or {} }, id)
  end

  local function event_item(eventId)
    return {
      t = "EVENT_UPSERT",
      p = { eventId = eventId, rosterId = "r1", rev = 1, updatedAt = 10, title = "From snapshot" },
    }
  end

  before_each(function()
    env = build_env()
    env.roles["Lead-Realm"] = "rl"
    env.roles["Raider-Realm"] = "member"
  end)

  it("applies a leader's snapshot as that leader", function()
    local text = snapshot_text("s-1", { event_item("ev-1") })
    assert.is_true(env.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
    assert.are.equal("Lead-Realm", env.events["ev-1"].updatedBy)
  end)

  it("refuses members and unknown senders before decoding anything", function()
    local decoded = 0
    local original = env.codec.Decode
    env.codec.Decode = function(...)
      decoded = decoded + 1
      return original(...)
    end
    local text = snapshot_text("s-1", { event_item("ev-1") })
    assert.are.equal("forbidden", select(2, env.comm:HandleMessage(text, "Raider-Realm", "WHISPER")))
    assert.are.equal("unknown_sender", select(2, env.comm:HandleMessage(text, "Stranger-Realm", "WHISPER")))
    assert.are.equal(0, decoded)
    assert.is_nil(next(env.events))
  end)

  it("ignores its own whispers and missing senders", function()
    local text = snapshot_text("s-1")
    assert.are.equal("own_message", select(2, env.comm:HandleMessage(text, "Me-Realm", "WHISPER")))
    assert.are.equal("bad_sender", select(2, env.comm:HandleMessage(text, nil, "WHISPER")))
  end)

  it("accepts only snapshots as whispers and only whispers for snapshots", function()
    local hello = env.wire("HELLO", { version = "0.1.0" }, "h-1")
    assert.are.equal("wrong_channel", select(2, env.comm:HandleMessage(hello, "Lead-Realm", "WHISPER")))
    local snapshot = snapshot_text("s-1", { event_item("ev-1") })
    assert.are.equal("wrong_channel", select(2, env.comm:HandleMessage(snapshot, "Lead-Realm", "GUILD")))
    assert.is_nil(next(env.events))
    assert.are.equal("wrong_channel", select(2, env.comm:HandleMessage(snapshot, "Lead-Realm", "SAY")))
  end)

  it("rate limits snapshots much harder than guild traffic", function()
    local limit = ns.Constants.SYNC_INBOX_MAX_PER_WINDOW
    for i = 1, limit do
      assert.is_true(env.comm:HandleMessage(snapshot_text("s-" .. i), "Lead-Realm", "WHISPER"))
    end
    local ok, reason = env.comm:HandleMessage(snapshot_text("s-next"), "Lead-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are.equal("rate_limited", reason)
  end)

  it("does not apply the same snapshot twice", function()
    local text = snapshot_text("s-1", { event_item("ev-1") })
    assert.is_true(env.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
    assert.are.equal("duplicate", select(2, env.comm:HandleMessage(text, "Lead-Realm", "WHISPER")))
  end)

  it("drops garbage and oversized whispers without raising", function()
    local ok, reason = env.comm:HandleMessage("not a real frame", "Lead-Realm", "WHISPER")
    assert.is_false(ok)
    assert.is_string(reason)
    local huge = ("a"):rep(ns.Constants.SYNC_MAX_ENCODED_BYTES + 1)
    assert.are.equal("too_large", select(2, env.comm:HandleMessage(huge, "Lead-Realm", "WHISPER")))
  end)

  it("skips invalid or unsupported items and still applies the good ones", function()
    local items = {
      event_item("ev-1"),
      { t = "PROFILE", p = { rev = 1, class = "MAGE", level = 60 } },
      { t = "EVENT_UPSERT", p = { eventId = "bad id", rev = 1, updatedAt = 10, title = "Bad" } },
      "not an item",
    }
    assert.is_true(env.comm:HandleMessage(snapshot_text("s-1", items), "Lead-Realm", "WHISPER"))
    assert.is_truthy(env.events["ev-1"])
    assert.are.equal(1, env.comm.lastSnapshot.applied)
    assert.are.equal(4, env.comm.lastSnapshot.total)
  end)

  it("does not let a snapshot bypass authority or the event limit", function()
    for i = 1, ns.Constants.EVENT_MAX do
      env.events["e" .. i] = { rev = 1, updatedAt = 1 }
    end
    assert.is_true(env.comm:HandleMessage(snapshot_text("s-1", { event_item("new") }), "Lead-Realm", "WHISPER"))
    assert.is_nil(env.events["new"])
    assert.are.equal(0, env.comm.lastSnapshot.applied)
  end)
end)

describe("Comm loot council", function()
  local env

  local function event()
    return {
      eventId = "ev-1",
      title = "Molten Core",
      status = "open",
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = {},
      loot = {},
    }
  end

  local function session_text(id, overrides)
    local payload = {
      eventId = "ev-1",
      sessionId = "s-1",
      rev = 1,
      updatedAt = 10,
      itemId = 19019,
      itemName = "Thunderfury",
      status = "open",
    }
    for k, v in pairs(overrides or {}) do
      payload[k] = v
    end
    return env.wire("LOOT_SESSION", payload, id)
  end

  before_each(function()
    env = build_env()
    env.events["ev-1"] = event()
    env.roles["Boss-Realm"] = "officer"
    env.roles["Ann-Realm"] = "roster"
  end)

  it("applies a session opened by the council, as that sender", function()
    assert.is_true(env.comm:HandleMessage(session_text("m-1"), "Boss-Realm", "GUILD"))
    local session = env.events["ev-1"].loot["s-1"]
    assert.are.equal("Thunderfury", session.itemName)
    assert.are.equal("Boss-Realm", session.updatedBy)
  end)

  it("refuses a session from a member or from someone the roster does not know", function()
    assert.are.equal("forbidden", select(2, env.comm:HandleMessage(session_text("m-1"), "Ann-Realm", "GUILD")))
    assert.are.equal("unknown_sender", select(2, env.comm:HandleMessage(session_text("m-2"), "Nobody-Realm", "GUILD")))
    assert.is_nil(next(env.events["ev-1"].loot))
  end)

  it("sends local loot changes as keyed messages that another client accepts", function()
    local session = {
      sessionId = "s-1",
      rev = 1,
      updatedAt = 10,
      itemId = 19019,
      itemName = "Thunderfury",
      status = "open",
    }
    local candidate = { spec = "Fury", need = "main", rev = 1, updatedAt = 11 }
    local vote = { target = "Ann-Realm", rev = 1, updatedAt = 12 }
    local awarded = {
      sessionId = "s-1",
      rev = 2,
      updatedAt = 13,
      itemId = 19019,
      itemName = "Thunderfury",
      status = "closed",
      award = { characterKey = "Ann-Realm", reason = "Highest need" },
    }

    assert.is_true(env.comm:SendLootSession("ev-1", session))
    assert.is_true(env.comm:SendLootCandidate("ev-1", "s-1", candidate))
    assert.is_true(env.comm:SendLootVote("ev-1", "s-1", vote))
    assert.is_true(env.comm:SendLootAward("ev-1", awarded))
    assert.are.equal(4, #env.sent)

    -- The same four messages, received from the people who would really have sent them.
    local receiver = build_env()
    receiver.events["ev-1"] = event()
    receiver.roles["Boss-Realm"] = "officer"
    receiver.roles["Ann-Realm"] = "roster"
    assert.is_true(receiver.comm:HandleMessage(env.sent[1], "Boss-Realm", "GUILD"))
    assert.is_true(receiver.comm:HandleMessage(env.sent[2], "Ann-Realm", "GUILD"))
    assert.is_true(receiver.comm:HandleMessage(env.sent[3], "Boss-Realm", "GUILD"))
    assert.is_true(receiver.comm:HandleMessage(env.sent[4], "Boss-Realm", "GUILD"))

    local stored = receiver.events["ev-1"].loot["s-1"]
    assert.are.equal("closed", stored.status)
    assert.are.equal("Ann-Realm", stored.award.characterKey)
    assert.are.equal("Fury", stored.candidates["Ann-Realm"].spec)
    assert.are.equal("Ann-Realm", stored.votes["Boss-Realm"].target)
  end)

  it("does not send an award for a session that has none", function()
    local ok, reason = env.comm:SendLootAward("ev-1", { sessionId = "s-1" })
    assert.is_false(ok)
    assert.are.equal("no_award", reason)
    assert.are.equal(0, #env.sent)
  end)

  it("replaces a queued vote of the same session during a lockdown", function()
    env.locked = true
    env.comm:SendLootVote("ev-1", "s-1", { target = "Ann-Realm", rev = 1, updatedAt = 10 })
    env.comm:SendLootVote("ev-1", "s-1", { target = "Bob-Realm", rev = 2, updatedAt = 11 })
    env.comm:SendLootCandidate("ev-1", "s-1", { spec = "Fury", need = "main", rev = 1, updatedAt = 10 })
    assert.are.equal(2, env.queue:Pending())
  end)

  it("gives a late joiner the awards and open sessions of a leader's snapshot", function()
    local leader = build_env()
    leader.ownRole = "rl"
    leader.events["ev-1"] = event()
    leader.events["ev-1"].loot = {
      ["s-1"] = {
        sessionId = "s-1",
        itemId = 19019,
        itemName = "Thunderfury",
        status = "closed",
        rev = 2,
        updatedAt = 20,
        candidates = { ["Ann-Realm"] = { spec = "Fury", need = "main", rev = 1, updatedAt = 10 } },
        votes = { ["Boss-Realm"] = { target = "Ann-Realm", rev = 1, updatedAt = 11 } },
        award = { characterKey = "Ann-Realm", reason = "Highest need", awardedBy = "Boss-Realm", at = 20 },
      },
      ["s-2"] = {
        sessionId = "s-2",
        itemId = 2,
        itemName = "Other",
        status = "open",
        rev = 1,
        updatedAt = 30,
        candidates = {},
        votes = {},
      },
    }
    assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))

    env.roles["Lead-Realm"] = "gm"
    assert.is_true(env.comm:HandleMessage(leader.sent[1], "Lead-Realm", "WHISPER"))
    local loot = env.events["ev-1"].loot
    assert.are.equal("Ann-Realm", loot["s-1"].award.characterKey)
    assert.are.equal("Highest need", loot["s-1"].award.reason)
    assert.are.equal("open", loot["s-2"].status)
    assert.is_nil(next(loot["s-1"].candidates))
  end)
end)

describe("Comm sender names", function()
  local env

  before_each(function()
    env = build_env()
    -- The client delivers "Name-Realm" where the guild roster writes "Name".
    env.platform.NormalizeName = function(name)
      return (name:gsub("%-ClassicBetaPvP$", ""))
    end
    env.platform.GetIdentityKey = function()
      return "Yonemon Gg"
    end
    env.roles["Black Coffee"] = "officer"
  end)

  local function session_text()
    return env.wire("LOOT_SESSION", {
      eventId = "ev-1",
      sessionId = "s-1",
      rev = 1,
      updatedAt = 10,
      itemId = 1,
      itemName = "X",
      status = "open",
    }, "m-1")
  end

  it("reads a sender delivered with the realm as the roster's name, and applies their rank", function()
    env.events["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = {},
      loot = {},
    }
    assert.is_true(env.comm:HandleMessage(session_text(), "Black Coffee-ClassicBetaPvP", "GUILD"))
    assert.are.equal("Black Coffee", env.events["ev-1"].loot["s-1"].updatedBy)
  end)

  it("recognises its own message whatever way the client writes the name", function()
    local hello = env.wire("HELLO", { version = "0.1.0" })
    assert.are.equal("own_message", select(2, env.comm:HandleMessage(hello, "Yonemon Gg", "GUILD")))
    assert.are.equal("own_message", select(2, env.comm:HandleMessage(hello, "Yonemon Gg-ClassicBetaPvP", "GUILD")))
  end)

  it("remembers the last senders as delivered, and how they were read, for the debug command", function()
    local hello = env.wire("HELLO", { version = "0.1.0" })
    env.comm:HandleMessage(hello, "Black Coffee-ClassicBetaPvP", "GUILD")
    local recent = env.comm.recentSenders
    assert.are.equal(1, #recent)
    assert.are.equal("Black Coffee-ClassicBetaPvP", recent[1].raw)
    assert.are.equal("Black Coffee", recent[1].name)
  end)

  it("keeps only the five most recent senders", function()
    for i = 1, 8 do
      env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }, "h-" .. i), "Member " .. i, "GUILD")
    end
    local recent = env.comm.recentSenders
    assert.are.equal(5, #recent)
    assert.are.equal("Member 4", recent[1].raw)
    assert.are.equal("Member 8", recent[5].raw)
  end)

  it("does not record anything for a missing sender", function()
    env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }), nil, "GUILD")
    assert.are.equal(0, #env.comm.recentSenders)
  end)
end)

describe("Comm loot change notification", function()
  local env, changes

  before_each(function()
    env = build_env()
    env.roles["Council-Realm"] = "officer"
    env.roles["Lead-Realm"] = "rl"
    env.roles["Raider-Realm"] = "roster"
    env.events["ev-1"] = {
      eventId = "ev-1",
      title = "Raid",
      status = "open",
      rev = 1,
      updatedAt = 1,
      attendance = {},
      assignments = {},
      loot = {},
    }
    changes = {}
    env.comm.onLootChange = function(messageType)
      changes[#changes + 1] = messageType
    end
  end)

  local function session_text(id)
    return env.wire("LOOT_SESSION", {
      eventId = "ev-1",
      sessionId = "s1",
      rev = 1,
      updatedAt = 10,
      itemId = 19019,
      itemName = "Thunderfury",
      status = "open",
    }, id)
  end

  it("tells the window when a loot session is applied", function()
    assert.is_true(env.comm:HandleMessage(session_text("m-1"), "Council-Realm", "GUILD"))
    assert.are.same({ "LOOT_SESSION" }, changes)
    assert.is_truthy(env.events["ev-1"].loot.s1)
  end)

  it("says nothing when the message is refused, and nothing for other kinds of message", function()
    assert.is_false(env.comm:HandleMessage(session_text("m-1"), "Raider-Realm", "GUILD"))
    local event =
      env.wire("EVENT_UPSERT", { eventId = "ev-2", rosterId = "r1", rev = 1, updatedAt = 10, title = "Other" }, "m-2")
    assert.is_true(env.comm:HandleMessage(event, "Lead-Realm", "GUILD"))
    assert.are.same({}, changes)
  end)
end)

describe("Comm PvP counters", function()
  local env

  local function stats(overrides)
    local p = {
      rev = 1,
      updatedAt = 4990,
      honor = { world = 10, bg = 5 },
      blows = { world = 3, bg = 1 },
      today = { day = "2026-10-01", honor = { world = 2, bg = 1 }, blows = { world = 1, bg = 0 } },
    }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  before_each(function()
    env = build_env()
    env.roles["Ann-Realm"] = "member"
    env.roles["Boss-Realm"] = "gm"
    env.roles["Lead-Realm"] = "rl"
  end)

  it("stores a record under the sender and tells the UI", function()
    local body = stats()
    body.owner = "Victim-Realm"
    assert.is_true(env.comm:HandleMessage(env.wire("PVP_STATS", body, "p-1"), "Ann-Realm", "GUILD"))
    assert.are.equal(15, env.pvpStats["Ann-Realm"].honor.world + env.pvpStats["Ann-Realm"].honor.bg)
    assert.is_nil(env.pvpStats["Victim-Realm"])
    assert.are.same({ "PVP_STATS" }, env.pvpChanges)
  end)

  it("reads the sender's role from the roster, never from the message", function()
    local ok, reason = env.comm:HandleMessage(env.wire("PVP_STATS", stats(), "p-1"), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, env.pvpStats)
    assert.are.same({}, env.pvpChanges)
  end)

  it("drops an implausible or stale record without telling the UI", function()
    assert.is_true(env.comm:HandleMessage(env.wire("PVP_STATS", stats(), "p-1"), "Ann-Realm", "GUILD"))
    local lowered = stats({ rev = 2, honor = { world = 1, bg = 1 } })
    local ok, reason = env.comm:HandleMessage(env.wire("PVP_STATS", lowered, "p-2"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("implausible", reason)
    ok, reason = env.comm:HandleMessage(env.wire("PVP_STATS", stats(), "p-3"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("stale", reason)
    assert.are.equal(1, #env.pvpChanges)
  end)

  it("lets only an admin reset a member", function()
    assert.is_true(env.comm:HandleMessage(env.wire("PVP_STATS", stats(), "p-1"), "Ann-Realm", "GUILD"))
    local reset = env.wire("PVP_RESET", { target = "Ann-Realm", rev = 2 }, "r-1")
    local ok, reason = env.comm:HandleMessage(reset, "Lead-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.are.equal(10, env.pvpStats["Ann-Realm"].honor.world)

    reset = env.wire("PVP_RESET", { target = "Ann-Realm", rev = 2 }, "r-2")
    assert.is_true(env.comm:HandleMessage(reset, "Boss-Realm", "GUILD"))
    assert.are.equal(0, env.pvpStats["Ann-Realm"].honor.world)
    assert.are.equal(2, env.pvpResets["Ann-Realm"].rev)
    assert.are.same({}, env.ownResets)
    ok, reason = env.comm:HandleMessage(env.wire("PVP_STATS", stats({ rev = 2 }), "p-2"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("reset", reason)
  end)

  it("hands a reset of this client's own key to the callback", function()
    local reset = env.wire("PVP_RESET", { target = "Me-Realm", rev = 7 }, "r-1")
    assert.is_true(env.comm:HandleMessage(reset, "Boss-Realm", "GUILD"))
    assert.are.same({ 7 }, env.ownResets)
  end)

  it("accepts neither message as a whisper", function()
    local text = env.wire("PVP_STATS", stats(), "p-1")
    local ok, reason = env.comm:HandleMessage(text, "Lead-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are.equal("wrong_channel", reason)
    assert.are.same({}, env.pvpStats)
  end)

  it("sends the own counters under one queue key, so a newer message replaces a waiting one", function()
    env.locked = true
    assert.is_true(env.comm:SendPvPStats(stats({ rev = 1 })))
    assert.is_true(env.comm:SendPvPStats(stats({ rev = 2 })))
    assert.are.equal(1, env.queue:Pending())
    env.locked = false
    env.comm:Flush()
    assert.are.equal(1, #env.sent)
    local decoded = assert(env.codec:Decode(env.sent[1]))
    assert.are.equal("PVP_STATS", decoded.t)
    assert.are.equal(2, decoded.p.rev)
  end)

  describe("an admin reset from this client", function()
    it("is applied here, then told to the guild", function()
      env.ownRole = "gm"
      env.roles["Me-Realm"] = "gm"
      env.pvpStats["Ann-Realm"] = {
        honor = { world = 5, bg = 0 },
        today = { day = "2026-10-01", honor = { world = 0, bg = 0 } },
        rev = 4,
        updatedAt = 100,
      }
      local ok, rev, queued = env.comm:ResetPvP("Ann-Realm")
      assert.is_true(ok)
      assert.are.equal(5, rev)
      assert.is_true(queued)
      assert.are.equal(0, env.pvpStats["Ann-Realm"].honor.world)
      assert.are.same({ "PVP_RESET" }, env.pvpChanges)
      local decoded = assert(env.codec:Decode(env.sent[1]))
      assert.are.same({ target = "Ann-Realm", rev = 5 }, decoded.p)
    end)

    it("is refused to anybody else and for a bad name", function()
      env.ownRole = "rl"
      local ok, reason = env.comm:ResetPvP("Ann-Realm")
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.are.equal(0, #env.sent)

      env.ownRole = "gm"
      ok, reason = env.comm:ResetPvP("bad|name")
      assert.is_false(ok)
      assert.are.equal("bad_target", reason)
      assert.are.equal(0, #env.sent)
    end)

    it("resets the own counters through the callback when it names this client", function()
      env.ownRole = "gm"
      env.roles["Me-Realm"] = "gm"
      assert.is_true(env.comm:ResetPvP("Me-Realm"))
      assert.are.same({ 1 }, env.ownResets)
    end)
  end)
end)

describe("Comm PvP in a snapshot", function()
  local leader, joiner

  local function record(overrides)
    local r = {
      rev = 1,
      updatedAt = 4990,
      honor = { world = 10, bg = 5 },
      blows = { world = 3, bg = 1 },
      today = { day = "2026-10-01", honor = { world = 2, bg = 1 }, blows = { world = 1, bg = 0 } },
      receivedAt = 4995,
    }
    for k, v in pairs(overrides or {}) do
      r[k] = v
    end
    return r
  end

  before_each(function()
    leader, joiner = build_env(), build_env()
    leader.ownRole = "rl"
    joiner.roles["Lead-Realm"] = "rl"
    leader.pvpStats["Ann-Realm"] = record()
    leader.pvpStats["Bob-Realm"] = record({ honor = { world = 20, bg = 5 } })
  end)

  local function send_snapshot()
    local ok = leader.comm:SendSnapshot("Joiner-Realm")
    assert.is_true(ok)
    return leader.sent[#leader.sent]
  end

  it("gives a late joiner the records of other members, owner by owner", function()
    assert.is_true(joiner.comm:HandleMessage(send_snapshot(), "Lead-Realm", "WHISPER"))
    assert.are.equal(10, joiner.pvpStats["Ann-Realm"].honor.world)
    assert.are.equal(20, joiner.pvpStats["Bob-Realm"].honor.world)
    assert.is_nil(joiner.pvpStats["Lead-Realm"])
    assert.are.equal(2, joiner.comm.lastSnapshot.applied)
    assert.is_truthy(joiner.pvpChanges[1])
  end)

  it("carries the resets, which only count when an admin sent the snapshot", function()
    leader.pvpResets["Ann-Realm"] = { rev = 9 }
    local text = send_snapshot()
    assert.is_true(joiner.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
    assert.is_nil(joiner.pvpResets["Ann-Realm"])
    assert.are.equal(10, joiner.pvpStats["Ann-Realm"].honor.world)

    local admin = build_env()
    admin.roles["Boss-Realm"] = "gm"
    assert.is_true(admin.comm:HandleMessage(text, "Boss-Realm", "WHISPER"))
    assert.are.equal(9, admin.pvpResets["Ann-Realm"].rev)
  end)

  it("resets this client's own counters when a snapshot from an admin carries its reset", function()
    leader.pvpResets["Me-Realm"] = { rev = 6 }
    local text = send_snapshot()
    local admin = build_env()
    admin.roles["Boss-Realm"] = "gm"
    assert.is_true(admin.comm:HandleMessage(text, "Boss-Realm", "WHISPER"))
    assert.are.same({ 6 }, admin.ownResets)
  end)

  it("stays under the byte cap with a maximal number of maximal records", function()
    math.randomseed(11)
    leader.pvpStats, leader.pvpResets = {}, {}
    leader.comm.pvpStats, leader.comm.pvpResets = leader.pvpStats, leader.pvpResets
    local function noise(length)
      local chars = {}
      for i = 1, length do
        chars[i] = string.char(math.random(97, 122))
      end
      return table.concat(chars)
    end
    for i = 1, ns.Constants.GUILD_ROSTER_MAX do
      leader.pvpStats[noise(64)] = record({
        rev = math.random(1, 2000000000),
        updatedAt = 1000 + i,
        honor = { world = math.random(500000, 600000), bg = math.random(1, 400000) },
        blows = { world = math.random(500000, 600000), bg = math.random(1, 400000) },
      })
      leader.pvpResets[noise(64)] = { rev = math.random(1, 2000000000) }
    end
    local ok = leader.comm:SendSnapshot("Joiner-Realm")
    assert.is_true(ok)
    assert.is_true(#leader.sent[1] <= ns.Constants.SYNC_MAX_ENCODED_BYTES, #leader.sent[1])

    local admin = build_env()
    admin.roles["Boss-Realm"] = "gm"
    assert.is_true(admin.comm:HandleMessage(leader.sent[1], "Boss-Realm", "WHISPER"))
    local received, resets = 0, 0
    for _ in pairs(admin.pvpStats) do
      received = received + 1
    end
    for _ in pairs(admin.pvpResets) do
      resets = resets + 1
    end
    assert.are.equal(ns.Constants.PVP_SNAPSHOT_MAX, received)
    assert.are.equal(ns.Constants.PVP_SNAPSHOT_MAX, resets)
  end)

  it("shrinks the PvP part together with the events when the snapshot would not fit", function()
    local saved = ns.Constants.SYNC_MAX_ENCODED_BYTES
    ns.Constants.SYNC_MAX_ENCODED_BYTES = 1500
    math.randomseed(5)
    for i = 1, 100 do
      local chars = {}
      for j = 1, 40 do
        chars[j] = string.char(math.random(97, 122))
      end
      leader.pvpStats[table.concat(chars)] = record({ updatedAt = 1000 + i })
    end
    local ok = leader.comm:SendSnapshot("Joiner-Realm")
    ns.Constants.SYNC_MAX_ENCODED_BYTES = saved
    assert.is_true(ok)
    assert.is_true(#leader.sent[1] <= 1500)
  end)

  it("sends a snapshot of PvP records alone", function()
    local ok = leader.comm:SendSnapshot("Joiner-Realm")
    assert.is_true(ok)
  end)
end)

describe("Comm PVP_KILL", function()
  local env

  local function kill(overrides)
    local p = { victim = "Zed", where = "world", blow = false }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  before_each(function()
    env = build_env()
    env.roles["Ann-Realm"] = "member"
  end)

  it("hands the kill to the feed with the sender as the killer", function()
    local body = kill({ killer = "Someone-Else", sender = "Someone-Else" })
    assert.is_true(env.comm:HandleMessage(env.wire("PVP_KILL", body, "k-1"), "Ann-Realm", "GUILD"))
    assert.are.same(
      { { sender = "Ann-Realm", payload = { victim = "Zed", where = "world", blow = false } } },
      env.pvpKills
    )
    -- It is not a counter: nothing is stored and the ranking is not told.
    assert.are.same({}, env.pvpStats)
    assert.are.same({}, env.pvpChanges)
  end)

  it("needs a sender the guild roster knows", function()
    local ok, reason = env.comm:HandleMessage(env.wire("PVP_KILL", kill(), "k-1"), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, env.pvpKills)
  end)

  it("drops a bad place or a blow that is not a boolean", function()
    local noBlow = kill()
    noBlow.blow = nil
    for index, bad in ipairs({ kill({ where = "arena" }), kill({ blow = "yes" }), noBlow, kill({ victim = "" }) }) do
      local ok, reason = env.comm:HandleMessage(env.wire("PVP_KILL", bad, "k-" .. index), "Ann-Realm", "GUILD")
      assert.is_false(ok)
      assert.are.equal("bad_payload", reason)
    end
    assert.are.same({}, env.pvpKills)
  end)

  it("is not accepted as a whisper", function()
    local ok, reason = env.comm:HandleMessage(env.wire("PVP_KILL", kill(), "k-1"), "Ann-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are_not.equal(nil, reason)
    assert.are.same({}, env.pvpKills)
  end)

  it("sends a kill at once, and refuses instead of queueing during the lockdown", function()
    assert.is_true(env.comm:SendPvPKill(kill()))
    assert.are.equal(1, #env.sent)
    env.locked = true
    local ok, reason = env.comm:SendPvPKill(kill())
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    assert.are.equal(0, env.queue:Pending())
    assert.are.equal(1, #env.sent)
  end)
end)

describe("Comm blacklist", function()
  local env

  local function upsert(overrides)
    local p = { key = "yonemongg", name = "Yonemon Gg", reason = "ninja", rev = 1, updatedAt = 4990 }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  before_each(function()
    env = build_env()
    env.roles["Ann-Realm"] = "member"
    env.roles["Boss-Realm"] = "gm"
  end)

  it("stores an entry from any member, with the sender as the author, and tells the interface", function()
    assert.is_true(env.comm:HandleMessage(env.wire("BLACKLIST_UPSERT", upsert()), "Ann-Realm", "GUILD"))
    assert.are.equal("Ann-Realm", env.blacklist.yonemongg.addedBy)
    assert.are.same({ "BLACKLIST_UPSERT" }, env.blacklistChanges)
  end)

  it("drops an entry from a sender the roster does not know", function()
    local ok, reason = env.comm:HandleMessage(env.wire("BLACKLIST_UPSERT", upsert()), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, env.blacklist)
    assert.are.same({}, env.blacklistChanges)
  end)

  it("lets only an admin remove, and tells the interface only when something changed", function()
    env.comm:HandleMessage(env.wire("BLACKLIST_UPSERT", upsert(), "u1"), "Ann-Realm", "GUILD")
    local forged = env.wire("BLACKLIST_DELETE", { key = "yonemongg", rev = 2 }, "d1")
    local ok, reason = env.comm:HandleMessage(forged, "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    assert.is_truthy(env.blacklist.yonemongg)

    assert.is_true(
      env.comm:HandleMessage(env.wire("BLACKLIST_DELETE", { key = "yonemongg", rev = 2 }, "d2"), "Boss-Realm", "GUILD")
    )
    assert.is_nil(env.blacklist.yonemongg)
    assert.are.equal(2, env.tombstones["B:yonemongg"].rev)
    assert.are.same({ "BLACKLIST_UPSERT", "BLACKLIST_DELETE" }, env.blacklistChanges)
  end)

  it("drops an entry whose key does not belong to its name", function()
    local ok, reason =
      env.comm:HandleMessage(env.wire("BLACKLIST_UPSERT", upsert({ key = "other" })), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("bad_key", reason)
  end)

  it("sends an entry keyed by player, so a newer edit replaces a queued one", function()
    env.locked = true
    local entry = { name = "Yonemon Gg", reason = "ninja", rev = 1, updatedAt = 4990 }
    assert.is_true(env.comm:SendBlacklistUpsert("yonemongg", entry))
    entry.rev, entry.reason = 2, "afk"
    assert.is_true(env.comm:SendBlacklistUpsert("yonemongg", entry))
    assert.are.equal(0, #env.sent)
    assert.are.equal(1, env.queue:Pending())

    env.locked = false
    env.queue:Flush()
    assert.are.equal(1, #env.sent)
    local decoded = env.codec:Decode(env.sent[1])
    assert.are.equal("BLACKLIST_UPSERT", decoded.t)
    assert.are.equal(2, decoded.p.rev)
    assert.are.equal("afk", decoded.p.reason)
  end)

  it("sends a removal with the revision of its tombstone, and refuses one without a tombstone", function()
    local ok, reason = env.comm:SendBlacklistDelete("yonemongg")
    assert.is_false(ok)
    assert.are.equal("no_tombstone", reason)

    env.tombstones["B:yonemongg"] = { at = 1, rev = 3 }
    assert.is_true(env.comm:SendBlacklistDelete("yonemongg"))
    local decoded = env.codec:Decode(env.sent[1])
    assert.are.equal("BLACKLIST_DELETE", decoded.t)
    assert.are.same({ key = "yonemongg", rev = 3 }, decoded.p)
  end)

  it("holds a send back during the encounter lockdown", function()
    env.locked = true
    env.tombstones["B:x"] = { at = 1, rev = 1 }
    assert.is_true(env.comm:SendBlacklistDelete("x"))
    assert.are.same({}, env.sent)
    assert.are.equal(1, env.queue:Pending())
  end)

  describe("in a snapshot", function()
    local leader

    local function entry(name, overrides)
      local e = {
        name = name,
        reason = "ninja",
        addedBy = "Ann-Realm",
        addedAt = 500,
        rev = 1,
        updatedAt = 4000,
        updatedBy = "Ann-Realm",
      }
      for k, v in pairs(overrides or {}) do
        e[k] = v
      end
      return e
    end

    before_each(function()
      leader = build_env()
      leader.ownRole = "gm"
      env.roles["Lead-Realm"] = "gm"
    end)

    it("gives a late joiner the entries with their author, and the removals", function()
      leader.blacklist.yonemongg = entry("Yonemon Gg")
      leader.blacklist.bob = entry("Bob", { addedBy = "Cid-Realm" })
      leader.tombstones["B:gone"] = { at = 10, rev = 5 }
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))

      assert.is_true(env.comm:HandleMessage(leader.sent[1], "Lead-Realm", "WHISPER"))
      assert.are.equal("Ann-Realm", env.blacklist.yonemongg.addedBy)
      assert.are.equal("Cid-Realm", env.blacklist.bob.addedBy)
      assert.are.equal("Lead-Realm", env.blacklist.bob.updatedBy)
      assert.are.equal(5, env.tombstones["B:gone"].rev)
      assert.are.same({ "SYNC_DATA" }, env.blacklistChanges)
    end)

    it("stays under the byte cap with a maximal number of maximal entries and removals", function()
      math.randomseed(23)
      local function noise(length)
        local chars = {}
        for i = 1, length do
          chars[i] = string.char(math.random(97, 122))
        end
        return table.concat(chars)
      end
      local constants = ns.Constants
      for i = 1, constants.BLACKLIST_MAX do
        local name = noise(constants.BLACKLIST_NAME_MAX)
        leader.blacklist[name] = entry(name, {
          reason = noise(constants.BLACKLIST_REASON_MAX),
          addedBy = noise(60),
          addedAt = math.random(1, 2000000000),
          rev = math.random(1, 2000000000),
          updatedAt = 1000 + i,
        })
        leader.tombstones["B:" .. noise(constants.BLACKLIST_NAME_MAX)] = { at = i, rev = math.random(1, 2000000000) }
      end
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))
      assert.is_true(#leader.sent[1] <= constants.SYNC_MAX_ENCODED_BYTES, #leader.sent[1])

      assert.is_true(env.comm:HandleMessage(leader.sent[1], "Lead-Realm", "WHISPER"))
      local received = 0
      for _ in pairs(env.blacklist) do
        received = received + 1
      end
      assert.is_true(received >= 1 and received <= constants.BLACKLIST_SNAPSHOT_MAX, received)
    end)

    it("shrinks the blacklist part together with the events when the snapshot would not fit", function()
      local saved = ns.Constants.SYNC_MAX_ENCODED_BYTES
      ns.Constants.SYNC_MAX_ENCODED_BYTES = 1500
      math.randomseed(7)
      for i = 1, 100 do
        local chars = {}
        for j = 1, 30 do
          chars[j] = string.char(math.random(97, 122))
        end
        local name = table.concat(chars)
        leader.blacklist[name] = entry(name, { updatedAt = 1000 + i })
      end
      local ok = leader.comm:SendSnapshot("Joiner-Realm")
      ns.Constants.SYNC_MAX_ENCODED_BYTES = saved
      assert.is_true(ok)
      assert.is_true(#leader.sent[1] <= 1500)
    end)

    it("sends a snapshot of removals alone", function()
      leader.tombstones["B:gone"] = { at = 10, rev = 5 }
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))
    end)
  end)
end)

describe("Comm readiness rules", function()
  local env

  local function rules(min)
    return { { id = "level", label = "Level", check = "level", min = min or 60 } }
  end

  local function payload(overrides)
    local p = { rev = 1, updatedAt = 4000, rules = rules() }
    for k, v in pairs(overrides or {}) do
      p[k] = v
    end
    return p
  end

  before_each(function()
    env = build_env()
    env.roles["Ann-Realm"] = "member"
    env.roles["Boss-Realm"] = "gm"
  end)

  it("keeps the rules an admin sends and tells the interface", function()
    assert.is_true(env.comm:HandleMessage(env.wire("READINESS_RULES", payload()), "Boss-Realm", "GUILD"))
    assert.are.equal(60, env.readinessRules.rules[1].min)
    assert.are.same({ "READINESS_RULES" }, env.rulesChanges)
  end)

  it("drops rules from a member or from a sender the roster does not know", function()
    local ok, reason = env.comm:HandleMessage(env.wire("READINESS_RULES", payload()), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = env.comm:HandleMessage(env.wire("READINESS_RULES", payload(), "id-2"), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(env.readinessRules.rules)
    assert.are.same({}, env.rulesChanges)
  end)

  it("lets an admin set the rules: applied here, then told to the guild", function()
    env.ownRole = "gm"
    local ok, rev, queued = env.comm:SetReadinessRules(rules(58))
    assert.is_true(ok)
    assert.are.equal(1, rev)
    assert.is_true(queued)
    assert.are.equal(58, env.readinessRules.rules[1].min)
    assert.are.same({ "READINESS_RULES" }, env.rulesChanges)
    local decoded = env.codec:Decode(env.sent[1])
    assert.are.equal("READINESS_RULES", decoded.t)
    assert.are.equal(1, decoded.p.rev)

    ok, rev = env.comm:SetReadinessRules(rules(60))
    assert.is_true(ok)
    assert.are.equal(2, rev)
  end)

  it("refuses to set the rules for anyone but an admin, and refuses rules that do not validate", function()
    env.ownRole = "rl"
    assert.are.same({ false, "forbidden" }, { env.comm:SetReadinessRules(rules()) })
    env.ownRole = "gm"
    assert.are.same({ false, "empty" }, { env.comm:SetReadinessRules({}) })
    assert.are.same(
      { false, "bad_check" },
      { env.comm:SetReadinessRules({ { id = "x", label = "X", check = "run" } }) }
    )
    assert.is_nil(env.readinessRules.rules)
    assert.are.same({}, env.sent)
  end)

  it("sends nothing while there are no rules", function()
    assert.are.same({ false, "no_rules" }, { env.comm:SendReadinessRules() })
  end)

  describe("in a snapshot", function()
    local leader

    before_each(function()
      leader = build_env()
      leader.roles["Ann-Realm"] = "member"
      leader.readinessRules.rules = rules(58)
      leader.readinessRules.rev = 3
      leader.readinessRules.updatedAt = 4000
      leader.tombstones["B:x"] = { at = 1, rev = 1 }
    end)

    it("gives a late joiner the rules when the snapshot comes from an admin", function()
      leader.ownRole = "gm"
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))
      assert.is_true(env.comm:HandleMessage(leader.sent[1], "Boss-Realm", "WHISPER"))
      assert.are.equal(58, env.readinessRules.rules[1].min)
      assert.are.equal(3, env.readinessRules.rev)
      assert.are.same({ "SYNC_DATA" }, env.rulesChanges)
    end)

    it("does not put the rules in a snapshot that does not come from an admin", function()
      leader.ownRole = "rl"
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))
      assert.is_true(env.comm:HandleMessage(leader.sent[1], "Boss-Realm", "WHISPER"))
      assert.is_nil(env.readinessRules.rules)
    end)

    it("ignores the rules of a snapshot whose sender is not an admin for the receiver", function()
      leader.ownRole = "gm"
      env.roles["Boss-Realm"] = "rl"
      assert.is_true(leader.comm:SendSnapshot("Joiner-Realm"))
      env.comm:HandleMessage(leader.sent[1], "Boss-Realm", "WHISPER")
      assert.is_nil(env.readinessRules.rules)
    end)
  end)
end)

describe("Comm layers", function()
  local env

  before_each(function()
    env = build_env()
    env.roles["Ann-Realm"] = "member"
    env.layerStates, env.layerSteps, env.layerChanges = {}, {}, {}
    env.comm.layerDirectory = {
      Apply = function(_, sender, state)
        env.layerStates[#env.layerStates + 1] = { sender = sender, state = state }
        return true
      end,
    }
    env.comm.layerSwap = {
      OnMessage = function(_, sender, payload)
        env.layerSteps[#env.layerSteps + 1] = { sender = sender, payload = payload }
        return true
      end,
    }
    env.comm.onLayerChange = function(messageType)
      env.layerChanges[#env.layerChanges + 1] = messageType
    end
  end)

  it("hands a received layer to the directory with the sender as its owner", function()
    assert.is_true(
      env.comm:HandleMessage(env.wire("LAYER_STATE", { map = 1, layer = 50 }, "l-1"), "Ann-Realm", "GUILD")
    )
    assert.are.same({ { sender = "Ann-Realm", state = { map = 1, layer = 50 } } }, env.layerStates)
    assert.are.same({ "LAYER_STATE" }, env.layerChanges)
  end)

  it("hands a swap step to the flow", function()
    assert.is_true(
      env.comm:HandleMessage(env.wire("LAYER_SWAP", { rid = "r-1", s = "offer" }, "l-2"), "Ann-Realm", "GUILD")
    )
    assert.are.same({ { sender = "Ann-Realm", payload = { rid = "r-1", s = "offer" } } }, env.layerSteps)
    assert.are.same({ "LAYER_SWAP" }, env.layerChanges)
  end)

  it("needs a sender the guild roster knows", function()
    local ok, reason =
      env.comm:HandleMessage(env.wire("LAYER_STATE", { map = 1, layer = 50 }, "l-1"), "Stranger-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, env.layerStates)
    assert.are.same({}, env.layerChanges)
  end)

  it("does not tell the UI when the flow refused the step", function()
    env.comm.layerSwap.OnMessage = function()
      return false, "busy"
    end
    local ok, reason =
      env.comm:HandleMessage(env.wire("LAYER_SWAP", { rid = "r-1", s = "offer" }, "l-3"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("busy", reason)
    assert.are.same({}, env.layerChanges)
  end)

  it("is not accepted as a whisper", function()
    local ok, reason =
      env.comm:HandleMessage(env.wire("LAYER_STATE", { map = 1, layer = 50 }, "l-1"), "Ann-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are_not.equal(nil, reason)
    assert.are.same({}, env.layerStates)
  end)

  it("drops a bad payload", function()
    local ok, reason =
      env.comm:HandleMessage(env.wire("LAYER_SWAP", { rid = "r-1", s = "close" }, "l-4"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("bad_payload", reason)
  end)

  it("works without a directory or flow, and without a callback", function()
    env.comm.layerDirectory, env.comm.layerSwap, env.comm.onLayerChange = nil, nil, nil
    local ok, reason =
      env.comm:HandleMessage(env.wire("LAYER_STATE", { map = 1, layer = 50 }, "l-5"), "Ann-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("unsupported", reason)
  end)

  it("works without a callback", function()
    env.comm.onLayerChange = nil
    assert.is_true(
      env.comm:HandleMessage(env.wire("LAYER_STATE", { map = 1, layer = 50 }, "l-6"), "Ann-Realm", "GUILD")
    )
  end)

  it("sends the own layer under one queue key, and refuses it during the lockdown", function()
    assert.is_true(env.comm:SendLayerState({ map = 1, layer = 50 }))
    assert.are.equal(1, #env.sent)
    env.locked = true
    local ok, reason = env.comm:SendLayerState({ map = 1, layer = 51 })
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    assert.are.equal(0, env.queue:Pending())
  end)

  it("sends a swap step at once, and refuses it instead of queueing during the lockdown", function()
    assert.is_true(env.comm:SendLayerSwap({ rid = "r-1", s = "offer" }))
    assert.are.equal(1, #env.sent)
    env.locked = true
    local ok, reason = env.comm:SendLayerSwap({ rid = "r-1", s = "offer" })
    assert.is_false(ok)
    assert.are.equal("locked", reason)
    assert.are.equal(0, env.queue:Pending())
    assert.are.equal(1, #env.sent)
  end)

  it("sends what the receiver accepts", function()
    env.comm:SendLayerState({ map = 1, layer = 50 })
    local decoded = env.codec:Decode(env.sent[1])
    local message = Protocol.Validate(decoded)
    assert.are.equal("LAYER_STATE", message.t)
    assert.are.same({ map = 1, layer = 50 }, message.p)
  end)
end)

describe("Comm PvP seasons", function()
  local Sync = ns.PvPSeasonSync
  local T = 5000

  local function season(change)
    local record = {
      id = "s1",
      name = "Season One",
      startsAt = 1000,
      endsAt = 100000,
      state = "active",
      rev = 1,
      updatedAt = 10,
    }
    for key, value in pairs(change or {}) do
      record[key] = value
    end
    return record
  end

  local mission = {
    id = "m1",
    seasonId = "s1",
    title = "Hunt",
    points = 10,
    goal = { kind = "kills", count = 2 },
    repeatKind = "once",
    perPlayer = 1,
    rev = 1,
    updatedAt = 10,
  }

  local function claim(player, at)
    return {
      id = player .. ":m1:all:1",
      missionId = "m1",
      seasonId = "s1",
      periodKey = "all",
      player = player,
      at = at or T,
      evidence = { { at = T - 5, victim = "Grunt", place = "world" } },
    }
  end

  local ids = 0
  local function guild(env, messageType, payload, sender, id)
    ids = ids + 1
    return env.comm:HandleMessage(env.wire(messageType, payload, id or ("t-" .. ids)), sender, "GUILD")
  end

  -- Gives an env the roles every test uses and a running season with a mission, as a guild member who saw it all.
  local function populated(env, ownRole)
    env.ownRole = ownRole
    env.roles["Boss-Realm"] = "gm"
    env.roles["Off-Realm"] = "member"
    env.roles["Ann-Realm"] = "member"
    env.roles["Lead-Realm"] = "rl"
    env.roles["Late-Realm"] = "member"
    assert.is_true(guild(env, "PVP_SEASON", season(), "Boss-Realm"))
    assert.is_true(guild(env, "PVP_MISSION", mission, "Boss-Realm"))
    assert.is_true(
      guild(
        env,
        "PVP_OFFICER",
        { player = "Off-Realm", intervals = { { from = 100 } }, rev = 1, updatedAt = 10 },
        "Boss-Realm"
      )
    )
    return env
  end

  local env

  before_each(function()
    env = populated(build_env(), "gm")
  end)

  it("takes the records of an admin, tells the interface, and keeps the sender as the author", function()
    assert.are.equal("s1", env.pvpSeason.activeId)
    assert.are.equal("Boss-Realm", env.pvpSeason.seasons.s1.updatedBy)
    assert.are.equal("Hunt", env.pvpSeason.missions.m1.title)
    assert.are.same({ "PVP_SEASON", "PVP_MISSION", "PVP_OFFICER" }, env.seasonChanges)
  end)

  it("refuses the same records from a member, and an author named in the payload changes nothing", function()
    local other = populated(build_env(), "gm")
    local ok, reason =
      guild(other, "PVP_SEASON", season({ id = "s2", state = "closed", rev = 1, by = "Boss-Realm" }), "Ann-Realm")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = guild(other, "PVP_MISSION", mission, "Ann-Realm", "x-1")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
    ok, reason = guild(other, "PVP_SEASON", season({ id = "s2" }), "Stranger-Realm")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.is_nil(other.pvpSeason.seasons.s2)
  end)

  it("keeps a claim of the sender on a client that approves, and refuses one that names somebody else", function()
    assert.is_true(guild(env, "PVP_CLAIM", claim("Ann-Realm"), "Ann-Realm"))
    assert.is_truthy(env.pvpSeason.queue["Ann-Realm:m1:all:1"])
    local ok, reason = guild(env, "PVP_CLAIM", claim("Bob-Realm"), "Ann-Realm")
    assert.is_false(ok)
    assert.are.equal("bad_player", reason)

    local member = populated(build_env(), "member")
    ok, reason = guild(member, "PVP_CLAIM", claim("Ann-Realm"), "Ann-Realm")
    assert.is_false(ok)
    assert.are.equal("not_approver", reason)
  end)

  it("approves claims only as gm or cogm: a stored officer flag gives nothing", function()
    local officer = populated(build_env(), "member")
    officer.platform.GetIdentityKey = function()
      return "Off-Realm"
    end
    assert.is_false(officer.comm:IsPvPApprover())
    assert.are.equal("not_approver", select(2, guild(officer, "PVP_CLAIM", claim("Ann-Realm"), "Ann-Realm")))
    for _, role in ipairs({ "officer", "rl", "roster", "member", "alter" }) do
      assert.is_false(populated(build_env(), role).comm:IsPvPApprover(), role)
    end
    assert.is_true(populated(build_env(), "gm").comm:IsPvPApprover())
    assert.is_true(populated(build_env(), "cogm").comm:IsPvPApprover())
  end)

  it("refuses everybody but gm and cogm to set a PvP officer", function()
    for _, sender in ipairs({ "Lead-Realm", "Ann-Realm", "Off-Realm" }) do
      local ok, reason = guild(
        env,
        "PVP_OFFICER",
        { player = "Ann-Realm", intervals = { { from = 100 } }, rev = 9, updatedAt = 20 },
        sender
      )
      assert.is_false(ok, sender)
      assert.are.equal("forbidden", reason, sender)
    end
    assert.is_nil(env.pvpSeason.officers["Ann-Realm"])
  end)

  it("applies a grant of the gm and the cogm, not one of an officer, and closes the season on the final", function()
    env.roles["Co-Realm"] = "cogm"
    local grant =
      { id = "Ann-Realm:m1:all:1", seasonId = "s1", player = "Ann-Realm", missionId = "m1", points = 10, at = T }
    assert.are.equal("forbidden", select(2, guild(env, "PVP_GRANT", grant, "Off-Realm")))
    assert.is_true(guild(env, "PVP_GRANT", grant, "Co-Realm"))
    assert.is_true(
      guild(
        env,
        "PVP_GRANT",
        { id = "direct-1", seasonId = "s1", player = "Bob-Realm", missionId = "m1", points = 5, at = T },
        "Boss-Realm"
      )
    )
    local ok, reason = guild(
      env,
      "PVP_GRANT",
      { id = "direct-2", seasonId = "s1", player = "Bob-Realm", missionId = "m1", points = 5, at = T },
      "Off-Realm"
    )
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)

    local final = {
      seasonId = "s1",
      name = "Season One",
      startsAt = 1000,
      endsAt = 100000,
      closedAt = T,
      standings = {
        { pos = 1, player = "Ann-Realm", points = 10, lastAt = T },
        { pos = 2, player = "Bob-Realm", points = 5, lastAt = T },
      },
      prizes = {},
    }
    assert.is_true(guild(env, "PVP_FINAL", final, "Boss-Realm"))
    assert.are.same({ "s1" }, env.seasonClosed)
    assert.is_nil(env.pvpSeason.activeId)
    assert.is_nil(env.pvpSeason.grants.s1)
    assert.is_truthy(env.pvpSeason.deliveries.s1["Ann-Realm"])
  end)

  it("works without callbacks", function()
    env.comm.onPvPSeasonChange, env.comm.onPvPSeasonClosed = nil, nil
    assert.is_true(guild(env, "PVP_SEASON", season({ rev = 2 }), "Boss-Realm", "y-1"))
  end)

  describe("asking for the ledger", function()
    it("sends the count and the digest of what is held, once per cooldown", function()
      local asker = populated(build_env(), "member")
      -- Learning of the season already asked once: wait out the cooldown.
      asker.clock = asker.clock + ns.Constants.PVP_LEDGER_REQUEST_COOLDOWN_SECONDS
      assert.is_true(asker.comm:RequestLedger())
      local request = Protocol.Validate(asker.codec:Decode(asker.sent[#asker.sent]))
      assert.are.equal("PVP_LEDGER_REQ", request.t)
      assert.are.equal("s1", request.p.seasonId)
      local summary = Sync.Summary(asker.pvpSeason, "s1")
      assert.are.same({ summary.count, summary.digest }, { request.p.count, request.p.digest })
      local ok, reason = asker.comm:RequestLedger()
      assert.is_false(ok)
      assert.are.equal("cooldown", reason)
      asker.clock = asker.clock + ns.Constants.PVP_LEDGER_REQUEST_COOLDOWN_SECONDS
      assert.is_true(asker.comm:RequestLedger())
    end)

    it("asks without a season when it knows none", function()
      local fresh = build_env()
      assert.is_true(fresh.comm:RequestLedger())
      local request = Protocol.Validate(fresh.codec:Decode(fresh.sent[#fresh.sent]))
      assert.is_nil(request.p.seasonId)
      assert.are.equal(0, request.p.count)
    end)

    it("asks by itself when a season becomes active here", function()
      local fresh = build_env()
      fresh.roles["Boss-Realm"] = "gm"
      assert.is_true(guild(fresh, "PVP_SEASON", season(), "Boss-Realm"))
      assert.are.equal(1, #fresh.sent)
      local request = Protocol.Validate(fresh.codec:Decode(fresh.sent[1]))
      assert.are.equal("PVP_LEDGER_REQ", request.t)
      assert.are.equal("s1", request.p.seasonId)
      -- A new edit of the same season is not a new season.
      assert.is_true(guild(fresh, "PVP_SEASON", season({ rev = 2 }), "Boss-Realm", "again"))
      assert.are.equal(1, #fresh.sent)
    end)
  end)

  describe("answering a request", function()
    local relay, late

    local function ask(from)
      assert.is_true(from.comm:RequestLedger())
      return from.sent[#from.sent]
    end

    before_each(function()
      -- The relay saw everything, plus a grant; the late joiner saw nothing.
      relay = populated(build_env(), "rl")
      assert.is_true(
        guild(
          relay,
          "PVP_GRANT",
          { id = "Ann-Realm:m1:all:1", seasonId = "s1", player = "Ann-Realm", missionId = "m1", points = 10, at = T },
          "Boss-Realm"
        )
      )
      assert.is_true(
        guild(
          relay,
          "PVP_GRANT",
          { id = "direct-1", seasonId = "s1", player = "Bob-Realm", missionId = "m1", points = 7, at = T + 1 },
          "Boss-Realm"
        )
      )
      relay.sent, relay.targets = {}, {}
      late = build_env()
      late.ownRole = "member"
      late.roles["Lead-Realm"] = "rl"
      late.roles["Boss-Realm"] = "gm"
      late.roles["Off-Realm"] = "member"
    end)

    it("catches a late joiner up through request, whisper and apply", function()
      local request = ask(late)
      assert.is_true(relay.comm:HandleMessage(request, "Late-Realm", "GUILD"))
      assert.are.equal(ns.Constants.SYNC_RESPONSE_DELAY_MIN, relay.scheduled[1].delay)
      assert.are.equal(0, #relay.sent)
      relay.scheduled[1].fn()
      assert.is_true(#relay.sent >= 1)
      for index, text in ipairs(relay.sent) do
        assert.are.equal("Late-Realm", relay.targets[index])
        assert.is_true(#text <= ns.Constants.SYNC_MAX_ENCODED_BYTES)
        assert.is_true(late.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
      end
      assert.are.equal("s1", late.pvpSeason.activeId)
      assert.are.equal("Hunt", late.pvpSeason.missions.m1.title)
      assert.is_truthy(late.pvpSeason.grants.s1["Ann-Realm:m1:all:1"])
      assert.are.same(Sync.Summary(relay.pvpSeason, "s1"), Sync.Summary(late.pvpSeason, "s1"))
      assert.is_truthy(late.seasonChanges[#late.seasonChanges])
      assert.are.equal("Lead-Realm", late.comm.lastLedger.from)
    end)

    it("does not answer when the ledgers are the same, from a client that is not a relay, or to a stranger", function()
      late.pvpSeason = relay.pvpSeason
      late.comm.pvpSeason = relay.pvpSeason
      local request = ask(late)
      assert.are.equal("in_sync", select(2, relay.comm:HandleMessage(request, "Late-Realm", "GUILD")))

      local fresh = build_env()
      fresh.comm.counter = 100
      request = ask(fresh)
      local member = populated(build_env(), "member")
      assert.are.equal("not_relay", select(2, member.comm:HandleMessage(request, "Late-Realm", "GUILD")))
      relay.roles["Late-Realm"] = nil
      assert.are.equal("unknown_sender", select(2, relay.comm:HandleMessage(request, "Late-Realm", "GUILD")))
      assert.are.equal(0, #relay.scheduled)
    end)

    it("answers a requester at most once per cooldown", function()
      local fresh = build_env()
      local first = ask(fresh)
      assert.is_true(relay.comm:HandleMessage(first, "Late-Realm", "GUILD"))
      fresh.clock = fresh.clock + ns.Constants.PVP_LEDGER_REQUEST_COOLDOWN_SECONDS
      local second = ask(fresh)
      local ok, reason = relay.comm:HandleMessage(second, "Late-Realm", "GUILD")
      assert.is_false(ok)
      assert.are.equal("cooldown", reason)
      relay.clock = relay.clock + ns.Constants.PVP_LEDGER_SERVE_COOLDOWN_SECONDS
      fresh.clock = fresh.clock + ns.Constants.PVP_LEDGER_REQUEST_COOLDOWN_SECONDS
      assert.is_true(relay.comm:HandleMessage(ask(fresh), "Late-Realm", "GUILD"))
    end)

    it("answers a leader (raid_manage), and not a stored PvP officer who is only a member", function()
      local officer = populated(build_env(), "member")
      officer.platform.GetIdentityKey = function()
        return "Off-Realm"
      end
      assert.is_false(officer.comm:IsLedgerRelay())
      for _, role in ipairs({ "gm", "cogm", "officer", "rl" }) do
        assert.is_true(populated(build_env(), role).comm:IsLedgerRelay(), role)
      end
      for _, role in ipairs({ "roster", "member", "alter" }) do
        assert.is_false(populated(build_env(), role).comm:IsLedgerRelay(), role)
      end
    end)

    it("says there is nothing to send when its ledger is empty", function()
      local empty = build_env()
      empty.ownRole = "rl"
      local ok, reason = empty.comm:SendLedger("Late-Realm", { count = 3, digest = "00000000" })
      assert.is_false(ok)
      assert.are.equal("empty", reason)
    end)

    it("splits a big ledger into whispers that each fit", function()
      -- Straight into the ledger: 600 guild messages from one sender would hit the rate limit first.
      for index = 1, 600 do
        local message = Protocol.Validate(Protocol.Build("PVP_GRANT", {
          id = "bulk-" .. index,
          seasonId = "s1",
          player = "Player" .. (index % 50) .. "-Realm",
          missionId = "m1",
          points = 1 + index % 30,
          at = T + index % 250,
        }, "bulk"))
        assert.is_true(Sync.Apply(relay.comm:PvPSeasonContext(), message, "Boss-Realm"))
      end
      relay.sent, relay.targets = {}, {}
      relay.queue.maxItems = 1000
      local ok, count = relay.comm:SendLedger("Late-Realm", { seasonId = "s1", count = 0, digest = "00000000" })
      assert.is_true(ok)
      assert.is_true(count >= 2)
      assert.are.equal(count, #relay.sent)
      for _, text in ipairs(relay.sent) do
        assert.is_true(#text <= ns.Constants.SYNC_MAX_ENCODED_BYTES)
        assert.is_true(late.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
      end
      assert.are.same(Sync.Summary(relay.pvpSeason, "s1"), Sync.Summary(late.pvpSeason, "s1"))
    end)
  end)

  describe("a catch-up whisper", function()
    local function page(items, id)
      return env.wire("PVP_LEDGER_DATA", { seasonId = "s1", page = 1, pages = 1, items = items }, id or "p-1")
    end
    local items = {
      {
        t = "PVP_GRANT",
        p = { id = "direct-9", seasonId = "s1", player = "Ann-Realm", missionId = "m1", points = 3, at = T },
        by = "Boss-Realm",
      },
    }

    it("is accepted from a raid leader and an admin, and applied as its author", function()
      assert.is_true(env.comm:HandleMessage(page(items), "Lead-Realm", "WHISPER"))
      assert.is_truthy(env.pvpSeason.grants.s1["direct-9"])
      assert.are.equal("Boss-Realm", env.pvpSeason.grants.s1["direct-9"].by)
      assert.is_true(env.comm:HandleMessage(page({}, "p-2"), "Boss-Realm", "WHISPER"))
      assert.are.equal("forbidden", select(2, env.comm:HandleMessage(page({}, "p-3"), "Off-Realm", "WHISPER")))
    end)

    it("is refused from a member before anything is decoded", function()
      local decoded = 0
      local original = env.codec.Decode
      env.codec.Decode = function(...)
        decoded = decoded + 1
        return original(...)
      end
      assert.are.equal("forbidden", select(2, env.comm:HandleMessage(page(items), "Ann-Realm", "WHISPER")))
      assert.are.equal("unknown_sender", select(2, env.comm:HandleMessage(page(items), "Stranger-Realm", "WHISPER")))
      assert.are.equal(0, decoded)
      assert.is_nil(env.pvpSeason.grants.s1)
    end)

    it("does not let a stored PvP officer relay a snapshot", function()
      local snapshot = env.wire("SYNC_DATA", { items = {} }, "s-1")
      local ok, reason = env.comm:HandleMessage(snapshot, "Off-Realm", "WHISPER")
      assert.is_false(ok)
      assert.are.equal("forbidden", reason)
      assert.is_true(env.comm:HandleMessage(snapshot, "Lead-Realm", "WHISPER"))
    end)

    it("is not applied twice, and not accepted on the guild channel", function()
      local text = page(items)
      assert.is_true(env.comm:HandleMessage(text, "Lead-Realm", "WHISPER"))
      assert.are.equal("duplicate", select(2, env.comm:HandleMessage(text, "Lead-Realm", "WHISPER")))
      assert.are.equal("wrong_channel", select(2, env.comm:HandleMessage(page(items, "p-9"), "Lead-Realm", "GUILD")))
    end)

    it("has a rate limit of its own that a burst of pages fits in", function()
      for index = 1, ns.Constants.PVP_LEDGER_PAGES_MAX do
        assert.is_true(env.comm:HandleMessage(page({}, "burst-" .. index), "Lead-Realm", "WHISPER"))
      end
      local ok, reason = env.comm:HandleMessage(page({}, "burst-next"), "Lead-Realm", "WHISPER")
      assert.is_false(ok)
      assert.are.equal("rate_limited", reason)
    end)

    it("skips what its author could not have written", function()
      local forged = {
        { t = "PVP_GRANT", p = items[1].p, by = "Ann-Realm" },
        { t = "PVP_SEASON", p = season({ id = "s9", rev = 9 }), by = "Ann-Realm" },
      }
      assert.is_true(env.comm:HandleMessage(page(forged), "Lead-Realm", "WHISPER"))
      assert.is_nil(env.pvpSeason.grants.s1)
      assert.is_nil(env.pvpSeason.seasons.s9)
      assert.are.equal(0, env.comm.lastLedger.applied)
    end)
  end)

  it("measures whether a record fits one guild message", function()
    assert.is_true(env.comm:Fits("PVP_SEASON", season()))
    local noise, seed = {}, 3
    for index = 1, 20000 do
      seed = (seed * 1103515245 + 12345) % 2147483648
      noise[index] = string.char(33 + seed % 90)
    end
    assert.is_false(env.comm:Fits("PVP_SEASON", { name = table.concat(noise) }))
  end)
end)
