-- goto: fly to a position with ArchHUD's autopilot, as a pilot would with a ::pos
-- waypoint and one autopilot toggle (docs/protocol.md, "Skills").
--
--   run goto <job> pos=<systemId>,<bodyId>,<lat>,<lon>,<alt> [tol=<m>] [timeout=<s>]
--
-- Body 0 is deep space: lat, lon and alt are then world x, y and z, as in ::pos.
--
-- Phases:
--   engage  select the target (location "dub-<job>") and toggle the autopilot once,
--           no sooner than 2 s after the bus's last toggle
--   travel  a travel mode is set: ArchHUD is flying, launching, orbiting or landing
--   settle  no travel mode. Done once the ship has stayed under 1 km/h for 5 s within tol
--           of the target; failed if it stopped further away, or is still moving after 30 s
--
-- On a planet ArchHUD lands under the target, so the distance there is horizontal. In
-- space it brakes to a stop near the target ("Space Arrival"), so the distance is straight.
-- The default tolerances, 50 m on a planet and 1000 m in space, stand until A1 measures
-- ArchHUD's precision. timeout (3600 s by default) counts running time, not pauses.
-- Cancel, pause, a timeout and a failed arrival all stop the autopilot and set the brake.
--
-- A goto does not start (E_FUEL) when a fuel type the trip needs is under dub.cfg.minfuel
-- (10% by default): atmo fuel while in atmosphere, space fuel in space or for a target on
-- another body or in deep space. Types the ship has no tanks for are not checked.

local M = { phase = "engage" }

M.TOL_PLANET, M.TOL_SPACE = 50, 1000
M.SETTLE_KMH, M.SETTLE_S, M.DISENGAGED_S = 1, 5, 30

local KEYS = { pos = true, tol = true, timeout = true }

local function round1(x)
    return math.floor(x * 10 + 0.5) / 10
end

-- A number in [lo, hi] from text, or nil and a message.
local function number(text, name, lo, hi)
    local n = tonumber(text)
    if not n or n ~= n or n < lo or n > hi then
        return nil, string.format("%s must be a number from %s to %s", name, lo, hi)
    end
    return n
end

