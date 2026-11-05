local _, ns = ...

-- The floating card the loot popup and the layer popup share: a movable frame on a cut surface with a title and a
-- close button, that remembers where it was left. What goes inside is up to each popup. Client only.
local PopupFrame = {}

local PADDING_SIDE, PADDING_TOP, PADDING_BOTTOM = 16, 48, 16

-- Makes the frame, hidden. opts: name (the global frame name), title, width, windowName (the key the position is kept
-- under, see UI.ApplyWindowStatus), closeTooltip, onClose() for the close button.
function PopupFrame.New(opts)
  local Kit = ns.Kit
  local frame = CreateFrame("Frame", opts.name, UIParent)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  -- A cut surface on the plain ground: it sits over the game, so it shows no scene and is not translucent.
  frame.shape = Kit.Shape.New(frame, { cut = "lg" })
  frame.shape:SetFill("bg")
  frame.shape.border:SetColor("border")
  frame.title = frame:CreateFontString(nil, "OVERLAY")
  frame.title:SetPoint("TOPLEFT", 16, -14)
  frame.title:SetFontObject(Kit.Theme.StyleFont("window"))
  Kit.SetTextColor(frame.title, "text")
  frame.title:SetText(opts.title)
  frame:SetScript("OnDragStart", function(self)
    self:StartMoving()
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local status = self.status
    local left, top = self:GetLeft(), self:GetTop()
    if status and type(left) == "number" and type(top) == "number" then
      status.left, status.top = left, top
    end
  end)
  frame.hide = Kit.IconButton(frame, {
    icon = "close",
    tooltip = opts.closeTooltip,
    onClick = opts.onClose,
  })
  frame.hide:Layout(28)
  frame.hide.frame:ClearAllPoints()
  frame.hide.frame:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
  ns.UI.ApplyWindowStatus({
    SetStatusTable = function(_, status)
      frame.status = status
      if type(status.left) == "number" and type(status.top) == "number" then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", status.left, status.top)
      end
    end,
  }, opts.windowName, opts.width, 0)
  frame:Hide()
  return frame
end

-- Lays `content` (a kit stack made on the frame) out inside the frame, sizes the frame to it and shows it.
function PopupFrame.Fit(frame, content, width)
  local height = content:Layout(width - 2 * PADDING_SIDE)
  ns.Kit.Place(content, frame, PADDING_SIDE, PADDING_TOP)
  frame:SetSize(width, height + PADDING_TOP + PADDING_BOTTOM)
  frame.shape:Resize()
  frame:Show()
end

ns.PopupFrame = PopupFrame
