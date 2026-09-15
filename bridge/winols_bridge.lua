-- Local configuration: edit these values before dragging this file onto your WinOLS project.
local SCRIPT_DIRECTORY = [[C:\winols-mcp\bridge]]
local BRIDGE_DIRECTORY = [[C:\winols-mcp-mailbox]]
-- Copy the exact address column title from an inspected WinOLS CSV map-list export.
-- Do not enter a guessed title. Enable all maps/all columns in the WinOLS export options.
local CSV_ADDRESS_COLUMN = ""
local CSV_DELIMITER = ";"

-- Only these trusted, locally installed module files are loaded. Request data never changes paths.
local function trusted_module(name)
  local file = assert(loadfile(SCRIPT_DIRECTORY .. "\\" .. name .. ".lua"))
  package.loaded[name] = file()
  return package.loaded[name]
end
local function main()
  assert(CSV_ADDRESS_COLUMN ~= "", "Set CSV_ADDRESS_COLUMN from your own WinOLS CSV export; see bridge/README.md")
  assert(type(Sleep) == "function" and type(GetVersion) == "function", "Run this script in licensed WinOLS with OLS530")
  local major, minor = GetVersion(eWinOLSMajor), GetVersion(eWinOLSMinor)
  assert(major == 5 and minor >= 93, "This adapter targets WinOLS 5.93 or later in the WinOLS 5 series")
  trusted_module("json")
  local core = trusted_module("core")
  local mailbox = trusted_module("mailbox")
  local csv = trusted_module("csv_inventory")
  local stop_path = BRIDGE_DIRECTORY .. "\\stop"
  assert(not mailbox.exists(stop_path), "Remove the stop file before restarting the bridge")
  -- Verify the mailbox already exists and is writable without creating arbitrary paths.
  local probe_path = BRIDGE_DIRECTORY .. "\\bridge-probe.tmp"
  assert(not mailbox.exists(probe_path), "Remove stale bridge-probe.tmp before restarting")
  local probe = assert(io.open(probe_path, "wb"))
  assert(probe:close()); assert(os.remove(probe_path))
  local adapter = core.new(_G, {
    inventory=csv.new(_G, BRIDGE_DIRECTORY .. "\\inventory.csv", CSV_DELIMITER, CSV_ADDRESS_COLUMN),
    session_id=tostring(os.time()) .. "-" .. tostring(windowGetActive()),
  })
  local connection = mailbox.new(BRIDGE_DIRECTORY, adapter)
  while not mailbox.exists(stop_path) do
    connection:step()
    if connection.halted then error("Bridge stopped after an uncertain operation. Inspect WinOLS and mailbox before recovery", 0) end
    -- EVC's documented wait yields CPU and wakes for incoming requests.
    Sleep(100, BRIDGE_DIRECTORY .. "\\request.json")
  end
end
local ok, message = pcall(main)
if not ok then
  if type(MessageBox) == "function" then MessageBox("WinOLS MCP bridge stopped: " .. tostring(message))
  else error(message, 0) end
end
