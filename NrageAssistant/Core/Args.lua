local _, ns = ...

-- Reading character names out of command text. Names on Forever can have several words ("Yonemon Gg"), so a
-- name cannot be told from the words after it by splitting on spaces. The commands use two rules:
--   * when the name is the last thing before a known word (a state), it is everything in between;
--   * otherwise the name is the first word, or the words inside double quotes.
local Args = {}

local function trim(text)
  return (text:match("^%s*(.-)%s*$"))
end

-- Takes a name from the start of `text`: "Yonemon Gg" in quotes, or the first word. Returns the name and
-- the rest of the text, or nil when there is no name (nothing, or an unclosed or empty quote).
function Args.TakeName(text)
  text = trim(text)
  if text:sub(1, 1) == '"' then
    local name, rest = text:match('^"([^"]+)"%s*(.*)$')
    if not name or trim(name) == "" then
      return nil
    end
    return trim(name), rest
  end
  local name, rest = text:match("^(%S+)%s*(.*)$")
  return name, rest
end

-- A whole text that is a name, with optional double quotes around it.
function Args.Unquote(text)
  text = trim(text)
  local inner = text:match('^"([^"]*)"$')
  return inner and trim(inner) or text
end

ns.Args = Args