local function parsePos(text)
    local fields = {}
    for field in (text .. ","):gmatch("([^,]*),") do fields[#fields + 1] = field end
    if #fields ~= 5 then return nil, "pos needs systemId,bodyId,lat,lon,alt" end
    for i, field in ipairs(fields) do
        local n = tonumber(field)
        if not n or n ~= n or n == math.huge or n == -math.huge then return nil, "pos needs 5 finite numbers" end
        fields[i] = n
    end
    local systemId, bodyId = math.tointeger(fields[1]), math.tointeger(fields[2])
    if not systemId or not bodyId or systemId < 0 or bodyId < 0 then
        return nil, "pos needs whole systemId and bodyId"
    end
    if bodyId ~= 0 and (fields[3] < -90 or fields[3] > 90) then return nil, "pos latitude is out of range" end
    return { systemId, bodyId, fields[3], fields[4], fields[5] }
end

-- The first fuel type the trip needs that is under env.minFuel, as a message, or nil.
local function lowFuel(env, bodyId)
    local min = env.minFuel or 0
    local fuel = min > 0 and env.fuel and env.fuel()
    if not fuel then return nil end
    local inAtmo, here = env.ah.inAtmosphere(), env.ah.body()
    local needs = {}
    if inAtmo then needs[#needs + 1] = "atmo" end
    if not inAtmo or bodyId == 0 or (here and here.id ~= bodyId) then needs[#needs + 1] = "space" end
    for _, kind in ipairs(needs) do
        if fuel[kind] and fuel[kind] < min then
            return string.format("%s fuel %d%%, under the %d%% minimum", kind, math.floor(fuel[kind] * 100 + 0.5),
                math.floor(min * 100 + 0.5))
        end
    end
    return nil
end

function M.check(params, env)
    for k in pairs(params) do
        if not KEYS[k] then return nil, "E_ARGS", "unknown parameter " .. k end
    end
    if not params.pos then return nil, "E_ARGS", "missing pos" end
    local pos, err = parsePos(params.pos)
    if not pos then return nil, "E_ARGS", err end
    local tol, timeout
    if params.tol then
        tol, err = number(params.tol, "tol", 1, 100000)
        if not tol then return nil, "E_ARGS", err end
    end
    timeout, err = number(params.timeout or "3600", "timeout", 10, 86400)
    if not timeout then return nil, "E_ARGS", err end

    if not env.ah.setupComplete() then return nil, "E_STATE", "ArchHUD is still starting" end
    local busy = env.ah.busy()
    if busy then return nil, "E_STATE", busy end
    local world, center = env.ah.worldFromMap(table.unpack(pos))
    if not world then return nil, "E_STATE", center end
    local low = lowFuel(env, pos[2])
    if low then return nil, "E_FUEL", low end
    return { world = world, center = pos[2] ~= 0 and center or nil, tol = tol, timeout = timeout }
end

-- Distance from p to the target: horizontal on a planet, straight in space.
local function distance(cfg, p)
    local w = cfg.world
    local d = { p[1] - w[1], p[2] - w[2], p[3] - w[3] }
    if not cfg.space then
        local c = cfg.center
        local u = { w[1] - c[1], w[2] - c[2], w[3] - c[3] }
        local len = math.sqrt(u[1] * u[1] + u[2] * u[2] + u[3] * u[3])
        if len > 0 then
            local along = (d[1] * u[1] + d[2] * u[2] + d[3] * u[3]) / len
            d = { d[1] - along * u[1] / len, d[2] - along * u[2] / len, d[3] - along * u[3] / len }
        end
    end
    return math.sqrt(d[1] * d[1] + d[2] * d[2] + d[3] * d[3])
end

local function engage(job, env, now)
    if not env.ah.canToggle(now) then return nil end
    local cfg = job.cfg
    local ok, planetname = env.ah.selectTarget("dub-" .. job.id, cfg.world)
    if not ok then return false, "E_STATE", planetname end
    cfg.space = cfg.center == nil or planetname == "Space"
    local mode, err = env.ah.engage(now)
    if not mode then return false, "E_STATE", err end
    job.phase = "travel"
    return nil
end

function M.step(job, env, now)
    local cfg = job.cfg
    if job.active > cfg.timeout then
        env.ah.stop()
        return false, "E_STATE", string.format("timed out after %d s", math.floor(cfg.timeout))
    end
    if job.phase == "engage" then return engage(job, env, now) end
    if env.ah.travelling() then
        job.phase, job.still = "travel", nil
        return nil
    end
    if job.phase ~= "settle" then
        job.phase, job.idle, job.still = "settle", now, nil
    end
    local p = env.position()
    if not p then return false, "E_INTERNAL", "no construct position" end
    local dist = distance(cfg, p)
    local speed = env.speed()
    if speed and speed * 3.6 < M.SETTLE_KMH then
        job.still = job.still or now
        if now - job.still < M.SETTLE_S then return nil end
        local data = { dist = round1(dist), t = math.floor(job.active + 0.5) }
        if dist <= (cfg.tol or (cfg.space and M.TOL_SPACE or M.TOL_PLANET)) then return true, data end
        env.ah.stop()
        return false, "E_STATE", string.format("stopped %d m from the target", math.floor(dist + 0.5)), data
    end
    job.still = nil
    if now - job.idle >= M.DISENGAGED_S then
        env.ah.stop()
        return false, "E_STATE", string.format("autopilot off and still moving, %d m from the target",
            math.floor(dist + 0.5)), { dist = round1(dist) }
    end
    return nil
end

function M.stop(_, env)
    return env.ah.stop()
end

function M.resume()
    return M.phase
end

return M
