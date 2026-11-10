-- PermissionService with a rank map: the role follows the rank index, so a renamed rank keeps its role. Without a map
-- everything is as before (permission_service_spec.lua covers that).
local ns = {}
for _, path in ipairs({
  "Core/Constants",
  "Core/Validate",
  "Domain/PermissionService",
  "Domain/RankMapModel",
}) do
  assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
end
local Service = ns.PermissionService

local function roster_with(entries)
  return {
    Lookup = function(_, name)
      return entries[name]
    end,
  }
end

local function platform_of(rank, index, leader)
  return {
    GetOwnGuildRank = function()
      return rank, index
    end,
    IsGuildLeader = leader ~= nil and function()
      return leader
    end or nil,
  }
end

local MAP = {
  rev = 1,
  updatedAt = 1,
  ranks = {
    [1] = { role = "cogm", name = "Comandante" },
    [2] = { role = "officer", name = "Oficial" },
    [5] = { role = "member", name = "Soldado" },
  },
}

describe("PermissionService with a rank map", function()
  after_each(function()
    ns.rankMap = nil
  end)

  it("RoleFor keeps the role of a renamed rank", function()
    assert.are.equal("cogm", Service.RoleFor("Capitana", 1, MAP))
    assert.are.equal("gm", Service.RoleFor("Anything", 0, MAP))
    assert.are.equal("alter", Service.RoleFor("Recruit", 9, MAP))
  end)

  it("RoleFor without a map is the name lookup", function()
    assert.are.equal("cogm", Service.RoleFor("Comandante", 1))
    assert.are.equal("alter", Service.RoleFor("Capitana", 1))
    assert.are.equal("gm", Service.RoleFor("Whatever", 0))
    assert.is_nil(Service.RoleFor(nil, 4))
  end)

  it("RoleOfEntry and RoleOf use the index of the entry", function()
    local roster = roster_with({
      Renamed = { rankName = "Capitana", rankIndex = 1 },
      Boss = { rankName = "Zeta", rankIndex = 0 },
    })
    assert.are.equal("cogm", Service.RoleOfEntry({ rankName = "Capitana", rankIndex = 1 }, nil, MAP))
    assert.are.equal("cogm", Service.RoleOf(roster, "Renamed", { rankMap = MAP }))
    assert.are.equal("gm", Service.RoleOf(roster, "Boss", { rankMap = MAP }))
    assert.are.equal("alter", Service.RoleOf(roster, "Renamed"))
  end)

  it("OwnRole uses the own rank index", function()
    assert.are.equal("cogm", Service.OwnRole(platform_of("Capitana", 1), { rankMap = MAP }))
    assert.are.equal("officer", Service.OwnRole(platform_of("Cualquiera", 2), { rankMap = MAP }))
    assert.are.equal("gm", Service.OwnRole(platform_of("Cualquiera", 0), { rankMap = MAP }))
    assert.are.equal("gm", Service.OwnRole(platform_of("Cualquiera", 4, true), { rankMap = MAP }))
    assert.is_nil(Service.OwnRole(platform_of(nil, 1), { rankMap = MAP }))
  end)

  it("reads the map of the current guild from ns.rankMap by default", function()
    local roster = roster_with({ Renamed = { rankName = "Capitana", rankIndex = 1 } })
    assert.are.equal("alter", Service.RoleOf(roster, "Renamed"))
    ns.rankMap = function()
      return MAP
    end
    assert.are.equal("cogm", Service.RoleOf(roster, "Renamed"))
    assert.are.equal("cogm", Service.OwnRole(platform_of("Capitana", 1)))
    ns.rankMap = function()
      return nil
    end
    assert.are.equal("alter", Service.RoleOf(roster, "Renamed"))
  end)

  it("lets an explicit rank map win over the provider", function()
    ns.rankMap = function()
      return MAP
    end
    local roster = roster_with({ Renamed = { rankName = "Capitana", rankIndex = 1 } })
    local other = { ranks = { [1] = { role = "rl" } } }
    assert.are.equal("rl", Service.RoleOf(roster, "Renamed", { rankMap = other }))
  end)

  it("keeps the old name mapping option working", function()
    local roster = roster_with({ Plain = { rankName = "Soldado", rankIndex = 5 } })
    assert.are.equal("rl", Service.RoleOf(roster, "Plain", { mapping = { soldado = "rl" } }))
  end)

  it("never lets the map assign gm", function()
    local hostile = { ranks = { [3] = { role = "gm" } } }
    assert.are.equal("alter", Service.RoleFor("Unlisted", 3, hostile))
  end)

  it("grants ranks_manage to gm and cogm only, and the Admin group to the usual ranks", function()
    for _, role in ipairs({ "gm", "cogm" }) do
      assert.is_true(Service.Can(role, "ranks_manage"), role)
    end
    for _, role in ipairs({ "officer", "rl", "roster", "member", "alter" }) do
      assert.is_false(Service.Can(role, "ranks_manage"), role)
    end
    assert.are.equal("all", Service.Scope("cogm", "ranks_manage"))
    assert.are.equal("none", Service.Scope("officer", "ranks_manage", "r1"))
  end)
end)
