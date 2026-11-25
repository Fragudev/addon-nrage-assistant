local _, ns = ...

-- The view model of the guild map: which pins to draw, from what the directory, the guild roster and the received
-- profiles know.
-- Pure; the clock and every lookup are injected.
--
-- ctx = { list = { { name, map, x, y, at } } (PositionDirectory:List()),
--         now = function() -> seconds (monotonic),
--         lookup = function(name) -> { class, level } or nil (the guild roster),
--         profile = function(name) -> { class, level } or nil (a received profile; optional),
--         isGroupMember = function(name) -> boolean (optional),
--         settings = { minimap, worldmap } }
--
-- Each pin is { key, name, class, level, map, x, y, age } with x and y as zone coordinates 0..1.
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
        pins[#pins + 1] = {
          key = entry.name,
          name = entry.name,
          class = text(member.class) or text(profile.class),
          level = member.level or profile.level,
          map = entry.map,
          x = x,
          y = y,
          age = math.max(0, now - entry.at),
        }
      end
    end
  end
  return pins
end

ns.PositionPins = PositionPins
