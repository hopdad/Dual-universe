-- The game API calls the bus makes (system, unit, construct, core), in one place so the
-- tests can replace them. Each returns nil when the element or call is missing.

local M = {}

local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = v[1] or v.x, v[2] or v.y, v[3] or v.z
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then return { x, y, z } end
    return nil
end

function M.now()
    return system.getUtcTime()
end

function M.print(s)
    system.print(s)
end

function M.setTimer(tag, period)
    unit.setTimer(tag, period)
end

function M.stopTimer(tag)
    unit.stopTimer(tag)
end

function M.constructId()
    if construct and construct.getId then return math.tointeger(construct.getId()) end
    return nil
end

-- World position of the construct, metres.
function M.position()
    if construct and construct.getWorldPosition then return vec(construct.getWorldPosition()) end
    return nil
end

-- World velocity relative to the parent body, m/s.
function M.velocity()
    if construct and construct.getWorldVelocity then return vec(construct.getWorldVelocity()) end
    return nil
end

-- Altitude above sea level of the nearest planet, metres; 0 in space.
function M.altitude()
    if core and core.getAltitude then
        local a = core.getAltitude()
        if type(a) == "number" then return a end
    end
    return nil
end

return M
