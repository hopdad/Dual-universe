-- A stand-in for ArchHUD 2.105 and the game API, enough for the bus: the PROGRAM
-- entry points ArchHUD's script handlers call, its autopilot globals, and the elements
-- (du-mocks for the control unit, core and databank; small fakes where du-mocks leaves
-- a call unimplemented).
local frames = require("frames")

local M = {}

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
    Autopilot, AltitudeHold, BrakeIsOn, AutopilotStatus = false, false, false, "Aligning"
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
            PROGRAM.onTick("dub")
        end
    end
    function h.messages() return frames.messages(h.printed) end
    function h.ofKind(kind) return frames.ofKind(h.messages(), kind) end
    return h
end

return M
