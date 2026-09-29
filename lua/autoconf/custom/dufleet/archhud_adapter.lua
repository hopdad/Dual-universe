-- The only module that touches ArchHUD's internals: The-Third-Verse/ArchHUD 2.105, modular
-- build, commit 6c95222 (docs/verification.md, ArchHUD addendum). Everything here is a
-- global ArchHUD defines. Reads degrade to nil or "unknown" when ArchHUD differs.

local M = {}

M.TESTED_VERSION = "2.105"

-- Checked in order; the first flag that is set names the mode reported in T.ap. TurnBurn
-- is a braking preference that outlives the autopilot, so it comes last.
local MODES = {
    { "Autopilot", "autopilot" }, { "VectorToTarget", "vector" }, { "spaceLaunch", "space_launch" },
    { "spaceLand", "space_land" }, { "Reentry", "reentry" }, { "BrakeLanding", "brake_landing" },
    { "AutoTakeoff", "takeoff" }, { "VertTakeOff", "vertical_takeoff" }, { "IntoOrbit", "orbit" },
    { "followMode", "follow" }, { "AltitudeHold", "altitude_hold" }, { "ProgradeIsOn", "prograde" },
    { "RetrogradeIsOn", "retrograde" }, { "BrakeIsOn", "brake" }, { "TurnBurn", "turn_burn" },
}

-- The modes in which ArchHUD moves the ship somewhere, plus alignTarget (turning toward the
-- target), which its own ::pos handler also waits out. Not altitude hold, the brake or the
-- prograde and retrograde holds: those also keep a parked or drifting ship steady.
local TRAVEL = { "Autopilot", "VectorToTarget", "spaceLaunch", "spaceLand", "Reentry", "BrakeLanding",
    "AutoTakeoff", "VertTakeOff", "IntoOrbit", "followMode", "alignTarget" }

-- Seconds between two autopilot toggles by the bus. ArchHUD reads two toggles within 1.5 s
-- in atmosphere as an orbital hop (apclass.lua, ap.ToggleAutopilot). Its own last-toggle
-- time is local, so a pilot's toggle just before cannot be seen.
M.TOGGLE_GAP = 2

local G = _ENV
local hooked
local lastToggle
local databank -- the databank ArchHUD hands its class constructors (see watchConstructors)

local function set(v)
    return v ~= nil and v ~= false
end

-- {x, y, z} from a vec3 or a list, or nil.
local function xyz(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x, y, z } end
    return nil
end

-- nil when the hooks the bus needs exist, or what is missing.
function M.problem()
    local prog = G.PROGRAM
    if type(prog) ~= "table" then return "ArchHUD's PROGRAM table not found" end
    if type(prog.controlInput) ~= "function" then return "ArchHUD's PROGRAM.controlInput not found" end
    if type(prog.onTick) ~= "function" then return "ArchHUD's PROGRAM.onTick not found" end
    if not M.unit() then return "ArchHUD's Nav.control (the control unit) not found" end
    return nil
end

