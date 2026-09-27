-- A stand-in for ArchHUD 2.105 and the game API, enough for the bus: the PROGRAM
-- entry points ArchHUD's script handlers call, its autopilot globals, and the elements
-- (du-mocks for the control unit, core and databank; small fakes where du-mocks leaves
-- a call unimplemented).
--
-- The atlas and autopilot follow atlasclass.lua and apclass.lua at 6c95222 as far as goto
-- uses them: AddNewLocation selects whichever location sorts first, UpdateAutopilotTarget
-- selects by AutopilotTargetIndex, and ToggleAutopilot engages only when no mode is set
-- (and records an orbital hop for two toggles within 1.5 s in atmosphere). While a mode
-- is set, each tick flies the ship toward the target at h.flySpeed (m/s); on arrival it
-- stops `h.miss` metres off and sets the brake, as ArchHUD's brake landing ends. Set
-- h.flySpeed = 0 to move the ship by hand.
local frames = require("frames")

local M = {}

-- Alioth in ArchHUD's atlas: the body goto specs fly on.
M.ALIOTH = { id = 2, systemId = 0, name = "Alioth", center = { x = -8, y = -8, z = -126303 }, radius = 126067.8984375,
    noAtmosphericDensityAltitude = 10000 }

local TRAVEL = { "Autopilot", "VectorToTarget", "spaceLaunch", "spaceLand", "Reentry", "BrakeLanding", "AutoTakeoff",
    "VertTakeOff", "IntoOrbit", "followMode", "alignTarget" }

