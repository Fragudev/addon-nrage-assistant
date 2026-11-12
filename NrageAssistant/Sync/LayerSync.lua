local _, ns = ...

-- Applies received layer messages and builds the payloads for them.
--
--   * LAYER_STATE: the sender's own layer, kept in the directory (in memory only, never in a snapshot).
--   * LAYER_SWAP: one step of a swap, handed to the swap flow. The actor is always the `sender`; a name in the
--     payload (the helper of an `assign`) is only data, compared by the flow.
--
-- Both need a sender the local guild roster knows (action layer_share). Every function returns true, or false plus
-- "unknown_sender" | "forbidden" | "unsupported" | the reason of the directory or the swap flow.
--
-- ctx = { directory = LayerDirectory, swap = LayerSwap }
local LayerSync = {}

local authorize = ns.SyncRules.Authorize

local function applyState(ctx, payload, sender, role)
  local denied = authorize(role, "layer_share")
  if denied then
    return false, denied
  end
  if not ctx.directory then
    return false, "unsupported"
  end
  return ctx.directory:Apply(sender, payload)
end

local function applySwap(ctx, payload, sender, role)
  local denied = authorize(role, "layer_share")
  if denied then
    return false, denied
  end
  if not ctx.swap then
    return false, "unsupported"
  end
  return ctx.swap:OnMessage(sender, payload)
end

local APPLIERS = { LAYER_STATE = applyState, LAYER_SWAP = applySwap }

function LayerSync.IsLayerMessage(messageType)
  return APPLIERS[messageType] ~= nil
end

-- `message` must already be validated by Protocol. `sender` is who sent it; `role` is theirs, from the roster.
function LayerSync.Apply(ctx, message, sender, role)
  local applier = APPLIERS[message.t]
  if not applier then
    return false, "unsupported"
  end
  return applier(ctx, message.p, sender, role)
end

-- The payload of the own layer ({ map, layer, zone } as the tracker gives it), or nil when it is not known.
function LayerSync.StatePayload(current)
  if type(current) ~= "table" then
    return nil
  end
  return { map = current.map, layer = current.layer, zone = current.zone }
end

-- "Forget me": sent when the player stops sharing.
function LayerSync.ForgetPayload()
  return { map = 0, layer = 0 }
end

ns.LayerSync = LayerSync
