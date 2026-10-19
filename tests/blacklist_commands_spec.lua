local Roles = dofile("tests/support/roles.lua")

local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/BlacklistService",
    "UI/ViewModel",
    "Commands/BlacklistCommands",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

-- Fakes only the client (platform) and the transport (comm); everything else is the real domain.
local function build(rank)
  local env = { blacklist = {}, tombstones = {}, sent = {}, sendResult = { true }, changes = 0 }
  env.platform = {
    GetOwnGuildRank = Roles.ranking(rank),
    GetIdentityKey = function()
      return "Me-Realm"
    end,
    ServerTime = function()
      return 1000
    end,
    FormatDate = function(timestamp)
      return "date:" .. timestamp
    end,
  }
  env.comm = {
    SendBlacklistUpsert = function(_, key, entry)
      env.sent[#env.sent + 1] = { kind = "upsert", key = key, entry = entry }
      return unpack(env.sendResult)
    end,
    SendBlacklistDelete = function(_, key)
      env.sent[#env.sent + 1] = { kind = "delete", key = key }
      return unpack(env.sendResult)
    end,
  }
  env.members = Roles.assignments(rank, "Me-Realm")
  ns.PermissionService.Configure({ members = env.members })
  env.commands = ns.BlacklistCommands.New({
    blacklist = env.blacklist,
    tombstones = env.tombstones,
    platform = env.platform,
    comm = env.comm,
    onChange = function()
      env.changes = env.changes + 1
    end,
  })
  return env
end

local function text(lines)
  local parts = {}
  for _, line in ipairs(lines) do
    parts[#parts + 1] = line
  end
  return table.concat(parts, "\n")
end

describe("BlacklistCommands add", function()
  it("adds a player for a plain member, sends it and reports the change", function()
    local env = build("member")
    local lines = env.commands:Add("Yonemon Gg", "stole loot")
    assert.is_truthy(text(lines):find("added Yonemon Gg", 1, true))
    assert.are.equal("stole loot", env.blacklist.yonemongg.reason)
    assert.are.equal("Me-Realm", env.blacklist.yonemongg.addedBy)
    assert.are.equal(1, #env.sent)
    assert.are.equal("upsert", env.sent[1].kind)
    assert.are.equal("yonemongg", env.sent[1].key)
    assert.are.equal(1, env.changes)
  end)

  it("explains what is wrong with the input", function()
    local env = build("member")
    assert.is_truthy(text(env.commands:Add("", "reason")):find("name", 1, true))
    assert.is_truthy(text(env.commands:Add("Ann", "")):find("reason", 1, true))
    assert.is_truthy(text(env.commands:Add("Ann", ("r"):rep(101))):find("too long", 1, true))
    assert.is_nil(next(env.blacklist))
    assert.are.equal(0, #env.sent)
    assert.are.equal(0, env.changes)
  end)

  it("changes the reason when the one who added the player adds them again", function()
    local env = build("member")
    env.commands:Add("Ann", "one")
    local lines = env.commands:Add("ann", "two")
    assert.is_truthy(text(lines):find("changed the reason of Ann", 1, true))
    assert.are.equal("two", env.blacklist.ann.reason)
    assert.are.equal(2, env.sent[2].entry.rev)
  end)

  it("refuses to change the reason of a player somebody else added", function()
    local env = build("member")
    env.blacklist.ann = { name = "Ann", reason = "one", addedBy = "Other-Realm", addedAt = 1, rev = 1, updatedAt = 1 }
    assert.is_truthy(text(env.commands:Add("ann", "two")):find("only the member who added", 1, true))
    assert.are.equal("one", env.blacklist.ann.reason)
    assert.are.equal(0, #env.sent)
  end)

  it("lets an officer change the reason of any player", function()
    local env = build("officer")
    env.blacklist.ann = { name = "Ann", reason = "one", addedBy = "Other-Realm", addedAt = 1, rev = 1, updatedAt = 1 }
    env.commands:Add("ann", "two")
    assert.are.equal("two", env.blacklist.ann.reason)
  end)

  it("refuses when the guild rank gives no role", function()
    local env = build(nil)
    assert.is_truthy(text(env.commands:Add("Ann", "x")):find("not allowed", 1, true))
    assert.is_nil(next(env.blacklist))
  end)

  it("says when it was saved here but could not be sent", function()
    local env = build("member")
    env.sendResult = { false, "full" }
    local lines = env.commands:Add("Ann", "x")
    assert.is_truthy(text(lines):find("not sent to the guild (full)", 1, true))
    assert.is_truthy(env.blacklist.ann)
  end)

  it("refuses a name with a text escape", function()
    local env = build("member")
    local lines = env.commands:Add("An|n", "x")
    assert.is_truthy(text(lines):find("valid name", 1, true))
  end)

  it("stops at the limit", function()
    local env = build("member")
    for index = 1, ns.Constants.BLACKLIST_MAX do
      env.blacklist["p" .. index] = { name = "P" .. index }
    end
    assert.is_truthy(text(env.commands:Add("One More", "x")):find("full", 1, true))
  end)
end)

describe("BlacklistCommands remove", function()
  local function listed(rank)
    local env = build(rank)
    env.blacklist.yonemongg = { name = "Yonemon Gg", reason = "x", rev = 1, updatedAt = 1, addedBy = "Ann-Realm" }
    return env
  end

  it("lets an admin remove a player, leaves a tombstone and sends the removal", function()
    local env = listed("GM")
    local lines = env.commands:Remove("Yonemon Gg")
    assert.is_truthy(text(lines):find("removed Yonemon Gg", 1, true))
    assert.is_nil(env.blacklist.yonemongg)
    assert.are.equal(2, env.tombstones["B:yonemongg"].rev)
    assert.are.equal("delete", env.sent[1].kind)
    assert.are.equal("yonemongg", env.sent[1].key)
    assert.are.equal(1, env.changes)
  end)

  it("accepts a key and a realm suffix", function()
    local env = listed("Officer")
    env.commands:Remove("yonemongg")
    assert.is_nil(env.blacklist.yonemongg)
    env = listed("Officer")
    env.commands:Remove("Yonemon Gg-ClassicBetaPvP")
    assert.is_nil(env.blacklist.yonemongg)
  end)

  it("tells everyone else that only admins can remove, whether or not the player is listed", function()
    for _, rank in ipairs({ "member", "RL", "council" }) do
      local env = listed(rank)
      assert.is_truthy(text(env.commands:Remove("Yonemon Gg")):find("only the guild master and officers", 1, true))
      assert.is_truthy(text(env.commands:Remove("Ghost")):find("only the guild master and officers", 1, true))
      assert.is_truthy(env.blacklist.yonemongg)
      assert.are.equal(0, #env.sent)
      assert.are.equal(0, env.changes)
    end
  end)

  it("reports a player who is not listed", function()
    local env = listed("GM")
    assert.is_truthy(text(env.commands:Remove("Ghost")):find("not on the blacklist", 1, true))
  end)

  it("says when the removal could not be sent", function()
    local env = listed("GM")
    env.sendResult = { false, "full" }
    assert.is_truthy(text(env.commands:Remove("yonemongg")):find("not sent to the guild", 1, true))
    assert.is_nil(env.blacklist.yonemongg)
  end)
end)

describe("BlacklistCommands without a change callback", function()
  it("works without a change callback", function()
    local env = build("member")
    local commands = ns.BlacklistCommands.New({
      blacklist = env.blacklist,
      tombstones = env.tombstones,
      platform = env.platform,
      comm = env.comm,
    })
    assert.is_truthy(text(commands:Add("Ann", "x")):find("added", 1, true))
  end)
end)
