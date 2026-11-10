-- The Ranks tab's rows (UI/ViewModelRanks.lua): pre-fill, preview, drift banners, who may edit what.
local function load_view_model()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/RankMapModel",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelRanks",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.ViewModel, ns
end

local ViewModel = load_view_model()

local RANKS = { [0] = "Emperador", [1] = "Comandante", [2] = "Oficial", [3] = "Raid Lider", [5] = "Soldado" }

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

local ENTRIES = {
  Boss = { rankName = "Emperador", rankIndex = 0 },
  Co = { rankName = "Comandante", rankIndex = 1 },
  Ann = { rankName = "Oficial", rankIndex = 2 },
  Bob = { rankName = "Oficial", rankIndex = 2 },
  Cat = { rankName = "Soldado", rankIndex = 5 },
}

local function view(args)
  args = args or {}
  args.currentRanks = args.currentRanks or RANKS
  args.guildRoster = args.guildRoster or roster_with(ENTRIES)
  args.formatDate = args.formatDate or function()
    return "2026-11-10 20:30"
  end
  if args.canManage == nil then
    args.canManage = true
  end
  return ViewModel.RankRows(args)
end

local function row_of(data, index)
  for _, row in ipairs(data.rows) do
    if row.index == index then
      return row
    end
  end
end

