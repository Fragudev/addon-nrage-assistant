local _, ns = ...

-- Blacklist (plan 3.7): an inline form to add a player (everyone can), a searchable table with the reason edited in
-- place
-- by who added the entry or the guild master, removal by the guild master with a two-click confirm, and an "In your
-- group" badge on the listed players that are with you now (they are listed first).
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local state = {
  search = "",
  name = "",
  reason = "",
  editing = nil,
  editReason = "",
}

local function commands()
  return ns.BlacklistCommands.New({
    blacklist = ns.db.global.blacklist,
    tombstones = ns.db.global.sync.tombstones,
    platform = ns.Platform,
    comm = ns.comm,
    onChange = function()
      if ns.blacklistWatcher then
        pcall(ns.blacklistWatcher.Check, ns.blacklistWatcher)
      end
    end,
  })
end

local function addForm(page, cmd)
  local max = ns.Constants.BLACKLIST_REASON_MAX
  local card = Kit.Card(page, { title = L("Add a player"), gap = 8 })
  local row = Kit.Row(card, { gap = 12, align = "top" })
  local name = Kit.Field(row, { label = L("Name"), layout = { weight = 2 } })
  Kit.EditBox(name, {
    text = state.name,
    maxLetters = ns.Constants.BLACKLIST_NAME_MAX,
    onChange = function(text)
      state.name = text
    end,
  })
  local reason = Kit.Field(row, { label = L("Reason"), layout = { weight = 4 } })
  local counter
  Kit.EditBox(reason, {
    text = state.reason,
    maxLetters = max,
    onChange = function(text)
      state.reason = text
      if counter then
        local info = ViewModel.ReasonCounter(text, max)
        counter:SetText(info.text)
        counter:SetColor(info.token)
      end
    end,
  })
  local info = ViewModel.ReasonCounter(state.reason, max)
  counter = Kit.Label(reason, { text = info.text, style = "small", color = info.token, align = "RIGHT" })
  Kit.Button(row, {
    text = L("Add"),
    variant = "primary",
    layout = { width = 90 },
    onClick = function()
      local lines = cmd:Add(state.name, state.reason)
      if not ns.Validate.IsFailure(lines) then
        state.name, state.reason = "", ""
      end
      UI.Report(lines)
    end,
  })
end

local function actionsOf(row, cmd)
  local edit, remove = nil, nil
  if state.editing == row.key then
    edit = {
      widget = "iconButton",
      opts = {
        icon = "check",
        tooltip = L("Save"),
        layout = {},
        onClick = function()
          local reason = state.editReason
          state.editing = nil
          UI.Report(cmd:Add(row.name, reason))
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
    return edit, remove
  end
  if row.canEdit then
    edit = {
      widget = "iconButton",
      opts = {
        icon = "pencil",
        tooltip = L("Edit the reason"),
        layout = {},
        onClick = function()
          state.editing, state.editReason = row.key, row.rawReason
          UI.Redraw()
        end,
      },
    }
  end
  if row.canRemove then
    local key = "blacklist:" .. row.key
    if UI.IsArmed(key) then
      remove = {
        widget = "iconButton",
        opts = {
          icon = "check",
          color = "danger",
          tooltip = L("Click again to remove"),
          layout = {},
          onClick = function()
            UI.Disarm()
            UI.Report(cmd:Remove(row.key))
          end,
        },
      }
    else
      remove = {
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
  end
  return edit, remove
end

local function drawTable(region, cmd, role)
  local names = ns.Platform.GetGroupMemberNames()
  local rows = ViewModel.BlacklistTable(ns.db.global.blacklist, {
    role = role,
    actor = ns.Platform.GetIdentityKey(),
    search = state.search,
    groupKeys = ViewModel.BlacklistGroupKeys(ns.db.global.blacklist, names),
    formatDate = ns.Platform.FormatDate,
  })
  local tableRows = {}
  for _, row in ipairs(rows) do
    local edit, remove = actionsOf(row, cmd)
    local reasonCell = { text = row.reason }
    if state.editing == row.key then
      reasonCell = {
        widget = "edit",
        opts = {
          text = state.editReason,
          maxLetters = ns.Constants.BLACKLIST_REASON_MAX,
          onChange = function(text)
            state.editReason = text
          end,
          onEnter = function(text)
            state.editing = nil
            UI.Report(cmd:Add(row.name, text))
          end,
        },
      }
    end
    tableRows[#tableRows + 1] = {
      highlight = row.inGroup,
      cells = {
        name = { text = row.name, color = row.inGroup and "danger" or nil },
        reason = reasonCell,
        group = row.inGroup and { widget = "badge", opts = { text = L("In your group"), color = "danger" } } or "",
        by = { text = row.addedBy, color = "dim" },
        added = { text = row.added, color = "muted" },
        edit = edit or "",
        remove = remove or "",
      },
    }
  end
  Kit.Table(region, {
    columns = {
      { key = "name", title = L("Name"), weight = 2 },
      { key = "reason", title = L("Reason"), weight = 4 },
      { key = "group", title = "", width = 118 },
      { key = "by", title = L("Added by"), weight = 1.6 },
      { key = "added", title = L("Date"), weight = 1.6 },
      { key = "edit", title = "", width = 30 },
      { key = "remove", title = "", width = 30 },
    },
    rows = tableRows,
    emptyText = state.search ~= "" and L("Nobody matches.") or L("Nobody is on the blacklist."),
  })
end

UI.Register("blacklist", function(page)
  local role = UI.Role()
  local cmd = commands()
  Kit.PageHeader(page, {
    title = L("Blacklist"),
    description = L("Players the guild wants to be warned about. You are warned when one is in your group."),
  })
  addForm(page, cmd)
  local region
  Kit.EditBox(page, {
    text = state.search,
    placeholder = L("Search by name or reason"),
    onChange = function(text, userInput)
      if userInput and region then
        state.search = text
        region:Clear()
        drawTable(region, cmd, role)
        UI.Relayout()
      end
    end,
  })
  region = Kit.Stack(page, { gap = 0 })
  drawTable(region, cmd, role)
  Kit.Label(page, {
    text = L("Everyone can add a player. Only the guild master can remove one."),
    style = "small",
    color = "muted",
  })
  Kit.Label(page, {
    text = L("You are warned once when a listed player is in your group."),
    style = "small",
    color = "muted",
    layout = { gap = 4 },
  })
end)
