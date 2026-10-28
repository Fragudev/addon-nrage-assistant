local _, ns = ...

-- Cards shared by the tabs that show who you are: the identity line and the two declared specs. Home (plan 3.1) and
-- Profile (plan 3.2) draw the same cards, so a change to either is made once, here.
local UI = ns.UI
local Kit = ns.Kit
local L = ns.L
local ViewModel = ns.ViewModel

-- Saves one declared field, publishes it (the change is picked up by the automatic publication too) and says so.
function UI.SaveDeclared(key, value)
  local character = ns.character
  local ok, reason = ns.ProfileService.SetField(ns.Platform, character.profile, key, value)
  if ok then
    if ns.comm then
      ns.PublishService.PublishIfChanged(ns.comm, character, ns.Platform)
    end
    UI.Notify("success", L("Saved."))
  else
    UI.Notify("danger", L("Not saved: ") .. (ViewModel.PROFILE_SET_ERRORS[reason] or tostring(reason)))
  end
end

local function specItems(optional)
  local items = {}
  if optional then
    items[1] = { value = "", text = L("None") }
  end
  for _, role in ipairs(ns.ProfileService.ROLES) do
    items[#items + 1] = { value = role, text = role }
  end
  return items
end

-- The identity line: name, class (in the class color), level and item level.
function UI.IdentityCard(parent, profile)
  local card = Kit.Card(parent, {})
  local stats = ViewModel.IdentityStats(profile, ns.Platform.GetIdentityKey())
  for _, stat in ipairs(stats) do
    if stat.color == "class" then
      stat.color = Kit.Theme.ClassColor(stat.classToken)
    end
  end
  Kit.StatGrid(card, { columns = 4, stats = stats })
end

-- The Main spec and Second spec dropdowns. Each one saves when it changes.
function UI.SpecsCard(parent, declared)
  local card = Kit.Card(parent, { title = L("Your declared details") })
  local row = Kit.Row(card, { gap = 16 })
  -- A legacy free text role that is not an allowed one stays unselected until the player picks one.
  local field = Kit.Field(row, { label = L("Main spec"), layout = { weight = 1 } })
  Kit.Dropdown(field, {
    items = specItems(false),
    value = ns.ProfileService.NormalizeRole(declared.role and declared.role.value),
    placeholder = L("Pick a spec"),
    onChange = function(value)
      UI.SaveDeclared("role", value)
    end,
  })
  local second = Kit.Field(row, { label = L("Second spec"), layout = { weight = 1 } })
  Kit.Dropdown(second, {
    items = specItems(true),
    value = ns.ProfileService.NormalizeRole(declared.role2 and declared.role2.value) or "",
    placeholder = L("None"),
    onChange = function(value)
      UI.SaveDeclared("role2", value)
    end,
  })
end
