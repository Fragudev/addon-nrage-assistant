local _, ns = ...

-- Data widgets: the table, the divided list and the item label (icon + name + tooltip).
local Kit = ns.Kit or {}
ns.Kit = Kit

local Theme, Util, Icons = Kit.Theme, Kit.Util, Kit.Icons
local setColor = Kit.SetTextColor

-- An item as the game shows it: its icon, its name in the quality color, and its tooltip on hover.
-- opts: itemId, text, color (token or { r, g, b, a }), size, onClick, icon (a texture path, overrides the lookup).
Kit.Define("ItemLabel", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.icon = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.icon:SetPoint("LEFT")
    obj.fs = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.fs:SetJustifyH("LEFT")
    obj.fs:SetWordWrap(false)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and obj.opts.onClick then
        obj.opts.onClick(obj)
      end
    end)
    obj.frame:SetScript("OnEnter", function()
      local id = obj.opts and obj.opts.itemId
      if type(id) == "number" and GameTooltip then
        GameTooltip:SetOwner(obj.frame, "ANCHOR_RIGHT")
        -- The tooltip may refuse an item the client has not seen; the icon and name still show.
        if pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. id) then
          GameTooltip:Show()
        else
          GameTooltip:Hide()
        end
      end
    end)
    obj.frame:SetScript("OnLeave", function()
      if GameTooltip then
        GameTooltip:Hide()
      end
    end)
  end,
  apply = function(obj, opts)
    obj.size = opts.size or 24
    obj.icon:SetSize(obj.size, obj.size)
    obj.icon:SetTexture(opts.icon or ns.Platform.GetItemIcon(opts.itemId))
    obj.icon:SetVertexColor(1, 1, 1, 1)
    obj.fs:ClearAllPoints()
    obj.fs:SetPoint("LEFT", obj.size + 8, 0)
    obj.fs:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.fs, opts.color or "text")
    obj.fs:SetText(opts.text or "")
  end,
  layout = function(obj, width)
    obj.fs:SetWidth(math.max(0, width - obj.size - 8))
    return obj.size
  end,
  natural = function(obj)
    return obj.size + 8 + math.ceil(obj.fs:GetStringWidth() or 0)
  end,
})

-- One row of a Table: a header (muted capitals, clickable to sort) or a body row. opts: columns, cells (by column
-- key), header, index (for the striping), highlight (the own row: accent wash), sort = { key, descending },
-- onSort(key), onClick(), height.
local function textCell(spec)
  if type(spec) == "table" then
    return spec.text, spec.color, spec.style
  end
  return spec, nil, nil
end

local WIDGET_CELLS = {
  button = "Button",
  iconButton = "IconButton",
  dropdown = "Dropdown",
  badge = "Badge",
  item = "ItemLabel",
  chip = "StatusChip",
  edit = "EditBox",
  label = "Label",
}

