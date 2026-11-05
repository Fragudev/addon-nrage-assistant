local _, ns = ...

-- Roster rules (docs/NAV_PERMISSIONS_PLAN.md 4.1): the readiness rules of the selected roster as a list with an
-- Automatic or Manual badge, edit in place (the rule keeps its id, so the confirmations members gave stay attached)
-- and delete with a two-click confirm; a form with the controls of each kind of rule, errors shown under the field they
-- belong to; and "Use the starting list" with a two-click confirm. Every change replaces the whole set of that roster,
-- sent to the guild by itself (Comm:SetReadinessRules). gm and cogm pick any roster and edit it, an rl edits its own,
-- an officer sees every roster with every control disabled.

local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- The form: the kind, and the controls of each kind. `editing` is the id of the rule being edited.
-- What the tab being drawn works on: the roster, and whether this player may change its rules (controls are disabled
-- otherwise, never hidden).
local view = { rosterId = nil, locked = true }

local state = {
  editing = nil,
  check = "level",
  fields = { label = "", min = "", slots = {}, buffs = "", profession = "", field = "role" },
  errors = {},
}

local PROFESSIONS = ns.Locale.Table(function()
  return {
    L("Alchemy"),
    L("Blacksmithing"),
    L("Enchanting"),
    L("Engineering"),
    L("Herbalism"),
    L("Leatherworking"),
    L("Mining"),
    L("Skinning"),
    L("Tailoring"),
    L("Cooking"),
    L("Fishing"),
    L("First Aid"),
  }
end)

local function resetForm()
  state.editing = nil
  state.check = "level"
  state.fields = { label = "", min = "", slots = {}, buffs = "", profession = "", field = "role" }
  state.errors = {}
end

-- Sends a new whole set to the guild and says so in the banner.
local function saveRules(rules)
  -- On success the second value is the revision, otherwise the reason.
  local ok, outcome = ns.comm:SetReadinessRules(view.rosterId, rules)
  if ok then
    UI.Notify("success", L("Rules saved as revision %d and sent to the guild."):format(outcome))
  else
    UI.Notify("danger", L("Not saved: ") .. (ViewModel.RULE_ERRORS[outcome] or tostring(outcome)))
  end
  return ok
end

-- ---------------------------------------------------------------------------------------------------------------
-- The list

local function ruleList(page, rules)
  local rows = {}
  for _, row in ipairs(ViewModel.RuleRows(rules)) do
    local key = "rule:" .. row.id
    local remove
    if UI.IsArmed(key) then
      remove = {
        widget = "button",
        opts = {
          text = L("Confirm: delete"),
          variant = "dangerSolid",
          disabled = view.locked,
          layout = {},
          onClick = function()
            UI.Disarm()
            local list, reason = ViewModel.WithoutRule(rules, row.id)
            if not list then
              UI.Notify("danger", L("Not saved: ") .. (ViewModel.RULE_ERRORS[reason] or tostring(reason)))
              return
            end
            if state.editing == row.id then
              resetForm()
            end
            saveRules(list)
          end,
        },
      }
    else
      remove = {
        widget = "iconButton",
        opts = {
          icon = "trash",
          variant = "danger",
          tooltip = L("Delete the rule"),
          disabled = view.locked,
          layout = {},
          onClick = function()
            UI.Arm(key)
          end,
        },
      }
    end
    rows[#rows + 1] = {
      title = row.name,
      subtitle = row.kindText .. " \194\183 " .. row.summary,
      badge = row.badge,
      rights = {
        remove,
        {
          widget = "iconButton",
          opts = {
            icon = "pencil",
            tooltip = L("Edit the rule"),
            disabled = view.locked,
            layout = {},
            onClick = function()
              state.editing = row.id
              state.check = row.rule.check
              state.fields = ViewModel.RuleFields(row.rule)
              state.errors = {}
              UI.Redraw()
            end,
          },
        },
      },
    }
  end
  Kit.List(page, { rows = rows })
end

-- ---------------------------------------------------------------------------------------------------------------
-- The form

