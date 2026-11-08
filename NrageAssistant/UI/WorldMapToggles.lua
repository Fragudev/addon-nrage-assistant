local _, ns = ...

-- Two small buttons on the world map: "Guild" shows or hides the guildmates and "Enemies" the enemies Intel
-- reports. They are the same two settings as the checkboxes of the panels, only closer to hand: what each button
-- shows and what a click does is decided here by plain functions, and the frames are built on the client only.
local WorldMapToggles = {}

local L = ns.L

local SIZE = 32
local GAP = 6
local INSET = 12
local RING_WIDTH = 2
-- The glyph fills this share of the disc, leaving the ring and some air around it.
local GLYPH_SHARE = 0.55
-- The addon's own anti-aliased disc (the kit's "disc" icon), the same technique as the map pins: a tinted disc with
-- a smaller solid disc over it leaves a clean round ring, with no mask texture to keep in step.
local DISC_TEXTURE = "Interface\\AddOns\\NrageAssistant\\Media\\Icons\\disc"

WorldMapToggles.SIZE = SIZE

-- Where a button sits on the right edge of the map canvas: { point, relPoint, x, y } for SetPoint, or nil for an
-- unknown button. Guild is above Enemies and the pair is centred on the edge, a little inward from it.
function WorldMapToggles.Layout(which)
  local step = (SIZE + GAP) / 2
  local y = (which == "guild" and step) or (which == "enemies" and -step)
  if not y then
    return nil
  end
  return { point = "RIGHT", relPoint = "RIGHT", x = -INSET, y = y }
end

-- Theme tokens of a button: the ring and the glyph are lit when on and muted when off; the fill behind the glyph is
-- always the same opaque colour, so the button reads over any map texture.
function WorldMapToggles.Look(on)
  local token = on and "accent" or "muted"
  return { ring = token, glyph = token, fill = "controlSolid" }
end

-- What both buttons show. args = { guild (the guildmates are shown), enemies (the Intel pins are shown) }. Returns
-- { guild = button, enemies = button }, each { on, label, icon, color, tooltip = { title, text } }. The colour is the
-- visual state: lit when on, dim when off.
function WorldMapToggles.State(args)
  local guild, enemies = args.guild == true, args.enemies == true
  return {
    guild = {
      on = guild,
      label = L("Guild"),
      icon = "users",
      color = guild and "accent" or "muted",
      tooltip = {
        L("Guildmates on the map"),
        guild and L("Click to hide guildmates on the world map.") or L("Click to show guildmates on the world map."),
      },
    },
    enemies = {
      on = enemies,
      label = L("Enemies"),
      icon = "swords",
      color = enemies and "accent" or "muted",
      tooltip = {
        L("Intel enemies on the map"),
        enemies and L("Click to hide the enemies reported by Intel on the world map.")
          or L("Click to show the enemies reported by Intel on the world map."),
      },
    },
  }
end

-- A click: flips the setting behind `which` ("guild" | "enemies") and returns the new value, or nil for any other
-- name. env = { position (PositionModel.Settings), intel (Settings.Intel), setPositionDisplay(which, on),
-- requestEnemies() }. The guild one goes through the setter the checkbox uses, so both stay one setting.
function WorldMapToggles.Toggle(which, env)
  if which == "guild" then
    local on = env.position.worldmap ~= true
    env.setPositionDisplay("worldmap", on)
    return on
  elseif which == "enemies" then
    local on = env.intel.worldmapPins ~= true
    env.intel.worldmapPins = on
    env.requestEnemies()
    return on
  end
  return nil
end

-- ---------------------------------------------------------------------------------------------------------------
-- The frames (client only)

local buttons, hooked

local function environment()
  return {
    position = ns.PositionModel.Settings(ns.db),
    intel = ns.Settings.Intel(ns.db),
    setPositionDisplay = ns.SetPositionDisplay,
    requestEnemies = function()
      if ns.intelMapPins then
        ns.intelMapPins:Request()
      end
    end,
  }
end

local function tint(texture, token, alpha)
  texture:SetVertexColor(ns.Kit.Theme.Color(token, alpha))
end

