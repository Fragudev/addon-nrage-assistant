local _, ns = ...

-- The toggleable modules of the addon (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, Part A.1). Each player switches them on
-- and off for themselves; nothing is synced. A module owns some tabs of the window and some activation steps of
-- Core/Init.lua. Every tab and every step belongs to the core or to exactly one module (tests/module_registry_spec).
--   requires: the modules that must be on for this one to work (turning one off turns this one off too).
-- The text of a module (its name, its description) is written by the Modules tab, not here: this file is pure data.
local ModuleRegistry = {}

local MODULES = {
  { id = "professions", tabs = { "professions" }, steps = { "recipes" }, requires = {} },
  { id = "raid", tabs = { "events", "ready", "raid", "rules", "roster" }, steps = {}, requires = {} },
  { id = "loot", tabs = { "loot" }, steps = { "lootPopup", "votingFrame", "bossLoot" }, requires = { "raid" } },
  { id = "pvp", tabs = { "pvp", "pvpadmin" }, steps = { "pvp", "pvpSeason" }, requires = {} },
  { id = "intel", tabs = {}, steps = { "intel" }, requires = { "pvp" } },
  { id = "groups", tabs = { "groups" }, steps = { "lfg" }, requires = {} },
  { id = "map", tabs = {}, steps = { "position" }, requires = {} },
  { id = "blacklist", tabs = {}, steps = { "blacklist" }, requires = {} },
  -- The board and the popup. The editor (announceadmin) and the service stay core: the guild master can still publish,
  -- and the announcements keep arriving while the board is hidden.
  { id = "announcements", tabs = { "announcements" }, steps = {}, requires = {} },
}

-- The tabs and the activation steps that no module owns: they are always on.
local CORE_TABS = { home = true, modules = true, ranks = true, installs = true, announceadmin = true }
local CORE_STEPS = {
  character = true,
  profile = true,
  purge = true,
  comm = true,
  minimap = true,
  roster = true,
  autoPublish = true,
  selfTest = true,
  announcements = true,
}

local BY_ID, BY_TAB, BY_STEP = {}, {}, {}
for _, module in ipairs(MODULES) do
  BY_ID[module.id] = module
  for _, tab in ipairs(module.tabs) do
    BY_TAB[tab] = module.id
  end
  for _, step in ipairs(module.steps) do
    BY_STEP[step] = module.id
  end
end

-- The modules in the order of the Modules tab. The list is shared: do not change it.
function ModuleRegistry.List()
  return MODULES
end

-- The module with `id`, or nil for an id this version does not know.
function ModuleRegistry.Get(id)
  return BY_ID[id]
end

-- The id of the module that owns the tab `value`, or nil (core tabs and unknown tabs).
function ModuleRegistry.ForTab(value)
  return BY_TAB[value]
end

-- The id of the module that owns the activation step `name`, or nil (core steps and unknown steps).
function ModuleRegistry.ForStep(name)
  return BY_STEP[name]
end

function ModuleRegistry.IsCoreTab(value)
  return CORE_TABS[value] == true
end

function ModuleRegistry.IsCoreStep(name)
  return CORE_STEPS[name] == true
end

-- Is the module `id` on? `moduleSettings` is db.global.settings.modules ({ off = { [id] = true } }) or nil, and
-- the module is off when it or a module it requires is in the off set. Unknown ids count as on.
function ModuleRegistry.IsEnabled(moduleSettings, id)
  local off = type(moduleSettings) == "table" and moduleSettings.off or nil
  if type(off) ~= "table" then
    return true
  end
  if off[id] then
    return false
  end
  local module = BY_ID[id]
  if not module then
    return true
  end
  for _, required in ipairs(module.requires) do
    if not ModuleRegistry.IsEnabled(moduleSettings, required) then
      return false
    end
  end
  return true
end

-- The ids of the modules that `id` needs, directly or through another one, in the order they are found.
function ModuleRegistry.Requirements(id)
  local result, seen = {}, {}
  local function visit(current)
    local module = BY_ID[current]
    if not module then
      return
    end
    for _, required in ipairs(module.requires) do
      if not seen[required] then
        seen[required] = true
        result[#result + 1] = required
        visit(required)
      end
    end
  end
  visit(id)
  return result
end

-- The ids of the modules that need `id`, directly or through another one, in the order of the registry.
function ModuleRegistry.Dependents(id)
  local result, seen = {}, { [id] = true }
  local changed = true
  while changed do
    changed = false
    for _, module in ipairs(MODULES) do
      if not seen[module.id] then
        for _, required in ipairs(module.requires) do
          if seen[required] then
            seen[module.id] = true
            result[#result + 1] = module.id
            changed = true
            break
          end
        end
      end
    end
  end
  return result
end

ns.ModuleRegistry = ModuleRegistry
