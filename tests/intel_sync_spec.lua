local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/IntelModel",
    "Domain/IntelDirectory",
    "Sync/SyncRules",
    "Sync/Inbox",
    "Sync/IntelSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local TEXT = "I1:1411:1235:5000:4:6:60:0:Bob"

local function build()
  local env = { clock = 100, roles = { Ann = "member", Cid = "alter", Boss = "gm" } }
  env.directory = ns.IntelDirectory.New({
    now = function()
      return env.clock
    end,
  })
  env.sync = ns.IntelSync.New({
    platform = {
      NormalizeName = function(name)
        return (name:gsub("%-Realm$", ""))
      end,
      GetIdentityKey = function()
        return "Me"
      end,
    },
    inbox = ns.Inbox.New({ maxPerWindow = Constants.INTEL_INBOX_MAX_PER_WINDOW }),
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

describe("IntelSync:Handle", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps the sighting of a guild member, with the sender from the client", function()
    assert.is_true(env.sync:Handle(TEXT, "GUILD", "Ann-Realm"))
    local list = env.directory:List()
    assert.are.equal(1, #list)
    assert.are.equal("Bob", list[1].name)
    assert.are.equal("Ann", list[1].source)
    assert.are.equal(1411, list[1].map)
    assert.are.equal(1, env.sync.received)
  end)

  it("accepts the guild and the group channels", function()
    for _, channel in ipairs({ "GUILD", "RAID", "PARTY", "INSTANCE_CHAT" }) do
      assert.is_true(env.sync:Handle(TEXT, channel, "Ann"), channel)
    end
  end)

  it("drops any other channel", function()
    for _, channel in ipairs({ "WHISPER", "SAY", "OFFICER", "", false, nil }) do
      assert.are.same({ false, "wrong_channel" }, { env.sync:Handle(TEXT, channel, "Ann") })
    end
    assert.are.equal(0, #env.directory:List())
  end)

  it("drops a sender that is not a string", function()
    for _, sender in ipairs({ "", false, 5 }) do
      assert.are.same({ false, "bad_sender" }, { env.sync:Handle(TEXT, "GUILD", sender) })
    end
  end)

  it("drops the own message, with or without the realm", function()
    assert.are.same({ false, "own_message" }, { env.sync:Handle(TEXT, "GUILD", "Me") })
    assert.are.same({ false, "own_message" }, { env.sync:Handle(TEXT, "GUILD", "Me-Realm") })
  end)

  it("drops a sender the guild roster does not know, such as a battleground group mate", function()
    assert.are.same({ false, "unknown_sender" }, { env.sync:Handle(TEXT, "INSTANCE_CHAT", "Stranger") })
    assert.are.equal(0, #env.directory:List())
  end)

  it("drops a sender whose role may not share", function()
    local can = ns.PermissionService.Can
    ns.PermissionService.Can = function()
      return false
    end
    local result = { env.sync:Handle(TEXT, "GUILD", "Ann") }
    ns.PermissionService.Can = can
    assert.are.same({ false, "forbidden" }, result)
  end)

  it("limits how many messages one sender can send", function()
    for _ = 1, Constants.INTEL_INBOX_MAX_PER_WINDOW do
      assert.is_true(env.sync:Handle(TEXT, "GUILD", "Ann"))
    end
    assert.are.same({ false, "rate_limited" }, { env.sync:Handle(TEXT, "GUILD", "Ann") })
    assert.is_true(env.sync:Handle(TEXT, "GUILD", "Boss"))
    env.clock = env.clock + Constants.INBOX_WINDOW_SECONDS
    assert.is_true(env.sync:Handle(TEXT, "GUILD", "Ann"))
  end)

  it("says why a text was dropped", function()
    assert.are.same({ false, "bad_format" }, { env.sync:Handle("hello", "GUILD", "Ann") })
    assert.are.same({ false, "bad_format" }, { env.sync:Handle(nil, "GUILD", "Ann") })
    assert.are.same({ false, "out_of_range" }, { env.sync:Handle("I1:0:1:1:0:0:0:0:Bob", "GUILD", "Ann") })
    assert.are.same({ false, "too_long" }, { env.sync:Handle(TEXT .. ("x"):rep(100), "GUILD", "Ann") })
    assert.are.same({ false, "bad_format" }, { env.sync:Handle(TEXT .. ":extra", "GUILD", "Ann") })
    assert.are.equal(1, env.sync.drops.out_of_range)
    assert.are.equal(0, #env.directory:List())
  end)

  it("reports the reason of the directory when it is full", function()
    for index = 1, Constants.INTEL_DIRECTORY_MAX do
      env.directory:Apply("Ann", { name = "P" .. index, map = 1, x = 0, y = 0 })
    end
    assert.are.same({ false, "limit" }, { env.sync:Handle(TEXT, "GUILD", "Ann") })
  end)
end)
