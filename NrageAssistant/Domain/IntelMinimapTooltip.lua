local _, ns = ...

-- The tooltip of the minimap (docs/PVP_INTEL_PLAN.md section 3.4): when the cursor rests on the dots of players, the
-- game lists their names. Intel adds the level and class of the enemies it knows and, when asked, adds them to Nearby.
-- Pure: the lines are read by the interface and handed over as plain tables. What the client prints on that tooltip
-- has not been measured (M11), so a line that is not a clean name is left alone.
--
--   Parse(lines)           the names found in `lines` = { { text, r, g, b } ... } (r, g, b optional)
--   Plan(names, service, settings)   what to add: { extras = { { index, name, text } }, feed = { details } }
local IntelMinimapTooltip = {}

-- A line coloured as a hostile unit: strongly red, little green and blue.
local function hostileColor(r, g, b)
  return type(r) == "number" and type(g) == "number" and type(b) == "number" and r >= 0.8 and g <= 0.45 and b <= 0.45
end

-- The text of a line without colour codes and textures, trimmed.
local function plainText(text)
  local plain = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", "")
  return plain:match("^%s*(.-)%s*$")
end

-- The hostile colour a line sets with a colour code (|cffff0000), when it does.
local function codedHostile(text)
  local r, g, b = text:match("|cff(%x%x)(%x%x)(%x%x)")
  if not r then
    return false
  end
  return hostileColor(tonumber(r, 16) / 255, tonumber(g, 16) / 255, tonumber(b, 16) / 255)
end

-- The names in `lines`, each as { index (the line), name, hostile }. A line that holds anything but one clean name is
-- skipped (a level line, a guild line, a title). `hostile` says the line was drawn in the colour of an enemy.
function IntelMinimapTooltip.Parse(lines)
  local found = {}
  if type(lines) ~= "table" then
    return found
  end
  for index, line in ipairs(lines) do
    if type(line) == "table" and type(line.text) == "string" and #line.text <= 120 then
      local name = ns.IntelModel.CleanName(plainText(line.text))
      if name and not name:find("%s") then
        found[#found + 1] = {
          index = index,
          name = name,
          hostile = hostileColor(line.r, line.g, line.b) or codedHostile(line.text),
        }
      end
    end
  end
  return found
end

-- "Level 60 Warrior" from what a record holds; nil when it holds neither.
local function describe(record)
  local parts = {}
  if type(record.level) == "number" and record.level > 0 then
    parts[#parts + 1] = ns.L("Level %d"):format(record.level) .. (record.levelEstimated and "?" or "")
  end
  local class = ns.IntelModel.ClassName(record.class)
  if class then
    parts[#parts + 1] = class
  end
  return #parts > 0 and table.concat(parts, " ") or nil
end

-- What to add for the names `Parse` found. `settings` = Settings.Intel. A name the service knows gets its level and
-- class on a line of its own (`extras`, in the order of the tooltip). With `minimapFeed` the enemies go to Nearby
-- (`feed`: the details IntelService:OnSeen takes): the ones drawn in an enemy colour, and the ones already known.
function IntelMinimapTooltip.Plan(names, service, settings)
  local plan = { extras = {}, feed = {} }
  if type(names) ~= "table" or type(settings) ~= "table" then
    return plan
  end
  for _, entry in ipairs(names) do
    local record = service:Player(entry.name)
    if record and settings.minimapTooltip then
      local text = describe(record)
      if text then
        plan.extras[#plan.extras + 1] = { index = entry.index, name = entry.name, text = text }
      end
    end
    if settings.minimapFeed and (record or entry.hostile) and not service:IsIgnored(entry.name) then
      local known = record or {}
      plan.feed[#plan.feed + 1] = {
        name = entry.name,
        class = known.class,
        race = known.race,
        level = known.level,
        levelEstimated = known.levelEstimated,
        guild = known.guild,
        faction = known.faction,
      }
    end
  end
  return plan
end

ns.IntelMinimapTooltip = IntelMinimapTooltip
