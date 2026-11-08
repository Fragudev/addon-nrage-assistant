local function load_modules()
  local ns = {}
  for _, path in ipairs({ "Core/Constants", "Core/Validate", "Domain/IntelModel", "Domain/IntelService" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_modules()
local Constants = ns.Constants

local function build(overrides)
  local env = {
    clock = 1000,
    wall = 5000000,
    settings = { removeMinutes = 5 },
    intel = { players = {}, kos = {}, ignore = {}, zones = {} },
    guildKos = {},
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
      return env.wall
    end,
  })
  return env
end

local function bob(overrides)
  local details = { name = "Bob-Realm", class = "ROGUE", race = "ORC", level = 60, guild = "Evil", faction = "Horde" }
  for key, value in pairs(overrides or {}) do
    details[key] = value
  end
  return details
end

describe("IntelService:OnSeen", function()
  local env

  before_each(function()
    env = build()
  end)

  it("creates the record and the Nearby entry", function()
    local result = env.service:OnSeen(bob(), { map = 1411, x = 10, y = 20 })
    assert.is_true(result.isNew)
    assert.are.equal("bob", result.key)
    assert.are.same({
      name = "Bob",
      class = "ROGUE",
      race = "ORC",
      level = 60,
      levelEstimated = false,
      guild = "Evil",
      faction = "Horde",
      firstSeen = 5000000,
      lastSeen = 5000000,
      seen = 1,
      wins = 0,
      losses = 0,
      lastMap = 1411,
      lastX = 10,
      lastY = 20,
    }, env.intel.players.bob)
    assert.are.equal(1, env.intel.zones[1411])
    assert.are.equal(1, #env.service:Nearby(env.clock))
  end)

  it("counts a contact once while the enemy stays in Nearby", function()
    env.service:OnSeen(bob(), { map = 1411 })
    env.clock, env.wall = env.clock + 3, env.wall + 3
    local again = env.service:OnSeen(bob({ level = 61 }), { map = 1411 })
    assert.is_false(again.isNew)
    assert.are.equal(1, env.intel.players.bob.seen)
    assert.are.equal(1, env.intel.zones[1411])
    assert.are.equal(61, env.intel.players.bob.level)
    assert.are.equal(5000003, env.intel.players.bob.lastSeen)
  end)

  it("treats an enemy that left Nearby as new again", function()
    env.service:OnSeen(bob(), { map = 1411 })
    env.clock = env.clock + 301
    local again = env.service:OnSeen(bob(), { map = 1411 })
    assert.is_true(again.isNew)
    assert.are.equal(2, env.intel.players.bob.seen)
    assert.are.equal(2, env.intel.zones[1411])
  end)

  it("keeps what is known when a read gives less", function()
    env.service:OnSeen(bob(), {})
    env.service:OnSeen({ name = "Bob" }, {})
    local record = env.intel.players.bob
    assert.are.equal("ROGUE", record.class)
    assert.are.equal("Evil", record.guild)
    assert.are.equal(60, record.level)
    assert.is_nil(record.lastMap)
  end)

  it("marks an estimated level", function()
    env.service:OnSeen(bob({ level = 70, levelEstimated = true }), {})
    assert.is_true(env.intel.players.bob.levelEstimated)
    env.service:OnSeen(bob({ level = 65 }), {})
    assert.is_false(env.intel.players.bob.levelEstimated)
  end)

  it("refuses a name it cannot keep", function()
    assert.are.same({ nil, "bad_name" }, { env.service:OnSeen({ name = "a|b" }, {}) })
    assert.are.same({ nil, "bad_name" }, { env.service:OnSeen(nil, {}) })
    assert.are.same({}, env.intel.players)
  end)

  it("records an ignored player but keeps it out of Nearby", function()
    env.service:AddIgnore("Bob")
    local result = env.service:OnSeen(bob(), { map = 1411 })
    assert.is_true(result.ignored)
    assert.is_false(result.isNew)
    assert.are.equal(0, #env.service:Nearby(env.clock))
    assert.is_table(env.intel.players.bob)
    assert.are.equal(0, env.intel.players.bob.seen)
  end)

  it("says whether the player is on a Kill On Sight list", function()
    env.service:AddKos({ name = "Bob" })
    assert.are.equal("personal", env.service:OnSeen(bob(), {}).kos)
  end)

  it("removes the oldest records in one batch when the list is full", function()
    local limit = Constants.INTEL_PLAYERS_MAX
    local batch = math.floor(limit * 0.05)
    for index = 1, limit do
      env.intel.players["p" .. index] = { name = "P" .. index, lastSeen = 100 + index, wins = 0, losses = 0 }
    end
    env = build({ intel = env.intel })
    env.service:OnSeen(bob(), {})
    assert.is_nil(env.intel.players.p1)
    assert.is_nil(env.intel.players["p" .. batch])
    assert.is_table(env.intel.players["p" .. (batch + 1)])
    assert.is_table(env.intel.players.bob)
    assert.are.equal(limit - batch + 1, env.service:Counts().players)
  end)

  it("replaces a damaged saved record instead of raising", function()
    env.intel.players.bob = { name = "Bob", lastSeen = 1, wins = 0, losses = 0 }
    env.intel.players.eve = "damaged"
    env = build({ intel = env.intel })
    local result = env.service:OnSeen(bob(), {})
    assert.are.equal(1, result.record.seen)
    assert.is_truthy(env.service:OnSeen({ name = "Eve" }, {}))
    assert.are.equal("Eve", env.intel.players.eve.name)
    assert.are.equal(2, env.service:Counts().players)
  end)

  it("stops counting new maps when the zone list is full", function()
    for map = 1, Constants.INTEL_ZONES_MAX do
      env.intel.zones[map] = 1
    end
    env.service:OnSeen(bob(), { map = 9000 })
    assert.is_nil(env.intel.zones[9000])
    env.clock = env.clock + 400
    env.service:OnSeen(bob(), { map = 1 })
    assert.are.equal(2, env.intel.zones[1])
  end)
end)

describe("IntelService:Nearby", function()
  local env

  before_each(function()
    env = build()
  end)

  it("fades an entry at half the delay and drops it at the delay", function()
    env.service:OnSeen(bob(), {})
    env.clock = 1000 + 149
    assert.is_false(env.service:Nearby(env.clock)[1].faded)
    env.clock = 1000 + 150
    assert.is_true(env.service:Nearby(env.clock)[1].faded)
    assert.are.equal(150, env.service:Nearby(env.clock)[1].age)
    env.clock = 1000 + 300
    assert.are.equal(1, #env.service:Nearby(env.clock))
    env.clock = 1000 + 301
    assert.are.equal(0, #env.service:Nearby(env.clock))
    assert.are.equal(0, env.service:Counts().nearby)
  end)

  it("never fades or drops with a delay of 0", function()
    env.settings.removeMinutes = 0
    env.service:OnSeen(bob(), {})
    env.clock = 1000 + 100000
    local list = env.service:Nearby(env.clock)
    assert.are.equal(1, #list)
    assert.is_false(list[1].faded)
  end)

  it("lists Kill On Sight first, then the most recent", function()
    env.service:OnSeen(bob({ name = "Old" }), {})
    env.clock = env.clock + 10
    env.service:OnSeen(bob({ name = "Mid" }), {})
    env.clock = env.clock + 10
    env.service:OnSeen(bob({ name = "Kos" }), {})
    env.service:OnSeen(bob({ name = "Zed" }), {})
    env.service:AddKos({ name = "Old" })
    env.guildKos.mid = { name = "Mid" }
    local names = {}
    for _, item in ipairs(env.service:Nearby(env.clock)) do
      names[#names + 1] = item.name .. ":" .. tostring(item.kos)
    end
    assert.are.same({ "Mid:guild", "Old:personal", "Kos:nil", "Zed:nil" }, names)
  end)

  it("adds received sightings that were not seen here, with their source", function()
    env.service:OnSeen(bob(), {})
    local list = env.service:Nearby(env.clock, {
      { name = "Bob", at = 995, source = "Ann" },
      { name = "Eve", class = "MAGE", level = 60, at = 990, source = "Ann", map = 1411 },
      { name = "Ign", at = 999, source = "Ann" },
    })
    local names = {}
    for _, item in ipairs(list) do
      names[#names + 1] = item.name .. "/" .. tostring(item.source)
    end
    assert.are.same({ "Bob/nil", "Ign/Ann", "Eve/Ann" }, names)
    env.service:AddIgnore("Ign")
    assert.are.equal(1, #env.service:Nearby(env.clock, { { name = "Ign", at = 999, source = "Ann" } }))
  end)

  it("drops a received sighting after the delay", function()
    local sighting = { { name = "Eve", at = 1000, source = "Ann" } }
    assert.are.equal(1, #env.service:Nearby(1300, sighting))
    assert.are.equal(0, #env.service:Nearby(1301, sighting))
  end)

  it("marks stealth", function()
    env.service:OnSeen(bob(), {})
    assert.is_true(env.service:MarkStealth("Bob"))
    assert.is_true(env.service:Nearby(env.clock)[1].stealth)
    assert.is_false(env.service:MarkStealth("Nobody"))
  end)

  it("clears Nearby only", function()
    env.service:OnSeen(bob(), {})
    env.service:ClearNearby()
    assert.are.equal(0, #env.service:Nearby(env.clock))
    assert.is_table(env.intel.players.bob)
  end)
end)

describe("IntelService lists", function()
  local env

  before_each(function()
    env = build()
  end)

  it("keeps the players seen in the last hour, most recent first", function()
    env.service:OnSeen(bob({ name = "Old" }), {})
    env.wall = env.wall + 3000
    env.service:OnSeen(bob({ name = "New" }), {})
    env.wall = env.wall + 700
    env.service:OnSeen(bob({ name = "Latest" }), {})
    local names = {}
    for _, item in ipairs(env.service:LastHour(env.wall)) do
      names[#names + 1] = item.name
    end
    assert.are.same({ "Latest", "New" }, names)
  end)

  it("leaves an ignored player out of the last hour", function()
    env.service:OnSeen(bob(), {})
    env.service:AddIgnore("Bob")
    assert.are.equal(0, #env.service:LastHour(env.wall))
  end)

  describe("Stats", function()
    local function names(list)
      local result = {}
      for _, item in ipairs(list) do
        result[#result + 1] = item.name
      end
      return result
    end

    before_each(function()
      local players = env.intel.players
      players.ann = { name = "Ann", guild = "Zeta", level = 40, lastSeen = 30, wins = 0, losses = 2 }
      players.bea = { name = "Bea", guild = "alpha", level = 60, lastSeen = 10, wins = 3, losses = 0 }
      players.cid = { name = "Cid", level = 50, lastSeen = 20, wins = 1, losses = 1 }
      players.broken = "oops"
      env.service:AddKos({ name = "Cid", category = "camp" })
      env.guildKos.bea = { name = "Bea", category = "gank" }
    end)

    it("sorts by last seen, most recent first, by default", function()
      assert.are.same({ "Ann", "Cid", "Bea" }, names(env.service:Stats()))
    end)

    it("sorts by every key, in its starting direction or the other one", function()
      assert.are.same({ "Ann", "Bea", "Cid" }, names(env.service:Stats(nil, "name")))
      assert.are.same({ "Bea", "Cid", "Ann" }, names(env.service:Stats(nil, "level")))
      assert.are.same({ "Bea", "Ann", "Cid" }, names(env.service:Stats(nil, "guild")))
      assert.are.same({ "Bea", "Cid", "Ann" }, names(env.service:Stats(nil, "wins")))
      assert.are.same({ "Ann", "Cid", "Bea" }, names(env.service:Stats(nil, "losses")))
      assert.are.same({ "Cid", "Bea", "Ann" }, names(env.service:Stats(nil, { key = "name", descending = true })))
      assert.are.same({ "Ann", "Cid", "Bea" }, names(env.service:Stats(nil, "nonsense")))
    end)

    it("filters by text on the name and the guild", function()
      assert.are.same({ "Ann" }, names(env.service:Stats({ text = "AN" })))
      assert.are.same({ "Bea" }, names(env.service:Stats({ text = "alp" })))
      assert.are.same({ "Ann", "Cid", "Bea" }, names(env.service:Stats({ text = "" })))
    end)

    it("filters by Kill On Sight, wins, losses and category", function()
      assert.are.same({ "Cid", "Bea" }, names(env.service:Stats({ kos = true })))
      assert.are.same({ "Cid", "Bea" }, names(env.service:Stats({ wins = true })))
      assert.are.same({ "Ann", "Cid" }, names(env.service:Stats({ losses = true })))
      assert.are.same({ "Cid" }, names(env.service:Stats({ category = "camp" })))
      assert.are.same({ "Bea" }, names(env.service:Stats({ category = "gank" })))
      assert.are.same({}, names(env.service:Stats({ category = "insult" })))
    end)

    it("tells the scope of each Kill On Sight entry", function()
      local list = env.service:Stats(nil, "name")
      assert.are.same({ "nil", "guild", "personal" }, { tostring(list[1].kos), list[2].kos, list[3].kos })
    end)
  end)

  describe("personal Kill On Sight", function()
    it("adds, changes and removes an entry", function()
      local entry, key = env.service:AddKos({ name = "Bob-Realm", category = "gank", reason = "ninja" })
      assert.are.equal("bob", key)
      assert.are.same({ name = "Bob", category = "gank", reason = "ninja", addedAt = env.wall }, entry)
      env.wall = env.wall + 5
      env.service:AddKos({ name = "Bob", category = "camp" })
      assert.are.equal("camp", env.intel.kos.bob.category)
      assert.is_nil(env.intel.kos.bob.reason)
      assert.are.equal(5000000, env.intel.kos.bob.addedAt)
      assert.is_true(env.service:RemoveKos("bob"))
      assert.is_false(env.service:RemoveKos("bob"))
      assert.is_false(env.service:RemoveKos(5))
    end)

    it("refuses what does not validate and what does not fit", function()
      assert.are.same({ nil, "bad_name" }, { env.service:AddKos({ name = "" }) })
      assert.are.same({ nil, "bad_category" }, { env.service:AddKos({ name = "Bob", category = "x" }) })
      for index = 1, Constants.INTEL_KOS_MAX do
        env.intel.kos["k" .. index] = { name = "K" .. index }
      end
      assert.are.same({ nil, "limit" }, { env.service:AddKos({ name = "Late" }) })
      assert.is_table(env.service:AddKos({ name = "K1", category = "camp" }))
    end)

    it("lists the entries by name", function()
      env.service:AddKos({ name = "zed" })
      env.service:AddKos({ name = "Amy" })
      env.guildKos.gil = { name = "Gil" }
      local function names(scope)
        local result = {}
        for _, item in ipairs(env.service:KosList(scope)) do
          result[#result + 1] = item.name .. "=" .. item.key
        end
        return result
      end
      assert.are.same({ "Amy=amy", "zed=zed" }, names("personal"))
      assert.are.same({ "Gil=gil" }, names("guild"))
    end)

    it("finds a player by name or by key", function()
      env.service:AddKos({ name = "Bob" })
      assert.are.equal("personal", (env.service:IsKos("BOB-Realm")))
      assert.are.equal("personal", (env.service:IsKos("bob")))
      assert.is_nil(env.service:IsKos("Eve"))
      assert.is_nil(env.service:IsKos(nil))
      env.guildKos.eve = { name = "Eve" }
      assert.are.equal("guild", (env.service:IsKos("Eve")))
      env.service:AddKos({ name = "Eve" })
      assert.are.equal("personal", (env.service:IsKos("Eve")))
    end)
  end)

  describe("Ignore", function()
    it("adds, lists and removes, and takes the player off the other places", function()
      env.service:AddKos({ name = "Bob" })
      env.service:OnSeen(bob(), {})
      local entry, key = env.service:AddIgnore("Bob-Realm")
      assert.are.equal("bob", key)
      assert.are.equal("Bob", entry.name)
      assert.is_nil(env.intel.kos.bob)
      assert.are.equal(0, #env.service:Nearby(env.clock))
      assert.is_true(env.service:IsIgnored("bob"))
      assert.are.equal("Bob", env.service:IgnoreList()[1].name)
      -- A Kill On Sight entry takes the player off the Ignore list again.
      env.service:AddKos({ name = "Bob" })
      assert.is_false(env.service:IsIgnored("Bob"))
      env.service:AddIgnore("Bob")
      assert.is_true(env.service:RemoveIgnore("bob"))
      assert.is_false(env.service:RemoveIgnore("bob"))
      assert.is_false(env.service:RemoveIgnore(nil))
    end)

    it("refuses a bad name and a full list", function()
      assert.are.same({ nil, "bad_name" }, { env.service:AddIgnore("a:b") })
      for index = 1, Constants.INTEL_IGNORE_MAX do
        env.intel.ignore["i" .. index] = { name = "I" .. index }
      end
      assert.are.same({ nil, "limit" }, { env.service:AddIgnore("Late") })
      assert.is_table(env.service:AddIgnore("I1"))
    end)
  end)

  describe("removing from Nearby", function()
    it("takes one player out and says whether he was there", function()
      env.service:OnSeen(bob(), { map = 1411 })
      env.service:OnSeen(bob({ name = "Eve" }), { map = 1411 })
      assert.is_true(env.service:RemoveNearby("bob"))
      assert.is_false(env.service:RemoveNearby("bob"))
      assert.is_false(env.service:RemoveNearby(nil))
      assert.are.equal(1, env.service:Counts().nearby)
    end)
  end)

  describe("housekeeping", function()
    it("prunes the players not seen for the retention time", function()
      env.intel.players.old = { name = "Old", lastSeen = 1000 }
      env.intel.players.fresh = { name = "Fresh", lastSeen = env.wall - 86400 }
      env.intel.players.broken = "oops"
      env = build({ intel = env.intel, wall = 30000000 })
      env.intel.players.fresh.lastSeen = env.wall - 86400
      assert.are.equal(2, env.service:Prune(env.wall))
      assert.is_nil(env.intel.players.old)
      assert.is_table(env.intel.players.fresh)
      assert.are.equal(1, env.service:Counts().players)
    end)

    it("resets the players and zones and keeps the lists", function()
      env.service:AddKos({ name = "Bob" })
      env.service:AddIgnore("Eve")
      env.service:OnSeen(bob({ name = "Zed" }), { map = 1411 })
      env.service:Reset()
      assert.are.same({
        players = 0,
        kos = 1,
        ignore = 1,
        zones = 0,
        guildKos = 0,
        nearby = 0,
      }, env.service:Counts())
    end)
  end)
end)

describe("IntelService results and session", function()
  local env

  before_each(function()
    env = build()
  end)

  it("counts a win against a known enemy and against one never met", function()
    env.service:OnSeen(bob(), { map = 1411 })
    local record, key = env.service:OnWin("Bob-Realm")
    assert.are.equal("bob", key)
    assert.are.equal(1, record.wins)
    local fresh = env.service:OnWin("Eve")
    assert.are.equal(1, fresh.wins)
    assert.are.equal(0, fresh.seen)
    assert.are.equal(2, env.service:Counts().players)
    assert.are.equal(2, env.service.session.wins)
    assert.are.same({ nil, "bad_name" }, { env.service:OnWin("a:b") })
  end)

  it("counts a loss and remembers who killed the player most", function()
    env.service:OnLoss("Bob")
    env.service:OnLoss("Bob")
    env.service:OnLoss("Eve")
    assert.are.equal(2, env.intel.players.bob.losses)
    assert.are.equal(3, env.service.session.losses)
    assert.are.equal(2, env.service.session.lostTo.bob)
    assert.are.same({ nil, "bad_name" }, { env.service:OnLoss("") })
  end)

  it("repairs a damaged record when a win names it", function()
    env.intel.players.bob = { name = "Bob" }
    local record = env.service:OnWin("Bob")
    assert.are.equal(1, record.wins)
    assert.are.equal(0, record.seen)
    assert.is_table(env.service:Player("Bob"))
    assert.is_nil(env.service:Player("Nobody"))
  end)

  it("counts the contacts, the zones and the new Kill On Sight entries of the session", function()
    env.service:OnSeen(bob(), { map = 1411 })
    env.service:OnSeen(bob(), { map = 1411 })
    env.service:OnSeen(bob({ name = "Eve" }), { map = 1412 })
    env.service:AddKos({ name = "Bob" })
    env.service:AddKos({ name = "Bob", category = "gank" })
    local session = env.service.session
    assert.are.equal(2, session.contacts)
    assert.are.equal(1, session.seen.bob)
    assert.are.equal(1, session.zones[1411])
    assert.are.equal(1, session.newKos)
    env.service:Reset()
    assert.are.equal(0, env.service.session.contacts)
  end)

  it("lists the guilds of the Kill On Sight players, personal and guild", function()
    env.service:OnSeen(bob(), { map = 1 })
    env.service:OnSeen(bob({ name = "Eve", guild = "Rivals" }), { map = 1 })
    env.service:OnSeen(bob({ name = "Zed", guild = "Third" }), { map = 1 })
    env.service:AddKos({ name = "Bob" })
    env.guildKos.eve = { name = "Eve" }
    env.guildKos.ghost = { name = "Ghost" }
    assert.are.same({ evil = true, rivals = true }, env.service:KosGuilds())
  end)
end)