describe("ViewModel.RankRows", function()
  it("lists one row per guild rank in index order, with the member count", function()
    local data = view()
    local indexes = {}
    for _, row in ipairs(data.rows) do
      indexes[#indexes + 1] = row.index
    end
    assert.are.same({ 0, 1, 2, 3, 5 }, indexes)
    assert.are.equal("Oficial", row_of(data, 2).rankName)
    assert.are.equal(2, row_of(data, 2).members)
    assert.are.equal(0, row_of(data, 3).members)
    assert.are.equal(1, row_of(data, 0).members)
  end)

  it("shows the guild master row as such, with no role to pick", function()
    local row = row_of(view(), 0)
    assert.is_true(row.guildMaster)
    assert.are.equal("gm", row.role)
    assert.is_true(row.readOnly)
  end)

  it("pre-fills the roles from today's name lookup while nothing is saved, so saving changes nobody", function()
    local data = view()
    assert.is_true(data.noMap)
    assert.are.equal("cogm", row_of(data, 1).role)
    assert.are.equal("officer", row_of(data, 2).role)
    assert.are.equal("rl", row_of(data, 3).role)
    assert.are.equal("member", row_of(data, 5).role)
    assert.are.same({}, data.changes)
    assert.are.equal("No member changes role.", data.previewText)
  end)

  it("lets the first save pin the current roles, then waits for a change", function()
    local first = view()
    assert.is_true(first.canSave)
    local saved = { rev = 1, updatedAt = 5, by = "Boss" }
    saved.ranks = {
      [1] = { role = "cogm", name = "Comandante" },
      [2] = { role = "officer", name = "Oficial" },
      [3] = { role = "rl", name = "Raid Lider" },
      [5] = { role = "member", name = "Soldado" },
    }
    local again = view({ rankMap = saved })
    assert.is_false(again.noMap)
    assert.is_false(again.canSave)
  end)

  it("previews who changes role when the draft differs, and enables Save", function()
    local draft =
      { [1] = { role = "cogm" }, [2] = { role = "member" }, [3] = { role = "rl" }, [5] = { role = "member" } }
    local data = view({ draft = draft })
    assert.is_true(data.canSave)
    assert.are.equal(2, #data.changes)
    assert.are.same({ name = "Ann", rankName = "Oficial", from = "officer", to = "member" }, data.changes[1])
    assert.are.equal("2 members change role: Ann (Officer -> Member), Bob (Officer -> Member)", data.previewText)
    assert.is_true(row_of(data, 2).changed)
    assert.is_false(row_of(data, 1).changed)
  end)

  it("says it in the singular and cuts a long list", function()
    local single = view({ draft = { [5] = { role = "alter" } } })
    assert.are.equal("1 member changes role: Cat (Member -> Alter)", single.previewText)
    local many = {}
    for index = 1, 8 do
      many["M" .. index] = { rankName = "Soldado", rankIndex = 5 }
    end
    local data = view({ guildRoster = roster_with(many), draft = { [5] = { role = "alter" } } })
    assert.are.equal(8, #data.changes)
    assert.is_truthy(data.previewText:find("and 3 more", 1, true))
  end)

  it("escapes names from the roster in the preview", function()
    local data = view({
      guildRoster = roster_with({ ["|cffff0000Evil"] = { rankName = "Soldado", rankIndex = 5 } }),
      draft = { [5] = { role = "alter" } },
    })
    assert.is_truthy(data.previewText:find("||cffff0000Evil", 1, true))
    assert.is_nil(data.previewText:gsub("||", ""):find("|", 1, true))
  end)

  it("keeps the saved role of a renamed rank and says so", function()
    local saved = {
      rev = 1,
      updatedAt = 5,
      by = "Boss",
      ranks = {
        [1] = { role = "cogm", name = "Comandante" },
        [2] = { role = "officer", name = "Oficial" },
        [3] = { role = "rl", name = "Raid Lider" },
        [5] = { role = "member", name = "Soldado" },
      },
    }
    local ranks = { [0] = "Emperador", [1] = "Capitana", [2] = "Oficial", [3] = "Raid Lider", [5] = "Soldado" }
    local data = view({ rankMap = saved, currentRanks = ranks })
    assert.are.equal("cogm", row_of(data, 1).role)
    assert.are.same({ "Rank 1 was renamed from Comandante to Capitana; its role is kept." }, data.drift.renamed)
    assert.is_false(data.drift.structural)
    assert.is_true(data.canSave, "re-saving updates the saved name")
  end)

  it("warns when ranks were added or removed", function()
    local saved = {
      rev = 1,
      updatedAt = 5,
      by = "Boss",
      ranks = { [1] = { role = "cogm", name = "Comandante" }, [7] = { role = "alter", name = "Gone" } },
    }
    local data = view({ rankMap = saved })
    assert.is_true(data.drift.structural)
    assert.are.equal("Guild ranks changed; review the mapping.", data.drift.structuralText)
  end)

  it("shows the author and date of the saved map", function()
    local saved = { rev = 1, updatedAt = 5, by = "Boss", ranks = {} }
    assert.are.equal("Saved by Boss, 2026-11-10 20:30", view({ rankMap = saved }).footer)
    assert.is_nil(view().footer)
  end)

  it("makes every row read-only for somebody who may not manage", function()
    local data = view({ canManage = false })
    assert.is_false(data.canEdit)
    assert.is_false(data.canSave)
    for _, row in ipairs(data.rows) do
      assert.is_true(row.readOnly, row.index)
    end
  end)

  it("makes the own rank read-only for a co-guild master, and only theirs", function()
    local data = view({ ownRole = "cogm", ownRankIndex = 1 })
    assert.is_true(row_of(data, 1).readOnly)
    assert.is_false(row_of(data, 2).readOnly)
    assert.is_false(row_of(data, 5).readOnly)
    assert.is_true(data.canEdit)
    local boss = view({ ownRole = "gm", ownRankIndex = 0 })
    assert.is_false(row_of(boss, 1).readOnly)
  end)

  it("ignores a draft row that is not assignable", function()
    local data = view({ draft = { [2] = { role = "gm" } } })
    assert.are.equal("officer", row_of(data, 2).role)
  end)
end)

describe("ViewModel.RankRoleChoices", function()
  it("offers every role but the guild master", function()
    local values = {}
    for _, choice in ipairs(ViewModel.RankRoleChoices()) do
      values[#values + 1] = choice.value
    end
    assert.are.same({ "cogm", "officer", "rl", "roster", "member", "alter" }, values)
  end)
end)
