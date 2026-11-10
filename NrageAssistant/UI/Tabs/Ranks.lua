local _, ns = ...

-- Ranks (Admin): which addon role each guild rank has. The roles follow the rank INDEX, so renaming a rank in the game
-- keeps the role of its members (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, part D). Every Admin rank reads the mapping;
-- the guild master and the co-guild master edit it (a co-guild master not the row of their own rank). Until the first
-- save the roles come from the rank names as always; the first save pins them to the rank indexes.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- The roles being edited, { [index] = { role } }, or nil while nothing was touched. Kept while the session lasts.
local state = { draft = nil }

local function view()
  local ownName, ownIndex = ns.Platform.GetOwnGuildRank()
  local role = UI.Role()
  return ViewModel.RankRows({
    currentRanks = ns.Platform.GetGuildRanks(),
    rankMap = ns.rankMapService and ns.rankMapService:Current() or nil,
    draft = state.draft,
    guildRoster = ns.guildRoster,
    canManage = ns.PermissionService.Can(role, "ranks_manage"),
    ownRole = role,
    ownRankIndex = ownName and ownIndex or nil,
    formatDate = ns.Platform.FormatDate,
  })
end

-- The rows to save: every rank of the game but the guild master, with the role being edited and the name it has now.
local function rowsToSave(data)
  local ranks = {}
  for _, row in ipairs(data.rows) do
    if not row.guildMaster then
      ranks[row.index] = { role = row.role, name = row.rankName }
    end
  end
  return ranks
end

local function save(data)
  if not ns.comm then
    UI.Notify("warning", L("Sync is not running: the mapping can not be saved."))
    return
  end
  local ok, reason = ns.comm:SetRankMap(rowsToSave(data))
  if ok then
    state.draft = nil
    UI.Notify("success", L("Mapping saved and sent to the guild."))
  else
    UI.Notify("danger", L("Not saved: ") .. (ViewModel.RANK_SAVE_ERRORS[reason] or tostring(reason)))
  end
  UI.Redraw()
end

local function choose(data, index, role)
  local draft = {}
  for _, row in ipairs(data.rows) do
    if not row.guildMaster then
      draft[row.index] = { role = row.role }
    end
  end
  draft[index] = { role = role }
  state.draft = draft
  UI.Redraw()
end

local function columns()
  return {
    { key = "index", title = L("Rank"), width = 60 },
    { key = "name", title = L("Name"), weight = 2 },
    { key = "members", title = L("Members"), width = 90 },
    { key = "role", title = L("Addon role"), weight = 2 },
  }
end

local function roleCell(data, row)
  if row.guildMaster then
    return { text = L("Guild master"), color = "info" }
  end
  if row.readOnly then
    return { text = row.roleText, color = "dim" }
  end
  return {
    widget = "dropdown",
    opts = {
      items = ViewModel.RankRoleChoices(),
      value = row.role,
      onChange = function(value)
        choose(data, row.index, value)
      end,
    },
  }
end

local function drawTable(page, data)
  local rows = {}
  for index, row in ipairs(data.rows) do
    rows[index] = {
      cells = {
        index = { text = tostring(row.index), color = "muted" },
        name = { text = ViewModel.Escape(row.rankName), color = row.changed and "warning" or nil },
        members = { text = tostring(row.members), color = "dim" },
        role = roleCell(data, row),
      },
    }
  end
  Kit.Table(page, {
    columns = columns(),
    rows = rows,
    emptyText = L("The client does not report the guild ranks yet. Try again in a moment."),
  })
end

UI.Register("ranks", function(page)
  local data = view()
  Kit.PageHeader(page, {
    title = L("Ranks"),
    description = L("The addon role of each guild rank. It follows the rank position, so a rename keeps the roles."),
  })
  if data.drift.structural then
    Kit.Banner(page, { kind = "danger", text = data.drift.structuralText })
  end
  if #data.drift.renamed > 0 then
    Kit.Banner(page, { kind = "info", text = table.concat(data.drift.renamed, " ") })
  end
  if data.noMap then
    Kit.Banner(page, {
      kind = "info",
      text = L(
        "No mapping saved yet: the roles come from the rank names. Saving pins today's roles to the rank positions."
      ),
    })
  end
  if not data.canEdit then
    Kit.Label(page, {
      text = L("Only the guild master and the co-guild master can change the mapping."),
      style = "small",
      color = "muted",
      wrap = true,
      layout = { gap = 6 },
    })
  end
  drawTable(page, data)

  if data.canEdit then
    local card = Kit.Card(page, { title = L("Preview"), gap = 8, layout = { gap = 12 } })
    Kit.Label(card, { text = data.previewText, wrap = true })
    local row = Kit.Row(card, { gap = 8, align = "center" })
    Kit.Button(row, {
      text = L("Save mapping"),
      variant = "primary",
      disabled = not data.canSave,
      layout = { width = "auto" },
      onClick = function()
        save(data)
      end,
    })
    if state.draft then
      Kit.Button(row, {
        text = L("Discard changes"),
        layout = { width = "auto" },
        onClick = function()
          state.draft = nil
          UI.Redraw()
        end,
      })
    end
  end
  if data.footer then
    Kit.Label(page, { text = data.footer, style = "small", color = "muted", layout = { gap = 10 } })
  end
end)
