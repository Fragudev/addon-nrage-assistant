local function load_publisher()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PositionModel",
    "Domain/PositionPublisher",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_publisher()
local Constants = ns.Constants

local function build()
  local env = {
    clock = 100,
    enabled = true,
    canSend = true,
    position = { map = 1411, x = 5000, y = 5000 },
    sent = {},
    sendOk = true,
  }
  env.publisher = ns.PositionPublisher.New({
    now = function()
      return env.clock
    end,
    current = function()
      return env.position
    end,
    enabled = function()
      return env.enabled
    end,
    canSend = function()
      if env.canSendFails then
        error("lockdown api")
      end
      return env.canSend
    end,
    send = function(text)
      if env.sendFails then
        error("transport")
      end
      env.sent[#env.sent + 1] = text
      return env.sendOk
    end,
  })
  function env.advance(seconds)
    env.clock = env.clock + seconds
  end
  return env
end

describe("PositionPublisher", function()
  local env

  before_each(function()
    env = build()
  end)

  it("sends the position on the first tick", function()
    assert.is_true(env.publisher:Tick())
    assert.are.same({ "P1:1411:5000:5000" }, env.sent)
  end)

  it("sends when the player moved", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = { map = 1411, x = 5000 + Constants.POSITION_MIN_MOVE + 1, y = 5000 }
    assert.is_true(env.publisher:Tick())
    assert.are.equal("P1:1411:5021:5000", env.sent[2])
  end)

  it("sends when the map changed, even without moving", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = { map = 1412, x = 5000, y = 5000 }
    assert.is_true(env.publisher:Tick())
    assert.are.equal("P1:1412:5000:5000", env.sent[2])
  end)

  it("does not send when nothing changed", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = { map = 1411, x = 5000 + Constants.POSITION_MIN_MOVE, y = 5000 }
    assert.is_false(env.publisher:Tick())
    assert.are.equal(1, #env.sent)
  end)

  it("sends the heartbeat after the interval, and not before", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_HEARTBEAT_SECONDS - 1)
    assert.is_false(env.publisher:Tick())
    env.advance(1)
    assert.is_true(env.publisher:Tick())
    assert.are.equal(2, #env.sent)
  end)

  it("never sends twice within one tick interval", function()
    env.publisher:Tick()
    env.position = { map = 1412, x = 1, y = 1 }
    env.advance(Constants.POSITION_TICK_SECONDS - 1)
    assert.is_false(env.publisher:Tick())
    assert.are.equal(1, #env.sent)
  end)

  it("sends nothing while sharing is off", function()
    env.enabled = false
    assert.is_false(env.publisher:Tick())
    assert.are.same({}, env.sent)
  end)

  it("sends nothing while the lockdown does not allow it, or when the check fails", function()
    env.canSend = false
    assert.is_false(env.publisher:Tick())
    env.canSend = true
    env.canSendFails = true
    assert.is_false(env.publisher:Tick())
    assert.are.same({}, env.sent)
    env.canSendFails = false
    assert.is_true(env.publisher:Tick())
  end)

  it("sends nothing when there is no position and nothing was published", function()
    env.position = nil
    assert.is_false(env.publisher:Tick())
    assert.are.same({}, env.sent)
  end)

  it("sends one forget when the position disappears, and not again", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = nil
    assert.is_true(env.publisher:Tick())
    assert.are.equal("P1:0", env.sent[2])
    env.advance(Constants.POSITION_TICK_SECONDS)
    assert.is_false(env.publisher:Tick())
    assert.are.equal(2, #env.sent)
  end)

  it("sends the position again at once when it comes back after a forget", function()
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = nil
    env.publisher:Tick()
    env.advance(Constants.POSITION_TICK_SECONDS)
    env.position = { map = 1411, x = 5000, y = 5000 }
    assert.is_true(env.publisher:Tick())
    assert.are.equal("P1:1411:5000:5000", env.sent[3])
  end)

  it("tries again on the next tick when the send is refused", function()
    env.sendOk = false
    assert.is_false(env.publisher:Tick())
    env.sendOk = true
    assert.is_true(env.publisher:Tick())
    assert.are.equal(2, #env.sent)
  end)

  it("survives a transport that raises", function()
    env.sendFails = true
    assert.has_no.errors(function()
      env.publisher:Tick()
      env.publisher:Forget()
    end)
    assert.is_false(env.publisher:Tick())
  end)

  it("does not send an invalid position", function()
    env.position = { map = 0, x = 1, y = 1 }
    assert.is_false(env.publisher:Tick())
    assert.are.same({}, env.sent)
  end)

  it("forgets when sharing stops, without waiting for the throttle", function()
    env.publisher:Tick()
    assert.is_true(env.publisher:Forget())
    assert.are.equal("P1:0", env.sent[2])
  end)

  it("forgets even before anything was published this session (after a reload)", function()
    assert.is_true(env.publisher:Forget())
    assert.are.equal("P1:0", env.sent[1])
  end)

  it("keeps trying to forget when the send is refused", function()
    env.publisher:Tick()
    env.sendOk = false
    assert.is_false(env.publisher:Forget())
    env.sendOk = true
    assert.is_true(env.publisher:Forget())
  end)

  it("publishes at once when sharing is switched on again after forgetting", function()
    env.publisher:Tick()
    env.publisher:Forget()
    env.advance(Constants.POSITION_TICK_SECONDS)
    assert.is_true(env.publisher:Tick())
    assert.are.equal(3, #env.sent)
  end)
end)
