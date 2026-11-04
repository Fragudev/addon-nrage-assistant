local _, ns = ...

-- A cut-corner surface (plan 5.3): a fill, a border and an optional glow, drawn with textures only. The corner cut
-- is a pre-drawn tile flipped with SetTexCoord (Media/Shapes, made by tools/make_shapes.py), so the only client
-- features it needs are SetTexCoord, SetBlendMode and SetGradient. None of them has been measured in the game yet, so
-- every one runs behind pcall and a failure falls back to a plain square fill or to no glow.
local Kit = ns.Kit or {}
ns.Kit = Kit

local Shape = {}
Kit.Shape = Shape
Shape.__index = Shape

local DIR = "Interface\\AddOns\\NrageAssistant\\Media\\Shapes\\"
local CUTS = { none = 0, sm = 4, md = 6, lg = 8 }
local TILES = { [4] = DIR .. "cut4", [6] = DIR .. "cut6", [8] = DIR .. "cut8" }
local GLOW_FILE = DIR .. "glow"
local GLOW_BORDER = 24 / 64 -- the glow art is 64 px with a 24 px falloff on each side and a solid middle
local GLOW_EXTENT = 10 -- units the halo reaches outside the frame (ScrollArea clips anything past 10)

local CORNER_KEYS = { "tl", "tr", "bl", "br" }
local CORNER_POINT = { tl = "TOPLEFT", tr = "TOPRIGHT", bl = "BOTTOMLEFT", br = "BOTTOMRIGHT" }
-- SetTexCoord (left, right, top, bottom) of the top-left tile for each corner.
local FLIPS = {
  tl = { 0, 1, 0, 1 },
  tr = { 1, 0, 0, 1 },
  bl = { 0, 1, 1, 0 },
  br = { 1, 0, 1, 0 },
}
local ALL_CORNERS = { tl = true, tr = true, bl = true, br = true }

-- The r, g, b, a of a theme token or a { r, g, b, a } table, with `alpha` over its own when given.
local function resolve(value, alpha)
  if type(value) == "table" then
    return value[1], value[2], value[3], alpha or value[4] or 1
  end
  return Kit.Theme.Color(value, alpha)
end

local function new_texture(frame, layer, sub)
  return frame:CreateTexture(nil, layer, nil, sub)
end

local function anchor(texture, point, frame, relative, x, y)
  texture:SetPoint(point, frame, relative or point, x or 0, y or 0)
end

-- Flips a corner tile. Returns false when the client refuses SetTexCoord.
local function set_flip(texture, key)
  local flip = FLIPS[key]
  return (pcall(texture.SetTexCoord, texture, flip[1], flip[2], flip[3], flip[4]))
end

-- The border: 4 straight edges snapped to a physical pixel and 4 diagonals. Same SetColor, SetShown and Resize as
-- Pixel.Border, so a widget does not care which one it holds.
local function make_border(shape)
  local frame = shape.frame
  local border = { frame = frame, straight = {}, diagonal = {}, shown = true }
  for _, side in ipairs({ "top", "bottom", "left", "right" }) do
    border.straight[side] = new_texture(frame, "BORDER", 0)
  end
  for _, key in ipairs(CORNER_KEYS) do
    border.diagonal[key] = new_texture(frame, "BORDER", 1)
  end

  -- Edges stop at a round corner and run into a square one (a pixel less on the sides, so the corner pixel is not
  -- drawn twice).
  function border:Resize()
    local px, cut = Kit.Pixel.Size(frame), shape.cut
    local function span(key)
      return shape:IsRound(key) and cut or 0
    end
    local function inset(key)
      return shape:IsRound(key) and cut or px
    end
    local edges = self.straight
    for _, texture in pairs(edges) do
      texture:ClearAllPoints()
    end
    anchor(edges.top, "TOPLEFT", frame, nil, span("tl"), 0)
    anchor(edges.top, "TOPRIGHT", frame, nil, -span("tr"), 0)
    edges.top:SetHeight(px)
    anchor(edges.bottom, "BOTTOMLEFT", frame, nil, span("bl"), 0)
    anchor(edges.bottom, "BOTTOMRIGHT", frame, nil, -span("br"), 0)
    edges.bottom:SetHeight(px)
    anchor(edges.left, "TOPLEFT", frame, nil, 0, -inset("tl"))
    anchor(edges.left, "BOTTOMLEFT", frame, nil, 0, inset("bl"))
    edges.left:SetWidth(px)
    anchor(edges.right, "TOPRIGHT", frame, nil, 0, -inset("tr"))
    anchor(edges.right, "BOTTOMRIGHT", frame, nil, 0, inset("br"))
    edges.right:SetWidth(px)
    for _, key in ipairs(CORNER_KEYS) do
      local texture = self.diagonal[key]
      texture:ClearAllPoints()
      anchor(texture, CORNER_POINT[key], frame)
      texture:SetSize(cut, cut)
    end
    self:Apply()
  end

  -- Shows what the shape draws: a diagonal only on a round corner, nothing while the border is hidden.
  function border:Apply()
    for _, texture in pairs(self.straight) do
      texture:SetShown(self.shown)
    end
    for key, texture in pairs(self.diagonal) do
      texture:SetShown(self.shown and shape:IsRound(key))
    end
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
    for _, texture in pairs(self.straight) do
      texture:SetColorTexture(r, g, b, a or 1)
    end
    for _, texture in pairs(self.diagonal) do
      texture:SetVertexColor(r, g, b, a or 1)
    end
  end

  function border:SetShown(shown)
    self.shown = shown and true or false
    self:Apply()
  end

  return border
