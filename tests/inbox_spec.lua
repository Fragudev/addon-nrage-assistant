local function load_inbox()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Constants.lua"))("NrageAssistant", ns)
  assert(loadfile("NrageAssistant/Sync/Inbox.lua"))("NrageAssistant", ns)
  return ns.Inbox
end

describe("Inbox", function()
  local Inbox = load_inbox()

  it("accepts a new message", function()
    assert.is_true(Inbox.New():Accept("Nrager-Realm", "id-1", 0))
  end)

  it("rejects a missing sender", function()
    local ok, reason = Inbox.New():Accept(nil, "id-1", 0)
    assert.is_false(ok)
    assert.are.equal("bad_sender", reason)
    ok, reason = Inbox.New():Accept("", "id-1", 0)
    assert.is_false(ok)
    assert.are.equal("bad_sender", reason)
  end)

  it("ignores a repeated message id from the same sender", function()
    local inbox = Inbox.New()
    assert.is_true(inbox:Accept("A-Realm", "id-1", 0))
    local ok, reason = inbox:Accept("A-Realm", "id-1", 1)
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
  end)

  it("does not let one sender suppress another sender's id", function()
    local inbox = Inbox.New()
    assert.is_true(inbox:Accept("A-Realm", "id-1", 0))
    assert.is_true(inbox:Accept("B-Realm", "id-1", 0))
  end)

  it("forgets the oldest ids once the cache is full", function()
    local inbox = Inbox.New({ seenLimit = 3, maxPerWindow = 100 })
    for i = 1, 4 do
      assert.is_true(inbox:Accept("A-Realm", "id-" .. i, 0))
    end
    assert.is_true(inbox:Accept("A-Realm", "id-1", 0))
    local ok, reason = inbox:Accept("A-Realm", "id-4", 0)
    assert.is_false(ok)
    assert.are.equal("duplicate", reason)
  end)

  it("rate limits a sender inside the window and recovers after it", function()
    local inbox = Inbox.New({ maxPerWindow = 3, window = 60 })
    for i = 1, 3 do
      assert.is_true(inbox:Accept("A-Realm", "id-" .. i, 10))
    end
    local ok, reason = inbox:Accept("A-Realm", "id-4", 20)
    assert.is_false(ok)
    assert.are.equal("rate_limited", reason)
    assert.is_true(inbox:Accept("A-Realm", "id-5", 70))
  end)

  it("keeps senders independent", function()
    local inbox = Inbox.New({ maxPerWindow = 1 })
    assert.is_true(inbox:Accept("A-Realm", "id-1", 0))
    assert.is_false(inbox:Accept("A-Realm", "id-2", 0))
    assert.is_true(inbox:Accept("B-Realm", "id-1", 0))
  end)

  it("evicts the sender tracked longest when the tracker is full of active ones", function()
    local inbox = Inbox.New({ maxSenders = 2, maxPerWindow = 1 })
    assert.is_true(inbox:Accept("A-Realm", "1", 0))
    assert.is_true(inbox:Accept("B-Realm", "1", 1))
    -- C is not refused for good: A, the oldest, makes room (and may start a fresh window afterwards).
    assert.is_true(inbox:Accept("C-Realm", "1", 2))
    assert.are.equal(2, inbox.senderCount)
    assert.is_nil(inbox.windows["A-Realm"])
    -- B is still counted: its limit holds.
    assert.is_false(inbox:Accept("B-Realm", "2", 3))
  end)

  it("is sized to the guild limit", function()
    assert.is_true(Inbox.New().maxSenders >= 1000)
  end)

  it("reclaims tracker slots from senders whose window expired", function()
    local inbox = Inbox.New({ maxSenders = 2, window = 60 })
    assert.is_true(inbox:Accept("A-Realm", "1", 0))
    assert.is_true(inbox:Accept("B-Realm", "1", 0))
    assert.is_true(inbox:Accept("C-Realm", "1", 100))
  end)
end)
