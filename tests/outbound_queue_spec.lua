local function load_queue()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/OutboundQueue.lua"))("NrageAssistant", ns)
  return ns.OutboundQueue
end

describe("OutboundQueue", function()
  local OutboundQueue = load_queue()
  local guard, clock, sent, jitter, queue

  before_each(function()
    guard = { locked = false }
    function guard:CanSend() return not self.locked end
    clock = 0
    sent = {}
    jitter = 0
    queue = OutboundQueue.New({
      guard = guard,
      now = function() return clock end,
      send = function(text) sent[#sent + 1] = text end,
      jitter = function() return jitter end,
      maxItems = 3,
      ttl = 100,
      maxJitter = 5,
    })
  end)

  it("sends immediately on flush when nothing blocks it", function()
    queue:Enqueue("a")
    assert.are.equal(1, queue:Flush())
    assert.are.same({ "a" }, sent)
    assert.are.equal(0, queue:Pending())
  end)

  it("holds messages during a lockdown and reports it as paused", function()
    guard.locked = true
    queue:Enqueue("a")
    local count, reason = queue:Flush()
    assert.are.equal(0, count)
    assert.are.equal("paused", reason)
    assert.is_true(queue:IsPaused())
    assert.are.same({}, sent)
  end)

  it("drains with jitter once the lockdown ends", function()
    guard.locked = true
    queue:Enqueue("a")
    guard.locked = false
    jitter = 3

    assert.are.equal(0, queue:Flush())
    assert.is_false(queue:IsPaused())
    assert.are.equal(1, queue:Pending())

    clock = 2
    assert.are.equal(0, queue:Flush())
    clock = 3
    assert.are.equal(1, queue:Flush())
    assert.are.same({ "a" }, sent)
  end)

  it("draws the jitter once, not on every flush", function()
    guard.locked = true
    queue:Enqueue("a")
    guard.locked = false
    jitter = 4
    queue:Flush()
    jitter = 0
    clock = 1
    assert.are.equal(0, queue:Flush())
    clock = 4
    assert.are.equal(1, queue:Flush())
  end)

  it("drops messages that outlive their TTL", function()
    guard.locked = true
    queue:Enqueue("a")
    clock = 100
    guard.locked = false
    assert.are.equal(0, queue:Flush())
    assert.are.equal(0, queue:Pending())
    assert.are.same({}, sent)
  end)

  it("refuses to grow past its limit", function()
    for i = 1, 3 do
      assert.is_true(queue:Enqueue("m" .. i))
    end
    local ok, reason = queue:Enqueue("m4")
    assert.is_false(ok)
    assert.are.equal("full", reason)
    assert.are.equal(3, queue:Pending())
  end)

  it("replaces a queued message that has the same key", function()
    guard.locked = true
    queue:Enqueue("old", "PROFILE")
    queue:Enqueue("new", "PROFILE")
    assert.are.equal(1, queue:Pending())
    guard.locked = false
    queue:Flush()
    assert.are.same({ "new" }, sent)
  end)

  it("frees room by expiring old messages before checking the limit", function()
    guard.locked = true
    for i = 1, 3 do queue:Enqueue("m" .. i) end
    clock = 200
    assert.is_true(queue:Enqueue("fresh"))
    assert.are.equal(1, queue:Pending())
  end)

  it("keeps draining when one send raises", function()
    queue.send = function(text)
      if text == "bad" then error("boom") end
      sent[#sent + 1] = text
    end
    queue:Enqueue("bad")
    queue:Enqueue("good")
    assert.are.equal(1, queue:Flush())
    assert.are.same({ "good" }, sent)
  end)

  it("clears everything", function()
    queue:Enqueue("a")
    queue:Clear()
    assert.are.equal(0, queue:Pending())
  end)
end)