end

-- `opts.cut`: "sm" (4), "md" (6, the default), "lg" (8), "none" or a number of units. `opts.corners`: the corners
-- that are cut, all four by default; one left out is drawn square.
function Shape.New(frame, opts)
  opts = opts or {}
  local cut = opts.cut
  if type(cut) ~= "number" then
    cut = CUTS[cut or "md"] or CUTS.md
  end
  local shape = setmetatable({ frame = frame, cut = cut, corners = opts.corners or ALL_CORNERS }, Shape)
  shape.tile = TILES[cut]
  -- Without a tile (an odd cut size) or when the client refuses SetTexCoord, every corner is square: a plain
  -- rectangle, no diagonal.
  shape.flat = shape.tile == nil or cut <= 0

  -- Fill: two corners and a strip on top, the same below, and the middle band (7 textures).
  shape.fillTextures = {}
  for _, name in ipairs({ "tl", "tr", "bl", "br", "top", "bottom", "mid" }) do
    shape.fillTextures[name] = new_texture(frame, "BACKGROUND", 0)
  end
  shape.border = make_border(shape)
  if not shape.flat then
    for _, key in ipairs(CORNER_KEYS) do
      shape.fillTextures[key]:SetTexture(shape.tile .. "_fill")
      shape.border.diagonal[key]:SetTexture(shape.tile .. "_edge")
      if not (set_flip(shape.fillTextures[key], key) and set_flip(shape.border.diagonal[key], key)) then
        shape.flat = true
      end
    end
  end
  shape:Layout()
  shape.border:SetColor("border")
  shape.border:Resize()
  shape:SetFill("panel")
  return shape
end

-- Whether a corner is drawn with the diagonal cut.
function Shape:IsRound(key)
  return self.corners[key] == true and not self.flat
end

-- Anchors the fill. The textures hang from the frame corners, so they follow any size without a Resize.
function Shape:Layout()
  local frame, cut, fill = self.frame, self.cut, self.fillTextures
  for _, texture in pairs(fill) do
    texture:ClearAllPoints()
  end
  for _, key in ipairs(CORNER_KEYS) do
    anchor(fill[key], CORNER_POINT[key], frame)
    fill[key]:SetSize(cut, cut)
    fill[key]:SetShown(cut > 0)
  end
  anchor(fill.top, "TOPLEFT", frame, nil, cut, 0)
  anchor(fill.top, "TOPRIGHT", frame, nil, -cut, 0)
  anchor(fill.bottom, "BOTTOMLEFT", frame, nil, cut, 0)
  anchor(fill.bottom, "BOTTOMRIGHT", frame, nil, -cut, 0)
  anchor(fill.mid, "TOPLEFT", frame, nil, 0, -cut)
  anchor(fill.mid, "BOTTOMRIGHT", frame, nil, 0, cut)
  for _, strip in ipairs({ fill.top, fill.bottom }) do
    strip:SetHeight(cut)
    strip:SetShown(cut > 0)
  end
end

-- A round corner is vertex colored art, a square one is a color texture.
local function paint_corner(self, key, color)
  local texture = self.fillTextures[key]
  if self:IsRound(key) then
    texture:SetTexture(self.tile .. "_fill")
    texture:SetVertexColor(color[1], color[2], color[3], color[4])
  else
    texture:SetColorTexture(color[1], color[2], color[3], color[4])
  end
