local _, ns = ...

-- The Intel sub-tab of PvP (docs/PVP_INTEL_PLAN.md section 3.4): who is nearby, the last hour, the Kill on Sight lists
-- (with the import box), the Ignore list, the statistics, the report and the settings. What each list shows comes from
-- ViewModel (UI/ViewModelIntel.lua); this file only draws it with the kit and sends the actions to the commands.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- What the tab remembers while the session lasts.
local state = {
  view = "nearby",
  settingsOpen = false,
  stats = {
    filter = { text = "", kos = false, wins = false, losses = false, category = "any" },
    sort = { key = "lastSeen", descending = true },
  },
  add = { name = "", category = "other", reason = "" },
  editing = nil,
  edit = { category = "other", reason = "" },
  import = { text = "", target = "kos" },
}

local function settings()
  return ns.Settings.Intel(ns.db)
end

local function currentMap()
  local read = ns.Platform and ns.Platform.GetPlayerMapId
  if type(read) ~= "function" then
    return nil
  end
  local ok, mapId = pcall(read)
  return ok and type(mapId) == "number" and mapId or nil
end

-- True while the Intel view on screen shows ages, so it is drawn again as time passes (Nearby and the last hour).
function UI.IntelLive()
  return state.view == "nearby" or state.view == "hour"
end

-- True while the Intel sub-tab is the one on screen.
function UI.IntelShown()
  return UI.CurrentTab() == "pvp" and UI.PvPShared ~= nil and UI.PvPShared.sub() == "intel"
end

-- Opens the PvP tab on the Intel sub-tab, on `view` ("nearby", "hour", "kos", "ignored", "stats", "report") or on the
-- settings card ("settings").
function UI.OpenIntelTab(view)
  if view == "settings" then
    state.settingsOpen = true
  elseif view then
    state.view = view
  end
  UI.OpenTab("pvp", { pvpSub = "intel" })
end

-- Runs a menu choice (or an action of a row) and tells the player what happened.
local function run(value, row)
  local lines = ViewModel.IntelRun(value, row, {
    commands = ns.intelCommands,
    service = ns.intel,
    directory = ns.intelDirectory,
    alerts = ns.intelAlerts,
  })
  if lines[1] or ns.Validate.IsFailure(lines) then
    UI.Report(lines)
  else
    UI.Redraw()
  end
end

local function openMenu(anchor, row)
  local platform = ns.Platform
  Kit.Menu.Open(
    anchor,
    ViewModel.IntelMenu(row, {
      role = UI.Role(),
      actor = platform.GetIdentityKey(),
      group = platform.GroupDistribution(),
      inGuild = platform.IsInGuild(),
      guildEntry = ns.intel.guildKos[row.key],
    }),
    function(value)
      run(value, row)
    end
  )
end

local function classColor(class)
  return Kit.Theme.ClassColor(class) or "dim"
end

local function kosCell(kos)
  local badge = ViewModel.IntelKosBadge(kos)
  if not badge then
    return ""
  end
  return { widget = "badge", opts = { text = badge.text, color = badge.color, fixed = true } }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Settings

local function applySetting(key, value)
  local ok, why = ViewModel.IntelApplySetting(settings(), key, value, {
    mapId = currentMap(),
    inCombat = ns.Platform.IsInCombat(),
  })
  if not ok then
    UI.Notify("danger", ViewModel.INTEL_SETTING_ERRORS[why] or tostring(why))
    return
  end
  UI.IntelRefreshAll()
  UI.Redraw()
end

