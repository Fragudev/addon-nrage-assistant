local function load_cache()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Domain/PvPUnitCache" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_cache()
local Constants = ns.Constants

local function build()
  local env = { clock = 1000 }
  env.cache = ns.PvPUnitCache.New({
    now = function()
      return env.clock
    end,
  })
  return env
end

describe("PvPUnitCache", function()
  it("remembers the class and race of a name, without case", function()
    local env = build()
    assert.is_true(env.cache:Remember("Zed Gg", "WARRIOR", "ORC"))
    local class, race = env.cache:Lookup("zed gg")
    assert.are.equal("WARRIOR", class)
    assert.are.equal("ORC", race)
    assert.is_nil(env.cache:Lookup("Nobody"))
  end)

  it("keeps what is known when a later sighting only gives one of the two", function()
    local env = build()
    env.cache:Remember("Zed", "MAGE", "TROLL")
    env.cache:Remember("Zed", nil, "TAUREN")
    local class, race = env.cache:Lookup("Zed")
    assert.are.equal("MAGE", class)
    assert.are.equal("TAUREN", race)
    assert.are.equal(1, env.cache:Count())
  end)

  it("ignores names and tokens that are not usable", function()
    local env = build()
    local secret = setmetatable({}, { __concat = error })
    assert.is_false(env.cache:Remember(nil, "MAGE", "ORC"))
    assert.is_false(env.cache:Remember("", "MAGE", "ORC"))
    assert.is_false(env.cache:Remember(secret, "MAGE", "ORC"))
    assert.is_false(env.cache:Remember("Zed", secret, secret))
    assert.is_false(env.cache:Remember("Zed", "Mage", "orc"))
    assert.is_false(env.cache:Remember("Zed"))
    assert.are.equal(0, env.cache:Count())
    assert.is_nil(env.cache:Lookup(nil))
    assert.is_nil(env.cache:Lookup(secret))
    -- one usable token is enough
    assert.is_true(env.cache:Remember("Zed", secret, "ORC"))
    local class, race = env.cache:Lookup("Zed")
    assert.is_nil(class)
    assert.are.equal("ORC", race)
  end)

  it("forgets an entry older than the time to live", function()
    local env = build()
    env.cache:Remember("Zed", "MAGE", "ORC")
    env.clock = env.clock + Constants.PVP_UNIT_CACHE_TTL
    assert.are.equal("MAGE", (env.cache:Lookup("Zed")))
    env.clock = env.clock + 1
    assert.is_nil(env.cache:Lookup("Zed"))
    assert.are.equal(0, env.cache:Count())
  end)

  it("a new sighting renews the entry", function()
    local env = build()
    env.cache:Remember("Zed", "MAGE", "ORC")
    env.clock = env.clock + Constants.PVP_UNIT_CACHE_TTL
    env.cache:Remember("Zed", "MAGE", "ORC")
    env.clock = env.clock + Constants.PVP_UNIT_CACHE_TTL
    assert.are.equal("MAGE", (env.cache:Lookup("Zed")))
  end)

  it("drops the least recently seen name when full", function()
    local env = build()
    for index = 1, Constants.PVP_UNIT_CACHE_MAX do
      env.cache:Remember("P" .. index, "MAGE", "ORC")
    end
    assert.are.equal(Constants.PVP_UNIT_CACHE_MAX, env.cache:Count())
    -- seeing P1 again makes P2 the oldest
    env.cache:Remember("P1", "MAGE", "ORC")
    env.cache:Remember("New", "ROGUE", "TROLL")
    assert.are.equal(Constants.PVP_UNIT_CACHE_MAX, env.cache:Count())
    assert.is_nil(env.cache:Lookup("P2"))
    assert.are.equal("MAGE", (env.cache:Lookup("P1")))
    assert.are.equal("ROGUE", (env.cache:Lookup("New")))
  end)
end)
