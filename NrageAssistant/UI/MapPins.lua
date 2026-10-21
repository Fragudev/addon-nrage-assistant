local _, ns = ...

-- The guildmates on the minimap and the world map. This is the only file that touches HereBeDragons: it places a
-- pooled pin frame per guildmate through the library's icon calls, and does nothing when the library is missing.
-- The decisions (pooling, which maps, coalescing) are apart from the frames so they can be tested with fakes; the
-- frames themselves (BuildPin) are client-only.
local MapPins = {}

local L = ns.L

local MINIMAP_SIZE, WORLDMAP_SIZE = 12, 14
local CLASS_TEXTURE = "Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES"
local DOT_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local GREY = { 0.5, 0.5, 0.5 }
local GREEN = { 0.3, 1, 0.3 }

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

-- The colour of a class token as { r, g, b }, or grey when it is unknown.
local function classColor(class)
  local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  if color then
    return { color.r, color.g, color.b }
  end
  return GREY
end

-- Dresses a pin frame for `pin`: the class icon with a thin border in the class colour, or a grey dot when the class
-- is unknown, and half transparent when the member is on another layer.
function MapPins.DressPin(frame, pin)
  frame.pin = pin
  local coords = pin.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[pin.class]
  local color = classColor(pin.class)
  frame.border:SetColorTexture(color[1], color[2], color[3], 1)
  if coords then
    frame.icon:SetTexture(CLASS_TEXTURE)
    frame.icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    frame.icon:SetVertexColor(1, 1, 1, 1)
  else
    frame.icon:SetTexture(DOT_TEXTURE)
    frame.icon:SetTexCoord(0, 1, 0, 1)
    frame.icon:SetVertexColor(GREY[1], GREY[2], GREY[3], 1)
  end
  frame:SetAlpha(pin.sameLayer == false and 0.5 or 1)
end

local function showTooltip(frame)
  local pin = frame.pin
  if not (pin and GameTooltip) then
    return
  end
  GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
  local color = classColor(pin.class)
  GameTooltip:AddLine(pin.name, color[1], color[2], color[3])
  for _, line in ipairs(MapPins.TooltipLines(pin)) do
    local tint = line.green and GREEN or { 1, 1, 1 }
    GameTooltip:AddLine(line.text, tint[1], tint[2], tint[3])
  end
  GameTooltip:Show()
end

-- A new pin frame of `kind` ("minimap" or "worldmap"): a border square with the icon inside. Client only.
function MapPins.BuildPin(kind)
  local size = kind == "minimap" and MINIMAP_SIZE or WORLDMAP_SIZE
  local frame = CreateFrame("Frame", nil, UIParent)
  frame:SetSize(size, size)
  frame:EnableMouse(true)
  frame.border = frame:CreateTexture(nil, "BACKGROUND")
  frame.border:SetAllPoints(frame)
  frame.icon = frame:CreateTexture(nil, "ARTWORK")
  frame.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
  frame.icon:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
  frame:SetScript("OnEnter", showTooltip)
  frame:SetScript("OnLeave", function()
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  return frame
end

-- The decisions, apart from the frames so they can be tested with fakes.
--   deps: hbd (HereBeDragons-Pins-2.0, or nil: then nothing is drawn), ref (the key the library files the icons under),
--         newPin(kind) -> frame, dress(frame, pin), worldFlag (what to pass for the world map display);
--         for Request: now() -> seconds, after(seconds, fn), pins() -> the pins to draw, settings() -> { minimap,
--         worldmap }
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
    if index > ns.Constants.POSITION_DIRECTORY_MAX then
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
    self:Redraw(self.deps.pins(), self.deps.settings())
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

ns.MapPins = MapPins
