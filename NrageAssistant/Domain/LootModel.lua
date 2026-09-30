local _, ns = ...

-- Shape and validation of loot council data: the item, a candidate's declaration, the award reason.
-- Used for local actions now and for received messages later, so both are held to the same rules.
local LootModel = {}

local V = ns.Validate

-- What the candidate wants the item for.
LootModel.NEEDS = { main = true, off = true, other = true }

local MAX_ITEM_ID = 10000000
local MAX_ITEM_NAME = 60
local MAX_SPEC = 30
local MAX_UPGRADE = 60
local MAX_REASON = 100

-- Returns the clean item, or nil plus "invalid:<field>".
function LootModel.ValidateItem(fields)
  if type(fields) ~= "table" then
    return nil, "invalid:fields"
  end
  if not V.Int(fields.itemId, 1, MAX_ITEM_ID) then
    return nil, "invalid:itemId"
  end
  if not V.Text(fields.itemName, MAX_ITEM_NAME) then
    return nil, "invalid:itemName"
  end
  return { itemId = fields.itemId, itemName = fields.itemName }
end

-- A candidate declares spec, need and, optionally, the upgrade they would get.
function LootModel.ValidateCandidate(fields)
  if type(fields) ~= "table" then
    return nil, "invalid:fields"
  end
  if not V.Text(fields.spec, MAX_SPEC) then
    return nil, "invalid:spec"
  end
  if not (type(fields.need) == "string" and LootModel.NEEDS[fields.need]) then
    return nil, "invalid:need"
  end
  local clean = { spec = fields.spec, need = fields.need }
  if fields.upgrade ~= nil then
    if not V.Text(fields.upgrade, MAX_UPGRADE) then
      return nil, "invalid:upgrade"
    end
    clean.upgrade = fields.upgrade
  end
  return clean
end

function LootModel.IsReason(text)
  return V.Text(text, MAX_REASON)
end

function LootModel.IsCharacterKey(key)
  return V.Text(key, 64)
end

ns.LootModel = LootModel
