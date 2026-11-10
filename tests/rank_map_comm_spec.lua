-- RANK_MAP through Comm: receiving, saving, the snapshot for a late joiner and the resend after login (part D).
local function load_addon()
  dofile("NrageAssistant/Libs/LibStub/LibStub.lua")
  dofile("NrageAssistant/Libs/LibDeflate/LibDeflate.lua")
  dofile("NrageAssistant/Libs/LibSerialize/LibSerialize.lua")

  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RankMapModel",
    "Domain/RosterService",
    "Domain/PvPSeasonModel",
    "Domain/RecipeService",
    "Domain/EventModel",
    "Domain/EventService",
    "Domain/LootModel",
    "Domain/LootService",
    "Domain/BlacklistService",
    "Domain/IntelModel",
    "Domain/GuildKosService",
    "Domain/ReadinessRules",
    "Domain/LfgModel",
    "Sync/Codec",
    "Sync/Protocol",
    "Sync/Inbox",
    "Sync/OutboundQueue",
    "Sync/SyncRules",
    "Sync/EventSync",
    "Sync/LootSync",
    "Sync/PvPSync",
    "Sync/BlacklistSync",
    "Sync/GuildKosSync",
    "Sync/ReadinessRulesSync",
    "Sync/RosterSync",
    "Sync/PvPSeasonSync",
    "Sync/RecipeSync",
    "Sync/LayerSync",
    "Sync/LfgSync",
    "Sync/RankMapSync",
    "Sync/Transfer",
    "Sync/Comm",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns
end

local ns = load_addon()
local GUILD = "Nrage-Realm"

-- The guild roster every client reads, by character name.
local GUILD_ROSTER = {
  ["Boss-Realm"] = { rankName = "Emperador", rankIndex = 0 },
  ["Co-Realm"] = { rankName = "Comandante", rankIndex = 1 },
  ["Off-Realm"] = { rankName = "Oficial", rankIndex = 2 },
  ["Joiner-Realm"] = { rankName = "Soldado", rankIndex = 5 },
}

local KEEP = {
  [1] = { role = "cogm", name = "Comandante" },
  [2] = { role = "officer", name = "Oficial" },
  [5] = { role = "member", name = "Soldado" },
}

local function copy(ranks, change)
  local out = {}
  for index, row in pairs(ranks) do
    out[index] = { role = row.role, name = row.name }
  end
  for index, role in pairs(change or {}) do
    out[index].role = role
  end
  return out
end

