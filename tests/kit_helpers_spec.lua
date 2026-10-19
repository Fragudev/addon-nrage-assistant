-- The pure helpers of the UI kit: theme tokens, layout arithmetic, the calendar and the icon registry.
local function load_kit()
  local ns = {}
  for _, path in ipairs({
    "Core/Constants",
    "Core/Locale",
    "UI/Kit/Theme",
    "UI/Kit/Pixel",
    "UI/Kit/Util",
    "UI/Kit/Calendar",
    "UI/Kit/Icons",
  }) do
    assert(loadfile("NrageAssistant/" .. path .. ".lua"))("NrageAssistant", ns)
  end
  return ns.Kit
end

describe("Kit.Theme", function()
  local Kit = load_kit()
  local Theme = Kit.Theme

  it("reads hex colors, with or without the hash", function()
    local color = Theme.Hex("#3FA7FF")
    assert.are.equal(4, #color)
    assert.is_true(math.abs(color[1] - 0x3F / 255) < 1e-9)
    assert.are.same(Theme.Hex("3FA7FF"), color)
    assert.are.equal(0.5, Theme.Hex("000000", 0.5)[4])
    assert.is_nil(Theme.Hex("nope"))
  end)

  it("has the tokens of the plan with their values", function()
    for _, name in ipairs({
      "bg",
      "panel",
      "side",
      "control",
      "input",
      "border",
      "text",
      "dim",
      "muted",
      "accent",
      "onAccent",
      "success",
      "warning",
      "danger",
    }) do
      assert.is_table(Theme.colors[name], name)
    end
    assert.are.same(Theme.Hex("121010"), Theme.colors.bg)
    assert.are.same({ 1, 1, 1, 0.08 }, Theme.colors.border)
    assert.are.equal(0.68, Theme.colors.dim[4])
  end)

  it("returns a color with another alpha when asked", function()
    local _, _, _, alpha = Theme.Color("danger", 0.14)
    assert.are.equal(0.14, alpha)
    local r = Theme.Color("unknown token")
    assert.are.equal(Theme.colors.text[1], r)
  end)

  it("changes the accent as one token", function()
    assert.is_true(Theme.SetAccent("gold"))
    assert.are.same(Theme.Hex("E6BA66"), Theme.colors.accent)
    assert.is_false(Theme.SetAccent("pink"))
    Theme.SetAccent("blue")
  end)

  it("maps statuses, classes, qualities and positions", function()
    assert.are.equal("success", Theme.StatusToken("open"))
    assert.are.equal("danger", Theme.StatusToken("cancelled"))
    assert.are.equal("muted", Theme.StatusToken("nonsense"))
    assert.is_table(Theme.ClassColor("MAGE"))
    assert.is_nil(Theme.ClassColor("BARD"))
    assert.are.same(Theme.Hex("A335EE"), Theme.QualityColor(4))
    assert.are.equal("gold", Theme.PositionToken(1))
    assert.are.equal("silver", Theme.PositionToken(2))
    assert.are.equal("bronze", Theme.PositionToken(3))
    assert.are.equal("dim", Theme.PositionToken(4))
  end)

  it("makes a font object per weight and size, falling back to the game font", function()
    local made = {}
    _G.CreateFont = function(name)
      return {
        SetFont = function(_, file)
          made[#made + 1] = { name = name, file = file }
          return file:find("SemiBold") == nil
        end,
      }
    end
    _G.STANDARD_TEXT_FONT = "fallback.ttf"
    local regular = Theme.Font("regular", 13)
    assert.are.equal(regular, Theme.Font("regular", 13))
    Theme.Font("semibold", 22)
    assert.are.equal("fallback.ttf", made[#made].file)
    assert.are.equal(Theme.Font("regular", 13), Theme.StyleFont("body"))
    assert.are.equal(17, Theme.LineHeight("body"))
    _G.CreateFont, _G.STANDARD_TEXT_FONT = nil, nil
  end)

  it("points at the Fira Sans files that ship with the addon", function()
    for _, path in pairs(Theme.FONT_FILES) do
      local file = path:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/")
      local handle = io.open(file, "r")
      assert.is_truthy(handle, file)
      handle:close()
    end
    assert.is_truthy(io.open("NrageAssistant/Media/Fonts/OFL.txt", "r"))
  end)
end)

describe("Kit.Util", function()
  local Util = load_kit().Util

  it("clamps and rounds", function()
    assert.are.equal(0, Util.Clamp(-4, 0, 10))
    assert.are.equal(10, Util.Clamp(40, 0, 10))
    assert.are.equal(5, Util.Clamp(5, 0, 10))
    assert.are.equal(3, Util.Round(2.5))
  end)

  it("distributes the width between fixed and weighted columns without losing a unit", function()
    local widths = Util.Distribute(100, { { width = 20 }, { weight = 1 }, { weight = 2 } }, 5)
    assert.are.same({ 20, 23, 47 }, widths)
    assert.are.equal(100, widths[1] + widths[2] + widths[3] + 10)
    local thirds = Util.Distribute(100, { {}, {}, {} }, 0)
    assert.are.equal(100, thirds[1] + thirds[2] + thirds[3])
  end)

  it("never gives a negative width, and honours a minimum", function()
    assert.are.same({ 50, 0 }, Util.Distribute(10, { { width = 50 }, { weight = 1 } }, 4))
    assert.are.same({ 30 }, Util.Distribute(10, { { weight = 1, min = 30 } }, 0))
    assert.are.same({}, Util.Distribute(10, {}, 4))
  end)

  it("wraps widths into lines, giving a wide item a line of its own", function()
    assert.are.same({ { 1, 2 }, { 3 }, { 4 } }, Util.WrapLines(100, { 40, 40, 40, 150 }, 10))
    assert.are.same({}, Util.WrapLines(100, {}, 10))
  end)

  it("upper-cases accented letters as well", function()
    assert.are.equal("CONFIGURACIÓN DE AÑO", Util.Upper("configuración de año"))
    assert.are.equal("YOUR READINESS", Util.Upper("Your readiness"))
  end)

  it("truncates text without cutting a character in half", function()
    assert.are.equal("short", Util.Truncate("short", 10))
    assert.are.equal("abcdefg...", Util.Truncate("abcdefghijklmnop", 10))
    local cut = Util.Truncate("ñññññññññññ", 9)
    assert.is_true(#cut <= 9)
    assert.is_nil(cut:find("[\128-\191]$"))
  end)

  it("places a scrollbar thumb in proportion", function()
    assert.are.same({ 0, 100 }, { Util.Thumb(100, 100, 0, 100) })
    local top, height = Util.Thumb(100, 400, 0, 100, 20)
    assert.are.same({ 0, 25 }, { top, height })
    top, height = Util.Thumb(100, 400, 300, 100, 20)
    assert.are.same({ 75, 25 }, { top, height })
    assert.are.equal(20, select(2, Util.Thumb(10, 1000, 0, 100, 20)))
  end)
end)

describe("Kit.Pixel", function()
  local Pixel = load_kit().Pixel

  it("snaps a value to whole pixels, never to nothing", function()
    assert.are.equal(1, Pixel.Snap(0.4, 1))
    assert.are.equal(0.5, Pixel.Snap(0.55, 0.25))
    assert.are.equal(3, Pixel.Snap(2.6, 1))
    assert.are.equal(7, Pixel.Snap(7, nil))
    assert.are.equal(0, Pixel.Snap(0, 1))
  end)

  it("gives one physical pixel from the screen height and the frame scale", function()
    _G.GetPhysicalScreenSize = function()
      return 2560, 1440
    end
    local frame = {
      GetEffectiveScale = function()
        return 0.5
      end,
    }
    assert.is_true(math.abs(Pixel.Size(frame) - (768 / 1440) / 0.5) < 1e-9)
    _G.GetPhysicalScreenSize = nil
    assert.are.equal(1, Pixel.Size(frame))
  end)
end)

describe("Kit.Icons", function()
  local Icons = load_kit().Icons

  it("has a TGA file for every icon it lists", function()
    for _, name in ipairs(Icons.NAMES) do
      local handle = io.open("NrageAssistant/Media/Icons/" .. name .. ".tga", "rb")
      assert.is_truthy(handle, name)
      local header = handle:read(18)
      handle:close()
      assert.are.equal(18, #header)
      -- Uncompressed true-colour, 32 bits per pixel, 32x32.
      assert.are.equal(2, header:byte(3))
      assert.are.equal(32, header:byte(13))
      assert.are.equal(32, header:byte(17))
    end
  end)

  it("gives the texture path without an extension, and nothing for an unknown icon", function()
    assert.are.equal("Interface\\AddOns\\NrageAssistant\\Media\\Icons\\home", Icons.Path("home"))
    assert.is_nil(Icons.Path("unicorn"))
    assert.is_true(Icons.Exists("gear"))
    assert.is_false(Icons.Exists("unicorn"))
  end)

  it("tints a texture, or hides it for an unknown icon", function()
    local texture = {
      SetTexture = function(self, path)
        self.path = path
      end,
      SetVertexColor = function(self, r)
        self.r = r
      end,
      Show = function(self)
        self.shown = true
      end,
      Hide = function(self)
        self.shown = false
      end,
    }
    assert.is_true(Icons.Apply(texture, "check", "accent"))
    assert.is_true(texture.shown)
    assert.is_false(Icons.Apply(texture, "unicorn"))
    assert.is_false(texture.shown)
  end)

  it("picks an icon for a status", function()
    assert.are.equal("check", Icons.ForStatus("met"))
    assert.are.equal("cross", Icons.ForStatus("missing"))
    assert.are.equal("alert", Icons.ForStatus("warning"))
    assert.are.equal("dash", Icons.ForStatus("whatever"))
  end)
end)

describe("Kit.Calendar", function()
  local Calendar = load_kit().Calendar

  it("knows the days of each month, leap years included", function()
    assert.are.equal(31, Calendar.DaysInMonth(2026, 10))
    assert.are.equal(28, Calendar.DaysInMonth(2026, 2))
    assert.are.equal(29, Calendar.DaysInMonth(2028, 2))
    assert.are.equal(28, Calendar.DaysInMonth(2100, 2))
    assert.are.equal(29, Calendar.DaysInMonth(2000, 2))
  end)

  it("works out the weekday with Monday first", function()
    assert.are.equal(4, Calendar.Weekday(2026, 10, 23))
    assert.are.equal(0, Calendar.Weekday(2026, 10, 19))
    assert.are.equal(6, Calendar.Weekday(2026, 10, 25))
    assert.are.equal(5, Calendar.Weekday(2000, 1, 1))
  end)

  it("moves between months across the year", function()
    assert.are.same({ 2027, 1 }, { Calendar.AddMonths(2026, 12, 1) })
    assert.are.same({ 2025, 12 }, { Calendar.AddMonths(2026, 1, -1) })
    assert.are.same({ 2027, 4 }, { Calendar.AddMonths(2026, 10, 6) })
  end)

  it("lays a month out as six weeks of seven, with the neighbours filling the edges", function()
    local weeks = Calendar.MonthGrid(2026, 10)
    assert.are.equal(6, #weeks)
    for _, week in ipairs(weeks) do
      assert.are.equal(7, #week)
    end
    -- 1 October 2026 is a Thursday: three days of September come first.
    assert.are.same({ year = 2026, month = 9, day = 28, inMonth = false }, weeks[1][1])
    assert.are.same({ year = 2026, month = 10, day = 1, inMonth = true }, weeks[1][4])
    assert.are.same({ year = 2026, month = 11, day = 8, inMonth = false }, weeks[6][7])
  end)

  it("turns a local date and time into a timestamp and back", function()
    local stamp = Calendar.ToTimestamp(2026, 10, 23, 20, 30)
    assert.is_number(stamp)
    assert.are.same({ 2026, 10, 23, 20, 30 }, { Calendar.Parts(stamp) })
  end)

  it("refuses dates and times that do not exist", function()
    assert.are.same({ nil, "invalid" }, { Calendar.ToTimestamp(2026, 2, 31, 10, 0) })
    assert.are.same({ nil, "invalid" }, { Calendar.ToTimestamp(2026, 13, 1, 10, 0) })
    assert.are.same({ nil, "invalid" }, { Calendar.ToTimestamp(2026, 10, 1, 24, 0) })
    assert.are.same({ nil, "invalid" }, { Calendar.ToTimestamp(2026, 10, 1, 10, 60) })
  end)

  -- A clock whose time zone skips 02:00 to 03:00 on 29 March 2026 (the clocks go forward) and repeats 02:00 to
  -- 03:00 on 25 October 2026 (they go back).
  local function clock()
    local base = os.time({ year = 2026, month = 1, day = 1, hour = 0 })
    local function utc(year, month, day, hour, minute)
      return os.time({ year = year, month = month, day = day, hour = hour, min = minute or 0 }) - base
    end
    return {
      time = function(parts)
        local stamp = utc(parts.year, parts.month, parts.day, parts.hour, parts.min)
        -- Local 02:30 on 29 March does not exist: the library rolls it forward to 03:30.
        if parts.year == 2026 and parts.month == 3 and parts.day == 29 and parts.hour == 2 then
          return stamp + 3600
        end
        return stamp
      end,
      date = function(format, stamp)
        local value = stamp + base
        if format == "*t" then
          return os.date("*t", value)
        end
        return os.date(format, value)
      end,
    }
  end

  it("refuses a time the clock skips when the clocks go forward", function()
    local fake = clock()
    assert.is_number(Calendar.ToTimestamp(2026, 3, 29, 1, 30, fake))
    assert.is_number(Calendar.ToTimestamp(2026, 3, 29, 3, 0, fake))
    assert.are.same({ nil, "does_not_exist" }, { Calendar.ToTimestamp(2026, 3, 29, 2, 30, fake) })
  end)

  it("accepts the hour that happens twice when the clocks go back", function()
    local fake = clock()
    local stamp = Calendar.ToTimestamp(2026, 10, 25, 2, 30, fake)
    assert.is_number(stamp)
    assert.are.equal(Calendar.ToTimestamp(2026, 10, 25, 2, 30, fake), stamp)
  end)

  it("snaps a minute to the picker's choices", function()
    assert.are.equal(0, Calendar.SnapMinute(7))
    assert.are.equal(15, Calendar.SnapMinute(29))
    assert.are.equal(30, Calendar.SnapMinute(30))
    assert.are.equal(45, Calendar.SnapMinute(59))
  end)
end)
