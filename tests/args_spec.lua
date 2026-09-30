local function load_args()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Args.lua"))("NrageAssistant", ns)
  return ns.Args
end

local Args = load_args()

describe("Args.TakeName", function()
  it("takes the first word as the name", function()
    local name, rest = Args.TakeName("Ann-Realm the rest of it")
    assert.are.equal("Ann-Realm", name)
    assert.are.equal("the rest of it", rest)
  end)

  it("takes a name with spaces when it is in double quotes", function()
    local name, rest = Args.TakeName('"Yonemon Gg" Baron Geddon')
    assert.are.equal("Yonemon Gg", name)
    assert.are.equal("Baron Geddon", rest)
  end)

  it("gives an empty rest when nothing follows", function()
    assert.are.same({ "Ann", "" }, { Args.TakeName("Ann") })
    assert.are.same({ "Yonemon Gg", "" }, { Args.TakeName('"Yonemon Gg"') })
  end)

  it("ignores spaces around the text and inside the quotes", function()
    assert.are.same({ "Black Coffee", "x" }, { Args.TakeName('   "  Black Coffee  "   x') })
    assert.are.same({ "Ann", "y z" }, { Args.TakeName("   Ann   y z  ") })
  end)

  it("gives nothing for no name, an empty quote or an unclosed quote", function()
    for _, text in ipairs({ "", "   ", '""', '"   " x', '"unclosed name', '"' }) do
      assert.is_nil(Args.TakeName(text), text)
    end
  end)
end)

describe("Args.Unquote", function()
  it("removes the quotes around a whole name", function()
    assert.are.equal("Yonemon Gg", Args.Unquote('"Yonemon Gg"'))
    assert.are.equal("Black Coffee", Args.Unquote('  " Black Coffee "  '))
  end)

  it("leaves an unquoted name, and a lone quote, as they are", function()
    assert.are.equal("Yonemon Gg", Args.Unquote("Yonemon Gg"))
    assert.are.equal("Ann", Args.Unquote("  Ann  "))
    assert.are.equal('"x', Args.Unquote('"x'))
    assert.are.equal("", Args.Unquote(""))
  end)
end)
