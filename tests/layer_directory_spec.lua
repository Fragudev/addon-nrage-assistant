local function load_directory()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LayerModel", "Domain/LayerDirectory" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_directory()

local function build(isMember)
  local env = { clock = 100, left = {} }
  env.directory = ns.LayerDirectory.New({
    now = function()
      return env.clock
    end,
    isMember = isMember == false and nil or function(name)
      if env.memberFails then
        error("roster")
      end
      return not env.left[name]
    end,
  })
  return env
end

describe("LayerDirectory", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps the layer of each member and replaces the older one", function()
    assert.is_true(env.directory:Apply("Ann", { map = 0, layer = 10 }))
    assert.is_true(env.directory:Apply("Ann", { map = 0, layer = 20 }))
    assert.are.same({ "Ann" }, env.directory:MembersOn(0, 20))
    assert.are.same({}, env.directory:MembersOn(0, 10))
  end)

  it("forgets a member who sends layer 0", function()
    env.directory:Apply("Ann", { map = 0, layer = 10 })
    assert.is_true(env.directory:Apply("Ann", { map = 0, layer = 0 }))
    assert.are.same({}, env.directory:Groups(0))
    assert.are.equal(0, env.directory.count)
    -- Forgetting someone unknown is fine.
    assert.is_true(env.directory:Apply("Bob", { map = 0, layer = 0 }))
  end)

  it("refuses a state that is not one", function()
    local bad = { "x", { map = "a", layer = 1 }, { map = 0, layer = -1 }, { map = 99999, layer = 1 }, {} }
    for _, state in ipairs(bad) do
      local ok, reason = env.directory:Apply("Ann", state)
      assert.is_false(ok)
      assert.are.equal("bad_state", reason)
    end
    assert.is_false(env.directory:Apply("", { map = 0, layer = 1 }))
    assert.is_false(env.directory:Apply(nil, { map = 0, layer = 1 }))
  end)

  it("is bounded", function()
    for index = 1, ns.Constants.GUILD_ROSTER_MAX do
      env.directory:Apply("M" .. index, { map = 0, layer = 1 })
    end
    local ok, reason = env.directory:Apply("OneMore", { map = 0, layer = 1 })
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    -- A member who is already listed can still change.
    assert.is_true(env.directory:Apply("M1", { map = 0, layer = 2 }))
  end)

  it("evicts stale entries so a new sender is not refused", function()
    for index = 1, ns.Constants.GUILD_ROSTER_MAX do
      env.directory:Apply("M" .. index, { map = 0, layer = 1 })
    end
    env.clock = env.clock + ns.Constants.LAYER_STATE_TTL + 1
    assert.is_true(env.directory:Apply("OneMore", { map = 0, layer = 1 }))
    assert.are.equal(1, env.directory.count)
  end)

  it("groups the members of a continent by layer, most crowded first", function()
    env.directory:Apply("Cid", { map = 0, layer = 20 })
    env.directory:Apply("Ann", { map = 0, layer = 10 })
    env.directory:Apply("Bob", { map = 0, layer = 10 })
    env.directory:Apply("Dan", { map = 0, layer = 30 })
    env.directory:Apply("Eve", { map = 1, layer = 99 })
    local groups = env.directory:Groups(0)
    assert.are.equal(3, #groups)
    assert.are.same({ "Ann", "Bob" }, groups[1].members)
    assert.are.equal(2, groups[1].count)
    assert.are.equal(10, groups[1].layer)
    assert.are.equal(20, groups[2].layer)
    assert.are.equal(30, groups[3].layer)
  end)

  it("lists every continent when none is asked for", function()
    env.directory:Apply("Ann", { map = 0, layer = 10 })
    env.directory:Apply("Eve", { map = 1, layer = 10 })
    local groups = env.directory:Groups()
    assert.are.equal(2, #groups)
    assert.are.equal(0, groups[1].map)
    assert.are.equal(1, groups[2].map)
  end)

  it("does not list stale entries", function()
    env.directory:Apply("Ann", { map = 0, layer = 10 })
    env.clock = env.clock + ns.Constants.LAYER_STATE_TTL - 1
    env.directory:Apply("Bob", { map = 0, layer = 10 })
    env.clock = env.clock + 2
    assert.are.same({ "Bob" }, env.directory:MembersOn(0, 10))
  end)

  it("drops the members who left the guild roster", function()
    env.directory:Apply("Ann", { map = 0, layer = 10 })
    env.directory:Apply("Bob", { map = 0, layer = 10 })
    env.left.Ann = true
    assert.are.same({ "Bob" }, env.directory:MembersOn(0, 10))
    env.memberFails = true
    assert.are.same({}, env.directory:Groups(0))
  end)

  it("lists everybody when it is not told who is a member", function()
    local open = build(false)
    open.directory:Apply("Ann", { map = 0, layer = 10 })
    assert.are.same({ "Ann" }, open.directory:MembersOn(0, 10))
  end)
end)
