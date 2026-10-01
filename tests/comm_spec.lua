-- Exercises the whole receive/send pipeline with the real codec, protocol, inbox and queue.
-- Only the client (AceComm, timers, platform) is faked.
local function load_addon()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Sync/Codec",
    "Sync/Protocol",
    "Sync/Inbox",
    "Sync/OutboundQueue",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
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
    serialize = _G.LibStub("LibSerialize"),
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
    return env.wire("EVENT_UPSERT", { eventId = "ev-1", rev = 1, updatedAt = 10, title = "Molten Core" }, id)
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
    local event = { eventId = "ev-1", rev = 1, updatedAt = 10, title = "Molten Core", status = "planned" }
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
    assert.are.equal(2, joiner.tombstones["E:ev-0"].rev)

    local status = table.concat(joiner.comm:Status(), "\n")
    assert.is_truthy(status:find("last snapshot: 4 of 4 record(s) applied, from Lead-Realm", 1, true))
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
    return { t = "EVENT_UPSERT", p = { eventId = eventId, rev = 1, updatedAt = 10, title = "From snapshot" } }
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
    env.roles["Boss-Realm"] = "council"
    env.roles["Ann-Realm"] = "member"
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
    receiver.roles["Boss-Realm"] = "council"
    receiver.roles["Ann-Realm"] = "member"
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

    env.roles["Lead-Realm"] = "admin"
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
    env.roles["Black Coffee"] = "council"
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
    env.roles["Council-Realm"] = "council"
    env.roles["Lead-Realm"] = "rl"
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
    assert.is_false(env.comm:HandleMessage(session_text("m-1"), "Lead-Realm", "GUILD"))
    local event = env.wire("EVENT_UPSERT", { eventId = "ev-2", rev = 1, updatedAt = 10, title = "Other" }, "m-2")
    assert.is_true(env.comm:HandleMessage(event, "Lead-Realm", "GUILD"))
    assert.are.same({}, changes)
  end)
end)
