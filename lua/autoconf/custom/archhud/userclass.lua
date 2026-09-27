-- dufleet bus shim for ArchHUD (The-Third-Verse/ArchHUD 2.105, modular build, commit 6c95222).
--
-- ArchHUD requires this file after its own classes and copies every userBase function
-- into its program class. It then calls all four ExtraOn* functions without checking
-- that they exist, so all four are defined here. The bus works on its own timer and
-- does nothing in onUpdate or onFlush.

local ok, bus = pcall(require, "autoconf/custom/dufleet/bus")
if not ok then
    system.print("dufleet: bus failed to load: " .. tostring(bus))
    bus = nil
end

userBase = {}

function userBase.ExtraOnStart()
    if bus then bus.start() end
end

function userBase.ExtraOnStop()
    if bus then bus.stop() end
end

function userBase.ExtraOnUpdate() end

function userBase.ExtraOnFlush() end
