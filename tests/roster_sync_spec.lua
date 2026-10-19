-- Roster definitions and assigned roles on the wire: protocol validation, who may send them, conflicts, tombstones,
-- snapshots, and the whole pipeline through Comm.
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
    "Sync/RecipeSync",
    "Sync/Transfer",
    "Sync/Comm",
    "Commands/RosterCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local Protocol, RosterSync, Constants = ns.Protocol, ns.RosterSync, ns.Constants

local function on_wire(messageType, payload)
  return assert(Protocol.Validate(Protocol.Build(messageType, payload, "id-1")))
end

local function validate(messageType, payload)
  return Protocol.Validate(Protocol.Build(messageType, payload, "id-1"))
end

local function store()
  local s = { rosters = {}, members = {}, tombstones = {}, clock = 10000 }
  function s.ctx()
    return {
      rosters = s.rosters,
      members = s.members,
      tombstones = s.tombstones,
      now = function()
        return s.clock
      end,
    }
  end
  return s
end

local function deliver(receiver, messageType, payload, sender, role)
  return RosterSync.Apply(receiver.ctx(), on_wire(messageType, payload), sender, role)
end

describe("Protocol roster messages", function()
  it("is at protocol 1.5", function()
    assert.are.equal(1, Constants.PROTOCOL_MAJOR)
    assert.are.equal(5, Constants.PROTOCOL_MINOR)
  end)

  it("accepts a clean roster upsert and delete, and drops unknown fields", function()
    local message =
      assert(validate("ROSTER_UPSERT", { rosterId = "r-1", name = "Main raid", rev = 1, updatedAt = 5, x = 1 }))
    assert.are.same({ rosterId = "r-1", name = "Main raid", rev = 1, updatedAt = 5 }, message.p)
    assert.are.same({ rosterId = "r-1", rev = 3 }, assert(validate("ROSTER_DELETE", { rosterId = "r-1", rev = 3 })).p)
  end)

  it("refuses a roster with a bad id, a bad name or a bad revision", function()
    local good = { rosterId = "r-1", name = "Main", rev = 1, updatedAt = 5 }
    local function with(change)
      local copy = {}
      for key, value in pairs(good) do
        copy[key] = value
      end
      for key, value in pairs(change) do
        copy[key] = value
      end
      return copy
    end
    for _, change in ipairs({
      { rosterId = "bad id" },
      { rosterId = "a:b" },
      { rosterId = 5 },
      { name = "" },
      { name = "|cffff0000Red" },
      { name = " padded " },
      { name = string.rep("x", Constants.ROSTER_NAME_MAX + 1) },
      { rev = 0 },
      { rev = 1.5 },
      { updatedAt = -1 },
    }) do
      local message, reason = validate("ROSTER_UPSERT", with(change))
      assert.is_nil(message)
      assert.are.equal("bad_payload", reason)
    end
    assert.is_nil(validate("ROSTER_DELETE", { rosterId = "r-1", rev = 0 }))
    assert.is_nil(validate("ROSTER_DELETE", { rosterId = "r 1", rev = 1 }))
  end)

  it("accepts a member upsert with and without a roster", function()
    local with =
      assert(validate("MEMBER_UPSERT", { key = "Yonemon Gg", role = "rl", rosterId = "r-1", rev = 1, updatedAt = 5 }))
    assert.are.same({ key = "Yonemon Gg", role = "rl", rosterId = "r-1", rev = 1, updatedAt = 5 }, with.p)
    local without = assert(validate("MEMBER_UPSERT", { key = "Ann-Realm", role = "member", rev = 2, updatedAt = 5 }))
    assert.is_nil(without.p.rosterId)
    assert.are.same({ key = "Ann-Realm", rev = 4 }, assert(validate("MEMBER_DELETE", { key = "Ann-Realm", rev = 4 })).p)
  end)

  it("never lets admin be assigned, and refuses anything that is not a role", function()
    for _, role in ipairs({ "admin", "root", "", 5, true }) do
      local message, reason = validate("MEMBER_UPSERT", { key = "Ann-Realm", role = role, rev = 1, updatedAt = 5 })
      assert.is_nil(message, tostring(role))
      assert.are.equal("bad_payload", reason)
    end
    assert.is_nil(validate("MEMBER_UPSERT", { key = "Ann-Realm", rev = 1, updatedAt = 5 }))
  end)

  it("refuses a member with a bad key or roster id", function()
    for _, key in ipairs({ "", "A:B", "|cffff0000X", string.rep("x", 65), 5 }) do
      assert.is_nil(validate("MEMBER_UPSERT", { key = key, role = "rl", rev = 1, updatedAt = 5 }), tostring(key))
      assert.is_nil(validate("MEMBER_DELETE", { key = key, rev = 1 }), tostring(key))
    end
    assert.is_nil(validate("MEMBER_UPSERT", { key = "Ann", role = "rl", rosterId = "a b", rev = 1, updatedAt = 5 }))
  end)

  it("keeps the profession flag of protocol 1.5 and tolerates its absence", function()
    local profile = {
      rev = 1,
      class = "MAGE",
      level = 60,
      professions = { { name = "Cooking", skill = 10, secondary = true }, { name = "Alchemy", skill = 300 } },
    }
    local message = assert(validate("PROFILE", profile))
    assert.is_true(message.p.professions[1].secondary)
    assert.is_nil(message.p.professions[2].secondary)
    profile.professions[1].secondary = "yes"
    assert.is_nil(validate("PROFILE", profile))
  end)

  it("keeps the roster of an event, and an old event without one still validates", function()
    local event =
      assert(validate("EVENT_UPSERT", { eventId = "e-1", rev = 1, updatedAt = 1, title = "Raid", rosterId = "r-1" }))
    assert.are.equal("r-1", event.p.rosterId)
    assert.is_nil(
      assert(validate("EVENT_UPSERT", { eventId = "e-1", rev = 1, updatedAt = 1, title = "Raid" })).p.rosterId
    )
    assert.is_nil(
      validate("EVENT_UPSERT", { eventId = "e-1", rev = 1, updatedAt = 1, title = "Raid", rosterId = "a b" })
    )
  end)
end)