end

-- Theme.gradients[name] is { from, to } or { from = ..., to = ..., orientation = ... } (the tokens or { r, g, b, a }
-- tables), `from` being the top. Nil when there is no such gradient.
local function gradient_colors(name, alpha)
  local entry = Kit.Theme.gradients and Kit.Theme.gradients[name]
  if type(entry) ~= "table" then
    return nil
  end
  local from, to = entry.from or entry[1], entry.to or entry[2]
  if from == nil or to == nil then
    return nil
  end
  return { resolve(from, alpha) }, { resolve(to, alpha) }, entry.orientation
end

-- `spec` is a token, { color = token, alpha = n } or { gradient = name, alpha = n }. A gradient runs on the middle
-- band; the top strip and corners take its start color and the bottom ones its end color. An unknown gradient name
-- is a flat fill of the token with that name (or "panel"). Always sets the whole fill, because widgets are pooled.
function Shape:SetFill(spec)
  local from, to, orientation
  if type(spec) == "table" and spec.gradient then
    from, to, orientation = gradient_colors(spec.gradient, spec.alpha)
    if not from then
      from = { resolve(Kit.Theme.colors[spec.gradient] and spec.gradient or "panel", spec.alpha) }
      to = from
    end
  elseif type(spec) == "table" and spec.color then
    from = { resolve(spec.color, spec.alpha) }
    to = from
  else
    from = { resolve(spec) }
    to = from
  end
  paint_corner(self, "tl", from)
  paint_corner(self, "tr", from)
  paint_corner(self, "bl", to)
  paint_corner(self, "br", to)
  local fill = self.fillTextures
  fill.top:SetColorTexture(from[1], from[2], from[3], from[4])
  fill.bottom:SetColorTexture(to[1], to[2], to[3], to[4])
  local mid = fill.mid
  if from == to then
    mid:SetColorTexture(from[1], from[2], from[3], from[4])
    if self.gradiented then
      -- A texture may keep its last gradient over a new color, so flatten it again.
      Kit.Theme.Gradient(mid, "VERTICAL", from, from)
    end
    self.gradiented = false
  else
    mid:SetColorTexture(1, 1, 1, 1)
    self.gradiented = Kit.Theme.Gradient(mid, orientation or "VERTICAL", from, to)
  end
end

-- Cuts the image into the three pieces that show it (the two strips and the middle band, no corner squares).
function Shape:LayoutImage()
  local image = self.image
  if not image then
    return
  end
  local cut = self.cut
  local width, height = self.frame:GetWidth(), self.frame:GetHeight()
  local fx, fy = 0, 0
  if width > 0 and height > 0 then
    fx, fy = cut / width, cut / height
  end
  local l, r, t, b = image.coords[1], image.coords[2], image.coords[3], image.coords[4]
  local du, dv = r - l, b - t
  local rects = {
    top = { l + du * fx, r - du * fx, t, t + dv * fy },
    mid = { l, r, t + dv * fy, b - dv * fy },
    bottom = { l + du * fx, r - du * fx, b - dv * fy, b },
  }
  local ok = true
  for name, texture in pairs(self.imageTextures) do
    local rect = rects[name]
    ok = pcall(texture.SetTexCoord, texture, rect[1], rect[2], rect[3], rect[4]) and ok
  end
  -- A client that refuses SetTexCoord shows the plain fill instead of a stretched image.
  for name, texture in pairs(self.imageTextures) do
    texture:SetShown(ok and (cut > 0 or name == "mid"))
  end
end

