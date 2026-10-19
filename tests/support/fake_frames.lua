-- Fake client frames, so the real kit code can run under busted. A frame keeps what it was told (size, text,
-- scripts, points, shown); any other capitalized method is accepted and does nothing, like a frame that supports it.
-- Text measuring is a simple rule: 7 units per character and 15 per line, which is enough to test the layout.
local M = {}

local CHAR_WIDTH, LINE_HEIGHT = 7, 15

local function make_region(kind, parent)
  local region = { kind = kind, parent = parent, shown = true, points = {}, scripts = {}, children = {} }
  local methods = {}

  function methods.SetSize(self, width, height)
    self.width, self.height = width, height
  end
  function methods.SetWidth(self, width)
    self.width = width
  end
  function methods.SetHeight(self, height)
    self.height = height
  end
  function methods.GetWidth(self)
    return self.width or 0
  end
  function methods.GetHeight(self)
    return self.height or 0
  end
  function methods.SetPoint(self, ...)
    self.points[#self.points + 1] = { ... }
  end
  function methods.ClearAllPoints(self)
    self.points = {}
  end
  function methods.SetAllPoints(self, target)
    self.allPoints = target or true
  end
  function methods.Show(self)
    self.shown = true
    local handler = self.scripts.OnShow
    if handler then
      handler(self)
    end
  end
  function methods.Hide(self)
    if self.shown then
      self.shown = false
      local handler = self.scripts.OnHide
      if handler then
        handler(self)
      end
    end
  end
  function methods.SetShown(self, shown)
    if shown then
      self:Show()
    else
      self:Hide()
    end
  end
  function methods.IsShown(self)
    return self.shown
  end
  function methods.SetParent(self, new)
    self.parent = new
  end
  function methods.GetParent(self)
    return self.parent
  end
  function methods.SetScript(self, name, handler)
    self.scripts[name] = handler
  end
  function methods.GetScript(self, name)
    return self.scripts[name]
  end
  function methods.HookScript(self, name, handler)
    self.scripts[name] = handler
  end
  function methods.SetText(self, text)
    self.text = text
  end
  function methods.GetText(self)
    return self.text or ""
  end
  function methods.SetColorTexture(self, r, g, b, a)
    self.color = { r, g, b, a }
  end
  function methods.SetVertexColor(self, r, g, b, a)
    self.vertex = { r, g, b, a }
  end
  function methods.SetTexture(self, path)
    self.texture = path
  end
  function methods.SetRotation(self, radians)
    self.rotation = radians
  end
  function methods.SetTextColor(self, r, g, b, a)
    self.textColor = { r, g, b, a }
  end
  function methods.SetAlpha(self, alpha)
    self.alpha = alpha
  end
  function methods.SetWordWrap(self, wrap)
    self.wrap = wrap
  end
  function methods.GetStringWidth(self)
    return #(self.text or "") * CHAR_WIDTH
  end
  function methods.GetStringHeight(self)
    local text = self.text or ""
    if text == "" then
      return 0
    end
    if self.wrap and self.width and self.width > 0 then
      return math.max(1, math.ceil(#text * CHAR_WIDTH / self.width)) * LINE_HEIGHT
    end
    return LINE_HEIGHT
  end
  function methods.GetEffectiveScale()
    return 1
  end
  function methods.GetFrameLevel()
    return 1
  end
  function methods.SetVerticalScroll(self, value)
    self.vscroll = value
  end
  function methods.GetVerticalScroll(self)
    return self.vscroll or 0
  end
  function methods.SetScrollChild(self, child)
    self.scrollChild = child
  end
  function methods.CreateTexture(self)
    local texture = make_region("Texture", self)
    self.children[#self.children + 1] = texture
    return texture
  end
  function methods.CreateFontString(self)
    local fontString = make_region("FontString", self)
    self.children[#self.children + 1] = fontString
    return fontString
  end
  function methods.SetFocus(self)
    self.focused = true
    local handler = self.scripts.OnEditFocusGained
    if handler then
      handler(self)
    end
  end
  function methods.ClearFocus(self)
    if self.focused then
      self.focused = false
      local handler = self.scripts.OnEditFocusLost
      if handler then
        handler(self)
      end
    end
  end
  function methods.GetLeft()
    return 100
  end
  function methods.GetTop()
    return 700
  end
  function methods.SetFont()
    return true
  end

  return setmetatable(region, {
    __index = function(_, name)
      if methods[name] then
        return methods[name]
      end
      if type(name) == "string" and name:match("^%u") then
        return function() end
      end
      return nil
    end,
  })
end

local NAMES = {
  "UIParent",
  "UISpecialFrames",
  "STANDARD_TEXT_FONT",
  "CreateFont",
  "CreateFrame",
  "GetPhysicalScreenSize",
  "NrageAssistantModal",
}
local saved

-- Installs CreateFrame and the other client globals the kit needs. Returns the list of every frame created.
function M.install()
  saved = {}
  for _, name in ipairs(NAMES) do
    saved[name] = _G[name]
  end
  local frames = {}
  _G.UIParent = make_region("Frame")
  _G.UIParent.width, _G.UIParent.height = 1920, 1080
  _G.UISpecialFrames = {}
  _G.STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
  _G.CreateFont = function()
    return make_region("Font")
  end
  _G.CreateFrame = function(kind, name, parent)
    local frame = make_region(kind, parent)
    frame.name = name
    frames[#frames + 1] = frame
    if name then
      _G[name] = frame
    end
    return frame
  end
  _G.GetPhysicalScreenSize = function()
    return 1920, 1080
  end
  return frames
end

-- Puts back what install() replaced.
function M.uninstall()
  for _, name in ipairs(NAMES) do
    _G[name] = saved and saved[name] or nil
  end
end

return M
