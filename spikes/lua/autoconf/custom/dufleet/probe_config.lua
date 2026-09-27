-- Settings for the dufleet probe. Edit before a session, or change most of
-- them in game with /b commands (type "/b help" in the Lua chat tab).
return {
    tick = 0.25,        -- seconds between probe ticks (its own "dub" timer)

    print_every = 2,    -- S0: seconds between heartbeat lines in Lua chat (0 = off)
    print_for = 300,    -- S0: stop heartbeat lines after this many seconds

    inbox_every = 0.5,  -- S11: seconds between inbox reads (0 = off)

    frame = false,      -- S1: show the optical test frame at start
    frame_fps = 2,      -- S1: new frames per second: 1, 2 or 4
    frame_bits = 2,     -- S1: bits per cell: 2 (four colours) or 1 (black and green)
    frame_cell = 6,     -- S1: cell size in HUD pixels
    frame_x = 20,       -- S1: frame position (top-left corner) in HUD pixels
    frame_y = 200,

    panel = true,       -- status panel with the results of every probe
    panel_x = 20,
    panel_y = 420,
}
