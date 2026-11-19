local _, ns = ...

-- PvP admin (docs/NAV_PERMISSIONS_PLAN.md 4.3): approvals, missions, season, prizes and deliveries, in the Admin group
-- of the sidebar for gm and cogm. It was the Admin sub-tab of the PvP tab; the helpers both tabs use are in
-- UI.PvPShared (UI/Tabs/PvP.lua).
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local DAY = 86400
local NEW_SEASON_DAYS = 30

local shared = UI.PvPShared
local service, fail, noSeason, zoneName, currentZone =
  shared.service, shared.fail, shared.noSeason, shared.zoneName, shared.currentZone
local rankingData = shared.rankingData

-- What the tab remembers while the session lasts.
local state = {
  admin = "approvals",
  resetTarget = nil,
  openClaim = nil,
  missionDraft = nil,
  seasonDraft = nil,
  prize = { tier = "1", gold = "", link = "", count = "1" },
  deliverySeason = nil,
  cloneFrom = nil,
}

-- Admin -> Season: reset the kill counters of a member (the old Admin card of the ranking).
local function killCounters(page)
  local rows = ViewModel.RankingTable((rankingData()), { limit = ns.Constants.PVP_RANKING_ROWS_MAX }).rows
  local list = {}
  for _, row in ipairs(rows) do
    if not row.mine then
      list[#list + 1] = { value = row.member, text = row.name }
    end
  end
  if #list == 0 then
    return
  end
  table.sort(list, function(a, b)
    return a.value < b.value
  end)
  local card = Kit.Card(page, { title = L("Kill counters"), gap = 10 })
  Kit.Label(card, {
    text = L("Resets the counters of a member on every client. It does not touch the season points."),
    style = "small",
    color = "dim",
    wrap = true,
  })
  local row = Kit.Row(card, { gap = 12, align = "center" })
  Kit.Dropdown(row, {
    items = list,
    value = state.resetTarget,
    placeholder = L("Member"),
    layout = { weight = 1 },
    onChange = function(value)
      state.resetTarget = value
      UI.Redraw()
    end,
  })
  local key = "pvpreset:" .. tostring(state.resetTarget)
  local armed = UI.IsArmed(key)
  Kit.Button(row, {
    text = armed and L("Confirm: reset") or L("Reset PvP counters"),
    variant = armed and "dangerSolid" or "danger",
    layout = { width = "auto" },
    onClick = function()
      if not state.resetTarget then
        UI.Notify("warning", L("Pick a member first."))
        return
      end
      if not armed then
        UI.Arm(key)
        return
      end
      UI.Disarm()
      if not ns.comm then
        UI.Notify("danger", L("Not reset: ") .. L("Not available"))
        return
      end
      local target = state.resetTarget
      state.resetTarget = nil
      local ok, outcome, sent = ns.comm:ResetPvP(target)
      if not ok then
        UI.Notify("danger", L("Not reset: ") .. (ViewModel.PVP_RESET_ERRORS[outcome] or tostring(outcome)))
        return
      end
      UI.Notify(
        sent and "success" or "warning",
        L("PvP counters of %s reset (revision %d)%s."):format(
          ViewModel.Escape(target),
          outcome,
          sent and L(", told to the guild") or L(", NOT sent")
        )
      )
    end,
  })
end

local function canManage()
  local svc = service()
  return svc ~= nil and svc:CanPvP("pvp_season_manage")
end

-- -------------------------------------------------------------------------------------------------------------
-- Admin: approvals

local function decide(action, claimId)
  local svc = service()
  local record, reason = svc[action](svc, claimId)
  if not record then
    fail(reason)
    return
  end
  if state.openClaim == claimId then
    state.openClaim = nil
  end
  UI.Notify(
    "success",
    action == "Approve" and L("Claim approved. The points are in the ranking.") or L("Claim rejected.")
  )
end

local function evidenceTable(box, row)
  local rows = {}
  for _, entry in ipairs(row.evidence) do
    rows[#rows + 1] = {
      cells = {
        time = { text = entry.time, color = "muted" },
        victim = entry.victim,
        zone = entry.zone,
        info = { text = entry.info, color = entry.unknown and "warning" or "dim" },
      },
    }
  end
  Kit.Table(box, {
    columns = {
      { key = "time", title = L("Time"), width = 60, fit = true },
      { key = "victim", title = L("Victim"), weight = 1.5 },
      { key = "zone", title = L("Zone"), weight = 1.5 },
      { key = "info", title = L("Class and race"), weight = 1.5 },
    },
    fit = true,
    rows = rows,
    layout = { gap = 8 },
  })
  if row.more then
    Kit.Label(box, { text = row.more, style = "small", color = "muted" })
  end
end

local function approvals(page)
  local svc = service()
  local rows = ViewModel.PvPClaimRows(svc:Queue(), {
    missionOf = function(id)
      return svc:Mission(id)
    end,
    now = ns.Platform.ServerTime(),
    formatClock = ns.Platform.FormatClock,
    zoneName = zoneName,
  })
  local rejected = ViewModel.PvPClaimRows(svc:Rejected(), {
    missionOf = function(id)
      return svc:Mission(id)
    end,
    now = ns.Platform.ServerTime(),
    formatClock = ns.Platform.FormatClock,
    zoneName = zoneName,
  })
  if #rows == 0 and #rejected == 0 then
    Kit.EmptyState(page, {
      icon = "check-circle",
      title = L("No claims waiting"),
      hint = L("Claims show up here when the members complete a mission."),
    })
  end
  if #rows > 0 then
    local box = Kit.Card(page, { gap = 14 })
    for _, row in ipairs(rows) do
      local line = Kit.Row(box, { gap = 8, align = "center" })
      local text = Kit.Stack(line, { gap = 2, layout = { weight = 1 } })
      Kit.Label(text, { text = ("%s \194\183 %s  %s"):format(row.who, row.mission, row.points), wrap = true })
      Kit.Label(text, {
        text = row.summary .. " \194\183 " .. row.when,
        style = "small",
        color = "muted",
        wrap = true,
      })
      local open = state.openClaim == row.id
      Kit.Button(line, {
        text = open and L("Hide evidence") or L("View evidence"),
        variant = "ghost",
        layout = { width = "auto" },
        onClick = function()
          state.openClaim = (not open) and row.id or nil
          UI.Redraw()
        end,
      })
      Kit.Button(line, {
        text = L("Reject"),
        variant = "danger",
        layout = { width = "auto" },
        onClick = function()
          decide("Reject", row.id)
        end,
      })
      Kit.Button(line, {
        text = L("Approve"),
        variant = "primary",
        layout = { width = "auto" },
        onClick = function()
          decide("Approve", row.id)
        end,
      })
      if open then
        if row.note then
          Kit.Label(box, { text = L("Note: %s"):format(row.note), style = "small", color = "dim", wrap = true })
        end
        if #row.evidence > 0 then
          evidenceTable(box, row)
        end
      end
    end
  end
  if #rejected > 0 then
    local box = Kit.Card(page, { title = L("Rejected claims"), gap = 10 })
    for _, row in ipairs(rejected) do
      local line = Kit.Row(box, { gap = 8, align = "center" })
      Kit.Label(line, {
        text = ("%s \194\183 %s"):format(row.who, row.mission),
        color = "dim",
        layout = { weight = 1 },
      })
      Kit.Button(line, {
        text = L("Approve"),
        layout = { width = "auto" },
        onClick = function()
          decide("Approve", row.id)
        end,
      })
    end
  end
  Kit.Label(page, {
    text = L("The evidence is the kills the player's addon recorded.") .. " " .. L(
      "You decide whether kills without a known class or race count."
    ) .. " " .. L("Approving the same claim twice adds it only once."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: progress

-- How far the members say they are in each mission, closest first (what their clients last told this one).
local function progressAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local blocks = ViewModel.PvPProgressBlocks(
    svc:ProgressBoard(season.id),
    svc:Missions(season.id),
    { now = ns.Platform.ServerTime() }
  )
  if #blocks == 0 then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("No progress reported yet"),
      hint = L("Members share how far they are while they play; it shows here when an approver is online."),
    })
    return
  end
  for _, block in ipairs(blocks) do
    local card = Kit.Card(page, { title = block.title, gap = 6 })
    local rows = {}
    for _, row in ipairs(block.rows) do
      rows[#rows + 1] = {
        cells = {
          player = row.player,
          progress = row.text,
          status = { widget = "badge", opts = { text = row.status.text, color = row.status.color } },
          updated = row.updated,
        },
      }
    end
    Kit.Table(card, {
      columns = {
        { key = "player", title = L("Player"), weight = 2 },
        { key = "progress", title = L("Progress"), width = 80, fit = true },
        { key = "status", title = L("Status"), width = 110, fit = true },
        { key = "updated", title = L("Updated"), width = 90, fit = true },
      },
      fit = true,
      rows = rows,
    })
  end
  Kit.Label(page, {
    text = L("Reported by each member's addon, not checked: the claim and its evidence are what you approve."),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: missions

local function fieldRow(parent, label, build, layout)
  local field = Kit.Field(parent, { label = label, layout = layout or { weight = 1 } })
  build(field)
  return field
end

local function saveMission()
  local svc = service()
  local fields, reason = ViewModel.PvPMissionFields(state.missionDraft)
  if not fields then
    fail(reason)
    return
  end
  local mission, why = svc:UpsertMission(fields)
  if not mission then
    fail(why)
    return
  end
  state.missionDraft = nil
  UI.Notify("success", L("Mission saved."))
end

-- Toggles a zone of the constant list in the draft's zone text.
local function toggleZone(draft, mapId, on)
  local zones = ViewModel.PvPParseZones(draft.zones) or {}
  local kept = {}
  for _, id in ipairs(zones) do
    if id ~= mapId then
      kept[#kept + 1] = id
    end
  end
  if on then
    kept[#kept + 1] = mapId
  end
  draft.zones = table.concat(kept, ", ")
end

-- Adds a zone to the draft's zone text; a zone already there stays once. Past PVP_MISSION_ZONES_MAX the zone is
-- refused with a warning. Returns true when the zone is in the draft.
local function addZone(draft, mapId)
  local zones = ViewModel.PvPParseZones(draft.zones) or {}
  for _, id in ipairs(zones) do
    if id == mapId then
      return true
    end
  end
  if #zones >= ns.Constants.PVP_MISSION_ZONES_MAX then
    UI.Notify("warning", L("At most 5 zones."))
    return false
  end
  toggleZone(draft, mapId, true)
  return true
end

-- The zone picker (docs/PVP_DUELS_ZONES_PLAN.md, 1.5): a dropdown of the whole world, the continents and every zone,
-- then the chosen zones as chips that can be taken out again. The dropdown keeps no choice of its own, so its value
-- matches no item and it always shows its placeholder.
local NO_CHOICE = ""
local WHOLE_WORLD = "world"

local function zonesField(parent, draft)
  local field = Kit.Field(parent, { label = L("Zones (optional)") })
  Kit.Dropdown(field, {
    items = ViewModel.PvPZonePickerItems(),
    value = NO_CHOICE,
    placeholder = L("Add a zone"),
    onChange = function(value)
      if value == WHOLE_WORLD then
        draft.zones = ""
      else
        addZone(draft, value)
      end
      UI.Redraw()
    end,
  })
  local selected = ViewModel.PvPParseZones(draft.zones) or {}
  if #selected == 0 then
    Kit.Label(field, { text = L("Whole world"), style = "small", color = "dim" })
  else
    local flow = Kit.Flow(field, { gap = 6, rowGap = 6 })
    for _, mapId in ipairs(selected) do
      Kit.Chip(flow, {
        text = zoneName(mapId) or tostring(mapId),
        active = true,
        onToggle = function(active)
          if not active then
            toggleZone(draft, mapId, false)
            UI.Redraw()
          end
        end,
      })
    end
  end
  local row = Kit.Row(field, { gap = 8 })
  if type(ns.Platform.GetPlayerMapId) == "function" then
    Kit.Button(row, {
      text = L("Add current zone"),
      layout = { width = "auto" },
      onClick = function()
        local mapId = currentZone()
        if not mapId then
          UI.Notify("warning", L("The current zone could not be read."))
          return
        end
        if addZone(draft, mapId) then
          UI.Redraw()
        end
      end,
    })
  end
end

local function dateField(parent, label, value, onChange)
  local field = Kit.Field(parent, { label = label, layout = { weight = 1 } })
  Kit.DateField(field, UI.DateFieldOptions(value, onChange))
end

-- The chips of a token list of the draft (battlegrounds, enemy classes, enemy races): `choices` = { { value, text } }.
local function tokenChips(parent, label, draft, field, choices)
  local box = Kit.Field(parent, { label = label })
  local flow = Kit.Flow(box, { gap = 6, rowGap = 6 })
  local chosen = {}
  for _, token in ipairs(draft[field] or {}) do
    chosen[token] = true
  end
  for _, choice in ipairs(choices) do
    Kit.Chip(flow, {
      text = choice.text,
      active = chosen[choice.value] == true,
      onToggle = function(active)
        ViewModel.PvPToggleToken(draft, field, choice.value, active)
        UI.Redraw()
      end,
    })
  end
end

-- The optional fields of a mission, under one button so the simple form stays as it is (docs/
-- ANNOUNCEMENTS_MODULES_PVP_PLAN.md, C.6).
local function advancedSection(card, draft)
  local open = draft.advancedOpen
  if open == nil then
    open = ViewModel.PvPHasAdvanced(draft)
  end
  Kit.Button(card, {
    text = open and L("Hide advanced options") or L("Advanced options"),
    variant = "ghost",
    layout = { width = "auto" },
    onClick = function()
      draft.advancedOpen = not open
      UI.Redraw()
    end,
  })
  if not open then
    return
  end
  local kind = draft.kind
  local kills = kind == "kills" or kind == "kos"
  if kind == "bg_wins" or kind == "bg_played" then
    tokenChips(card, L("Battlegrounds (none = any)"), draft, "bgs", ViewModel.PvPBattlegroundChoices())
  end
  if kind == "duel_wins" then
    -- A duel mission takes the per-opponent daily cap and no other kill filter (no class, race, group or place).
    fieldRow(card, L("Max duels won against one opponent per day"), function(field)
      Kit.EditBox(field, {
        text = draft.victimCap,
        placeholder = L("Default: %d, 0 = no cap"):format(ns.Constants.PVP_VICTIM_DAILY_CAP),
        numeric = true,
        maxLetters = 2,
        onChange = function(text)
          draft.victimCap = text
        end,
        onEnter = UI.Redraw,
      })
    end, { weight = 1 })
  end
  if kills then
    local faction = type(ns.Platform.GetPlayerFaction) == "function" and ns.Platform.GetPlayerFaction() or nil
    local classes, races = ViewModel.PvPEnemyChoices(faction)
    tokenChips(card, L("Victim classes (none = any)"), draft, "victimClasses", classes)
    tokenChips(card, L("Victim races (none = any)"), draft, "victimRaces", races)
    local limits = Kit.Row(card, { gap = 16 })
    fieldRow(limits, L("Max kills of one victim per day"), function(field)
      Kit.EditBox(field, {
        text = draft.victimCap,
        placeholder = L("Default: %d, 0 = no cap"):format(ns.Constants.PVP_VICTIM_DAILY_CAP),
        numeric = true,
        maxLetters = 2,
        onChange = function(text)
          draft.victimCap = text
        end,
        onEnter = UI.Redraw,
      })
    end)
    fieldRow(limits, L("Guildmates in the group (minimum)"), function(field)
      Kit.EditBox(field, {
        text = draft.minGuild,
        placeholder = L("0 = off"),
        numeric = true,
        maxLetters = 2,
        onChange = function(text)
          draft.minGuild = text
        end,
        onEnter = UI.Redraw,
      })
    end)
  end
  if kind ~= "manual" then
    Kit.Switch(card, {
      label = L("Only inside a time window"),
      description = L("A weekend event: only what happens between the two dates counts."),
      checked = draft.windowOn == true,
      onChange = function(checked)
        draft.windowOn = checked
        UI.Redraw()
      end,
    })
    if draft.windowOn then
      local dates = Kit.Row(card, { gap = 16 })
      dateField(dates, L("Window start"), draft.windowStart, function(timestamp)
        draft.windowStart = timestamp
      end)
      dateField(dates, L("Window end"), draft.windowEnd, function(timestamp)
        draft.windowEnd = timestamp
      end)
    end
  end
  fieldRow(card, L("Max completions per member in the season"), function(field)
    Kit.EditBox(field, {
      text = draft.maxCompletions,
      placeholder = L("0 = no limit"),
      numeric = true,
      maxLetters = 3,
      onChange = function(text)
        draft.maxCompletions = text
      end,
      onEnter = UI.Redraw,
    })
  end, { weight = 1 })
  if kind ~= "manual" then
    Kit.Switch(card, {
      label = L("Claim automatically"),
      description = L("When the goal is reached the claim is sent by itself and the member gets a notice."),
      checked = draft.autoClaim == true,
      onChange = function(checked)
        draft.autoClaim = checked
        UI.Redraw()
      end,
    })
  end
  local fields = ViewModel.PvPMissionFields(draft)
  if fields and ns.PvPSeasonModel.UsesNewGoalFeatures(fields.goal) then
    Kit.Label(card, {
      text = L("Members on an older addon version will not see these options: ask them to update."),
      style = "small",
      color = "warning",
      wrap = true,
    })
  end
end

local function missionForm(page)
  local draft = state.missionDraft
  local tracker = ns.pvpMissions
  local title = draft.id and L("Edit mission") or L("New mission")
  local card = Kit.Card(page, { title = title, gap = 12 })
  if not draft.id then
    fieldRow(card, L("Start from a template"), function(field)
      Kit.Dropdown(field, {
        items = ViewModel.PvPPresetChoices(),
        placeholder = L("Pick a template"),
        onChange = function(value)
          ViewModel.PvPApplyPreset(draft, value)
          UI.Redraw()
        end,
      })
    end, { weight = 1 })
  end
  fieldRow(card, L("Title"), function(field)
    Kit.EditBox(field, {
      text = draft.title,
      maxLetters = ns.Constants.PVP_MISSION_TITLE_MAX,
      onChange = function(text)
        draft.title = text
      end,
    })
  end, { weight = 1 })
  fieldRow(card, L("Description"), function(field)
    Kit.EditBox(field, {
      text = draft.desc,
      maxLetters = ns.Constants.PVP_MISSION_DESC_MAX,
      onChange = function(text)
        draft.desc = text
      end,
    })
  end, { weight = 1 })

  local goal = Kit.Row(card, { gap = 16 })
  fieldRow(goal, L("Goal"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPGoalChoices(tracker and tracker:Availability() or nil),
      value = draft.kind,
      onChange = function(value)
        draft.kind = value
        UI.Redraw()
      end,
    })
  end)
  if draft.kind ~= "manual" then
    fieldRow(goal, L("Count"), function(field)
      Kit.EditBox(field, {
        text = draft.count,
        numeric = true,
        maxLetters = 3,
        onChange = function(text)
          draft.count = text
        end,
      })
    end)
  end
  fieldRow(goal, L("Points"), function(field)
    Kit.EditBox(field, {
      text = draft.points,
      numeric = true,
      maxLetters = 4,
      onChange = function(text)
        draft.points = text
      end,
    })
  end)

  if draft.kind ~= "manual" then
    zonesField(card, draft)
  end
  if draft.kind == "kos" then
    fieldRow(card, L("Target (optional)"), function(field)
      Kit.EditBox(field, {
        text = draft.target,
        placeholder = L("Any player on the guild Kill on Sight list"),
        maxLetters = ns.Constants.INTEL_NAME_MAX,
        onChange = function(text)
          draft.target = text
        end,
      })
    end, { weight = 1 })
  end
  if draft.kind == "kills" or draft.kind == "kos" then
    local where = Kit.Row(card, { gap = 16 })
    fieldRow(where, L("Place"), function(field)
      Kit.Dropdown(field, {
        items = ViewModel.PvPPlaceChoices(),
        value = draft.place,
        onChange = function(value)
          draft.place = value
        end,
      })
    end)
    if draft.kind == "kills" then
      fieldRow(where, L("Distinct by"), function(field)
        Kit.Dropdown(field, {
          items = ViewModel.PvPDistinctChoices(),
          value = draft.distinct,
          onChange = function(value)
            draft.distinct = value
          end,
        })
      end)
    end
  end

  if draft.kind == "duel_wins" then
    fieldRow(card, L("Distinct by"), function(field)
      Kit.Dropdown(field, {
        items = ViewModel.PvPDuelDistinctChoices(),
        value = draft.distinct == "name" and "name" or "none",
        onChange = function(value)
          draft.distinct = value
        end,
      })
    end, { weight = 1 })
  end

  local when = Kit.Row(card, { gap = 16 })
  fieldRow(when, L("Repeats"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPRepeatChoices(),
      value = draft.repeatKind,
      onChange = function(value)
        draft.repeatKind = value
      end,
    })
  end)
  fieldRow(when, L("Times per player"), function(field)
    Kit.EditBox(field, {
      text = draft.perPlayer,
      numeric = true,
      maxLetters = 2,
      onChange = function(text)
        draft.perPlayer = text
      end,
    })
  end)
  fieldRow(when, L("Status"), function(field)
    Kit.Dropdown(field, {
      items = ViewModel.PvPActiveChoices(),
      value = draft.active,
      onChange = function(value)
        draft.active = value
      end,
    })
  end)

  advancedSection(card, draft)
  local fields = ViewModel.PvPMissionFields(draft)
  Kit.Label(card, {
    text = fields and ViewModel.PvPMissionSummary(fields, { zoneName = zoneName, dateText = ViewModel.DateText })
      or L("Fill in the numbers to see what this mission counts."),
    style = "small",
    color = "muted",
    wrap = true,
  })

  local buttons = Kit.Row(card, { gap = 10, layout = { gap = 14 } })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  Kit.Button(buttons, {
    text = L("Cancel"),
    variant = "ghost",
    layout = { width = "auto" },
    onClick = function()
      state.missionDraft = nil
      UI.Redraw()
    end,
  })
  Kit.Button(buttons, {
    text = draft.id and L("Save mission") or L("Create mission"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = saveMission,
  })
end

local function cloneMissions(seasonId)
  local svc = service()
  local season = svc:ActiveSeason()
  local copied = 0
  for _, mission in ipairs(svc:Missions(seasonId, true)) do
    local zones = {}
    for index, mapId in ipairs(mission.goal.zones or {}) do
      zones[index] = mapId
    end
    local goal = {
      kind = mission.goal.kind,
      count = mission.goal.count,
      zones = zones,
      place = mission.goal.place,
      distinct = mission.goal.distinct,
      target = mission.goal.target,
    }
    local clone, reason = svc:UpsertMission({
      title = mission.title,
      desc = mission.desc,
      points = mission.points,
      goal = goal,
      repeatKind = mission.repeatKind,
      perPlayer = mission.perPlayer,
      active = mission.active,
    })
    if not clone then
      fail(reason)
      return
    end
    copied = copied + 1
  end
  state.cloneFrom = nil
  UI.Notify(
    "success",
    L("Copied %d mission(s) into '%s'."):format(copied, ViewModel.Escape(season and season.name or "?"))
  )
end

-- Opens the admin Missions page on a new bounty for `name` (a player of the guild Kill on Sight list). Used by the
-- Intel sub-tab.
function UI.PvPNewBounty(name)
  local draft = ViewModel.PvPMissionDraft(nil)
  draft.kind = "kos"
  draft.target = name or ""
  draft.count = "1"
  draft.title = name and L("Bounty: %s"):format(name):sub(1, ns.Constants.PVP_MISSION_TITLE_MAX) or ""
  state.missionDraft = draft
  state.admin = "missions"
  UI.OpenTab("pvpadmin")
end

local function missionsAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local bar = Kit.Row(page, { gap = 10, align = "center" })
  Kit.Button(bar, {
    text = L("New mission"),
    icon = "plus",
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      state.missionDraft = ViewModel.PvPMissionDraft(nil)
      UI.Redraw()
    end,
  })
  local sources = ViewModel.PvPCloneChoices(svc:Seasons(), season.id, function(seasonId)
    return #svc:Missions(seasonId, true)
  end)
  if #sources > 0 then
    Kit.Dropdown(bar, {
      items = sources,
      value = state.cloneFrom,
      placeholder = L("Copy from another season"),
      layout = { width = 240 },
      onChange = function(value)
        state.cloneFrom = value
        cloneMissions(value)
      end,
    })
  end

  local missions = svc:Missions(season.id, true)
  local rows = {}
  for _, row in ipairs(ViewModel.PvPMissionRows(missions, zoneName)) do
    rows[#rows + 1] = {
      cells = {
        title = row.title,
        criteria = { text = row.criteria, color = "dim" },
        points = row.points,
        status = { widget = "badge", opts = { text = row.status, color = row.token } },
        edit = {
          widget = "button",
          opts = {
            text = L("Edit"),
            variant = "ghost",
            onClick = function()
              state.missionDraft = ViewModel.PvPMissionDraft(svc:Mission(row.id))
              UI.Redraw()
            end,
          },
        },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "title", title = L("Mission"), weight = 1.4 },
      { key = "criteria", title = L("Criteria"), weight = 2.4 },
      { key = "points", title = L("Points"), width = 60, align = "RIGHT", fit = true },
      { key = "status", title = L("Status"), width = 90, fit = true },
      { key = "edit", title = "", width = 70 },
    },
    fit = true,
    rows = rows,
    emptyText = L("There are no missions yet."),
  })
  if state.missionDraft then
    missionForm(page)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: season

local function seasonDraft(season)
  local draft = state.seasonDraft
  local key = season and season.id or false
  if draft and draft.key == key then
    return draft
  end
  local now = ns.Platform.ServerTime()
  draft = {
    key = key,
    name = season and season.name or "",
    startsAt = season and season.startsAt or now,
    endsAt = season and season.endsAt or (now + NEW_SEASON_DAYS * DAY),
  }
  state.seasonDraft = draft
  return draft
end

local function saveSeason(season, draft)
  local svc = service()
  local fields = { name = draft.name, startsAt = draft.startsAt, endsAt = draft.endsAt }
  local record, reason
  if season then
    record, reason = svc:EditSeason(season.id, fields)
  else
    record, reason = svc:CreateSeason(fields)
  end
  if not record then
    fail(reason)
    return
  end
  state.seasonDraft = nil
  UI.Notify("success", L("Season saved."))
end

local function closeSeason(season)
  local svc = service()
  local final, expired = svc:CloseSeason(season.id)
  UI.Disarm()
  if not final then
    fail(expired)
    return
  end
  state.seasonDraft = nil
  state.deliverySeason = final.seasonId
  UI.Notify(
    "success",
    L("Season closed: %d player(s) ranked, %d claim(s) expired."):format(#final.standings, expired or 0)
  )
end

local function seasonAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  local draft = seasonDraft(season)
  local card = Kit.Card(page, { title = season and L("Active season") or L("New season"), gap = 12 })
  local name = Kit.Field(card, { label = L("Name") })
  Kit.EditBox(name, {
    text = draft.name,
    maxLetters = ns.Constants.PVP_SEASON_NAME_MAX,
    onChange = function(text)
      draft.name = text
    end,
  })
  local dates = Kit.Row(card, { gap = 16 })
  dateField(dates, L("Start"), draft.startsAt, function(timestamp)
    draft.startsAt = timestamp
  end)
  dateField(dates, L("End"), draft.endsAt, function(timestamp)
    draft.endsAt = timestamp
  end)
  Kit.Label(card, {
    text = L(
      "The end date only stops new claims. Close the season with the button when you have reviewed the pending ones."
    ),
    style = "small",
    color = "dim",
    wrap = true,
  })
  local buttons = Kit.Row(card, { gap = 10, align = "center" })
  Kit.Button(buttons, {
    text = season and L("Save") or L("Create season"),
    variant = "primary",
    layout = { width = "auto" },
    onClick = function()
      saveSeason(season, draft)
    end,
  })
  Kit.Label(buttons, { text = "", layout = { weight = 1 } })
  if season then
    local key = "pvpclose:" .. season.id
    local armed = UI.IsArmed(key)
    Kit.Button(buttons, {
      text = armed and L("Confirm: close and freeze the ranking") or L("Close season"),
      variant = armed and "dangerSolid" or "danger",
      layout = { width = "auto" },
      onClick = function()
        if not armed then
          UI.Arm(key)
          return
        end
        closeSeason(season)
      end,
    })
    if armed then
      Kit.Label(card, {
        text = ViewModel.PvPCloseWarning(#svc:Queue()),
        style = "small",
        color = "warning",
        wrap = true,
      })
    end
  end
  if ns.comm and ns.PermissionService.Can(UI.Role(), "moderate") then
    killCounters(page)
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: prizes

local function savePrizes(seasonId, tiers)
  local record, reason = service():SetPrizes(seasonId, tiers)
  if not record then
    fail(reason)
    return false
  end
  return true
end

local function addReward(season, tiers, reward, reason)
  if not reward then
    fail(reason)
    return
  end
  local updated, why = ViewModel.PvPAddReward(tiers, state.prize.tier, reward)
  if not updated then
    fail(why)
    return
  end
  if savePrizes(season.id, updated) then
    state.prize.gold, state.prize.link = "", ""
    UI.Redraw()
  end
end

local function prizesAdmin(page)
  local svc = service()
  local season = svc:ActiveSeason()
  if not season then
    noSeason(page)
    return
  end
  local prizes = svc:Prizes(season.id)
  local tiers = prizes and prizes.tiers or {}
  local card = Kit.Card(page, { gap = 12 })
  for _, row in ipairs(ViewModel.PvPPrizeRows(tiers)) do
    local line = Kit.Row(card, { gap = 12 })
    Kit.Label(line, { text = row.label, color = row.token, layout = { width = 64 } })
    local chips = Kit.Flow(line, { gap = 6, rowGap = 6, layout = { weight = 1 } })
    if #row.rewards == 0 then
      Kit.Label(chips, { text = "-", color = "muted" })
    end
    for index, reward in ipairs(row.rewards) do
      Kit.Chip(chips, {
        text = ViewModel.PvPRewardText(reward),
        active = true,
        tooltip = L("Click to remove"),
        onToggle = function()
          savePrizes(season.id, ViewModel.PvPRemoveReward(tiers, row.tier, index))
          UI.Redraw()
        end,
      })
    end
  end

  local add = Kit.Card(page, { title = L("Add a reward"), gap = 10 })
  local tierRow = Kit.Row(add, { gap = 12, align = "center" })
  Kit.Label(tierRow, { text = L("Tier"), color = "dim", layout = { width = 64 } })
  local tierItems = {}
  for _, row in ipairs(ViewModel.PvPPrizeRows(tiers)) do
    tierItems[#tierItems + 1] = { value = row.tier, text = row.label }
  end
  Kit.Dropdown(tierRow, {
    items = tierItems,
    value = state.prize.tier,
    layout = { width = 140 },
    onChange = function(value)
      state.prize.tier = value
      UI.Redraw()
    end,
  })
  local gold = Kit.Row(add, { gap = 8 })
  Kit.EditBox(gold, {
    text = state.prize.gold,
    numeric = true,
    placeholder = L("Gold amount"),
    maxLetters = 6,
    layout = { weight = 1 },
    onChange = function(text)
      state.prize.gold = text
    end,
  })
  Kit.Button(gold, {
    text = L("Add gold"),
    icon = "plus",
    layout = { width = "auto" },
    onClick = function()
      addReward(season, tiers, ViewModel.PvPGoldReward(state.prize.gold))
    end,
  })
  local item = Kit.Row(add, { gap = 8 })
  Kit.EditBox(item, {
    text = state.prize.link,
    placeholder = L("Paste an item link"),
    layout = { weight = 1 },
    onChange = function(text)
      state.prize.link = text
    end,
  })
  Kit.EditBox(item, {
    text = state.prize.count,
    numeric = true,
    placeholder = L("Count"),
    maxLetters = 3,
    layout = { width = 70 },
    onChange = function(text)
      state.prize.count = text
    end,
  })
  Kit.Button(item, {
    text = L("Add item"),
    icon = "plus",
    layout = { width = "auto" },
    onClick = function()
      addReward(season, tiers, ViewModel.PvPItemReward(state.prize.link, state.prize.count))
    end,
  })
  Kit.Label(page, {
    text = L("Every player in a tier gets the full prize. To add an item, paste its link.") .. " " .. L(
      "The addon does not send gold or mail."
    ),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin: deliveries

local function deliveriesAdmin(page)
  local svc = service()
  local finals = svc:Finals()
  if #finals == 0 then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("No closed seasons yet"),
      hint = L("When a season closes, the prizes to hand over are listed here."),
    })
    return
  end
  local chosen = finals[1]
  for _, final in ipairs(finals) do
    if final.seasonId == state.deliverySeason then
      chosen = final
    end
  end
  if #finals > 1 then
    Kit.Dropdown(page, {
      items = ViewModel.PvPFinalChoices(finals),
      value = chosen.seasonId,
      layout = { width = 260 },
      onChange = function(value)
        state.deliverySeason = value
        UI.Redraw()
      end,
    })
  end
  local data = ViewModel.PvPDeliveryRows(svc:Deliveries(chosen.seasonId))
  Kit.Label(page, {
    text = chosen.name .. " \194\183 " .. ViewModel.PvPDeliveryHeader(chosen, data.delivered, data.total),
    color = "dim",
    wrap = true,
  })
  local rows = {}
  for _, row in ipairs(data.rows) do
    rows[#rows + 1] = {
      cells = {
        position = { text = tostring(row.pos), color = row.positionToken },
        player = row.player,
        tier = { widget = "badge", opts = { text = row.tier.text, color = row.tier.color } },
        reward = row.reward,
        status = row.delivered and { text = row.delivered, color = "success" } or {
          widget = "button",
          opts = {
            text = L("Mark delivered"),
            onClick = function()
              local record, reason = svc:MarkDelivery(chosen.seasonId, row.raw, true)
              if not record then
                fail(reason)
                return
              end
              UI.Redraw()
            end,
          },
        },
      },
    }
  end
  Kit.Table(page, {
    columns = {
      { key = "position", title = "#", width = 36, align = "RIGHT", fit = true },
      { key = "player", title = L("Player"), weight = 1.5 },
      { key = "tier", title = L("Tier"), width = 80, fit = true },
      { key = "reward", title = L("Reward"), weight = 2 },
      { key = "status", title = L("Status"), weight = 2 },
    },
    fit = true,
    rows = rows,
    emptyText = L("Nobody won a prize."),
  })
  Kit.Label(page, {
    text = L(
      "The addon does not send gold or mail: hand it over in game and mark it here. It stays in the season history."
    ),
    style = "small",
    color = "muted",
    wrap = true,
  })
end

-- ---------------------------------------------------------------------------------------------------------------
-- Admin

local function adminView(page)
  local svc = service()
  local manage = canManage()
  local sections = ViewModel.PvPAdminSections({ manage = manage, pending = #svc:Queue() })
  state.admin = ViewModel.PvPPick(sections, state.admin)
  Kit.Segmented(page, {
    items = sections,
    value = state.admin,
    layout = { width = "auto" },
    onChange = function(value)
      state.admin = value
      UI.Redraw()
    end,
  })
  if state.admin == "progress" then
    progressAdmin(page)
  elseif state.admin == "missions" then
    missionsAdmin(page)
  elseif state.admin == "season" then
    seasonAdmin(page)
  elseif state.admin == "prizes" then
    prizesAdmin(page)
  elseif state.admin == "deliveries" then
    deliveriesAdmin(page)
  else
    approvals(page)
  end
end

UI.Register("pvpadmin", function(page)
  Kit.PageHeader(page, {
    title = "PvP",
    description = L("Approve claims and manage the season, its missions and the prizes."),
  })
  if service() == nil or not ns.PermissionService.Can(UI.Role(), "pvp_admin") then
    return
  end
  adminView(page)
end)
