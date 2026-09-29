-- dufleet probe shim for ArchHUD (The-Third-Verse/ArchHUD 2.105, modular build).
--
-- ArchHUD requires this file after its own classes and copies every userBase
-- function into its program class. It then calls all four ExtraOn* functions
-- without checking that they exist, so all four must be defined here even when
-- they do nothing. Each one runs the probe under pcall, so no probe error can reach
-- ArchHUD's own startup or flight code. Remove this file (or run `dufleet-probe
-- install --uninstall-probe`) to return ArchHUD to stock behaviour.
--
-- Files loaded with require do not see the handler slot `system`. ArchHUD's own
-- classes use DUSystem, and so does this file.

local function say(line)
    if DUSystem then pcall(DUSystem.print, line) end
end

local ok, probe = pcall(require, "autoconf/custom/dufleet/probe")
if not ok then
    say("dufleet: probe failed to load: " .. tostring(probe))
    probe = nil
end

local errors = 0
local function call(name)
    if not probe then return end
    local okCall, err = pcall(probe[name])
    if not okCall then
        errors = errors + 1
        if errors <= 5 then say("dufleet probe error (" .. name .. "): " .. tostring(err)) end
    end
end

userBase = {}

function userBase.ExtraOnStart() call("start") end

function userBase.ExtraOnStop() call("stop") end

function userBase.ExtraOnUpdate() call("onUpdate") end

function userBase.ExtraOnFlush() call("onFlush") end
