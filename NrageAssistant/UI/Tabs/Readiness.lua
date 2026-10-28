local _, ns = ...

-- Readiness (plan 3.3): one divided list with a row per rule: a status chip, the rule, what was measured and, for a
-- rule
-- the player confirms by hand, its dropdown. The list refreshes by itself while it is on screen (UI.WatchReadiness).
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

local function statusItems()
  local items = {}
  for _, status in ipairs(ViewModel.READY_STATUSES) do
    items[#items + 1] = { value = status, text = ViewModel.Word(status) }
  end
  return items
end

UI.Register("ready", function(page)
  local character = ns.character
  local rules = ns.ReadinessRules.Current()
  local results, summary = ns.ReadinessService.Evaluate(rules, character.profile, character.readiness)
  local data = ViewModel.ReadinessRows(rules, results, summary)

  Kit.PageHeader(page, {
    title = L("Raid check"),
    description = L("The guild's checklist, measured on your own character."),
    badge = data.badge,
  })

  local rows = {}
  for _, row in ipairs(data.rows) do
    local entry = {
      status = row.status == "unknown" and "pending" or row.status,
      title = row.title,
      subtitle = row.detail,
      value = row.valueText,
      valueColor = row.valueToken,
    }
    if row.manual then
      entry.value = nil
      entry.right = {
        widget = "dropdown",
        opts = {
          items = statusItems(),
          value = row.manual.status,
          onChange = function(status)
            local ok, reason =
              ns.ReadinessService.SetManual(ns.Platform, rules, character.readiness, row.ruleId, status)
            if ok then
              UI.Redraw()
            else
              UI.Notify("danger", ViewModel.READY_SET_ERRORS[reason] or tostring(reason))
            end
          end,
        },
      }
    end
    rows[#rows + 1] = entry
  end
  Kit.List(page, { rows = rows })
end)
