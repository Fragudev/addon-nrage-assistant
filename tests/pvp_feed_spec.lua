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

-- A fake client: `clock` is the monotonic clock, `scheduled` the timers (run with env.advance), `sent` what went
-- to the transport and `settings` the saved feed switches.
local function build()
  local env = {
    clock = 100,
    locked = false,
    sent = {},
    scheduled = {},
    changes = 0,
    settings = { feedWorld = true, feedBg = false },
    sendOk = true,
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
    settings = function()
      return env.settings
    end,
    ownName = function()
      return "Me"
    end,
    onChange = function()
      env.changes = env.changes + 1
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

  it("sends nothing and lists nothing for a place that is switched off", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "bg")
    env.advance(MERGE)
    assert.are.same({}, env.sent)
    assert.are.same({}, env.feed:Entries())

    env.settings.feedBg = true
    env.feed:OnHonorKill("Yan", "bg")
    env.advance(MERGE)
    assert.are.equal("bg", env.sent[1].where)
  end)

  it("honours a switch turned off while the entry waits", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.settings.feedWorld = false
    env.advance(MERGE)
    assert.are.same({}, env.sent)
  end)

  it("uses the default for a setting that is not a boolean", function()
    local env = build()
    env.settings.feedWorld = "yes"
    env.settings.feedBg = 1
    env.feed:OnHonorKill("Zed", "world")
    env.feed:OnHonorKill("Yan", "bg")
    env.advance(MERGE)
    assert.are.equal(1, #env.sent)
    assert.are.equal("world", env.sent[1].where)
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

describe("PvPFeed received kills", function()
  local function kill(victim, where, blow)
    return { victim = victim, where = where or "world", blow = blow or false }
  end

  it("lists an entry newest first and asks for a chat line", function()
    local env = build()
    local show, entry = env.feed:OnReceived("Ann", kill("Zed"))
    assert.is_true(show)
    assert.are.same({ "Ann" }, entry.killers)
    env.clock = env.clock + 60
    env.feed:OnReceived("Bob", kill("Yan"))
    local names = {}
    for _, listed in ipairs(env.feed:Entries()) do
      names[#names + 1] = listed.victim
    end
    assert.are.same({ "Yan", "Zed" }, names)
  end)

  it("merges the killers of the same victim within the window and prints one line", function()
    local env = build()
    assert.is_true((env.feed:OnReceived("Ann", kill("Zed"))))
    local show, entry = env.feed:OnReceived("Bob", kill("zed", "world", true))
    assert.is_false(show)
    assert.are.same({ "Ann", "Bob" }, entry.killers)
    assert.is_true(entry.blow)
    assert.are.equal(1, #env.feed:Entries())
    -- The same sender twice is listed once.
    env.feed:OnReceived("Bob", kill("Zed"))
    assert.are.same({ "Ann", "Bob" }, env.feed:Entries()[1].killers)
  end)

  it("makes a new entry once the dedupe window has passed", function()
    local env = build()
    env.feed:OnReceived("Ann", kill("Zed"))
    env.clock = env.clock + Constants.PVP_FEED_DEDUPE_SECONDS + 1
    assert.is_true((env.feed:OnReceived("Bob", kill("Zed"))))
    assert.are.equal(2, #env.feed:Entries())
  end)

  it("bounds the killers of one entry", function()
    local env = build()
    for index = 1, Constants.PVP_FEED_KILLERS_MAX + 4 do
      env.feed:OnReceived("Killer" .. index, kill("Zed"))
    end
    assert.are.equal(Constants.PVP_FEED_KILLERS_MAX, #env.feed:Entries()[1].killers)
  end)

  it("bounds the list to the newest entries", function()
    local env = build()
    for index = 1, Constants.PVP_FEED_MAX + 10 do
      env.clock = env.clock + 100
      env.feed:OnReceived("Ann", kill("Victim" .. index))
    end
    local list = env.feed:Entries()
    assert.are.equal(Constants.PVP_FEED_MAX, #list)
    assert.are.equal("Victim" .. (Constants.PVP_FEED_MAX + 10), list[1].victim)
  end)

  it("limits how much one sender can add per minute", function()
    local env = build()
    for index = 1, Constants.PVP_FEED_MAX_PER_MINUTE + 5 do
      env.feed:OnReceived("Spammer", kill("Victim" .. index))
    end
    assert.are.equal(Constants.PVP_FEED_MAX_PER_MINUTE, #env.feed:Entries())
    env.clock = env.clock + 61
    assert.is_true((env.feed:OnReceived("Spammer", kill("Fresh"))))
  end)

  it("bounds the number of senders it remembers", function()
    local env = build()
    for index = 1, Constants.PVP_FEED_SENDERS_MAX do
      env.feed:OnReceived("Sender" .. index, kill("Victim" .. index))
    end
    assert.is_false((env.feed:OnReceived("OneTooMany", kill("Zed"))))
    env.clock = env.clock + 61
    assert.is_true((env.feed:OnReceived("OneTooMany", kill("Zed"))))
  end)

  it("ignores a place that is switched off", function()
    local env = build()
    assert.is_false((env.feed:OnReceived("Ann", kill("Zed", "bg"))))
    assert.are.same({}, env.feed:Entries())
    env.settings.feedBg = true
    assert.is_true((env.feed:OnReceived("Ann", kill("Zed", "bg"))))
    env.settings.feedWorld = false
    assert.is_false((env.feed:OnReceived("Ann", kill("Yan", "world"))))
    assert.are.equal(1, #env.feed:Entries())
  end)

  it("ignores what is not a usable payload or sender", function()
    local env = build()
    assert.is_false((env.feed:OnReceived(nil, kill("Zed"))))
    assert.is_false((env.feed:OnReceived("Ann", nil)))
    assert.is_false((env.feed:OnReceived("Ann", { victim = "Zed", where = "moon" })))
    assert.is_false((env.feed:OnReceived("Ann", { victim = "A|B", where = "world" })))
    assert.are.same({}, env.feed:Entries())
  end)

  it("treats a blow that is not exactly true as no blow", function()
    local env = build()
    local _, entry = env.feed:OnReceived("Ann", { victim = "Zed", where = "world", blow = "yes" })
    assert.is_false(entry.blow)
  end)

  it("merges a received kill into an own entry of the same victim", function()
    local env = build()
    env.feed:OnHonorKill("Zed", "world")
    env.clock = env.clock + 3
    local show, entry = env.feed:OnReceived("Ann", kill("Zed"))
    assert.is_false(show)
    assert.are.same({ "Me", "Ann" }, entry.killers)
    assert.are.equal(1, #env.feed:Entries())
  end)

  it("tells the UI about every change", function()
    local env = build()
    env.feed:OnReceived("Ann", kill("Zed"))
    env.feed:OnReceived("Bob", kill("Zed"))
    assert.are.equal(2, env.changes)
  end)
end)

describe("PvPFeed availability and settings", function()
  it("is available when either source of a victim name exists", function()
    local env = build()
    assert.is_false(env.feed:Available())
    env.feed.honorNames = true
    assert.is_true(env.feed:Available())
    env.feed.honorNames, env.feed.blowNames = false, true
    assert.is_true(env.feed:Available())
  end)

  it("creates and repairs the saved settings with their defaults", function()
    local db = { global = {} }
    assert.are.same({ feedWorld = true, feedBg = false }, PvPFeed.Settings(db))
    db.global.settings.pvp = { feedWorld = false, feedBg = "x" }
    assert.are.same({ feedWorld = false, feedBg = false }, PvPFeed.Settings(db))
    db.global.settings = "oops"
    local settings = PvPFeed.Settings(db)
    assert.are.same({ feedWorld = true, feedBg = false }, settings)
    assert.are.equal(settings, db.global.settings.pvp)
  end)
end)
