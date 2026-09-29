std = "lua53"
max_line_length = 120
exclude_files = { ".deps/**", "autoconf/custom/dufleet/protocol_gen.lua" }

-- The game defines these for every file. The handler slots (system, unit, construct, core,
-- dbHud_1) are not listed: files loaded with require cannot see them.
read_globals = { "DUSystem", "DUConstruct" }

files["autoconf/custom/archhud/userclass.lua"] = {
    globals = { "userBase" },
}

files["spec"] = {
    std = "+busted",
    globals = { "system", "unit", "construct", "core", "dbHud_1", "DUSystem", "DUConstruct", "Nav", "AtlasClass",
        "APClass", "PROGRAM", "VERSION_NUMBER", "AutopilotStatus",
        "Autopilot", "AltitudeHold", "AutoTakeoff", "BrakeIsOn", "SetupComplete", "userBase", "userScreen", "planet",
        "TurnBurn",
        "VectorToTarget", "spaceLaunch", "IntoOrbit", "ATLAS", "AP", "AtlasOrdered", "AutopilotTargetIndex",
        "CustomTarget", "apRoute", "galaxyReference", "vec3", "inAtmo", "atmoTanks", "spaceTanks", "rocketTanks",
        "AutopilotSpaceDistance", "PlayerThrottle", "abvGndDet" },
}

files["tools/simulate.lua"] = {
    read_globals = { "userBase" },
}

-- Builds ArchHUD's global environment for its real classes, which dofile defines.
files["spec/helpers/real_archhud.lua"] = {
    allow_defined = true,
    ignore = { "131" }, -- globals only ArchHUD's code reads
    read_globals = { "PlanetRef", "Kinematics", "Keplers", "AtlasClass", "APClass", "globalDeclare" },
}
