# ArchHUD's user manual: notes for the bot

Read in full on 2026-09-29, from the owner's copy of the *ArchHUD User's Manual* (version 2.102+). The manual describes what a pilot sees; the pinned source (The-Third-Verse/ArchHUD at `6c95222`) decides what the bus relies on. Each note says whether the source was checked.

## Acted on

| The manual says | The source | What the bus does |
|---|---|---|
| From the ground, Alt-4 "will lift off ground and ask you to throttle up and release brakes (this is to ensure it is safe to commence)" | Checked: altitude hold starts an auto takeoff that holds the brake, `BrakeIsOn = "ATO Hold"` (`apclass.lua:721-747`) | `engage` throttles up and releases the hold, as the pilot would (2026-09-28) |
| In the air, ArchHUD "waits for pilot throttle up" (AGG scenario 3) | Checked: vector to target releases the brake itself on each tick unless it is taking off (`apclass.lua:2490-2491`); nothing throttles up | `engage` throttles up when the throttle is at 0, as a `cancel` or `pause` leaves it |
| In space, Alt-4 stops `AutopilotSpaceDistance` (5000 m by default) from a waypoint | Checked: the autopilot aims that far short of a custom target, back toward the ship (`apclass.lua:1853`) | `goto` counts `tol` beyond that distance in space; before, every space trip would have failed |

## To consider

| The manual says | Why it matters for bots | Checked |
|---|---|---|
| "DO NOT TRY TO USE THE HUD TO AUTOPILOT TO A MOON SURFACE" | `goto` should refuse targets on moons and asteroids. The Third Verse's atlas marks each body Planet (12), Moon (13) or Asteroid (34) | The atlas types; the refusal is not built |
| Same-planet trips climb to ground height plus `AutoTakeoffAltitude` (1000 m by default) before they cruise; Alt-4-4 hops through low orbit | Why a 2 km trip looked odd in session 1. Short trips could use a lower `AutoTakeoffAltitude` | No |
| Brake landings hold drift under `allowedHorizontalDrift`; "landing accuracy (< 20m probably)" | Matches A1 (11.5 m, then 4.2 m). `TOL_PLANET` stays 50 m | — |
| `CollisionSystem` (on by default) brake-lands to avoid a collision during any autopilot; `PreventPvP` (on) stops before crossing into PvP space | A `goto` can end early, far from its target. The bus reports "stopped N m from the target"; saying why would help the planner | No |
| Radar "causes significant lag on ANY hud if attached and the radar widget is open" | Leave radar unlinked on bot ships | — |
| Do not use HUDs with the game's voxel rendering setting on Auto or the maximum number of threads | A setting for every bot PC | — |
| `LandingGearGroundHeight` should equal the AGL shown when landed, or the ship can bounce back up after landing | Set it on each bot ship | — |
| Fuel in tanks not linked to the seat is estimated from skill settings (`fuelTankHandling*`, `ContainerOptimization`, `FuelTankOptimization`) | `goto`'s fuel check reads ArchHUD's estimates: set these on bot ships, or link the tanks | — |
| Settings load from the `.conf`, then `userglobals.lua`, then the databank (unless `useTheseSettings`); standing up saves every value to the databank; `/G Name Value` changes one, `/G dump` lists them | The way to configure bot ships. `/iphWP` prints the selected target's `::pos`, useful for checks | — |
| ArchHUD on an emergency control unit keeps flying (`ECUHud`) or brake-lands when the pilot leaves the seat | A safety net for when a bot's client drops | — |
| Waypoints can keep a landing heading and an AGG altitude; one multipoint route (Alt-Shift-8) | For later skills: aligned landings at pads, haul routes | — |
| Alt-3 hides the HUD | It would hide the optical frame (ADR-0001) too: a bot must never toggle it | — |
