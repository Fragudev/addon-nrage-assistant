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

-- Texture coordinates { left, right, top, bottom } that fill a `width` x `height` frame with an image of
-- `sourceWidth` x `sourceHeight` the way CSS "cover" does: scaled until it covers, centered, the overflow cropped.
-- The coordinates are relative to the file, so they hold for a texture that was squeezed to a power of two as long as
-- the source size given here is the size of the original art. A frame or source with no size gets the whole image.
function Util.CoverCoords(width, height, sourceWidth, sourceHeight)
  if not (width and height and sourceWidth and sourceHeight) or width <= 0 or height <= 0 then
    return { 0, 1, 0, 1 }
  end
  if sourceWidth <= 0 or sourceHeight <= 0 then
    return { 0, 1, 0, 1 }
  end
  local frameAspect, sourceAspect = width / height, sourceWidth / sourceHeight
  if frameAspect > sourceAspect then
    -- Wider than the art: all of its width, a centered band of its height.
    local shown = sourceAspect / frameAspect
    local margin = (1 - shown) / 2
    return { 0, 1, margin, 1 - margin }
  end
  local shown = frameAspect / sourceAspect
  local margin = (1 - shown) / 2
  return { margin, 1 - margin, 0, 1 }
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

-- One pass of FitColumns: fixed columns keep their width (or `key` when that is wider), the weighted ones share
-- what is left but never get less than their `key` bound. Returns the widths and what is left over (negative when
-- the bounds do not fit).
local function flex(total, specs, gap, key)
  local widths, frozen = {}, {}
  local free = total - gap * (#specs - 1)
  for index, spec in ipairs(specs) do
    if spec.width then
      widths[index] = math.max(spec.width, spec[key] or 0)
      frozen[index] = true
      free = free - widths[index]
    end
  end
  while true do
    local weights = 0
    for index, spec in ipairs(specs) do
      if not frozen[index] then
        weights = weights + (spec.weight or 1)
      end
    end
    if weights == 0 then
      break
    end
    local clamped = false
    for index, spec in ipairs(specs) do
      local bound = spec[key] or 0
      if not frozen[index] and free * (spec.weight or 1) / weights < bound then
        widths[index], frozen[index] = bound, true
        free = free - bound
        clamped = true
        break
      end
    end
    if not clamped then
      local given, last = 0, nil
      for index, spec in ipairs(specs) do
        if not frozen[index] then
          widths[index] = math.max(0, math.floor(free * (spec.weight or 1) / weights))
          given = given + widths[index]
          last = index
        end
      end
      if last then
        widths[last] = widths[last] + math.max(0, free - given)
      end
      break
    end
  end
  return widths, free
end

-- Splits `total` units between table columns that must not be narrower than their text. Each spec is { width = n }
-- or { weight = w } plus `min` (the width the whole text wants, header and cells) and `floor` (the width of the
-- header alone). The widest layout that fits is used: first every column at its `min`; when that does not fit,
-- every column at its `floor`; when even that does not fit, the floors shrink in proportion (the cells are then cut,
-- and the table shows their full text in a tooltip). Returns one width per spec, never negative.
function Util.FitColumns(total, specs, gap)
  gap = gap or 0
  local bounded = {}
  for index, spec in ipairs(specs) do
    local floor = spec.floor or 0
    bounded[index] = { width = spec.width, weight = spec.weight, floor = floor, min = math.max(spec.min or 0, floor) }
  end
  local widths, free = flex(total, bounded, gap, "min")
  if free >= 0 then
    return widths
  end
  widths, free = flex(total, bounded, gap, "floor")
  if free >= 0 then
    return widths
  end
  local sum = 0
  for _, width in ipairs(widths) do
    sum = sum + width
  end
  local available = math.max(0, total - gap * (#specs - 1))
  for index, width in ipairs(widths) do
    widths[index] = sum > 0 and math.floor(width * available / sum) or 0
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

-- The inverse of Util.Thumb: the scroll offset (0..content - view) for a thumb whose top is at `top` units of the
-- track. Used while the thumb is dragged; a top past either end gives the first or the last offset.
function Util.ThumbOffset(top, view, content, track, minimum)
  if content <= view or content <= 0 then
    return 0
  end
  local _, height = Util.Thumb(view, content, 0, track, minimum)
  local travel = track - height
  local range = content - view
  if travel <= 0 then
    return 0
  end
  return Util.Clamp(math.floor(top * range / travel + 0.5), 0, range)
end

-- The first `count` UTF-8 characters of `text` (never half of a multi-byte one: "sáb" -> "sá" for 2).
function Util.Chars(text, count)
  text = tostring(text or "")
  local last, seen = 0, 0
  for index = 1, #text do
    local byte = text:byte(index)
    if byte < 128 or byte >= 192 then
      if seen == count then
        break
      end
      seen = seen + 1
    end
    last = index
  end
  return text:sub(1, last)
end
