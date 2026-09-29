-- The game API calls the bus makes, in one place so the tests can replace them. Each
-- returns nil when the element or call is missing.
--
-- Files loaded with require cannot see the handler slots (system, unit, construct, core,
-- ...). The system and construct APIs are the globals DUSystem and DUConstruct, as
-- ArchHUD's own classes use them; the unit and the core come from ArchHUD (its global
-- Nav, through archhud_adapter).

local adapter = require("autoconf/custom/dufleet/archhud_adapter")

local M = {}

local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x, y, z } end
    return nil
end

local function unit()
    local u = adapter.unit()
    if not u then error("the control unit is not reachable (ArchHUD's Nav.control)") end
    return u
end

function M.now()
    return DUSystem.getUtcTime()
end

function M.print(s)
    DUSystem.print(s)
end

function M.setTimer(tag, period)
    unit().setTimer(tag, period)
end

function M.stopTimer(tag)
    unit().stopTimer(tag)
end

function M.constructId()
    local construct = DUConstruct
    if construct and construct.getId then return math.tointeger(construct.getId()) end
    return nil
end

-- World position of the construct, metres.
function M.position()
    local construct = DUConstruct
    if construct and construct.getWorldPosition then return vec(construct.getWorldPosition()) end
    return nil
end

-- World velocity relative to the parent body, m/s.
function M.velocity()
    local construct = DUConstruct
    if construct and construct.getWorldVelocity then return vec(construct.getWorldVelocity()) end
    return nil
end

-- Mass of one of the construct's elements, kg.
function M.elementMass(id)
    local core = adapter.core()
    if core and core.getElementMassById then
        local m = core.getElementMassById(id)
        if type(m) == "number" then return m end
    end
    return nil
end

-- Altitude above sea level of the nearest planet, metres; 0 in space.
function M.altitude()
    local core = adapter.core()
    if core and core.getAltitude then
        local a = core.getAltitude()
        if type(a) == "number" then return a end
    end
    return nil
end

return M
