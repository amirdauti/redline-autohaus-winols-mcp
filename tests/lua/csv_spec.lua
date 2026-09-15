local csv = require('csv_inventory')
local addresses = csv.parse('Name;Address\r\n"Synthetic; map";4096\r\n"Quoted ""map""";8192\r\n', ';', 'Address')
assert(#addresses == 2 and addresses[1] == 4096 and addresses[2] == 8192)
assert(#csv.parse('Name,Address\n', ',', 'Address') == 0)
assert(csv.parse('\239\187\191Address\tName\n0\t"Multi\nline"\n', '\t', 'Address')[1] == 0)
for _, example in ipairs({
  {'278644', 278644}, {'$44074', 278644}, {'$ABcDef', 11259375},
  {'0', 0}, {'$0', 0}, {'000042', 42}, {'$00002a', 42},
  {'9007199254740991', 9007199254740991}, {'$1fffffffffffff', 9007199254740991},
  {'0009007199254740991', 9007199254740991}, {'$0001FFFFFFFFFFFFF', 9007199254740991},
}) do
  assert(csv.parse('Address\n' .. example[1] .. '\n', ';', 'Address')[1] == example[2], example[1])
end
local mixed = csv.parse('Address;Name\n"$44074";Synthetic hex\n278644;Synthetic decimal\n', ';', 'Address')
assert(#mixed == 2 and mixed[1] == mixed[2])
for _, contents in ipairs({
  '', 'Wrong\n1\n', 'Address;Address\n1;2\n', 'Address\n0x100\n', 'Address\n-1\n',
  'Address\n1.5\n', 'Address\n9007199254740992\n', 'Address;Name\n1\n',
  'Address;Name\n1;"unterminated', 'Address;Name\n1;"closed"garbage\n',
}) do assert(not pcall(csv.parse, contents, ';', 'Address'), contents) end
for _, address in ipairs({
  '$', '$-1', '$+1', '$0x10', '$GG', '$1.5', '$1e+2', '$ 10', '$10 ',
  '0X10', '+1', ' 1', '1 ', '1e3', '1,000',
  '$20000000000000', '$FFFFFFFFFFFFFFFF', '$10000000000000000',
  '9007199254740993', '18446744073709551616',
}) do assert(not pcall(csv.parse, 'Address\n' .. address .. '\n', ';', 'Address'), address) end
assert(not pcall(csv.parse, 'Address\n1\n', ';', ''))
assert(not pcall(csv.parse, 'Address\n1\n', '|', 'Address'))

-- An unsuccessful native export must never reuse yesterday's inventory.
local file_path = TEST_TEMP_DIR .. '/inventory.csv'
local stale = assert(io.open(file_path, 'wb')); stale:write('Address\n123\n'); stale:close()
local inventory = csv.new({projectExportMaps=function() return false end}, file_path, ';', 'Address')
assert(not pcall(inventory))
assert(io.open(file_path, 'rb') == nil)
inventory = csv.new({projectExportMaps=function(filename)
  local file = assert(io.open(filename, 'wb')); file:write('Address;Name\n$2a;Synthetic\n'); file:close(); return true
end}, file_path, ';', 'Address')
assert(inventory()[1] == 42)
assert(io.open(file_path, 'rb') == nil)