describe("RosterSync.Apply", function()
  local receiver

  before_each(function()
    receiver = store()
  end)

  local function roster(overrides)
    local payload = { rosterId = "r-1", name = "Main", rev = 1, updatedAt = 100 }
    for key, value in pairs(overrides or {}) do
      payload[key] = value
    end
    return payload
  end

  local function member(overrides)
    local payload = { key = "Ann-Realm", role = "rl", rosterId = "r-1", rev = 1, updatedAt = 100 }
    for key, value in pairs(overrides or {}) do
      payload[key] = value
    end
    return payload
  end

  it("stores a roster and an assignment from the guild master, with the sender as the author", function()
    assert.is_true(deliver(receiver, "ROSTER_UPSERT", roster(), "Boss-Realm", "admin"))
    assert.are.same(
      { id = "r-1", name = "Main", rev = 1, updatedAt = 100, updatedBy = "Boss-Realm" },
      receiver.rosters["r-1"]
    )
    assert.is_true(deliver(receiver, "MEMBER_UPSERT", member(), "Boss-Realm", "admin"))
    local record = receiver.members["Ann-Realm"]
    assert.are.same({ "rl", "r-1", 1, "Boss-Realm" }, { record.role, record.rosterId, record.rev, record.updatedBy })
  end)

  it("refuses every role but admin, and a sender nobody knows", function()
    for _, role in ipairs({ "rl", "council", "member" }) do
      for _, case in ipairs({
        { "ROSTER_UPSERT", roster() },
        { "ROSTER_DELETE", { rosterId = "r-1", rev = 5 } },
        { "MEMBER_UPSERT", member() },
        { "MEMBER_DELETE", { key = "Ann-Realm", rev = 5 } },
      }) do
        assert.are.equal(
          "forbidden",
          select(2, deliver(receiver, case[1], case[2], "Sender-Realm", role)),
          role .. case[1]
        )
      end
    end
    assert.are.equal("unknown_sender", select(2, deliver(receiver, "MEMBER_UPSERT", member(), "Ghost-Realm", nil)))
    assert.is_nil(next(receiver.rosters))
    assert.is_nil(next(receiver.members))
  end)

  it("takes the newer revision, ignores an older or identical one, and clamps the time", function()
    assert.is_true(deliver(receiver, "ROSTER_UPSERT", roster({ rev = 2, name = "Two" }), "Boss-Realm", "admin"))
    assert.are.equal(
      "stale",
      select(2, deliver(receiver, "ROSTER_UPSERT", roster({ rev = 1, name = "One" }), "Boss-Realm", "admin"))
    )
    assert.are.equal(
      "stale",
      select(2, deliver(receiver, "ROSTER_UPSERT", roster({ rev = 2, name = "Two" }), "Boss-Realm", "admin"))
    )
    assert.are.equal("Two", receiver.rosters["r-1"].name)
    assert.is_true(deliver(receiver, "MEMBER_UPSERT", member({ updatedAt = 4000000000 }), "Boss-Realm", "admin"))
    assert.are.equal(receiver.clock + 300, receiver.members["Ann-Realm"].updatedAt)
  end)

  it("lets an assignment without a roster clear the roster", function()
    deliver(receiver, "MEMBER_UPSERT", member(), "Boss-Realm", "admin")
    local without = member({ rev = 2 })
    without.rosterId = nil
    assert.is_true(deliver(receiver, "MEMBER_UPSERT", without, "Boss-Realm", "admin"))
    assert.is_nil(receiver.members["Ann-Realm"].rosterId)
  end)

  it("deletes with a tombstone, and an older upsert cannot bring the record back", function()
    deliver(receiver, "ROSTER_UPSERT", roster(), "Boss-Realm", "admin")
    deliver(receiver, "MEMBER_UPSERT", member(), "Boss-Realm", "admin")
    assert.are.equal(
      "stale",
      select(2, deliver(receiver, "ROSTER_DELETE", { rosterId = "r-1", rev = 1 }, "Boss-Realm", "admin"))
    )
    assert.is_true(deliver(receiver, "ROSTER_DELETE", { rosterId = "r-1", rev = 2 }, "Boss-Realm", "admin"))
    assert.is_nil(receiver.rosters["r-1"])
    assert.are.equal(2, receiver.tombstones["R:r-1"].rev)
    assert.are.equal(
      "tombstoned",
      select(2, deliver(receiver, "ROSTER_UPSERT", roster({ rev = 2 }), "Boss-Realm", "admin"))
    )
    assert.is_true(deliver(receiver, "ROSTER_UPSERT", roster({ rev = 3 }), "Boss-Realm", "admin"))
    assert.is_nil(receiver.tombstones["R:r-1"])

    assert.is_true(deliver(receiver, "MEMBER_DELETE", { key = "Ann-Realm", rev = 2 }, "Boss-Realm", "admin"))
    assert.is_nil(receiver.members["Ann-Realm"])
    assert.are.equal(
      "tombstoned",
      select(2, deliver(receiver, "MEMBER_UPSERT", member({ rev = 2 }), "Boss-Realm", "admin"))
    )
    assert.are.equal(
      "stale",
      select(2, deliver(receiver, "MEMBER_DELETE", { key = "Ann-Realm", rev = 2 }, "Boss-Realm", "admin"))
    )
  end)

  it("remembers the deletion of something it never saw", function()
    assert.is_true(deliver(receiver, "MEMBER_DELETE", { key = "Ghost-Realm", rev = 4 }, "Boss-Realm", "admin"))
    assert.are.equal(4, receiver.tombstones["M:Ghost-Realm"].rev)
    assert.is_true(deliver(receiver, "ROSTER_DELETE", { rosterId = "ghost", rev = 4 }, "Boss-Realm", "admin"))
    assert.are.equal(4, receiver.tombstones["R:ghost"].rev)
  end)

  it("stops at the limits", function()
    for index = 1, Constants.ROSTERS_MAX do
      receiver.rosters["x" .. index] = { id = "x" .. index, name = "X" .. index, rev = 1 }
    end
    assert.are.equal("limit", select(2, deliver(receiver, "ROSTER_UPSERT", roster(), "Boss-Realm", "admin")))
    for index = 1, Constants.MEMBER_ASSIGNMENTS_MAX do
      receiver.members["M" .. index] = { role = "member", rev = 1 }
    end
    assert.are.equal("limit", select(2, deliver(receiver, "MEMBER_UPSERT", member(), "Boss-Realm", "admin")))
    assert.is_true(deliver(receiver, "MEMBER_UPSERT", member({ key = "M1", rev = 2 }), "Boss-Realm", "admin"))
  end)

  it("says which messages are roster messages and refuses others", function()
    for _, kind in ipairs({ "ROSTER_UPSERT", "ROSTER_DELETE", "MEMBER_UPSERT", "MEMBER_DELETE" }) do
      assert.is_true(RosterSync.IsRosterMessage(kind))
    end
    assert.is_false(RosterSync.IsRosterMessage("EVENT_UPSERT"))
    assert.are.same(
      { false, "unsupported" },
      { RosterSync.Apply(receiver.ctx(), { t = "PROFILE", p = {} }, "A", "admin") }
    )
  end)

  it("builds the payloads of local changes that the protocol accepts", function()
    local source = store()
    local sctx = {
      rosters = source.rosters,
      members = source.members,
      tombstones = source.tombstones,
      role = "admin",
      actor = "Boss-Realm",
      now = function()
        return 500
      end,
      newId = function()
        return "r-1"
      end,
    }
    local main = assert(ns.RosterService.Create(sctx, "Main"))
    local record = assert(ns.RosterService.Assign(sctx, "Ann-Realm", { role = "council", rosterId = main.id }))
    assert.is_true(deliver(receiver, "ROSTER_UPSERT", RosterSync.RosterPayload(main), "Boss-Realm", "admin"))
    assert.is_true(
      deliver(receiver, "MEMBER_UPSERT", RosterSync.MemberPayload("Ann-Realm", record), "Boss-Realm", "admin")
    )
    assert.are.equal("council", receiver.members["Ann-Realm"].role)

    assert.is_true(ns.RosterService.Unassign(sctx, "Ann-Realm"))
    assert.is_true(ns.RosterService.Delete(sctx, main.id))
    assert.is_true(
      deliver(
        receiver,
        "MEMBER_DELETE",
        RosterSync.DeleteMemberPayload(source.tombstones, "Ann-Realm"),
        "Boss-Realm",
        "admin"
      )
    )
    assert.is_true(
      deliver(
        receiver,
        "ROSTER_DELETE",
        RosterSync.DeleteRosterPayload(source.tombstones, main.id),
        "Boss-Realm",
        "admin"
      )
    )
    assert.is_nil(receiver.members["Ann-Realm"])
    assert.is_nil(receiver.rosters["r-1"])
    assert.is_nil(RosterSync.DeleteMemberPayload(source.tombstones, "Nobody"))
    assert.is_nil(RosterSync.DeleteRosterPayload(source.tombstones, "nope"))
  end)
end)

