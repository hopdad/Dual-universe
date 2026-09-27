-- The only module that touches ArchHUD's internals: The-Third-Verse/ArchHUD 2.105, modular
-- build, commit 6c95222 (docs/verification.md, ArchHUD addendum). Everything here is a
-- global ArchHUD defines. Reads degrade to nil or "unknown" when ArchHUD differs.

local M = {}

M.TESTED_VERSION = "2.105"

-- Checked in order; the first flag that is set names the mode reported in T.ap.
local MODES = {
    { "Autopilot", "autopilot" }, { "VectorToTarget", "vector" }, { "spaceLaunch", "space_launch" },
    { "spaceLand", "space_land" }, { "Reentry", "reentry" }, { "BrakeLanding", "brake_landing" },
    { "AutoTakeoff", "takeoff" }, { "IntoOrbit", "orbit" }, { "AltitudeHold", "altitude_hold" },
    { "TurnBurn", "turn_burn" }, { "ProgradeIsOn", "prograde" }, { "RetrogradeIsOn", "retrograde" },
    { "BrakeIsOn", "brake" },
}

local G = _ENV
local hooked

-- nil when the hooks the bus needs exist, or what is missing.
function M.problem()
    local prog = G.PROGRAM
    if type(prog) ~= "table" then return "ArchHUD's PROGRAM table not found" end
    if type(prog.controlInput) ~= "function" then return "ArchHUD's PROGRAM.controlInput not found" end
    if type(prog.onTick) ~= "function" then return "ArchHUD's PROGRAM.onTick not found" end
    return nil
end

function M.version()
    local v = G.VERSION_NUMBER
    if type(v) == "number" then return string.format("%.3f", v) end
    return "unknown"
end

function M.setupComplete()
    return G.SetupComplete == true
end

-- True for the chat lines the bus takes. They never reach ArchHUD, which would turn a
-- line containing "::pos" into a waypoint.
function M.isBusLine(text)
    return type(text) == "string" and (text == "/b" or text:sub(1, 3) == "/b ")
end

-- Wraps PROGRAM.controlInput (script.onInputText) and PROGRAM.onTick (script.onTick).
-- Other chat lines and other timers still reach ArchHUD.
function M.hook(timerTag, onLine, onTick)
    local prog = G.PROGRAM
    local input, tick = prog.controlInput, prog.onTick
    prog.controlInput = function(text)
        if M.isBusLine(text) then return onLine(text) end
        return input(text)
    end
    prog.onTick = function(id)
        if id == timerTag then return onTick() end
        return tick(id)
    end
    hooked = { prog = prog, input = input, tick = tick }
end

function M.unhook()
    if hooked then
        hooked.prog.controlInput, hooked.prog.onTick = hooked.input, hooked.tick
        hooked = nil
    end
end

-- The databank linked on ArchHUD's dbHud_1 slot, or nil.
function M.databank()
    local db = G.dbHud_1
    local t = type(db)
    if (t == "table" or t == "userdata") and db.getStringValue and db.setStringValue and db.hasKey then
        return db
    end
    return nil
end

-- ArchHUD's autopilot mode, e.g. "autopilot:Cruising", "altitude_hold" or "manual".
function M.autopilot()
    for _, mode in ipairs(MODES) do
        local v = G[mode[1]]
        if v ~= nil and v ~= false then
            if mode[1] == "Autopilot" and type(G.AutopilotStatus) == "string" then
                return ("autopilot:" .. G.AutopilotStatus):sub(1, 40)
            end
            return mode[2]
        end
    end
    return "manual"
end

-- The body ArchHUD currently flies relative to (its global `planet`, the closest body in its
-- atlas): { id, systemId, center = {x, y, z}, radius }, or nil.
function M.body()
    local p = G.planet
    if type(p) ~= "table" or type(p.id) ~= "number" or type(p.center) ~= "table" or type(p.radius) ~= "number" then
        return nil
    end
    local c = p.center
    local x, y, z = c.x or c[1], c.y or c[2], c.z or c[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return { id = math.tointeger(p.id) or p.id, systemId = p.systemId, center = { x, y, z }, radius = p.radius }
end

-- The global ArchHUD adds to its HUD content on each redraw (Transport O).
function M.setScreen(svg)
    G.userScreen = svg
end

return M
