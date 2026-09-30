local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants", "Core/Validate", "Core/Args", "Domain/PermissionService", "Domain/EventModel",
    "Domain/EventService", "Domain/LootModel", "Domain/LootService", "Commands/LootCommands",
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
    eventId = "ev-1", title = "Molten Core", status = "open", startAt = 1000, rev = 1, updatedAt = 1,
    attendance = {}, assignments = {}, loot = {},
  }
  env.platform = {
    GetOwnGuildRank = function() return rank end,
    GetIdentityKey = function() return options.identity or "Boss-Realm" end,
    ServerTime = function() return 1000 end,
    IsChatMessagingLockedDown = function() return env.locked end,
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
  env.loot = ns.LootCommands.New({ events = env.events, platform = env.platform, comm = env.comm })
  return env
end

local LINK = "|cffff8000|Hitem:19019::::::::60:::::|h[Thunderfury, Blessed Blade]|h|r"

local function first_session(env)
  return ns.LootService.Sessions(env.events["ev-1"])[1]
end

describe("LootCommands open", function()
  it("opens a session from a shift-clicked item link and sends it", function()
    local env = build("Council")
    local lines = text(env.loot:Loot("1 open " .. LINK))
    assert.is_truthy(lines:find("opened a session for Thunderfury, Blessed Blade", 1, true))
    local session = first_session(env)
    assert.are.equal(19019, session.itemId)
    assert.are.equal("Thunderfury, Blessed Blade", session.itemName)
    assert.are.equal("SendLootSession", env.sent[1].kind)
    assert.are.equal("ev-1", env.sent[1].args[1])
  end)

  it("opens a session from an item id and a name", function()
    local env = build("GM")
    assert.is_truthy(text(env.loot:Loot("1 open 19019 Thunderfury")):find("opened a session", 1, true))
    assert.are.equal("Thunderfury", first_session(env).itemName)
  end)

  it("explains what to give when the item cannot be read, and sends nothing", function()
    local env = build("Council")
    for _, args in ipairs({ "", "Thunderfury", "0 ", "abc def" }) do
      assert.is_truthy(text(env.loot:Loot("1 open " .. args)):find("give an item link", 1, true), args)
    end
    assert.is_truthy(text(env.loot:Loot("1 open |Hitem:5|h|h")):find("give an item link", 1, true))
    assert.are.equal(0, #env.sent)
    assert.is_nil(first_session(env))
  end)

  it("refuses to open a session while chat messaging is locked down", function()
    local env = build("Council")
    env.locked = true
    assert.is_truthy(text(env.loot:Loot("1 open " .. LINK)):find("wait until the encounter ends", 1, true))
    assert.is_nil(first_session(env))
    assert.are.equal(0, #env.sent)
  end)

  it("tells a member and a raid leader why they cannot open a session", function()
    for _, rank in ipairs({ "member", "RL" }) do
      local env = build(rank)
      local lines = text(env.loot:Loot("1 open " .. LINK))
      assert.is_truthy(lines:find("not allowed", 1, true), rank)
      assert.are.equal(0, #env.sent)
    end
  end)

  it("reports when the change was saved but could not be queued", function()
    local env = build("Council")
    env.sendResult = { false, "full" }
    local lines = text(env.loot:Loot("1 open " .. LINK))
    assert.is_truthy(lines:find("saved here, but not sent to the guild (full)", 1, true))
    assert.is_truthy(first_session(env))
  end)
end)

describe("LootCommands session flow", function()
  local env

  before_each(function()
    env = build("Council")
    env.loot:Loot("1 open 19019 Thunderfury")
    env.sent = {}
  end)

  it("registers the actor as a candidate with an optional upgrade, and sends it", function()
    local lines = text(env.loot:Loot("1 1 apply Fury main Replaces my old axe"))
    assert.is_truthy(lines:find("you are a candidate for Thunderfury (Fury, main)", 1, true))
    local candidate = first_session(env).candidates["Boss-Realm"]
    assert.are.equal("Replaces my old axe", candidate.upgrade)
    assert.are.equal("SendLootCandidate", env.sent[1].kind)
  end)

  it("rejects a malformed or invalid application", function()
    assert.is_truthy(text(env.loot:Loot("1 1 apply Fury")):find("usage:", 1, true))
    assert.is_truthy(text(env.loot:Loot("1 1 apply Fury greed")):find("invalid need", 1, true))
    assert.are.equal(0, #env.sent)
  end)

  it("votes for a candidate and refuses a character who has not applied", function()
    env.loot:Loot("1 1 apply Fury main")
    env.sent = {}
    assert.is_truthy(text(env.loot:Loot("1 1 vote Boss-Realm")):find("voted for Boss-Realm", 1, true))
    assert.are.equal("SendLootVote", env.sent[1].kind)
    assert.is_truthy(text(env.loot:Loot("1 1 vote Nobody-Realm")):find("has not put themselves forward", 1, true))
    assert.are.equal(1, #env.sent)
  end)

  it("awards with a reason, closes the session and sends the award", function()
    env.loot:Loot("1 1 apply Fury main")
    env.sent = {}
    local lines = text(env.loot:Loot("1 1 award Boss-Realm Highest need in the raid"))
    assert.is_truthy(lines:find("Thunderfury awarded to Boss-Realm", 1, true))
    assert.are.equal("SendLootAward", env.sent[1].kind)
    assert.are.equal("closed", first_session(env).status)
    assert.are.equal("Highest need in the raid", first_session(env).award.reason)
    assert.is_truthy(text(env.loot:Loot("1 1 vote Boss-Realm")):find("already closed", 1, true))
  end)

  it("asks for a reason and for a candidate before awarding", function()
    env.loot:Loot("1 1 apply Fury main")
    assert.is_truthy(text(env.loot:Loot("1 1 award Boss-Realm")):find("usage:", 1, true))
    assert.is_truthy(text(env.loot:Loot("1 1 award Nobody-Realm why")):find("has not put themselves forward", 1, true))
    assert.are.equal("open", first_session(env).status)
  end)

  it("closes a session without awarding and sends the closed session", function()
    local lines = text(env.loot:Loot("1 1 close"))
    assert.is_truthy(lines:find("without awarding", 1, true))
    assert.are.equal("SendLootSession", env.sent[1].kind)
    assert.are.equal("closed", env.sent[1].args[2].status)
  end)

  it("shows a session with its candidates, votes and the privacy warning", function()
    env.loot:Loot("1 1 apply Fury main Better axe")
    env.loot:Loot("1 1 vote Boss-Realm")
    local lines = text(env.loot:Loot("1 1"))
    assert.is_truthy(lines:find("Thunderfury [open]", 1, true))
    assert.is_truthy(lines:find("Boss-Realm: Fury, main - Better axe", 1, true))
    assert.is_truthy(lines:find("votes: Boss-Realm 1", 1, true))
    assert.is_truthy(lines:find("not private", 1, true))
  end)

  it("hides vote counts while open under a secret policy", function()
    local saved = ns.Constants.VOTE_VISIBILITY
    ns.Constants.VOTE_VISIBILITY = "secret"
    env.loot:Loot("1 1 apply Fury main")
    env.loot:Loot("1 1 vote Boss-Realm")
    local open = text(env.loot:Loot("1 1"))
    env.loot:Loot("1 1 close")
    local closed = text(env.loot:Loot("1 1"))
    ns.Constants.VOTE_VISIBILITY = saved

    assert.is_truthy(open:find("1 vote(s) cast (hidden until the session closes)", 1, true))
    assert.is_nil(open:find("Boss-Realm 1", 1, true))
    assert.is_truthy(closed:find("votes: Boss-Realm 1", 1, true))
  end)

  it("a member can apply but cannot vote, award or close", function()
    local member = build("member", { identity = "Ann-Realm" })
    member.events["ev-1"].loot["s1"] = {
      sessionId = "s1", itemId = 1, itemName = "Item", status = "open", candidates = {}, votes = {}, rev = 1,
    }
    assert.is_truthy(text(member.loot:Loot("1 1 apply Fury main")):find("you are a candidate", 1, true))
    for _, command in ipairs({ "1 1 vote Ann-Realm", "1 1 award Ann-Realm why", "1 1 close" }) do
      assert.is_truthy(text(member.loot:Loot(command)):find("not allowed", 1, true), command)
    end
    assert.are.equal("open", member.events["ev-1"].loot["s1"].status)
  end)
end)

describe("LootCommands lists, minutes and errors", function()
  it("explains an empty session list", function()
    local env = build("Council")
    assert.is_truthy(text(env.loot:Loot("1")):find("No loot sessions", 1, true))
  end)

  it("lists sessions by number with their outcome", function()
    local env = build("Council")
    env.loot:Loot("1 open 2 Beta")
    env.loot:Loot("1 open 1 Alpha")
    env.loot:Loot("1 1 apply Fury main")
    env.loot:Loot("1 1 award Boss-Realm Highest need")
    local lines = env.loot:Loot("1")
    assert.are.equal("  1. Alpha [closed] - awarded to Boss-Realm", lines[2])
    assert.are.equal("  2. Beta [open]", lines[3])
  end)

  it("prints the minutes of an event", function()
    local env = build("Council")
    assert.is_truthy(text(env.loot:Loot("acta 1")):find("No closed loot sessions", 1, true))

    env.loot:Loot("1 open 1 Alpha")
    env.loot:Loot("1 1 apply Fury main")
    env.loot:Loot("1 1 award Boss-Realm Highest need")
    env.loot:Loot("1 open 2 Beta")
    env.loot:Loot("1 2 close")
    local lines = env.loot:Loot("acta 1")
    assert.are.equal("  Alpha -> Boss-Realm (by Boss-Realm): Highest need", lines[2])
    assert.are.equal("  Beta -> not awarded", lines[3])
  end)

  it("gives clear errors for a bad event or session number and shows the usage", function()
    local env = build("Council")
    assert.is_truthy(text(env.loot:Loot("x")):find("give the event number", 1, true))
    assert.is_truthy(text(env.loot:Loot("7")):find("give the event number", 1, true))
    assert.is_truthy(text(env.loot:Loot("1 9")):find("no session number 9", 1, true))
    assert.is_truthy(text(env.loot:Loot("acta x")):find("give the event number", 1, true))
    assert.is_truthy(text(env.loot:Loot("")):find("usage:", 1, true))
    assert.is_truthy(text(env.loot:Loot("help")):find("/nrage loot acta", 1, true))
    env.loot:Loot("1 open 1 Alpha")
    assert.is_truthy(text(env.loot:Loot("1 1 dance")):find("usage:", 1, true))
  end)
end)

describe("LootCommands character names with spaces", function()
  local env

  before_each(function()
    env = build("Council", { identity = "Yonemon Gg" })
    env.loot:Loot("1 open 19019 Thunderfury")
    env.loot:Loot("1 1 apply Fury main")
    env.sent = {}
  end)

  it("votes for a name with spaces, quoted or not", function()
    assert.is_truthy(text(env.loot:Loot("1 1 vote Yonemon Gg")):find("voted for Yonemon Gg", 1, true))
    assert.is_truthy(text(env.loot:Loot('1 1 vote "Yonemon Gg"')):find("voted for Yonemon Gg", 1, true))
    assert.are.equal("Yonemon Gg", env.sent[1].args[3].target)
  end)

  it("awards to a quoted name with spaces, taking the rest as the reason", function()
    local lines = text(env.loot:Loot('1 1 award "Yonemon Gg" Highest need in the raid'))
    assert.is_truthy(lines:find("Thunderfury awarded to Yonemon Gg", 1, true))
    assert.are.equal("Yonemon Gg", first_session(env).award.characterKey)
    assert.are.equal("Highest need in the raid", first_session(env).award.reason)
  end)

  it("asks for a reason, and explains the quotes, when the award is malformed", function()
    for _, args in ipairs({ '"Yonemon Gg"', '"Yonemon Gg', "" }) do
      local lines = text(env.loot:Loot("1 1 award " .. args))
      assert.is_truthy(lines:find("usage:", 1, true), args)
      assert.is_truthy(lines:find("quotes", 1, true), args)
    end
    assert.are.equal("open", first_session(env).status)
  end)
end)
