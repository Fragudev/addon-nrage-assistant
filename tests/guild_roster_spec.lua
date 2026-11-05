local function load_roster()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Domain/GuildRoster.lua"))("NrageAssistant", ns)
  return ns.GuildRoster
end

local GuildRoster = load_roster()

local function build(members, options)
  local env = { clock = 0, members = members, scheduled = {}, requested = 0 }
  env.platform = {
    GetNumGuildMembers = function()
      return #env.members
    end,
    GetGuildRosterEntry = function(index)
      return env.members[index]
    end,
    RequestGuildRoster = function()
      env.requested = env.requested + 1
    end,
  }
  options = options or {}
  env.roster = GuildRoster.New({
    platform = env.platform,
    now = function()
      return env.clock
    end,
    schedule = function(delay, fn)
      env.scheduled[#env.scheduled + 1] = { delay = delay, fn = fn }
    end,
    chunk = options.chunk,
    max = options.max,
    minInterval = options.minInterval,
    onReady = options.onReady,
  })
  -- Runs every scheduled step, in order, until nothing is left.
  function env.drain()
    while #env.scheduled > 0 do
      table.remove(env.scheduled, 1).fn()
    end
  end
  return env
end

local function member(name, rank)
  return { name = name, rankName = rank or "member", rankIndex = 2, level = 60, class = "MAGE" }
end

describe("GuildRoster", function()
  it("indexes members by exact name", function()
    local env = build({ member("A-Realm", "Officer"), member("B-Realm") })
    env.roster:Rebuild()
    assert.is_true(env.roster:IsReady())
    assert.are.equal(2, env.roster:Count())
    assert.are.equal("Officer", env.roster:Lookup("A-Realm").rankName)
    assert.is_nil(env.roster:Lookup("a-realm"))
    assert.is_nil(env.roster:Lookup("A"))
    assert.is_nil(env.roster:Lookup(nil))
  end)

  it("finds the roster's spelling of a name typed in any case or spacing", function()
    local env = build({ member("Yonemon Gg"), member("B-Realm") })
    assert.is_nil(env.roster:Canonical("yonemon gg"))
    env.roster:Rebuild()
    assert.are.equal("Yonemon Gg", env.roster:Canonical("yonemon gg"))
    assert.are.equal("Yonemon Gg", env.roster:Canonical("YONEMONGG"))
    assert.are.equal("B-Realm", env.roster:Canonical("b-realm"))
    assert.is_nil(env.roster:Canonical("Yonemon"))
    assert.is_nil(env.roster:Canonical(nil))
    env.roster:Reset()
    assert.is_nil(env.roster:Canonical("b-realm"))
  end)

  it("is not ready before the first rebuild", function()
    local env = build({ member("A-Realm") })
    assert.is_false(env.roster:IsReady())
    assert.is_nil(env.roster:Lookup("A-Realm"))
  end)

  it("keeps the old index when the client reports an empty roster", function()
    local env = build({ member("A-Realm") })
    env.roster:Rebuild()
    env.members = {}
    env.roster:Rebuild()
    assert.are.equal(1, env.roster:Count())
    assert.is_truthy(env.roster:Lookup("A-Realm"))
  end)

  it("rebuilds in chunks and swaps the index in only when complete", function()
    local env = build({ member("A-Realm"), member("B-Realm"), member("C-Realm") }, { chunk = 2 })
    env.roster:Rebuild()
    assert.are.equal(1, #env.scheduled)
    assert.is_nil(env.roster:Lookup("A-Realm"))
    assert.is_false(env.roster:IsReady())

    env.drain()
    assert.are.equal(3, env.roster:Count())
    assert.is_truthy(env.roster:Lookup("C-Realm"))
  end)

  it("never exposes a half-built index while replacing an old one", function()
    local env = build({ member("Old-Realm") }, { chunk = 1 })
    env.roster:Rebuild()
    env.members = { member("New1-Realm"), member("New2-Realm") }
    env.roster:Rebuild()
    assert.are.equal(1, #env.scheduled)
    assert.is_nil(env.roster:Lookup("New1-Realm"))
    env.drain()
    assert.is_nil(env.roster:Lookup("Old-Realm"))
    assert.are.equal(2, env.roster:Count())
  end)

  it("caps the number of indexed members", function()
    local env = build({ member("A-Realm"), member("B-Realm"), member("C-Realm") }, { max = 2 })
    env.roster:Rebuild()
    assert.are.equal(2, env.roster:Count())
    assert.is_nil(env.roster:Lookup("C-Realm"))
  end)

  it("skips malformed rows without failing", function()
    local env = build({ member("A-Realm"), { rankName = "member" }, member("B-Realm") })
    env.members[2] = { rankName = "member" }
    env.roster:Rebuild()
    assert.are.equal(2, env.roster:Count())
  end)

  it("runs one more rebuild when an update arrives during a rebuild", function()
    local env = build({ member("A-Realm"), member("B-Realm") }, { chunk = 1, minInterval = 0 })
    env.roster:Rebuild()
    env.members = { member("A-Realm"), member("B-Realm"), member("C-Realm") }
    env.roster:Rebuild()
    env.drain()
    assert.are.equal(3, env.roster:Count())
  end)
end)

describe("GuildRoster failures and Reset", function()
  it("recovers when a step raises: a later rebuild runs", function()
    local env = build({ member("A-Realm"), member("B-Realm") }, { chunk = 1 })
    local fail = true
    env.platform.GetGuildRosterEntry = function(index)
      if fail and index == 2 then
        error("boom")
      end
      return env.members[index]
    end
    env.roster:Rebuild()
    assert.has_no.errors(function()
      env.drain()
    end)
    assert.is_false(env.roster:IsReady())
    fail = false
    env.roster:Rebuild()
    env.drain()
    assert.is_true(env.roster:IsReady())
    assert.are.equal(2, env.roster:Count())
  end)

  it("drops the index on Reset and abandons a rebuild in flight", function()
    local env = build({ member("A-Realm"), member("B-Realm") }, { chunk = 1 })
    env.roster:Rebuild()
    env.drain()
    assert.is_true(env.roster:IsReady())
    env.roster:Reset()
    assert.is_false(env.roster:IsReady())
    assert.is_nil(env.roster:Lookup("A-Realm"))
    assert.are.equal(0, env.roster:Count())
    env.roster:Rebuild()
    env.roster:Reset()
    env.drain()
    assert.is_false(env.roster:IsReady())
    env.roster:Rebuild()
    env.drain()
    assert.are.equal(2, env.roster:Count())
  end)
end)

describe("GuildRoster.OnUpdate", function()
  it("rebuilds right away the first time", function()
    local env = build({ member("A-Realm") })
    env.roster:OnUpdate()
    assert.are.equal(1, env.roster:Count())
  end)

  it("delays, and does not drop, an update that comes too soon", function()
    local env = build({ member("A-Realm") }, { minInterval = 10 })
    env.roster:OnUpdate()
    env.members = { member("A-Realm"), member("B-Realm") }

    env.clock = 3
    env.roster:OnUpdate()
    env.roster:OnUpdate()
    assert.are.equal(1, env.roster:Count())
    assert.are.equal(1, #env.scheduled)
    assert.are.equal(7, env.scheduled[1].delay)

    env.clock = 10
    env.drain()
    assert.are.equal(2, env.roster:Count())
  end)

  it("asks the client for a fresh roster on Request", function()
    local env = build({})
    env.roster:Request()
    assert.are.equal(1, env.requested)
  end)
end)

describe("GuildRoster own name", function()
  local function with_guids(members, options)
    local env = build(members, options)
    env.ownName = nil
    env.roster.ownGuid = function()
      return env.guid
    end
    env.roster.onOwnName = function(name)
      env.ownName = name
    end
    return env
  end

  local function person(name, guid)
    local entry = member(name)
    entry.guid = guid
    return entry
  end

  it("finds this character's full name in the roster by GUID", function()
    local env = with_guids({ person("Black Coffee", "G-1"), person("Yonemon Gg", "G-2") })
    env.guid = "G-2"
    env.roster:Rebuild()
    assert.are.equal("Yonemon Gg", env.ownName)
    assert.are.equal("Yonemon Gg", env.roster.ownName)
  end)

  it("keeps the GUID in each entry", function()
    local env = with_guids({ person("Black Coffee", "G-1") })
    env.guid = "G-1"
    env.roster:Rebuild()
    assert.are.equal("G-1", env.roster:Lookup("Black Coffee").guid)
  end)

  it("does nothing when the GUID is not in the roster or not known", function()
    local env = with_guids({ person("Black Coffee", "G-1") })
    env.guid = "G-9"
    env.roster:Rebuild()
    assert.is_nil(env.ownName)

    env.guid = nil
    env.roster:Rebuild()
    assert.is_nil(env.ownName)
  end)

  it("looks again on every rebuild, so a renamed character is picked up", function()
    local env = with_guids({ person("Old Name", "G-1") }, { minInterval = 0 })
    env.guid = "G-1"
    env.roster:Rebuild()
    assert.are.equal("Old Name", env.ownName)

    env.members = { person("New Name", "G-1") }
    env.roster:Rebuild()
    assert.are.equal("New Name", env.ownName)
  end)

  it("works without the optional dependencies", function()
    local env = build({ person("Black Coffee", "G-1") })
    env.roster:Rebuild()
    assert.are.equal(1, env.roster:Count())
  end)
end)

describe("GuildRoster:Names", function()
  it("lists every known member sorted, and nothing before the first rebuild", function()
    local env = build({ member("Zed-Realm"), member("Ann-Realm"), member("Yonemon Gg-Realm") })
    assert.are.same({}, env.roster:Names())
    env.roster:Rebuild()
    assert.are.same({ "Ann-Realm", "Yonemon Gg-Realm", "Zed-Realm" }, env.roster:Names())
  end)
end)

describe("GuildRoster.onReady", function()
  it("is called once a rebuild completes, with the roster already answering", function()
    local answered
    local env
    env = build({ { name = "Ann", rankName = "Member", rankIndex = 3 } }, {
      onReady = function()
        answered = env.roster:Lookup("Ann") ~= nil
      end,
    })
    env.roster:Rebuild()
    env.drain()
    assert.is_true(answered)
  end)
end)
