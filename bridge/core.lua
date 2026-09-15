-- WinOLS adapter. All native calls below are documented EVC APIs; see docs/winols-api.md.
local json = require("json")
local core = {}
local MAX_INTEGER = 9007199254740991
local types = {
  u8 = { "eByte", 0, 1 }, i8 = { "eByte", 1, 1 },
  u16_le = { "eLoHi", 0, 2 }, i16_le = { "eLoHi", 1, 2 },
  u16_be = { "eHiLo", 0, 2 }, i16_be = { "eHiLo", 1, 2 },
  u32_le = { "eLoHiLoHi", 0, 4 }, i32_le = { "eLoHiLoHi", 1, 4 },
  u32_be = { "eHiLoHiLo", 0, 4 }, i32_be = { "eHiLoHiLo", 1, 4 },
}
local function fail(code, message) error({ code = code, message = message }, 0) end
local function integer(value, minimum, maximum, label)
  if type(value) ~= "number" or value ~= value or value % 1 ~= 0 or value < minimum or value > maximum then
    fail("invalid_argument", label .. " must be an integer in range")
  end
  return value
end
local function fields(value, allowed, label)
  if type(value) ~= "table" or value == json.null or json.is_array(value) then fail("invalid_argument", label .. " must be an object") end
  for key in pairs(value) do if not allowed[key] then fail("invalid_argument", label .. " has an unknown property") end end
end
local function text(value, maximum, required, label)
  local ok, count = pcall(json.text_length, value, true)
  if not ok or count > maximum or (required and not value:find("%S")) then fail("invalid_argument", label .. " is invalid") end
  return value
end
local function scalar(value, fallback, nonzero, label)
  if value == nil then value = fallback end
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge or (nonzero and value == 0) then
    fail("invalid_argument", label .. " must be finite" .. (nonzero and " and nonzero" or ""))
  end
  return value
end
local function storage(value, count, size, label)
  local typ = types[value.data_type]
  if not typ then fail("invalid_argument", label .. " has unsupported data_type") end
  local address = integer(value.address, 0, MAX_INTEGER, label .. " address")
  if address > size - count * typ[3] then fail("invalid_argument", label .. " exceeds project size") end
  return {
    address = address, data_type = value.data_type,
    factor = scalar(value.factor, 1, true, label .. " factor"),
    offset = scalar(value.offset, 0, false, label .. " offset"),
    unit = text(value.unit == nil and "" or value.unit, 64, false, label .. " unit"),
  }
end
local axis_fields = { address=true, data_type=true, factor=true, offset=true, unit=true }
local definition_fields = { name=true, address=true, columns=true, rows=true, data_type=true,
  factor=true, offset=true, unit=true, x_axis=true, y_axis=true }