-- Draws one button from its state: the ring, the glyph and the tooltip text.
local function dress(widget, look, on)
  local colors = WorldMapToggles.Look(on)
  tint(widget.ring, colors.ring)
  tint(widget.fill, colors.fill)
  ns.Kit.Icons.Apply(widget.glyph, look.icon, colors.glyph)
  widget.tooltip = look.tooltip[1] .. "\n" .. look.tooltip[2]
end

-- Draws both buttons again from the settings.
function WorldMapToggles.Refresh()
  if not (buttons and ns.db) then
    return
  end
  local env = environment()
  local state = WorldMapToggles.State({ guild = env.position.worldmap, enemies = env.intel.worldmapPins })
  for which, widget in pairs(buttons) do
    dress(widget, state[which], state[which].on)
  end
end

local function buildButton(parent, which)
  local frame = CreateFrame("Button", nil, parent)
  frame:SetSize(SIZE, SIZE)
  frame:RegisterForClicks("LeftButtonUp")
  local widget = { frame = frame }
  widget.ring = frame:CreateTexture(nil, "BACKGROUND")
  widget.ring:SetAllPoints(frame)
  widget.ring:SetTexture(DISC_TEXTURE)
  widget.fill = frame:CreateTexture(nil, "BORDER")
  widget.fill:SetPoint("TOPLEFT", frame, "TOPLEFT", RING_WIDTH, -RING_WIDTH)
  widget.fill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -RING_WIDTH, RING_WIDTH)
  widget.fill:SetTexture(DISC_TEXTURE)
  widget.glyph = frame:CreateTexture(nil, "ARTWORK")
  widget.glyph:SetPoint("CENTER")
  widget.glyph:SetSize(math.floor(SIZE * GLYPH_SHARE), math.floor(SIZE * GLYPH_SHARE))
  widget.highlight = frame:CreateTexture(nil, "HIGHLIGHT")
  widget.highlight:SetAllPoints(frame)
  widget.highlight:SetTexture(DISC_TEXTURE)
  widget.highlight:SetVertexColor(1, 1, 1, 0.15)
  frame:SetScript("OnEnter", function()
    if widget.tooltip and GameTooltip then
      -- The buttons hug the right edge of the map, so the tooltip opens to the left, over the map.
      GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
      GameTooltip:SetText(widget.tooltip)
      GameTooltip:Show()
    end
  end)
  frame:SetScript("OnLeave", function()
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  frame:SetScript("OnClick", function()
    if ns.active and ns.db then
      WorldMapToggles.Toggle(which, environment())
      WorldMapToggles.Refresh()
    end
  end)
  local place = WorldMapToggles.Layout(which)
  frame:ClearAllPoints()
  frame:SetPoint(place.point, parent, place.relPoint, place.x, place.y)
  frame:SetFrameLevel(parent:GetFrameLevel() + 10)
  return widget
end

local function build(parent)
  buttons = {}
  for _, which in ipairs({ "guild", "enemies" }) do
    buttons[which] = buildButton(parent, which)
  end
end

-- Builds the buttons on the world map and keeps them in step with the settings. Does nothing, and never raises,
-- when the world map or the kit is missing. Runs once.
function WorldMapToggles.Start()
  if buttons or not (WorldMapFrame and ns.Kit and ns.Kit.Icons and ns.Kit.Theme) then
    return
  end
  local parent = WorldMapFrame.ScrollContainer or WorldMapFrame
  local ok = pcall(build, parent)
  if not ok then
    buttons = nil
    return
  end
  if not hooked and WorldMapFrame.HookScript then
    hooked = true
    -- The map keeps its own state between openings, so the buttons are drawn again each time it opens.
    WorldMapFrame:HookScript("OnShow", function()
      pcall(WorldMapToggles.Refresh)
    end)
  end
  WorldMapToggles.Refresh()
end

-- The button tables ({ frame, ring, fill, glyph, highlight }) keyed "guild" and "enemies", or nil before they were
-- made (for the tests).
function WorldMapToggles.Widgets()
  return buttons
end

-- Forgets the frames (for the tests).
function WorldMapToggles.Reset()
  buttons, hooked = nil, nil
end

ns.WorldMapToggles = WorldMapToggles
