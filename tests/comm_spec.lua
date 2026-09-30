-- Exercises the whole receive/send pipeline with the real codec, protocol, inbox and queue.
-- Only the client (AceComm, timers, platform) is faked.
local function load_addon()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Sync/Codec", "Sync/Protocol", "Sync/Inbox", "Sync/OutboundQueue", "Sync/Comm",
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
    scheduled = {},
    roster = {},
  }

  env.platform = {
    GetIdentityKey = function() return "Me-Realm" end,
    ServerTime = function() return 5000 end,
  }
  env.codec = ns.Codec.New({
    serialize = _G.LibStub("LibSerialize"),
    deflate = _G.LibStub("LibDeflate"),
  })
  env.guard = {}
  function env.guard.CanSend() return not env.locked end
  env.queue = ns.OutboundQueue.New({
    guard = env.guard,
    now = function() return env.clock end,
    send = function(text) env.sent[#env.sent + 1] = text end,
    jitter = function() return 0 end,
  })
  env.comm = ns.Comm.New({
    platform = env.platform,
    codec = env.codec,
    inbox = ns.Inbox.New(),
    queue = env.queue,
    roster = env.roster,
    version = "0.1.0",
    now = function() return env.clock end,
    schedule = function(delay, fn) env.scheduled[#env.scheduled + 1] = { delay = delay, fn = fn } end,
    random = function(low) return low end,
  })

  function env.wire(messageType, payload, id)
    return env.codec:Encode(Protocol.Build(messageType, payload, id or "id-1"))
  end
  return env
end

local function profile(rev, overrides)
  local p = { rev = rev, class = "WARRIOR", level = 60, ilvl = 200 }
  for k, v in pairs(overrides or {}) do p[k] = v end
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

  it("only accepts the GUILD channel", function()
    local ok, reason = env.comm:HandleMessage(env.wire("HELLO", { version = "0.1.0" }), "Other-Realm", "WHISPER")
    assert.is_false(ok)
    assert.are.equal("wrong_channel", reason)
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
