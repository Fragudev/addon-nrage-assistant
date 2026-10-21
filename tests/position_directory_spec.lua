local function load_directory()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/PositionDirectory" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_directory()
local Constants = ns.Constants

local function build()
  local env = { clock = 100, changes = 0 }
  env.directory = ns.PositionDirectory.New({
    now = function()
      return env.clock
    end,
    onChange = function()
      env.changes = env.changes + 1
    end,
  })
  return env
end

describe("PositionDirectory", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps the position of a member and lists it with the time it arrived", function()
    assert.is_true(env.directory:Apply("Ann", { map = 1, x = 10, y = 20 }))
    assert.are.same({ { name = "Ann", map = 1, x = 10, y = 20, at = 100 } }, env.directory:List())
  end)

  it("replaces the older position of the same member", function()
    env.directory:Apply("Ann", { map = 1, x = 10, y = 20 })
    env.clock = 110
    env.directory:Apply("Ann", { map = 2, x = 30, y = 40 })
    assert.are.same({ { name = "Ann", map = 2, x = 30, y = 40, at = 110 } }, env.directory:List())
  end)

  it("lists the members sorted by name", function()
    env.directory:Apply("Cid", { map = 1, x = 1, y = 1 })
    env.directory:Apply("Ann", { map = 1, x = 1, y = 1 })
    env.directory:Apply("Bob", { map = 1, x = 1, y = 1 })
    local names = {}
    for _, entry in ipairs(env.directory:List()) do
      names[#names + 1] = entry.name
    end
    assert.are.same({ "Ann", "Bob", "Cid" }, names)
  end)

  it("removes a member who says forget me", function()
    env.directory:Apply("Ann", { map = 1, x = 10, y = 20 })
    assert.is_true(env.directory:Apply("Ann", { forget = true }))
    assert.are.same({}, env.directory:List())
    assert.is_true(env.directory:Apply("Ann", { forget = true }))
  end)

  it("refuses a bad sender and a bad state", function()
    for _, sender in ipairs({ "", 5 }) do
      local ok, reason = env.directory:Apply(sender, { map = 1, x = 1, y = 1 })
      assert.is_false(ok)
      assert.are.equal("bad_sender", reason)
    end
    for _, state in ipairs({
      "x",
      {},
      { map = 0, x = 1, y = 1 },
      { map = 1, x = -1, y = 1 },
      { map = 1, x = 1, y = 10001 },
      { map = 1, x = 1.5, y = 1 },
    }) do
      local ok, reason = env.directory:Apply("Ann", state)
      assert.is_false(ok)
      assert.are.equal("bad_state", reason)
    end
    assert.are.same({}, env.directory:List())
  end)

  it("refuses new members when it is full, but still updates the ones it has", function()
    for i = 1, Constants.POSITION_DIRECTORY_MAX do
      assert.is_true(env.directory:Apply("Member" .. i, { map = 1, x = 1, y = 1 }))
    end
    local ok, reason = env.directory:Apply("Newcomer", { map = 1, x = 1, y = 1 })
    assert.is_false(ok)
    assert.are.equal("limit", reason)
    assert.is_true(env.directory:Apply("Member1", { map = 2, x = 5, y = 5 }))
    assert.are.equal(Constants.POSITION_DIRECTORY_MAX, #env.directory:List())
  end)

  it("makes room again when a member is forgotten", function()
    for i = 1, Constants.POSITION_DIRECTORY_MAX do
      env.directory:Apply("Member" .. i, { map = 1, x = 1, y = 1 })
    end
    env.directory:Apply("Member1", { forget = true })
    assert.is_true(env.directory:Apply("Newcomer", { map = 1, x = 1, y = 1 }))
  end)

  it("does not list an entry older than the TTL, and prunes it", function()
    env.directory:Apply("Ann", { map = 1, x = 1, y = 1 })
    env.clock = 100 + Constants.POSITION_TTL
    assert.are.equal(1, #env.directory:List())
    assert.is_false(env.directory:Prune())
    env.clock = env.clock + 1
    assert.are.same({}, env.directory:List())
    assert.is_true(env.directory:Prune())
    assert.is_false(env.directory:Prune())
  end)

  it("keeps the fresh entries when it prunes", function()
    env.directory:Apply("Old", { map = 1, x = 1, y = 1 })
    env.clock = 100 + Constants.POSITION_TTL
    env.directory:Apply("Fresh", { map = 1, x = 1, y = 1 })
    env.clock = env.clock + 1
    assert.is_true(env.directory:Prune())
    assert.are.equal("Fresh", env.directory:List()[1].name)
    assert.are.equal(1, #env.directory:List())
  end)

  it("makes room when it prunes", function()
    for i = 1, Constants.POSITION_DIRECTORY_MAX do
      env.directory:Apply("Member" .. i, { map = 1, x = 1, y = 1 })
    end
    env.clock = env.clock + Constants.POSITION_TTL + 1
    env.directory:Prune()
    assert.is_true(env.directory:Apply("Newcomer", { map = 1, x = 1, y = 1 }))
  end)

  it("calls onChange after a change, and not when nothing changed", function()
    env.directory:Apply("Ann", { map = 1, x = 1, y = 1 })
    assert.are.equal(1, env.changes)
    env.directory:Apply("Ann", { forget = true })
    assert.are.equal(2, env.changes)
    env.directory:Apply("Ann", { forget = true })
    env.directory:Apply("Ann", { map = 0, x = 1, y = 1 })
    env.directory:Prune()
    assert.are.equal(2, env.changes)
    env.directory:Apply("Bob", { map = 1, x = 1, y = 1 })
    env.clock = env.clock + Constants.POSITION_TTL + 1
    env.directory:Prune()
    assert.are.equal(4, env.changes)
  end)

  it("works without an onChange and survives one that raises", function()
    local plain = ns.PositionDirectory.New({
      now = function()
        return 1
      end,
    })
    assert.is_true(plain:Apply("Ann", { map = 1, x = 1, y = 1 }))
    local raising = ns.PositionDirectory.New({
      now = function()
        return 1
      end,
      onChange = function()
        error("redraw")
      end,
    })
    assert.is_true(raising:Apply("Ann", { map = 1, x = 1, y = 1 }))
    assert.are.equal(1, #raising:List())
  end)
end)
