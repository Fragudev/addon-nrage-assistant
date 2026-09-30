-- Loads the addon files in the exact order the TOC lists them, so a file missing
-- from the TOC (or listed in the wrong order) fails the specs.
return function(ns)
  local toc = assert(io.open("NrageAssistant/NrageAssistant.toc", "r"))
  for line in toc:lines() do
    local path = line:match("^%s*([^#%s][^%s]*%.lua)%s*$")
    if path then
      path = "NrageAssistant/" .. path:gsub("\\", "/")
      assert(loadfile(path))("NrageAssistant", ns)
    end
  end
  toc:close()
  return ns
end
