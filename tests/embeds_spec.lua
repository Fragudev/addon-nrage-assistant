local function read(path)
  local file = assert(io.open(path, "r"), "cannot open " .. path)
  local content = file:read("*a")
  file:close()
  return content
end

describe("Vendored libraries", function()
  it("lists embeds.xml in the TOC before the addon files", function()
    local toc = read("NrageAssistant/NrageAssistant.toc")
    local embeds = toc:find("\nembeds.xml", 1, true)
    local first_lua = toc:find("\nCore\\Constants.lua", 1, true)
    assert.is_truthy(embeds)
    assert.is_truthy(first_lua)
    assert.is_true(embeds < first_lua)
  end)

  it("only references files that exist", function()
    local xml = read("NrageAssistant/embeds.xml")
    local count = 0
    for file in xml:gmatch('file="([^"]+)"') do
      local path = "NrageAssistant/" .. file:gsub("\\", "/")
      local handle = io.open(path, "r")
      assert.is_truthy(handle, "missing " .. path)
      handle:close()
      count = count + 1
    end
    assert.is_true(count >= 5)
  end)

  it("does not embed AceGUI: every window is drawn with the kit", function()
    assert.is_falsy(read("NrageAssistant/embeds.xml"):find("AceGUI", 1, true))
    assert.is_falsy(io.open("NrageAssistant/Libs/AceGUI-3.0/AceGUI-3.0.xml", "r"))
  end)

  it("keeps the license of every vendored library", function()
    for _, path in ipairs({
      "NrageAssistant/Libs/Ace3-LICENSE.txt",
      "NrageAssistant/Libs/LibSerialize/LICENSE",
      "NrageAssistant/Libs/LibDeflate/LICENSE.txt",
      "NrageAssistant/Libs/HereBeDragons/LICENSE.txt",
    }) do
      local handle = io.open(path, "r")
      assert.is_truthy(handle, "missing " .. path)
      handle:close()
    end
  end)
end)