local function installAutopilot(h)
    local space = { name = "Space", id = 0, systemId = 0 }
    h.atlas0 = { [0] = space, [2] = M.ALIOTH } -- ArchHUD's atlas[0], keyed by body id
    galaxyReference = { [0] = { [0] = space, [2] = M.ALIOTH } }
    vec3 = function(x, y, z) return { x = x, y = y, z = z } end
    h.added, h.replaced, h.toggles, h.hops, h.cleared, h.throttle = {}, 0, {}, 0, 0, nil
    h.inAtmo, h.flySpeed, h.miss = true, 2000, { 3, 4, 0 }

    local function order()
        AtlasOrdered = {}
        for k, v in pairs(h.atlas0) do AtlasOrdered[#AtlasOrdered + 1] = { name = v.name, index = k } end
        table.sort(AtlasOrdered, function(a, b) return a.name < b.name end)
    end
    order()
    AutopilotTargetIndex, CustomTarget, apRoute = 0, nil, {}
    for _, name in ipairs(TRAVEL) do _G[name] = false end

    local function planetName(position)
        local b = M.ALIOTH
        local dx, dy, dz = position.x - b.center.x, position.y - b.center.y, position.z - b.center.z
        if math.sqrt(dx * dx + dy * dy + dz * dz) > b.radius + b.noAtmosphericDensityAltitude then return "Space" end
        return b.name
    end

    ATLAS = {}
    function ATLAS.UpdateAutopilotTarget()
        if AutopilotTargetIndex == 0 then
            CustomTarget = nil
            return
        end
        local entry = h.atlas0[AtlasOrdered[AutopilotTargetIndex].index]
        CustomTarget = not entry.center and entry or nil
    end
    function ATLAS.AddNewLocation(name, position, temp)
        h.added[#h.added + 1] = name
        for k, v in pairs(h.atlas0) do
            if v.name == name then
                h.replaced = h.replaced + 1
                table.remove(h.atlas0, k)
            end
        end
        table.insert(h.atlas0, { name = name, position = position, planetname = planetName(position) })
        order()
        if temp then AutopilotTargetIndex = 1 end
        ATLAS.UpdateAutopilotTarget()
    end

    AP = {}
    function AP.clearAll()
        h.cleared = h.cleared + 1
        for _, name in ipairs(TRAVEL) do _G[name] = false end
        AltitudeHold = false
    end
    function AP.ToggleAutopilot()
        local last = h.toggles[#h.toggles]
        if last and h.clock - last < 1.5 and h.inAtmo then h.hops = h.hops + 1 end
        h.toggles[#h.toggles + 1] = h.clock
        if (AutopilotTargetIndex > 0 or #apRoute > 0) and not Autopilot and not VectorToTarget and not spaceLaunch
            and not IntoOrbit then
            ATLAS.UpdateAutopilotTarget()
            if CustomTarget and CustomTarget.planetname ~= "Space" and h.inAtmo then
                VectorToTarget, AltitudeHold = true, true
            else
                Autopilot, AutopilotStatus = true, "Aligning"
            end
        else
            AP.clearAll()
        end
    end
    function AP.BrakeToggle()
        if not BrakeIsOn then BrakeIsOn = true else BrakeIsOn = false end
    end
    function AP.cmdThrottle(value)
        h.throttle = value
    end

    -- One tick of flight toward CustomTarget while ArchHUD flies.
    function h.fly(dt)
        if h.flySpeed <= 0 or not CustomTarget or not (Autopilot or VectorToTarget) then return end
        local p, t = h.construct.position, CustomTarget.position
        local d = { t.x - p[1], t.y - p[2], t.z - p[3] }
        local len = math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
        local step = h.flySpeed * dt
        if len <= step then
            h.construct.position = { t.x + h.miss[1], t.y + h.miss[2], t.z + h.miss[3] }
            h.construct.velocity = { 0, 0, 0 }
            AP.clearAll()
            BrakeIsOn = "BL Complete"
        else
            h.construct.position = { p[1] + d[1] / len * step, p[2] + d[2] / len * step, p[3] + d[3] / len * step }
            h.construct.velocity = { d[1] / len * h.flySpeed, d[2] / len * h.flySpeed, d[3] / len * h.flySpeed }
            BrakeIsOn = false
        end
    end
end

function M.install(opts)
    opts = opts or {}
    local h = { printed = {}, archInputs = {}, archTicks = {}, clock = opts.clock or 1790000000.0 }

    system = {
        print = function(s) h.printed[#h.printed + 1] = s end,
        getUtcTime = function() return h.clock end,
    }
    h.unitMock = require("dumocks.ControlUnit"):new(nil, 1, "remote controller xs")
    unit = h.unitMock:mockGetClosure()
    h.coreMock = require("dumocks.CoreUnit"):new(nil, 2, "dynamic core unit xs")
    h.coreMock.altitude = 285.54
    core = h.coreMock:mockGetClosure()
    h.construct = { id = opts.constructId or 4242, position = { -123456.54, 98765.25, 42.0 }, velocity = { 3, 4, 0 } }
    construct = {
        getId = function() return h.construct.id end,
        getWorldPosition = function() return h.construct.position end,
        getWorldVelocity = function() return h.construct.velocity end,
    }
    if opts.databank == false then
        dbHud_1 = nil
    else
        h.dbMock = opts.dbMock or require("dumocks.DatabankUnit"):new(nil, 3)
        dbHud_1 = h.dbMock:mockGetClosure()
    end
    PROGRAM = {
        controlInput = function(text) h.archInputs[#h.archInputs + 1] = text end,
        onTick = function(id) h.archTicks[#h.archTicks + 1] = id end,
    }
    VERSION_NUMBER = 2.105
    SetupComplete = true
    AltitudeHold, BrakeIsOn, AutopilotStatus, TurnBurn = false, false, "Aligning", false
    installAutopilot(h)
    planet = nil -- ArchHUD's current body; specs set it when they need one
    userBase, userScreen = nil, nil

    -- Every test starts from freshly loaded bus modules.
    for name in pairs(package.loaded) do
        if name:find("^autoconf/custom/") then package.loaded[name] = nil end
    end

    -- script.onInputText and script.onTick, as ArchHUD.conf wires them.
    function h.type(text) PROGRAM.controlInput(text) end
    function h.tick(n, dt)
        for _ = 1, n or 1 do
            h.clock = h.clock + (dt or 0.25)
            h.fly(dt or 0.25)
            PROGRAM.onTick("dub")
        end
    end
    function h.messages() return frames.messages(h.printed) end
    function h.ofKind(kind) return frames.ofKind(h.messages(), kind) end
    return h
end

return M
