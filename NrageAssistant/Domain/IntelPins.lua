local _, ns = ...

-- The view model of the enemy pins on the maps (docs/PVP_INTEL_PLAN.md section 3.4): which enemies to draw, from the
-- ones seen here and the sightings the guild shared. Pure; every lookup is injected. It follows PositionPins.
--
-- ctx = { own = { Nearby items of IntelService (own sightings; x and y are the wire integers) },
--         remote = { IntelDirectory:List() entries },
--         now = function() -> seconds (monotonic),
--         mapMode = "all" | "zone" | "continent" | "none", ownMap = the map id the player is on or nil,
--         continentOf = function(map) -> continent map id or nil,
--         ownLayer = { map, layer } or nil, layerOf = function(reporter) -> { map, layer } or nil (optional),
--         kosOf = function(key) -> "personal" | "guild" | nil, isIgnored = function(key) -> boolean (both optional) }
--
-- Each pin is { key, name, class, level, levelEstimated, map, x, y, layer, sameLayer, age, kos, stealth, reporter }
-- with x and y as zone coordinates 0..1. The position is the reporter's, not the enemy's. `reporter` is nil for an
-- enemy seen here. When two sightings name the same enemy, the newest one wins. `sameLayer` is nil when either layer
-- is unknown, so the pin is drawn normally.
local IntelPins = {}

local function safeCall(fn, ...)
  if not fn then
    return nil
  end
  local ok, result = pcall(fn, ...)
  return ok and result or nil
end

-- Does a sighting on `map` pass the map mode?
local function inMode(ctx, map)
  local mode = ctx.mapMode
  if mode == "all" then
    return true
  elseif mode == "zone" then
    return ctx.ownMap ~= nil and map == ctx.ownMap
  elseif mode == "continent" then
    if ctx.ownMap == nil then
      return false
    end
    if map == ctx.ownMap then
      return true
    end
    local mine = safeCall(ctx.continentOf, ctx.ownMap)
    return mine ~= nil and safeCall(ctx.continentOf, map) == mine
  end
  return false
end

local function candidate(ctx, item, age, reporter)
  local key = ns.IntelModel.Key(item.name)
  if not key or ns.IntelModel.CleanName(item.name) ~= item.name or type(item.map) ~= "number" then
    return nil
  end
  if not inMode(ctx, item.map) then
    return nil
  end
  if safeCall(ctx.isIgnored, key) then
    return nil
  end
  local x, y = ns.PositionModel.ToZone(item.x, item.y)
  if not x then
    return nil
  end
  -- The layer of the reporter: the own one for an enemy seen here, else the one the reporter shared (maybe none).
  local theirs = ctx.ownLayer
  if reporter then
    theirs = safeCall(ctx.layerOf, reporter)
  end
  local sameLayer
  if theirs and ctx.ownLayer and reporter then
    sameLayer = ns.LayerModel.SameLayer(ctx.ownLayer, theirs)
  end
  return {
    key = key,
    name = item.name,
    class = item.class,
    level = item.level,
    levelEstimated = item.levelEstimated == true or item.estimated == true,
    map = item.map,
    x = x,
    y = y,
    layer = theirs and theirs.layer or nil,
    sameLayer = sameLayer,
    age = math.max(0, age),
    kos = item.kos or safeCall(ctx.kosOf, key),
    stealth = item.stealth == true,
    reporter = reporter,
  }
end

function IntelPins.Build(ctx)
  local pins = {}
  if ctx.mapMode == "none" or ctx.mapMode == nil then
    return pins
  end
  local now = ctx.now()
  local byKey = {}
  local function consider(pin)
    local held = pin and byKey[pin.key]
    if pin and (not held or pin.age < held.age) then
      byKey[pin.key] = pin
    end
  end
  for _, item in ipairs(ctx.own or {}) do
    -- An enemy seen here that came from a guild sighting only (`source`) is the directory's to draw.
    if not item.source then
      consider(candidate(ctx, item, item.age or 0, nil))
    end
  end
  for _, entry in ipairs(ctx.remote or {}) do
    consider(candidate(ctx, entry, now - entry.at, entry.source))
  end
  for _, pin in pairs(byKey) do
    pins[#pins + 1] = pin
  end
  table.sort(pins, function(a, b)
    if (a.kos ~= nil) ~= (b.kos ~= nil) then
      return a.kos ~= nil
    end
    if a.age ~= b.age then
      return a.age < b.age
    end
    return a.key < b.key
  end)
  for index = #pins, ns.Constants.INTEL_DIRECTORY_MAX + 1, -1 do
    pins[index] = nil
  end
  return pins
end

ns.IntelPins = IntelPins
