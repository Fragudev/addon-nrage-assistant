local Roles = dofile("tests/support/roles.lua")

local function load_modules()
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
    "Commands/LootCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

local function text(lines)
  return table.concat(lines, "\n")
end

-- Fakes only the client and the transport; everything else is the real domain.
local function build(rank, options)
  options = options or {}
  local env = { events = {}, sent = {}, sendResult = { true }, counter = 0, locked = false }
  env.events["ev-1"] = {
    eventId = "ev-1",
    title = "Molten Core",
    status = "open",
    startAt = 1000,
    rev = 1,
    updatedAt = 1,
    attendance = {},
    assignments = {},
    loot = {},
  }
  env.platform = {
    GetOwnGuildRank = Roles.ranking(rank),
    GetIdentityKey = function()
      return options.identity or "Boss-Realm"
    end,
    ServerTime = function()
      return 1000
    end,
    IsChatMessagingLockedDown = function()
      return env.locked
    end,
  }
  env.comm = {}
  function env.comm.NextId()
    env.counter = env.counter + 1
    return "id" .. env.counter
  end
  for _, kind in ipairs({ "SendLootSession", "SendLootCandidate", "SendLootVote", "SendLootAward" }) do
    env.comm[kind] = function(_, ...)
      env.sent[#env.sent + 1] = { kind = kind, args = { ... } }
      return unpack(env.sendResult)
    end
  end
  env.members, env.rosters = Roles.assignments(rank, options.identity or "Boss-Realm")
  env.loot = ns.LootCommands.New({
    events = env.events,
    platform = env.platform,
    comm = env.comm,
    members = env.members,
    rosters = env.rosters,
  })
  return env
end

local LINK = "|cffff8000|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade]|h|r"

local function first_session(env)
  return ns.LootService.Sessions(env.events["ev-1"])[1]
end

local function event_of(env)
  return env.events["ev-1"]
end

local function open_session(env, id, name)
  return env.loot:OpenItem(event_of(env), { itemId = id or 19019, itemName = name or "Thunderfury" })
end

describe("LootCommands open", function()
  it("opens a session from a shift-clicked item link and sends it", function()
    local env = build("Council")
    local item = ns.LootCommands.ParseItem(LINK)
    local lines = text(env.loot:OpenItem(event_of(env), item))
    assert.is_truthy(lines:find("opened a session for Thunderfury, Blessed Blade", 1, true))
    local session = first_session(env)
    assert.are.equal(19019, session.itemId)
    assert.are.equal("Thunderfury, Blessed Blade", session.itemName)
    assert.are.equal("SendLootSession", env.sent[1].kind)
    assert.are.equal("ev-1", env.sent[1].args[1])
  end)

  it("opens a session from an item id and a name", function()
    local env = build("GM")
    local item = ns.LootCommands.ParseItem("19019 Thunderfury")
    assert.is_truthy(text(env.loot:OpenItem(event_of(env), item)):find("opened a session", 1, true))
    assert.are.equal("Thunderfury", first_session(env).itemName)
  end)

  it("cannot read an item that is not a link or an id and a name", function()
    for _, args in ipairs({ "", "Thunderfury", "0 ", "abc def", "|Hitem:5|h|h" }) do
      assert.is_nil(ns.LootCommands.ParseItem(args), args)
    end
  end)

  it("refuses to open a session while chat messaging is locked down", function()
    local env = build("Council")
    env.locked = true
    assert.is_truthy(text(open_session(env)):find("wait until the encounter ends", 1, true))
    assert.is_nil(first_session(env))
    assert.are.equal(0, #env.sent)
  end)

  it("tells a roster player, a member and an alter why they cannot open a session", function()
    for _, rank in ipairs({ "Roster", "member", "Alter" }) do
      local env = build(rank)
      assert.is_truthy(text(open_session(env)):find("not allowed", 1, true), rank)
      assert.are.equal(0, #env.sent)
    end
  end)

  it("reports when the change was saved but could not be queued", function()
    local env = build("Council")
    env.sendResult = { false, "full" }
    local lines = text(open_session(env))
    assert.is_truthy(lines:find("saved here, but not sent to the guild (full)", 1, true))
    assert.is_truthy(first_session(env))
  end)
end)

describe("LootCommands send failures", function()
  it("shows what the encoder reported, so a failure can be diagnosed", function()
    local env = build("Council")
    env.sendResult = { false, "encode_failed", "cannot serialize a function" }
    local lines = text(open_session(env))
    assert.is_truthy(lines:find("(encode_failed: cannot serialize a function)", 1, true))
  end)
end)

describe("LootCommands session flow", function()
  local env

  local function apply(fields)
    return env.loot:Apply(event_of(env), first_session(env), fields)
  end

  before_each(function()
    env = build("Council")
    open_session(env)
    env.sent = {}
  end)

  it("registers the actor as a candidate with an optional upgrade, and sends it", function()
    local lines = text(apply({ spec = "Fury", need = "main", upgrade = "Replaces my old axe" }))
    assert.is_truthy(lines:find("you are a candidate for Thunderfury (Fury, main).", 1, true))
    local candidate = first_session(env).candidates["Boss-Realm"]
    assert.are.equal("Replaces my old axe", candidate.upgrade)
    assert.are.equal("SendLootCandidate", env.sent[1].kind)
  end)

  it("rejects an invalid application", function()
    assert.is_truthy(text(apply({ spec = "Fury", need = "greed" })):find("invalid need", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("votes for a candidate and refuses a character who has not applied", function()
    apply({ spec = "Fury", need = "main" })
    env.sent = {}
    local event, session = event_of(env), first_session(env)
    assert.is_truthy(text(env.loot:VoteFor(event, session, "Boss-Realm")):find("voted for Boss-Realm", 1, true))
    assert.are.equal("SendLootVote", env.sent[1].kind)
    local refused = text(env.loot:VoteFor(event, session, "Nobody-Realm"))
    assert.is_truthy(refused:find("has not put themselves forward", 1, true))
    assert.are.equal(1, #env.sent)
  end)

  it("awards with a reason, closes the session and sends the award", function()
    apply({ spec = "Fury", need = "main" })
    env.sent = {}
    local event, session = event_of(env), first_session(env)
    local lines = text(env.loot:AwardTo(event, session, "Boss-Realm", "Highest need in the raid"))
    assert.is_truthy(lines:find("Thunderfury awarded to Boss-Realm", 1, true))
    assert.are.equal("SendLootAward", env.sent[1].kind)
    assert.are.equal("closed", first_session(env).status)
    assert.are.equal("Highest need in the raid", first_session(env).award.reason)
    assert.is_truthy(text(env.loot:VoteFor(event, session, "Boss-Realm")):find("already closed", 1, true))
  end)

  it("asks for a reason and for a candidate before awarding", function()
    apply({ spec = "Fury", need = "main" })
    local event, session = event_of(env), first_session(env)
    assert.is_truthy(text(env.loot:AwardTo(event, session, "Boss-Realm", "")):find("invalid", 1, true))
    local refused = text(env.loot:AwardTo(event, session, "Nobody-Realm", "why"))
    assert.is_truthy(refused:find("has not put themselves forward", 1, true))
    assert.are.equal("open", first_session(env).status)
  end)

  it("closes a session without awarding and sends the closed session", function()
    local lines = text(env.loot:CloseSession(event_of(env), first_session(env)))
    assert.is_truthy(lines:find("without awarding", 1, true))
    assert.are.equal("SendLootSession", env.sent[1].kind)
    assert.are.equal("closed", env.sent[1].args[2].status)
  end)

  it("a roster player can apply but cannot vote, award or close", function()
    local member = build("Roster", { identity = "Ann-Realm" })
    local session = {
      sessionId = "s1",
      itemId = 1,
      itemName = "Item",
      status = "open",
      candidates = {},
      votes = {},
      rev = 1,
    }
    member.events["ev-1"].loot["s1"] = session
    local event = member.events["ev-1"]
    assert.is_truthy(
      text(member.loot:Apply(event, session, { spec = "Fury", need = "main" })):find("you are a candidate", 1, true)
    )
    for _, lines in ipairs({
      member.loot:VoteFor(event, session, "Ann-Realm"),
      member.loot:AwardTo(event, session, "Ann-Realm", "why"),
      member.loot:CloseSession(event, session),
    }) do
      assert.is_truthy(text(lines):find("not allowed", 1, true))
    end
    assert.are.equal("open", session.status)
  end)

  it("a member and an alter cannot apply", function()
    for _, rank in ipairs({ "member", "Alter" }) do
      local denied = build(rank, { identity = "Ann-Realm" })
      local session =
        { sessionId = "s1", itemId = 1, itemName = "Item", status = "open", candidates = {}, votes = {}, rev = 1 }
      denied.events["ev-1"].loot["s1"] = session
      local lines = text(denied.loot:Apply(denied.events["ev-1"], session, { spec = "Fury", need = "main" }))
      assert.is_truthy(lines:find("not allowed", 1, true), rank)
      assert.is_nil(next(session.candidates))
      assert.are.equal(0, #denied.sent)
    end
  end)

  it("votes for and awards a character whose name has several words", function()
    local spaced = build("Council", { identity = "Yonemon Gg" })
    open_session(spaced)
    local event, session = event_of(spaced), first_session(spaced)
    spaced.loot:Apply(event, session, { spec = "Fury", need = "main" })
    spaced.sent = {}
    assert.is_truthy(text(spaced.loot:VoteFor(event, session, "Yonemon Gg")):find("voted for Yonemon Gg", 1, true))
    assert.are.equal("Yonemon Gg", spaced.sent[1].args[3].target)
    local lines = text(spaced.loot:AwardTo(event, session, "Yonemon Gg", "Highest need in the raid"))
    assert.is_truthy(lines:find("Thunderfury awarded to Yonemon Gg", 1, true))
    assert.are.equal("Yonemon Gg", first_session(spaced).award.characterKey)
  end)
end)

describe("LootCommands structured operations", function()
  local function open_and_get(env)
    env.loot:OpenItem(env.events["ev-1"], { itemId = 19019, itemName = "Thunderfury" })
    return ns.LootService.Sessions(env.events["ev-1"])[1]
  end

  it("opens a session, applies, votes, awards and sends each change", function()
    local env = build("GM")
    local event = env.events["ev-1"]
    local session = open_and_get(env)
    assert.are.equal("Thunderfury", session.itemName)

    local applied = text(env.loot:Apply(event, session, { spec = "Fury", need = "main", upgrade = "+12 ilvl" }))
    assert.is_truthy(applied:find("you are a candidate for Thunderfury (Fury, main).", 1, true))
    assert.is_truthy(text(env.loot:VoteFor(event, session, "Boss-Realm")):find("voted for Boss-Realm", 1, true))
    assert.is_truthy(text(env.loot:AwardTo(event, session, "Boss-Realm", "highest need")):find("awarded to", 1, true))
    assert.are.equal("closed", session.status)
    assert.are.equal(4, #env.sent)
  end)

  it("closes a session without awarding it", function()
    local env = build("GM")
    local session = open_and_get(env)
    assert.is_truthy(text(env.loot:CloseSession(env.events["ev-1"], session)):find("without awarding", 1, true))
    assert.are.equal("closed", session.status)
    assert.is_nil(session.award)
  end)

  it("rejects a bad need and keeps the role checks", function()
    local env = build("GM")
    local session = open_and_get(env)
    local event = env.events["ev-1"]
    assert.is_truthy(
      text(env.loot:Apply(event, session, { spec = "Fury", need = "greed" })):find("invalid need", 1, true)
    )

    local member = build("member")
    assert.is_truthy(
      text(member.loot:OpenItem(member.events["ev-1"], { itemId = 1, itemName = "Item" })):find("not allowed", 1, true)
    )
    assert.is_nil(next(member.events["ev-1"].loot))
  end)

  it("reads an item link the way the open command does", function()
    local item = ns.LootCommands.ParseItem("|cffa335ee|Hitem:19019::::|h[Thunderfury]|h|r")
    assert.are.same({ itemId = 19019, itemName = "Thunderfury" }, item)
    assert.is_nil(ns.LootCommands.ParseItem("not an item"))
  end)
end)

describe("LootCommands onChange", function()
  local function with_callback(env)
    local calls = 0
    env.loot = ns.LootCommands.New({
      events = env.events,
      platform = env.platform,
      comm = env.comm,
      members = env.members,
      rosters = env.rosters,
      onChange = function()
        calls = calls + 1
      end,
    })
    return function()
      return calls
    end
  end

  it("is called after each change made here, and not after a refused one", function()
    local env = build("Council")
    local calls = with_callback(env)
    local event = env.events["ev-1"]
    env.loot:OpenItem(event, { itemId = 19019, itemName = "Thunderfury" })
    assert.are.equal(1, calls())
    local session = ns.LootService.Sessions(event)[1]
    env.loot:Apply(event, session, { spec = "Fury", need = "main" })
    env.loot:VoteFor(event, session, "Boss-Realm")
    env.loot:AwardTo(event, session, "Boss-Realm", "highest need")
    assert.are.equal(4, calls())

    env.loot:CloseSession(event, session)
    assert.are.equal(4, calls())
  end)

  it("works without a callback", function()
    local env = build("Council")
    assert.is_truthy(text(env.loot:OpenItem(env.events["ev-1"], { itemId = 1, itemName = "Item" })))
  end)
end)
