-- The Installed check tab's rows (UI/ViewModelInstalls.lua).
local function load_view_model()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Locales/esES",
    "Core/Validate",
    "Domain/PermissionService",
    "Domain/InstallDirectory",
    "UI/Kit/Theme",
    "UI/Kit/Util",
    "Domain/Professions",
    "UI/ViewModel",
    "UI/ViewModelHome",
    "UI/ViewModelInstalls",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.ViewModel
end

local ViewModel = load_view_model()

local NOW = 100000
local ENTRIES = {
  Ann = { rankName = "Officer", rankIndex = 2, class = "WARRIOR", online = true },
  Bob = { rankName = "Member", rankIndex = 5, class = "PRIEST" },
  Cid = { rankName = "Member", rankIndex = 5, class = "MAGE", online = true },
  Dee = { rankName = "Alt", rankIndex = 6, class = "ROGUE" },
  Me = { rankName = "Guild Master", rankIndex = 0, class = "DRUID", online = true },
}
local INSTALLS = {
  Ann = { version = "1.10.0", seenAt = NOW - 30 },
  Bob = { version = "1.9.2", seenAt = NOW - 7200 },
  Gone = { version = "1.0.0", seenAt = 1 },
}

local function rows(args)
  args = args or {}
  args.entries = args.entries or ENTRIES
  args.installs = args.installs or INSTALLS
  args.ownKey, args.ownVersion, args.now = "Me", args.ownVersion or "1.10.0", NOW
  return ViewModel.InstallRows(args)
end

local function names(data)
  local list = {}
  for _, row in ipairs(data.rows) do
    list[#list + 1] = row.key .. ":" .. row.status
  end
  return list
end

describe("ViewModel.InstallRows", function()
  it("lists the guild members only, each with its status, and counts them per filter", function()
    local data = rows()
    assert.are.same({ "Ann:current", "Bob:outdated", "Cid:missing", "Dee:unseen", "Me:current" }, names(data))
    assert.are.equal(5, data.total)
    assert.are.same({ addon = 3, outdated = 1, missing = 1, unseen = 1 }, data.counts)
    assert.are.equal("1.10.0", data.newest)
  end)

  it("shows the version, the age of the last message and the own row as now", function()
    local byKey = {}
    for _, row in ipairs(rows().rows) do
      byKey[row.key] = row
    end
    assert.are.equal("1.9.2", byKey.Bob.version)
    assert.are.equal("-", byKey.Cid.version)
    assert.are.equal("-", byKey.Dee.seen)
    assert.are.equal("now", byKey.Me.seen)
    assert.are_not.equal("-", byKey.Bob.seen)
    assert.are.equal("Outdated", byKey.Bob.statusText)
    assert.are.equal("warning", byKey.Bob.statusColor)
  end)

  it("filters by name, status, version and online", function()
    assert.are.same({ "Bob:outdated" }, names(rows({ search = "BO" })))
    assert.are.same({ "Bob:outdated" }, names(rows({ filter = "outdated" })))
    assert.are.same({ "Ann:current", "Me:current" }, names(rows({ version = "1.10.0" })))
    assert.are.same({ "Ann:current", "Cid:missing", "Me:current" }, names(rows({ onlineOnly = true })))
    assert.are.equal(5, rows({ filter = "missing" }).total)
  end)

  it("sorts versions by number, newest first, with no version as the oldest", function()
    local data = rows({ sort = { key = "version", descending = true } })
    assert.are.same({ "Ann:current", "Me:current", "Bob:outdated", "Cid:missing", "Dee:unseen" }, names(data))
    assert.are.same({ "1.10.0", "1.9.2" }, data.versions)
  end)

  it("sorts the members needing attention first by status, and by rank", function()
    assert.are.equal("Cid", rows({ sort = { key = "status" } }).rows[1].key)
    assert.are.equal("Me", rows({ sort = { key = "rank" } }).rows[1].key)
  end)

  it("lists the members heard from while the guild roster is not loaded", function()
    local data = rows({ entries = {} })
    assert.are.equal(3, data.total)
  end)

  it("gives the version dropdown every version first", function()
    local items = ViewModel.InstallVersionChoices({ "1.10.0", "1.9.2" })
    assert.are.same({ value = false, text = "Every version" }, items[1])
    assert.are.same({ value = "1.9.2", text = "1.9.2" }, items[3])
  end)
end)
