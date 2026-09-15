-- Reusable synthetic EVC API. No native project or file access.
local Core = require('core')

-- Property values are strings because windowGetMapProperties documents a string
-- return type. Symbolic enum strings are the names in the WinOLS scripting help.
local function native_defaults()
  local map = {
    Name = "New map", IdName = "", Typ = "eZweidim", DataOrg = "eByte",
    Spalten = "1", Zeilen = "1", bVorzeichen = "0", bKehrwert = "0",
    bDelta = "0", bProzent = "0", bOriginal = "0", bOriginalWerte = "0",
    SkipBytes = "0", LineSkipBytes = "0", Radix = "10",
    ["Feldwerte.StartAddr"] = "0", ["Feldwerte.Einheit"] = "",
    ["Feldwerte.Faktor"] = "1", ["Feldwerte.Offset"] = "0", ["Feldwerte.PreOffset"] = "0",
  }
  for _, prefix in ipairs({ "StuetzX", "StuetzY" }) do
    for property, value in pairs({
      DataSrc = "eDataSrcNone", DataOrg = "eByte", DataAddr = "0", DataHeader = "0",
      bVorzeichen = "0", bRueckwaerts = "0", bKehrwert = "0", SkipBytes = "0",
      SignaturByte = "0xFFFFFFFF", Faktor = "1", Offset = "0", PreOffset = "0", Einheit = "",
    }) do map[prefix .. "." .. property] = value end
  end
  return map
end

local function fixture()
  local state = {
    maps = {}, adds = 0, sets = 0, deletes = 0, binary_writes = 0, saves = 0,
    filename = "C:\\synthetic\\fixture.ols", hash = string.rep("a", 64),
    ranges = "Synthetic / Eprom:0-1048575", element_offset = 0,
  }
  local api = {}
  api.TRUE, api.FALSE = 1, 0
  for index, name in ipairs({
    "ePrjFilename", "ePrjPropChecksumSHA256", "eWinOLSMajor", "eWinOLSMinor",
    "eByte", "eLoHi", "eHiLo", "eLoHiLoHi", "eHiLoHiLo",
    "eEinzel", "eEindim", "eZweidim", "eDataSrcNone", "eRom", "eViewText",
  }) do api[name] = index end

  function api.GetVersion(kind)
    if kind == api.eWinOLSMajor then return 5 end
    assert(kind == api.eWinOLSMinor, "unexpected version constant")
    return 93
  end
  function api.projectGetProperty(kind)
    if kind == api.ePrjFilename then return state.filename end
    assert(kind == api.ePrjPropChecksumSHA256, "unexpected project property constant")
    state.hash_reads = (state.hash_reads or 0) + 1
    if state.expire_on_hash_read == state.hash_reads then state.now = 2000 end
    return state.hash
  end
  function api.projectGetElementRanges(ecu, long_format)
    assert(ecu == 0 and long_format == 0, "element ranges require EVC numeric FALSE, not Lua booleans")
    return state.ranges
  end
  function api.projectGetElementOffset() return state.element_offset end
  function api.projectAddMap()
    state.adds = state.adds + 1
    state.maps[#state.maps + 1] = native_defaults()
    state.last_created = state.maps[#state.maps]
    if state.add_throws then error("synthetic projectAddMap failure") end
    return true
  end
  function api.windowSetMapProperties(key, value, last_new)
    assert(last_new == 1, "creation requires EVC numeric TRUE, not a Lua boolean, for the last Lua-created map")
    assert(state.last_created, "no newly created map for setter")
    state.sets = state.sets + 1
    if key == state.fail_property then return false end
    if key == state.throw_property then error("synthetic native setter failure") end
    state.last_created[key] = tostring(value)
    return true
  end
  function api.windowGetMapProperties(key, address, skip)
    assert(type(address) == "number" and type(skip) == "number", "readback must target explicit map address and skip")
    local matching = 0
    for _, map in ipairs(state.maps) do
      if tonumber(map["Feldwerte.StartAddr"]) == address then
        if matching == skip then
          assert(map[key] ~= nil, "undocumented or unmodeled map property " .. key)
          if key == state.override_property then return state.override_value end
          local result = map[key]
          if state.comma_decimal and (key:match("%.Faktor$") or key:match("%.Offset$")) then
            result = result:gsub("%.", ",")
          end
          return result
        end
        matching = matching + 1
      end
    end
    error("native map address/skip not found")
  end
  function api.projectFindMap(criterion, value, start_address)
    assert(criterion == "Name" or criterion == "IdName", "unsupported find criterion")
    assert(start_address == -1, "inventory lookup must request all exact matches")
    local found = {}
    for _, map in ipairs(state.maps) do
      if map[criterion] == value then found[#found + 1] = tonumber(map["Feldwerte.StartAddr"]) end
    end
    return found
  end
  function api.projectDelMap(name)
    assert(type(name) == "string" and name:match("^__winols_mcp_[A-Za-z0-9_-]+$"),
      "rollback must delete only an exact generated map name")
    if state.delete_fails then return 0 end
    local deleted = 0
    for index = #state.maps, 1, -1 do
      if state.maps[index].Name == name then
        table.remove(state.maps, index)
        deleted = deleted + 1
      end
    end
    state.deletes = state.deletes + deleted
    return deleted
  end
  function api.projectSetAt()
    state.binary_writes = state.binary_writes + 1
    error("binary writes are forbidden in definition tools")
  end
  function api.projectSetOrg()
    state.binary_writes = state.binary_writes + 1
    error("original binary writes are forbidden in definition tools")
  end
  function api.projectSave()
    state.saves = state.saves + 1
    error("definition tools must not save projects")
  end

  local function inventory()
    local result = {}
    for _, map in ipairs(state.maps) do result[#result + 1] = tonumber(map["Feldwerte.StartAddr"]) end
    if state.switch_on_inventory then
      state.filename = "C:\\synthetic\\another-project.ols"
      state.switch_on_inventory = false
    end
    return result
  end
  local core = Core.new(api, {
    session_id = "synthetic-session", inventory = inventory,
    now = function() return state.now or os.time() end,
  })
  return { core = core, state = state, api = api, inventory = inventory }
end

return { new = fixture }
