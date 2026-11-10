local _, ns = ...

-- Modules (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, Part A.5): every player turns the modules of the addon on and off
-- for themselves. The switches are saved in this account only; nothing is shared. The rows and their sentences come
-- from ViewModelModules; the switch itself is ModuleService:SetEnabled, which redraws the window through
-- UI.ModulesChanged. Open to every role: it is the one tab with no gate.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local function rows()
  local role = UI.Role()
  return ViewModel.ModuleRows({
    enabled = function(id)
      return ns.modules:IsEnabled(id)
    end,
    needsReload = function(id)
      return ns.modules:NeedsReload(id)
    end,
    cascade = function(id, enabled)
      return ns.modules:Cascade(id, enabled)
    end,
    admin = role == "gm" or role == "cogm",
  })
end

-- The notes under a switch: what else moves, the admin section it takes along, and the reload it needs.
local function drawNotes(card, row)
  local lines = {}
  local function add(text)
    if text then
      lines[#lines + 1] = text
    end
  end
  add(ViewModel.ModuleAlsoLine(row))
  add(row.adminNote and L("You will stop seeing its admin section too.") or nil)
  add(ViewModel.ModuleTabsLine(row))
  add(row.needsReload and L("Type /reload to start %s."):format(row.label) or nil)
  for _, line in ipairs(lines) do
    Kit.Label(card, { text = line, style = "small", color = "muted", wrap = true })
  end
end

UI.Register("modules", function(page)
  Kit.PageHeader(page, {
    title = L("Modules"),
    description = L("Turn the parts of the addon you use on or off. Only you are affected: nothing is shared, ")
      .. L("and turning a module off never deletes its data."),
  })
  local card = Kit.Card(page, { title = L("Your modules"), gap = 12 })
  local list = rows()
  for _, row in ipairs(list) do
    Kit.Switch(card, {
      label = row.label,
      description = row.description,
      checked = row.enabled,
      onChange = function(checked)
        ns.modules:SetEnabled(row.id, checked == true)
      end,
    })
    drawNotes(card, row)
  end
  for _, row in ipairs(list) do
    if row.needsReload then
      Kit.Button(page, {
        text = L("Reload the interface"),
        layout = { width = 180, gap = 10 },
        onClick = function()
          ns.Platform.ReloadUI()
        end,
      })
      break
    end
  end
  Kit.Button(page, {
    text = L("Turn all on"),
    layout = { width = 180, gap = 10 },
    onClick = function()
      for _, row in ipairs(list) do
        ns.modules:SetEnabled(row.id, true)
      end
    end,
  })
end)
