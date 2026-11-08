-- Intel alerts: which kind fires, the cooldown, the delivery and the announcements.
local function load_modules()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/IntelModel",
    "Domain/IntelService",
    "Domain/IntelAlerts",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build(overrides)
  local env = {
    clock = 1000,
    settings = {
      removeMinutes = 5,
      sound = true,
      alertNew = false,
      alertKos = true,
      alertKosGuild = true,
      alertStealth = true,
      alertGuildReports = true,
      alertRaces = {},
      warnTarget = "window",
      announce = "none",
    },
    intel = { players = {}, kos = {}, ignore = {}, zones = {} },
    guildKos = {},
    windows = {},
    errors = {},
    sounds = {},
    said = {},
    sent = {},
    window = true,
    group = nil,
    sendOk = true,
    map = 1411,
  }
  for key, value in pairs(overrides or {}) do
    env[key] = value
  end
  env.service = ns.IntelService.New({
    intel = env.intel,
    guildKos = env.guildKos,
    settings = function()
      return env.settings
    end,
    now = function()
      return env.clock
    end,
    wall = function()
      return 5000000
    end,
  })
  env.alerts = ns.IntelAlerts.New({
    settings = function()
      return env.settings
    end,
    service = env.service,
    now = function()
      return env.clock
    end,
    mapId = function()
      return env.map
    end,
    window = function(text, alert)
      env.windows[#env.windows + 1] = { text = text, kind = alert.kind }
      return env.window
    end,
    errorText = function(text)
      env.errors[#env.errors + 1] = text
    end,
    playSound = function(kind)
      env.sounds[#env.sounds + 1] = kind
    end,
    say = function(text)
      env.said[#env.said + 1] = text
    end,
    send = function(channel, text)
      env.sent[#env.sent + 1] = { channel = channel, text = text }
      return env.sendOk
    end,
    groupChannel = function()
      return env.group
    end,
  })
  return env
end

local function details(overrides)
  local value = { name = "Bob", class = "ROGUE", race = "ORC", level = 60, guild = "Evil", faction = "Horde" }
  for key, inner in pairs(overrides or {}) do
    value[key] = inner
  end
  return value
end

-- Reads an enemy into the service and runs the alert on it, like the detector does.
local function contact(env, overrides)
  local read = details(overrides)
  local result = env.service:OnSeen(read, { map = 1411 })
  return env.alerts:OnContact(result, read), result, read
end

describe("IntelAlerts:Decide", function()
  local env

  before_each(function()
    env = build()
  end)

  local function decide(overrides)
    local read = details(overrides)
    local result = env.service:OnSeen(read, { map = 1411 })
    return env.alerts:Decide(result, read)
  end

  it("is silent for an enemy nothing asks about", function()
    assert.is_nil(decide())
  end)

  it("alerts for a Kill On Sight player, personal or guild", function()
    env.service:AddKos({ name = "Bob" })
    local alert = decide()
    assert.are.equal("kos", alert.kind)
    assert.are.equal("kos", alert.sound)
    assert.is_nil(alert.announce)
    assert.are.equal("Kill on Sight: Bob (level 60) <Evil>", alert.text)
    env.guildKos.eve = { name = "Eve" }
    assert.are.equal("kos", decide({ name = "Eve" }).kind)
  end)

  it("alerts for the guild of a Kill On Sight player but not for the player himself", function()
    env.service:OnSeen(details({ name = "Bob" }), { map = 1 })
    env.service:AddKos({ name = "Bob" })
    local alert = decide({ name = "Zed" })
    assert.are.equal("kosGuild", alert.kind)
    assert.are.equal("kos", decide({ name = "Bob" }).kind)
    assert.is_nil(decide({ name = "Una", guild = "Other" }))
    assert.is_nil(decide({ name = "Vic", guild = false }))
  end)

  it("alerts for a stealth cast, a watched race and, only when asked, a new enemy", function()
    assert.are.equal("stealth", decide({ name = "A", stealth = true }).kind)
    env.settings.alertRaces = { ORC = true }
    assert.are.equal("race", decide({ name = "B" }).kind)
    env.settings.alertRaces = {}
    env.settings.alertNew = true
    assert.are.equal("new", decide({ name = "C" }).kind)
    assert.is_nil(decide({ name = "C" }))
  end)

  it("fires only the first match, in the order of the plan", function()
    env.service:OnSeen(details({ name = "Boss" }), { map = 1 })
    env.service:AddKos({ name = "Boss" })
    env.settings.alertRaces = { ORC = true }
    env.settings.alertNew = true
    assert.are.equal("kos", decide({ name = "Boss", stealth = true }).kind)
    assert.are.equal("kosGuild", decide({ name = "Mate", stealth = true }).kind)
    env.settings.alertKosGuild = false
    assert.are.equal("stealth", decide({ name = "Mate2", stealth = true }).kind)
    env.settings.alertStealth = false
    assert.are.equal("race", decide({ name = "Mate3" }).kind)
  end)

  it("lets a switched off kind fall to the next one", function()
    env.service:AddKos({ name = "Bob" })
    env.settings.alertKos = false
    assert.are.equal("kosGuild", decide().kind)
    env.settings.alertKosGuild = false
    env.settings.alertNew = true
    assert.are.equal("new", decide({ name = "Zed", guild = "Other" }).kind)
  end)

  it("never alerts for an ignored enemy", function()
    env.service:AddIgnore("Bob")
    env.settings.alertNew = true
    assert.is_nil(decide())
    assert.is_nil(env.alerts:Decide(nil, details()))
    assert.is_nil(env.alerts:OnContact({ ignored = true }, details()))
  end)

  it("reports no sound when sounds are off, and the channel of the announcement when one is set", function()
    env.service:AddKos({ name = "Bob" })
    env.settings.sound = false
    env.settings.announce = "guild"
    local alert = decide()
    assert.is_nil(alert.sound)
    assert.are.equal("guild", alert.announce)
  end)

  it("marks an estimated level and drops pipes from a guild name", function()
    env.service:AddKos({ name = "Bob" })
    local alert = decide({ level = 70, levelEstimated = true, guild = "Ev|il" })
    assert.are.equal("Kill on Sight: Bob (level 70?) <Evil>", alert.text)
  end)

  it("looks the Kill On Sight guilds up again only after a few seconds", function()
    env.service:OnSeen(details({ name = "Bob" }), { map = 1 })
    assert.is_nil(decide({ name = "Zed" }))
    env.service:AddKos({ name = "Bob" })
    assert.is_nil(decide({ name = "Una" }))
    env.clock = env.clock + 6
    assert.are.equal("kosGuild", decide({ name = "Vic" }).kind)
  end)
end)

describe("IntelAlerts:OnContact", function()
  local env

  before_each(function()
    env = build()
    env.service:AddKos({ name = "Bob" })
  end)

  it("shows the warning in the window, plays the sound and counts it", function()
    local alert = contact(env)
    assert.are.equal("kos", alert.kind)
    assert.are.same({ { text = alert.text, kind = "kos" } }, env.windows)
    assert.are.same({}, env.errors)
    assert.are.same({ "kos" }, env.sounds)
    assert.are.equal(1, env.alerts.fired)
  end)

  it("falls back to the error area when there is no window", function()
    env.window = false
    local alert = contact(env)
    assert.are.same({ alert.text }, env.errors)
  end)

  it("uses the error area when asked, and nothing when the warning is off", function()
    env.settings.warnTarget = "error"
    local alert = contact(env)
    assert.are.same({ alert.text }, env.errors)
    assert.are.same({}, env.windows)
    env.settings.warnTarget = "none"
    env.clock = env.clock + Constants.INTEL_REALERT_SECONDS
    contact(env)
    assert.are.equal(1, #env.errors)
    assert.are.same({ "kos", "kos" }, env.sounds)
  end)

  it("plays no sound when sounds are off", function()
    env.settings.sound = false
    contact(env)
    assert.are.same({}, env.sounds)
  end)

  it("does not alert the same enemy and kind again until the cooldown has passed", function()
    assert.is_truthy(contact(env))
    env.clock = env.clock + Constants.INTEL_REALERT_SECONDS - 1
    assert.is_nil(contact(env))
    assert.are.equal(1, env.alerts.drops.cooldown)
    env.clock = env.clock + 1
    assert.is_truthy(contact(env))
    assert.are.equal(2, #env.windows)
  end)

  it("keeps the cooldown of each enemy and kind apart", function()
    env.service:AddKos({ name = "Eve" })
    assert.is_truthy(contact(env))
    assert.is_truthy(contact(env, { name = "Eve" }))
  end)

  it("survives a delivery that raises", function()
    env.alerts.deps.window = function()
      error("boom")
    end
    env.alerts.deps.playSound = function()
      error("boom")
    end
    env.alerts.deps.errorText = function()
      error("boom")
    end
    assert.is_truthy(contact(env))
  end)

  it("cleans old cooldowns when the table is full", function()
    for index = 1, 600 do
      env.alerts.alerted["kos:x" .. index] = 1
    end
    env.clock = 5000
    assert.is_truthy(contact(env))
    local count = 0
    for _ in pairs(env.alerts.alerted) do
      count = count + 1
    end
    assert.are.equal(1, count)
  end)
end)

describe("IntelAlerts guild reports", function()
  local env

  before_each(function()
    env = build()
    env.service:AddKos({ name = "Bob" })
  end)

  local function report(overrides)
    local entry = { key = "bob", name = "Bob", level = 60, map = 1411, source = "Ann" }
    for key, value in pairs(overrides or {}) do
      entry[key] = value
    end
    return env.alerts:OnReport(entry)
  end

  it("alerts as Kill On Sight and names the reporter", function()
    local alert = report()
    assert.are.equal("kos", alert.kind)
    assert.are.equal("Ann reports Kill on Sight: Bob (level 60)", alert.text)
    assert.are.same({ "kos" }, env.sounds)
  end)

  it("shares the cooldown with the own sightings", function()
    contact(env)
    assert.is_nil(report())
  end)

  it("stays quiet for another map, an unknown map, a player that is not Kill On Sight, an ignored one", function()
    assert.is_nil(report({ map = 1412 }))
    env.map = nil
    assert.is_nil(report())
    env.map = 1411
    assert.is_nil(report({ key = "eve", name = "Eve" }))
    env.service:AddIgnore("Bob")
    assert.is_nil(report())
  end)

  it("stays quiet when the setting is off or the entry is not a table, and tolerates a bad name", function()
    env.settings.alertGuildReports = false
    assert.is_nil(report())
    env.settings.alertGuildReports = true
    assert.is_nil(env.alerts:OnReport(nil))
    assert.is_nil(report({ name = "a:b", key = "bob" }))
    assert.is_truthy(report({ source = nil }))
  end)

  it("sound off gives no sound", function()
    env.settings.sound = false
    assert.is_nil(report().sound)
  end)
end)

describe("IntelAlerts announcements", function()
  local env

  before_each(function()
    env = build({ group = "PARTY" })
    env.settings.alertNew = true
  end)

  it("announces a new enemy to the chosen channel at most once per enemy per window", function()
    env.settings.announce = "guild"
    contact(env)
    assert.are.same({ { channel = "GUILD", text = "Enemy player nearby: Bob (level 60) <Evil>" } }, env.sent)
    env.clock = env.clock + 10
    env.service:ClearNearby()
    contact(env)
    assert.are.equal(1, #env.sent)
    env.clock = env.clock + Constants.INTEL_ANNOUNCE_SECONDS
    env.service:ClearNearby()
    contact(env)
    assert.are.equal(2, #env.sent)
    assert.are.equal(2, env.alerts.announcedCount)
  end)

  it("sends at most INTEL_ANNOUNCE_MAX_PER_MINUTE automatic announcements to the chat in any minute", function()
    env.settings.announce = "guild"
    local max = Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE
    for index = 1, max + 3 do
      contact(env, { name = "Foe" .. string.char(96 + index) })
    end
    assert.are.equal(max, #env.sent)
    assert.are.equal(max, env.alerts.announcedCount)
    assert.are.equal(3, env.alerts.drops.announce_rate)
    -- A dropped enemy is not marked: it is announced once the minute has passed.
    env.clock = env.clock + 60
    env.service:ClearNearby()
    contact(env, { name = "Foe" .. string.char(96 + max + 1) })
    assert.are.equal(max + 1, #env.sent)
  end)

  it("does not count announcements to the player only, nor the manual ones, against the minute", function()
    env.settings.announce = "self"
    for index = 1, Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE + 2 do
      contact(env, { name = "Foe" .. string.char(96 + index) })
    end
    assert.are.equal(Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE + 2, #env.said)
    env.settings.announce = "guild"
    for index = 1, Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE do
      assert.is_true(env.alerts:AnnounceNow("Man" .. string.char(96 + index), "guild"))
    end
    contact(env, { name = "Late" })
    assert.are.equal(Constants.INTEL_ANNOUNCE_MAX_PER_MINUTE + 1, #env.sent)
  end)

  it("announces even when no alert fires, but only for a new enemy", function()
    env.settings.alertNew = false
    env.settings.announce = "guild"
    contact(env)
    assert.are.equal(1, #env.sent)
    env.clock = env.clock + Constants.INTEL_ANNOUNCE_SECONDS
    contact(env)
    assert.are.equal(1, #env.sent)
  end)

  it("tells only the player with 'self'", function()
    env.settings.announce = "self"
    contact(env)
    assert.are.same({}, env.sent)
    assert.are.same({ "Enemy player nearby: Bob (level 60) <Evil>" }, env.said)
  end)

  it("skips party and raid when the player is not in one, and uses the instance chat in a battleground", function()
    env.settings.announce = "party"
    env.group = nil
    contact(env)
    assert.are.same({}, env.sent)
    env.group = "RAID"
    env.service:ClearNearby()
    contact(env, { name = "Eve" })
    assert.are.equal("PARTY", env.sent[1].channel)
    env.settings.announce = "raid"
    env.group = "PARTY"
    contact(env, { name = "Una" })
    assert.are.equal(1, #env.sent)
    env.group = "INSTANCE_CHAT"
    contact(env, { name = "Vic" })
    assert.are.equal("INSTANCE_CHAT", env.sent[2].channel)
    env.group = "RAID"
    contact(env, { name = "Wes" })
    assert.are.equal("RAID", env.sent[3].channel)
  end)

  it("does nothing when announcements are off, and does not mark a send that failed", function()
    contact(env)
    assert.are.same({}, env.sent)
    env.settings.announce = "guild"
    env.sendOk = false
    contact(env, { name = "Eve" })
    assert.are.equal(0, env.alerts.announcedCount)
    env.sendOk = true
    env.service:ClearNearby()
    contact(env, { name = "Eve" })
    assert.are.equal(1, env.alerts.announcedCount)
  end)

  it("sends to Local Defense only from AnnounceNow, with what is known of the enemy", function()
    env.settings.announce = "none"
    contact(env)
    assert.are.same({}, env.sent)
    assert.is_true(env.alerts:AnnounceNow("Bob-Realm", "localdefense"))
    assert.are.same({ channel = "LOCALDEFENSE", text = "Enemy player nearby: Bob (level 60) <Evil>" }, env.sent[1])
    assert.is_true(env.alerts:AnnounceNow("Stranger", "guild"))
    assert.are.equal("Enemy player nearby: Stranger", env.sent[2].text)
  end)

  it("says why a manual announcement did not go", function()
    assert.are.same({ false, "bad_name" }, { env.alerts:AnnounceNow("a:b", "guild") })
    assert.are.same({ false, "bad_channel" }, { env.alerts:AnnounceNow("Bob", "yell") })
    env.group = nil
    assert.are.same({ false, "no_group" }, { env.alerts:AnnounceNow("Bob", "raid") })
    assert.are.same({ false, "no_group" }, { env.alerts:AnnounceNow("Bob", "party") })
    env.sendOk = false
    assert.are.same({ false, "send_failed" }, { env.alerts:AnnounceNow("Bob", "guild") })
    local said = env.alerts:AnnounceNow("Bob", "self")
    assert.is_true(said)
  end)

  it("announces with no 'say' hook without raising", function()
    env.alerts.deps.say = nil
    assert.is_true(env.alerts:AnnounceNow("Bob", "self"))
  end)
end)

describe("IntelAlerts:Test", function()
  it("delivers a fake alert and shares nothing", function()
    local env = build({ group = "PARTY" })
    env.settings.announce = "guild"
    local alert = env.alerts:Test()
    assert.are.equal("kos", alert.kind)
    assert.are.same({ alert.text }, { env.windows[1].text })
    assert.are.same({ "kos" }, env.sounds)
    assert.are.same({}, env.sent)
    env.settings.sound = false
    assert.is_nil(env.alerts:Test().sound)
  end)
end)
