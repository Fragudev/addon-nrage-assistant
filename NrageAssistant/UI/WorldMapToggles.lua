local _, ns = ...

-- Two small buttons on the world map: "Guild" shows or hides the guildmates and "Enemies" the enemies Intel
-- reports. They are the same two settings as the checkboxes of the panels, only closer to hand: what each button
-- shows and what a click does is decided here by plain functions, and the frames are built on the client only.
local WorldMapToggles = {}

local L = ns.L

local SIZE = 22
local GAP = 4

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

-- Draws both buttons again from the settings.
function WorldMapToggles.Refresh()
  if not (buttons and ns.db) then
    return
  end
  local env = environment()
  local state = WorldMapToggles.State({ guild = env.position.worldmap, enemies = env.intel.worldmapPins })
  for which, widget in pairs(buttons) do
    local look = state[which]
    widget.opts.icon = look.icon
    widget.opts.color = look.color
    widget.opts.tooltip = look.tooltip[1] .. "\n" .. look.tooltip[2]
    widget:refresh()
  end
end

local function build(parent)
  buttons = {}
  local previous
  for _, which in ipairs({ "enemies", "guild" }) do
    local widget = ns.Kit.IconButton(parent, {
      icon = which == "guild" and "users" or "swords",
      size = SIZE,
      variant = "secondary",
      onClick = function()
        if ns.active and ns.db then
          WorldMapToggles.Toggle(which, environment())
          WorldMapToggles.Refresh()
        end
      end,
    })
    widget:Layout(SIZE)
    widget.frame:ClearAllPoints()
    if previous then
      widget.frame:SetPoint("RIGHT", previous, "LEFT", -GAP, 0)
    else
      -- Inside the map canvas, a little in from the top right, clear of the Blizzard controls on the title bar.
      widget.frame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -12, -12)
    end
    widget.frame:SetFrameLevel(parent:GetFrameLevel() + 10)
    previous = widget.frame
    buttons[which] = widget
  end
end

-- Builds the buttons on the world map and keeps them in step with the settings. Does nothing, and never raises,
-- when the world map or the kit is missing. Runs once.
function WorldMapToggles.Start()
  if buttons or not (WorldMapFrame and ns.Kit and ns.Kit.IconButton) then
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

-- The kit widgets keyed "guild" and "enemies", or nil before they were made (for the tests).
function WorldMapToggles.Widgets()
  return buttons
end

-- Forgets the frames (for the tests).
function WorldMapToggles.Reset()
  buttons, hooked = nil, nil
end

ns.WorldMapToggles = WorldMapToggles
