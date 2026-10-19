local _, ns = ...

-- Pure helpers of the kit: no frames, no client API, so they are unit tested.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Util = {}
Kit.Util = Util

function Util.Clamp(value, low, high)
  if value < low then
    return low
  end
  if value > high then
    return high
  end
  return value
end

function Util.Round(value)
  return math.floor(value + 0.5)
end

-- Splits `total` units between columns. Each spec is { width = n } (fixed), { weight = w } (a share of what is
-- left, default 1) or { width = n, min = m }. `gap` goes between columns. Returns one width per spec; the weighted
-- columns always add up to exactly what the fixed ones and the gaps leave, and nothing is ever negative.
function Util.Distribute(total, specs, gap)
  gap = gap or 0
  local count = #specs
  local widths = {}
  if count == 0 then
    return widths
  end
  local fixed, weights = 0, 0
  for index, spec in ipairs(specs) do
    if spec.width then
      widths[index] = spec.width
      fixed = fixed + spec.width
    else
      weights = weights + (spec.weight or 1)
    end
  end
  local free = math.max(0, total - fixed - gap * (count - 1))
  local given, last = 0, nil
  for index, spec in ipairs(specs) do
    if not spec.width then
      local share = math.floor(free * (spec.weight or 1) / weights)
      widths[index] = share
      given = given + share
      last = index
    end
  end
  -- The rounding leftovers go to the last weighted column, so the row is exactly as wide as asked.
  if last then
    widths[last] = widths[last] + (free - given)
  end
  for index, spec in ipairs(specs) do
    if spec.min and widths[index] < spec.min then
      widths[index] = spec.min
    end
  end
  return widths
end

-- Wraps a list of widths into lines of at most `total` units (with `gap` between items): returns a list of lines,
-- each a list of item indexes. An item wider than the line gets a line of its own.
function Util.WrapLines(total, widths, gap)
  gap = gap or 0
  local lines, line, used = {}, {}, 0
  for index, width in ipairs(widths) do
    local needed = (#line > 0 and gap or 0) + width
    if #line > 0 and used + needed > total then
      lines[#lines + 1] = line
      line, used = {}, 0
      needed = width
    end
    line[#line + 1] = index
    used = used + needed
  end
  if #line > 0 then
    lines[#lines + 1] = line
  end
  return lines
end

-- Capital letters for a section label. The client's own upper-casing only knows ASCII, which would leave the
-- accented letters of Spanish in lower case ("CONFIGURACIóN"), so these are mapped by hand.
local UPPER = {
  ["á"] = "Á",
  ["é"] = "É",
  ["í"] = "Í",
  ["ó"] = "Ó",
  ["ú"] = "Ú",
  ["ü"] = "Ü",
  ["ñ"] = "Ñ",
}

function Util.Upper(text)
  text = tostring(text)
  for lower, upper in pairs(UPPER) do
    text = text:gsub(lower, upper)
  end
  return (text:gsub("%l", string.upper))
end

-- Text cut to `limit` bytes with "..." when it is longer, never in the middle of a UTF-8 character.
function Util.Truncate(text, limit)
  text = tostring(text)
  if #text <= limit then
    return text
  end
  local cut = limit - 3
  while cut > 0 do
    local byte = text:byte(cut + 1)
    if not byte or byte < 128 or byte >= 192 then
      break
    end
    cut = cut - 1
  end
  return text:sub(1, math.max(cut, 0)) .. "..."
end

-- The position of a scrollbar thumb. `view` and `content` are heights, `scroll` the offset (0..content - view),
-- `track` the height of the track. Returns the thumb's top offset and its height (never under `minimum`).
function Util.Thumb(view, content, scroll, track, minimum)
  if content <= view or content <= 0 then
    return 0, track
  end
  local height = math.max(minimum or 20, math.floor(track * view / content))
  local range = content - view
  local top = math.floor((track - height) * Util.Clamp(scroll, 0, range) / range)
  return top, height
end
