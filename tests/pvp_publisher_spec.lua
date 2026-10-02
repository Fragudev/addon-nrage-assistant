local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Validate",
    "Domain/PvPService",
    "Domain/PvPPublisher",
    "Sync/SyncRules",
    "Sync/PvPSync",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

-- A publisher on fakes: a manual clock, a timer that only runs when asked, and a transport that records.
local function build(options)
  options = options or {}
  local env = { clock = 1000, sent = {}, timers = {}, accept = true, blows = true, day = "2026-10-01" }
  env.sync = { rev = options.rev or 0 }
  env.stats = ns.PvPService.Ensure(options.stats or {})
  env.publisher = ns.PvPPublisher.New({
    sync = env.sync,
    stats = env.stats,
    send = function(payload)
      env.sent[#env.sent + 1] = payload
      if env.accept then
        return true
      end
      return false, "full"
    end,
    now = function()
      return env.clock
    end,
    serverTime = function()
      return 5000 + env.clock
    end,
    day = function()
      return env.day
    end,
    blowsAvailable = function()
      return env.blows
    end,
    schedule = function(delay, fn)
      env.timers[#env.timers + 1] = { delay = delay, fn = fn }
    end,
    random = function(low)
      return low
    end,
  })
  -- Runs the oldest timer, moving the clock to its due time.
  function env.fire()
    local timer = table.remove(env.timers, 1)
    env.clock = env.clock + timer.delay
    timer.fn()
  end
  return env
end

describe("PvPPublisher", function()
  it("sends a change after a short delay, with the counters and the next revision", function()
    local env = build({ rev = 4 })
    ns.PvPService.RecordHonorKills(env.stats, 3, "world", "2026-10-01")
    env.publisher:Changed()
    assert.are.equal(1, #env.timers)
    assert.are.equal(Constants.PVP_SYNC_MIN_DELAY_SECONDS, env.timers[1].delay)
    assert.are.equal(0, #env.sent)

    env.fire()
    assert.are.equal(1, #env.sent)
    local payload = env.sent[1]
    assert.are.equal(5, payload.rev)
    assert.are.equal(5000 + env.clock, payload.updatedAt)
    assert.are.same({ world = 3, bg = 0 }, payload.honor)
    assert.are.same({ world = 3, bg = 0 }, payload.today.honor)
    assert.are.equal("2026-10-01", payload.today.day)
    assert.are.equal(5, env.sync.rev)
  end)

  it("coalesces a burst of changes into one message with the latest counters", function()
    local env = build()
    for _ = 1, 5 do
      ns.PvPService.RecordHonorKills(env.stats, 1, "bg", "2026-10-01")
      env.publisher:Changed()
    end
    assert.are.equal(1, #env.timers)
    env.fire()
    assert.are.equal(1, #env.sent)
    assert.are.equal(5, env.sent[1].honor.bg)
  end)

  it("sends at most once per interval", function()
    local env = build()
    ns.PvPService.RecordHonorKills(env.stats, 1, "world", "2026-10-01")
    env.publisher:Changed()
    env.fire()
    assert.are.equal(1, #env.sent)

    env.clock = env.clock + 10
    ns.PvPService.RecordHonorKills(env.stats, 1, "world", "2026-10-01")
    env.publisher:Changed()
    -- Due at the end of the interval counted from the previous send.
    assert.are.equal(1, #env.timers)
    assert.are.equal(Constants.PVP_SYNC_INTERVAL_SECONDS - 10, env.timers[1].delay)
    env.fire()
    assert.are.equal(2, #env.sent)
    assert.are.equal(2, env.sent[2].rev)
    assert.are.equal(env.sent[1].updatedAt + Constants.PVP_SYNC_INTERVAL_SECONDS, env.sent[2].updatedAt)
  end)

  it("does not send when nothing changed", function()
    local env = build()
    local ok, reason = env.publisher:Send()
    assert.is_false(ok)
    assert.are.equal("unchanged", reason)
    ns.PvPService.RecordHonorKills(env.stats, 1, "world", "2026-10-01")
    env.publisher:Changed()
    env.fire()
    ok, reason = env.publisher:Send()
    assert.is_false(ok)
    assert.are.equal("unchanged", reason)
    assert.are.equal(1, #env.sent)
  end)

  it("leaves the killing blows out when they are not available", function()
    local env = build()
    env.blows = false
    env.publisher:Changed()
    env.fire()
    assert.is_nil(env.sent[1].blows)
    assert.is_nil(env.sent[1].today.blows)
  end)

  it("keeps the revision and tries again later when the message could not be queued", function()
    local env = build({ rev = 2 })
    env.accept = false
    env.publisher:Changed()
    env.fire()
    assert.are.equal(2, env.sync.rev)
    assert.are.equal(1, #env.timers)
    assert.are.equal(Constants.PVP_SYNC_INTERVAL_SECONDS, env.timers[1].delay)
    env.accept = true
    env.fire()
    assert.are.equal(3, env.sync.rev)
    assert.are.equal(3, env.sent[2].rev)
  end)

  it("waits when the server day cannot be read", function()
    local env = build()
    env.day = nil
    env.publisher:Changed()
    env.fire()
    assert.are.equal(0, #env.sent)
    env.day = "2026-10-01"
    local ok = env.publisher:Send()
    assert.is_true(ok)
  end)

  describe("after login", function()
    it("sends once after the login delay when there are counters", function()
      local env = build()
      ns.PvPService.RecordHonorKills(env.stats, 7, "world", "2026-10-01")
      env.publisher:SendAtLogin()
      assert.are.equal(Constants.PVP_LOGIN_SEND_DELAY_MIN, env.timers[1].delay)
      env.fire()
      assert.are.equal(1, #env.sent)
      assert.are.equal(7, env.sent[1].honor.world)
    end)

    it("sends when the character published before, even with zero counters", function()
      local env = build({ rev = 3 })
      env.publisher:SendAtLogin()
      env.fire()
      assert.are.equal(1, #env.sent)
      assert.are.equal(4, env.sent[1].rev)
    end)

    it("has nothing to tell a character without kills that never published", function()
      local env = build()
      env.publisher:SendAtLogin()
      env.fire()
      assert.are.equal(0, #env.sent)
    end)

    it("does not repeat a send that already happened", function()
      local env = build()
      ns.PvPService.RecordHonorKills(env.stats, 1, "world", "2026-10-01")
      env.publisher:SendAtLogin()
      env.publisher:Changed()
      env.fire()
      env.fire()
      assert.are.equal(1, #env.sent)
    end)
  end)

  describe("after an admin reset", function()
    it("continues above the revision of the reset and tells the zeroed counters", function()
      local env = build({ rev = 3 })
      env.publisher:OnReset(10)
      assert.are.equal(10, env.sync.rev)
      env.fire()
      assert.are.equal(11, env.sent[1].rev)
    end)

    it("keeps a higher revision of its own", function()
      local env = build({ rev = 30 })
      env.publisher:OnReset(10)
      assert.are.equal(30, env.sync.rev)
    end)
  end)
end)