-- Files loaded with require cannot see the handler slots (unit, core, dbHud_1, ...).
-- ArchHUD.conf keeps the unit and the core in its global Nav = Navigator.new(system, core,
-- unit), which stores them as Nav.control and Nav.core (the game's Navigator.lua).
local function nav(field)
    local n = G.Nav
    if type(n) ~= "table" then return nil end
    local v = n[field]
    local t = type(v)
    if t == "table" or t == "userdata" then return v end
    return nil
end

-- The control unit, or nil.
function M.unit()
    return nav("control")
end

-- The core unit, or nil.
function M.core()
    return nav("core")
end

-- ArchHUD passes its dbHud_1 slot only to its class constructors, during setup and before
-- ExtraOnStart: AtlasClass as argument 5 and APClass as argument 9 (baseclass.lua:527,552).
-- Both are globals that ArchHUD looks up when it calls them, so wrapping them when the
-- userclass shim loads, before setup runs, keeps the databank for M.databank.
function M.watchConstructors()
    local function keep(db)
        if databank == nil and db ~= nil then databank = db end
    end
    local atlasClass, apClass = G.AtlasClass, G.APClass
    if type(atlasClass) == "function" then
        G.AtlasClass = function(...)
            keep((select(5, ...)))
            return atlasClass(...)
        end
    end
    if type(apClass) == "function" then
        G.APClass = function(...)
            keep((select(9, ...)))
            return apClass(...)
        end
    end
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

-- The databank linked on ArchHUD's dbHud_1 slot, as its constructors received it, or nil.
function M.databank()
    local db = databank
    local t = type(db)
    if (t == "table" or t == "userdata") and db.getStringValue and db.setStringValue and db.hasKey then
        return db
    end
    return nil
end

-- ArchHUD's autopilot mode, e.g. "autopilot:Cruising", "altitude_hold" or "manual".
function M.autopilot()
    for _, mode in ipairs(MODES) do
        if set(G[mode[1]]) then
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
    local c = xyz(p.center)
    if not c then return nil end
    return { id = math.tointeger(p.id) or p.id, systemId = p.systemId, center = c, radius = p.radius }
end

-- ArchHUD's fuel tank lists, one entry per tank: { id, name, max fuel mass (kg), empty mass
-- (kg), ... } (baseclass.lua:267-281,333-343; hudclass.lua:2186-2192 names the positions).
-- ArchHUD fills them at start while its fuel display is on (fuelX and fuelY not 0, the default).
local TANKS = { atmo = "atmoTanks", space = "spaceTanks", rocket = "rocketTanks" }

-- Fuel left per type, as a fraction of the capacity of all tanks of that type, the way
-- ArchHUD computes a tank's percentage (hudclass.lua:2315-2330): { atmo = 0.82, ... }.
-- Types without tanks are left out; nil when ArchHUD lists no tanks. elementMass(id) gives
-- an element's current mass.
function M.fuel(elementMass)
    local out
    for kind, name in pairs(TANKS) do
        local tanks = G[name]
        local fuel, capacity = 0, 0
        for _, tank in ipairs(type(tanks) == "table" and tanks or {}) do
            local mass, max, empty = elementMass(tank[1]), tank[3], tank[4]
            if type(mass) == "number" and type(max) == "number" and type(empty) == "number" and max > 0 then
                fuel, capacity = fuel + math.max(0, mass - empty), capacity + max
            end
        end
        if capacity > 0 then
            out = out or {}
            out[kind] = math.min(1, fuel / capacity)
        end
    end
    return out
end

-- Whether ArchHUD counts the ship as in atmosphere (its inAtmo, set on every tick).
function M.inAtmosphere()
    return G.inAtmo == true
end

-- Flying for goto (skills/goto.lua), the way a pilot does it: select a target, then
-- toggle the autopilot once (docs/verification.md, ArchHUD addendum).

-- The travel mode that is set, or nil.
function M.travelling()
    for _, name in ipairs(TRAVEL) do
        if set(G[name]) then return name end
    end
    return nil
end

