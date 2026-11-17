local _, ns = ...

-- The slash commands of the guild LFG (`/nrage lfg ...`). Each method returns the lines to show, so the whole
-- thing is testable without a client. The icon preview is local-only: it forces the floating Groups button to
-- appear without creating a group or sending anything to the guild.
--   deps: groupsIcon (GroupsIcon, with SetAlwaysShow and AlwaysShow)
local LfgCommands = {}
LfgCommands.__index = LfgCommands

local L = ns.L

function LfgCommands.New(deps)
  return setmetatable({
    groupsIcon = deps.groupsIcon,
  }, LfgCommands)
end

-- The available LFG commands, also shown when `/nrage lfg help` is typed.
function LfgCommands.Usage()
  return {
    L("/nrage lfg icon show | hide | toggle  control the Groups icon visibility"),
  }
end

-- Runs the text that follows `/nrage lfg` and returns the lines to show. Command words are case-insensitive.
function LfgCommands:Run(text)
  local args = {}

  for word in (text or ""):gmatch("%S+") do
    args[#args + 1] = word:lower()
  end

  local command = args[1] or ""
  local action = args[2] or ""

  if command == "" or command == "help" then
    return LfgCommands.Usage()
  end

  if command ~= "icon" then
    return LfgCommands.Usage()
  end

  local icon = self.groupsIcon

  if not icon then
    return { L("Groups icon is not available.") }
  end

  -- Overrides only the local icon visibility; the real LFG board and its posts are left unchanged.
  if action == "show" then
    icon.SetAlwaysShow(true)
  elseif action == "hide" then
    icon.SetAlwaysShow(false)
  elseif action == "toggle" then
    icon.SetAlwaysShow(not icon.AlwaysShow())
  else
    return LfgCommands.Usage()
  end

  return {
    L("Groups icon preview: %s"):format(icon.AlwaysShow() and "ON" or "OFF"),
  }
end

ns.LfgCommands = LfgCommands