-- Draws `path` over the fill, on the middle band and the two middle strips only, so the corner squares keep the
-- solid fill (plan 5.7). `coords` is { left, right, top, bottom } of the whole frame (the whole image by default);
-- the strips and the band take their share. `nil` takes the image away. Call Resize after the frame changes size.
function Shape:SetImage(path, alpha, coords)
  if not path then
    self.image = nil
    for _, texture in pairs(self.imageTextures or {}) do
      texture:Hide()
    end
    return
  end
  if not self.imageTextures then
    local frame, cut = self.frame, self.cut
    local top = new_texture(frame, "BACKGROUND", 1)
    local mid = new_texture(frame, "BACKGROUND", 1)
    local bottom = new_texture(frame, "BACKGROUND", 1)
    anchor(top, "TOPLEFT", frame, nil, cut, 0)
    anchor(top, "TOPRIGHT", frame, nil, -cut, 0)
    top:SetHeight(cut)
    anchor(mid, "TOPLEFT", frame, nil, 0, -cut)
    anchor(mid, "BOTTOMRIGHT", frame, nil, 0, cut)
    anchor(bottom, "BOTTOMLEFT", frame, nil, cut, 0)
    anchor(bottom, "BOTTOMRIGHT", frame, nil, -cut, 0)
    bottom:SetHeight(cut)
    self.imageTextures = { top = top, mid = mid, bottom = bottom }
  end
  self.image = { coords = coords or { 0, 1, 0, 1 } }
  for _, texture in pairs(self.imageTextures) do
    texture:SetTexture(path)
    texture:SetVertexColor(1, 1, 1, alpha or 1)
  end
  self:LayoutImage()
end

-- Moves the image to other texture coordinates (the window was resized) without making its textures again. Does
-- nothing while there is no image.
function Shape:SetImageCoords(coords)
  if not self.image then
    return
  end
  self.image.coords = coords
  self:LayoutImage()
end

-- Eight sliced pieces of the glow art outside the frame, blended with ADD.
local function build_glow(self)
  local frame, e, b = self.frame, GLOW_EXTENT, GLOW_BORDER
  local pieces, ok = {}, true
  local function piece(name, left, right, top, bottom)
    local texture = new_texture(frame, "BACKGROUND", -8)
    texture:SetTexture(GLOW_FILE)
    ok = pcall(texture.SetBlendMode, texture, "ADD") and ok
    ok = pcall(texture.SetTexCoord, texture, left, right, top, bottom) and ok
    pieces[name] = texture
    return texture
  end
  -- A corner piece sits outside, diagonally, with its inner corner on the frame corner.
  local inner = { tl = "BOTTOMRIGHT", tr = "BOTTOMLEFT", bl = "TOPRIGHT", br = "TOPLEFT" }
  local coords = { tl = { 0, b, 0, b }, tr = { 1 - b, 1, 0, b }, bl = { 0, b, 1 - b, 1 }, br = { 1 - b, 1, 1 - b, 1 } }
  for _, key in ipairs(CORNER_KEYS) do
    local c = coords[key]
    local texture = piece(key, c[1], c[2], c[3], c[4])
    texture:SetSize(e, e)
    anchor(texture, inner[key], frame, CORNER_POINT[key])
  end
  local top = piece("top", b, 1 - b, 0, b)
  anchor(top, "BOTTOMLEFT", frame, "TOPLEFT")
  anchor(top, "BOTTOMRIGHT", frame, "TOPRIGHT")
  top:SetHeight(e)
  local bottom = piece("bottom", b, 1 - b, 1 - b, 1)
  anchor(bottom, "TOPLEFT", frame, "BOTTOMLEFT")
  anchor(bottom, "TOPRIGHT", frame, "BOTTOMRIGHT")
  bottom:SetHeight(e)
  local left = piece("left", 0, b, b, 1 - b)
  anchor(left, "TOPRIGHT", frame, "TOPLEFT")
  anchor(left, "BOTTOMRIGHT", frame, "BOTTOMLEFT")
  left:SetWidth(e)
  local right = piece("right", 1 - b, 1, b, 1 - b)
  anchor(right, "TOPLEFT", frame, "TOPRIGHT")
  anchor(right, "BOTTOMLEFT", frame, "BOTTOMRIGHT")
  right:SetWidth(e)
  self.glowTextures = pieces
  self.glowOk = ok
end

-- `nil` removes the glow; otherwise { color = token, alpha = n }. The 8 pieces are made on the first call. When the
-- client refuses ADD blending or SetTexCoord the glow stays hidden, since a normally blended halo would be a smudge.
function Shape:SetGlow(spec)
  if not spec then
    for _, texture in pairs(self.glowTextures or {}) do
      texture:Hide()
    end
    return
  end
  if not self.glowTextures then
    build_glow(self)
  end
  local r, g, b, a = resolve(spec.color or "accent", spec.alpha or 0.5)
  for _, texture in pairs(self.glowTextures) do
    texture:SetVertexColor(r, g, b, a)
    texture:SetShown(self.glowOk)
  end
end

-- After the frame changes size or scale: snaps the border to a pixel again and re-cuts the image.
function Shape:Resize()
  self.border:Resize()
  self:LayoutImage()
end
