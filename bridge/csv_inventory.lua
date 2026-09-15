-- Read only addresses from WinOLS CSV; get complete definitions through the native getters.
-- The address-column name and delimiter must match a locally inspected WinOLS export.
local csv = {}
function csv.parse(input, delimiter, address_column)
  assert(type(input) == "string" and #input <= 16777216, "CSV exceeds 16 MiB")
  assert(delimiter == "," or delimiter == ";" or delimiter == "\t", "CSV delimiter must be comma, semicolon, or tab")
  assert(type(address_column) == "string" and address_column ~= "", "Configure CSV_ADDRESS_COLUMN from a WinOLS CSV export")
  if input:sub(1, 3) == "\239\187\191" then input = input:sub(4) end
  local rows, row, field, pos, quoted, after_quote = {}, {}, {}, 1, false, false
  local function finish_field()
    row[#row + 1], field, after_quote = table.concat(field), {}, false
    if #row > 512 then error("Too many CSV columns", 0) end
  end
  local function finish_row()
    finish_field()
    rows[#rows + 1], row = row, {}
    if #rows > 10001 then error("Map inventory exceeds 10000 maps", 0) end
  end
  while pos <= #input do
    local c = input:sub(pos, pos)
    if quoted then
      if c == '"' then
        if input:sub(pos + 1, pos + 1) == '"' then field[#field + 1], pos = '"', pos + 1
        else quoted, after_quote = false, true end
      else field[#field + 1] = c end
    elseif c == delimiter then finish_field()
    elseif c == "\n" or c == "\r" then
      if c == "\r" and input:sub(pos + 1, pos + 1) == "\n" then pos = pos + 1 end
      finish_row()
    elseif c == '"' then
      if #field ~= 0 or after_quote then error("Invalid CSV quoting", 0) end
      quoted = true
    else
      if after_quote then error("Unexpected CSV content after closing quote", 0) end
      field[#field + 1] = c
    end
    pos = pos + 1
  end
  if quoted then error("Unclosed CSV quote", 0) end
  if #row > 0 or #field > 0 or after_quote then finish_row() end
  if #rows == 0 then error("CSV header missing", 0) end
  local column
  for index, header in ipairs(rows[1]) do
    if header == address_column then
      if column then error("Ambiguous duplicate CSV address column", 0) end
      column = index
    end
  end
  if not column then error("Configured CSV address column is missing; inspect the WinOLS export", 0) end
  local addresses = {}
  for index = 2, #rows do
    local cells = rows[index]
    if #cells ~= #rows[1] then error("CSV row has the wrong number of columns", 0) end
    local address = cells[column]
    -- The EVC help explicitly specifies project-relative decimal CSV addresses.
    if not address:match("^%d+$") then error("CSV map address is not an unsigned decimal byte offset", 0) end
    local value = tonumber(address)
    if not value or value > 9007199254740991 then error("CSV address exceeds exact numeric range", 0) end
    addresses[#addresses + 1] = value
  end
  return addresses
end

function csv.new(api, filename, delimiter, address_column)
  assert(address_column ~= "", "Configure CSV_ADDRESS_COLUMN before starting the bridge")
  local export = api.projectExportMaps or api.projectExportmaps
  assert(type(export) == "function", "WinOLS projectExportMaps function unavailable")
  return function()
    local previous = io.open(filename, "rb")
    if previous then previous:close(); assert(os.remove(filename)) end
    local success = export(filename)
    if success ~= true and success ~= 1 then error("WinOLS map CSV export failed", 0) end
    local file = assert(io.open(filename, "rb"))
    local input = file:read(16777217) or ""
    assert(file:close())
    local addresses = csv.parse(input, delimiter, address_column)
    assert(os.remove(filename))
    return addresses
  end
end
return csv
