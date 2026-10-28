local _, ns = ...

-- Assignment templates: the assignments of an event saved under a name, to be applied to another event
-- (the same boss week after week). Templates are local to this client and never sent; applying one
-- creates ordinary assignments, so the usual role check and the usual sync apply to each of them.
--
--   template = { name, slots = { { encounter, characterKey, group?, task?, note? } ... }, savedAt, savedBy,
--                rosterId? }
-- A template follows the roster of the event it was saved from (plan 3.4.1): it is offered and applied only for events
-- of that roster. A template with no roster is a legacy one and works for every roster.
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

-- The names of the templates, sorted. With a `viewer` (RosterService.Viewer) only the ones that viewer can use.
function TemplateService.List(templates, viewer)
  local names = {}
  for name, template in pairs(templates) do
    if not viewer or ns.RosterService.TemplateVisible(template, viewer) then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- Saves the assignments of `event` as `name` (replacing a template with that name).
-- Returns the template, or nil plus "invalid:name" | "empty" | "limit" | "other_roster" (a template of that name
-- belongs to another roster).
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
  local existing = templates[name]
  if existing and existing.rosterId ~= nil and existing.rosterId ~= event.rosterId then
    return nil, "other_roster"
  end
  if not existing and countKeys(templates) >= constants.TEMPLATES_MAX then
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

  local template = { name = name, slots = slots, savedAt = now, savedBy = actor, rosterId = event.rosterId }
  templates[name] = template
  return template
end

-- Deletes a template. With `ctx` ({ role, rosterId }) a raid leader can only delete the ones of their own roster (and
-- the legacy ones); returns true, or false plus "not_found" | "other_roster".
function TemplateService.Delete(templates, name, ctx)
  local template = templates[name]
  if not template then
    return false, "not_found"
  end
  if
    ctx
    and not ns.PermissionService.IsGlobal(ctx.role)
    and template.rosterId ~= nil
    and template.rosterId ~= ctx.rosterId
  then
    return false, "other_roster"
  end
  templates[name] = nil
  return true
end

-- Adds the template's assignments to an event, skipping any the event already has. `ctx` is the one
-- EventService uses (events, role, actor, now, newId). Returns the assignments created (so the caller
-- can send them) and a table of skip reasons with counts, or nil plus "forbidden" | "not_found" | "other_roster" (the
-- template belongs to another roster than the event).
function TemplateService.Apply(ctx, templates, name, eventId)
  if not ns.PermissionService.Can(ctx.role, "raid_manage") then
    return nil, "forbidden"
  end
  local template = templates[name]
  local event = ctx.events[eventId]
  if not template or not event then
    return nil, "not_found"
  end
  if template.rosterId ~= nil and template.rosterId ~= event.rosterId then
    return nil, "other_roster"
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
    local mine = template.rosterId == nil or template.rosterId == event.rosterId
    local related = mine
      and (mentions(title, key) or mentions(instance, key) or mentions(key, title) or mentions(key, instance))
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
