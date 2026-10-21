local _, ns = ...

-- The view model of the guild map: which pins to draw, from what the directory, the guild roster and the layers know.
-- Pure; the clock and every lookup are injected.
--
-- ctx = { list = { { name, map, x, y, at } } (PositionDirectory:List()),
--         now = function() -> seconds (monotonic),
--         lookup = function(name) -> { class, level } or nil (the guild roster),
--         profile = function(name) -> { class, level } or nil (a received profile; optional),
--         ownLayer = { map, layer } or nil,
--         layerOf = function(name) -> { map, layer } or nil (optional),
--         isGroupMember = function(name) -> boolean (optional),
--         settings = { minimap, worldmap } }
--
-- Each pin is { key, name, class, level, map, x, y, layer, sameLayer, age } with x and y as zone coordinates 0..1.
-- `layer` is nil when the member's layer is unknown and `sameLayer` when either layer is unknown, so the pin is drawn
-- normally.
local PositionPins = {}

local function text(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function safeCall(fn, ...)
  if not fn then
    return nil
  end
  local ok, result = pcall(fn, ...)
  return ok and result or nil
end

function PositionPins.Build(ctx)
  local settings = ctx.settings or {}
  local pins = {}
  if settings.minimap == false and settings.worldmap == false then
    return pins
  end
  local now = ctx.now()
  for _, entry in ipairs(ctx.list or {}) do
    local member = ctx.lookup(entry.name)
    -- Someone who left the guild, and the party or raid the client already shows, get no pin.
    if member and not safeCall(ctx.isGroupMember, entry.name) then
      local profile = safeCall(ctx.profile, entry.name) or {}
      local x, y = ns.PositionModel.ToZone(entry.x, entry.y)
      if x then
        local theirs = safeCall(ctx.layerOf, entry.name)
        local layer, sameLayer = theirs and theirs.layer, nil
        if theirs and ctx.ownLayer then
          sameLayer = ns.LayerModel.SameLayer(ctx.ownLayer, theirs)
        end
        pins[#pins + 1] = {
          key = entry.name,
          name = entry.name,
          class = text(member.class) or text(profile.class),
          level = member.level or profile.level,
          map = entry.map,
          x = x,
          y = y,
          layer = layer,
          sameLayer = sameLayer,
          age = math.max(0, now - entry.at),
        }
      end
    end
  end
  return pins
end

ns.PositionPins = PositionPins
