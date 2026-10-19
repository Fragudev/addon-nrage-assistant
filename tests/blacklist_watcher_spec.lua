local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RosterService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/BlacklistService",
    "Domain/BlacklistWatcher",
    "Sync/Protocol",
    "Sync/SyncRules",
    "Sync/BlacklistSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()

-- A watcher over fakes: `env.group` is the list of member names (nil when not in a group).
local function build(overrides)
  local env = { blacklist = {}, group = nil, alerts = {}, own = { "Me Myself-Realm", "Me" } }
  env.blacklist.ann = { name = "Ann", reason = "ninja", rev = 1, updatedAt = 1 }
  env.blacklist.yonemongg = { name = "Yonemon Gg", reason = "scammer", rev = 1, updatedAt = 1 }
  for k, v in pairs(overrides or {}) do
    env[k] = v
  end
  env.watcher = ns.BlacklistWatcher.New({
    blacklist = env.blacklist,
    isGrouped = function()
      return env.group ~= nil
    end,
    members = function()
      return env.group or {}
    end,
    ownNames = function()
      return env.own
    end,
    alert = function(match)
      env.alerts[#env.alerts + 1] = match
    end,
  })
  return env
end

describe("BlacklistWatcher.Check", function()
  it("does nothing outside a group", function()
    local env = build()
    assert.are.same({}, env.watcher:Check())
    assert.are.same({}, env.alerts)
  end)

  it("alerts for a listed player in the group", function()
    local env = build({ group = { "Bob", "Ann" } })
    local warned = env.watcher:Check()
    assert.are.equal(1, #warned)
    assert.are.equal(1, #env.alerts)
    assert.are.equal("ann", env.alerts[1].key)
    assert.is_false(env.alerts[1].approximate)
  end)

  it("alerts once per player per group, however often the group changes", function()
    local env = build({ group = { "Ann" } })
    env.watcher:Check()
    env.watcher:Check()
    env.group = { "Ann", "Bob" }
    env.watcher:Check()
    assert.are.equal(1, #env.alerts)
  end)

  it("alerts for a player who joins later, and for each listed player once", function()
    local env = build({ group = { "Bob" } })
    env.watcher:Check()
    assert.are.equal(0, #env.alerts)
    env.group = { "Bob", "Ann", "Yonemon Gg" }
    env.watcher:Check()
    env.watcher:Check()
    assert.are.equal(2, #env.alerts)
  end)

  it("alerts again in the next group, after leaving the first one", function()
    local env = build({ group = { "Ann" } })
    env.watcher:Check()
    env.group = nil
    env.watcher:Check()
    env.group = { "Ann" }
    env.watcher:Check()
    assert.are.equal(2, #env.alerts)
  end)

  it("keeps what it has warned about when the group is momentarily unreadable", function()
    local env = build({ group = { "Ann" } })
    env.watcher:Check()
    env.group = {}
    env.watcher:Check()
    env.group = { "Ann" }
    env.watcher:Check()
    assert.are.equal(1, #env.alerts)
  end)

  it("matches the first word of a multi-word listed name as an approximate match", function()
    local env = build({ group = { "Yonemon" } })
    env.watcher:Check()
    assert.are.equal(1, #env.alerts)
    assert.is_true(env.alerts[1].approximate)
    assert.are.equal("Yonemon", env.alerts[1].member)
    assert.are.equal("Yonemon Gg", env.alerts[1].entry.name)
  end)

  it("never alerts about the player themselves, whichever way the name is spelled", function()
    local env = build({ group = { "Me", "Me Myself", "Bob" } })
    env.blacklist.me = { name = "Me", reason = "x", rev = 1, updatedAt = 1 }
    env.blacklist.memyself = { name = "Me Myself", reason = "x", rev = 1, updatedAt = 1 }
    env.watcher:Check()
    assert.are.same({}, env.alerts)
  end)

  it("never alerts about the first word of the own multi-word name", function()
    local env = build({ group = { "Yonemon" }, own = { "Yonemon Gg" } })
    env.watcher:Check()
    assert.are.same({}, env.alerts)
  end)

  it("alerts when an entry arrives by sync for a member who is already in the group", function()
    local env = build({ group = { "Bob", "Zed" } })
    env.watcher:Check()
    assert.are.equal(0, #env.alerts)

    local ctx = {
      blacklist = env.blacklist,
      tombstones = {},
      now = function()
        return 100
      end,
    }
    local message = ns.Protocol.Validate(ns.Protocol.Build("BLACKLIST_UPSERT", {
      key = "zed",
      name = "Zed",
      reason = "ninja",
      rev = 1,
      updatedAt = 50,
    }, "id-1"))
    assert.is_true(ns.BlacklistSync.Apply(ctx, message, "Ann-Realm", "member"))
    env.watcher:Check()
    assert.are.equal(1, #env.alerts)
    assert.are.equal("zed", env.alerts[1].key)
  end)

  it("keeps going when an alert raises", function()
    local env = build({ group = { "Ann", "Yonemon" } })
    local calls = 0
    env.watcher.deps.alert = function()
      calls = calls + 1
      error("boom")
    end
    assert.has_no.errors(function()
      env.watcher:Check()
    end)
    assert.are.equal(2, calls)
  end)

  it("does nothing for an empty blacklist", function()
    local env = build({ group = { "Ann" }, blacklist = {} })
    assert.are.same({}, env.watcher:Check())
  end)
end)
