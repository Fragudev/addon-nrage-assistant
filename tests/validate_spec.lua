local ns = {}
assert(loadfile("NrageAssistant/Core/Validate.lua"))("NrageAssistant", ns)
local NameKey = ns.Validate.NameKey

describe("Validate.NameKey", function()
  it("lowers ASCII and drops whitespace", function()
    assert.are.equal("yonemongg", NameKey("Yonemon Gg"))
    assert.are.equal("ann", NameKey("  ANN "))
  end)

  it("treats accented capitals and small letters as the same name", function()
    assert.are.equal(NameKey("\195\129ngel"), NameKey("\195\161ngel"))
    assert.are.equal("\195\161ngel", NameKey("\195\129NGEL"))
    assert.are.equal("\195\177and\195\186", NameKey("\195\145AND\195\154"))
    assert.are.equal("\195\160\195\190", NameKey("\195\128\195\158"))
  end)

  it("leaves the multiplication sign and the already small letters alone", function()
    assert.are.equal("a\195\151b", NameKey("A\195\151B"))
    assert.are.equal("\195\159", NameKey("\195\159"))
    assert.are.equal("\195\191", NameKey("\195\191"))
  end)
end)
