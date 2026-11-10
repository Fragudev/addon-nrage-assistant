-- The rank map store and its questions: current map per guild, editor draft, who changes role (part D).
local ns = {}
for _, path in ipairs({
  "Core/Constants",
  "Core/Validate",
  "Domain/PermissionService",
  "Domain/RankMapModel",
  "Domain/RankMapService",
}) do
  assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
end
local Service = ns.RankMapService

local function roster_with(entries)
  local names = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  return {
    Names = function()
      return names
    end,
    Lookup = function(_, name)
      return entries[name]
    end,
  }
end

describe("RankMapService.GuildKey", function()
  it("joins the guild and the realm, and is nil while either is unknown", function()
    assert.are.equal("Nrage-Realm", Service.GuildKey("Nrage", "Realm"))
    assert.is_nil(Service.GuildKey(nil, "Realm"))
    assert.is_nil(Service.GuildKey("Nrage", ""))
    assert.is_nil(Service.GuildKey("", "Realm"))
  end)
end)

describe("RankMapService:Current", function()
  it("reads the map of the current guild only", function()
    local maps = { ["A-R"] = { rev = 1, ranks = { [1] = { role = "rl" } } }, ["B-R"] = { rev = 2, ranks = {} } }
    local key = "A-R"
    local service = Service.New({
      maps = maps,
      guildKey = function()
        return key
      end,
    })
    assert.are.equal(maps["A-R"], service:Current())
    assert.are.equal(maps["A-R"], service:Provider()())
    key = "C-R"
    assert.is_nil(service:Current())
    key = nil
    assert.is_nil(service:Current())
  end)

  it("ignores a damaged record", function()
    local service = Service.New({
      maps = { ["A-R"] = "oops" },
      guildKey = function()
        return "A-R"
      end,
    })
    assert.is_nil(service:Current())
  end)
end)

describe("RankMapService:Draft", function()
  local ranks = { [0] = "Emperador", [1] = "Comandante", [2] = "Oficial", [3] = "Mystery" }

  it("starts from today's name lookup when nothing was saved", function()
    local service = Service.New({
      maps = {},
      guildKey = function()
        return "A-R"
      end,
    })
    local draft = service:Draft(ranks)
    assert.are.equal("cogm", draft[1].role)
    assert.are.equal("officer", draft[2].role)
    assert.are.equal("alter", draft[3].role)
  end)

  it("lets the saved rows win and ignores a saved row of a rank that is gone", function()
    local service = Service.New({
      maps = { ["A-R"] = { ranks = { [2] = { role = "member" }, [8] = { role = "rl" } } } },
      guildKey = function()
        return "A-R"
      end,
    })
    local draft = service:Draft(ranks)
    assert.are.equal("member", draft[2].role)
    assert.are.equal("Oficial", draft[2].name)
    assert.is_nil(draft[8])
  end)
end)

describe("RankMapService:Preview", function()
  local guild = roster_with({
    Boss = { rankName = "Emperador", rankIndex = 0 },
    Ann = { rankName = "Oficial", rankIndex = 2 },
    Bob = { rankName = "Oficial", rankIndex = 2 },
    Cat = { rankName = "Soldado", rankIndex = 5 },
  })
  local service = Service.New({
    maps = {},
    guildKey = function()
      return "A-R"
    end,
  })

  it("lists nobody when the draft changes nothing", function()
    local draft = service:Draft({ [0] = "Emperador", [2] = "Oficial", [5] = "Soldado" })
    assert.are.same({}, service:Preview(guild, draft))
  end)

  it("lists who changes role, sorted by name, and never the guild master", function()
    local changes = service:Preview(guild, {
      [0] = { role = "alter" },
      [2] = { role = "member" },
      [5] = { role = "member" },
    })
    assert.are.same({
      { name = "Ann", rankName = "Oficial", from = "officer", to = "member" },
      { name = "Bob", rankName = "Oficial", from = "officer", to = "member" },
    }, changes)
  end)
end)
