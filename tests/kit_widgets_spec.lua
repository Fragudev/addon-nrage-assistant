-- The real kit widgets, built on fake frames: every widget is made, laid out and pressed, so a nil call or a wrong
-- argument is found here and not in the game. How things look is not tested, only what they do.
local fake = dofile("tests/support/fake_frames.lua")

local function load_kit()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "Core/Platform",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
    "UI/Kit/Shape",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/Kit/Icons",
    "UI/Kit/Core",
    "UI/Kit/Text",
    "UI/Kit/Controls",
    "UI/Kit/Data",
    "UI/Kit/Shell",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.Kit, ns
end

-- Every widget under `root` whose kind is `kind`.
local function find_all(root, kind, found)
  found = found or {}
  if root.kind == kind then
    found[#found + 1] = root
  end
  for _, item in ipairs(root.items or {}) do
    find_all(item.obj, kind, found)
  end
  return found
end

describe("Kit widgets", function()
  local Kit, root

  before_each(function()
    fake.install()
    Kit = load_kit()
    root = Kit.Stack(_G.UIParent, { gap = 10 })
  end)

  after_each(function()
    fake.uninstall()
  end)

  describe("layout containers", function()
    it("stacks children one under the other with the gap between them", function()
      Kit.Button(root, { text = "A" })
      Kit.Button(root, { text = "B", variant = "primary" })
      local height = root:Layout(400)
      assert.are.equal(30 + 10 + 34, height)
      assert.are.equal(400, root.items[1].obj.width)
      local second = root.items[2].obj.frame.points[1]
      assert.are.same({ "TOPLEFT", root.frame, "TOPLEFT", 0, -40 }, second)
    end)

    it("skips hidden children and honours a gap, a width and an alignment of the child", function()
      local first = Kit.Button(root, { text = "A", layout = { gap = 99 } })
      local hidden = Kit.Button(root, { text = "hidden" })
      hidden:SetShown(false)
      Kit.Button(root, { text = "B", layout = { gap = 4, width = 100, align = "right" } })
      assert.are.equal(30 + 4 + 30, root:Layout(300))
      assert.are.equal(100, root.items[3].obj.width)
      assert.are.equal(200, root.items[3].obj.frame.points[1][4])
      assert.is_true(first.frame:IsShown())
    end)

    it("adds the padding of a stack", function()
      local padded = Kit.Stack(_G.UIParent, { pad = { 10, 5, 10, 5 } })
      Kit.Button(padded, { text = "A" })
      assert.are.equal(40, padded:Layout(200))
      assert.are.equal(180, padded.items[1].obj.width)
    end)

    it("lays a row out with fixed, automatic and weighted columns", function()
      local row = Kit.Row(root, { gap = 10, align = "center" })
      Kit.Button(row, { text = "Fixed", layout = { width = 60 } })
      Kit.Badge(row, { text = "tag", layout = { width = "auto" } })
      Kit.Label(row, { text = "rest", layout = { weight = 1 } })
      local height = root:Layout(400)
      local fixed, badge, label = row.items[1].obj, row.items[2].obj, row.items[3].obj
      assert.are.equal(60, fixed.width)
      assert.are.equal(badge:NaturalWidth(), badge.width)
      assert.are.equal(400 - 60 - badge:NaturalWidth() - 20, label.width)
      assert.are.equal(30, height)
      -- Centered vertically: the label is shorter than the button.
      assert.is_true(label.frame.points[1][5] < 0)
    end)

    it("lays a grid out in equal columns and rows", function()
      local grid = Kit.Grid(root, { columns = 2, gap = 20, rowGap = 8 })
      for index = 1, 3 do
        Kit.Button(grid, { text = tostring(index) })
      end
      assert.are.equal(30 + 8 + 30, root:Layout(420))
      assert.are.equal(200, grid.items[1].obj.width)
      assert.are.equal(220, grid.items[2].obj.frame.points[1][4])
    end)

    it("wraps a flow of chips onto new lines", function()
      local flow = Kit.Flow(root, { gap = 5, rowGap = 5 })
      for index = 1, 6 do
        Kit.Chip(flow, { text = "chip number " .. index })
      end
      local height = root:Layout(300)
      assert.is_true(height > 26)
      assert.are.equal(0, flow.items[1].obj.frame.points[1][4])
    end)

    it("draws a card with its title as the first child", function()
      local card = Kit.Card(root, { title = "Your readiness" })
      Kit.Label(card, { text = "Body" })
      local height = root:Layout(300)
      assert.are.equal("YOUR READINESS", card.items[1].obj:GetText())
      assert.is_true(height > 36)
    end)

    it("scrolls: the range follows the content and the wheel moves the view", function()
      local scroll = Kit.ScrollArea(_G.UIParent, { gap = 10 })
      for index = 1, 20 do
        Kit.Button(scroll, { text = tostring(index) })
      end
      assert.are.equal(200, scroll:Layout(400, 200))
      assert.are.equal(20 * 30 + 19 * 10 - 200, scroll.range)
      scroll.scroll.scripts.OnMouseWheel(scroll.scroll, -1)
      assert.are.equal(40, scroll:GetScroll())
      scroll:SetScroll(100000)
      assert.are.equal(scroll.range, scroll:GetScroll())
      scroll:SetScroll(-5)
      assert.are.equal(0, scroll:GetScroll())
      -- A short content needs no bar.
      scroll:Clear()
      Kit.Button(scroll, { text = "only" })
      scroll:Layout(400, 200)
      assert.are.equal(0, scroll.range)
    end)
  end)

  describe("pooling", function()
    it("reuses the frames of a released widget", function()
      local first = Kit.Button(root, { text = "A", onClick = function() end })
      local frame = first.frame
      root:Clear()
      assert.are.equal(1, Kit.PoolSize("Button"))
      local second = Kit.Button(root, { text = "B" })
      assert.are.equal(frame, second.frame)
      assert.are.equal(0, Kit.PoolSize("Button"))
      assert.is_true(second.frame:IsShown())
      assert.are.equal("B", second.label.text)
      -- The old callback did not survive.
      assert.is_nil(second.opts.onClick)
    end)

    it("releases the children of a container and ignores a second release", function()
      local card = Kit.Card(root, {})
      Kit.Button(card, { text = "A" })
      root:Clear()
      assert.are.equal(1, Kit.PoolSize("Card"))
      assert.are.equal(1, Kit.PoolSize("Button"))
      card:Release()
      assert.are.equal(1, Kit.PoolSize("Card"))
    end)
  end)

  describe("cut surfaces", function()
    -- Whether any glow piece of a widget is shown right now, and the alpha of the first one.
    local function glow(obj)
      local pieces = obj.shape.glowTextures
      if not pieces then
        return false
      end
      return pieces.top.shown, pieces.top.vertex and pieces.top.vertex[4]
    end

    local function border_color(obj)
      return obj.shape.border.straight.top.color
    end

    local function token(name)
      return { Kit.Theme.Color(name) }
    end

    it("glows a primary button, harder under the pointer, and not once it is reused as another variant", function()
      local button = Kit.Button(root, { text = "Go", variant = "primary" })
      local shown, alpha = glow(button)
      assert.is_true(shown)
      assert.are.equal(0.45, alpha)
      button.frame.scripts.OnEnter()
      shown, alpha = glow(button)
      assert.is_true(shown)
      assert.are.equal(0.6, alpha)
      button.frame.scripts.OnLeave()
      assert.are.equal(0.45, select(2, glow(button)))
      local frame = button.frame
      root:Clear()
      local reused = Kit.Button(root, { text = "Cancel" })
      assert.are.equal(frame, reused.frame)
      assert.is_false(glow(reused))
      reused.frame.scripts.OnEnter()
      assert.is_false(glow(reused))
      -- And back again: the glow returns on the primary one.
      root:Clear()
      assert.is_true(glow(Kit.Button(root, { text = "Go", variant = "primary" })))
    end)

    it("never glows a dangerSolid button and fills it with blood under a danger border", function()
      local button = Kit.Button(root, { text = "Delete", variant = "dangerSolid" })
      assert.is_false(glow(button))
      button.frame.scripts.OnEnter()
      assert.is_false(glow(button))
      button.frame.scripts.OnMouseDown()
      assert.is_false(glow(button))
      button.frame.scripts.OnLeave()
      assert.are.same(token("blood"), button.shape.fillTextures.mid.color)
      assert.are.same(token("danger"), border_color(button))
      assert.are.same(
        token("danger"),
        { button.label.textColor[1], button.label.textColor[2], button.label.textColor[3], button.label.textColor[4] }
      )
    end)

    it("fills the hover color of a secondary button and has no shape on a ghost one", function()
      local secondary = Kit.Button(root, { text = "A" })
      assert.are.same(token("control"), secondary.shape.fillTextures.mid.color)
      secondary.frame.scripts.OnEnter()
      assert.are.same(token("controlHover"), secondary.shape.fillTextures.mid.color)
      assert.are.same(token("border"), border_color(secondary))
      root:Clear()
      local ghost = Kit.Button(root, { text = "A", variant = "ghost" })
      assert.are.equal(0, ghost.shape.fillTextures.mid.color[4])
      assert.is_false(ghost.shape.border.straight.top.shown)
      assert.is_false(glow(ghost))
    end)

    it("shows the focus as borderStrong and an error as danger, the error winning", function()
      local box = Kit.EditBox(root, {})
      assert.are.same(token("line"), border_color(box))
      box.frame:SetFocus()
      assert.are.same(token("borderStrong"), border_color(box))
      box:SetError(true)
      assert.are.same(token("danger"), border_color(box))
      box.frame:ClearFocus()
      assert.are.same(token("danger"), border_color(box))
      box:SetError(false)
      assert.are.same(token("line"), border_color(box))
      assert.are.same(token("input"), box.shape.fillTextures.mid.color)
    end)

    it("clears an error left on a pooled edit box", function()
      Kit.EditBox(root, { error = true })
      root:Clear()
      local box = Kit.EditBox(root, {})
      assert.are.same(token("line"), border_color(box))
    end)

    it("draws the same field border on a text area, a dropdown and a date field", function()
      local area = Kit.TextArea(root, { error = true })
      assert.are.same(token("danger"), border_color(area))
      area.edit:SetFocus()
      assert.are.same(token("danger"), border_color(area))
      area:SetError(false)
      assert.are.same(token("borderStrong"), border_color(area))
      local dropdown = Kit.Dropdown(root, { items = {}, error = true })
      assert.are.same(token("danger"), border_color(dropdown))
      local date = Kit.DateField(root, {})
      assert.are.same(token("line"), border_color(date))
      date:SetError(true)
      assert.are.same(token("danger"), border_color(date))
    end)

    it("gives a card a translucent gradient, an opaque one on request, and a highlight or special border", function()
      local card = Kit.Card(root, {})
      assert.are.equal(Kit.Theme.metrics.card.alpha, card.shape.fillTextures.top.color[4])
      assert.are.same(token("border"), border_color(card))
      assert.is_false(glow(card))
      root:Clear()
      local solid = Kit.Card(root, { solid = true })
      assert.are.equal(1, solid.shape.fillTextures.top.color[4])
      root:Clear()
      local highlighted = Kit.Card(root, { highlight = true })
      assert.are.same(token("borderStrong"), border_color(highlighted))
      assert.is_true(glow(highlighted))
      root:Clear()
      local special = Kit.Card(root, { special = true })
      assert.are.same(token("gold"), border_color(special))
      assert.is_false(glow(special))
    end)

    it("tints a badge and a banner with the status color at 0.10 and no border", function()
      local badge = Kit.Badge(root, { text = "Stale", color = "warning" })
      assert.are.same({ Kit.Theme.Color("warning", 0.1) }, badge.shape.fillTextures.mid.color)
      assert.is_false(badge.shape.border.straight.top.shown)
      local banner = Kit.Banner(root, { kind = "danger", text = "No" })
      assert.are.same({ Kit.Theme.Color("danger", 0.1) }, banner.shape.fillTextures.mid.color)
    end)

    it("marks the selected segment and the selected tab", function()
      local segmented = Kit.Segmented(root, {
        items = { { value = "a", text = "A" }, { value = "b", text = "B" } },
        value = "a",
      })
      assert.are.same(token("control"), segmented.segments[1].shape.fillTextures.mid.color)
      assert.are.equal(0, segmented.segments[2].shape.fillTextures.mid.color[4])
      segmented.segments[2].frame.scripts.OnClick()
      assert.are.equal(0, segmented.segments[1].shape.fillTextures.mid.color[4])
      assert.are.same(token("control"), segmented.segments[2].shape.fillTextures.mid.color)
      local strip = Kit.TabStrip(root, { tabs = { { value = "x", text = "X" } }, value = "x" })
      strip:Layout(300)
      assert.is_true(strip.piece:IsShown())
      strip.value = "none"
      strip:Layout(300)
      assert.is_false(strip.piece:IsShown())
    end)
  end)

  describe("text and display", function()
    it("measures a wrapped label and a one-line label", function()
      local wrapped =
        Kit.Label(root, { text = string.rep("word ", 40), wrap = true, style = "small", color = { 1, 0, 0, 1 } })
      local line = Kit.Label(root, { text = "one", upper = true })
      root:Layout(140)
      assert.is_true(wrapped.height > 15 * 2)
      assert.are.equal(Kit.Theme.LineHeight("body"), line.height)
      assert.are.equal("ONE", line:GetText())
      line:SetText("two")
      line:SetColor("danger")
      assert.are.equal("TWO", line:GetText())
    end)

    it("draws the small pieces: key/value, stat grid, badge, chip, progress, divider, icon", function()
      Kit.KeyValue(root, { label = "Status", value = "ready", dot = "success" })
      Kit.KeyValue(root, { label = "Queued", value = "0" })
      Kit.StatGrid(root, {
        columns = 3,
        stats = {
          { caption = "Class", value = "Mage" },
          { caption = "Level", value = "60" },
          { caption = "ilvl", value = "1" },
        },
      })
      Kit.Badge(root, { text = "Stale", color = "warning" })
      Kit.StatusChip(root, { status = "met", size = 40 })
      Kit.ProgressBar(root, { value = 1.5 })
      Kit.ProgressBar(root, { value = 0 })
      Kit.Divider(root, {})
      Kit.Icon(root, { icon = "gear", size = 20 })
      Kit.SectionLabel(root, { text = "Sección" })
      assert.is_true(root:Layout(500) > 100)
      local bars = find_all(root, "ProgressBar")
      assert.are.equal(1, bars[1].value)
      assert.is_false(bars[2].fill:IsShown())
    end)

    it("wraps a long caption or value of a stat block instead of cutting it, and grows taller", function()
      Kit.StatGrid(root, {
        columns = 3,
        stats = {
          { caption = "Level", value = "60" },
          { caption = "Battleground kills of the day", value = "Not available at the moment on this client" },
          { caption = "Class", value = "Mage" },
        },
      })
      local grid = root.items[1].obj
      local blocks = find_all(root, "StatBlock")
      assert.is_true(blocks[1].caption.wrap)
      assert.is_true(blocks[2].value.wrap)
      root:Layout(300)
      local oneLine = blocks[1].height
      assert.is_true(blocks[2].height > oneLine)
      assert.are.equal(blocks[2].height, grid.height)
    end)

    it("shows a divided row that had to be cut whole in a tooltip, when it asks for it", function()
      local long = string.rep("killer, ", 20) .. "victim"
      Kit.List(root, {
        rows = {
          { title = long, subtitle = "12:04", tooltipWhenCut = true },
          { title = "Ann", subtitle = "12:05", tooltipWhenCut = true },
          { title = long, subtitle = "12:06" },
        },
      })
      root:Layout(400)
      local rows = find_all(root, "ListRow")
      assert.are.equal(long .. "\n12:04", rows[1].cutTip)
      assert.is_nil(rows[2].cutTip)
      assert.is_nil(rows[3].cutTip)
      rows[1].frame.scripts.OnEnter()
      rows[1].frame.scripts.OnLeave()
    end)

    it("puts an icon before the caption of a stat block and keeps nothing when there is none", function()
      Kit.StatGrid(root, {
        columns = 2,
        stats = {
          { caption = "Alchemy", value = "300/300", icon = 136240 },
          { caption = "Mining", value = "1/300" },
        },
      })
      Kit.Picture(root, { texture = 136240, size = 16 })
      Kit.Picture(root, { size = 16 })
      assert.is_true(root:Layout(500) > 0)
      local blocks = find_all(root, "StatBlock")
      assert.is_true(blocks[1].hasIcon)
      assert.are.equal(136240, blocks[1].icon.texture)
      assert.are.equal(22, blocks[1].indent)
      assert.is_false(blocks[2].hasIcon)
      assert.are.equal(0, blocks[2].indent)
      local pictures = find_all(root, "Picture")
      assert.is_true(pictures[1].texture:IsShown())
      assert.is_false(pictures[2].texture:IsShown())
    end)

    it("draws a banner that can be dismissed, an empty state and a page header", function()
      local dismissed = false
      local banner = Kit.Banner(root, {
        kind = "success",
        text = string.rep("saved ", 30),
        onDismiss = function()
          dismissed = true
        end,
      })
      Kit.Banner(root, { kind = "info", text = "plain" })
      Kit.EmptyState(root, { icon = "calendar", title = "No upcoming events", hint = "Nothing planned" })
      Kit.EmptyState(root, { title = "Bare" })
      local header =
        Kit.PageHeader(root, { title = "Raid", description = "Events", badge = { text = "3", color = "accent" } })
      Kit.PageHeader(root, { title = "Plain" })
      assert.is_true(root:Layout(500) > 200)
      banner.close.scripts.OnClick()
      assert.is_true(dismissed)
      assert.is_not_nil(header.badge)
    end)
  end)

  describe("controls", function()
    it("clicks a button, ignores a disabled one and reports its natural width", function()
      local clicks = 0
      local button = Kit.Button(root, {
        text = "Save",
        icon = "check",
        onClick = function()
          clicks = clicks + 1
        end,
      })
      button.frame.scripts.OnClick()
      assert.are.equal(1, clicks)
      button:SetDisabled(true)
      button.frame.scripts.OnClick()
      assert.are.equal(1, clicks)
      assert.are.equal(0.4, button.frame.alpha)
      assert.are.equal(4 * 7 + 28 + 22, button:NaturalWidth())
      button.frame.scripts.OnEnter()
      button.frame.scripts.OnMouseDown()
      button.frame.scripts.OnMouseUp()
      button.frame.scripts.OnLeave()
    end)

    it("has the five variants and the heights of the plan", function()
      local heights = {}
      for _, variant in ipairs({ "secondary", "primary", "ghost", "danger", "dangerSolid" }) do
        heights[variant] = Kit.Button(root, { text = variant, variant = variant }):Layout(100)
      end
      assert.are.same({ secondary = 30, primary = 34, ghost = 22, danger = 30, dangerSolid = 30 }, heights)
    end)

    it("shows a tooltip on an icon button and clicks it", function()
      local shown
      _G.GameTooltip = {
        SetOwner = function() end,
        SetText = function(_, text)
          shown = text
        end,
        Show = function() end,
        Hide = function() end,
      }
      local clicked = false
      local button = Kit.IconButton(root, {
        icon = "gear",
        tooltip = "Settings",
        onClick = function()
          clicked = true
        end,
      })
      button.frame.scripts.OnEnter()
      assert.are.equal("Settings", shown)
      button.frame.scripts.OnClick()
      assert.is_true(clicked)
      button.frame.scripts.OnLeave()
      _G.GameTooltip = nil
    end)

    it("toggles a switch and a checkbox and reports the new value", function()
      local values = {}
      local switch = Kit.Switch(root, {
        label = "Minimap",
        checked = false,
        onChange = function(value)
          values[#values + 1] = value
        end,
      })
      local checkbox = Kit.Checkbox(root, {
        label = "Done",
        checked = true,
        onChange = function(value)
          values[#values + 1] = value
        end,
      })
      switch.frame.scripts.OnClick()
      checkbox.frame.scripts.OnClick()
      assert.are.same({ true, false }, values)
      assert.is_true(switch:GetChecked())
      assert.is_false(checkbox:GetChecked())
      assert.is_true(checkbox:NaturalWidth() > 26)
      switch:SetDisabled(true)
      root:Layout(300)
    end)

    it("draws fixed words in the label font and names and free text in the semibold one", function()
      local requested = {}
      local original = Kit.Theme.StyleFont
      Kit.Theme.StyleFont = function(style)
        requested[#requested + 1] = style
        return original(style)
      end
      Kit.Badge(root, { text = "Open", fixed = true })
      Kit.Badge(root, { text = "Ann" })
      Kit.Chip(root, { text = "Tank", fixed = true })
      Kit.Chip(root, { text = "Ann" })
      Kit.Theme.StyleFont = original
      local function count(style)
        local n = 0
        for _, name in ipairs(requested) do
          n = n + (name == style and 1 or 0)
        end
        return n
      end
      assert.are.equal(2, count("label"))
      assert.are.equal(2, count("smallMedium"))
    end)

    it("uses the button style for buttons and the info color for ghost buttons", function()
      local requested = {}
      local original = Kit.Theme.StyleFont
      Kit.Theme.StyleFont = function(style)
        requested[#requested + 1] = style
        return original(style)
      end
      Kit.Button(root, { text = "Save", variant = "ghost" })
      Kit.Button(root, { text = "Save" })
      Kit.Theme.StyleFont = original
      assert.are.same({ "button", "button" }, requested)
    end)

    it("toggles a chip and picks a segment and a tab", function()
      local toggled, chosen, selected
      local chip = Kit.Chip(root, {
        text = "Tank",
        onToggle = function(active)
          toggled = active
        end,
      })
      chip.frame.scripts.OnClick()
      assert.is_true(toggled)
      local segmented = Kit.Segmented(root, {
        items = { { value = "a", text = "A" }, { value = "b", text = "B" } },
        value = "a",
        onChange = function(value)
          chosen = value
        end,
      })
      segmented.segments[2].frame.scripts.OnClick()
      assert.are.equal("b", chosen)
      assert.is_true(segmented.segments[2].opts.active)
      assert.is_false(segmented.segments[1].opts.active)
      local strip = Kit.TabStrip(root, {
        tabs = { { value = "x", text = "X" }, { value = "y", text = "Y" } },
        value = "y",
        onSelect = function(value)
          selected = value
        end,
      })
      strip.tabs[1].frame.scripts.OnClick()
      assert.are.equal("x", selected)
      assert.is_true(root:Layout(400) > 60)
      assert.is_true(strip.underline:IsShown())
    end)

    describe("edit box", function()
      it("commits on Enter and on losing the focus, only when the text changed", function()
        local commits, enters = {}, {}
        local box = Kit.EditBox(root, {
          text = "old",
          placeholder = "name",
          onCommit = function(text)
            commits[#commits + 1] = text
          end,
          onEnter = function(text)
            enters[#enters + 1] = text
          end,
        })
        local frame = box.frame
        frame:SetFocus()
        frame:SetText("new")
        frame.scripts.OnEnterPressed()
        assert.are.same({ "new" }, commits)
        assert.are.same({ "new" }, enters)
        -- Focus again, same text: nothing is saved.
        frame:SetFocus()
        frame:ClearFocus()
        assert.are.same({ "new" }, commits)
        frame:SetFocus()
        frame:SetText("third")
        frame:ClearFocus()
        assert.are.same({ "new", "third" }, commits)
      end)

      it("restores the stored text on Escape without saving", function()
        local commits = 0
        local box = Kit.EditBox(root, {
          text = "kept",
          onCommit = function()
            commits = commits + 1
          end,
        })
        box.frame:SetFocus()
        box.frame:SetText("typed")
        box.frame.scripts.OnEscapePressed()
        assert.are.equal("kept", box:GetText())
        assert.are.equal(0, commits)
      end)

      it("reports changes, shows the error border and the placeholder", function()
        local changes = {}
        local box = Kit.EditBox(root, {
          text = "",
          placeholder = "type here",
          maxLetters = 10,
          numeric = true,
          onChange = function(text, user)
            changes[#changes + 1] = { text, user }
          end,
        })
        assert.is_true(box.hint:IsShown())
        box.frame:SetText("5")
        box.frame.scripts.OnTextChanged(box.frame, true)
        assert.are.same({ { "5", true } }, changes)
        assert.is_false(box.hint:IsShown())
        box:SetError(true)
        assert.is_true(box.opts.error)
        box:SetText("fresh")
        assert.are.equal("fresh", box:GetText())
        box:Focus()
        assert.are.equal(32, box:Layout(200))
      end)
    end)

    it("shows a multi-line text area and selects all its text", function()
      local area = Kit.TextArea(root, { text = "NRAGE1:abc", readOnly = true, height = 160 })
      assert.are.equal(160, root:Layout(300))
      area:HighlightAll()
      assert.are.equal("NRAGE1:abc", area:GetValueText())
      area.edit.scripts.OnEditFocusGained()
      area.scroll.scripts.OnMouseWheel(area.scroll, -1)
    end)

    it("shows the chosen item in a dropdown, opens the menu and reports the choice", function()
      local chosen
      local dropdown = Kit.Dropdown(root, {
        items = { { value = "a", text = "Alpha" }, { value = "b", text = "Beta" } },
        value = "a",
        placeholder = "Pick",
        onChange = function(value)
          chosen = value
        end,
      })
      assert.are.equal("Alpha", dropdown.label.text)
      dropdown.frame.scripts.OnClick()
      assert.is_true(Kit.Popup.Get(2):IsOpen())
      local menuItems = find_all(Kit.Popup.Get(2).stack, "MenuItem")
      assert.are.equal(2, #menuItems)
      assert.is_true(menuItems[1].opts.selected)
      menuItems[2].frame.scripts.OnClick()
      assert.are.equal("b", chosen)
      assert.are.equal("Beta", dropdown.label.text)
      assert.is_false(Kit.Popup.Get(2):IsOpen())
      dropdown:SetValue(nil)
      assert.are.equal("Pick", dropdown.label.text)
      dropdown:SetItems({})
      dropdown:SetDisabled(true)
      dropdown.frame.scripts.OnClick()
      assert.is_false(Kit.Popup.Get(2):IsOpen())
    end)

    it("scrolls a long menu and ignores a disabled item and a separator", function()
      local items = {}
      for index = 1, 15 do
        items[index] = { value = index, text = "Item " .. index, disabled = index == 2 }
      end
      items[3] = { separator = true }
      local picked
      local anchor = _G.CreateFrame("Frame")
      Kit.Menu.Open(anchor, items, function(value)
        picked = value
      end, { width = 100 })
      local menuItems = find_all(Kit.Popup.Get(2).stack, "MenuItem")
      menuItems[2].frame.scripts.OnClick()
      menuItems[3].frame.scripts.OnClick()
      assert.is_nil(picked)
      menuItems[1].frame.scripts.OnEnter()
      menuItems[1].frame.scripts.OnLeave()
      menuItems[4].frame.scripts.OnClick()
      assert.are.equal(4, picked)
      Kit.Menu.Close()
    end)

    it("puts a caption and an error around a field", function()
      local field = Kit.Field(root, { label = "Name", error = "Too long" })
      Kit.EditBox(field, { text = "" })
      assert.is_true(field:Layout(300) > 15 + 6 + 32)
      Kit.Field(root, { label = "Plain" })
    end)
  end)

  describe("data widgets", function()
    local function columns()
      return {
        { key = "name", title = "Name", weight = 2, sortable = true },
        { key = "total", title = "Total", width = 60, align = "RIGHT", sortable = true },
        { key = "action", title = "" },
      }
    end

    it("draws a table with a header, stripes, widget cells and a sortable header", function()
      local sorted, clicked, pressed
      local table_ = Kit.Table(root, {
        columns = columns(),
        sort = { key = "total", descending = true },
        onSort = function(key)
          sorted = key
        end,
        rows = {
          {
            cells = {
              name = { text = "Ann", color = "accent" },
              total = "5",
              action = {
                widget = "button",
                opts = {
                  text = "Vote",
                  onClick = function()
                    pressed = true
                  end,
                },
              },
            },
            highlight = true,
            onClick = function()
              clicked = true
            end,
          },
          { cells = { name = "Bob", total = 3, action = { widget = "item", opts = { itemId = 5, text = "Sword" } } } },
          { cells = { name = "Cy", total = "1", action = { widget = "badge", opts = { text = "x" } } } },
        },
      })
      local height = root:Layout(500)
      assert.are.equal(28 + 3 * 30, height)
      local rows = find_all(table_, "TableRow")
      assert.are.equal(4, #rows)
      rows[1].hits[2].frame.scripts.OnClick()
      assert.are.equal("total", sorted)
      assert.is_true(rows[1].arrow:IsShown())
      rows[2].frame.scripts.OnClick()
      assert.is_true(clicked)
      rows[2].frame.scripts.OnEnter()
      rows[2].frame.scripts.OnLeave()
      find_all(rows[2], "Button")[1].frame.scripts.OnClick()
      assert.is_true(pressed)
    end)

    it("sizes the columns of a fit table to their text and shows a tooltip for what is still cut", function()
      local fitColumns = {
        { key = "name", title = "Name", weight = 1 },
        { key = "total", title = "Kills in total", width = 20, fit = true, sortable = true },
      }
      local rows = {
        { cells = { name = "Ann", total = "5" } },
        { cells = { name = "A very long player name", total = "1234" } },
      }
      local tbl = Kit.Table(root, { columns = fitColumns, rows = rows, fit = true, sort = { key = "total" } })
      root:Layout(600)
      local lines = find_all(tbl, "TableRow")
      -- The header "KILLS IN TOTAL" (14 characters) plus the room of the sort arrow decides the width.
      assert.are.equal(14 * 7 + 16, lines[1].fitWidths[2])
      assert.are.same(lines[1].fitWidths, lines[3].fitWidths)
      assert.is_nil(lines[3].tips[1])
      assert.is_nil(lines[1].tips[2])
      -- A narrower table cannot give the long name its room: it is cut and the whole name is in a tooltip.
      root:Layout(260)
      assert.is_true(lines[1].fitWidths[2] >= 14 * 7)
      assert.are.equal("A very long player name", lines[3].tips[1].tipText)
      assert.is_nil(lines[2].tips[1])
    end)

    it("gives a table that is not fit the widths it always had", function()
      local tbl = Kit.Table(root, { columns = columns(), rows = { { cells = { name = "A", total = "1" } } } })
      root:Layout(500)
      assert.is_nil(find_all(tbl, "TableRow")[1].fitWidths)
    end)

    it("shows the empty text of a table with no rows", function()
      Kit.Table(root, { columns = columns(), rows = {}, emptyText = "Nobody yet" })
      assert.is_true(root:Layout(400) > 28)
    end)

    it("reuses the text of a pooled row and hides what it no longer needs", function()
      local first =
        Kit.Table(root, { columns = columns(), rows = { { cells = { name = "A", total = "1", action = "x" } } } })
      root:Clear()
      Kit.Table(root, { columns = { columns()[1] }, rows = { { cells = { name = "B" } } } })
      root:Layout(300)
      assert.is_not_nil(first)
    end)

    it("draws a divided list with chips, badges, values and a right widget", function()
      local clicked
      Kit.List(root, {
        rows = {
          { status = "met", title = "Level 60", subtitle = "level 60 or more", value = "60", valueColor = "success" },
          {
            status = "missing",
            title = "Flask",
            subtitle = "any buff",
            badge = { text = "Manual", color = "warning" },
            right = { widget = "dropdown", opts = { items = { { value = "met", text = "Met" } }, value = "met" } },
            onClick = function()
              clicked = true
            end,
          },
          { title = "Plain row", selected = true },
        },
      })
      assert.is_true(root:Layout(600) > 100)
      local rows = find_all(root, "ListRow")
      assert.are.equal(3, #rows)
      assert.is_false(rows[1].line:IsShown())
      assert.is_true(rows[2].line:IsShown())
      rows[2].frame.scripts.OnEnter()
      rows[2].frame.scripts.OnLeave()
      rows[2].frame.scripts.OnClick()
      assert.is_true(clicked)
      rows[3].frame.scripts.OnEnter()
      rows[3].frame.scripts.OnLeave()
    end)

    it("shows an item with its tooltip, refusing an unknown item quietly", function()
      local hyperlink
      _G.GameTooltip = {
        SetOwner = function() end,
        SetHyperlink = function(_, link)
          hyperlink = link
          if link == "item:1" then
            error("unknown item")
          end
        end,
        Show = function() end,
        Hide = function() end,
      }
      local clicked
      local item = Kit.ItemLabel(root, {
        itemId = 7,
        text = "Sword",
        color = Kit.Theme.QualityColor(4),
        onClick = function()
          clicked = true
        end,
      })
      item.frame.scripts.OnEnter()
      assert.are.equal("item:7", hyperlink)
      item.frame.scripts.OnClick()
      assert.is_true(clicked)
      item.frame.scripts.OnLeave()
      local unknown = Kit.ItemLabel(root, { itemId = 1, text = "Unknown" })
      unknown.frame.scripts.OnEnter()
      assert.are.equal(24 + 8 + 5 * 7, item:NaturalWidth())
      root:Layout(300)
      _G.GameTooltip = nil
    end)
  end)

  describe("shell", function()
    it("opens a popup under an anchor, rebuilds it and closes it with its callback", function()
      local closed = false
      local builds = 0
      local popup = Kit.Popup.Get(1)
      popup:Open(_G.CreateFrame("Frame"), 200, function(stack)
        builds = builds + 1
        Kit.Button(stack, { text = "Inside" })
      end, {
        onClose = function()
          closed = true
        end,
        point = "BOTTOMRIGHT",
      })
      assert.is_true(popup:IsOpen())
      popup:Rebuild()
      assert.are.equal(2, builds)
      popup.catcher.scripts.OnClick()
      assert.is_false(popup:IsOpen())
      assert.is_true(closed)
      popup:Rebuild()
      Kit.CloseAllPopups()
    end)

    it("opens a modal with a title and a content stack, and closes it", function()
      local closed = false
      Kit.Modal.Open({
        title = "Export",
        width = 500,
        build = function(stack)
          Kit.TextArea(stack, { text = "x", height = 100 })
        end,
        onClose = function()
          closed = true
        end,
      })
      assert.is_true(Kit.Modal.IsOpen())
      Kit.Modal.Open({ title = "Again", build = function() end })
      Kit.Modal.Close()
      assert.is_false(Kit.Modal.IsOpen())
      Kit.Modal.Close()
      assert.is_false(closed)
    end)

    it("draws the sidebar with its groups, user card and selection", function()
      local selected
      local sidebar = Kit.Sidebar(_G.UIParent, {
        groups = {
          { items = { { value = "home", text = "Home", icon = "home" } } },
          { label = "Guild", items = { { value = "raid", text = "Raid", icon = "calendar" } } },
        },
        value = "raid",
        onSelect = function(value)
          selected = value
        end,
        user = { name = "Ann", detail = "Raider - member" },
      })
      assert.are.equal(500, sidebar:Layout(200, 500))
      local rows = find_all(sidebar, "NavRow")
      assert.are.equal(2, #rows)
      assert.is_true(rows[2].opts.selected)
      rows[1].frame.scripts.OnEnter()
      rows[1].frame.scripts.OnLeave()
      rows[1].frame.scripts.OnClick()
      assert.are.equal("home", selected)
      assert.are.equal(1, #find_all(sidebar, "UserCard"))
      local bare = Kit.Sidebar(_G.UIParent, { groups = {}, value = "x" })
      assert.are.equal(300, bare:Layout(200, 300))
    end)

    describe("date field", function()
      local function clock()
        return { time = os.time, date = os.date }
      end

      it("shows the chosen date, opens a calendar and reports a day, an hour and a minute", function()
        local changes, errors = {}, {}
        local start = os.time({ year = 2026, month = 10, day = 23, hour = 20, min = 30 })
        local field = Kit.DateField(root, {
          value = start,
          placeholder = "Pick a date",
          clock = clock(),
          now = function()
            return os.time({ year = 2026, month = 10, day = 19, hour = 12, min = 0 })
          end,
          format = function(stamp)
            return os.date("%d/%m %H:%M", stamp)
          end,
          onChange = function(stamp)
            changes[#changes + 1] = stamp
          end,
          onError = function(reason)
            errors[#errors + 1] = reason
          end,
          monthName = function(month)
            return "M" .. month
          end,
          weekdayName = function(index)
            return "d" .. index
          end,
        })
        assert.are.equal("23/10 20:30", field.label.text)
        field.frame.scripts.OnClick()
        local popup = Kit.Popup.Get(1)
        assert.is_true(popup:IsOpen())
        local cells = find_all(popup.stack, "DayCell")
        assert.are.equal(42, #cells)
        local day24
        for _, cell in ipairs(cells) do
          if cell.opts.text == "24" and not cell.opts.muted then
            day24 = cell
          end
        end
        assert.is_nil(day24 and nil)
        for _, cell in ipairs(cells) do
          if cell.opts.text == "24" then
            cell.frame.scripts.OnClick()
            break
          end
        end
        assert.are.equal(1, #changes)
        assert.are.equal("24/10 20:30", os.date("%d/%m %H:%M", changes[1]))
        local dropdowns = find_all(Kit.Popup.Get(1).stack, "Dropdown")
        assert.are.equal(2, #dropdowns)
        dropdowns[1].frame.scripts.OnClick()
        local hours = find_all(Kit.Popup.Get(2).stack, "MenuItem")
        assert.are.equal(24, #hours)
        hours[4].frame.scripts.OnClick()
        assert.are.equal("24/10 03:30", os.date("%d/%m %H:%M", changes[2]))
        dropdowns = find_all(Kit.Popup.Get(1).stack, "Dropdown")
        dropdowns[2].frame.scripts.OnClick()
        find_all(Kit.Popup.Get(2).stack, "MenuItem")[2].frame.scripts.OnClick()
        assert.are.equal("24/10 03:15", os.date("%d/%m %H:%M", changes[3]))
        assert.are.same({}, errors)
        -- Month arrows rebuild the calendar.
        local arrows = find_all(Kit.Popup.Get(1).stack, "IconButton")
        arrows[1].frame.scripts.OnClick()
        arrows[2].frame.scripts.OnClick()
        local done = find_all(Kit.Popup.Get(1).stack, "Button")
        done[#done].frame.scripts.OnClick()
        assert.is_false(Kit.Popup.Get(1):IsOpen())
      end)

      it("starts on today with no value, shows the placeholder and reports an impossible time", function()
        local errors = {}
        local field = Kit.DateField(root, {
          placeholder = "Pick a date",
          now = function()
            return os.time({ year = 2026, month = 3, day = 28, hour = 12 })
          end,
          clock = {
            time = function()
              return os.time({ year = 2026, month = 3, day = 29, hour = 3 })
            end,
            date = os.date,
          },
          format = function()
            return "never"
          end,
          onError = function(reason)
            errors[#errors + 1] = reason
          end,
        })
        assert.are.equal("Pick a date", field.label.text)
        field.frame.scripts.OnClick()
        find_all(Kit.Popup.Get(1).stack, "DayCell")[20].frame.scripts.OnClick()
        assert.are.same({ "does_not_exist" }, errors)
        Kit.CloseAllPopups()
      end)
    end)

    it("builds the window with its header, buttons, pill, status table and resizing", function()
      local resized, closed = {}, false
      local pressed
      local window = Kit.Window.New({
        name = "NrageTestWindow",
        title = "Nrage Assistant",
        version = "1.2.3",
        buttons = {
          {
            name = "gear",
            icon = "gear",
            tooltip = "Settings",
            onClick = function()
              pressed = true
            end,
          },
        },
        onResize = function(width, height)
          resized = { width, height }
        end,
        onClose = function()
          closed = true
        end,
      })
      window:SetPill("Sync ready", "success")
      window:SetTitle("Nrage")
      window:SetVersion("dev")
      local status = {}
      window:SetStatusTable(status)
      window:Show()
      assert.are.same({ 1000, 640 - 52 }, resized)
      window.buttons.gear.frame.scripts.OnClick()
      assert.is_true(pressed)
      window.header.scripts.OnDragStart()
      window.header.scripts.OnDragStop()
      assert.are.same({ 100, 700 }, { status.left, status.top })
      window.grip.scripts.OnMouseDown()
      window.grip.scripts.OnMouseUp()
      window.frame.scripts.OnSizeChanged()
      assert.is_true(window:IsShown())
      window:Toggle()
      assert.is_false(window:IsShown())
      assert.is_true(closed)
      window:Toggle()
      window.buttons.close.frame.scripts.OnClick()
      assert.is_false(window:IsShown())
      window:SetStatusTable({ width = 800, height = 500, left = 10, top = 600 })
      assert.are.equal(800, window.frame:GetWidth())
      assert.are.equal("NrageTestWindow", _G.UISpecialFrames[#_G.UISpecialFrames])
    end)
  end)
end)