-- A client whose character is `me`: its own Comm, queue and rank maps.
local function client(me)
  local env = { sent = {}, targets = {}, changes = {}, maps = {}, clock = 0 }
  env.platform = {
    GetIdentityKey = function()
      return me
    end,
    GetOwnGuildRank = function()
      local entry = GUILD_ROSTER[me]
      return entry.rankName, entry.rankIndex
    end,
    NormalizeName = function(name)
      return name
    end,
    ServerTime = function()
      return 5000
    end,
  }
  env.queue = ns.OutboundQueue.New({
    guard = {
      CanSend = function()
        return true
      end,
    },
    now = function()
      return env.clock
    end,
    send = function(text, target)
      env.sent[#env.sent + 1] = text
      env.targets[#env.sent] = target
    end,
    jitter = function()
      return 0
    end,
  })
  env.events, env.tombstones = {}, {}
  env.comm = ns.Comm.New({
    platform = env.platform,
    codec = ns.Codec.New({
      serialize = _G.LibStub("NrageAssistant-LibSerialize"),
      deflate = _G.LibStub("LibDeflate"),
    }),
    inbox = ns.Inbox.New(),
    queue = env.queue,
    roster = {},
    events = env.events,
    tombstones = env.tombstones,
    rankMaps = env.maps,
    guildKey = function()
      return GUILD
    end,
    entryOf = function(name)
      return GUILD_ROSTER[name]
    end,
    onRanksChange = function(messageType)
      env.changes[#env.changes + 1] = messageType
    end,
    roleOf = function(name)
      local entry = GUILD_ROSTER[name]
      return entry and ns.PermissionService.RoleOfEntry(entry, nil, env.maps[GUILD] or { ranks = {} }) or nil
    end,
    ownRole = function()
      local entry = GUILD_ROSTER[me]
      return ns.PermissionService.RoleOfEntry(entry, nil, env.maps[GUILD] or { ranks = {} })
    end,
    version = "0.1.0",
    now = function()
      return env.clock
    end,
    schedule = function() end,
    random = function(low)
      return low
    end,
  })
  return env
end

describe("Comm RANK_MAP", function()
  local boss, joiner

  before_each(function()
    boss, joiner = client("Boss-Realm"), client("Joiner-Realm")
  end)

  it("saves a map for the guild, tells the guild and tells the interface", function()
    local ok, rev, queued = boss.comm:SetRankMap(copy(KEEP, { [2] = "member" }))
    assert.is_true(ok)
    assert.are.equal(1, rev)
    assert.is_true(queued)
    assert.are.equal("member", boss.maps[GUILD].ranks[2].role)
    assert.are.equal("Boss-Realm", boss.maps[GUILD].by)
    assert.are.same({ "RANK_MAP" }, boss.changes)
    assert.are.equal(1, #boss.sent)

    assert.is_true(joiner.comm:HandleMessage(boss.sent[1], "Boss-Realm", "GUILD"))
    assert.are.equal("member", joiner.maps[GUILD].ranks[2].role)
    assert.are.same({ "RANK_MAP" }, joiner.changes)
  end)

  it("raises the revision on every save", function()
    boss.comm:SetRankMap(copy(KEEP))
    local ok, rev = boss.comm:SetRankMap(copy(KEEP, { [5] = "alter" }))
    assert.is_true(ok)
    assert.are.equal(2, rev)
    assert.are.equal("alter", boss.maps[GUILD].ranks[5].role)
  end)

  it("lets a co-guild master save, but not change the row of their own rank", function()
    local co = client("Co-Realm")
    local ok, why = co.comm:SetRankMap(copy(KEEP, { [1] = "officer" }))
    assert.is_false(ok)
    assert.are.equal("self_row", why)
    assert.is_nil(co.maps[GUILD])
    assert.are.equal(0, #co.sent)
    assert.is_true((co.comm:SetRankMap(copy(KEEP, { [5] = "roster" }))))
    assert.are.equal("roster", co.maps[GUILD].ranks[5].role)
  end)

  it("refuses to save for an officer, and drops what an officer sends", function()
    local officer = client("Off-Realm")
    local ok, why = officer.comm:SetRankMap(copy(KEEP, { [2] = "cogm" }))
    assert.is_false(ok)
    assert.are.equal("forbidden", why)
    boss.comm:SetRankMap(copy(KEEP))
    joiner.comm:HandleMessage(boss.sent[1], "Off-Realm", "GUILD")
    assert.is_nil(joiner.maps[GUILD])
    assert.are.same({}, joiner.changes)
  end)

  it("takes the role from the sender's roster entry and never from the message", function()
    boss.comm:SetRankMap(copy(KEEP))
    -- The same bytes from a member are dropped.
    local ok, why = boss.comm:HandleMessage(boss.sent[1], "Joiner-Realm", "GUILD")
    assert.is_false(ok)
    assert.are.equal("forbidden", why)
  end)

  it("carries the map in the snapshot of its author, and a late joiner applies it", function()
    boss.comm:SetRankMap(copy(KEEP, { [2] = "rl" }))
    boss.sent, boss.targets = {}, {}
    assert.is_true((boss.comm:SendSnapshot("Joiner-Realm")))
    assert.are.equal("Joiner-Realm", boss.targets[1])
    local ok = joiner.comm:HandleMessage(boss.sent[1], "Boss-Realm", "WHISPER")
    assert.is_true(ok)
    assert.are.equal("rl", joiner.maps[GUILD].ranks[2].role)
    assert.are.same({ "SYNC_DATA" }, joiner.changes)
  end)

  it("does not carry the map in the snapshot of somebody who may not author it", function()
    local officer = client("Off-Realm")
    officer.maps[GUILD] = { rev = 3, updatedAt = 1, by = "Boss-Realm", ranks = copy(KEEP) }
    local items = ns.Transfer.BuildSnapshot(
      {},
      {},
      5,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      nil,
      officer.comm:AuthoredRankMap()
    )
    assert.are.same({}, items)
  end)

  it("ignores a rank map in a snapshot whispered by a member", function()
    boss.comm:SetRankMap(copy(KEEP, { [2] = "rl" }))
    boss.sent = {}
    boss.comm:SendSnapshot("Joiner-Realm")
    -- The whisper guard wants a leader first; a member's snapshot never gets as far as applying the map.
    local ok = joiner.comm:HandleMessage(boss.sent[1], "Joiner-Realm", "WHISPER")
    assert.is_false(ok)
    assert.is_nil(joiner.maps[GUILD])
  end)

  it("resends after login only the map this client saved", function()
    assert.are.same({ false, "not_author" }, { boss.comm:SendAuthoredRankMap() })
    boss.comm:SetRankMap(copy(KEEP))
    boss.sent = {}
    assert.is_true((boss.comm:SendAuthoredRankMap()))
    assert.are.equal(1, #boss.sent)
    -- A map somebody else saved is not resent by the guild master.
    boss.maps[GUILD].by = "Co-Realm"
    boss.sent = {}
    assert.are.same({ false, "not_author" }, { boss.comm:SendAuthoredRankMap() })
    assert.are.equal(0, #boss.sent)
  end)

  it("answers the roles of members through the map it holds before applying a new one", function()
    -- Rank 3 of a renamed guild is only a co-guild master rank because the held map says so.
    GUILD_ROSTER["Renamed-Realm"] = { rankName = "Capitana", rankIndex = 3 }
    boss.comm:SetRankMap(copy(KEEP, {}))
    boss.maps[GUILD].ranks[3] = { role = "cogm", name = "Capitana" }
    local renamed = client("Renamed-Realm")
    renamed.maps[GUILD] = boss.maps[GUILD]
    local ok = renamed.comm:SetRankMap(copy(boss.maps[GUILD].ranks, { [5] = "alter" }))
    assert.is_true(ok)
    -- Without the held map the same character is an alter and may not.
    local fresh = client("Renamed-Realm")
    local denied, why = fresh.comm:SetRankMap(copy(boss.maps[GUILD].ranks, { [5] = "alter" }))
    GUILD_ROSTER["Renamed-Realm"] = nil
    assert.is_false(denied)
    assert.are.equal("forbidden", why)
  end)
end)