describe("Roster items in a snapshot", function()
  local function admin_store()
    local source = store()
    source.rosters["r-1"] = { id = "r-1", name = "Main", rev = 1, updatedAt = 10 }
    source.rosters["r-2"] = { id = "r-2", name = "Alts", rev = 2, updatedAt = 20 }
    for index = 1, 5 do
      source.members["M" .. index] = { role = "rl", rosterId = "r-1", rev = 1, updatedAt = 100 + index }
    end
    source.tombstones["M:Gone"] = { at = 5, rev = 3 }
    source.tombstones["R:old"] = { at = 6, rev = 2 }
    source.tombstones["E:other"] = { at = 7, rev = 2 }
    return source
  end

  it("lists every roster, the newest assignments up to the limit, and the removals", function()
    local items = RosterSync.SnapshotItems(admin_store().ctx(), 3)
    local kinds = {}
    for _, item in ipairs(items) do
      kinds[item.t] = (kinds[item.t] or 0) + 1
    end
    assert.are.same({ ROSTER_UPSERT = 2, MEMBER_UPSERT = 3, MEMBER_DELETE = 1, ROSTER_DELETE = 1 }, kinds)
    local newest
    for _, item in ipairs(items) do
      if item.t == "MEMBER_UPSERT" then
        newest = newest or item.p.key
      end
    end
    assert.are.equal("M5", newest)
  end)

  it("is applied by a late joiner only from an admin's snapshot", function()
    local source = admin_store()
    local items = ns.Transfer.BuildSnapshot({}, source.tombstones, 5, nil, nil, nil, nil, nil, source.ctx(), 10)

    local joiner = store()
    local ctx = joiner.ctx()
    ctx.events = {}
    local summary = ns.Transfer.ApplyItems(items, ctx, "Boss-Realm", "admin")
    assert.are.equal(9, summary.rosters)
    assert.are.equal("Alts", joiner.rosters["r-2"].name)
    assert.are.equal("rl", joiner.members["M3"].role)
    assert.are.equal(3, joiner.tombstones["M:Gone"].rev)

    local other = store()
    local otherCtx = other.ctx()
    otherCtx.events = {}
    local refused = ns.Transfer.ApplyItems(items, otherCtx, "Lead-Realm", "rl")
    assert.are.equal(0, refused.rosters)
    assert.are.equal(9, refused.skipped.forbidden)
    assert.is_nil(next(other.rosters))
    assert.is_nil(next(other.members))
  end)

  it("leaves the roster items out of a snapshot that is not an admin's, and out of a text export", function()
    local source = admin_store()
    local items = ns.Transfer.BuildSnapshot({}, source.tombstones, 5)
    for _, item in ipairs(items) do
      assert.is_nil(RosterSync.IsRosterMessage(item.t) and item.t or nil)
    end
    for _, item in ipairs(ns.Transfer.BuildItems({}, source.tombstones)) do
      assert.is_false(RosterSync.IsRosterMessage(item.t))
    end
    -- A text import has no roster tables, so a roster item in one is unsupported.
    local summary = ns.Transfer.ApplyItems(
      { { t = "ROSTER_UPSERT", p = { rosterId = "r-1", name = "Main", rev = 1, updatedAt = 1 } } },
      { events = {}, tombstones = {}, now = os.time },
      "import",
      "admin"
    )
    assert.are.equal(1, summary.skipped.unsupported)
  end)
end)

