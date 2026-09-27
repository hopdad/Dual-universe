-- Runs the bus inside the fake ArchHUD (spec/helpers) and prints every outbound line.
--
--   lua5.3 lua/tools/simulate.lua < script.txt          batch: print everything at the end
--   lua5.3 lua/tools/simulate.lua --interactive         a virtual game client for the companion
--
-- Each input line is typed into chat, except:
--   tick N    advance N timer ticks of 0.25 s
--   restart   stop the unit and start it again on the same databank
-- Batch mode runs 40 more ticks at the end so the outbox drains. Interactive mode writes
-- the bus's lines out after every input line (companion/src/dufleet/sim.py drives it).
-- Needs tools/deps.sh and dkjson. companion/tests/test_lua_bus.py feeds the batch
-- output to the Python deframer.

local root = (arg and arg[0] or ""):match("^(.*)/tools/[^/]*$") or "."
package.path = root .. "/?.lua;" .. root .. "/spec/helpers/?.lua;" .. root .. "/.deps/du-mocks/src/?.lua;"
    .. package.path

local fake = require("fake_archhud")

local out = {}
local function start(dbMock, clock)
    local h = fake.install({ dbMock = dbMock, clock = clock })
    require("autoconf/custom/archhud/userclass")
    userBase.ExtraOnStart()
    return h
end
local function collect(h)
    for _, line in ipairs(h.printed) do out[#out + 1] = line end
    h.printed = {}
end

local interactive = arg and arg[1] == "--interactive"
local function flush()
    for _, line in ipairs(out) do io.write(line, "\n") end
    out = {}
    io.stdout:flush()
end

local h = start()
for line in io.lines() do
    local n = line:match("^tick (%d+)$")
    if n then
        h.tick(tonumber(n))
    elseif line == "restart" then
        userBase.ExtraOnStop()
        collect(h)
        h = start(h.dbMock, h.clock)
    else
        h.type(line)
    end
    if interactive then
        collect(h)
        flush()
    end
end
if not interactive then h.tick(40) end
collect(h)
flush()
