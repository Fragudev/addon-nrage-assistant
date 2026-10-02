local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Core/Args",
    "Domain/PvPService",
    "Domain/PermissionService",
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
    GetOwnGuildRank = function()
      return rank
    end,
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
    local lines = env.commands:Blacklist("add Yonemon Gg | stole loot")
    assert.is_truthy(text(lines):find("added Yonemon Gg", 1, true))
    assert.are.equal("stole loot", env.blacklist.yonemongg.reason)
    assert.are.equal("Me-Realm", env.blacklist.yonemongg.addedBy)
    assert.are.equal(1, #env.sent)
    assert.are.equal("upsert", env.sent[1].kind)
    assert.are.equal("yonemongg", env.sent[1].key)
    assert.are.equal(1, env.changes)
  end)

  it("accepts a name in quotes", function()
    local env = build("member")
    env.commands:Blacklist('add "Black Coffee" | afk')
    assert.is_truthy(env.blacklist.blackcoffee)
  end)

  it("explains what is wrong with the input", function()
    local env = build("member")
    assert.is_truthy(text(env.commands:Blacklist("add Ann")):find("usage", 1, true))
    assert.is_truthy(text(env.commands:Blacklist("add | reason")):find("name", 1, true))
    assert.is_truthy(text(env.commands:Blacklist("add Ann |")):find("reason", 1, true))
    assert.is_truthy(text(env.commands:Blacklist("add Ann | " .. ("r"):rep(101))):find("too long", 1, true))
    assert.is_nil(next(env.blacklist))
    assert.are.equal(0, #env.sent)
    assert.are.equal(0, env.changes)
  end)

  it("refuses a player who is already listed", function()
    local env = build("member")
    env.commands:Blacklist("add Ann | one")
    assert.is_truthy(text(env.commands:Blacklist("add ann | two")):find("already", 1, true))
    assert.are.equal("one", env.blacklist.ann.reason)
  end)

  it("refuses when the guild rank gives no role", function()
    local env = build(nil)
    assert.is_truthy(text(env.commands:Blacklist("add Ann | x")):find("not allowed", 1, true))
    assert.is_nil(next(env.blacklist))
  end)

  it("says when it was saved here but could not be sent", function()
    local env = build("member")
    env.sendResult = { false, "full" }
    local lines = env.commands:Blacklist("add Ann | x")
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
    assert.is_truthy(text(env.commands:Blacklist("add One More | x")):find("full", 1, true))
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
    local lines = env.commands:Blacklist("remove Yonemon Gg")
    assert.is_truthy(text(lines):find("removed Yonemon Gg", 1, true))
    assert.is_nil(env.blacklist.yonemongg)
    assert.are.equal(2, env.tombstones["B:yonemongg"].rev)
    assert.are.equal("delete", env.sent[1].kind)
    assert.are.equal("yonemongg", env.sent[1].key)
    assert.are.equal(1, env.changes)
  end)

  it("accepts a key, quotes and a realm suffix", function()
    local env = listed("Officer")
    env.commands:Remove("yonemongg")
    assert.is_nil(env.blacklist.yonemongg)
    env = listed("Officer")
    env.commands:Blacklist('remove "Yonemon Gg-ClassicBetaPvP"')
    assert.is_nil(env.blacklist.yonemongg)
  end)

  it("tells everyone else that only admins can remove, whether or not the player is listed", function()
    for _, rank in ipairs({ "member", "RL", "council" }) do
      local env = listed(rank)
      assert.is_truthy(
        text(env.commands:Blacklist("remove Yonemon Gg")):find("only the guild master and officers", 1, true)
      )
      assert.is_truthy(text(env.commands:Blacklist("remove Ghost")):find("only the guild master and officers", 1, true))
      assert.is_truthy(env.blacklist.yonemongg)
      assert.are.equal(0, #env.sent)
      assert.are.equal(0, env.changes)
    end
  end)

  it("reports a player who is not listed", function()
    local env = listed("GM")
    assert.is_truthy(text(env.commands:Blacklist("remove Ghost")):find("not on the blacklist", 1, true))
  end)

  it("says when the removal could not be sent", function()
    local env = listed("GM")
    env.sendResult = { false, "full" }
    assert.is_truthy(text(env.commands:Remove("yonemongg")):find("not sent to the guild", 1, true))
    assert.is_nil(env.blacklist.yonemongg)
  end)
end)

describe("BlacklistCommands list and usage", function()
  it("lists the players sorted by name with the author and the date", function()
    local env = build("member")
    env.blacklist.zed = { name = "Zed", reason = "ninja", addedBy = "Ann-Realm", addedAt = 5 }
    env.blacklist.ann = { name = "Ann", reason = "afk", addedBy = "Bob-Realm", addedAt = 6 }
    local lines = env.commands:Blacklist("")
    assert.are.equal("2 player(s) on the blacklist:", lines[1])
    assert.are.equal("  Ann - afk (added by Bob-Realm, date:6)", lines[2])
    assert.are.equal("  Zed - ninja (added by Ann-Realm, date:5)", lines[3])
    assert.are.same(lines, env.commands:Blacklist("list"))
  end)

  it("escapes what it lists", function()
    local env = build("member")
    env.blacklist.x = { name = "|cffff0000X", reason = "|r", addedBy = "|H", addedAt = 1 }
    local line = env.commands:List()[2]
    assert.is_nil(line:find("[^|]|[^|]"))
  end)

  it("says the list is empty", function()
    assert.is_truthy(text(build("member").commands:List()):find("empty", 1, true))
  end)

  it("prints the usage for anything else", function()
    local env = build("member")
    for _, rest in ipairs({ "remove", "frobnicate", "add" }) do
      assert.is_truthy(text(env.commands:Blacklist(rest)):find("usage", 1, true), rest)
    end
  end)

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
