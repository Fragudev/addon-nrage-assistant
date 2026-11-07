local _, ns = ...

-- The Installed check tab (Admin, gm and cogm): every guild member with whether it runs the addon and which version,
-- from what InstallDirectory saved. Rows are values, not text, so the tab only draws them.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape

-- How each status is shown, and the order the Status column sorts in (the ones needing attention first).
local STATUS = {
  missing = { order = 1, color = "danger" },
  incompatible = { order = 2, color = "danger" },
  outdated = { order = 3, color = "warning" },
  installed = { order = 4, color = "info" },
  current = { order = 5, color = "success" },
  unseen = { order = 6, color = "muted" },
}

ViewModel.INSTALL_STATUS_TEXT = ns.Locale.Table(function()
  return {
    current = L("Up to date"),
    outdated = L("Outdated"),
    installed = L("Installed"),
    incompatible = L("Incompatible"),
    missing = L("Not installed"),
    unseen = L("Never seen"),
  }
end)

-- The filter chips of the tab, in order: which statuses each one keeps.
ViewModel.INSTALL_FILTERS = { "addon", "outdated", "missing", "unseen" }
local FILTER_KEEPS = {
  addon = { current = true, outdated = true, installed = true, incompatible = true },
  outdated = { outdated = true, incompatible = true },
  missing = { missing = true },
  unseen = { unseen = true },
}
ViewModel.INSTALL_FILTER_TEXT = ns.Locale.Table(function()
  return {
    addon = L("With addon"),
    outdated = L("Outdated"),
    missing = L("Not installed"),
    unseen = L("Never seen"),
  }
end)

local SORTABLE = { name = true, class = true, rank = true, status = true, version = true, seen = true }
-- The columns whose first click sorts the most recent first.
ViewModel.INSTALL_FIRST_DESCENDING = { seen = true, version = true }

local function sortRows(rows, sort)
  local key, descending = sort and sort.key, sort and sort.descending
  if not SORTABLE[key] then
    key, descending = "name", false
  end
  local function less(a, b)
    if key == "version" then
      -- A row with no comparable version sorts as the oldest.
      local comparison = ns.InstallDirectory.CompareVersions(a.versionRaw, b.versionRaw)
      if comparison == nil then
        local left = ns.InstallDirectory.CompareVersions(a.versionRaw, a.versionRaw) ~= nil
        local right = ns.InstallDirectory.CompareVersions(b.versionRaw, b.versionRaw) ~= nil
        if left == right then
          return nil
        end
        return right
      end
      if comparison == 0 then
        return nil
      end
      return comparison < 0
    end
    local left, right
    if key == "name" then
      left, right = a.sortName, b.sortName
    elseif key == "class" then
      left, right = a.class:lower(), b.class:lower()
    elseif key == "rank" then
      left, right = a.rankIndex or math.huge, b.rankIndex or math.huge
    elseif key == "status" then
      left, right = STATUS[a.status].order, STATUS[b.status].order
    else
      left, right = a.seenAt or -math.huge, b.seenAt or -math.huge
    end
    if left == right then
      return nil
    end
    return left < right
  end
  table.sort(rows, function(a, b)
    local result = less(a, b)
    if result == nil then
      return a.sortName < b.sortName
    end
    if descending then
      return not result
    end
    return result
  end)
end

-- The rows of the tab. args:
--   entries     ns.guildRoster.entries (name -> { rankName, rankIndex, class, online })
--   installs    db.global.installs (see InstallDirectory)
--   ownKey, ownVersion   this character and its version: its own row is always up to date with itself
--   now         server time, for the "last seen" age
--   search      part of a name; filter = a key of INSTALL_FILTERS or nil; version = a version text or nil;
--   onlineOnly  only the members online now; sort = { key, descending } (default: name)
-- Returns { rows, total (before the filters), counts = { [filter] = members }, versions (newest first, for the
-- dropdown), newest }.
function ViewModel.InstallRows(args)
  local entries = args.entries or {}
  local installs = args.installs or {}
  local now = args.now
  local names = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  -- Before the guild roster has loaded, the members heard from are all there is.
  if #names == 0 then
    for name in pairs(installs) do
      names[#names + 1] = name
    end
  end

  local newest = ns.InstallDirectory.Newest(installs, args.ownVersion)
  local rows, counts, seenVersions = {}, {}, {}
  for _, filter in ipairs(ViewModel.INSTALL_FILTERS) do
    counts[filter] = 0
  end
  for _, name in ipairs(names) do
    local guild = entries[name] or {}
    local mine = args.ownKey ~= nil and args.ownKey == name
    local record = installs[name]
    if mine then
      record = { version = args.ownVersion, seenAt = now }
    end
    record = type(record) == "table" and record or nil
    local online = mine or guild.online == true
    local status = ns.InstallDirectory.Status(record, newest, online)
    local version = record and type(record.version) == "string" and record.version or nil
    if version then
      seenVersions[version] = true
    end
    local seenAt = record and type(record.seenAt) == "number" and record.seenAt or nil
    rows[#rows + 1] = {
      key = name,
      name = Escape(name),
      sortName = name:lower(),
      mine = mine,
      classToken = guild.class,
      class = Escape(ViewModel.ClassText(guild.class) or "-"),
      rank = guild.rankName and Escape(guild.rankName) or "-",
      rankIndex = guild.rankIndex,
      online = online,
      status = status,
      statusText = ViewModel.INSTALL_STATUS_TEXT[status],
      statusColor = STATUS[status].color,
      versionRaw = version,
      version = version and Escape(version) or "-",
      seenAt = seenAt,
      seen = (mine and L("now")) or (seenAt and now and ViewModel.AgeText(math.max(0, now - seenAt))) or "-",
    }
    for _, filter in ipairs(ViewModel.INSTALL_FILTERS) do
      if FILTER_KEEPS[filter][status] then
        counts[filter] = counts[filter] + 1
      end
    end
  end

  local needle = (args.search or ""):lower()
  local keeps = args.filter and FILTER_KEEPS[args.filter] or nil
  local filtered = {}
  for _, row in ipairs(rows) do
    local keep = needle == "" or row.sortName:find(needle, 1, true) ~= nil
    keep = keep and (keeps == nil or keeps[row.status] == true)
    keep = keep and (args.version == nil or row.versionRaw == args.version)
    keep = keep and (not args.onlineOnly or row.online)
    if keep then
      filtered[#filtered + 1] = row
    end
  end
  sortRows(filtered, args.sort)

  local versions = {}
  for version in pairs(seenVersions) do
    versions[#versions + 1] = version
  end
  table.sort(versions, function(a, b)
    local comparison = ns.InstallDirectory.CompareVersions(a, b)
    if comparison == nil or comparison == 0 then
      return a < b
    end
    return comparison > 0
  end)

  return { rows = filtered, total = #rows, counts = counts, versions = versions, newest = newest }
end

-- The items of the version dropdown: every version first, then each one seen, newest first.
function ViewModel.InstallVersionChoices(versions)
  local items = { { value = false, text = L("Every version") } }
  for _, version in ipairs(versions or {}) do
    items[#items + 1] = { value = version, text = Escape(version) }
  end
  return items
end
