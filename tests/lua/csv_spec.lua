local csv = require('csv_inventory')
local addresses = csv.parse('Name;Address\r\n"Synthetic; map";4096\r\n"Quoted ""map""";8192\r\n', ';', 'Address')
assert(#addresses == 2 and addresses[1] == 4096 and addresses[2] == 8192)
assert(#csv.parse('Name,Address\n', ',', 'Address') == 0)
assert(csv.parse('\239\187\191Address\tName\n0\t"Multi\nline"\n', '\t', 'Address')[1] == 0)
for _, contents in ipairs({
  '', 'Wrong\n1\n', 'Address;Address\n1;2\n', 'Address\n0x100\n', 'Address\n-1\n',
  'Address\n1.5\n', 'Address\n9007199254740992\n', 'Address;Name\n1\n',
  'Address;Name\n1;"unterminated', 'Address;Name\n1;"closed"garbage\n',
}) do assert(not pcall(csv.parse, contents, ';', 'Address'), contents) end
assert(not pcall(csv.parse, 'Address\n1\n', ';', ''))
assert(not pcall(csv.parse, 'Address\n1\n', '|', 'Address'))

-- An unsuccessful native export must never reuse yesterday's inventory.
local file_path = TEST_TEMP_DIR .. '/inventory.csv'
local stale = assert(io.open(file_path, 'wb')); stale:write('Address\n123\n'); stale:close()
local inventory = csv.new({projectExportMaps=function() return false end}, file_path, ';', 'Address')
assert(not pcall(inventory))
assert(io.open(file_path, 'rb') == nil)
inventory = csv.new({projectExportMaps=function(filename)
  local file = assert(io.open(filename, 'wb')); file:write('Address;Name\n42;Synthetic\n'); file:close(); return true
end}, file_path, ';', 'Address')
assert(inventory()[1] == 42)
assert(io.open(file_path, 'rb') == nil)