Kit.Define("TableRow", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.stripe = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.stripe:SetAllPoints(obj.frame)
    obj.wash = obj.frame:CreateTexture(nil, "BORDER")
    obj.wash:SetAllPoints(obj.frame)
    obj.texts, obj.hits = {}, {}
    obj.frame:SetScript("OnClick", function()
      if obj.opts and obj.opts.onClick then
        obj.opts.onClick(obj)
      end
    end)
    obj.frame:SetScript("OnEnter", function()
      if obj.opts and obj.opts.onClick then
        obj.wash:SetColorTexture(Theme.Color("hover"))
      end
    end)
    obj.frame:SetScript("OnLeave", function()
      if obj.opts then
        obj.wash:SetColorTexture(obj.washColor())
      end
    end)
  end,
  apply = function(obj, opts)
    obj.columns = opts.columns
    obj.rowHeight = opts.height or (opts.header and Theme.metrics.tableHeader or Theme.metrics.tableRow)
    if opts.header then
      obj.stripe:SetColorTexture(0, 0, 0, 0)
    elseif (opts.index or 1) % 2 == 0 then
      obj.stripe:SetColorTexture(0, 0, 0, 0.2)
    else
      obj.stripe:SetColorTexture(0, 0, 0, 0.1)
    end
    obj.washColor = function()
      if opts.highlight then
        return Theme.Color("accent", 0.14)
      end
      return 0, 0, 0, 0
    end
    obj.wash:SetColorTexture(obj.washColor())
    obj.cellOrder = {}
    local textIndex = 0
    for index, column in ipairs(opts.columns) do
      local spec = opts.header and column.title or (opts.cells or {})[column.key]
      local kindName = type(spec) == "table" and spec.widget and WIDGET_CELLS[spec.widget]
      if kindName then
        local widget = Kit[kindName](obj, spec.opts)
        obj.cellOrder[index] = { widget = widget, spec = spec }
      else
        textIndex = textIndex + 1
        local fs = obj.texts[textIndex]
        if not fs then
          fs = obj.frame:CreateFontString(nil, "OVERLAY")
          fs:SetWordWrap(false)
          obj.texts[textIndex] = fs
        end
        local text, color, style = textCell(spec)
        local headerStyle = opts.header and "label" or (style or "body")
        fs:SetFontObject(Theme.StyleFont(headerStyle))
        setColor(fs, color or (opts.header and "muted" or "text"))
        text = text == nil and "" or tostring(text)
        if opts.header then
          text = Util.Upper(text)
        end
        fs:SetText(text)
        fs:SetJustifyH(column.align or "LEFT")
        fs:Show()
        obj.cellOrder[index] = { fs = fs, spec = spec }
      end
    end
    for extra = textIndex + 1, #obj.texts do
      obj.texts[extra]:Hide()
    end
    -- Header cells are clickable to sort, and show the direction with a chevron.
    for _, hit in ipairs(obj.hits) do
      hit.frame:Hide()
    end
    obj.arrow = obj.arrow or obj.frame:CreateTexture(nil, "OVERLAY")
    obj.arrow:Hide()
  end,
  layout = function(obj, width)
    local opts = obj.opts
    local pad = 14
    local specs = {}
    for index, column in ipairs(obj.columns) do
      specs[index] = { weight = column.weight, width = column.width }
      if column.weight == nil and column.width == nil then
        specs[index].weight = 1
      end
    end
    local widths = Util.Distribute(math.max(0, width - pad * 2), specs, 8)
    local x = pad
    for index, column in ipairs(obj.columns) do
      local cell = obj.cellOrder[index]
      local w = widths[index]
      if cell.widget then
        local h = cell.widget:Layout(w)
        Kit.Place(cell.widget, obj.frame, x, math.floor((obj.rowHeight - h) / 2))
      else
        cell.fs:ClearAllPoints()
        cell.fs:SetPoint("LEFT", obj.frame, "LEFT", x, 0)
        cell.fs:SetWidth(w)
      end
      if opts.header and column.sortable then
        local hit = obj.hits[index]
        if not hit then
          hit = { frame = CreateFrame("Button", nil, obj.frame) }
          hit.frame:SetScript("OnClick", function()
            if obj.opts and obj.opts.onSort then
              obj.opts.onSort(column.key)
            end
          end)
          obj.hits[index] = hit
        end
        hit.frame:ClearAllPoints()
        hit.frame:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", x, 0)
        hit.frame:SetSize(w, obj.rowHeight)
        hit.frame:Show()
        if opts.sort and opts.sort.key == column.key then
          local labelWidth = math.ceil(cell.fs:GetStringWidth() or 0)
          Icons.Apply(obj.arrow, "chevron", "dim")
          obj.arrow:SetSize(10, 10)
          obj.arrow:SetRotation(opts.sort.descending and -math.pi / 2 or math.pi / 2)
          obj.arrow:ClearAllPoints()
          obj.arrow:SetPoint("LEFT", obj.frame, "LEFT", x + math.min(labelWidth, w - 12) + 6, 0)
          obj.arrow:Show()
        end
      end
      x = x + w + 8
    end
    return obj.rowHeight
  end,
  reset = function(obj)
    for _, hit in pairs(obj.hits) do
      hit.frame:Hide()
    end
  end,
})

