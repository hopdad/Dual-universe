-- Prints one optical frame for the host parity tests:
--   line 1: the colour index of every data cell, row by row, as digits
--   line 2: the SVG the probe would put in userScreen
-- Usage: lua5.3 spikes/lua/tests/dump_frame.lua SEQ BITS [CELL X Y]

local root = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\][^/\\]*$") or "spikes/lua"
package.path = root .. "/?.lua;" .. package.path
local optical = require("autoconf/custom/dufleet/optical")

local seq, bits = math.tointeger(tonumber(arg[1])), math.tointeger(tonumber(arg[2]))
local cell, x, y = tonumber(arg[3] or "6"), tonumber(arg[4] or "0"), tonumber(arg[5] or "0")
local cells = optical.cells(seq, bits)
io.write(table.concat(cells), "\n")
io.write(optical.svg(cells, x, y, cell), "\n")
