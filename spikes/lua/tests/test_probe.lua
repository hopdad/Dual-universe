-- Offline test for the dufleet probe, with a fake ArchHUD and a fake game API.
-- Run from anywhere with Lua 5.3:   lua5.3 spikes/lua/tests/test_probe.lua
-- Uses a scratch directory for the inbox file (DUFLEET_TMP, or a new temp dir).

local root = (arg and arg[0] or ""):match("^(.*)/tests/[^/]*$") or "spikes/lua"
local tmp = os.getenv("DUFLEET_TMP")
if not tmp then
    tmp = os.tmpname()
    os.remove(tmp)
end
assert(os.execute('mkdir -p "' .. tmp .. '/autoconf/custom/dufleet"'))
package.path = tmp .. "/?.lua;" .. root .. "/?.lua;" .. package.path

-- Fake game API ---------------------------------------------------------------
local clock = 1790000000.0
local printed = {}
local counter = 1000
system = {
    print = function(s) printed[#printed + 1] = s end,
    getUtcTime = function() return clock end,
    getInstructionCount = function() counter = counter + 7 return counter end,
    getInstructionLimit = function() return 500000 end,
}
local timers = {}
unit = {
    setTimer = function(tag, period) timers[tag] = period end,
    stopTimer = function(tag) timers[tag] = nil end,
}
local archInputs, archTicks = {}, {}
PROGRAM = {
    controlInput = function(text) archInputs[#archInputs + 1] = text end,
    onTick = function(id) archTicks[#archTicks + 1] = id end,
}

-- Helpers ---------------------------------------------------------------------
local failures = 0
local function check(cond, msg)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. msg)
    end
end
local function linesOf(kind)
    local out = {}
    for _, l in ipairs(printed) do
        if l:sub(1, #("@@DUB|probe|" .. kind .. "|")) == "@@DUB|probe|" .. kind .. "|" then out[#out + 1] = l end
    end
    return out
end
local function tick(n)
    for _ = 1, n do
        clock = clock + 0.25
        PROGRAM.onTick("dub")
    end
end
local function writeInbox(seq)
    local f = assert(io.open(tmp .. "/autoconf/custom/dufleet/inbox.lua", "w"))
    f:write(string.format("return {seq = %d, t = %.3f}\n", seq, clock - 0.1))
    f:close()
end

-- The shim, as ArchHUD would load and call it ---------------------------------
require("autoconf/custom/archhud/userclass")
check(type(userBase) == "table", "userclass defines the global userBase")
for _, k in ipairs({ "ExtraOnStart", "ExtraOnStop", "ExtraOnUpdate", "ExtraOnFlush" }) do
    check(type(userBase[k]) == "function", "userBase." .. k .. " exists (ArchHUD calls it unconditionally)")
end
local probe = require("autoconf/custom/dufleet/probe")
local st = probe._state

userBase.ExtraOnStart()
check(timers.dub == 0.25, "start sets the dub timer")
check(#linesOf("hello") == 1, "start prints a hello line")
check(linesOf("hello")[1]:find("package=table", 1, true) ~= nil, "hello reports the package table")
check(type(userScreen) == "string" and userScreen:find("dufleet probe", 1, true) ~= nil, "panel is drawn")

-- A2: /b lines are consumed, even with ::pos inside; everything else reaches ArchHUD
PROGRAM.controlInput("/b ping ::pos{0,2,35.3951,104.1187,285.5413}")
check(#archInputs == 0, "/b line with ::pos does not reach ArchHUD")
check(#linesOf("pong") == 1, "/b ping replies")
PROGRAM.controlInput("/commands")
PROGRAM.controlInput("/bogus")
check(#archInputs == 2 and archInputs[2] == "/bogus", "non-/b lines reach ArchHUD")
check(st.passthru == 2, "passthrough counted")
PROGRAM.onTick("apTick")
check(archTicks[1] == "apTick", "ArchHUD timers still reach ArchHUD")

-- S0: heartbeat lines and the length sweep (first beat on the first tick, then every 2 s)
tick(9)
check(#linesOf("tick") == 2, "heartbeat lines every 2 s (got " .. #linesOf("tick") .. ")")
PROGRAM.controlInput("/b len")
tick(8)
local sweep = linesOf("len")
check(#sweep == 8, "length sweep prints 8 lines (got " .. #sweep .. ")")
for i, len in ipairs({ 100, 200, 400, 800, 1600, 3200, 6400, 12800 }) do
    local l = sweep[i] or ""
    check(#l == len and l:sub(-4) == "|END", "sweep line " .. i .. " is exactly " .. len .. " chars")
end
PROGRAM.controlInput("/b esc")
check(linesOf("esc")[1]:find('<>&"', 1, true) ~= nil, "escape line keeps special characters")

-- S11: inbox re-reads see changes because package.loaded is cleared
writeInbox(1)
tick(2)
check(st.inbox_seq == 1 and st.inbox_state == "ok", "inbox seq 1 read (state " .. tostring(st.inbox_state) .. ")")
writeInbox(2)
tick(2)
check(st.inbox_seq == 2 and st.inbox_changes == 2, "inbox change to seq 2 seen")
check(#linesOf("inbox") == 2, "each inbox change is printed")
PROGRAM.controlInput("/b inbox off")
writeInbox(3)
tick(4)
check(st.inbox_seq == 2, "inbox off stops reads")

-- S1: the optical frame goes into userScreen
PROGRAM.controlInput("/b frame on")
tick(4)
check(st.frame_seq >= 1, "frames are built")
check(userScreen:find('fill="#0000FF"', 1, true) ~= nil and userScreen:find("viewBox=\"0 0 56 32\"", 1, true) ~= nil,
    "frame SVG is in userScreen")
PROGRAM.controlInput("/b bits 1")
tick(4)
check(userScreen:find('fill="#FF0000"', 1, true) == nil, "1-bit frames use black and green only")
PROGRAM.controlInput("/b frame off")
tick(1)
check(userScreen:find("viewBox", 1, true) == nil, "frame off removes it")

-- S3 and S10
PROGRAM.controlInput("/b echo hello world")
check(linesOf("echo")[1]:find("|19|", 1, true) ~= nil, "echo reports the input length")
userBase.ExtraOnUpdate()
userBase.ExtraOnFlush()
check(st.upd_max > 0 and st.flush_max > 0, "update and flush instruction counts recorded")
PROGRAM.controlInput("/b stats")
check(#linesOf("stats") == 1, "stats line printed")

-- A bug inside the probe is contained
local optical = require("autoconf/custom/dufleet/optical")
local realSvg = optical.svg
optical.svg = function() error("boom") end
PROGRAM.controlInput("/b frame on")
local ok = pcall(tick, 2)
optical.svg = realSvg
check(ok and st.errors >= 1, "errors are caught and counted")

-- Unknown /b verbs print help; bare /b too
local before = #printed
PROGRAM.controlInput("/b")
check(#printed > before and #archInputs == 2, "bare /b prints help and stays with the probe")

-- Stop
userBase.ExtraOnStop()
check(timers.dub == nil and userScreen == nil, "stop removes the timer and the HUD content")
check(#linesOf("bye") == 1, "stop prints bye")

-- CRC-8/SMBUS check value
local bytes = {}
for c in ("123456789"):gmatch(".") do bytes[#bytes + 1] = c:byte() end
check(optical._crc8(bytes) == 0xF4, "crc8 check value")

if failures > 0 then
    print(failures .. " check(s) failed")
    os.exit(1)
end
print("probe tests passed")
