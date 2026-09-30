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

-- Identifiers made of letters, digits, "-", "_" and ":".
function Validate.Id(value)
  return Validate.Text(value, 40) and value:find("^[%w%-_:]+$") ~= nil
end

ns.Validate = Validate
