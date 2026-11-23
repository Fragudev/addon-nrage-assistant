local _, ns = ...

-- The Modules tab (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, Part A.5): one row per module of the registry, with what its
-- switch does to the rest. Pure: the switches come in as functions, the rows go out as plain values.
local ViewModel = ns.ViewModel
local L = ns.L

-- The name and the one-line description of each module, by id.
ViewModel.MODULE_TEXT = ns.Locale.Table(function()
  return {
    professions = {
      label = L("Professions"),
      description = L("Recipes of your professions, read when you open a profession window."),
    },
    raid = {
      label = L("Raid"),
      description = L("Raid events, the raid check, the members and the roster rules."),
    },
    loot = {
      label = L("Loot"),
      description = L("Loot sessions, the loot popup and the voting window, and the loot of the bosses you kill."),
    },
    pvp = {
      label = "PvP",
      description = L("PvP kills, honour, seasons, missions and the PvP admin section."),
    },
    intel = {
      label = L("Intel"),
      description = L("Enemy sightings, the Intel alerts and their map pins."),
    },
    groups = {
      label = L("Groups"),
      description = L("The group board and the popup of join requests."),
    },
    layers = {
      label = L("Layers"),
      description = L("Your layer and the layers of your guildmates."),
    },
    map = {
      label = L("Map pins"),
      description = L("Guildmates' positions on the map and the minimap."),
    },
    blacklist = {
      label = L("Blacklist"),
      description = L("The alert when a blacklisted player joins your group."),
    },
    announcements = {
      label = L("Notice board"),
      description = L("The guild announcements board and the popup when a new one arrives."),
    },
  }
end)

-- The names of a list of module ids, in the same order, for a sentence.
local function namesOf(ids)
  local names = {}
  for index, id in ipairs(ids) do
    names[index] = ViewModel.MODULE_TEXT[id] and ViewModel.MODULE_TEXT[id].label or id
  end
  return names
end

-- The rows of the Modules tab, one per module of the registry, in its order. `opts`:
--   enabled(id)           is the module on for this player
--   needsReload(id)       is it on, but its activation steps were skipped at login (ModuleService:NeedsReload)
--   cascade(id, enabled)  the ids whose switch would change if `id` were switched to `enabled` (ModuleService:Cascade)
--   admin                 does the player see admin tabs (gm and cogm): a module takes its admin section with it
-- A row: { id, label, description, tabs = { names }, enabled, needsReload, also = { names of the other switches the
-- change would move }, alsoOn = true when those are turned on rather than off, adminNote = true when turning it off
-- hides an admin section }.
function ViewModel.ModuleRows(opts)
  local tabByValue = {}
  for _, tab in ipairs(ViewModel.TABS) do
    tabByValue[tab.value] = tab
  end
  local rows = {}
  for _, module in ipairs(ns.ModuleRegistry.List()) do
    local text = ViewModel.MODULE_TEXT[module.id] or { label = module.id, description = "" }
    local enabled = opts.enabled(module.id) == true
    local tabs, hasAdmin = {}, false
    for _, value in ipairs(module.tabs) do
      local tab = tabByValue[value]
      if tab then
        tabs[#tabs + 1] = tab.text
        hasAdmin = hasAdmin or tab.group == "admin"
      end
    end
    local others = {}
    for _, id in ipairs(opts.cascade(module.id, not enabled)) do
      if id ~= module.id then
        others[#others + 1] = id
      end
    end
    rows[#rows + 1] = {
      id = module.id,
      label = text.label,
      description = text.description,
      tabs = tabs,
      enabled = enabled,
      needsReload = opts.needsReload(module.id) == true,
      also = namesOf(others),
      alsoOn = not enabled,
      adminNote = enabled and hasAdmin and opts.admin == true,
    }
  end
  return rows
end

-- The sentence under a switch that moves other switches, or nil. "Turning it off also turns off: Intel."
function ViewModel.ModuleAlsoLine(row)
  if #row.also == 0 then
    return nil
  end
  local names = table.concat(row.also, ", ")
  if row.alsoOn then
    return L("Turning it on also turns on: %s."):format(names)
  end
  return L("Turning it off also turns off: %s."):format(names)
end

-- The line that lists the tabs a module controls: "Tabs: PvP, PvP".
function ViewModel.ModuleTabsLine(row)
  if #row.tabs == 0 then
    return nil
  end
  return L("Tabs: %s."):format(table.concat(row.tabs, ", "))
end
