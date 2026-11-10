local _, ns = ...

-- The Ranks tab (Admin): which addon role each guild rank has (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, part D.7).
-- Functions that return tables of values, not frames, so every decision is tested here. A rank name or a member name
-- comes from the client and goes through ViewModel.Escape.
local ViewModel = ns.ViewModel
local L = ns.L
local Escape = ViewModel.Escape
local Model = ns.RankMapModel

-- How many names the preview lists before "and N more".
local PREVIEW_NAMES = 5

-- The roles a rank can be given, in order of authority: the dropdown of every row.
function ViewModel.RankRoleChoices()
  local choices = {}
  for _, role in ipairs(Model.ASSIGNABLE) do
    choices[#choices + 1] = { value = role, text = ViewModel.Word(role) }
  end
  return choices
end

local function previewText(changes)
  if #changes == 0 then
    return L("No member changes role.")
  end
  local parts = {}
  for index = 1, math.min(#changes, PREVIEW_NAMES) do
    local change = changes[index]
    parts[index] = ("%s (%s -> %s)"):format(Escape(change.name), ViewModel.Word(change.from), ViewModel.Word(change.to))
  end
  local text = table.concat(parts, ", ")
  if #changes > PREVIEW_NAMES then
    text = text .. " " .. L("and %d more"):format(#changes - PREVIEW_NAMES)
  end
  if #changes == 1 then
    return L("1 member changes role: %s"):format(text)
  end
  return L("%d members change role: %s"):format(#changes, text)
end

-- The drift banners: renamed ranks keep their role (information), added or removed ranks need a look (warning).
local function driftOf(rankMap, currentRanks)
  local drift = { renamed = {}, structural = false }
  for _, item in ipairs(Model.Drift(rankMap, currentRanks)) do
    if item.savedName and item.currentName then
      drift.renamed[#drift.renamed + 1] = L("Rank %d was renamed from %s to %s; its role is kept."):format(
        item.index,
        Escape(item.savedName),
        Escape(item.currentName)
      )
    else
      drift.structural = true
    end
  end
  if drift.structural then
    drift.structuralText = L("Guild ranks changed; review the mapping.")
  end
  return drift
end

-- args = { currentRanks = { [index] = name } (Platform.GetGuildRanks), rankMap = the saved map or nil,
--          draft = { [index] = { role } } being edited or nil, guildRoster (Names, Lookup), canManage (ranks_manage),
--          ownRole, ownRankIndex, formatDate }
-- Returns { rows = { { index, rankName, members, role, roleText, changed, readOnly, guildMaster } }, changes,
--           previewText, drift = { renamed = { text }, structural, structuralText }, noMap, canEdit, canSave, footer }.
function ViewModel.RankRows(args)
  local currentRanks = args.currentRanks or {}
  local rankMap = args.rankMap
  -- What every rank has today: the saved role, else the one its name gives. A row is `changed` against it.
  local baseline = Model.Draft(rankMap, currentRanks)
  local draft = Model.Draft(rankMap, currentRanks)
  for index, row in pairs(args.draft or {}) do
    if draft[index] and type(row) == "table" and Model.IsAssignable(row.role) then
      draft[index].role = row.role
    end
  end

  local counts = {}
  for _, name in ipairs(args.guildRoster:Names()) do
    local entry = args.guildRoster:Lookup(name)
    if entry and type(entry.rankIndex) == "number" then
      counts[entry.rankIndex] = (counts[entry.rankIndex] or 0) + 1
    end
  end

  local canEdit = args.canManage == true
  local indexes = {}
  for index in pairs(currentRanks) do
    if type(index) == "number" then
      indexes[#indexes + 1] = index
    end
  end
  table.sort(indexes)

  local rows, differs = {}, false
  for _, index in ipairs(indexes) do
    local guildMaster = index == ns.Constants.GUILD_MASTER_RANK_INDEX
    local row = {
      index = index,
      rankName = currentRanks[index],
      members = counts[index] or 0,
      guildMaster = guildMaster,
    }
    if guildMaster then
      row.role = "gm"
      row.readOnly = true
      row.changed = false
    else
      row.role = draft[index] and draft[index].role or "alter"
      row.changed = baseline[index] ~= nil and baseline[index].role ~= row.role
      -- A co-guild master can not touch the row of their own rank.
      row.readOnly = not canEdit or (args.ownRole == "cogm" and index == args.ownRankIndex)
      differs = differs or row.changed
    end
    row.roleText = ViewModel.Word(row.role)
    rows[#rows + 1] = row
  end

  local ranks = {}
  for index, row in pairs(draft) do
    ranks[index] = { role = row.role, name = row.name }
  end
  local changes = Model.Preview(args.guildRoster, rankMap, ranks)
  local drift = driftOf(rankMap, currentRanks)

  local footer
  if type(rankMap) == "table" and type(rankMap.by) == "string" and type(rankMap.updatedAt) == "number" then
    footer =
      L("Saved by %s, %s"):format(Escape(rankMap.by), args.formatDate and args.formatDate(rankMap.updatedAt) or "")
  end

  return {
    rows = rows,
    changes = changes,
    previewText = previewText(changes),
    drift = drift,
    noMap = rankMap == nil,
    canEdit = canEdit,
    -- The first save pins today's roles by rank index (nobody changes role); after that Save waits for a change, or
    -- for a renamed rank whose saved name should be updated.
    canSave = canEdit and (rankMap == nil or differs or #drift.renamed > 0 or drift.structural),
    footer = footer,
  }
end

-- Why a save of the mapping was refused (Comm:SetRankMap).
ViewModel.RANK_SAVE_ERRORS = ns.Locale.Table(function()
  return {
    no_guild = L("the guild is not known yet. Try again in a moment."),
    unknown_sender = L("your guild rank is not known yet. Try again in a moment."),
    forbidden = L("only the guild master and the co-guild master can change the mapping."),
    self_row = L("a co-guild master can not change the role of their own rank."),
    invalid = L("the mapping is not valid."),
    stale = L("a newer mapping arrived first. Review it and save again."),
  }
end)
