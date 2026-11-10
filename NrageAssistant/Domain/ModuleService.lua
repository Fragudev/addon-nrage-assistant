local _, ns = ...

-- The personal switches of the modules (docs/ANNOUNCEMENTS_MODULES_PVP_PLAN.md, Part A.3). The switches live in this
-- account's settings (Settings.ModulesOff), are read by everybody through IsEnabled, and are never synced.
--
-- deps:
--   db()          returns the saved database (ns.db); nil before it exists, when every module counts as on
--   skipped()     returns the list of the activation steps skipped at login (ns.skippedSteps)
--   onChange()    optional, called after a switch changed
local ModuleService = {}
ModuleService.__index = ModuleService

function ModuleService.New(deps)
  return setmetatable({ deps = deps }, ModuleService)
end

-- The saved database, or nil.
function ModuleService:database()
  return self.deps.db and self.deps.db() or nil
end

-- The view of the settings the registry reads: { off = { [id] = true } }, or nil without a database.
function ModuleService:settingsView()
  local db = self:database()
  if not (db and db.global) then
    return nil
  end
  return { off = ns.Settings.ModulesOff(db) }
end

-- Is the module `id` on for this player? Unknown ids count as on. This is the one check the rest of the addon makes.
function ModuleService:IsEnabled(id)
  return ns.ModuleRegistry.IsEnabled(self:settingsView(), id)
end

-- The ids whose own switch would change if `id` were switched to `enabled`, the id first. Switching on changes the
-- switched-off modules it needs; switching off changes the switched-on modules that need it. Nothing else.
function ModuleService:Cascade(id, enabled)
  local Registry = ns.ModuleRegistry
  if not Registry.Get(id) then
    return {}
  end
  local db = self:database()
  local off = db and db.global and ns.Settings.ModulesOff(db) or {}
  local candidates = { id }
  for _, other in ipairs(enabled and Registry.Requirements(id) or Registry.Dependents(id)) do
    candidates[#candidates + 1] = other
  end
  local result = {}
  for _, candidate in ipairs(candidates) do
    -- An own switch that already has the wanted value is not a change.
    if (off[candidate] == true) ~= (enabled ~= true) then
      result[#result + 1] = candidate
    end
  end
  return result
end

-- Switches the module `id` (and the modules it needs or that need it, see Cascade). Returns true, or false plus
-- "unknown" for an id this version does not know, or "unavailable" when there is no database yet.
function ModuleService:SetEnabled(id, enabled)
  if not ns.ModuleRegistry.Get(id) then
    return false, "unknown"
  end
  local db = self:database()
  if not (db and db.global) then
    return false, "unavailable"
  end
  local changed = self:Cascade(id, enabled == true)
  for _, other in ipairs(changed) do
    ns.Settings.SetModuleOff(db, other, enabled ~= true)
  end
  if #changed > 0 and self.deps.onChange then
    self.deps.onChange()
  end
  return true
end

-- True when the module is on now but one of its activation steps was skipped at login, so a reload starts it.
function ModuleService:NeedsReload(id)
  local module = ns.ModuleRegistry.Get(id)
  if not module or #module.steps == 0 or not self:IsEnabled(id) then
    return false
  end
  local skipped = {}
  for _, name in ipairs(self.deps.skipped and self.deps.skipped() or {}) do
    skipped[name] = true
  end
  for _, step in ipairs(module.steps) do
    if skipped[step] then
      return true
    end
  end
  return false
end

ns.ModuleService = ModuleService