describe("Rosters through Comm", function()
  local function build_comm(role)
    local env =
      { sent = {}, roles = {}, changes = {}, rosters = {}, members = {}, events = {}, tombstones = {}, clock = 0 }
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
    env.queue = ns.OutboundQueue.New({
      guard = {
        CanSend = function()
          return true
        end,
      },
      now = function()
        return env.clock
      end,
      send = function(text, target)
        env.sent[#env.sent + 1] = { text = text, target = target }
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
      roster = {},
      events = env.events,
      tombstones = env.tombstones,
      rosters = env.rosters,
      members = env.members,
      onRosterChange = function(kind)
        env.changes[#env.changes + 1] = kind
      end,
      roleOf = function(sender)
        return env.roles[sender]
      end,
      ownRole = function()
        return role
      end,
      version = "0.1.0",
      now = function()
        return env.clock
      end,
      schedule = function() end,
      random = function(low)
        return low
      end,
    })
    function env.wire(messageType, payload, id)
      return env.codec:Encode(Protocol.Build(messageType, payload, id or "id-1"))
    end
    return env
  end

  it("applies a roster and an assignment from the guild master and tells the window", function()
    local env = build_comm("member")
    env.roles["Boss-Realm"] = "admin"
    local roster = env.wire("ROSTER_UPSERT", { rosterId = "r-1", name = "Main", rev = 1, updatedAt = 1 }, "m-1")
    assert.is_true(env.comm:HandleMessage(roster, "Boss-Realm", "GUILD"))
    local assignment =
      env.wire("MEMBER_UPSERT", { key = "Ann-Realm", role = "rl", rosterId = "r-1", rev = 1, updatedAt = 1 }, "m-2")
    assert.is_true(env.comm:HandleMessage(assignment, "Boss-Realm", "GUILD"))
    assert.are.equal("Main", env.rosters["r-1"].name)
    assert.are.equal("rl", env.members["Ann-Realm"].role)
    assert.are.same({ "ROSTER_UPSERT", "MEMBER_UPSERT" }, env.changes)
  end)

  it("refuses the same messages from a raid leader, an unknown sender and a forged admin role", function()
    local env = build_comm("member")
    env.roles["Lead-Realm"] = "rl"
    local text = env.wire("MEMBER_UPSERT", { key = "Lead-Realm", role = "council", rev = 1, updatedAt = 1 }, "m-1")
    assert.are.same({ false, "forbidden" }, { env.comm:HandleMessage(text, "Lead-Realm", "GUILD") })
    local unknown = env.wire("MEMBER_UPSERT", { key = "X-Realm", role = "rl", rev = 1, updatedAt = 1 }, "m-2")
    assert.are.same({ false, "unknown_sender" }, { env.comm:HandleMessage(unknown, "Ghost-Realm", "GUILD") })
    -- `admin` is not a role that can be assigned: the message does not even validate.
    env.roles["Boss-Realm"] = "admin"
    local forged = env.wire("MEMBER_UPSERT", { key = "Lead-Realm", role = "admin", rev = 1, updatedAt = 1 }, "m-3")
    assert.are.same({ false, "bad_payload" }, { env.comm:HandleMessage(forged, "Boss-Realm", "GUILD") })
    assert.is_nil(next(env.members))
    assert.are.same({}, env.changes)
  end)

  it("sends local changes as keyed messages that another client accepts", function()
    local env = build_comm("admin")
    local receiver = build_comm("member")
    receiver.roles["Boss-Realm"] = "admin"
    local commands = ns.RosterCommands.New({
      rosters = env.rosters,
      members = env.members,
      tombstones = env.tombstones,
      platform = {
        GetOwnGuildRank = function()
          return "Maestro", 0
        end,
        GetIdentityKey = function()
          return "Me-Realm"
        end,
        ServerTime = function()
          return 5000
        end,
      },
      comm = env.comm,
    })
    local lines = commands:CreateRoster("Main")
    assert.are.equal("created the roster 'Main'.", lines[1])
    local id = next(env.rosters)
    commands:AssignMember("Ann-Realm", { role = "rl", rosterId = id })
    commands:UnassignMember("Ann-Realm")
    commands:DeleteRoster(id)
    assert.are.equal(4, #env.sent)
    for _, sent in ipairs(env.sent) do
      assert.is_true(receiver.comm:HandleMessage(sent.text, "Boss-Realm", "GUILD"))
    end
    assert.is_nil(receiver.rosters[id])
    assert.is_nil(receiver.members["Ann-Realm"])
    assert.are.equal(2, receiver.tombstones["R:" .. id].rev)
    assert.are.same({ false, "no_tombstone" }, { env.comm:SendDeleteRoster("nope") })
    assert.are.same({ false, "no_tombstone" }, { env.comm:SendDeleteMember("nope") })
  end)

  it("puts the rosters and assignments in the snapshot an admin answers, and not in anybody else's", function()
    for _, role in ipairs({ "admin", "rl" }) do
      local env = build_comm(role)
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
      env.rosters["r-1"] = { id = "r-1", name = "Main", rev = 1, updatedAt = 1 }
      env.members["Ann-Realm"] = { role = "rl", rosterId = "r-1", rev = 1, updatedAt = 1 }
      assert.is_true(env.comm:SendSnapshot("Joiner-Realm"))
      local decoded = env.codec:Decode(env.sent[1].text, {
        encoded = Constants.SYNC_MAX_ENCODED_BYTES,
        decompressed = Constants.SYNC_MAX_DECOMPRESSED_BYTES,
      })
      local found = false
      for _, item in ipairs(decoded.p.items) do
        found = found or RosterSync.IsRosterMessage(item.t)
      end
      assert.are.equal(role == "admin", found, role)
    end
  end)

  it("applies a snapshot's roster items only when an admin sent it, and tells the window", function()
    local env = build_comm("member")
    env.roles["Boss-Realm"] = "admin"
    local items = { { t = "ROSTER_UPSERT", p = { rosterId = "r-1", name = "Main", rev = 1, updatedAt = 1 } } }
    local snapshot = env.wire("SYNC_DATA", { items = items }, "s-1")
    assert.is_true(env.comm:HandleMessage(snapshot, "Boss-Realm", "WHISPER"))
    assert.are.equal("Main", env.rosters["r-1"].name)
    assert.are.same({ "SYNC_DATA" }, env.changes)
  end)
end)

describe("RosterCommands", function()
  local env

  local function build(role)
    env = { rosters = {}, members = {}, tombstones = {}, sent = {}, counter = 0 }
    env.comm = {
      NextId = function()
        env.counter = env.counter + 1
        return "id" .. env.counter
      end,
    }
    for _, kind in ipairs({ "SendRoster", "SendDeleteRoster", "SendMember", "SendDeleteMember" }) do
      env.comm[kind] = function(_, ...)
        env.sent[#env.sent + 1] = { kind = kind, args = { ... } }
        return true
      end
    end
    ns.PermissionService.Configure({ members = {} })
    env.commands = ns.RosterCommands.New({
      rosters = env.rosters,
      members = env.members,
      tombstones = env.tombstones,
      platform = {
        GetOwnGuildRank = function()
          return "Rank", role == "admin" and 0 or 4
        end,
        GetIdentityKey = function()
          return "Me-Realm"
        end,
        ServerTime = function()
          return 1000
        end,
      },
      comm = env.comm,
      onChange = function()
        env.changed = (env.changed or 0) + 1
      end,
    })
    return env
  end

  it("creates, renames, assigns, unassigns and deletes, sending each change", function()
    build("admin")
    assert.are.equal("created the roster 'Main'.", env.commands:CreateRoster("Main")[1])
    local id = next(env.rosters)
    assert.are.equal("renamed the roster to 'Alts'.", env.commands:RenameRoster(id, "Alts")[1])
    assert.are.equal(
      "saved the role and roster of Ann-Realm.",
      env.commands:AssignMember("Ann-Realm", { role = "rl", rosterId = id })[1]
    )
    assert.are.equal("Ann-Realm is a plain member with no roster again.", env.commands:UnassignMember("Ann-Realm")[1])
    assert.are.equal("deleted the roster 'Alts'.", env.commands:DeleteRoster(id)[1])
    local kinds = {}
    for _, sent in ipairs(env.sent) do
      kinds[#kinds + 1] = sent.kind
    end
    assert.are.same({ "SendRoster", "SendRoster", "SendMember", "SendDeleteMember", "SendDeleteRoster" }, kinds)
    assert.are.equal(5, env.changed)
  end)

  it("says why it could not, and sends nothing", function()
    build("member")
    assert.are.equal("only the guild master can manage rosters and roles.", env.commands:CreateRoster("Main")[1])
    build("admin")
    assert.are.equal("give a plain-text roster name (up to 30 characters).", env.commands:CreateRoster("")[1])
    env.commands:CreateRoster("Main")
    assert.are.equal("there is a roster with that name already.", env.commands:CreateRoster("main")[1])
    assert.are.equal("that roster does not exist.", env.commands:AssignMember("Ann-Realm", { rosterId = "ghost" })[1])
    assert.are.equal(
      "a member can be assigned member, raid leader or loot council.",
      env.commands:AssignMember("Ann-Realm", { role = "admin" })[1]
    )
    assert.are.equal("not found.", env.commands:UnassignMember("Ann-Realm")[1])
    assert.are.equal("not found.", env.commands:DeleteRoster("ghost")[1])
    assert.are.equal(1, #env.sent)
  end)

  it("notes a change that was saved but could not be sent", function()
    build("admin")
    env.comm.SendRoster = function()
      return false, "full"
    end
    local lines = env.commands:CreateRoster("Main")
    assert.are.equal("saved here, but not sent to the guild (full).", lines[2])
  end)
end)
