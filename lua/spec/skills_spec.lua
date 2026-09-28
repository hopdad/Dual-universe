-- The skills registry's examples (packages/protocol/skills.json) through each skill's own check:
-- the bus must take exactly the arguments the registry's schema takes (companion/tests/test_skills_registry.py).
local json = require("dkjson")

local f = assert(io.open("../packages/protocol/skills.json"))
local registry = json.decode(f:read("a"))
f:close()

-- ArchHUD ready and idle, the body known, fuel not checked.
local ENV = {
    ah = {
        setupComplete = function() return true end,
        busy = function() return nil end,
        worldFromMap = function() return { 1, 2, 3 }, { 0, 0, 0 } end,
        inAtmosphere = function() return true end,
        body = function() return nil end,
    },
    now = function() return 0 end,
}

-- key=value tokens carry text.
local function tokens(args)
    local out = {}
    for k, v in pairs(args) do out[k] = type(v) == "number" and tostring(v) or v end
    return out
end

describe("skills registry examples", function()
    for name, skill in pairs(registry) do
        if name:sub(1, 1) ~= "$" then
            local check = require("autoconf/custom/dufleet/skills/" .. name).check
            it(name .. " takes the valid ones", function()
                for _, args in ipairs(skill.examples.valid) do
                    local cfg, code, msg = check(tokens(args), ENV)
                    assert.is_table(cfg, json.encode(args) .. ": " .. tostring(code) .. " " .. tostring(msg))
                end
            end)
            it(name .. " refuses the invalid ones with E_ARGS", function()
                for _, args in ipairs(skill.examples.invalid) do
                    local cfg, code = check(tokens(args), ENV)
                    assert.are.same({ nil, "E_ARGS" }, { cfg, code }, json.encode(args))
                end
            end)
        end
    end
end)