local function drawSetting(card, item)
  if item.kind == "switch" then
    Kit.Switch(card, {
      label = item.label,
      description = item.description,
      checked = item.value,
      disabled = item.disabled,
      onChange = function(on)
        applySetting(item.key, on)
      end,
    })
  elseif item.kind == "choice" then
    local row = Kit.Row(card, { gap = 10, align = "center" })
    Kit.Label(row, { text = item.label, layout = { weight = 1 } })
    Kit.Dropdown(row, {
      items = item.choices,
      value = item.value,
      layout = { width = 170 },
      onChange = function(value)
        applySetting(item.key, value)
      end,
    })
  elseif item.kind == "races" or item.kind == "zones" then
    Kit.Label(card, { text = item.label, style = "small", color = "dim" })
    local chips = Kit.Flow(card, { gap = 6, rowGap = 6 })
    -- A race is switched on and off by its chip; a skipped zone is let go by switching its chip off.
    local prefix = item.kind == "races" and "alertRaces:" or "excludedZone:"
    for _, choice in ipairs(item.choices) do
      Kit.Chip(chips, {
        text = choice.text,
        active = choice.active,
        onToggle = function(active)
          applySetting(prefix .. choice.value, active)
        end,
      })
    end
  end
end

local function drawSettings(page)
  local mapId = currentMap()
  local groups = ViewModel.IntelSettingsGroups(settings(), {
    mapId = mapId,
    mapName = mapId and ns.Platform.GetMapName(mapId) or nil,
    zoneName = ns.Platform.GetMapName,
  })
  for _, group in ipairs(groups) do
    local card = Kit.Card(page, { title = group.title, gap = 10 })
    for _, item in ipairs(group.items) do
      drawSetting(card, item)
    end
  end
  Kit.Label(page, {
    text = L("Intel reads the enemies whose nameplate you can see. Stealthed enemies are not seen."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Nearby and last hour

local function playerColumns(timeTitle)
  return {
    { key = "kos", title = "", width = 62, fit = true },
    { key = "name", title = L("Name"), weight = 2 },
    { key = "level", title = L("Level"), width = 50, align = "RIGHT", fit = true },
    { key = "class", title = L("Class"), weight = 1.2 },
    { key = "guild", title = L("Guild"), weight = 2 },
    { key = "by", title = L("Reported by"), weight = 1.2 },
    { key = "age", title = timeTitle, width = 56, align = "RIGHT", fit = true },
  }
end

local function playerTable(page, rows, timeTitle, emptyText)
  local list = {}
  for _, row in ipairs(rows) do
    list[#list + 1] = {
      highlight = row.kos ~= nil,
      onClick = function(obj)
        openMenu(obj.frame, row)
      end,
      cells = {
        kos = kosCell(row.kos),
        name = { text = row.nameText, color = row.faded and "muted" or classColor(row.class) },
        level = row.levelText,
        class = { text = row.classText or "", color = "dim" },
        guild = { text = row.guildText, color = "dim" },
        by = { text = row.sourceText or "", color = "dim" },
        age = { text = row.ageText, color = "muted" },
      },
    }
  end
  Kit.Table(page, { columns = playerColumns(timeTitle), fit = true, rows = list, emptyText = emptyText })
  Kit.Label(page, {
    text = L("Click a player for the menu: Kill on Sight, Ignore, announce."),
    style = "small",
    color = "muted",
  })
end

local function nearbyView(page)
  local rows = ViewModel.IntelNearbyRows(ns.IntelNearby())
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.Label(bar, { text = L("%d nearby"):format(#rows), color = "dim", layout = { weight = 1 } })
  Kit.Button(bar, {
    text = L("Clear the list"),
    layout = { width = "auto" },
    onClick = function()
      ns.intelCommands:Clear()
      ns.intelCommands:Changed()
      UI.Redraw()
    end,
  })
  playerTable(page, rows, L("Ago"), L("Nobody nearby."))
end

local function hourView(page)
  local now = ns.Platform.ServerTime()
  playerTable(page, ViewModel.IntelHourRows(ns.intel:LastHour(now), now), L("Ago"), L("Nobody in the last hour."))
end

-- ---------------------------------------------------------------------------------------------------------------
-- Kill on Sight

local function addForm(page)
  local card = Kit.Card(page, { title = L("Add a player"), gap = 8 })
  local row = Kit.Row(card, { gap = 12, align = "top" })
  local name = Kit.Field(row, { label = L("Name"), layout = { weight = 2 } })
  Kit.EditBox(name, {
    text = state.add.name,
    maxLetters = ns.Constants.INTEL_NAME_MAX,
    onChange = function(text)
      state.add.name = text
    end,
  })
  local category = Kit.Field(row, { label = L("Category"), layout = { weight = 2 } })
  Kit.Dropdown(category, {
    items = ViewModel.IntelCategoryChoices(),
    value = state.add.category,
    onChange = function(value)
      state.add.category = value
    end,
  })
  local reason = Kit.Field(row, { label = L("Reason"), layout = { weight = 4 } })
  Kit.EditBox(reason, {
    text = state.add.reason,
    maxLetters = ns.Constants.INTEL_REASON_MAX,
    onChange = function(text)
      state.add.reason = text
    end,
  })
  local buttons = Kit.Row(card, { gap = 10, align = "center" })
  local function send(guild)
    local commands = ns.intelCommands
    local reasonText = state.add.reason ~= "" and state.add.reason or nil
    local lines
    if guild then
      lines = commands:GuildAdd(state.add.name, state.add.category, reasonText)
    else
      lines = commands:KosAdd(state.add.name, state.add.category, reasonText)
    end
    if not ns.Validate.IsFailure(lines) then
      state.add.name, state.add.reason = "", ""
    end
    UI.Report(lines)
  end
  Kit.Button(buttons, {
    text = L("Add to my list"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      send(false)
    end,
  })
  Kit.Button(buttons, {
    text = L("Add to the guild list"),
    layout = { width = "auto" },
    onClick = function()
      send(true)
    end,
  })
end

local function editKey(row)
  return row.scope .. ":" .. row.key
end

local function saveEdit(row)
  local commands = ns.intelCommands
  local reason = state.edit.reason ~= "" and state.edit.reason or nil
  local lines
  if row.scope == "guild" then
    lines = commands:GuildAdd(row.name, state.edit.category, reason)
  else
    lines = commands:KosAdd(row.name, state.edit.category, reason)
  end
  if not ns.Validate.IsFailure(lines) then
    state.editing = nil
  end
  UI.Report(lines)
end

local function removeButton(row)
  local key = "intel:" .. editKey(row)
  local function remove()
    UI.Disarm()
    local commands = ns.intelCommands
    UI.Report(row.scope == "guild" and commands:GuildRemove(row.name) or commands:KosRemove(row.name))
  end
  if UI.IsArmed(key) then
    return {
      widget = "iconButton",
      opts = { icon = "check", color = "danger", tooltip = L("Click again to remove"), layout = {}, onClick = remove },
    }
  end
  return {
    widget = "iconButton",
    opts = {
      icon = "trash",
      variant = "danger",
      tooltip = L("Remove"),
      layout = {},
      onClick = function()
        UI.Arm(key)
      end,
    },
  }
end

local function kosActions(row)
  local editing = state.editing == editKey(row)
  local edit, promote, remove = "", "", ""
  if editing then
    edit = {
      widget = "iconButton",
      opts = {
        icon = "check",
        tooltip = L("Save"),
        layout = {},
        onClick = function()
          saveEdit(row)
        end,
      },
    }
    remove = {
      widget = "iconButton",
      opts = {
        icon = "close",
        tooltip = L("Cancel"),
        layout = {},
        onClick = function()
          state.editing = nil
          UI.Redraw()
        end,
      },
    }
    return edit, promote, remove
  end
  if row.canEdit then
    edit = {
      widget = "iconButton",
      opts = {
        icon = "pencil",
        tooltip = L("Edit the category and the reason"),
        layout = {},
        onClick = function()
          state.editing = editKey(row)
          state.edit = { category = row.category, reason = row.reason or "" }
          UI.Redraw()
        end,
      },
    }
  end
  if row.canPromote then
    promote = {
      widget = "iconButton",
      opts = {
        icon = "users",
        tooltip = L("Share with the guild"),
        layout = {},
        onClick = function()
          UI.Report(ns.intelCommands:GuildAdd(row.name, nil, nil))
        end,
      },
    }
  end
  if row.canBounty then
    -- Admins turn a guild KOS player into a bounty; the button shares the slot of "Share with the guild".
    promote = {
      widget = "iconButton",
      opts = {
        icon = "swords",
        tooltip = L("Create bounty"),
        layout = {},
        onClick = function()
          UI.PvPNewBounty(row.name)
        end,
      },
    }
  end
  if row.canRemove then
    remove = removeButton(row)
  end
  return edit, promote, remove
end

local function kosTable(page)
  local rows = ViewModel.IntelKosRows(ns.intel, {
    role = UI.Role(),
    actor = ns.Platform.GetIdentityKey(),
    formatDate = ns.Platform.FormatDate,
    canBounty = UI.PvPNewBounty ~= nil and ns.PermissionService.Can(UI.Role(), "pvp_mission_manage"),
  })
  local list = {}
  for _, row in ipairs(rows) do
    local editing = state.editing == editKey(row)
    local edit, promote, remove = kosActions(row)
    local categoryCell, reasonCell = row.categoryText, { text = row.reasonText }
    if editing then
      categoryCell = {
        widget = "dropdown",
        opts = {
          items = ViewModel.IntelCategoryChoices(),
          value = state.edit.category,
          onChange = function(value)
            state.edit.category = value
          end,
        },
      }
      reasonCell = {
        widget = "edit",
        opts = {
          text = state.edit.reason,
          maxLetters = ns.Constants.INTEL_REASON_MAX,
          onChange = function(text)
            state.edit.reason = text
          end,
          onEnter = function()
            saveEdit(row)
          end,
        },
      }
    end
    list[#list + 1] = {
      highlight = row.scope == "guild",
      cells = {
        scope = { widget = "badge", opts = { text = row.badge.text, color = row.badge.color, fixed = true } },
        name = { text = row.nameText },
        category = categoryCell,
        reason = reasonCell,
        by = { text = row.author, color = "dim" },
        added = { text = row.added, color = "muted" },
        edit = edit,
        promote = promote,
        remove = remove,
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "scope", title = "", width = 62, fit = true },
      { key = "name", title = L("Name"), weight = 2 },
      { key = "category", title = L("Category"), weight = 1.6 },
      { key = "reason", title = L("Reason"), weight = 3 },
      { key = "by", title = L("Added by"), weight = 1.4 },
      { key = "added", title = L("Date"), weight = 1.4 },
      { key = "edit", title = "", width = 30 },
      { key = "promote", title = "", width = 30 },
      { key = "remove", title = "", width = 30 },
    },
    rows = list,
    emptyText = L("The Kill on Sight lists are empty."),
  })
  Kit.Label(page, {
    text = L("Everyone can add to the guild list. Only who added a player, or an officer, can change or remove him."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

local function importCard(page)
  local card = Kit.Card(page, { title = L("Import names"), gap = 8 })
  Kit.Label(card, {
    text = L("One name per line, or separated by commas. Nobody already on a list is changed."),
    style = "small",
    color = "dim",
    wrap = true,
  })
  Kit.TextArea(card, {
    text = state.import.text,
    height = 90,
    onChange = function(text)
      state.import.text = text
    end,
  })
  local row = Kit.Row(card, { gap = 10, align = "center" })
  Kit.Dropdown(row, {
    items = {
      { value = "kos", text = L("To my Kill on Sight list") },
      { value = "ignore", text = L("To my Ignore list") },
    },
    value = state.import.target,
    layout = { width = 200 },
    onChange = function(value)
      state.import.target = value
    end,
  })
  Kit.Button(row, {
    text = L("Import"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      local lines = ns.intelCommands:ImportText(state.import.text, state.import.target)
      state.import.text = ""
      UI.Report(lines)
    end,
  })
  Kit.Button(row, {
    text = L("Import from Spy"),
    layout = { width = "auto" },
    onClick = function()
      UI.Report(ns.intelCommands:ImportSpy())
    end,
  })
end

local function kosView(page)
  addForm(page)
  kosTable(page)
  importCard(page)
end

-- ---------------------------------------------------------------------------------------------------------------
-- Ignored

local function ignoredView(page)
  local rows = ViewModel.IntelIgnoreRows(ns.intel:IgnoreList(), ns.Platform.FormatDate)
  local list = {}
  for _, row in ipairs(rows) do
    list[#list + 1] = {
      cells = {
        name = { text = row.nameText },
        added = { text = row.added, color = "muted" },
        remove = {
          widget = "iconButton",
          opts = {
            icon = "close",
            tooltip = L("Stop ignoring"),
            layout = {},
            onClick = function()
              UI.Report(ns.intelCommands:IgnoreRemove(row.name))
            end,
          },
        },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "name", title = L("Name"), weight = 3 },
      { key = "added", title = L("Date"), weight = 1.4 },
      { key = "remove", title = "", width = 30 },
    },
    rows = list,
    emptyText = L("Nobody is ignored."),
  })
  Kit.Label(page, {
    text = L("An ignored player gives no alerts, is not listed nearby and is never shared."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Statistics

local function statsColumns()
  return {
    { key = "kos", title = "", width = 62, fit = true },
    { key = "name", title = L("Name"), weight = 2, sortable = true },
    { key = "level", title = L("Level"), width = 50, align = "RIGHT", sortable = true, fit = true },
    { key = "class", title = L("Class"), weight = 1.2 },
    { key = "guild", title = L("Guild"), weight = 2, sortable = true },
    { key = "wins", title = L("Wins"), width = 50, align = "RIGHT", sortable = true, fit = true },
    { key = "losses", title = L("Losses"), width = 60, align = "RIGHT", sortable = true, fit = true },
    { key = "lastSeen", title = L("Last seen"), weight = 1.4, sortable = true, fit = true },
  }
end

local function drawStatsTable(region, data)
  local list = {}
  for _, row in ipairs(data.rows) do
    list[#list + 1] = {
      onClick = function(obj)
        openMenu(obj.frame, row)
      end,
      cells = {
        kos = kosCell(row.kos),
        name = { text = row.nameText, color = classColor(row.class) },
        level = row.levelText,
        class = { text = row.classText or "", color = "dim" },
        guild = { text = row.guildText, color = "dim" },
        wins = tostring(row.wins),
        losses = { text = tostring(row.losses), color = row.losses > 0 and "danger" or nil },
        lastSeen = { text = row.lastSeenText, color = "muted" },
      },
    }
  end
  Kit.Table(region, {
    columns = statsColumns(),
    fit = true,
    rows = list,
    sort = state.stats.sort,
    emptyText = L("Nobody matches."),
    onSort = function(key)
      state.stats.sort = ViewModel.NextSort(state.stats.sort, key, ViewModel.INTEL_FIRST_DESCENDING)
      UI.Redraw()
    end,
  })
  if data.shown < data.total then
    Kit.Label(region, {
      text = L("Showing the first %d of %d players."):format(data.shown, data.total),
      style = "small",
      color = "muted",
      wrap = true,
      layout = { gap = 10 },
    })
  end
end

local function statsData()
  local now = ns.Platform.ServerTime()
  local list = ns.intel:Stats(ViewModel.IntelStatsFilter(state.stats.filter), state.stats.sort)
  return ViewModel.IntelStatsRows(list, now, ns.Platform.FormatDate)
end

local function statsView(page)
  local honor
  local tracker = ns.pvpTracker
  if tracker and tracker.honorAvailable and ns.character then
    honor = ns.PvPService.Totals(ns.character.pvp).honor.total
  end
  Kit.StatGrid(page, { columns = 4, stats = ViewModel.IntelStatsSummary(ns.intel, honor) })

  local filter = state.stats.filter
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  local region
  Kit.EditBox(bar, {
    text = filter.text,
    placeholder = L("Search by name or guild"),
    layout = { weight = 1 },
    onChange = function(text, userInput)
      if userInput and region then
        filter.text = text
        UI.Refill(region, function(target)
          drawStatsTable(target, statsData())
        end)
      end
    end,
  })
  for _, choice in ipairs(ViewModel.IntelStatsFilters()) do
    Kit.Chip(bar, {
      text = choice.text,
      active = filter[choice.value] == true,
      layout = { width = "auto" },
      onToggle = function(active)
        filter[choice.value] = active
        UI.Redraw()
      end,
    })
  end
  Kit.Dropdown(bar, {
    items = ViewModel.IntelStatsCategoryChoices(),
    value = filter.category,
    layout = { width = 150 },
    onChange = function(value)
      filter.category = value
      UI.Redraw()
    end,
  })
  region = Kit.Stack(page, { gap = 0 })
  drawStatsTable(region, statsData())
end

-- ---------------------------------------------------------------------------------------------------------------
-- Report

local function reportView(page)
  local season = ns.pvpSeason and ns.pvpSeason:ActiveSeason() or nil
  local cards = ViewModel.IntelReportCards(
    ns.IntelReport.Session(ns.intel),
    season and ns.IntelReport.Season(ns.intel, season) or nil,
    ns.Platform.GetMapName
  )
  for _, card in ipairs(cards) do
    local box = Kit.Card(page, { title = card.title, gap = 10 })
    if #card.stats > 0 then
      Kit.StatGrid(box, { columns = 4, stats = card.stats })
    end
    for _, line in ipairs(card.lines) do
      Kit.Label(box, { text = ViewModel.Escape(line), color = "dim", wrap = true })
    end
  end
end

-- ---------------------------------------------------------------------------------------------------------------

local VIEWS = {
  nearby = nearbyView,
  hour = hourView,
  kos = kosView,
  ignored = ignoredView,
  stats = statsView,
  report = reportView,
}

-- Draws the sub-tab into `page`.
function UI.PvPIntel(page)
  if not ns.intel then
    Kit.EmptyState(page, {
      icon = "swords",
      title = L("Intel is not running"),
      hint = L("It starts when the addon is active for your guild."),
    })
    return
  end
  local notice = ViewModel.IntelNameplateNotice({
    enabled = settings().enabled,
    nameplates = ns.Platform.EnemyNameplatesEnabled(),
    inCombat = ns.Platform.IsInCombat(),
  })
  if notice then
    Kit.Banner(page, { kind = "warning", text = notice.text })
    if notice.canEnable then
      Kit.Button(page, {
        text = L("Turn on enemy nameplates"),
        layout = { width = "auto" },
        onClick = function()
          ns.Platform.EnableEnemyNameplates()
          UI.Redraw()
        end,
      })
    end
  end

  local views = ViewModel.IntelViews()
  state.view = ViewModel.PvPPick(views, state.view)
  local bar = Kit.Row(page, { gap = 12, align = "center" })
  Kit.Segmented(bar, {
    items = views,
    value = state.view,
    layout = { weight = 1 },
    onChange = function(value)
      state.view = value
      UI.Redraw()
    end,
  })
  Kit.Button(bar, {
    text = state.settingsOpen and L("Hide settings") or L("Settings"),
    layout = { width = "auto" },
    onClick = function()
      state.settingsOpen = not state.settingsOpen
      UI.Redraw()
    end,
  })
  if state.settingsOpen then
    drawSettings(page)
  end
  VIEWS[state.view](page)
end
