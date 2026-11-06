local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/IntelModel", "Domain/IntelDirectory" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build()
  local env = { clock = 100, changes = 0 }
  env.directory = ns.IntelDirectory.New({
    now = function()
      return env.clock
    end,
    onChange = function()
      env.changes = env.changes + 1
    end,
  })
  return env
end

local function sighting(overrides)
  local decoded = {
    map = 1411,
    x = 100,
    y = 200,
    class = "ROGUE",
    race = "ORC",
    level = 60,
    stealth = false,
    estimated = false,
    name = "Bob",
  }
  for key, value in pairs(overrides or {}) do
    decoded[key] = value
  end
  return decoded
end

describe("IntelDirectory", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps a sighting with the reporter as its source", function()
    assert.is_true(env.directory:Apply("Ann", sighting()))
    assert.are.same({
      {
        key = "bob",
        name = "Bob",
        class = "ROGUE",
        race = "ORC",
        level = 60,
        estimated = false,
        stealth = false,
        map = 1411,
        x = 100,
        y = 200,
        at = 100,
        source = "Ann",
      },
    }, env.directory:List())
    assert.are.equal(1, env.changes)
  end)

  it("keeps one entry per enemy, the newest sighting winning whoever reported it", function()
    env.directory:Apply("Ann", sighting())
    env.clock = 110
    env.directory:Apply("Cid", sighting({ x = 5, stealth = true }))
    local list = env.directory:List()
    assert.are.equal(1, #list)
    assert.are.equal("Cid", list[1].source)
    assert.are.equal(5, list[1].x)
    assert.is_true(list[1].stealth)
    -- The same enemy under another spelling is the same enemy.
    env.directory:Apply("Ann", sighting({ name = "BOB" }))
    assert.are.equal(1, #env.directory:List())
  end)

  it("drops an entry after the time to live and says so", function()
    env.directory:Apply("Ann", sighting())
    env.clock = 100 + Constants.INTEL_DIRECTORY_TTL
    assert.are.equal(1, #env.directory:List())
    env.clock = env.clock + 1
    assert.are.equal(0, #env.directory:List())
    local changes = env.changes
    assert.is_true(env.directory:Prune())
    assert.are.equal(changes + 1, env.changes)
    assert.is_false(env.directory:Prune())
  end)

  it("lists the enemies of one map, most recent first", function()
    env.directory:Apply("Ann", sighting({ name = "Old" }))
    env.clock = 105
    env.directory:Apply("Ann", sighting({ name = "New" }))
    env.directory:Apply("Ann", sighting({ name = "Far", map = 1412 }))
    local names = {}
    for _, item in ipairs(env.directory:List(1411)) do
      names[#names + 1] = item.name
    end
    assert.are.same({ "New", "Old" }, names)
    assert.are.equal(3, #env.directory:List())
  end)

  it("refuses a new enemy when it is full of live ones, and makes room when some are stale", function()
    for index = 1, Constants.INTEL_DIRECTORY_MAX do
      assert.is_true(env.directory:Apply("Ann", sighting({ name = "P" .. index })))
    end
    assert.are.same({ false, "limit" }, { env.directory:Apply("Ann", sighting({ name = "Late" })) })
    assert.is_true(env.directory:Apply("Ann", sighting({ name = "P1", x = 7 })))
    env.clock = env.clock + Constants.INTEL_DIRECTORY_TTL + 1
    assert.is_true(env.directory:Apply("Ann", sighting({ name = "Late" })))
    assert.are.equal(1, #env.directory:List())
  end)

  it("refuses a sender or a sighting that is not usable", function()
    assert.are.same({ false, "bad_sender" }, { env.directory:Apply("", sighting()) })
    assert.are.same({ false, "bad_sender" }, { env.directory:Apply(nil, sighting()) })
    assert.are.same({ false, "bad_state" }, { env.directory:Apply("Ann", nil) })
    assert.are.same({ false, "bad_state" }, { env.directory:Apply("Ann", { name = "" }) })
    assert.are.equal(0, env.changes)
  end)

  it("removes an enemy", function()
    env.directory:Apply("Ann", sighting())
    assert.is_true(env.directory:Remove("bob"))
    assert.is_false(env.directory:Remove("bob"))
    assert.are.equal(0, #env.directory:List())
  end)

  it("works without a change handler and survives one that raises", function()
    local quiet = ns.IntelDirectory.New({
      now = function()
        return 1
      end,
    })
    assert.is_true(quiet:Apply("Ann", sighting()))
    local loud = ns.IntelDirectory.New({
      now = function()
        return 1
      end,
      onChange = function()
        error("boom")
      end,
    })
    assert.is_true(loud:Apply("Ann", sighting()))
  end)

  it("hands out copies", function()
    env.directory:Apply("Ann", sighting())
    env.directory:List()[1].name = "Changed"
    assert.are.equal("Bob", env.directory:List()[1].name)
  end)
end)
