-- dufleet bus shim for ArchHUD (The-Third-Verse/ArchHUD 2.105, modular build, commit 6c95222).
--
-- ArchHUD requires this file after its own classes and copies every userBase function
-- into its program class. It then calls all four ExtraOn* functions without checking
-- that they exist, so all four are defined here. The bus works on its own timer and
-- does nothing in onUpdate or onFlush.
--
-- ExtraOnStart runs inside ArchHUD's setup coroutine, so an error escaping it would end
-- ArchHUD's setup. Every hook runs under pcall. Files loaded with require do not see the
-- handler slot `system`; this one prints through DUSystem, as ArchHUD's classes do.

local function say(line)
    if DUSystem then pcall(DUSystem.print, line) end
end

local ok, bus = pcall(require, "autoconf/custom/dufleet/bus")
if not ok then
    say("dufleet: bus failed to load: " .. tostring(bus))
    bus = nil
end

local errors = 0
local function call(name)
    if not bus then return end
    local okCall, err = pcall(bus[name])
    if not okCall then
        errors = errors + 1
        if errors <= 5 then say("dufleet: bus error (" .. name .. "): " .. tostring(err)) end
    end
end

call("attach") -- now, before ArchHUD's setup builds its classes

userBase = {}

function userBase.ExtraOnStart() call("start") end

function userBase.ExtraOnStop() call("stop") end

function userBase.ExtraOnUpdate() end

function userBase.ExtraOnFlush() end
