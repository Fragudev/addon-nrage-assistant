-- Kit.Shape and Theme.Gradient on fake frames: how many textures a surface draws, which corners are cut, what a fill
-- sets and what happens when the client refuses a call. How it looks is checked in the game, not here.
local fake = dofile("tests/support/fake_frames.lua")

local function load_kit()
  local ns = {}
  for _, path in ipairs({ "UI/Kit/Theme", "UI/Kit/Pixel", "UI/Kit/Shape" }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.Kit
end

-- The textures of `frame` shown right now.
local function shown(frame)
  local count = 0
  for _, texture in ipairs(frame.children) do
    if texture.shown then
      count = count + 1
    end
  end
  return count
end

-- Makes every texture the frame creates from now on raise when `method` is called.
local function refuse(frame, method)
  local original = frame.CreateTexture
  frame.CreateTexture = function(self, ...)
    local texture = original(self, ...)
    rawset(texture, method, function()
      error("the client refuses " .. method)
    end)
    return texture
  end
end

describe("Theme.Gradient", function()
  local Theme, from, to

  before_each(function()
    fake.install()
    Theme = load_kit().Theme
    from, to = { 1, 0, 0, 1 }, { 0, 0, 1, 0.5 }
  end)

  after_each(function()
    fake.uninstall()
  end)

  it("uses the ColorMixin form first", function()
    local texture = _G.UIParent:CreateTexture()
    assert.is_true(Theme.Gradient(texture, "HORIZONTAL", from, to))
    assert.are.equal("HORIZONTAL", texture.gradient[1])
    assert.are.equal(1, texture.gradient[2].r)
    assert.are.equal(0.5, texture.gradient[3].a)
  end)

  it("keeps from at the top of a VERTICAL gradient under the minColor assumption", function()
    local texture = _G.UIParent:CreateTexture()
    Theme.Gradient(texture, "VERTICAL", from, to)
    -- minColor (the first one) is the bottom, which is `to`.
    assert.are.equal(0, texture.gradient[2].r)
    assert.are.equal(1, texture.gradient[3].r)
  end)

  it("falls back to the old r, g, b form", function()
    local calls = {}
    local texture = {
      SetGradient = function(_, orientation, a, ...)
        if type(a) == "table" then
          error("old client")
        end
        calls[#calls + 1] = { orientation, a, ... }
      end,
    }
    assert.is_true(Theme.Gradient(texture, "HORIZONTAL", from, to))
    assert.are.same({ { "HORIZONTAL", 1, 0, 0, 0, 0, 1 } }, calls)
  end)

  it("falls back to the flat from color when SetGradient is missing", function()
    local color
    local texture = {
      SetColorTexture = function(_, ...)
        color = { ... }
      end,
    }
    assert.is_false(Theme.Gradient(texture, "VERTICAL", from, to))
    assert.are.same({ 1, 0, 0, 1 }, color)
  end)

  it("falls back to flat when SetGradient raises, and never raises itself", function()
    local color
    local texture = {
      SetGradient = function()
        error("boom")
      end,
      SetColorTexture = function(_, ...)
        color = { ... }
      end,
    }
    assert.is_false(Theme.Gradient(texture, "VERTICAL", from, to))
    assert.are.same({ 1, 0, 0, 1 }, color)
  end)
end)

describe("Kit.Shape", function()
  local Kit, frame, saved_gradients

  before_each(function()
    fake.install()
    Kit = load_kit()
    frame = _G.CreateFrame("Frame", nil, _G.UIParent)
    frame:SetSize(200, 100)
    saved_gradients = Kit.Theme.gradients
    Kit.Theme.gradients = { panel = { from = { 0.2, 0.1, 0.1, 1 }, to = { 0.1, 0.05, 0.05, 1 } } }
  end)

  after_each(function()
    Kit.Theme.gradients = saved_gradients
    fake.uninstall()
  end)

  it("draws 7 fill and 8 border textures, and the glow only once asked for", function()
    local shape = Kit.Shape.New(frame, { cut = "md" })
    assert.are.equal(15, #frame.children)
    shape:SetGlow(nil)
    assert.are.equal(15, #frame.children)
    shape:SetGlow({ color = "accent", alpha = 0.5 })
    assert.are.equal(23, #frame.children)
    shape:SetGlow({ color = "accent", alpha = 0.3 })
    assert.are.equal(23, #frame.children)
  end)

  it("sizes the cut from its name", function()
    for name, size in pairs({ sm = 4, md = 6, lg = 8 }) do
      local shape = Kit.Shape.New(_G.CreateFrame("Frame", nil, _G.UIParent), { cut = name })
      assert.are.equal(size, shape.fillTextures.tl.width)
      assert.is_truthy(shape.fillTextures.tl.texture:find("cut" .. size .. "_fill", 1, true))
    end
  end)

  it("flips the corner tiles", function()
    local shape = Kit.Shape.New(frame, { cut = "lg" })
    assert.are.same({ 0, 1, 0, 1 }, shape.fillTextures.tl.texcoord)
    assert.are.same({ 1, 0, 0, 1 }, shape.fillTextures.tr.texcoord)
    assert.are.same({ 0, 1, 1, 0 }, shape.fillTextures.bl.texcoord)
    assert.are.same({ 1, 0, 1, 0 }, shape.fillTextures.br.texcoord)
  end)

  it("draws a corner left out square", function()
    local shape = Kit.Shape.New(frame, { cut = "md", corners = { tl = true } })
    assert.is_truthy(shape.fillTextures.tl.vertex)
    assert.is_nil(shape.fillTextures.tr.vertex)
    assert.is_truthy(shape.fillTextures.tr.color)
    assert.is_true(shape.border.diagonal.tl.shown)
    assert.is_false(shape.border.diagonal.tr.shown)
    assert.is_false(shape.border.diagonal.br.shown)
    -- The top edge stops at the round corner and runs into the square one.
    assert.are.equal(6, shape.border.straight.top.points[1][4])
    assert.are.equal(0, shape.border.straight.top.points[2][4])
  end)

  it("fills with a token", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetFill("control")
    local color = { Kit.Theme.Color("control") }
    assert.are.same(color, shape.fillTextures.mid.color)
    assert.are.same(color, shape.fillTextures.top.color)
    assert.are.same(color, shape.fillTextures.bottom.color)
    assert.are.same(color, shape.fillTextures.tl.vertex)
    shape:SetFill({ color = "control", alpha = 0.4 })
    assert.are.equal(0.4, shape.fillTextures.mid.color[4])
  end)

  it("fills with a gradient on the band and the ends on the strips", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetFill({ gradient = "panel" })
    local fill = shape.fillTextures
    assert.is_truthy(fill.mid.gradient)
    assert.are.same({ 1, 1, 1, 1 }, fill.mid.color)
    assert.are.same({ 0.2, 0.1, 0.1, 1 }, fill.top.color)
    assert.are.same({ 0.2, 0.1, 0.1, 1 }, fill.tl.vertex)
    assert.are.same({ 0.1, 0.05, 0.05, 1 }, fill.bottom.color)
    assert.are.same({ 0.1, 0.05, 0.05, 1 }, fill.br.vertex)
  end)

  it("falls back to a flat fill for an unknown gradient", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetFill({ gradient = "nope" })
    assert.is_nil(shape.fillTextures.mid.gradient)
    assert.are.same({ Kit.Theme.Color("panel") }, shape.fillTextures.mid.color)
  end)

  it("falls back to a flat fill when the client has no gradient", function()
    refuse(frame, "SetGradient")
    local shape = Kit.Shape.New(frame, {})
    shape:SetFill({ gradient = "panel" })
    assert.are.same({ 0.2, 0.1, 0.1, 1 }, shape.fillTextures.mid.color)
  end)

  it("flattens a pooled band that had a gradient", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetFill({ gradient = "panel" })
    shape:SetFill("control")
    -- The last SetGradient call has both ends equal.
    local gradient = shape.fillTextures.mid.gradient
    assert.are.same(gradient[2], gradient[3])
  end)

  it("shows no glow on a pooled widget reused without one", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetGlow({ color = "accent", alpha = 0.5 })
    assert.are.equal(23, shown(frame))
    shape:SetGlow(nil)
    assert.are.equal(15, shown(frame))
    shape:SetGlow({ color = "accent", alpha = 0.5 })
    assert.are.equal(23, shown(frame))
  end)

  it("blends the glow with ADD, tinted", function()
    local shape = Kit.Shape.New(frame, {})
    shape:SetGlow({ color = "danger", alpha = 0.45 })
    local r, g, b = Kit.Theme.Color("danger")
    for _, texture in pairs(shape.glowTextures) do
      assert.are.equal("ADD", texture.blend)
      assert.are.same({ r, g, b, 0.45 }, texture.vertex)
    end
  end)

  it("keeps the glow hidden when the client refuses ADD", function()
    refuse(frame, "SetBlendMode")
    local shape = Kit.Shape.New(frame, {})
    shape:SetGlow({ color = "accent", alpha = 0.5 })
    assert.are.equal(15, shown(frame))
  end)

  it("draws square when the client refuses SetTexCoord", function()
    refuse(frame, "SetTexCoord")
    local shape = Kit.Shape.New(frame, { cut = "md" })
    assert.is_false(shape:IsRound("tl"))
    assert.is_truthy(shape.fillTextures.tl.color)
    assert.is_false(shape.border.diagonal.tl.shown)
  end)

  it("hides, shows and recolors the whole border", function()
    local shape = Kit.Shape.New(frame, {})
    shape.border:SetShown(false)
    assert.are.equal(7, shown(frame))
    shape.border:SetShown(true)
    assert.are.equal(15, shown(frame))
    shape.border:SetColor("danger")
    assert.are.same({ Kit.Theme.Color("danger") }, shape.border.straight.top.color)
    shape.border:SetColor(1, 0, 0, 0.5)
    assert.are.same({ 1, 0, 0, 0.5 }, shape.border.diagonal.tl.vertex)
  end)

  it("snaps the border to a pixel on Resize", function()
    local shape = Kit.Shape.New(frame, {})
    assert.are.equal(768 / 1080, shape.border.straight.top.height)
    frame.GetEffectiveScale = function()
      return 0.5
    end
    shape:Resize()
    assert.are.equal(2 * 768 / 1080, shape.border.straight.top.height)
  end)

  it("draws an image on the band and the two strips, not on the corners", function()
    local shape = Kit.Shape.New(frame, { cut = "lg" })
    local count = #frame.children
    shape:SetImage("Interface\\x\\hero", 0.5, { 0, 1, 0.2, 0.8 })
    assert.are.equal(count + 3, #frame.children)
    local pieces = shape.imageTextures
    assert.are.equal("Interface\\x\\hero", pieces.mid.texture)
    assert.are.same({ 1, 1, 1, 0.5 }, pieces.mid.vertex)
    -- Full width for the band, inset by one cut for the strips; the vertical range is shared out.
    assert.are.equal(0, pieces.mid.texcoord[1])
    assert.are.equal(1, pieces.mid.texcoord[2])
    assert.is_true(pieces.top.texcoord[1] > 0 and pieces.top.texcoord[2] < 1)
    assert.are.equal(0.2, pieces.top.texcoord[3])
    assert.are.equal(0.8, pieces.bottom.texcoord[4])
    shape:SetImage(nil)
    assert.is_false(pieces.mid.shown)
  end)

  it("shows the plain fill when the client refuses SetTexCoord for the image", function()
    local shape = Kit.Shape.New(frame, {})
    refuse(frame, "SetTexCoord")
    shape:SetImage("Interface\\x\\hero", 1)
    for _, texture in pairs(shape.imageTextures) do
      assert.is_false(texture.shown)
    end
  end)
end)
