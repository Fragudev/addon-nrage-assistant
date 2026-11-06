local _, ns = ...

-- Applies received Groups messages (docs/LFG_PLAN.md 4). Live only, nothing is saved.
--
--   * LFG_POST: the post of the sender, handed to the service, which keeps it on the board. The owner is always the
--     `sender`.
--   * LFG_APPLY: one step of an application. The actor is always the `sender`; a name in the payload (`to`) is only
--     data, compared by the service.
--
-- Both need a sender the local guild roster knows (action lfg_use). Every function returns true, or false plus
-- "unknown_sender" | "forbidden" | "unsupported" | the reason of the service.
--
-- ctx = { service = LfgService }
local LfgSync = {}

local authorize = ns.SyncRules.Authorize

local function applyPost(ctx, payload, sender, role)
  local denied = authorize(role, "lfg_use")
  if denied then
    return false, denied
  end
  if not ctx.service then
    return false, "unsupported"
  end
  return ctx.service:OnPost(sender, payload)
end

local function applyStep(ctx, payload, sender, role)
  local denied = authorize(role, "lfg_use")
  if denied then
    return false, denied
  end
  if not ctx.service then
    return false, "unsupported"
  end
  return ctx.service:OnApply(sender, payload)
end

local APPLIERS = { LFG_POST = applyPost, LFG_APPLY = applyStep }

function LfgSync.IsLfgMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` is who sent it; `role` is theirs, from the roster.
function LfgSync.Apply(ctx, message, sender, role)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role)
end

ns.LfgSync = LfgSync
