local _, ns = ...

-- The view model of Intel (docs/PVP_INTEL_PLAN.md section 3.4): the rows of every list, the settings card, the menu of
-- a row and what each choice of it does. Everything here is pure: the Intel sub-tab, the compact window and the
-- target button read the service and hand plain data to these functions, and the frames only draw what comes back.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape
local Model = ns.IntelModel

-- ---------------------------------------------------------------------------------------------------------------
-- Views

-- The views of the Intel sub-tab.
function ViewModel.IntelViews()
  return {
    { value = "nearby", text = L("Nearby") },
    { value = "hour", text = L("Last hour") },
    { value = "kos", text = L("Kill on Sight") },
    { value = "ignored", text = L("Ignored") },
    { value = "stats", text = L("Statistics") },
    { value = "report", text = L("Report") },
  }
end

-- The lists the compact window switches between.
function ViewModel.IntelWindowModes()
  return {
    { value = "nearby", text = L("Nearby") },
    { value = "hour", text = L("Last hour") },
    { value = "ignored", text = L("Ignore") },
    { value = "kos", text = L("KOS") },
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Text of a row

-- How long ago, in the shortest form: "12s", "3m", "2h".
function ViewModel.IntelAge(seconds)
  if type(seconds) ~= "number" or seconds ~= seconds then
    return "?"
  end
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then
    return ("%ds"):format(seconds)
  elseif seconds < 3600 then
    return ("%dm"):format(math.floor(seconds / 60))
  end
  return ("%dh"):format(math.floor(seconds / 3600))
end

-- "60", "60?" for an estimated level (a skull enemy), "??" when it is not known.
function ViewModel.IntelLevel(level, estimated)
  if type(level) ~= "number" or level < 1 then
    return "??"
  end
  return tostring(level) .. (estimated and "?" or "")
end

local CATEGORY_NAMES = ns.Locale.Table(function()
  return {
    gank = L("Gank"),
    camp = L("Camper"),
    corpse = L("Corpse camper"),
    objective = L("Objective"),
    insult = L("Insulted me"),
    other = L("Other"),
  }
end)

-- The name of a Kill on Sight category.
function ViewModel.IntelCategoryName(category)
  return CATEGORY_NAMES[category] or CATEGORY_NAMES.other
end

-- The categories as choices of a dropdown.
function ViewModel.IntelCategoryChoices()
  local choices = {}
  for _, category in ipairs(ns.Constants.INTEL_KOS_CATEGORIES) do
    choices[#choices + 1] = { value = category, text = CATEGORY_NAMES[category] }
  end
  return choices
end

local KOS_BADGES = ns.Locale.Table(function()
  return {
    personal = L("Mine"),
    guild = L("Guild"),
  }
end)

-- The badge of a Kill on Sight scope ("personal" | "guild"): { text, color }, or nil for none.
function ViewModel.IntelKosBadge(scope)
  if scope == "guild" then
    return { text = KOS_BADGES.guild, color = "danger" }
  elseif scope == "personal" then
    return { text = KOS_BADGES.personal, color = "warning" }
  end
  return nil
end

-- A player of the lists, ready to draw. `item` is a Nearby, LastHour or Stats item of IntelService; `age` is how long
-- ago he was seen, in seconds. `name` is the plain name (for the actions) and `nameText` the same, escaped.
function ViewModel.IntelRow(item, age)
  local guild = Model.Plain(item.guild)
  return {
    key = item.key,
    name = item.name,
    nameText = Escape(item.name),
    class = item.class,
    classText = Model.ClassName(item.class),
    race = item.race,
    level = item.level,
    levelText = ViewModel.IntelLevel(item.level, item.levelEstimated),
    guild = guild,
    guildText = guild and Escape("<" .. guild .. ">") or "",
    age = age,
    ageText = age and ViewModel.IntelAge(age) or "",
    faded = item.faded == true,
    kos = item.kos,
    stealth = item.stealth == true,
    source = item.source,
    sourceText = item.source and Escape(ViewModel.CharacterName(item.source)) or nil,
    wins = item.wins,
    losses = item.losses,
    ignored = item.ignored == true,
  }
end

-- ---------------------------------------------------------------------------------------------------------------
-- The lists

-- The players nearby now (`list` is IntelService:Nearby).
function ViewModel.IntelNearbyRows(list)
  local rows = {}
  for _, item in ipairs(list) do
    rows[#rows + 1] = ViewModel.IntelRow(item, item.age)
  end
  return rows
end

-- The players seen in the last hour (`list` is IntelService:LastHour, `now` the server time).
function ViewModel.IntelHourRows(list, now)
  local rows = {}
  for _, item in ipairs(list) do
    rows[#rows + 1] = ViewModel.IntelRow(item, math.max(0, now - item.lastSeen))
  end
  return rows
end

-- The ignored players (`list` is IntelService:IgnoreList).
function ViewModel.IntelIgnoreRows(list, formatDate)
  local rows = {}
  for _, entry in ipairs(list) do
    rows[#rows + 1] = {
      key = entry.key,
      name = entry.name,
      nameText = Escape(entry.name),
      added = type(entry.addedAt) == "number" and formatDate and formatDate(entry.addedAt) or "",
      ignored = true,
    }
  end
  return rows
end

-- The Kill on Sight entries of both lists, by name: a row says whose list it is (`scope`), and what the player may do
-- with it. ctx = { role, actor, formatDate }.
function ViewModel.IntelKosRows(service, ctx)
  local rows = {}
  local canAdd = ns.PermissionService.Can(ctx.role, "kos_add")
  for _, scope in ipairs({ "personal", "guild" }) do
    for _, entry in ipairs(service:KosList(scope)) do
      local guild = scope == "guild"
      local reason = Model.Plain(entry.reason, ns.Constants.INTEL_REASON_MAX)
      local row = {
        key = entry.key,
        scope = scope,
        badge = ViewModel.IntelKosBadge(scope),
        name = entry.name,
        nameText = Escape(entry.name),
        category = entry.category,
        categoryText = ViewModel.IntelCategoryName(entry.category),
        reason = reason,
        reasonText = reason and Escape(reason) or "",
        added = type(entry.addedAt) == "number" and ctx.formatDate and ctx.formatDate(entry.addedAt) or "",
        canEdit = true,
        canRemove = true,
        canPromote = false,
      }
      if guild then
        local by = Model.Plain(entry.addedBy)
        row.author = by and Escape(ViewModel.CharacterName(by)) or ""
        row.canEdit = ns.GuildKosService.CanEdit(entry, ctx.actor, ctx.role)
        row.canRemove = ns.GuildKosService.CanRemove(entry, ctx.actor, ctx.role)
      else
        row.author = L("You")
        row.canPromote = canAdd and service.guildKos[entry.key] == nil
      end
      rows[#rows + 1] = row
    end
  end
  table.sort(rows, function(a, b)
    local left, right = a.name:lower(), b.name:lower()
    if left ~= right then
      return left < right
    end
    return a.scope == "personal" and b.scope ~= "personal"
  end)
  return rows
end

-- The most players the statistics table draws at once.
ViewModel.INTEL_STATS_LIMIT = 200

-- The sort keys that start from the biggest value.
ViewModel.INTEL_FIRST_DESCENDING = { level = true, wins = true, losses = true, lastSeen = true }

-- The statistics: every enemy met (`list` is IntelService:Stats), the first INTEL_STATS_LIMIT of them. Returns
-- { rows, shown, total }; `now` is the server time and `formatDate` writes a date.
function ViewModel.IntelStatsRows(list, now, formatDate)
  local rows = {}
  for index, item in ipairs(list) do
    if index > ViewModel.INTEL_STATS_LIMIT then
      break
    end
    local row = ViewModel.IntelRow(item, nil)
    row.lastSeen = item.lastSeen
    row.lastSeenText = formatDate and formatDate(item.lastSeen) or tostring(item.lastSeen)
    row.agoText = ViewModel.IntelAge(math.max(0, now - item.lastSeen))
    row.wins, row.losses = item.wins or 0, item.losses or 0
    row.seen = item.seen or 0
    rows[#rows + 1] = row
  end
  return { rows = rows, shown = #rows, total = #list }
end

-- The filters of the statistics as choices: [value] -> text.
function ViewModel.IntelStatsFilters()
  return {
    { value = "kos", text = L("Kill on Sight") },
    { value = "wins", text = L("With wins") },
    { value = "losses", text = L("With losses") },
  }
end

-- The category choices of the statistics filter, with "any" first.
function ViewModel.IntelStatsCategoryChoices()
  local choices = { { value = "any", text = L("Any category") } }
  for _, choice in ipairs(ViewModel.IntelCategoryChoices()) do
    choices[#choices + 1] = choice
  end
  return choices
end

-- The filter table IntelService:Stats takes, from what the tab holds: { text, kos, wins, losses, category }, where
-- category "any" means none.
function ViewModel.IntelStatsFilter(state)
  return {
    text = state.text,
    kos = state.kos == true,
    wins = state.wins == true,
    losses = state.losses == true,
    category = (state.category ~= nil and state.category ~= "any") and state.category or nil,
  }
end

-- The report, as cards: { { title, stats = { { caption, value } }, lines } ... }. `session` and `season` are the
-- reports of IntelReport (the season may be nil); `zoneName(map)` names a map.
function ViewModel.IntelReportCards(session, season, zoneName)
  local function card(report)
    local lines = ns.IntelReport.Lines(report, zoneName)
    local title = table.remove(lines, 1)
    -- The second line repeats the four figures that the grid shows.
    table.remove(lines, 1)
    return {
      title = title,
      stats = {
        { caption = L("Enemies met"), value = tostring(report.contacts) },
        { caption = L("Wins"), value = tostring(report.wins), color = "success" },
        { caption = L("Losses"), value = tostring(report.losses), color = report.losses > 0 and "danger" or nil },
        { caption = L("New Kill on Sight"), value = tostring(report.newKos) },
      },
      lines = lines,
    }
  end
  local cards = { card(session) }
  if season then
    cards[#cards + 1] = card(season)
  else
    cards[#cards + 1] = {
      title = L("Season"),
      stats = {},
      lines = { L("no PvP season is running.") },
    }
  end
  return cards
end

-- ---------------------------------------------------------------------------------------------------------------
-- The compact window

-- What the compact window draws for `mode` (a value of IntelWindowModes): { rows, more, empty }. ctx = { service,
-- nearby (the list of ns.IntelNearby), now (server time), limit (how many rows fit), formatDate }.
function ViewModel.IntelWindowView(mode, ctx)
  local all
  local service = ctx.service
  if mode == "hour" then
    all = ViewModel.IntelHourRows(service:LastHour(ctx.now), ctx.now)
  elseif mode == "ignored" then
    all = ViewModel.IntelIgnoreRows(service:IgnoreList(), ctx.formatDate)
  elseif mode == "kos" then
    all = {}
    for _, row in ipairs(ViewModel.IntelKosRows(service, { role = ctx.role, actor = ctx.actor })) do
      row.guildText = row.badge and row.badge.text or ""
      row.ageText = row.categoryText
      all[#all + 1] = row
    end
  else
    all = ViewModel.IntelNearbyRows(ctx.nearby)
  end
  local empty = {
    nearby = L("Nobody nearby."),
    hour = L("Nobody in the last hour."),
    ignored = L("Nobody is ignored."),
    kos = L("The Kill on Sight lists are empty."),
  }
  local rows = {}
  for index = 1, math.min(#all, ctx.limit) do
    rows[index] = all[index]
  end
  return { rows = rows, more = math.max(0, #all - #rows), empty = empty[mode] or empty.nearby, total = #all }
end

-- What a click on a row does: "target" (the secure button), "kos", "ignore" or "menu"; nil for anything else.
function ViewModel.IntelClick(button, shift, ctrl)
  if button == "RightButton" then
    return "menu"
  elseif button ~= "LeftButton" then
    return nil
  elseif shift then
    return "kos"
  elseif ctrl then
    return "ignore"
  end
  return "target"
end

-- ---------------------------------------------------------------------------------------------------------------
-- The menu of a row

local ANNOUNCE_CHANNELS = { "self", "party", "raid", "guild", "localdefense" }

local ANNOUNCE_NAMES = ns.Locale.Table(function()
  return {
    self = L("Only me"),
    party = L("Party"),
    raid = L("Raid"),
    guild = L("Guild"),
    localdefense = L("Local Defense"),
  }
end)

-- The menu of a row. `row` is a row of the lists (name, kos, ignored); ctx = { role, actor, group = "PARTY" | "RAID" |
-- "INSTANCE_CHAT" | nil, guildEntry = the guild Kill on Sight entry of the player or nil, inGuild }. The items are
-- those of Kit.Menu.Open; `value` says what a choice does (see IntelRun).
function ViewModel.IntelMenu(row, ctx)
  local items = {}
  local function add(value, text, extra)
    local item = { value = value, text = text }
    for field, content in pairs(extra or {}) do
      item[field] = content
    end
    items[#items + 1] = item
  end
  local function separator()
    items[#items + 1] = { value = "-", text = "", separator = true }
  end

  if not row.ignored then
    add("remove", L("Remove from the list"))
    separator()
  end
  add("kos", row.kos == "personal" and L("Remove from my Kill on Sight") or L("Add to my Kill on Sight"))
  local canAddGuild = ns.PermissionService.Can(ctx.role, "kos_add")
  local guildEntry = ctx.guildEntry
  local canChangeGuild = canAddGuild
    and (guildEntry == nil or ns.GuildKosService.CanEdit(guildEntry, ctx.actor, ctx.role))
  add("-guild", L("Guild Kill on Sight:"), { disabled = true })
  for _, category in ipairs(ns.Constants.INTEL_KOS_CATEGORIES) do
    add("gkos:" .. category, "  " .. ViewModel.IntelCategoryName(category), { disabled = not canChangeGuild })
  end
  if guildEntry and ns.GuildKosService.CanRemove(guildEntry, ctx.actor, ctx.role) then
    add("gremove", L("Remove from the guild Kill on Sight"))
  end
  separator()
  add("ignore", row.ignored and L("Stop ignoring") or L("Ignore"))
  separator()
  add("-announce", L("Announce to:"), { disabled = true })
  local group = ctx.group
  for _, channel in ipairs(ANNOUNCE_CHANNELS) do
    local disabled = false
    if channel == "party" then
      disabled = group == nil
    elseif channel == "raid" then
      disabled = not (group == "RAID" or group == "INSTANCE_CHAT")
    elseif channel == "guild" then
      disabled = ctx.inGuild == false
    end
    add("say:" .. channel, "  " .. ANNOUNCE_NAMES[channel], { disabled = disabled })
  end
  return items
end

local ANNOUNCE_ERRORS = ns.Locale.Table(function()
  return {
    bad_name = L("that is not a valid name."),
    no_group = L("you are not in a group for that."),
    send_failed = L("the message could not be sent."),
    bad_channel = L("unknown channel."),
  }
end)

-- Does what a choice of the menu (or a click) says on `row`. deps = { commands (IntelCommands), service, directory
-- (optional), alerts (IntelAlerts) }. Returns the lines to show, a failure included (see Validate.IsFailure); an empty
-- list when there is nothing to say. Announcing to Local Defense works from here because this runs from a click.
function ViewModel.IntelRun(value, row, deps)
  if type(value) ~= "string" or type(row) ~= "table" or type(row.name) ~= "string" then
    return {}
  end
  local commands = deps.commands
  if value == "remove" then
    deps.service:RemoveNearby(row.key)
    if deps.directory then
      deps.directory:Remove(row.key)
    end
    commands:Changed()
    return {}
  elseif value == "kos" then
    if row.kos == "personal" then
      return commands:KosRemove(row.name)
    end
    return commands:KosAdd(row.name)
  elseif value == "gremove" then
    return commands:GuildRemove(row.name)
  elseif value == "ignore" then
    if row.ignored then
      return commands:IgnoreRemove(row.name)
    end
    return commands:IgnoreAdd(row.name)
  end
  local category = value:match("^gkos:(%a+)$")
  if category then
    return commands:GuildAdd(row.name, category, nil)
  end
  local channel = value:match("^say:(%a+)$")
  if channel then
    local ok, why = deps.alerts:AnnounceNow(row.name, channel)
    if not ok then
      return ns.Validate.Failure(ANNOUNCE_ERRORS[why] or tostring(why))
    end
  end
  return {}
end

-- ---------------------------------------------------------------------------------------------------------------
-- The settings

local REMOVE_MINUTES = { 0, 1, 2, 3, 5, 10, 15 }
local WINDOW_ROWS = { 4, 6, 8, 10, 12, 15, 20 }

local WARN_NAMES = ns.Locale.Table(function()
  return {
    window = L("Warning window"),
    error = L("Top of the screen"),
    none = L("No warning"),
  }
end)

local ANNOUNCE_SETTING_NAMES = ns.Locale.Table(function()
  return {
    none = L("Off"),
    self = L("Only me"),
    party = L("Party"),
    raid = L("Raid"),
    guild = L("Guild"),
  }
end)

local MAP_MODE_NAMES = ns.Locale.Table(function()
  return {
    all = L("Every zone"),
    zone = L("This zone"),
    continent = L("This continent"),
    none = L("Off"),
  }
end)

local function choices(order, names)
  local list = {}
  for _, value in ipairs(order) do
    list[#list + 1] = { value = value, text = names[value] }
  end
  return list
end

-- A list of numbers as choices, with `current` among them even when it is not one of the usual values.
local function numberChoices(values, current, label)
  local list, all, seen = {}, {}, false
  for _, value in ipairs(values) do
    seen = seen or value == current
    all[#all + 1] = value
  end
  if not seen and type(current) == "number" then
    all[#all + 1] = current
    table.sort(all)
  end
  for _, value in ipairs(all) do
    list[#list + 1] = { value = value, text = label(value) }
  end
  return list
end

-- The settings card, in groups: { { title, items = { { key, kind, label, description, value, choices } } } }.
-- `kind` is "switch", "choice", "races" or "zones" (a set of chips: each choice has `active`). `settings` is
-- Settings.Intel; ctx = { mapId, mapName (the zone the player stands in, nil when unknown), zoneName = function(map) }.
-- Apply a change with IntelApplySetting.
function ViewModel.IntelSettingsGroups(settings, ctx)
  local window = settings.window
  local function switch(key, label, description, value)
    return { key = key, kind = "switch", label = label, description = description, value = value == true }
  end
  local zoneText
  if ctx.mapId then
    zoneText = ctx.mapName and Escape(ctx.mapName) or L("map %d"):format(ctx.mapId)
  end
  local races = {}
  for _, token in ipairs(ns.Constants.INTEL_RACES) do
    races[#races + 1] = { value = token, text = Model.RaceName(token), active = settings.alertRaces[token] == true }
  end
  local skipped = {}
  for map in pairs(settings.excludedZones) do
    local name = ctx.zoneName and ctx.zoneName(map) or nil
    skipped[#skipped + 1] = { value = map, text = name and Escape(name) or L("map %d"):format(map), active = true }
  end
  table.sort(skipped, function(a, b)
    return a.value < b.value
  end)
  local detection = {
    switch(
      "enabled",
      L("Detect enemy players"),
      L("Reads the enemies in range of the nameplates. It never runs in dungeons or raids."),
      settings.enabled
    ),
    switch("inSanctuary", L("In sanctuaries"), nil, settings.inSanctuary),
    switch("inBattleground", L("In battlegrounds"), nil, settings.inBattleground),
    switch("inArena", L("In arenas"), nil, settings.inArena),
    {
      key = "zone",
      kind = "switch",
      label = L("Skip this zone"),
      description = zoneText,
      value = ctx.mapId ~= nil and settings.excludedZones[ctx.mapId] == true,
      disabled = ctx.mapId == nil,
    },
  }
  if #skipped > 0 then
    detection[#detection + 1] = { key = "excludedZones", kind = "zones", label = L("Skipped zones"), choices = skipped }
  end
  detection[#detection + 1] = {
    key = "removeMinutes",
    kind = "choice",
    label = L("Leave the Nearby list after"),
    value = settings.removeMinutes,
    choices = numberChoices(REMOVE_MINUTES, settings.removeMinutes, function(value)
      return value == 0 and L("Never") or L("%d min"):format(value)
    end),
  }
  return {
    {
      title = L("Detection"),
      items = detection,
    },
    {
      title = L("Alerts"),
      items = {
        switch("sound", L("Alert sounds"), nil, settings.sound),
        switch("alertKos", L("Kill on Sight player"), nil, settings.alertKos),
        switch("alertKosGuild", L("Guild of a Kill on Sight player"), nil, settings.alertKosGuild),
        switch("alertStealth", L("Stealth ability"), nil, settings.alertStealth),
        switch("alertNew", L("Any new enemy"), nil, settings.alertNew),
        switch(
          "alertGuildReports",
          L("Guildmate reports"),
          L("A guildmate sees a Kill on Sight player in your zone."),
          settings.alertGuildReports
        ),
        { key = "alertRaces", kind = "races", label = L("Always alert for these races"), choices = races },
        {
          key = "warnTarget",
          kind = "choice",
          label = L("Show the warning in"),
          value = settings.warnTarget,
          choices = choices({ "window", "error", "none" }, WARN_NAMES),
        },
      },
    },
    {
      title = L("Sharing"),
      items = {
        switch(
          "share",
          L("Share sightings with the guild"),
          L("Guildmates see the enemies you meet and where you were. Never sent in arenas or dungeons."),
          settings.share
        ),
        {
          key = "announce",
          kind = "choice",
          label = L("Announce new enemies to"),
          value = settings.announce,
          choices = choices({ "none", "self", "party", "raid", "guild" }, ANNOUNCE_SETTING_NAMES),
        },
      },
    },
    {
      title = L("Maps"),
      items = {
        {
          key = "mapMode",
          kind = "choice",
          label = L("Show enemies on the maps"),
          value = settings.mapMode,
          choices = choices({ "all", "zone", "continent", "none" }, MAP_MODE_NAMES),
        },
        switch("mapFollow", L("Open map follows a sighting"), nil, settings.mapFollow),
        switch("minimapTooltip", L("Level and class on the minimap tooltip"), nil, settings.minimapTooltip),
        switch("minimapFeed", L("Add minimap enemies to Nearby"), nil, settings.minimapFeed),
      },
    },
    {
      title = L("Window"),
      items = {
        switch("window.shown", L("Show the Intel window"), nil, window.shown),
        switch("window.locked", L("Lock the Intel window"), nil, window.locked),
        {
          key = "window.rows",
          kind = "choice",
          label = L("Rows in the Intel window"),
          value = window.rows,
          choices = numberChoices(WINDOW_ROWS, window.rows, tostring),
        },
        switch("targetButton", L("Button by the target frame"), nil, settings.targetButton),
      },
    },
  }
end

-- The values each scalar setting takes: a list, or "boolean".
local CHOICE_VALUES = {
  removeMinutes = REMOVE_MINUTES,
  warnTarget = { "window", "error", "none" },
  announce = { "none", "self", "party", "raid", "guild" },
  mapMode = { "all", "zone", "continent", "none" },
}

local BOOLEAN_SETTINGS = {
  "enabled",
  "share",
  "sound",
  "alertNew",
  "alertKos",
  "alertKosGuild",
  "alertStealth",
  "alertGuildReports",
  "inSanctuary",
  "inBattleground",
  "inArena",
  "mapFollow",
  "minimapTooltip",
  "minimapFeed",
  "targetButton",
}

local function listed(values, value)
  for _, entry in ipairs(values) do
    if entry == value then
      return true
    end
  end
  return false
end

-- Changes a setting of `settings` (Settings.Intel) from the card. Keys: the ones of IntelSettingsGroups, "zone" (the
-- zone the player stands in, ctx.mapId), "excludedZone:<map>", "alertRaces:<TOKEN>" and "window.rows|shown|locked".
-- A change that is not valid is refused. ctx = { mapId, inCombat }: the rows of the window cannot change in combat
-- (the secure buttons of the window are not touched then). Returns true, or false plus "invalid" | "combat".
function ViewModel.IntelApplySetting(settings, key, value, ctx)
  ctx = ctx or {}
  if key == "zone" then
    if type(ctx.mapId) ~= "number" or type(value) ~= "boolean" then
      return false, "invalid"
    end
    settings.excludedZones[ctx.mapId] = value and true or nil
    return true
  end
  local token = type(key) == "string" and key:match("^alertRaces:(%u+)$")
  if token then
    if not listed(ns.Constants.INTEL_RACES, token) or type(value) ~= "boolean" then
      return false, "invalid"
    end
    settings.alertRaces[token] = value and true or nil
    return true
  end
  local zone = type(key) == "string" and key:match("^excludedZone:(%d+)$")
  if zone then
    local map = tonumber(zone)
    if not ns.Validate.Int(map, 1, ns.Constants.LAYER_MAP_MAX) or type(value) ~= "boolean" then
      return false, "invalid"
    end
    settings.excludedZones[map] = value and true or nil
    return true
  end
  if key == "window.rows" then
    if ctx.inCombat then
      return false, "combat"
    end
    if not ns.Validate.Int(value, 1, 20) then
      return false, "invalid"
    end
    settings.window.rows = value
    return true
  elseif key == "window.shown" or key == "window.locked" then
    if type(value) ~= "boolean" then
      return false, "invalid"
    end
    settings.window[key:match("%.(%a+)$")] = value
    return true
  end
  if CHOICE_VALUES[key] then
    if not listed(CHOICE_VALUES[key], value) then
      return false, "invalid"
    end
    settings[key] = value
    return true
  end
  if listed(BOOLEAN_SETTINGS, key) and type(value) == "boolean" then
    settings[key] = value
    return true
  end
  return false, "invalid"
end

ViewModel.INTEL_SETTING_ERRORS = ns.Locale.Table(function()
  return {
    invalid = L("that value is not valid."),
    combat = L("that cannot change during combat."),
  }
end)

-- ---------------------------------------------------------------------------------------------------------------
-- Notices

-- The notice about the enemy nameplates: nil when there is nothing to say, else { text, canEnable }. ctx = { enabled
-- (detection is on), nameplates (true, false or nil), inCombat }. The nameplates can only be turned on out of combat.
function ViewModel.IntelNameplateNotice(ctx)
  if not ctx.enabled or ctx.nameplates ~= false then
    return nil
  end
  return {
    text = L("Enemy nameplates are off, so Intel cannot see enemy players. Turn them on to detect them."),
    canEnable = not ctx.inCombat,
  }
end

-- The lines the minimap tooltip adds: the enemies nearby and how many of them are on a Kill on Sight list. Nothing
-- while there is no list or nobody is there.
function ViewModel.IntelMinimapLines(nearby)
  if type(nearby) ~= "table" or #nearby == 0 then
    return {}
  end
  local kos = 0
  for _, item in ipairs(nearby) do
    if item.kos then
      kos = kos + 1
    end
  end
  return { L("Intel: %d enemies nearby, %d Kill on Sight"):format(#nearby, kos) }
end

-- The warning window's colour token for an alert kind.
function ViewModel.IntelWarnColor(kind)
  if kind == "kos" or kind == "kosGuild" then
    return "danger"
  elseif kind == "stealth" then
    return "warning"
  end
  return "info"
end

-- The lines of the tooltip of a row: { { text, color } }. `kosEntry` is the Kill on Sight entry of the player, if any.
function ViewModel.IntelRowTooltip(row, kosEntry)
  local lines = { { text = row.nameText, color = "text" } }
  local detail = {}
  if row.levelText ~= "??" then
    detail[#detail + 1] = L("Level %s"):format(row.levelText)
  end
  if row.classText then
    detail[#detail + 1] = row.classText
  end
  if #detail > 0 then
    lines[#lines + 1] = { text = table.concat(detail, " "), color = "dim" }
  end
  if row.guild then
    lines[#lines + 1] = { text = row.guildText, color = "dim" }
  end
  if row.sourceText then
    lines[#lines + 1] = { text = L("Reported by %s"):format(row.sourceText), color = "info" }
  end
  if kosEntry then
    local text = L("Kill on Sight: %s"):format(ViewModel.IntelCategoryName(kosEntry.category))
    local reason = Model.Plain(kosEntry.reason, ns.Constants.INTEL_REASON_MAX)
    lines[#lines + 1] = { text = reason and (text .. " - " .. Escape(reason)) or text, color = "danger" }
  end
  lines[#lines + 1] = { text = L("Left click: target. Shift: Kill on Sight. Ctrl: Ignore."), color = "muted" }
  lines[#lines + 1] = { text = L("Right click: menu."), color = "muted" }
  return lines
end

-- The figures over the statistics table: the enemies met, the wins and losses against them, and the honourable kills
-- of the character (`honorTotal`, nil when the client does not give them).
function ViewModel.IntelStatsSummary(service, honorTotal)
  local wins, losses = 0, 0
  for _, record in pairs(service.intel.players) do
    if type(record) == "table" then
      wins = wins + (type(record.wins) == "number" and record.wins or 0)
      losses = losses + (type(record.losses) == "number" and record.losses or 0)
    end
  end
  local honour = { caption = L("Honourable kills"), value = honorTotal and tostring(honorTotal) or "-" }
  if not honorTotal then
    honour.color = "muted"
  end
  return {
    { caption = L("Enemies met"), value = tostring(service.playerCount) },
    { caption = L("Wins against them"), value = tostring(wins), color = "success" },
    { caption = L("Losses against them"), value = tostring(losses), color = losses > 0 and "danger" or nil },
    honour,
  }
end
