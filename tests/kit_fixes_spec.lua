-- Regressions of the code review of the kit: release re-entrancy, pooled handlers, UTF-8 text, the switch description,
-- the read-only text area, the modal close hook, the tooltip owner and the throttled window resize.
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
  return ns.Kit
end

describe("Kit review fixes", function()
  local Kit, root

  before_each(function()
    fake.install()
    Kit = load_kit()
    root = Kit.Stack(_G.UIParent, { gap = 10 })
  end)

  after_each(function()
    _G.GameTooltip, _G.C_Timer = nil, nil
    fake.uninstall()
  end)

  describe("the edit box being typed in", function()
    local function typed(commits)
      local box = Kit.EditBox(root, {
        text = "old",
        onCommit = function(value)
          commits[#commits + 1] = value
        end,
      })
      box.frame:SetFocus()
      box.frame:SetText("new")
      return box
    end

    it("is committed by CommitEdit, which a redraw calls before it releases the page", function()
      local commits = {}
      typed(commits)
      assert.is_true(Kit.HasEditFocus())
      Kit.CommitEdit()
      assert.are.same({ "new" }, commits)
      assert.is_false(Kit.HasEditFocus())
    end)

    it("is not committed by DiscardEdit, and goes back to its text", function()
      local commits = {}
      local box = typed(commits)
      Kit.DiscardEdit()
      assert.are.same({}, commits)
      assert.are.equal("old", box.frame:GetText())
      assert.is_false(Kit.HasEditFocus())
    end)

    it("stops counting as focused when it is released", function()
      typed({}):Release()
      assert.is_false(Kit.HasEditFocus())
    end)
  end)

  describe("releasing a widget", function()
    it("never commits the typed text of an edit box and pools it once", function()
      local commits = 0
      local box
      box = Kit.EditBox(root, {
        text = "old",
        onCommit = function()
          commits = commits + 1
          -- What a tab does on a commit: redraw, which releases the box again.
          root:Clear()
        end,
      })
      box.frame:SetFocus()
      box.frame:SetText("typed")
      root:Clear()
      assert.are.equal(0, commits)
      assert.are.equal(1, Kit.PoolSize("EditBox"))
    end)

    it("does not hand the same widget to two owners after a re-entrant release", function()
      local box = Kit.EditBox(root, {
        text = "old",
        onCommit = function()
          root:Clear()
        end,
      })
      box.frame:SetFocus()
      box.frame:SetText("typed")
      box:Release()
      local first = Kit.EditBox(root, { text = "a" })
      local second = Kit.EditBox(root, { text = "b" })
      assert.are_not.equal(first, second)
      assert.are_not.equal(first.frame, second.frame)
    end)

    it("still commits on a focus loss while the widget lives", function()
      local committed
      local box = Kit.EditBox(root, {
        text = "old",
        onCommit = function(text)
          committed = text
        end,
      })
      box.frame:SetFocus()
      box.frame:SetText("typed")
      box.frame:ClearFocus()
      assert.are.equal("typed", committed)
    end)

    it("hides the tooltip that the released frame owns and ignores late hover events", function()
      local hidden = 0
      local owner
      _G.GameTooltip = {
        SetOwner = function(_, frame)
          owner = frame
        end,
        SetText = function() end,
        Show = function() end,
        GetOwner = function()
          return owner
        end,
        Hide = function()
          hidden = hidden + 1
        end,
      }
      local button = Kit.IconButton(root, { icon = "gear", tooltip = "Settings" })
      button.frame.scripts.OnEnter()
      button:Release()
      assert.are.equal(1, hidden)
      assert.has_no.errors(function()
        button.frame.scripts.OnEnter()
        button.frame.scripts.OnLeave()
        button.frame.scripts.OnMouseDown()
      end)
      assert.has_no.errors(function()
        button:SetError(true)
        button:SetDisabled(true)
      end)
    end)
  end)

  describe("pooled handlers", function()
    local function columns(first, second)
      return {
        { key = first, title = first, weight = 1, sortable = true },
        { key = second, title = second, weight = 1, sortable = true },
      }
    end

    it("sorts by the column of the current table, not the one the header was made for", function()
      Kit.Table(root, { columns = columns("name", "total"), rows = {} })
      root:Layout(500)
      root:Clear()
      local sorted
      local again = Kit.Table(root, {
        columns = columns("alpha", "beta"),
        rows = {},
        onSort = function(key)
          sorted = key
        end,
      })
      root:Layout(500)
      local header
      for _, item in ipairs(again.items) do
        header = header or item.obj
      end
      header.hits[2].frame.scripts.OnClick()
      assert.are.equal("beta", sorted)
    end)

    it("keeps the dismiss handler of a banner when the widget is reused", function()
      Kit.Banner(root, { text = "one", onDismiss = function() end })
      root:Clear()
      local dismissed = false
      local banner = Kit.Banner(root, {
        text = "two",
        onDismiss = function()
          dismissed = true
        end,
      })
      banner.close.scripts.OnClick()
      assert.is_true(dismissed)
    end)
  end)

  describe("UTF-8 text", function()
    it("cuts characters, not bytes", function()
      local Chars = Kit.Util.Chars
      assert.are.equal("sá", Chars("sáb", 2))
      assert.are.equal("sáb", Chars("sáb", 3))
      assert.are.equal("sáb", Chars("sáb", 9))
      assert.are.equal("Á", Chars("Álvaro", 1))
      assert.are.equal("", Chars("", 1))
      assert.are.equal("", Chars("abc", 0))
      assert.are.equal("ab", Chars("abc", 2))
    end)

    it("takes a whole character as the initial of the user card", function()
      local card = Kit.UserCard(root, { name = "ñandú", detail = "x" })
      assert.are.equal("Ñ", card.initial.text)
      local plain = Kit.UserCard(root, { name = "ann", detail = "x" })
      assert.are.equal("A", plain.initial.text)
    end)
  end)

  describe("controls", function()
    it("shows the description of a switch and makes the row taller", function()
      local plain = Kit.Switch(root, { label = "Share", checked = true })
      local described = Kit.Switch(root, {
        label = "Share",
        checked = true,
        description = string.rep("Only the guild sees it. ", 8),
      })
      assert.are.equal(36, plain:Layout(300))
      assert.is_true(described.desc:IsShown())
      assert.is_true(described:Layout(300) > 36)
      assert.is_false(plain.desc:IsShown())
      -- A pooled switch forgets the description.
      root:Clear()
      local reused = Kit.Switch(root, { label = "Share" })
      assert.is_false(reused.desc:IsShown())
      assert.are.equal(36, reused:Layout(300))
    end)

    it("keeps a read-only text area unchanged and still reports an editable one", function()
      local changes = {}
      local locked = Kit.TextArea(root, {
        text = "NRAGE1:abc",
        readOnly = true,
        onChange = function(text)
          changes[#changes + 1] = text
        end,
      })
      locked.edit:SetText("hacked")
      locked.edit.scripts.OnTextChanged(locked.edit, true)
      assert.are.equal("NRAGE1:abc", locked:GetValueText())
      assert.are.same({}, changes)

      local open = Kit.TextArea(root, {
        text = "a",
        onChange = function(text)
          changes[#changes + 1] = text
        end,
      })
      open.edit:SetText("b")
      open.edit.scripts.OnTextChanged(open.edit, true)
      assert.are.same({ "b" }, changes)
      -- A pooled box is editable again.
      locked:Release()
      local reused = Kit.TextArea(root, { text = "x" })
      assert.are.equal(locked, reused)
      reused.edit:SetText("y")
      reused.edit.scripts.OnTextChanged(reused.edit, true)
      assert.are.equal("y", reused:GetValueText())
    end)
  end)

  describe("modal", function()
    it("runs onClose once when Escape hides it", function()
      local closed = 0
      Kit.Modal.Open({
        title = "Export",
        build = function() end,
        onClose = function()
          closed = closed + 1
        end,
      })
      assert.are.equal("NrageAssistantModal", _G.UISpecialFrames[1])
      -- Escape hides the frames listed in UISpecialFrames; it never goes through Modal.Close.
      _G.NrageAssistantModal:Hide()
      assert.are.equal(1, closed)
      assert.is_false(Kit.Modal.IsOpen())
      Kit.Modal.Close()
      assert.are.equal(1, closed)
    end)

    it("runs onClose once when the close button is used", function()
      local closed = 0
      Kit.Modal.Open({
        title = "Export",
        build = function() end,
        onClose = function()
          closed = closed + 1
        end,
      })
      Kit.Modal.Close()
      Kit.Modal.Close()
      assert.are.equal(1, closed)
    end)
  end)

  describe("window resize", function()
    it("coalesces the layout of a drag and ends with the final size", function()
      local queue = {}
      _G.C_Timer = {
        After = function(_, fn)
          queue[#queue + 1] = fn
        end,
      }
      local sizes = {}
      local window = Kit.Window.New({
        title = "T",
        width = 1000,
        height = 640,
        onResize = function(width, height)
          sizes[#sizes + 1] = { width, height }
        end,
      })
      for step = 1, 20 do
        window.frame:SetSize(1000 + step, 640)
        window.frame.scripts.OnSizeChanged()
      end
      assert.are.equal(0, #sizes)
      assert.are.equal(1, #queue)
      queue[1]()
      assert.are.equal(1, #sizes)
      assert.are.equal(1020, sizes[1][1])
    end)

    it("lays out at once when the grip is released and drops the pending run", function()
      local queue = {}
      _G.C_Timer = {
        After = function(_, fn)
          queue[#queue + 1] = fn
        end,
      }
      local count = 0
      local window = Kit.Window.New({
        title = "T",
        onResize = function()
          count = count + 1
        end,
      })
      window.frame.scripts.OnSizeChanged()
      window.grip.scripts.OnMouseUp()
      assert.are.equal(1, count)
      queue[1]()
      assert.are.equal(1, count)
      -- The next drag schedules again.
      window.frame.scripts.OnSizeChanged()
      assert.are.equal(2, #queue)
      queue[2]()
      assert.are.equal(2, count)
    end)
  end)

  describe("progress bar setter", function()
    it("moves the fill in place, clamped to 0..1, without laying the parent out again", function()
      local bar = Kit.ProgressBar(root, { value = 0.5, height = 6 })
      root:Layout(400)
      assert.are.equal(200, bar.fill.width)
      local relayouts = 0
      local layout = root.Layout
      root.Layout = function(self, ...)
        relayouts = relayouts + 1
        return layout(self, ...)
      end
      bar:SetValue(0.25)
      assert.are.equal(100, bar.fill.width)
      assert.are.equal(0.25, bar.value)
      bar:SetValue(1.5)
      assert.are.equal(1, bar.value)
      assert.are.equal(400, bar.fill.width)
      bar:SetValue(-1)
      assert.are.equal(0, bar.value)
      assert.is_false(bar.fill:IsShown())
      assert.are.equal(0, relayouts)
    end)

    it("keeps the value until the first layout gives it a width", function()
      local bar = Kit.ProgressBar(root, { value = 0, height = 6 })
      bar:SetValue(0.75)
      assert.are.equal(0.75, bar.value)
      root:Layout(400)
      assert.are.equal(300, bar.fill.width)
    end)
  end)
end)
