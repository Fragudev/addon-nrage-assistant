local function load_guard()
  local ns = {}
  assert(loadfile("NrageAssistant/Core/AccessGuard.lua"))("NrageAssistant", ns)
  return ns.AccessGuard
end

local function fake_platform(overrides)
  local p = {
    IsInGuild = function() return true end,
    GetGuildClubId = function() return 123 end,
    GetGuildName = function() return "Nrage" end,
    GetFaction = function() return "Alliance" end,
  }
  for k, v in pairs(overrides or {}) do p[k] = v end
  return p
end

describe("AccessGuard.Evaluate", function()
  local guard = load_guard()
  local by_name = { GUILD_NAME = "Nrage", FACTION = "Alliance" }
  local by_id = { GUILD_NAME = "Nrage", GUILD_CLUB_ID = 123, FACTION = "Alliance" }

  it("allows a Nrage Alliance member (name fallback)", function()
    assert.is_true(guard.Evaluate(fake_platform(), by_name))
  end)

  it("allows a Nrage Alliance member (club id)", function()
    assert.is_true(guard.Evaluate(fake_platform(), by_id))
  end)

  it("rejects players without a guild", function()
    local ok, reason = guard.Evaluate(fake_platform({ IsInGuild = function() return false end }), by_name)
    assert.is_false(ok)
    assert.are.equal("not_in_guild", reason)
  end)

  it("rejects another guild by name", function()
    local ok, reason = guard.Evaluate(fake_platform({ GetGuildName = function() return "Other" end }), by_name)
    assert.is_false(ok)
    assert.are.equal("wrong_guild", reason)
  end)

  it("rejects another guild by club id, ignoring a matching name", function()
    local ok, reason = guard.Evaluate(fake_platform({ GetGuildClubId = function() return 999 end }), by_id)
    assert.is_false(ok)
    assert.are.equal("wrong_guild", reason)
  end)

  it("rejects the wrong faction", function()
    local ok, reason = guard.Evaluate(fake_platform({ GetFaction = function() return "Horde" end }), by_name)
    assert.is_false(ok)
    assert.are.equal("wrong_faction", reason)
  end)
end)