-- A table: header row, body rows with subtle striping, the own row highlighted. opts: columns = { { key, title,
-- weight | width, align, sortable } }, rows = { { key, cells = { [columnKey] = text | cell }, highlight, onClick } },
-- sort = { key, descending }, onSort(key), emptyText, rowHeight. A cell is a string, { text, color, style } or
-- { widget = "button" | "iconButton" | "dropdown" | "badge" | "item" | "chip" | "edit" | "label", opts = {...} }.
Kit.Define("Table", {
  create = function(obj)
    obj.border = Kit.Pixel.Border(obj.frame, "border")
  end,
  apply = function(obj, opts)
    obj.gap = 0
    obj.border:SetColor("border")
    Kit.TableRow(obj, {
      columns = opts.columns,
      header = true,
      sort = opts.sort,
      onSort = opts.onSort,
    })
    if #(opts.rows or {}) == 0 and opts.emptyText then
      Kit.Label(obj, { text = opts.emptyText, color = "muted", align = "CENTER", layout = { gap = 18 } })
      return
    end
    for index, row in ipairs(opts.rows or {}) do
      Kit.TableRow(obj, {
        columns = opts.columns,
        cells = row.cells,
        index = index,
        highlight = row.highlight,
        onClick = row.onClick,
        height = opts.rowHeight,
      })
    end
  end,
  layout = function(obj, width)
    local height = Kit.LayoutStack(obj, width, 0, nil)
    if obj.opts.emptyText and #(obj.opts.rows or {}) == 0 then
      height = height + 18
    end
    return height
  end,
})

