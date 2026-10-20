local _, ns = ...

-- One physical pixel, and borders built from four solid textures (no backdrop templates, no art files).
-- The technique is the common one for pixel-perfect UI: a physical pixel is 768 / screen height in interface units
-- at scale 1, divided by the effective scale of the frame that draws it.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Pixel = {}
Kit.Pixel = Pixel

-- `value` rounded to a whole multiple of `pixel`, at least one pixel (so a thin line never rounds to nothing).
function Pixel.Snap(value, pixel)
  if type(pixel) ~= "number" or pixel <= 0 then
    return value
  end
  local snapped = math.floor(value / pixel + 0.5) * pixel
  if snapped < pixel and value > 0 then
    return pixel
  end
  return snapped
end

-- The size of one physical pixel in the units of `frame` (1 when the client cannot say).
function Pixel.Size(frame)
  local height
  if GetPhysicalScreenSize then
    local ok, _, physical = pcall(GetPhysicalScreenSize)
    if ok and type(physical) == "number" and physical > 0 then
      height = physical
    end
  end
  local scale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or 1
  if not height or type(scale) ~= "number" or scale <= 0 then
    return 1
  end
  return (768 / height) / scale
end

-- Four textures along the edges of `frame`. `color` is a theme token or { r, g, b, a }. Returns a border object
-- with SetColor(token | r, g, b, a) and Resize() to snap its thickness again (after a scale change).
function Pixel.Border(frame, color)
  local border = { frame = frame, textures = {} }
  for index, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local texture = frame:CreateTexture(nil, "BORDER")
    border.textures[index] = texture
    if side == "TOP" or side == "BOTTOM" then
      texture:SetPoint(side .. "LEFT")
      texture:SetPoint(side .. "RIGHT")
    else
      texture:SetPoint("TOP" .. side)
      texture:SetPoint("BOTTOM" .. side)
    end
  end

  function border:Resize()
    local size = Pixel.Size(self.frame)
    self.textures[1]:SetHeight(size)
    self.textures[2]:SetHeight(size)
    self.textures[3]:SetWidth(size)
    self.textures[4]:SetWidth(size)
  end

  function border:SetColor(value, g, b, a)
    local r
    if type(value) == "string" then
      r, g, b, a = Kit.Theme.Color(value)
    elseif type(value) == "table" then
      r, g, b, a = value[1], value[2], value[3], value[4]
    else
      r = value
    end
    for _, texture in ipairs(self.textures) do
      texture:SetColorTexture(r, g, b, a or 1)
    end
  end

  function border:SetShown(shown)
    for _, texture in ipairs(self.textures) do
      if shown then
        texture:Show()
      else
        texture:Hide()
      end
    end
  end

  border:Resize()
  border:SetColor(color or "border")
  return border
end