-- Why ArchHUD cannot take a new target now, or nil: a travel mode is set, or a route is
-- loaded (ToggleAutopilot would fly the route's first stop instead).
function M.busy()
    local mode = M.travelling()
    if mode then return "ArchHUD is busy: " .. mode end
    local route = G.apRoute
    if type(route) == "table" and #route > 0 then return "an ArchHUD route is loaded" end
    return nil
end

-- World position {x, y, z} of a map position, as ArchHUD converts ::pos
-- (controlclass.lua, zeroConvertToWorldCoordinates), and the body's center. Body 0 means
-- deep space: lat, lon and alt are then world x, y and z. Nil and a reason when the body
-- is not in ArchHUD's atlas.
function M.worldFromMap(systemId, bodyId, lat, lon, alt)
    if bodyId == 0 then return { lat, lon, alt } end
    local ref = G.galaxyReference
    local ok, body = pcall(function() return ref[systemId][bodyId] end)
    local c = ok and type(body) == "table" and xyz(body.center)
    if not c or type(body.radius) ~= "number" then
        return nil, string.format("body %d in system %d is not in ArchHUD's atlas", bodyId, systemId)
    end
    local la, lo = math.rad(lat), math.rad(lon)
    local r, xproj = body.radius + alt, math.cos(la)
    return { c[1] + r * xproj * math.cos(lo), c[2] + r * xproj * math.sin(lo), c[3] + r * math.sin(la) }, c
end

local function atlasIndex(name)
    local list = G.AtlasOrdered
    if type(list) ~= "table" then return nil end
    for i, entry in ipairs(list) do
        if entry.name == name then return i end
    end
    return nil
end

-- Makes world position `w` ArchHUD's autopilot target, as a temporary location (not saved
-- to the databank) called `name`. ATLAS.AddNewLocation selects whichever location sorts
-- first by name, so the bus then selects its own by index. A location of that name at the
-- same place is selected again rather than added twice, since ArchHUD replaces one by
-- table.remove() on its body-id keyed atlas; at another place, the name gets a suffix.
-- Returns true and the name of the target's planet ("Space" when off planets), or nil and
-- a reason.
function M.selectTarget(name, w)
    local atlas = G.ATLAS
    if type(atlas) ~= "table" or not atlas.AddNewLocation or not atlas.UpdateAutopilotTarget then
        return nil, "ArchHUD's ATLAS not found"
    end
    for n = 1, 9 do
        local candidate = n == 1 and name or name .. "-" .. n
        local i = atlasIndex(candidate)
        if not i then
            if G.vec3 == nil then return nil, "vec3 not found" end
            atlas.AddNewLocation(candidate, G.vec3(w[1], w[2], w[3]), true)
            i = atlasIndex(candidate)
            if not i then return nil, "ArchHUD did not add the location" end
        end
        G.AutopilotTargetIndex = i
        atlas.UpdateAutopilotTarget()
        local target = G.CustomTarget
        if type(target) ~= "table" or target.name ~= candidate then
            return nil, "ArchHUD did not select the location"
        end
        local p = xyz(target.position)
        if p and math.abs(p[1] - w[1]) + math.abs(p[2] - w[2]) + math.abs(p[3] - w[3]) < 1 then
            return true, target.planetname
        end
    end
    return nil, "too many locations called " .. name
end

function M.canToggle(now)
    return lastToggle == nil or now - lastToggle >= M.TOGGLE_GAP
end

-- Toggles the autopilot on toward the selected target. Returns the travel mode it
-- engaged, or nil and a reason; the caller checks canToggle first.
function M.engage(now)
    local ap = G.AP
    if type(ap) ~= "table" or not ap.ToggleAutopilot then return nil, "ArchHUD's AP not found" end
    local busy = M.busy()
    if busy then return nil, busy end
    lastToggle = now
    ap.ToggleAutopilot()
    local mode = M.travelling()
    if not mode then return nil, "ArchHUD's autopilot did not engage" end
    return mode
end

-- Stops every autopilot mode, cuts the throttle and sets the brake, leaving a brake that
-- is already set alone (AP.BrakeToggle would release it).
function M.stop()
    local ap = G.AP
    if type(ap) ~= "table" or not ap.clearAll then return nil, "ArchHUD's AP not found" end
    ap.clearAll()
    if ap.cmdThrottle then ap.cmdThrottle(0) end
    if not set(G.BrakeIsOn) and ap.BrakeToggle then ap.BrakeToggle() end
    return true
end

-- The global ArchHUD adds to its HUD content on each redraw (Transport O).
function M.setScreen(svg)
    G.userScreen = svg
end

return M
