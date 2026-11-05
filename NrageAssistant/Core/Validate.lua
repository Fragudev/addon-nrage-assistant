local _, ns = ...

-- Small validators shared by the wire protocol and the domain models. They never raise: anything
-- that is not exactly what was asked for is simply "not valid".
local Validate = {}

function Validate.Int(value, low, high)
  return type(value) == "number" and value % 1 == 0 and value >= low and value <= high
end

-- Plain text only: 1..maxLength bytes, no "|" (colour/link escapes) and no control characters.
function Validate.Text(value, maxLength)
  return type(value) == "string"
    and #value >= 1
    and #value <= maxLength
    and not value:find("|", 1, true)
    and not value:find("%c")
end

-- Identifiers made of letters, digits, "-" and "_". No ":" so that composite keys such as
-- "A:<eventId>:<assignmentId>" can always be split back unambiguously.
function Validate.Id(value)
  return Validate.Text(value, 40) and value:find("^[%w%-_]+$") ~= nil
end

-- The capital letters of the Latin-1 Supplement (A-grave to Thorn, two bytes \195\128 to \195\158) become their small
-- letters by adding 32 to the second byte. The multiplication sign (\195\151) is not a letter and stays.
local function LowerLatin1(second)
  if second == "\151" then
    return nil
  end
  return "\195" .. string.char(second:byte() + 32)
end

-- Lowercase, no whitespace: "Some Name" and "somename" are the same name. Used to compare names that people type
-- or that come from different places, never to display them. string.lower only knows ASCII, so the accented
-- capitals of UTF-8 names ("Angel" with an acute accent) are lowered here as well.
function Validate.NameKey(text)
  return (text:lower():gsub("\195([\128-\158])", LowerLatin1):gsub("%s+", ""))
end

-- What a command (RaidCommands, LootCommands...) returns when it did not do what was asked: the lines to show, marked
-- as a failure so the window can color the message. The mark is a metatable, so the lines still compare as a plain
-- list.
local FAILED = {}

function Validate.Failure(text)
  return setmetatable({ text }, FAILED)
end

function Validate.IsFailure(lines)
  return getmetatable(lines) == FAILED
end

ns.Validate = Validate
