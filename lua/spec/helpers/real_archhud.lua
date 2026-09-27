-- The real ArchHUD 2.105 atlas and autopilot classes, from lua/.deps (tools/deps.sh fetches
-- The-Third-Verse/ArchHUD and The-Third-Verse/AtlasFile at their pinned commits). They start
-- the way baseclass.lua starts them, with ArchHUD's own globals.lua and the defaults of its
-- --export settings, in a game made of stubs: just enough for the calls goto makes. Everything
-- else, the Lua bus included, comes from fake_archhud; this replaces its fake ATLAS and AP.
--
-- M.install{ at = "ground" | "space" } puts the ship landed on Alioth, or in space 2000 km
-- from it, and sets the globals ArchHUD's ticks would (inAtmo, coreAltitude, planet, ...).
local fake = require("fake_archhud")

local M = { DIR = ".deps/archhud/", ATLAS = ".deps/atlasfile/atlas.lua" }

function M.available()
    local f = io.open(M.DIR .. "src/requires/apclass.lua")
    if f then f:close() end
    return f ~= nil
end

-- ArchHUD.conf's --export settings, at their defaults.
local function loadExports()
    for line in io.lines(M.DIR .. "ArchHUD.conf") do
        local name, value = line:match("^%s*([%a_][%w_]*)%s*=%s*(.-)%s*%-%-export")
        local chunk = name and load("return " .. value)
        if chunk then
            local ok, v = pcall(chunk)
            if ok then _G[name] = v end
        end
    end
end

-- The helpers baseclass.lua passes to the classes (baseclass.lua:39-60, 86, 117).
local function float_eq(a, b)
    if a == 0 then return math.abs(b) < 1e-09 end
    if b == 0 then return math.abs(a) < 1e-09 end
    return math.abs(a - b) < math.max(math.abs(a), math.abs(b)) * 2.220446049250313e-16
end

local function round(num, places)
    local mult = 10 ^ (places or 0)
    return math.floor(num * mult + 0.5) / mult
end

