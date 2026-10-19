# Dead Signal Speedrun — Release history

## v0.9 — Pre-release

- Adds a fourth **Speedrun** card to the New Game difficulty menu, launching Casual mode.
- Starts RTA and estimated IGT at **Begin Shift**. RTA updates continuously; IGT displays its accumulated value at pause/loading checkpoints.
- Gold stopwatch card, compact native-style HUD, and 1px black timer outline.
- Includes restart-safety improvements and refreshes the native font when the title screen is rebuilt.
- Uses the exact Lua script and stopwatch image tested in v1.0 RC2; v0.9 is a release-label change, not a new gameplay patch.

### Outstanding verification

- The stop trigger at the **successful end-of-run fade** has not been verified with a completed run.
- Font consistency after an **actual death and restart** still needs more testing. Regular returns to the main menu have been tested.
- IGT is an estimate and is not an officially approved leaderboard timing method.

## Previous private builds

- **v1.0 RC2:** Font-cache refresh for repeated menu visits.
- **v1.0 RC1:** Automatic start detection, restart safety, menu presentation, estimated IGT checkpoints, and timer readability improvements.
