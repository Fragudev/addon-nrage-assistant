local _, ns = ...

-- /nrage template: keep the assignments of an event as a named template and apply it to another event.
-- Returns the lines to print. Applying a template sends each created assignment to the guild like any
-- other assignment; the templates themselves stay on this client.
--   deps: events, templates, platform, comm
local TemplateCommands = {}
TemplateCommands.__index = TemplateCommands

local USAGE = {
  "usage: /nrage template [list]                  the saved templates",
  "       /nrage template show <name>             the slots of a template",
  "       /nrage template save <event> <name>     save the assignments of an event",
  "       /nrage template apply <event> <name>    add a template's assignments to an event",
  "       /nrage template delete <name>",
}

function TemplateCommands.New(deps)
  return setmetatable({
    events = deps.events,
    templates = deps.templates,
    platform = deps.platform,
    comm = deps.comm,
  }, TemplateCommands)
end

function TemplateCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    now = platform.ServerTime,
    newId = function() return self.comm:NextId() end,
  }
end

function TemplateCommands:ResolveEvent(token)
  local index = tonumber(token)
  local event = index and index % 1 == 0 and ns.EventService.List({ events = self.events })[index] or nil
  if not event then
    return nil, "give the event number from /nrage event."
  end
  return event
end

local ERRORS = {
  ["invalid:name"] = "give a plain-text name (up to 40 characters).",
  empty = "that event has no assignments to save.",
  limit = "you already have the maximum number of templates: delete one first.",
  not_found = "not found.",
}

local function error_line(ctx, reason)
  if reason == "forbidden" then
    return ("not allowed: your guild rank gives the role '%s', which cannot manage assignments."):format(
      tostring(ctx.role))
  end
  return ERRORS[reason] or tostring(reason)
end

function TemplateCommands:List()
  local names = ns.TemplateService.List(self.templates)
  if #names == 0 then
    return { "No templates yet. Save one with /nrage template save <event> <name>." }
  end
  local lines = { ("%d template(s):"):format(#names) }
  for _, name in ipairs(names) do
    lines[#lines + 1] = ("  %s - %d slot(s)"):format(name, #self.templates[name].slots)
  end
  return lines
end

function TemplateCommands:Show(name)
  local template = self.templates[name]
  if not template then
    return { ("no template called '%s'."):format(name) }
  end
  local lines = { ("Template '%s':"):format(name) }
  for _, slot in ipairs(template.slots) do
    local task = slot.task and (" - " .. slot.task) or ""
    lines[#lines + 1] = ("  %s: %s%s"):format(slot.encounter, slot.characterKey, task)
  end
  return lines
end

function TemplateCommands:Save(args)
  local token, name = args:match("^(%S*)%s*(.-)$")
  local event, problem = self:ResolveEvent(token)
  if not event then
    return { problem }
  end
  local ctx = self:Context()
  local template, reason = ns.TemplateService.Save(self.templates, event, name, ctx.now(), ctx.actor)
  if not template then
    return { error_line(ctx, reason) }
  end
  return { ("saved '%s' with %d slot(s)."):format(template.name, #template.slots) }
end

function TemplateCommands:Apply(args)
  local token, name = args:match("^(%S*)%s*(.-)$")
  local event, problem = self:ResolveEvent(token)
  if not event then
    return { problem }
  end
  local ctx = self:Context()
  local created, skipped = ns.TemplateService.Apply(ctx, self.templates, name, event.eventId)
  if not created then
    return { error_line(ctx, skipped) }
  end

  local lines = { ns.TemplateService.Describe(created, skipped) .. "." }
  local unsent = 0
  for _, assignment in ipairs(created) do
    if not self.comm:SendAssignment(event.eventId, assignment) then
      unsent = unsent + 1
    end
  end
  if unsent > 0 then
    lines[#lines + 1] = ("saved here, but %d assignment(s) could not be sent to the guild."):format(unsent)
  end
  return lines
end

function TemplateCommands:Template(rest)
  local sub, args = rest:match("^(%S*)%s*(.-)$")
  if sub == "" or sub == "list" then
    return self:List()
  end
  if sub == "show" then
    return self:Show(args)
  end
  if sub == "save" then
    return self:Save(args)
  end
  if sub == "apply" then
    return self:Apply(args)
  end
  if sub == "delete" then
    local ok, reason = ns.TemplateService.Delete(self.templates, args)
    if not ok then
      return { error_line(self:Context(), reason) }
    end
    return { ("deleted '%s'."):format(args) }
  end
  return USAGE
end

ns.TemplateCommands = TemplateCommands
