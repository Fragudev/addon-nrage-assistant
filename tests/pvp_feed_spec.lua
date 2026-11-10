local function load_feed()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/PvPFeed" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_feed()
local PvPFeed = ns.PvPFeed
local Constants = ns.Constants

-- A fake client: `clock` is the monotonic clock, `scheduled` the timers (run with env.advance), and `sent` what went
-- to the transport.
local function build()
  local env = {
    clock = 100,
    locked = false,
    sent = {},
    scheduled = {},
    changes = 0,
    sendOk = true,
    honor = {},
  }
  env.feed = PvPFeed.New({
    now = function()
      return env.clock
    end,
    serverTime = function()
      return 5000 + env.clock
    end,
    send = function(payload)
      if env.sendFails then
        error("transport")
      end
      env.sent[#env.sent + 1] = payload
      return env.sendOk, "queue_full"
    end,
    isLocked = function()
      if env.lockFails then
        error("secret")
      end
      return env.locked
    end,
    schedule = function(delay, fn)
      env.scheduled[#env.scheduled + 1] = { at = env.clock + delay, fn = fn }
    end,
    ownName = function()
      return "Me"
    end,
    onChange = function()
      env.changes = env.changes + 1
    end,
    onHonorKill = function(entry)
      if env.honorFails then
        error("listener")
      end
      env.honor[#env.honor + 1] = entry
    end,
  })
  -- Moves the clock and runs the timers that are due.
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

local MERGE = Constants.PVP_FEED_MERGE_SECONDS

describe("PvPFeed own kills", function()
  it("tells the listener about every honour kill, also two of the same victim inside the merge window", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.feed:OnHonorKill("zed", "world")
    env.feed:OnKillingBlow("Zed", "world")
    assert.are.equal(2, #env.honor)
    assert.are.equal("Zed", env.honor[1].victim)
    assert.are.equal("zed", env.honor[2].victim)
    assert.are.equal(5100, env.honor[1].time)
    -- the feed still shows and sends one merged entry
    assert.are.equal(1, #env.feed:Entries())

    env = build()
    env.feed:OnKillingBlow("Zed", "world")
    assert.are.equal(0, #env.honor)
    env.feed:OnHonorKill("Zed", "world")
    assert.are.equal(1, #env.honor)
  end)

  it("does not tell the listener about a refused victim, and a failing listener changes nothing", function()
    local env = build()
    env.feed:OnHonorKill("", "world")
    env.feed:OnHonorKill("Zed", "sky")
    env.feed:OnHonorKill(nil, "world")
    assert.are.equal(0, #env.honor)
    env.honorFails = true
    assert.is_true(env.feed:OnHonorKill("Zed", "world"))
    env.advance(MERGE)
    assert.are.equal(1, #env.sent)
  end)

  it("sends an honour kill after the merge delay, not before", function()
    local env = build()
    assert.is_true(env.feed:OnHonorKill("Zed", "world"))
    assert.are.same({}, env.sent)
    env.advance(MERGE)
    assert.are.same({ { victim = "Zed", where = "world", blow = false } }, env.sent)
  end)

  it("merges an honour kill and the killing blow into one entry, in either order", function()
    local env = build()
    assert.is_true(env.feed:OnHonorKill("Zed", "world"))
    assert.is_false(env.feed:OnKillingBlow("zed", "world"))
    env.advance(MERGE)
    assert.are.same({ { victim = "Zed", where = "world", blow = true } }, env.sent)

    env = build()
    assert.is_true(env.feed:OnKillingBlow("Zed", "world"))
    assert.is_false(env.feed:OnHonorKill("Zed", "world"))
    env.advance(MERGE)
    assert.are.same({ { victim = "Zed", where = "world", blow = true } }, env.sent)
    assert.are.equal(1, #env.feed:Entries())
  end)

  it("sends a killing blow without honour on its own", function()
    local env = build()
    env.feed:OnKillingBlow("Grey", "world")
    env.advance(MERGE)
    assert.are.same({ { victim = "Grey", where = "world", blow = true } }, env.sent)
  end)

  it("treats a blow after the merge window as a new kill", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.advance(MERGE)
    env.advance(1)
    -- A later blow after the window is a new kill of the same name, not a change of the sent one.
    assert.is_true(env.feed:OnKillingBlow("Zed", "world"))
    assert.are.equal(1, #env.sent)
    env.advance(MERGE)
    assert.are.equal(2, #env.sent)
  end)

  it("makes one entry per victim, so group credit is one message per honour kill", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.feed:OnHonorKill("Yan", "world")
    env.advance(MERGE)
    assert.are.equal(2, #env.sent)
  end)

  it("adds the own kill to the local list with the own name", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    local entry = env.feed:Entries()[1]
    assert.are.equal("Zed", entry.victim)
    assert.are.same({ "Me" }, entry.killers)
    assert.is_true(entry.own)
    assert.are.equal(1, env.changes)
  end)

  it("sends at most the per-minute limit, dropping the rest", function()
    local env = build()
    for index = 1, Constants.PVP_FEED_MAX_PER_MINUTE + 3 do
      env.feed:OnHonorKill("Victim" .. index, "world")
    end
    env.advance(MERGE)
    assert.are.equal(Constants.PVP_FEED_MAX_PER_MINUTE, #env.sent)
    -- The dropped ones are not queued: nothing more goes out later in the same minute.
    env.advance(30)
    assert.are.equal(Constants.PVP_FEED_MAX_PER_MINUTE, #env.sent)
    -- A minute after the first sends, there is room again.
    env.advance(40)
    env.feed:OnHonorKill("Later", "world")
    env.advance(MERGE)
    assert.are.equal(Constants.PVP_FEED_MAX_PER_MINUTE + 1, #env.sent)
  end)

  it("does not count a failed send against the limit", function()
    local env = build()
    env.sendOk = false
    for index = 1, Constants.PVP_FEED_MAX_PER_MINUTE do
      env.feed:OnHonorKill("Victim" .. index, "world")
    end
    env.advance(MERGE)
    env.sendOk = true
    env.feed:OnHonorKill("Next", "world")
    env.advance(MERGE)
    assert.are.equal("Next", env.sent[#env.sent].victim)
  end)

  it("drops an entry during the lockdown instead of queueing it", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.locked = true
    env.advance(MERGE)
    env.locked = false
    env.advance(60)
    assert.are.same({}, env.sent)
    -- It stays in the local list: only the sharing was dropped.
    assert.are.equal(1, #env.feed:Entries())
  end)

  it("treats an unreadable lockdown state as locked", function()
    local env = build()
    env.lockFails = true
    env.feed:OnHonorKill("Zed", "world")
    env.advance(MERGE)
    assert.are.same({}, env.sent)
  end)

  it("survives a transport that raises", function()
    local env = build()
    env.sendFails = true
    env.feed:OnHonorKill("Zed", "world")
    assert.has_no.errors(function()
      env.advance(MERGE)
    end)
  end)

  it("lists and sends the kills of every place", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.feed:OnHonorKill("Yan", "bg")
    env.advance(MERGE)
    assert.are.equal(2, #env.feed:Entries())
    assert.are.equal("world", env.sent[1].where)
    assert.are.equal("bg", env.sent[2].where)
  end)

  it("ignores victims and places it cannot send", function()
    local env = build()
    assert.is_false(env.feed:OnHonorKill(nil, "world"))
    assert.is_false(env.feed:OnHonorKill("", "world"))
    assert.is_false(env.feed:OnHonorKill("Bad|cffff0000Name", "world"))
    assert.is_false(env.feed:OnHonorKill(("x"):rep(Constants.PVP_FEED_VICTIM_MAX + 1), "world"))
    assert.is_false(env.feed:OnHonorKill("Zed", "arena"))
    assert.is_false(env.feed:OnHonorKill({}, "world"))
    env.advance(MERGE)
    assert.are.same({}, env.sent)
  end)

  it("keeps multi-word names whole", function()
    local env = build()
    env.feed:OnHonorKill("Yonemon Gg", "world")
    env.advance(MERGE)
    assert.are.equal("Yonemon Gg", env.sent[1].victim)
  end)
end)

describe("PvPFeed availability", function()
  it("is available when either source of a victim name exists", function()
    local env = build()
    assert.is_false(env.feed:Available())
    env.feed.honorNames = true
    assert.is_true(env.feed:Available())
    env.feed.honorNames, env.feed.blowNames = false, true
    assert.is_true(env.feed:Available())
  end)
end)
