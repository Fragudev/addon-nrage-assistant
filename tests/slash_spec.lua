-- The /nrage slash command: the command words are case-insensitive, the text after them keeps its case.
local function load_slash(seen)
  local function probe(name)
    return {
      Handle = function(action)
        seen[#seen + 1] = name .. ":" .. action
      end,
    }
  end
  local ns = {
    L = function(text)
      return text
    end,
    active = true,
    ViewModel = {
      HelpLines = function()
        return { "help line" }
      end,
    },
    pvpSeasonCommands = {
      Run = function(_, text)
        seen[#seen + 1] = "pvp:" .. text
        return { "pvp line" }
      end,
    },
    PvPProbe = probe("pvp"),
    LayerProbe = probe("layer"),
    Probe = probe("lockdown"),
  }
  _G.SlashCmdList = {}
  assert(loadfile("NrageAssistant/Commands/Slash.lua"))("NrageAssistant", ns)
  return ns
end

describe("/nrage", function()
  local seen, printed, realPrint

  before_each(function()
    seen = {}
    printed = {}
    load_slash(seen)
    realPrint = _G.print
    _G.print = function(line)
      printed[#printed + 1] = line
    end
  end)

  after_each(function()
    _G.print = realPrint
  end)

  local function run(msg)
    _G.SlashCmdList.NRAGE(msg)
  end

  it("takes the command word in any case and passes the rest of the text unchanged", function()
    run("PVP Grant Yonemon Gg M-1 40")
    assert.are.same({ "pvp:Grant Yonemon Gg M-1 40" }, seen)
  end)

  it("answers help in any case", function()
    run("HELP")
    assert.is_truthy(table.concat(printed, "\n"):find("help line", 1, true))
  end)

  it("takes the debug subcommand and action in any case, and passes the action lowercase", function()
    run("Debug LAYER Status")
    run("DEBUG Pvp Start")
    run("debug LockDown Send")
    assert.are.same({ "layer:status", "pvp:start", "lockdown:send" }, seen)
  end)

  it("reports an unknown command with the text as the user typed it", function()
    run("Frobnicate")
    assert.is_truthy(table.concat(printed, "\n"):find("unknown command 'Frobnicate'", 1, true))
  end)
end)
