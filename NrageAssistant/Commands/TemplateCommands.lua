local _, ns = ...

-- Assignment templates: keep the assignments of an event as a named template and apply it to another event.
-- Each method returns the lines to show. Applying a template sends each created assignment to the guild like any
-- other assignment; the templates themselves stay on this client.
--   deps: events, templates, platform, comm
local TemplateCommands = {}
TemplateCommands.__index = TemplateCommands

local L = ns.L

function TemplateCommands.New(deps)
  return setmetatable({
    events = deps.events,
    templates = deps.templates,
    platform = deps.platform,
    comm = deps.comm,
    rosters = deps.rosters,
    members = deps.members,
  }, TemplateCommands)
end

function TemplateCommands:Context()
  local platform = self.platform
  return {
    events = self.events,
    role = ns.PermissionService.OwnRole(platform),
    actor = platform.GetIdentityKey(),
    rosterId = ns.RosterService.RosterOf(self.members or {}, self.rosters or {}, platform.GetIdentityKey()),
    now = platform.ServerTime,
    newId = function()
      return self.comm:NextId()
    end,
  }
end

local ERRORS = ns.Locale.Table(function()
  return {
    ["invalid:name"] = L("give a plain-text name (up to 40 characters)."),
    other_roster = L("that template belongs to another roster."),
    empty = L("that event has no assignments to save."),
    limit = L("you already have the maximum number of templates: delete one first."),
    not_found = L("not found."),
  }
end)

local function error_line(ctx, reason)
  if reason == "forbidden" then
    return L("not allowed: your guild rank gives the role '%s', which cannot manage assignments."):format(
      tostring(ctx.role)
    )
  end
  return ERRORS[reason] or tostring(reason)
end

function TemplateCommands:SaveEvent(event, name)
  local ctx = self:Context()
  local template, reason = ns.TemplateService.Save(self.templates, event, name, ctx.now(), ctx.actor)
  if not template then
    return { error_line(ctx, reason) }
  end
  return { L("saved '%s' with %d slot(s)."):format(template.name, #template.slots) }
end

function TemplateCommands:ApplyToEvent(event, name)
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
    lines[#lines + 1] = L("saved here, but %d assignment(s) could not be sent to the guild."):format(unsent)
  end
  return lines
end

function TemplateCommands:Delete(name)
  local ok, reason = ns.TemplateService.Delete(self.templates, name, self:Context())
  if not ok then
    return { error_line(self:Context(), reason) }
  end
  return { L("deleted '%s'."):format(name) }
end

ns.TemplateCommands = TemplateCommands
