local function load_publisher()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Domain/LayerPublisher" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_publisher()
local Constants = ns.Constants

local function build()
  local env = { clock = 100, enabled = true, layer = { map = 0, layer = 10 }, sent = {}, scheduled = {}, sendOk = true }
  env.publisher = ns.LayerPublisher.New({
    now = function()
      return env.clock
    end,
    schedule = function(delay, fn)
      env.scheduled[#env.scheduled + 1] = { at = env.clock + delay, fn = fn }
    end,
    send = function(payload)
      if env.sendFails then
        error("transport")
      end
      env.sent[#env.sent + 1] = payload
      return env.sendOk
    end,
    current = function()
      return env.layer
    end,
    enabled = function()
      return env.enabled
    end,
  })
  function env.advance(seconds)
    env.clock = env.clock + seconds
    local due, rest = {}, {}
    for _, timer in ipairs(env.scheduled) do
      table.insert(timer.at <= env.clock and due or rest, timer)
    end
    env.scheduled = rest
    for _, timer in ipairs(due) do
      timer.fn()
    end
  end
  return env
end

describe("LayerPublisher", function()
  local env

  before_each(function()
    env = build()
  end)

  it("sends the layer when it changes", function()
    env.publisher:Changed()
    assert.are.same({ { map = 0, layer = 10 } }, env.sent)
  end)

  it("sends the zone the layer was read in", function()
    env.layer = { map = 0, layer = 10, zone = 1429 }
    env.publisher:Changed()
    assert.are.same({ { map = 0, layer = 10, zone = 1429 } }, env.sent)
  end)

  it("sends nothing while the layer is unknown or sharing is off", function()
    env.layer = nil
    env.publisher:Changed()
    env.publisher:Tick()
    env.layer = { map = 0, layer = 10 }
    env.enabled = false
    env.publisher:Changed()
    env.publisher:Tick()
    assert.are.same({}, env.sent)
  end)

  it("waits for the end of the throttle window after a quick second change", function()
    env.publisher:Changed()
    env.advance(5)
    env.layer = { map = 0, layer = 20 }
    env.publisher:Changed()
    assert.are.equal(1, #env.sent)
    env.advance(Constants.LAYER_PUBLISH_MIN_SECONDS)
    assert.are.equal(2, #env.sent)
    assert.are.equal(20, env.sent[2].layer)
  end)

  it("plans one send only, however many changes come", function()
    env.publisher:Changed()
    env.publisher:Changed()
    env.publisher:Changed()
    assert.are.equal(1, #env.sent)
    env.advance(1)
    env.publisher:Changed()
    env.publisher:Changed()
    assert.are.equal(1, #env.scheduled)
  end)

  it("tries again later when the send is refused", function()
    env.sendOk = false
    env.publisher:Changed()
    assert.are.equal(1, #env.sent)
    env.sendOk = true
    env.advance(Constants.LAYER_PUBLISH_MIN_SECONDS)
    assert.are.equal(2, #env.sent)
  end)

  it("survives a transport that raises", function()
    env.sendFails = true
    assert.has_no.errors(function()
      env.publisher:Changed()
      env.publisher:Tick()
    end)
  end)

  it("republishes on the tick, within the throttle", function()
    env.publisher:Changed()
    env.advance(Constants.LAYER_REPUBLISH_SECONDS)
    env.publisher:Tick()
    assert.are.equal(2, #env.sent)
    env.publisher:Tick()
    assert.are.equal(2, #env.sent)
  end)

  it("tells the guild to forget the member when sharing stops", function()
    env.publisher:Changed()
    assert.is_true(env.publisher:Forget())
    assert.are.same({ map = 0, layer = 0 }, env.sent[2])
  end)

  it("tells the guild to forget the member even before anything was published this session (after a reload)", function()
    assert.is_true(env.publisher:Forget())
    assert.are.same({ map = 0, layer = 0 }, env.sent[1])
  end)

  it("keeps trying to forget when the send is refused", function()
    env.publisher:Changed()
    env.sendOk = false
    assert.is_false(env.publisher:Forget())
    env.sendOk = true
    assert.is_true(env.publisher:Forget())
  end)

  it("publishes at once when sharing is switched on again after forgetting", function()
    env.publisher:Changed()
    env.publisher:Forget()
    env.publisher:Changed()
    assert.are.equal(3, #env.sent)
    assert.are.equal(10, env.sent[3].layer)
  end)
end)
