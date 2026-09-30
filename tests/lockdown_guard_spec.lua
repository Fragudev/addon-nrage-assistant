local function load_guard()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/LockdownGuard.lua"))("NrageAssistant", ns)
  return ns.LockdownGuard
end

local function fake_platform()
  local p = { locked = false, clock = 0 }
  p.IsChatMessagingLockedDown = function()
    return p.locked
  end
  p.Now = function()
    p.clock = p.clock + 1
    return p.clock
  end
  p.WallClock = function()
    return "12:00:00"
  end
  return p
end

describe("LockdownGuard", function()
  local LockdownGuard = load_guard()
  local platform, guard

  before_each(function()
    platform = fake_platform()
    guard = LockdownGuard.New(platform)
  end)

  it("reports no transition while the state is unchanged", function()
    assert.is_false(guard:Poll())
    assert.are.equal(0, #guard:GetLog())
  end)

  it("logs the start and end of a lockdown with the last event as context", function()
    guard:Note("ENCOUNTER_START")
    platform.locked = true
    assert.is_true(guard:Poll())
    guard:Note("ENCOUNTER_END")
    platform.locked = false
    assert.is_true(guard:Poll())

    local log = guard:GetLog()
    assert.are.equal(4, #log)
    assert.are.equal("started after ENCOUNTER_START", log[2].detail)
    assert.is_true(log[2].locked)
    assert.are.equal("ended after ENCOUNTER_END", log[4].detail)
    assert.is_false(log[4].locked)
  end)

  it("does not log the same transition twice", function()
    platform.locked = true
    assert.is_true(guard:Poll())
    assert.is_false(guard:Poll())
    assert.are.equal(1, #guard:GetLog())
  end)

  it("reads CanSend live from the client, not from the cached state", function()
    assert.is_true(guard:CanSend())
    platform.locked = true
    assert.is_false(guard:CanSend())
  end)

  it("starts from the current lockdown state without logging a transition", function()
    platform.locked = true
    local late = LockdownGuard.New(platform)
    assert.is_false(late:Poll())
    assert.are.equal(0, #late:GetLog())
  end)

  it("caps the log at 200 entries, dropping the oldest", function()
    for i = 1, 250 do
      guard:Record("send", "PING:" .. i)
    end
    local log = guard:GetLog()
    assert.are.equal(200, #log)
    assert.are.equal("PING:51", log[1].detail)
    assert.are.equal("PING:250", log[200].detail)
  end)

  it("clears the log", function()
    guard:Record("send", "PING:1")
    guard:Clear()
    assert.are.equal(0, #guard:GetLog())
  end)
end)
