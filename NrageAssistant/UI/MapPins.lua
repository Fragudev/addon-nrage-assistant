local _, ns = ...

-- The guildmates and the enemy players on the minimap and the world map. This is the only file that touches
-- HereBeDragons: it places a pooled pin frame per pin through the library's icon calls, and does nothing when the
-- library is missing. The enemy pins (docs/PVP_INTEL_PLAN.md section 3.4) have a pool and a library key of their own,
-- so redrawing one set never removes the other.
-- A pin is a round class icon inside a ring: the ring carries the signal (the class colour, red for an enemy, grey when
-- the pin is on another layer) and the pin is always fully opaque, so it stays readable over any map.
-- The decisions (pooling, which maps, coalescing) are apart from the frames so they can be tested with fakes; the
-- frames themselves (BuildPin) are client-only.
local MapPins = {}

local L = ns.L

local MINIMAP_SIZE, WORLDMAP_SIZE = 12, 14
local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local DOT_TEXTURE = "Interface\\Buttons\\WHITE8X8"
-- The ring is the addon's own anti-aliased disc (the kit's "disc" icon) tinted at runtime: a solid disc behind a
-- smaller masked icon leaves a clean round ring, with no second mask to keep in step.
local RING_TEXTURE = "Interface\\AddOns\\NrageAssistant\\Media\\Icons\\disc"
local MASK_TEXTURE = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
-- How much of each side of a class cell is cut away, so the square frame baked into the atlas does not show.
local CROP = 0.08
local RING_WIDTH = 2
local GREY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.3, 1, 0.3 }
local RED = { 1, 0.35, 0.35 }