-- One row of a divided list: a status chip, a title with a sub-line, a value on the right, and optionally a widget
-- on the right. opts: status, icon, title, subtitle, value, valueColor, badge = { text, color }, right = { widget,
-- opts }, onClick, selected, divider (a line above), titleColor, titleWidget = { widget, opts } (replaces the title).
Kit.Define("ListRow", {
  frameType = "Button",
  create = function(obj)
    obj.frame:RegisterForClicks("LeftButtonUp")
    obj.line = obj.frame:CreateTexture(nil, "BORDER")
    obj.line:SetPoint("TOPLEFT")
    obj.line:SetPoint("TOPRIGHT")
    obj.line:SetHeight(1)
    obj.wash = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.wash:SetAllPoints(obj.frame)
    obj.bar = obj.frame:CreateTexture(nil, "ARTWORK")
    obj.bar:SetPoint("TOPLEFT", 0, -8)
    obj.bar:SetPoint("BOTTOMLEFT", 0, 8)
    obj.bar:SetWidth(Theme.metrics.navBar)
    obj.title = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.title:SetJustifyH("LEFT")
    obj.title:SetWordWrap(false)
    obj.sub = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.sub:SetJustifyH("LEFT")
    obj.sub:SetWordWrap(false)
    obj.value = obj.frame:CreateFontString(nil, "OVERLAY")
    obj.value:SetJustifyH("RIGHT")
    obj.value:SetWordWrap(false)
    obj.frame:SetScript("OnClick", function()
      if obj.opts and obj.opts.onClick then
        obj.opts.onClick(obj)
      end
    end)
    obj.frame:SetScript("OnEnter", function()
      if obj.opts and obj.opts.onClick and not obj.opts.selected then
        obj.wash:SetColorTexture(Theme.Color("hover"))
      end
    end)
    obj.frame:SetScript("OnLeave", function()
      if obj.opts and obj.opts.selected then
        obj.wash:SetColorTexture(Theme.Color("selected"))
      elseif obj.opts then
        obj.wash:SetColorTexture(0, 0, 0, 0)
      end
    end)
  end,
  apply = function(obj, opts)
    obj.line:SetColorTexture(Theme.Color("border"))
    obj.line:SetShown(opts.divider == true)
    if opts.selected then
      obj.wash:SetColorTexture(Theme.Color("selected"))
      obj.bar:SetColorTexture(Theme.Color("accent"))
      obj.bar:Show()
    else
      obj.wash:SetColorTexture(0, 0, 0, 0)
      obj.bar:Hide()
    end
    obj.title:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.title, opts.titleColor or "text")
    obj.title:SetText(opts.title or "")
    obj.sub:SetFontObject(Theme.StyleFont("small"))
    setColor(obj.sub, "muted")
    obj.sub:SetText(opts.subtitle or "")
    obj.value:SetFontObject(Theme.StyleFont("body"))
    setColor(obj.value, opts.valueColor or "dim")
    obj.value:SetText(opts.value or "")
    obj.chip, obj.badge, obj.rightWidget = nil, nil, nil
    if opts.status then
      obj.chip = Kit.StatusChip(obj, { status = opts.status, icon = opts.icon, size = Theme.metrics.chip })
    end
    if opts.badge then
      obj.badge = Kit.Badge(obj, { text = opts.badge.text, color = opts.badge.color })
    end
    if opts.right then
      obj.rightWidget = Kit[WIDGET_CELLS[opts.right.widget] or opts.right.widget](obj, opts.right.opts)
    end
  end,
  layout = function(obj, width)
    local opts = obj.opts
    local padX, padY = Theme.metrics.listRowPadX, Theme.metrics.listRowPadY
    local height = padY * 2 + Theme.LineHeight("body")
    local hasSub = opts.subtitle ~= nil and opts.subtitle ~= ""
    if hasSub then
      height = height + Theme.LineHeight("small") + 2
    end
    local left = padX
    if obj.chip then
      obj.chip:Layout(Theme.metrics.chip)
      Kit.Place(obj.chip, obj.frame, padX, math.floor((height - Theme.metrics.chip) / 2))
      left = left + Theme.metrics.chip + 12
    end
    local right = padX
    if obj.rightWidget then
      local w = obj.rightWidget:NaturalWidth() or 160
      w = math.min(w, math.floor(width * 0.4))
      local h = obj.rightWidget:Layout(w)
      Kit.Place(obj.rightWidget, obj.frame, width - padX - w, math.floor((height - h) / 2))
      right = right + w + 12
    end
    if obj.badge then
      local w = obj.badge:NaturalWidth()
      obj.badge:Layout(w)
      Kit.Place(obj.badge, obj.frame, width - right - w, math.floor((height - 20) / 2))
      right = right + w + 12
    end
    if opts.value and opts.value ~= "" then
      local valueWidth = math.min(math.floor(width * 0.35), math.ceil(obj.value:GetStringWidth() or 0))
      obj.value:ClearAllPoints()
      obj.value:SetPoint("RIGHT", obj.frame, "RIGHT", -right, 0)
      obj.value:SetWidth(valueWidth)
      obj.value:Show()
      right = right + valueWidth + 12
    else
      obj.value:Hide()
    end
    local textWidth = math.max(0, width - left - right)
    obj.title:ClearAllPoints()
    obj.title:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", left, -padY)
    obj.title:SetWidth(textWidth)
    obj.sub:ClearAllPoints()
    obj.sub:SetPoint("TOPLEFT", obj.frame, "TOPLEFT", left, -(padY + Theme.LineHeight("body") + 2))
    obj.sub:SetWidth(textWidth)
    obj.sub:SetShown(hasSub)
    return height
  end,
})

-- A card of divided rows. opts: rows = { <ListRow opts> ... }; the dividers are added here.
Kit.Define("List", {
  create = function(obj)
    obj.bg = obj.frame:CreateTexture(nil, "BACKGROUND")
    obj.bg:SetAllPoints(obj.frame)
    obj.border = Kit.Pixel.Border(obj.frame, "border")
  end,
  apply = function(obj, opts)
    obj.bg:SetColorTexture(Theme.Color("panel"))
    for index, row in ipairs(opts.rows or {}) do
      row.divider = index > 1
      Kit.ListRow(obj, row)
    end
  end,
  layout = function(obj, width)
    return Kit.LayoutStack(obj, width, 0, nil)
  end,
})