local function addTable(a, b)
    for _, v in ipairs(b) do a[#a + 1] = v end
    return a
end

-- ArchHUD's atlas setup (baseclass.lua:430-527), for the entries it reads.
local function buildAtlas()
    local atlas = dofile(M.ATLAS)
    local function extra(id, name, center)
        return { id = id, name = { name }, center = center, gravity = 0, radius = 0, atmosphereThickness = 0,
            hasAtmosphere = false, surfaceMaxAltitude = 0, GM = 0, systemId = 0 }
    end
    local copy = {}
    for galaxyId in pairs(atlas) do
        atlas[galaxyId][0] = extra(0, "Space", { 0, 0, 0 })
        atlas[galaxyId][0].systemId = galaxyId
        atlas[galaxyId][1000] = extra(1000, "Aegis", { 13856549.3576, 7386341.6738, -258459.8925 })
        copy[galaxyId] = {}
        for planetId, planet in pairs(atlas[galaxyId]) do
            planet.gravity = planet.gravity / 9.8
            planet.center = vec3(planet.center)
            planet.name = planet.name[1]
            planet.noAtmosphericDensityAltitude = planet.atmosphereThickness
            planet.spaceEngineMinAltitude = 0.5353125 * planet.atmosphereThickness
            planet.planetarySystemId = galaxyId
            planet.bodyId = planet.id
            copy[galaxyId][planetId] = planet
        end
    end
    return atlas, copy
end

function M.install(opts)
    opts = opts or {}
    local h = fake.install(opts)
    h.msgs, h.sounds, h.throttle, h.flySpeed = {}, {}, nil, 0 -- ArchHUD's own code flies now, if anything
    vec3 = require("vec3")
    pid = { new = function() return { inject = function() end, get = function() return 0 end } end }
    utils = { sign = function(x) return x > 0 and 1 or x < 0 and -1 or 0 end,
        clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end }
    axisCommandId = { longitudinal = 0, lateral = 1, vertical = 2 }
    axisCommandType = { unused = -1, byThrottle = 0, byTargetSpeed = 1 }

    -- The game, as ArchHUD sees it: s (system), C (construct), c (core), u (unit), Nav.
    DUSystem = { getArkTime = function() return h.clock end, getAxisValue = function() return 0 end,
        print = function() end, setWaypoint = function() end }
    DUConstruct = {
        getWorldOrientationUp = function() return { 0, 0, 1 } end,
        getWorldOrientationForward = function() return { 0, 1, 0 } end,
        getWorldOrientationRight = function() return { 1, 0, 0 } end,
        getVelocity = function() return { 0, 0, 0 } end,
        getWorldVelocity = function() return h.construct.velocity end,
        getWorldPosition = function() return h.construct.position end,
        getMaxSpeed = function() return 50000 end,
        getMass = function() return 50000 end,
    }
    local c = { getGravityIntensity = function() return 9.8 end, getWorldVertical = function() return { 0, 0, -1 } end,
        getAltitude = function() return 0 end }
    local u = { getThrottle = function() return 0 end, getClosestPlanetInfluence = function() return 1 end,
        getAtmosphereDensity = function() return 1 end }
    local navCom = {
        getAxisCommandType = function() return axisCommandType.byThrottle end,
        setThrottleCommand = function(_, _, value) h.throttle = value end,
        setTargetGroundAltitude = function() end,
        deactivateGroundEngineAltitudeStabilization = function() end,
        updateCommandFromActionStart = function() end,
    }
    local Nav = { axisCommandManager = navCom, maxForceForward = function() return 1e7 end,
        control = { isRemoteControlled = function() return false end, cancelCurrentControlMasterMode = function() end,
            isAnyLandingGearDeployed = function() return false end } }

    local function msg(text) h.msgs[#h.msgs + 1] = text end
    local function play(sound) h.sounds[#h.sounds + 1] = sound end
    local function nop() end

    loadExports()
    dofile(M.DIR .. "src/requires/globals.lua")
    coreAltitude, showHud = 0, true
    globalDeclare(c, u, DUSystem.getArkTime, math.floor, u.getAtmosphereDensity)

    local atlas, copy = buildAtlas()
    dofile(M.DIR .. "src/requires/atlasclass.lua")
    local clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
    PlanetaryReference = PlanetRef(Nav, c, u, DUSystem, string.format, clamp, tonumber, math.sqrt, float_eq)
    galaxyReference = PlanetaryReference(copy)
    sys = galaxyReference[0]
    Kinematic = Kinematics(Nav, c, u, DUSystem, math.sqrt, math.abs)
    Kep = Keplers(Nav, c, u, DUSystem, string.format, clamp, tonumber, math.sqrt, float_eq)
    ATLAS = AtlasClass(Nav, c, u, DUSystem, dbHud_1, atlas, nop, nop, math.floor, tonumber, math.sqrt, play, round,
        msg)
    dofile(M.DIR .. "src/requires/apclass.lua")
    AP = APClass(Nav, c, u, atlas, nil, nil, nil, nil, dbHud_1, math.abs, math.floor, u.getAtmosphereDensity,
        Nav.control.isRemoteControlled, math.atan, DUSystem.getArkTime, clamp, navCom, nop, function() return false end,
        math.sqrt, round, play, addTable, float_eq, function(d) return tostring(d) end, tostring, nop, nop, msg)

    -- Where the ship is, and what ArchHUD's ticks would have worked out from it.
    local alioth = sys[2]
    h.alioth = alioth
    if opts.at == "space" then
        local p = alioth.center + vec3(2000000, 0, 0)
        h.construct.position = { p.x, p.y, p.z }
        inAtmo, atmosDensity, coreAltitude, nearPlanet, abvGndDet = false, 0, 0, false, -1
    else
        local p = alioth.center + vec3(alioth.radius + 300, 0, 0)
        h.construct.position = { p.x, p.y, p.z }
        inAtmo, atmosDensity, coreAltitude, nearPlanet, abvGndDet = true, 1, 300, true, 1
    end
    h.construct.velocity = { 0, 0, 0 }
    worldPos = vec3(h.construct.position)
    planet = sys:closestBody(worldPos)
    time, velMag, coreMass, SpaceEngines = h.clock, 0, 50000, true
    return h
end

return M