local function kindControls(card, fields)
  local check = state.check
  local details = state.errors.details
  if check == "level" or check == "ilvl" then
    local field = Kit.Field(card, { label = L("Minimum"), error = details })
    Kit.EditBox(field, {
      text = fields.min,
      numeric = true,
      maxLetters = 3,
      disabled = view.locked,
      error = details ~= nil,
      onChange = function(text)
        fields.min = text
      end,
    })
  elseif check == "enchants" then
    local field = Kit.Field(card, { label = L("Slots that must be enchanted"), error = details })
    local flow = Kit.Flow(field, { gap = 8, rowGap = 8 })
    for _, slot in ipairs(ViewModel.EnchantSlotChoices()) do
      Kit.Chip(flow, {
        text = slot.text,
        fixed = true,
        active = fields.slots[slot.slot] == true,
        disabled = view.locked,
        onToggle = function(active)
          fields.slots[slot.slot] = active or nil
        end,
      })
    end
  elseif check == "buff" then
    local field = Kit.Field(card, { label = L("Spell names or ids, separated by commas"), error = details })
    Kit.EditBox(field, {
      text = fields.buffs,
      disabled = view.locked,
      error = details ~= nil,
      onChange = function(text)
        fields.buffs = text
      end,
    })
  elseif check == "profession" then
    local row = Kit.Row(card, { gap = 12 })
    local profession = Kit.Field(row, { label = L("Profession"), error = details, layout = { weight = 2 } })
    local items = {}
    for _, name in ipairs(PROFESSIONS) do
      items[#items + 1] = { value = name, text = name }
    end
    Kit.Dropdown(profession, {
      items = items,
      value = fields.profession ~= "" and fields.profession or nil,
      placeholder = L("Pick a profession"),
      disabled = view.locked,
      onChange = function(value)
        fields.profession = value
      end,
    })
    local min = Kit.Field(row, { label = L("Minimum skill"), layout = { weight = 1 } })
    Kit.EditBox(min, {
      text = fields.min,
      numeric = true,
      maxLetters = 4,
      disabled = view.locked,
      onChange = function(text)
        fields.min = text
      end,
    })
  elseif check == "field" then
    local field = Kit.Field(card, { label = L("Declared profile field") })
    Kit.Dropdown(field, {
      items = ViewModel.FieldChoices(),
      value = fields.field,
      disabled = view.locked,
      onChange = function(value)
        fields.field = value
      end,
    })
  else
    Kit.Label(card, { text = L("The player confirms this one by hand."), style = "small", color = "muted" })
  end
end

local function ruleForm(page, rules)
  local fields = state.fields
  local editing = state.editing
  local card = Kit.Card(page, { title = editing and L("Edit the rule") or L("Add a rule"), gap = 12 })
  local top = Kit.Row(card, { gap = 12 })
  local kind = Kit.Field(top, { label = L("Kind"), layout = { weight = 1 } })
  Kit.Dropdown(kind, {
    items = ViewModel.RuleKindChoices(),
    value = state.check,
    disabled = view.locked or editing ~= nil,
    onChange = function(value)
      state.check = value
      state.errors = {}
      UI.Redraw()
    end,
  })
  local name = Kit.Field(top, { label = L("Name"), error = state.errors.label, layout = { weight = 2 } })
  Kit.EditBox(name, {
    text = fields.label,
    maxLetters = 60,
    disabled = view.locked,
    error = state.errors.label ~= nil,
    onChange = function(text)
      fields.label = text
    end,
  })
  kindControls(card, fields)

  local buttons = Kit.Row(card, { gap = 10, layout = { gap = 14 } })
  Kit.Button(buttons, {
    text = editing and L("Save rule") or L("Add rule"),
    variant = "primary",
    disabled = view.locked,
    layout = { width = "auto" },
    onClick = function()
      local rule, reason = ViewModel.RuleFromFields(state.check, fields, rules, editing)
      if not rule then
        state.errors = { [ViewModel.RuleErrorField(reason)] = ViewModel.RULE_ERRORS[reason] }
        UI.Notify("danger", L("Not saved: ") .. (ViewModel.RULE_ERRORS[reason] or tostring(reason)))
        return
      end
      local list
      if editing then
        list = ViewModel.ReplaceRule(rules, editing, rule)
      else
        list = ViewModel.WithRule(rules, rule)
      end
      if list and saveRules(list) then
        resetForm()
        UI.Redraw()
      end
    end,
  })
  if editing then
    Kit.Button(buttons, {
      text = L("Cancel"),
      disabled = view.locked,
      layout = { width = "auto" },
      onClick = function()
        resetForm()
        UI.Redraw()
      end,
    })
  end
end

-- ---------------------------------------------------------------------------------------------------------------
-- The tab

-- May this player change the rules of `rosterId`? "all" scope anywhere, "own" on the own roster only. Without a sync
-- transport nothing could be sent, so the tab stays read-only.
local function mayEdit(role, rosterId)
  local own = UI.OwnRosterId()
  local scope = ns.PermissionService.Scope(role, "rules_edit", own)
  return ns.comm ~= nil and (scope == "all" or (scope == "own" and rosterId == own))
end

-- The Raid check tab shows the same roster when the player may pick it (or it is the own roster).
local function openRaidCheck(role, rosterId)
  local own = UI.OwnRosterId()
  local scope = ns.PermissionService.Scope(role, "raidcheck_view", own)
  if scope == "all" then
    UI.nav.rosters = UI.nav.rosters or {}
    UI.nav.rosters.ready = rosterId
  end
  UI.OpenTab("ready")
end

UI.Register("rules", function(page)
  local role = UI.Role()
  local selection = UI.RosterSelection("rules", "rules_view")
  local rosterId = selection.selected
  Kit.PageHeader(page, {
    title = L("Roster rules"),
    description = L("The checklist each roster is measured against."),
  })
  UI.DrawRosterSelector(page, "rules", selection, function()
    resetForm()
    UI.Disarm()
  end)
  if rosterId == nil then
    Kit.EmptyState(page, {
      icon = "list",
      title = L("There is no roster to show rules for."),
      hint = L("Rosters are created in the Members tab."),
    })
    return
  end

  view.rosterId, view.locked = rosterId, not mayEdit(role, rosterId)
  local rules = ns.ReadinessRules.Current(rosterId)
  local revision = ns.ReadinessRules.Describe(ns.ReadinessRules.Record(rosterId))[1]
  local header = Kit.Row(page, { gap = 12, align = "center" })
  local left = Kit.Stack(header, { gap = 4, layout = { weight = 1 } })
  Kit.Label(left, {
    text = ViewModel.Escape(revision) .. " \194\183 " .. (view.locked and L("Read only") or L(
      "Sent to the guild automatically"
    )),
    color = "dim",
  })
  if ns.PermissionService.Scope(role, "raidcheck_view", UI.OwnRosterId()) ~= "none" then
    Kit.Button(header, {
      text = L("See how members see it"),
      variant = "ghost",
      icon = "chevron",
      layout = { width = "auto" },
      onClick = function()
        openRaidCheck(role, rosterId)
      end,
    })
  end

  ruleList(page, rules)
  ruleForm(page, rules)

  local key = "rules:default"
  local armed = UI.IsArmed(key) and not view.locked
  Kit.Button(page, {
    text = armed and L("Confirm: replace every rule with the starting list") or L("Use the starting list"),
    variant = armed and "dangerSolid" or "secondary",
    disabled = view.locked,
    layout = { width = 360 },
    onClick = function()
      if not armed then
        UI.Arm(key)
        return
      end
      UI.Disarm()
      resetForm()
      saveRules(ns.Constants.DEFAULT_RULES)
    end,
  })
  Kit.Label(page, {
    text = L("These rules apply to the players of this roster and are measured on each player's own game."),
    style = "small",
    color = "muted",
    wrap = true,
  })
  Kit.Label(page, {
    text = L(
      "Level, item level, professions, enchants and buffs are checked automatically; the rest are confirmed by hand."
    ),
    style = "small",
    color = "muted",
    wrap = true,
    layout = { gap = 4 },
  })
end)
