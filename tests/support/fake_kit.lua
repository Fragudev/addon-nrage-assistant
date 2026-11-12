-- A fake of the kit's API, for the smoke test of the window. Kit.<Kind>(parent, opts) records a node with its opts
-- and children instead of building frames, so every tab can be drawn for every role and its controls pressed.
-- The pure kit modules (Theme, Util, Calendar, Icons) are the real ones.
local M = {}

-- Every node under `root` (itself included), depth first.
function M.walk(root, visit)
  visit(root)
  for _, child in ipairs(root.items or {}) do
    M.walk(child, visit)
  end
end

function M.find_all(root, kind, predicate)
  local found = {}
  M.walk(root, function(node)
    if node.kind == kind and (predicate == nil or predicate(node)) then
      found[#found + 1] = node
    end
  end)
  return found
end

-- The first node of `kind` whose text (or label, title, caption) is `text`.
function M.find(root, kind, text)
  return M.find_all(root, kind, function(node)
    if text == nil then
      return true
    end
    local o = node.opts or {}
    return o.text == text or o.label == text or o.title == text or o.caption == text
  end)[1]
end

-- All the visible words under `root`, one per line, to search with find().
function M.text(root)
  local parts = {}
  M.walk(root, function(node)
    local o = node.opts or {}
    for _, key in ipairs({
      "text",
      "title",
      "label",
      "caption",
      "description",
      "hint",
      "value",
      "subtitle",
      "emptyText",
    }) do
      if type(o[key]) == "string" or type(o[key]) == "number" then
        parts[#parts + 1] = tostring(o[key])
      end
    end
    if o.badge and o.badge.text then
      parts[#parts + 1] = o.badge.text
    end
    for _, row in ipairs(o.rows or {}) do
      if row.cells then
        for _, cell in pairs(row.cells) do
          local value = type(cell) == "table" and (cell.text or (cell.opts and cell.opts.text)) or cell
          if value ~= nil then
            parts[#parts + 1] = tostring(value)
          end
        end
      end
      for _, key in ipairs({ "title", "subtitle", "value" }) do
        if type(row[key]) == "string" then
          parts[#parts + 1] = row[key]
        end
      end
    end
    for _, stat in ipairs(o.stats or {}) do
      parts[#parts + 1] = tostring(stat.value)
    end
  end)
  return table.concat(parts, "\n")
end

-- Presses a node: its onClick, else onToggle, else onSelect.
function M.press(node, ...)
  local o = assert(node.opts, "node without opts")
  local fn = o.onClick or o.onToggle or o.onSelect
  assert(fn, "nothing to press on " .. tostring(node.kind))
  return fn(...)
end

local function new_node(kind, parent, opts)
  local node = { kind = kind, opts = opts or {}, items = {}, parent = parent, calls = {} }
  node.frame = {}
  node.text = (opts or {}).text
  return node
end

local methods = {}

function methods.Add(self, child)
  self.items[#self.items + 1] = child
  child.parent = self
  return child
end
function methods.Clear(self)
  self.items = {}
end
function methods.Release(self)
  self.released = true
end
function methods.SetText(self, text)
  self.text = text
  self.opts.text = text
end
function methods.GetText(self)
  return self.text or self.opts.text or ""
end
function methods.GetValueText(self)
  return self.text or self.opts.text or ""
end
function methods.SetValue(self, value)
  self.value = value
  self.opts.value = value
end
function methods.GetValue(self)
  return self.value or self.opts.value
end
function methods.SetChecked(self, checked)
  self.checked = checked
end
function methods.GetChecked(self)
  return self.checked
end
function methods.SetShown(self, shown)
  self.hidden = not shown
end
function methods.SetDisabled(self, disabled)
  self.opts.disabled = disabled
end
function methods.SetError(self, flag)
  self.opts.error = flag
end
function methods.Layout()
  return 0
end
function methods.NaturalWidth()
  return 50
end
function methods.GetScroll(self)
  return self.scroll or 0
end
function methods.SetScroll(self, value)
  self.scroll = value
end

local node_meta = {
  __index = function(_, name)
    if methods[name] then
      return methods[name]
    end
    if type(name) == "string" and name:match("^%u") then
      return function() end
    end
    return nil
  end,
}

-- Builds the fake. `real` = the real Kit table loaded with only the pure modules (Theme, Util, Calendar, Icons, Pixel).
function M.new(real)
  local Kit = { Theme = real.Theme, Util = real.Util, Calendar = real.Calendar, Icons = real.Icons, Pixel = real.Pixel }
  local fake = { nodes = {} }
  Kit.fake = fake
  Kit.Place = function() end

  local function make(kind, parent, opts)
    local node = setmetatable(new_node(kind, parent, opts), node_meta)
    fake.nodes[#fake.nodes + 1] = node
    if type(parent) == "table" and parent.items then
      parent:Add(node)
    end
    return node
  end

  setmetatable(Kit, {
    __index = function(_, kind)
      if type(kind) == "string" and kind:match("^%u") then
        return function(parent, opts)
          return make(kind, parent, opts)
        end
      end
      return nil
    end,
  })

  -- The menu, popovers and modal record what they were asked and run the builders on a fake stack.
  Kit.Menu = {
    Open = function(anchor, items, onSelect, opts)
      fake.menu = { anchor = anchor, items = items, onSelect = onSelect, opts = opts }
    end,
    Close = function()
      fake.menu = nil
    end,
  }
  local popups = {}
  Kit.Popup = {
    Get = function(layer)
      if not popups[layer] then
        popups[layer] = {
          Open = function(self, anchor, width, build, opts)
            self.anchor, self.width, self.build, self.opts = anchor, width, build, opts
            self.stack = make("Stack", nil, {})
            build(self.stack)
            self.open = true
          end,
          Rebuild = function(self)
            self.stack = make("Stack", nil, {})
            self.build(self.stack)
          end,
          Close = function(self)
            self.open = false
          end,
          IsOpen = function(self)
            return self.open == true
          end,
        }
      end
      return popups[layer]
    end,
  }
  Kit.CloseAllPopups = function()
    for _, popup in pairs(popups) do
      popup.open = false
    end
  end
  -- `fake.editFocus` stands for a kit edit box that has the keyboard.
  Kit.HasEditFocus = function()
    return fake.editFocus ~= nil
  end
  Kit.CommitEdit = function()
    fake.commits = (fake.commits or 0) + 1
    fake.editFocus = nil
  end
  Kit.DiscardEdit = function()
    fake.discards = (fake.discards or 0) + 1
    fake.editFocus = nil
  end
  Kit.Modal = {
    Open = function(opts)
      local stack = make("Stack", nil, {})
      opts.build(stack)
      fake.modal = { opts = opts, stack = stack }
    end,
    Close = function()
      local modal = fake.modal
      fake.modal = nil
      if modal and modal.opts.onClose then
        modal.opts.onClose()
      end
    end,
    IsOpen = function()
      return fake.modal ~= nil
    end,
  }

  -- The window: a node with a body stack the sidebar and content are drawn into.
  Kit.Window = {
    New = function(opts)
      local window = make("Window", nil, opts)
      window.shown = false
      window.buttons = {}
      for _, button in ipairs(opts.buttons or {}) do
        window.buttons[button.name or button.icon] = button
      end
      window.Show = function(self)
        self.shown = true
        if opts.onResize then
          opts.onResize(1000, 588)
        end
      end
      window.Hide = function(self)
        if self.shown then
          self.shown = false
          if opts.onClose then
            opts.onClose()
          end
        end
      end
      window.IsShown = function(self)
        return self.shown
      end
      window.Toggle = function(self)
        if self.shown then
          self:Hide()
        else
          self:Show()
        end
      end
      window.SetStatusTable = function(self, status)
        self.status = status
      end
      window.SetPill = function(self, text, status)
        self.pill = { text = text, status = status }
      end
      window.SetTitle = function() end
      window.SetVersion = function() end
      window.body = {}
      -- The frame answers what the drag of the sidebar edge asks: its width (window.frameWidth, 1000 by default)
      -- and its scale.
      window.frame = {
        GetWidth = function()
          return window.frameWidth or 1000
        end,
        GetEffectiveScale = function()
          return 1
        end,
      }
      window.NotifyResize = function()
        if opts.onResize then
          opts.onResize(window.frameWidth or 1000, 588)
        end
      end
      window.ScheduleResize = window.NotifyResize
      return window
    end,
  }
  return Kit
end

return M
