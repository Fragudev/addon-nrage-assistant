local _, ns = ...

-- Pure helpers for layers. A creature GUID has the form
--   Creature-0-<serverId>-<instanceId>-<zoneUid>-<npcId>-<spawnUid>   (also Vehicle-)
-- and on layered realms `zoneUid` identifies the layer within one continent while `instanceId` is the map. So the
-- layer key is the pair (map, layer); layers of different maps are never compared. This is an assumption that is
-- still to be measured on Forever (docs/API_NOTES.md), which is why nothing here raises on a surprise.
local LayerModel = {}

local KINDS = { Creature = true, Vehicle = true }

-- { kind, map, layer, npcId, spawnUid } for a creature GUID, or nil for anything else: a player, a pet, a
-- malformed or missing value, or a secret value (which raises when it is inspected). Never raises.
function LayerModel.Parse(guid)
  local ok, parsed = pcall(function()
    if type(guid) ~= "string" then
      return nil
    end
    local kind, instanceId, zoneUid, npcId, spawnUid = guid:match("^(%a+)%-%d+%-%d+%-(%d+)%-(%d+)%-(%d+)%-(%x+)$")
    if not (kind and KINDS[kind]) then
      return nil
    end
    local map, layer = tonumber(instanceId), tonumber(zoneUid)
    -- Zero means "forget me" on the wire, so it is never a layer.
    if
      not (ns.Validate.Int(map, 0, ns.Constants.LAYER_MAP_MAX) and ns.Validate.Int(layer, 1, ns.Constants.LAYER_ID_MAX))
    then
      return nil
    end
    return { kind = kind, map = map, layer = layer, npcId = tonumber(npcId), spawnUid = spawnUid }
  end)
  if ok then
    return parsed
  end
  return nil
end

function LayerModel.Key(map, layer)
  return ("%d:%d"):format(map, layer)
end

-- Do two { map, layer } tables name the same layer? Anything that is not such a table is not the same.
function LayerModel.SameLayer(a, b)
  return type(a) == "table" and type(b) == "table" and a.map == b.map and a.layer == b.layer and a.layer ~= nil
end

-- The label shown for a layer: "#" plus the last four digits of the zone id, because the id is not readable as
-- "layer 1/2/3".
function LayerModel.Describe(_, layer)
  if type(layer) ~= "number" then
    return "#????"
  end
  return ("#%04d"):format(layer % 10000)
end

-- The layer settings, created and repaired as needed: { share = boolean }. Sharing is on until the player turns it
-- off. Defaults live here and not in a schema migration, like the minimap settings.
function LayerModel.Settings(db)
  db.global.settings = type(db.global.settings) == "table" and db.global.settings or {}
  local settings = db.global.settings
  settings.layer = type(settings.layer) == "table" and settings.layer or {}
  settings.layer.share = settings.layer.share ~= false
  return settings.layer
end

ns.LayerModel = LayerModel