-- What the tooltip says under the name: { text, green } rows, in order. A layer that is unknown is left out.
function MapPins.TooltipLines(pin)
  local lines = {}
  if type(pin.level) == "number" then
    lines[#lines + 1] = { text = L("Level %d"):format(pin.level) }
  end
  if type(pin.layer) == "number" then
    lines[#lines + 1] = {
      text = L("Layer %s"):format(ns.LayerModel.Describe(nil, pin.layer)),
      green = pin.sameLayer == true,
    }
  end
  lines[#lines + 1] = { text = L("%d s ago"):format(math.floor(pin.age or 0)) }
  return lines
end

-- What the tooltip of an enemy pin says under the name: { text, green, red } rows, in order. `pin` = a pin of
-- IntelPins. The position is the reporter's, and the tooltip says who the reporter is.
function MapPins.EnemyTooltipLines(pin)
  local lines = {}
  local detail = {}
  if type(pin.level) == "number" then
    detail[#detail + 1] = L("Level %d"):format(pin.level) .. (pin.levelEstimated and "?" or "")
  end
  local class = ns.IntelModel.ClassName(pin.class)
  if class then
    detail[#detail + 1] = class
  end
  if #detail > 0 then
    lines[#lines + 1] = { text = table.concat(detail, " ") }
  end
  if pin.kos then
    lines[#lines + 1] = { text = L("Kill on Sight"), red = true }
  end
  if pin.stealth then
    lines[#lines + 1] = { text = L("Used a stealth ability") }
  end
  if pin.reporter then
    lines[#lines + 1] = { text = L("Reported by %s"):format((pin.reporter:gsub("%-[^%-]*$", ""))) }
  else
    lines[#lines + 1] = { text = L("Seen by you") }
  end
  if type(pin.layer) == "number" then
    lines[#lines + 1] = {
      text = L("Layer %s"):format(ns.LayerModel.Describe(nil, pin.layer)),
      green = pin.sameLayer == true,
    }
  end
  lines[#lines + 1] = { text = L("%d s ago"):format(math.floor(pin.age or 0)) }
  return lines
end

-- The colour of a class token as { r, g, b }, or grey when it is unknown.
local function classColor(class)
  local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if color then
    return { color.r, color.g, color.b }
  end
  return GREY
end

local function setRing(frame, color)
  frame.border:SetVertexColor(color[1], color[2], color[3], 1)
end

-- Dresses a pin frame for `pin`: the round class icon (or a round grey dot when the class is unknown) inside a ring in
-- the class colour, and a grey ring when the member is on another layer. The pin is never transparent.
function MapPins.DressPin(frame, pin)
  frame.pin = pin
  local coords = pin.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[pin.class]
  frame.border:SetTexture(RING_TEXTURE)
  setRing(frame, pin.sameLayer == false and GREY or classColor(pin.class))
  if coords then
    local inset = (coords[2] - coords[1]) * CROP
    local vinset = (coords[4] - coords[3]) * CROP
    frame.icon:SetTexture(CLASS_TEXTURE)
    frame.icon:SetTexCoord(coords[1] + inset, coords[2] - inset, coords[3] + vinset, coords[4] - vinset)
    frame.icon:SetVertexColor(1, 1, 1, 1)
  else
    frame.icon:SetTexture(DOT_TEXTURE)
    frame.icon:SetTexCoord(0, 1, 0, 1)
    frame.icon:SetVertexColor(GREY[1], GREY[2], GREY[3], 1)
  end
  frame:SetAlpha(1)
end

-- Dresses a pin frame for an enemy: the class icon in a red ring (grey when the reporter is on another layer), and a
-- mark when the enemy is on a Kill on Sight list.
function MapPins.DressEnemyPin(frame, pin)
  MapPins.DressPin(frame, pin)
  frame.enemy = true
  setRing(frame, pin.sameLayer == false and GREY or RED)
  if frame.mark then
    frame.mark:SetText(pin.kos and "!" or "")
  end
end

local function showTooltip(frame)
  local pin = frame.pin
  if not (pin and GameTooltip) then
    return
  end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  local color = classColor(pin.class)
  GameTooltip:AddLine(pin.name, color[1], color[2], color[3])
  local lines = frame.enemy and MapPins.EnemyTooltipLines(pin) or MapPins.TooltipLines(pin)
  for _, line in ipairs(lines) do
    local tint = (line.green and GREEN) or (line.red and RED) or { 1, 1, 1 }
    GameTooltip:AddLine(line.text, tint[1], tint[2], tint[3])
  end
  GameTooltip:Show()
end

-- A new pin frame of `kind` ("minimap" or "worldmap"): a ring disc with the round icon inside. Client only.
function MapPins.BuildPin(kind)
  local size = kind == "minimap" and MINIMAP_SIZE or WORLDMAP_SIZE
  local frame = CreateFrame("Frame", nil, UIParent)
  frame:SetSize(size, size)
  frame:EnableMouse(true)
  frame.border = frame:CreateTexture(nil, "BACKGROUND")
  frame.border:SetAllPoints(frame)
  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", RING_WIDTH, -RING_WIDTH)
  frame.icon:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -RING_WIDTH, RING_WIDTH)
  -- Clients and fakes without mask textures keep a square icon; the ring still shows.
  local mask = frame.CreateMaskTexture and frame:CreateMaskTexture()
  if mask then
    mask:SetTexture(MASK_TEXTURE)
    mask:SetAllPoints(frame.icon)
    frame.icon:AddMaskTexture(mask)
    frame.mask = mask
  end
  frame:SetScript("OnEnter", showTooltip)
  frame:SetScript("OnLeave", function()
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  return frame
end

-- A new enemy pin frame: a pin with a mark for the Kill on Sight players. Client only.
function MapPins.BuildEnemyPin(kind)
  local frame = MapPins.BuildPin(kind)
  frame.mark = frame:CreateFontString(nil, "OVERLAY")
  frame.mark:SetFontObject(ns.Kit.Theme.StyleFont("smallMedium"))
  frame.mark:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 3, -3)
  ns.Kit.SetTextColor(frame.mark, "danger")
  return frame
end

-- The decisions, apart from the frames so they can be tested with fakes.
--   deps: hbd (HereBeDragons-Pins-2.0, or nil: then nothing is drawn), ref (the key the library files the icons under),
--         newPin(kind) -> frame, dress(frame, pin), worldFlag (what to pass for the world map display), max (the most
--         pins, default POSITION_DIRECTORY_MAX), follow(map) (optional: an open world map goes to this map);
--         for Request: now() -> seconds, after(seconds, fn), pins() -> the pins to draw, settings() -> { minimap,
--         worldmap, follow }
local Controller = {}
Controller.__index = Controller
MapPins.Controller = Controller

function Controller.New(deps)
  return setmetatable({
    deps = deps,
    pools = { minimap = {}, worldmap = {} },
    pending = false,
    lastAt = nil,
  }, Controller)
end

local function acquire(self, kind, index)
  local pool = self.pools[kind]
  if not pool[index] then
    pool[index] = self.deps.newPin(kind)
  end
  return pool[index]
end

-- Draws `pins` again: every icon is removed and one is added per pin, only on the maps the settings enable. The pool
-- never holds more frames than Constants.POSITION_DIRECTORY_MAX. Returns the number of pins drawn, nil without the
-- library.
function Controller:Redraw(pins, settings)
  local deps = self.deps
  local hbd = deps.hbd
  if not hbd then
    return nil
  end
  hbd:RemoveAllMinimapIcons(deps.ref)
  hbd:RemoveAllWorldMapIcons(deps.ref)
  local drawn = 0
  for index, pin in ipairs(pins) do
    if index > (deps.max or ns.Constants.POSITION_DIRECTORY_MAX) then
      break
    end
    if settings.minimap ~= false then
      local frame = acquire(self, "minimap", index)
      deps.dress(frame, pin)
      hbd:AddMinimapIconMap(deps.ref, frame, pin.map, pin.x, pin.y, true, true)
    end
    if settings.worldmap ~= false then
      local frame = acquire(self, "worldmap", index)
      deps.dress(frame, pin)
      hbd:AddWorldMapIconMap(deps.ref, frame, pin.map, pin.x, pin.y, deps.worldFlag)
    end
    drawn = drawn + 1
  end
  return drawn
end

-- The world map goes to the map of the first pin (the Kill on Sight players first, then the newest), once for each new
-- enemy and map: a map the player moved elsewhere is left alone until something new shows up. `deps.follow` decides
-- whether the map is open.
function Controller:Follow(pins)
  local pin = pins[1]
  if not pin then
    self.followed = nil
    return
  end
  local token = tostring(pin.key) .. ":" .. tostring(pin.map)
  if token ~= self.followed then
    self.followed = token
    if self.deps.follow then
      self.deps.follow(pin.map)
    end
  end
end

-- Asks for a redraw: at most one per Constants.POSITION_REDRAW_SECONDS, however many changes come.
function Controller:Request()
  if self.pending or not self.deps.hbd then
    return
  end
  local wait = 0
  if self.lastAt then
    wait = math.max(0, ns.Constants.POSITION_REDRAW_SECONDS - (self.deps.now() - self.lastAt))
  end
  self.pending = true
  self.deps.after(wait, function()
    self.pending = false
    self.lastAt = self.deps.now()
    local pins, settings = self.deps.pins(), self.deps.settings()
    self:Redraw(pins, settings)
    if settings.follow then
      self:Follow(pins)
    end
  end)
end

-- Builds the controller on the real library. `deps` brings now, after, pins and settings from the caller. Client only.
-- `hbd` is injectable for the same reason as in the tests; the default is the shared LibStub copy.
function MapPins.Start(deps)
  local hbd = deps.hbd
  if hbd == nil and LibStub then
    hbd = LibStub("HereBeDragons-Pins-2.0", true)
  end
  return Controller.New({
    hbd = hbd or nil,
    ref = ns,
    newPin = MapPins.BuildPin,
    dress = MapPins.DressPin,
    worldFlag = HBD_PINS_WORLDMAP_SHOW_CONTINENT,
    now = deps.now,
    after = deps.after,
    pins = deps.pins,
    settings = deps.settings,
  })
end

-- The controller of the enemy pins. `deps` = { now, after, pins, settings, follow, hbd }. Client only.
function MapPins.StartEnemies(deps)
  local hbd = deps.hbd
  if hbd == nil and LibStub then
    hbd = LibStub("HereBeDragons-Pins-2.0", true)
  end
  return Controller.New({
    hbd = hbd or nil,
    -- Its own key: the guild pins are not removed when these are drawn again.
    ref = MapPins.EnemyPins,
    newPin = MapPins.BuildEnemyPin,
    dress = MapPins.DressEnemyPin,
    worldFlag = HBD_PINS_WORLDMAP_SHOW_CONTINENT,
    max = ns.Constants.INTEL_DIRECTORY_MAX,
    now = deps.now,
    after = deps.after,
    pins = deps.pins,
    settings = deps.settings,
    follow = deps.follow,
  })
end

-- The key the library files the enemy icons under.
MapPins.EnemyPins = {}

ns.MapPins = MapPins
