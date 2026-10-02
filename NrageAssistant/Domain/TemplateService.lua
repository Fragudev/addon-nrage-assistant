local _, ns = ...

-- Assignment templates: the assignments of an event saved under a name, to be applied to another event
-- (the same boss week after week). Templates are local to this client and never sent; applying one
-- creates ordinary assignments, so the usual role check and the usual sync apply to each of them.
--
--   template = { name, slots = { { encounter, characterKey, group?, task?, note? } ... }, savedAt, savedBy }
local TemplateService = {}

local L = ns.L

local function countKeys(tbl)
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

local function slotKey(slot)
  return ("%s\n%s\n%s"):format(slot.encounter, slot.characterKey, slot.task or "")
end

function TemplateService.List(templates)
  local names = {}
  for name in pairs(templates) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

-- Saves the assignments of `event` as `name` (replacing a template with that name).
-- Returns the template, or nil plus "invalid:name" | "empty" | "limit".
function TemplateService.Save(templates, event, name, now, actor)
  local constants = ns.Constants
  name = type(name) == "string" and name:match("^%s*(.-)%s*$") or nil
  if not ns.Validate.Text(name, constants.TEMPLATE_NAME_MAX) then
    return nil, "invalid:name"
  end

  local slots = {}
  for _, assignment in pairs(event.assignments) do
    local clean = ns.EventModel.ValidateAssignment(assignment)
    if clean then
      slots[#slots + 1] = clean
    end
  end
  if #slots == 0 then
    return nil, "empty"
  end
  if not templates[name] and countKeys(templates) >= constants.TEMPLATES_MAX then
    return nil, "limit"
  end

  table.sort(slots, function(a, b)
    if a.encounter ~= b.encounter then
      return a.encounter < b.encounter
    end
    if a.characterKey ~= b.characterKey then
      return a.characterKey < b.characterKey
    end
    return (a.task or "") < (b.task or "")
  end)

  local template = { name = name, slots = slots, savedAt = now, savedBy = actor }
  templates[name] = template
  return template
end

function TemplateService.Delete(templates, name)
  if not templates[name] then
    return false, "not_found"
  end
  templates[name] = nil
  return true
end

-- Adds the template's assignments to an event, skipping any the event already has. `ctx` is the one
-- EventService uses (events, role, actor, now, newId). Returns the assignments created (so the caller
-- can send them) and a table of skip reasons with counts, or nil plus "forbidden" | "not_found".
function TemplateService.Apply(ctx, templates, name, eventId)
  if not ns.PermissionService.Can(ctx.role, "manage_assignments") then
    return nil, "forbidden"
  end
  local template = templates[name]
  local event = ctx.events[eventId]
  if not template or not event then
    return nil, "not_found"
  end

  local present = {}
  for _, assignment in pairs(event.assignments) do
    present[slotKey(assignment)] = true
  end

  local created, skipped = {}, {}
  local function skip(reason)
    skipped[reason] = (skipped[reason] or 0) + 1
  end

  for _, slot in ipairs(template.slots) do
    if present[slotKey(slot)] then
      skip("duplicate")
    else
      local assignment, reason = ns.EventService.AddAssignment(ctx, eventId, {
        encounter = slot.encounter,
        characterKey = slot.characterKey,
        group = slot.group,
        task = slot.task,
        note = slot.note,
      })
      if assignment then
        created[#created + 1] = assignment
        present[slotKey(slot)] = true
      else
        skip(reason)
        if reason == "limit" then
          break
        end
      end
    end
  end
  return created, skipped
end

local SUGGEST_MIN_LENGTH = 3

local function lowered(text)
  return type(text) == "string" and text:lower():match("^%s*(.-)%s*$") or ""
end

local function mentions(haystack, needle)
  return #needle >= SUGGEST_MIN_LENGTH and haystack:find(needle, 1, true) ~= nil
end

-- Templates worth offering for an event: the template name appears in the event's title or instance, or the
-- other way round (a template called "Molten Core" for an event "Molten Core night"). A template whose slots
-- the event already has is left out. Nothing is applied here; the caller offers each name and applies only
-- when the player clicks. Returns the names, sorted.
function TemplateService.Suggest(templates, event)
  local title, instance = lowered(event.title), lowered(event.instance)
  local present = {}
  for _, assignment in pairs(event.assignments or {}) do
    present[slotKey(assignment)] = true
  end

  local names = {}
  for name, template in pairs(templates) do
    local key = lowered(name)
    local related = mentions(title, key) or mentions(instance, key) or mentions(key, title) or mentions(key, instance)
    if related then
      for _, slot in ipairs(template.slots) do
        if not present[slotKey(slot)] then
          names[#names + 1] = name
          break
        end
      end
    end
  end
  table.sort(names)
  return names
end

-- One line for the result of Apply.
function TemplateService.Describe(created, skipped)
  local parts = {}
  local reasons = {}
  for reason in pairs(skipped) do
    reasons[#reasons + 1] = reason
  end
  table.sort(reasons)
  for _, reason in ipairs(reasons) do
    parts[#parts + 1] = ("%s: %d"):format(reason, skipped[reason])
  end
  local text = L("added %d assignment(s)"):format(#created)
  if #parts > 0 then
    text = text .. L(" (skipped - %s)"):format(table.concat(parts, ", "))
  end
  return text
end

ns.TemplateService = TemplateService
