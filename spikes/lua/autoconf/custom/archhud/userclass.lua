-- dufleet probe shim for ArchHUD (The-Third-Verse/ArchHUD 2.105, modular build).
--
-- ArchHUD requires this file after its own classes and copies every userBase
-- function into its program class. It then calls all four ExtraOn* functions
-- without checking that they exist, so all four must be defined here even when
-- they do nothing. Remove this file (or run `dufleet-probe install
-- --uninstall-probe`) to return ArchHUD to stock behaviour.

local ok, probe = pcall(require, "autoconf/custom/dufleet/probe")
if not ok then
    system.print("dufleet: probe failed to load: " .. tostring(probe))
    probe = nil
end

userBase = {}

function userBase.ExtraOnStart()
    if probe then probe.start() end
end

function userBase.ExtraOnStop()
    if probe then probe.stop() end
end

function userBase.ExtraOnUpdate()
    if probe then probe.onUpdate() end
end

function userBase.ExtraOnFlush()
    if probe then probe.onFlush() end
end
