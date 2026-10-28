local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/PositionModel",
    "Domain/PositionDirectory",
    "Sync/SyncRules",
    "Sync/Inbox",
    "Sync/PositionSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build()
  local env = { clock = 100, roles = { Ann = "member", Bob = "gm" } }
  env.directory = ns.PositionDirectory.New({
    now = function()
      return env.clock
    end,
  })
  env.sync = ns.PositionSync.New({
    platform = {
      NormalizeName = function(name)
        return (name:gsub("%-Realm$", ""))
      end,
      GetIdentityKey = function()
        return "Me"
      end,
    },
    inbox = ns.Inbox.New({ maxPerWindow = Constants.POSITION_INBOX_MAX_PER_WINDOW }),
    roleOf = function(sender)
      return env.roles[sender]
    end,
    directory = env.directory,
    now = function()
      return env.clock
    end,
  })
  return env
end

describe("PositionSync:Handle", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps the position of a guild member", function()
    assert.is_true(env.sync:Handle("P1:1411:1235:5000", "GUILD", "Ann"))
    assert.are.same({ { name = "Ann", map = 1411, x = 1235, y = 5000, at = 100 } }, env.directory:List())
  end)

  it("reads the sender without the realm of the own server", function()
    assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Ann-Realm"))
    assert.are.equal("Ann", env.directory:List()[1].name)
  end)

  it("forgets a member who says forget me", function()
    env.sync:Handle("P1:1:1:1", "GUILD", "Ann")
    assert.is_true(env.sync:Handle("P1:0", "GUILD", "Ann"))
    assert.are.same({}, env.directory:List())
  end)

  it("drops every channel but the guild", function()
    for _, channel in ipairs({ "WHISPER", "PARTY", "RAID", "SAY", "", nil }) do
      local ok, reason = env.sync:Handle("P1:1:1:1", channel, "Ann")
      assert.is_false(ok)
      assert.are.equal("wrong_channel", reason)
    end
    assert.are.same({}, env.directory:List())
  end)

  it("drops a bad sender", function()
    for _, sender in ipairs({ "", 5, true }) do
      local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", sender)
      assert.is_false(ok)
      assert.are.equal("bad_sender", reason)
    end
    local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", nil)
    assert.is_false(ok)
    assert.are.equal("bad_sender", reason)
  end)

  it("drops the own messages, with or without the realm", function()
    for _, sender in ipairs({ "Me", "Me-Realm" }) do
      local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", sender)
      assert.is_false(ok)
      assert.are.equal("own_message", reason)
    end
    assert.are.same({}, env.directory:List())
  end)

  it("drops a sender the guild roster does not know", function()
    local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", "Stranger")
    assert.is_false(ok)
    assert.are.equal("unknown_sender", reason)
    assert.are.same({}, env.directory:List())
  end)

  it("drops a sender whose role may not share positions", function()
    env.roles.Ann = "nobody"
    local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", "Ann")
    assert.is_false(ok)
    assert.are.equal("forbidden", reason)
  end)

  it("drops a sender who is over the rate limit, and counts them again in the next window", function()
    for _ = 1, Constants.POSITION_INBOX_MAX_PER_WINDOW do
      assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Ann"))
    end
    local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", "Ann")
    assert.is_false(ok)
    assert.are.equal("rate_limited", reason)
    assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Bob"))
    env.clock = env.clock + Constants.INBOX_WINDOW_SECONDS
    assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Ann"))
  end)

  it("does not mark messages as seen: the same text twice is fine", function()
    assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Ann"))
    assert.is_true(env.sync:Handle("P1:1:1:1", "GUILD", "Ann"))
  end)

  it("drops a malformed message with the reason", function()
    local cases = {
      { "P2:1:1:1", "bad_format" },
      { "P1:1:1:1x", "bad_format" },
      { "P1:0:1:1", "out_of_range" },
      { "P1:1:10001:1", "out_of_range" },
      { "P1:1:" .. ("1"):rep(40), "too_long" },
      { 42, "bad_format" },
    }
    for _, case in ipairs(cases) do
      local ok, reason = env.sync:Handle(case[1], "GUILD", "Ann")
      assert.is_false(ok)
      assert.are.equal(case[2], reason, tostring(case[1]))
    end
    assert.are.same({}, env.directory:List())
  end)

  it("passes on the refusal of a full directory", function()
    for i = 1, Constants.POSITION_DIRECTORY_MAX do
      env.directory:Apply("Member" .. i, { map = 1, x = 1, y = 1 })
    end
    local ok, reason = env.sync:Handle("P1:1:1:1", "GUILD", "Ann")
    assert.is_false(ok)
    assert.are.equal("limit", reason)
  end)
end)