local function definition(value, size)
  fields(value, definition_fields, "definition")
  local columns = integer(value.columns, 1, 4096, "columns")
  local rows = integer(value.rows, 1, 4096, "rows")
  if columns * rows > 1048576 then fail("invalid_argument", "map exceeds 1048576 cells") end
  local result = storage(value, columns * rows, size, "map")
  result.name = text(value.name, 128, true, "name")
  result.columns, result.rows = columns, rows
  for key, count in pairs({ x_axis=columns, y_axis=rows }) do
    if value[key] ~= nil and value[key] ~= json.null then
      fields(value[key], axis_fields, key)
      result[key] = storage(value[key], count, size, key)
    end
  end
  return result
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do if not same(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

function core.new(api, options)
  options = options or {}
  assert(type(options.inventory) == "function", "inventory callback required")
  assert(type(options.session_id) == "string", "session_id required")
  local self = { halted=false, seen={}, seen_count=0 }
  local now = options.now or os.time
  local function invoke(name, ...)
    if type(api[name]) ~= "function" then fail("unsupported_winols", "WinOLS function unavailable: " .. name) end
    return api[name](...)
  end
  local function constant(name)
    if type(api[name]) ~= "number" then fail("unsupported_winols", "WinOLS constant unavailable: " .. name) end
    return api[name]
  end
  local function enum(value, name) return value == name or tonumber(value) == constant(name) end
  local function number(value, label)
    if type(value) == "string" then
      -- EVC's own scripts show comma decimal separators. Grouped/ambiguous numbers fail.
      if value:find(",", 1, true) then
        if value:find(".", 1, true) or select(2, value:gsub(",", "")) > 1 then fail("unsupported_map", label .. " has ambiguous numeric format") end
        value = value:gsub(",", ".")
      end
      value = tonumber(value)
    end
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
      fail("unsupported_map", "WinOLS did not return a numeric " .. label)
    end
    return value
  end
  local function project()
    local filename = invoke("projectGetProperty", constant("ePrjFilename"))
    -- The default iOrgVer=0 selects the original, independent of the selected version.
    local hash = invoke("projectGetProperty", constant("ePrjPropChecksumSHA256"))
    if type(filename) ~= "string" or filename == "" then fail("no_project", "Open and save a project before starting the bridge") end
    if type(hash) ~= "string" or #hash ~= 64 or not hash:match("^%x+$") then
      fail("unsupported_project", "Original SHA-256 is unavailable; cannot establish project identity")
    end
    local ranges = invoke("projectGetElementRanges", false, false)
    if type(ranges) ~= "string" then fail("unsupported_project", "Element ranges unavailable (WinOLS 5.93 required)") end
    local first, last = ranges:match("^[^:;]+:%s*(%d+)%s*%-%s*(%d+)%s*$")
    first, last = tonumber(first), tonumber(last)
    if first ~= 0 or not last or last >= MAX_INTEGER or invoke("projectGetElementOffset") ~= 0 then
      fail("unsupported_project", "Only a single element starting at byte zero is supported")
    end
    return { id="winols:" .. options.session_id .. ":" .. filename:lower() .. ":" .. hash:lower(),
      name=filename:match("[^/\\]+$") or filename, size_bytes=last + 1 }
  end
  local function inventory(size)
    local ok, addresses = pcall(options.inventory)
    if not ok then
      local message = type(addresses) == "string" and #addresses <= 2048 and addresses or "native export failed"
      fail("unsupported_inventory", "Map CSV inventory failed: " .. message)
    end
    if type(addresses) ~= "table" or #addresses > 10000 then fail("unsupported_inventory", "Map inventory is unavailable or exceeds 10000 maps") end
    local result, counts = {}, {}
    for index, address in ipairs(addresses) do
      integer(address, 0, size - 1, "exported map address")
      local skip = counts[address] or 0
      counts[address] = skip + 1
      result[index] = { address=address, skip=skip, id=string.format("map:%.0f:%d", address, skip) }
    end
    return result
  end
  local function properties(item, size)
    local function get(key) return invoke("windowGetMapProperties", key, item.address, item.skip) end
    local function num(key) return number(get(key), key) end
    local function zero(key)
      if num(key) ~= 0 then fail("unsupported_map", key .. " must be zero for a contiguous linear definition") end
    end
    local function datatype(prefix)
      local org, sign = get(prefix .. "DataOrg"), num(prefix .. "bVorzeichen")
      for name, typ in pairs(types) do if enum(org, typ[1]) and sign == typ[2] then return name end end
      fail("unsupported_map", "Only 8/16/32-bit integer maps are supported")
    end
    local typ = get("Typ")
    if not enum(typ, "eEinzel") and not enum(typ, "eEindim") and not enum(typ, "eZweidim") then
      fail("unsupported_map", "Inverted or unknown map layout is unsupported")
    end
    for _, key in ipairs({ "SkipBytes", "LineSkipBytes", "bKehrwert", "bOriginal", "bDelta", "bProzent", "Feldwerte.PreOffset" }) do zero(key) end
    local value = { name=get("Name"), address=num("Feldwerte.StartAddr"), columns=num("Spalten"), rows=num("Zeilen"),
      data_type=datatype(""), factor=num("Feldwerte.Faktor"), offset=num("Feldwerte.Offset"), unit=get("Feldwerte.Einheit") }
    if value.address ~= item.address then fail("unsupported_map", "Map address differs from project-relative inventory") end
    for key, prefix in pairs({ x_axis="StuetzX.", y_axis="StuetzY." }) do
      local source = get(prefix .. "DataSrc")
      if not enum(source, "eDataSrcNone") then
        if not enum(source, "eRom") then fail("unsupported_map", "Only contiguous ROM axes are supported") end
        for _, suffix in ipairs({ "SkipBytes", "bRueckwaerts", "bKehrwert", "PreOffset", "DataHeader" }) do zero(prefix .. suffix) end
        value[key] = { address=num(prefix .. "DataAddr"), data_type=datatype(prefix),
          factor=num(prefix .. "Faktor"), offset=num(prefix .. "Offset"), unit=get(prefix .. "Einheit") }
      end
    end
    return { id=item.id, definition=definition(value, size) }
  end
  local function check_project(expected)
    local current = project()
    if current.id ~= expected then fail("project_changed", "Current project identity changed") end
    return current
  end
  local function created_map(request, params, current, maps)
    local wanted = definition(params.definition, current.size_bytes)
    if params.expected_project_id ~= current.id then fail("project_changed", "expected_project_id does not match the current project") end
    if #maps >= 10000 then fail("map_limit", "Project exceeds 10000 maps") end
    for _, item in ipairs(maps) do
      if item.address == wanted.address then fail("duplicate_map", "A map already starts at this address") end
    end
    local same_name = invoke("projectFindMap", "Name", wanted.name, -1)
    if type(same_name) ~= "table" then fail("native_error", "Cannot check existing map names") end
    if #same_name ~= 0 then fail("duplicate_map", "A map already has this name") end
    local marker = "__winols_mcp_" .. request.id
    local existing = invoke("projectFindMap", "Name", marker, -1)
    if type(existing) ~= "table" or #existing ~= 0 then fail("marker_conflict", "Cannot establish a unique temporary map name") end
    -- Resolve all constants before the first mutation.
    for _, name in ipairs({ "eEinzel", "eEindim", "eZweidim", "eViewText", "eDataSrcNone", "eRom" }) do constant(name) end
    for _, typ in pairs(types) do constant(typ[1]) end
    if now() >= request.expires_at then fail("expired_request", "Request expired before mutation") end
    check_project(current.id)
    if now() >= request.expires_at then fail("expired_request", "Request expired during project verification") end
    local added, named = false, false
    local function set(key, value)
      local rc = invoke("windowSetMapProperties", key, value, true)
      if rc ~= true and rc ~= 1 then fail("native_error", "WinOLS rejected map property " .. key) end
    end
    local ok, result = pcall(function()
      -- Once the call begins its outcome may be uncertain even if WinOLS throws.
      added = true
      local rc = invoke("projectAddMap")
      if rc ~= true and rc ~= 1 then fail("native_error", "WinOLS rejected projectAddMap") end
      set("Name", marker)
      named = true
      set("IdName", marker)
      set("Typ", constant(wanted.columns == 1 and wanted.rows == 1 and "eEinzel" or (wanted.rows == 1 and "eEindim" or "eZweidim")))
      set("ViewMode", constant("eViewText"))
      set("DataOrg", constant(types[wanted.data_type][1]))
      set("bVorzeichen", types[wanted.data_type][2])
      for _, key in ipairs({ "bKehrwert", "bDelta", "bProzent", "bOriginal", "bOriginalWerte", "SkipBytes", "LineSkipBytes", "Feldwerte.PreOffset" }) do set(key, 0) end
      set("Spalten", wanted.columns); set("Zeilen", wanted.rows)
      set("Feldwerte.StartAddr", wanted.address)
      set("Feldwerte.Faktor", wanted.factor); set("Feldwerte.Offset", wanted.offset); set("Feldwerte.Einheit", wanted.unit)
      for key, prefix in pairs({ x_axis="StuetzX.", y_axis="StuetzY." }) do
        local axis = wanted[key]
        set(prefix .. "DataSrc", constant(axis and "eRom" or "eDataSrcNone"))
        if axis then
          set(prefix .. "DataAddr", axis.address)
          set(prefix .. "DataOrg", constant(types[axis.data_type][1]))
          set(prefix .. "bVorzeichen", types[axis.data_type][2])
          set(prefix .. "Faktor", axis.factor); set(prefix .. "Offset", axis.offset); set(prefix .. "Einheit", axis.unit)
          for _, suffix in ipairs({ "SkipBytes", "bRueckwaerts", "bKehrwert", "PreOffset", "DataHeader" }) do set(prefix .. suffix, 0) end
        end
      end
      check_project(current.id)
      if invoke("windowGetMapProperties", "IdName", wanted.address, 0) ~= marker then
        fail("verification_failed", "Created map identity did not match its temporary identifier")
      end
      local readback = properties({ address=wanted.address, skip=0, id=string.format("map:%.0f:0", wanted.address) }, current.size_bytes)
      readback.definition.name = wanted.name
      if not same(readback.definition, wanted) then fail("verification_failed", "WinOLS map readback differs from requested definition") end
      set("Name", wanted.name)
      local final = properties({ address=wanted.address, skip=0, id=readback.id }, current.size_bytes)
      if not same(final.definition, wanted) then fail("verification_failed", "Final map readback differs from requested definition") end
      if invoke("windowGetMapProperties", "IdName", wanted.address, 0) ~= marker then
        fail("verification_failed", "Created map identity changed during readback")
      end
      check_project(current.id)
      return final
    end)
    if ok then return result end
    if added then
      local rollback_ok = false
      if named then
        rollback_ok = pcall(function()
          check_project(current.id)
          -- Only delete an exact generated name after restoring and verifying that name.
          set("Name", marker)
          local found = invoke("projectFindMap", "Name", marker, -1)
          if type(found) ~= "table" or #found ~= 1 then error("rollback target is ambiguous") end
          if invoke("projectDelMap", marker) ~= 1 then error("rollback deletion failed") end
          local remaining = invoke("projectFindMap", "Name", marker, -1)
          if type(remaining) ~= "table" or #remaining ~= 0 then error("rollback not verified") end
        end)
      end
      if not rollback_ok then
        self.halted = true
        fail("mutation_uncertain", "Map creation failed and rollback could not be verified. Stop the client and inspect WinOLS before recovery")
      end
    end
    if type(result) == "table" and result.code then
      fail(result.code, result.message .. "; temporary map was removed")
    end
    fail("native_error", "WinOLS failed while configuring the map; temporary map was removed")
  end

  function self:handle(request)
    local id = type(request) == "table" and type(request.id) == "string" and request.id or "invalid"
    local ok, result = pcall(function()
      if self.halted then fail("bridge_halted", "Bridge requires manual recovery") end
      fields(request, { protocol_version=true, id=true, operation=true, params=true, expires_at=true }, "request")
      if request.protocol_version ~= 1 then fail("protocol_error", "Unsupported protocol version") end
      if type(request.id) ~= "string" or #id > 80 or not id:match("^[A-Za-z0-9_-]+$") then fail("protocol_error", "Invalid request ID") end
      if self.seen[id] then fail("duplicate_request", "Request ID has already been processed; never replay mutations") end
      integer(request.expires_at, 0, MAX_INTEGER, "expires_at")
      if now() >= request.expires_at then fail("expired_request", "Request expired before processing") end
      if self.seen_count >= 10000 then self.halted = true; fail("bridge_halted", "Session request limit reached; restart bridge and client") end
      self.seen[id], self.seen_count = true, self.seen_count + 1
      local operation, params = request.operation, request.params
      local allowed = { get_status={}, get_project={}, list_maps={offset=true,limit=true}, get_map={id=true}, create_map={expected_project_id=true,definition=true} }
      if type(operation) ~= "string" or not allowed[operation] then fail("unknown_operation", "Unsupported bridge operation") end
      fields(params, allowed[operation], "params")
      if operation == "get_status" then
        local major, minor = invoke("GetVersion", constant("eWinOLSMajor")), invoke("GetVersion", constant("eWinOLSMinor"))
        return { backend="winols", bridge_version="0.1.0", winols_major=major, winols_minor=minor,
          live_verified=false, project_scope="single-element byte-zero", autosave=false }
      end
      local current = project()
      local maps = inventory(current.size_bytes)
      check_project(current.id)
      if operation == "get_project" then current.map_count = #maps; return current end
      if operation == "create_map" then return created_map(request, params, current, maps) end
      if operation == "list_maps" then
        local offset = integer(params.offset == nil and 0 or params.offset, 0, MAX_INTEGER, "offset")
        local limit = integer(params.limit == nil and 25 or params.limit, 1, 100, "limit")
        local output = json.array()
        for i = offset + 1, math.min(#maps, offset + limit) do output[#output + 1] = properties(maps[i], current.size_bytes) end
        check_project(current.id)
        return { maps=output, total=#maps }
      end
      text(params.id, 100, true, "map id")
      for _, item in ipairs(maps) do
        if item.id == params.id then
          local record = properties(item, current.size_bytes)
          check_project(current.id)
          return record
        end
      end
      fail("map_not_found", "Map ID does not exist in the current project")
    end)
    if ok then return { protocol_version=1, id=id, ok=true, result=result } end
    local error_value = type(result) == "table" and result.code and result or { code="native_error", message="WinOLS bridge operation failed" }
    return { protocol_version=1, id=id, ok=false, error=error_value }
  end
  return self
end
return core
