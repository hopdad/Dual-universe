-- The adapter's goto calls against ArchHUD's real atlas and autopilot code (spec/helpers/real_archhud.lua),
-- to check what fake_archhud assumes. Pending unless tools/deps.sh has fetched ArchHUD.
local real = require("real_archhud")

local function near(a, b, eps)
    return math.abs(a - b) < (eps or 1e-6)
end

local function adapter()
    return require("autoconf/custom/dufleet/archhud_adapter")
end

local function names()
    local out = {}
    for _, e in ipairs(_G.AtlasOrdered) do out[#out + 1] = e.name end
    return out
end

local function count(list, value)
    local n = 0
    for _, v in ipairs(list) do
        if v == value then n = n + 1 end
    end
    return n
end

local describeIf = real.available() and describe or pending

describeIf("the ArchHUD adapter against ArchHUD 2.105", function()
    it("converts positions exactly as ArchHUD converts map positions", function()
        real.install()
        for _, p in ipairs({ { 35.3951, 104.1187, 285.5413 }, { -60, 300, 1000 }, { 0, 0, -50 } }) do
            local w = adapter().worldFromMap(0, 2, p[1], p[2], p[3])
            local mapPosition = _G.PlanetaryReference.MapPosition(0, 2, p[1], p[2], p[3])
            local theirs = _G.sys[2]:convertToWorldCoordinates(mapPosition)
            assert.is_true(near(w[1], theirs.x, 1e-3) and near(w[2], theirs.y, 1e-3) and near(w[3], theirs.z, 1e-3))
        end
        assert.are.same({ 1, 2, 3 }, adapter().worldFromMap(0, 0, 1, 2, 3))
        assert.is_nil((adapter().worldFromMap(0, 999, 1, 2, 3)))
    end)

    it("cannot parse ::pos strings through galaxyReference, so the bus converts positions itself", function()
        real.install()
        -- atlasclass.lua:131 calls a global stringmatch that ArchHUD only defines as a local (baseclass.lua:15).
        assert.has_error(function() _G.sys:convertToBodyIdAndWorldCoordinates("::pos{0,2,1,2,3}") end)
    end)

    it("ArchHUD alone selects the location that sorts first, not the new one", function()
        real.install()
        local w = adapter().worldFromMap(0, 2, 10, 20, 300)
        _G.ATLAS.AddNewLocation("dub-j_1", _G.vec3(w[1], w[2], w[3]), true)
        assert.are.equal(1, _G.AutopilotTargetIndex)
        assert.are.not_equal("dub-j_1", _G.AutopilotTargetName)
        assert.is_nil(_G.CustomTarget) -- a planet sorts first here
    end)

    it("selects the bus's own location, once", function()
        real.install()
        local w = adapter().worldFromMap(0, 2, 10, 20, 300)
        local ok, planetname = adapter().selectTarget("dub-j_1", w)
        assert.are.same({ true, "Alioth" }, { ok, planetname })
        assert.are.equal("dub-j_1", _G.CustomTarget.name)
        assert.are.equal("dub-j_1", _G.AutopilotTargetName)
        assert.are.equal("Alioth", _G.autopilotTargetPlanet.name)
        local c = _G.AutopilotTargetCoords
        assert.is_true(near(c.x, w[1]) and near(c.y, w[2]) and near(c.z, w[3]))
        assert.is_true(adapter().selectTarget("dub-j_1", w))
        assert.are.equal(1, count(names(), "dub-j_1"))
        local w2 = adapter().worldFromMap(0, 2, 11, 20, 300)
        assert.are.same({ true, "Alioth" }, { adapter().selectTarget("dub-j_1", w2) })
        assert.are.equal("dub-j_1-2", _G.CustomTarget.name)
    end)

    it("classes a target beyond the atmosphere as Space", function()
        real.install()
        local w = adapter().worldFromMap(0, 2, 10, 20, 500000)
        assert.are.same({ true, "Space" }, { adapter().selectTarget("dub-j_1", w) })
    end)

    it("on the ground, ArchHUD's own toggle starts an auto takeoff that holds the brake", function()
        local h = real.install({ at = "ground" })
        adapter().selectTarget("dub-j_1", adapter().worldFromMap(0, 2, 10, 20, 300))
        _G.AP.ToggleAutopilot()
        assert.is_true(_G.VectorToTarget and _G.AltitudeHold and _G.AutoTakeoff)
        assert.are.equal("ATO Hold", _G.BrakeIsOn) -- held until the pilot throttles up and releases it
        assert.is_not.equal(1, h.throttle)
    end)

    it("engages from the ground and releases that hold as a pilot would", function()
        local h = real.install({ at = "ground" })
        adapter().selectTarget("dub-j_1", adapter().worldFromMap(0, 2, 10, 20, 300))
        assert.are.equal("VectorToTarget", adapter().engage(h.clock))
        assert.is_true(_G.AltitudeHold)
        assert.is_true(_G.AutoTakeoff) -- the takeoff is still on
        assert.is_false(_G.BrakeIsOn) -- the brake is released
        assert.are.equal(1, h.throttle) -- and the throttle is up
        assert.is_false(_G.Autopilot)
    end)

    it("aims AutopilotSpaceDistance short of a custom target in space, so goto counts from there", function()
        local f = assert(io.open(real.DIR .. "src/requires/apclass.lua"))
        local src = f:read("a")
        f:close()
        assert.truthy(src:find("targetCoords = CustomTarget.position + (worldPos - CustomTarget.position)"
            .. ":normalize()*AutopilotSpaceDistance", 1, true))
        real.install({ at = "space" })
        assert.are.equal(5000, adapter().spaceStopDistance()) -- ArchHUD.conf's default
        _G.AutopilotSpaceDistance = 1500
        assert.are.equal(1500, adapter().spaceStopDistance())
    end)

    it("engages from the air with no takeoff, and throttles up", function()
        local h = real.install({ at = "ground" })
        _G.abvGndDet, _G.PlayerThrottle = -1, 0 -- no ground in sight, throttle at 0 after a cancel
        adapter().selectTarget("dub-j_1", adapter().worldFromMap(0, 2, 10, 20, 300))
        assert.are.equal("VectorToTarget", adapter().engage(h.clock))
        assert.is_false(_G.AutoTakeoff)
        assert.are.equal(1, h.throttle)
    end)

    it("engages the autopilot in space", function()
        local h = real.install({ at = "space" })
        local p = h.construct.position
        adapter().selectTarget("dub-j_1", { p[1] + 50000, p[2], p[3] })
        assert.are.equal("Autopilot", adapter().engage(h.clock))
        assert.is_false(_G.VectorToTarget)
    end)

    it("stops everything and sets the brake, leaving a set brake alone", function()
        local h = real.install({ at = "ground" })
        adapter().selectTarget("dub-j_1", adapter().worldFromMap(0, 2, 10, 20, 300))
        adapter().engage(h.clock)
        assert.is_true(adapter().stop())
        assert.is_nil(adapter().travelling())
        assert.is_false(_G.AltitudeHold)
        assert.is_true(_G.BrakeIsOn)
        assert.are.equal(0, h.throttle)
        _G.BrakeIsOn = "BL Complete"
        adapter().stop()
        assert.are.equal("BL Complete", _G.BrakeIsOn) -- a string brake stays set: BrakeToggle would release it
    end)

    it("would fly a loaded route instead, so the adapter refuses", function()
        local h = real.install({ at = "space" })
        local p = h.construct.position
        adapter().selectTarget("home", { p[1] - 50000, p[2], p[3] })
        _G.apRoute = { "home" } -- a route holds custom locations (AP.routeWP)
        adapter().selectTarget("dub-j_1", { p[1] + 50000, p[2], p[3] })
        assert.are.equal("an ArchHUD route is loaded", adapter().busy())
        assert.is_nil((adapter().engage(h.clock)))
        _G.AP.ToggleAutopilot() -- what the bus avoids
        assert.are.equal("home", _G.CustomTarget.name)
    end)

    it("reads a quick second toggle in atmosphere as an orbital hop", function()
        local h = real.install({ at = "ground" })
        adapter().selectTarget("dub-j_1", adapter().worldFromMap(0, 2, 10, 20, 300))
        _G.AP.ToggleAutopilot()
        _G.time = h.clock + 1
        _G.AP.ToggleAutopilot()
        assert.is_true(_G.VectorToTarget) -- the second toggle did not turn it off: it set a hop altitude
        assert.are.equal(_G.planet.noAtmosphericDensityAltitude + _G.LowOrbitHeight, _G.HoldAltitude)
    end)
end)

-- Files loaded with require cannot see the handler slots (system, unit, core, dbHud_1), so the
-- bus reaches them through what ArchHUD's start does with them (docs/verification.md, "Addendum:
-- in game"). These read the pinned source, since real_archhud calls the constructors itself.
describeIf("what the bus relies on in ArchHUD 2.105's start", function()
    local function source(path)
        local f = assert(io.open(real.DIR .. path))
        local s = f:read("a")
        f:close()
        return s
    end

    it("builds the global Nav from the system, the core and the unit", function()
        assert.truthy(source("src/ArchHUD.lua"):find("Nav = Navigator.new(system, core, unit)", 1, true))
    end)

    it("passes the databank to AtlasClass as argument 5 and to APClass as argument 9", function()
        local base = source("src/requires/baseclass.lua")
        assert.truthy(base:find("ATLAS = AtlasClass(Nav, c, u, s, dbHud_1,", 1, true))
        assert.truthy(base:find("AP = APClass(Nav, c, u, atlas, vBooster, hover, telemeter_1, antigrav, dbHud_1,", 1,
            true))
    end)

    it("builds both classes in its setup before it calls ExtraOnStart", function()
        local base = source("src/requires/baseclass.lua")
        local setup = base:find("beginSetup = coroutine.create", 1, true)
        assert.truthy(setup)
        local ap = base:find("AP = APClass(", setup, true)
        local atlas = base:find("atlasSetup()", setup, true) -- atlasSetup builds ATLAS
        local extra = base:find("PROGRAM.ExtraOnStart()", setup, true)
        assert.truthy(ap and atlas and extra)
        assert.is_true(ap < extra and atlas < extra)
    end)
end)
