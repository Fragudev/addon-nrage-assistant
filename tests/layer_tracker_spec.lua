local function load_tracker()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/LayerModel", "Domain/LayerTracker" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_tracker()
local Constants = ns.Constants

local function guid(layer, spawn, map)
  return ("Creature-0-3134-%d-%d-6491-%08X"):format(map or 0, layer, spawn)
end

local function build()
  local env = { clock = 100, instance = false, changes = {} }
  env.tracker = ns.LayerTracker.New({
    now = function()
      return env.clock
    end,
    isInInstance = function()
      if env.instanceFails then
        error("secret")
      end
      return env.instance
    end,
    onChange = function(current)
      env.changes[#env.changes + 1] = current
    end,
  })
  return env
end

describe("LayerTracker", function()
  local env

  before_each(function()
    env = build()
  end)

  it("is unknown until a layer is confirmed", function()
    assert.is_nil(env.tracker:Current())
    assert.is_true(env.tracker:Observe(guid(10, 1)))
    assert.is_nil(env.tracker:Current())
  end)

  it("confirms a layer after readings from different spawns", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    assert.are.same({ map = 0, layer = 10, confirmedAt = 100 }, env.tracker:Current())
    assert.are.equal(1, #env.changes)
    assert.are.equal(10, env.changes[1].layer)
  end)

  it("does not count the same spawn twice", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 1))
    assert.is_nil(env.tracker:Current())
  end)

  it("is not flipped by one odd creature", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    env.tracker:Observe(guid(20, 3))
    assert.are.equal(10, env.tracker:Current().layer)
    assert.are.equal(1, #env.changes)
    env.tracker:Observe(guid(20, 4))
    assert.are.equal(20, env.tracker:Current().layer)
    assert.are.equal(2, #env.changes)
  end)

  it("does not announce the layer it already has", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    env.tracker:Observe(guid(10, 3))
    assert.are.equal(1, #env.changes)
  end)

  it("keeps layers of different continents apart", function()
    env.tracker:Observe(guid(10, 1, 0))
    env.tracker:Observe(guid(10, 2, 1))
    assert.is_nil(env.tracker:Current())
  end)

  it("ignores what is not a creature", function()
    assert.is_false(env.tracker:Observe("Player-3134-0123ABCD"))
    assert.is_false(env.tracker:Observe(nil))
  end)

  it("keeps only the latest readings", function()
    for spawn = 1, Constants.LAYER_READINGS_MAX + 5 do
      env.tracker:Observe(guid(100 + spawn, spawn))
    end
    assert.is_true(#env.tracker.readings <= Constants.LAYER_READINGS_MAX)
  end)

  it("forgets the layer in an instance and refuses readings there", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    env.instance = true
    assert.is_nil(env.tracker:Current())
    assert.is_false(env.tracker:Observe(guid(10, 3)))
    env.instance = false
    assert.is_nil(env.tracker:Current())
  end)

  it("treats an instance check that raises as not in an instance", function()
    env.instanceFails = true
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    assert.are.equal(10, env.tracker:Current().layer)
  end)

  it("forgets the layer after the time to live without a reading", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    env.clock = env.clock + Constants.LAYER_STATE_TTL - 1
    assert.is_truthy(env.tracker:Current())
    env.clock = env.clock + 2
    assert.is_nil(env.tracker:Current())
  end)

  it("keeps the layer alive while it is read again", function()
    env.tracker:Observe(guid(10, 1))
    env.tracker:Observe(guid(10, 2))
    env.clock = env.clock + Constants.LAYER_STATE_TTL - 1
    env.tracker:Observe(guid(10, 3))
    env.clock = env.clock + Constants.LAYER_STATE_TTL - 1
    assert.is_truthy(env.tracker:Current())
  end)

  it("does not confirm from readings that are older than the time to live", function()
    env.tracker:Observe(guid(10, 1))
    env.clock = env.clock + Constants.LAYER_STATE_TTL + 1
    env.tracker:Observe(guid(10, 2))
    assert.is_nil(env.tracker:Current())
  end)

  describe("ResetSince", function()
    it("drops what was read before the time, the confirmed layer included", function()
      env.tracker:Observe(guid(10, 1))
      env.tracker:Observe(guid(10, 2))
      env.clock = env.clock + 10
      env.tracker:ResetSince(env.clock)
      assert.is_nil(env.tracker:Current())
      assert.are.equal(0, #env.tracker.readings)
    end)

    it("lets the readings taken afterwards confirm a layer", function()
      env.tracker:Observe(guid(10, 1))
      env.tracker:Observe(guid(10, 2))
      env.clock = env.clock + 10
      env.tracker:ResetSince(env.clock)
      env.tracker:Observe(guid(20, 3))
      env.tracker:Observe(guid(20, 4))
      assert.are.equal(20, env.tracker:Current().layer)
      assert.are.equal(2, #env.changes)
    end)

    it("keeps a layer confirmed after the time", function()
      env.clock = env.clock + 10
      env.tracker:Observe(guid(10, 1))
      env.tracker:Observe(guid(10, 2))
      env.tracker:ResetSince(env.clock - 5)
      assert.is_truthy(env.tracker:Current())
    end)
  end)
end)
