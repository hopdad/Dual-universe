std = "lua53"
max_line_length = 120
exclude_files = { ".deps/**", "autoconf/custom/dufleet/protocol_gen.lua" }

-- The game and ArchHUD define these; the bus reads them.
read_globals = { "system", "unit", "construct", "core" }

files["autoconf/custom/archhud/userclass.lua"] = {
    globals = { "userBase" },
}

files["spec"] = {
    std = "+busted",
    globals = { "system", "unit", "construct", "core", "dbHud_1", "PROGRAM", "VERSION_NUMBER", "AutopilotStatus",
        "Autopilot", "AltitudeHold", "BrakeIsOn", "SetupComplete", "userBase", "userScreen" },
}

files["tools/simulate.lua"] = {
    read_globals = { "userBase" },
}
