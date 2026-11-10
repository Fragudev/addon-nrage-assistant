-- Platform.GetGuildRanks: the rank names by rank index. Assumes position i is rank index i - 1 (M10, not measured yet).
local function load_platform()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/Platform.lua"))("NrageAssistant", ns)
  return ns.Platform
end

-- Runs `fn` with some client globals replaced (false removes one), then puts them back.
local function with_globals(values, fn)
  local saved = {}
  for name, value in pairs(values) do
    saved[name] = _G[name]
    if value == false then
      _G[name] = nil
    else
      _G[name] = value
    end
  end
  local ok, err = pcall(fn)
  for name in pairs(values) do
    _G[name] = saved[name]
  end
  assert(ok, err)
end

describe("Platform.GetGuildRanks", function()
  it("maps the 1-based rank position of the client to the 0-based rank index", function()
    with_globals({
      GuildControlGetNumRanks = function()
        return 3
      end,
      GuildControlGetRankName = function(position)
        return ({ "Emperador", "Comandante", "Oficial" })[position]
      end,
    }, function()
      assert.are.same({ [0] = "Emperador", [1] = "Comandante", [2] = "Oficial" }, load_platform().GetGuildRanks())
    end)
  end)

  it("skips a rank the client gives no name for", function()
    with_globals({
      GuildControlGetNumRanks = function()
        return 3
      end,
      GuildControlGetRankName = function(position)
        return position ~= 2 and "Rank " .. position or ""
      end,
    }, function()
      assert.are.same({ [0] = "Rank 1", [2] = "Rank 3" }, load_platform().GetGuildRanks())
    end)
  end)

  it("gives an empty table when the API is missing or raises", function()
    with_globals({ GuildControlGetNumRanks = false, GuildControlGetRankName = false }, function()
      assert.are.same({}, load_platform().GetGuildRanks())
    end)
    with_globals({
      GuildControlGetNumRanks = function()
        error("restricted")
      end,
      GuildControlGetRankName = function() end,
    }, function()
      assert.are.same({}, load_platform().GetGuildRanks())
    end)
  end)
end)
