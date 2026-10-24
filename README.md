# OrganizeEntropy

A Delphi 12 (Win32) desktop app that reads the WoW **BagSync** addon's saved data,
stores every item across your characters, guild banks and the account-wide Warband
bank into a local **SQLite** database, and suggests how to consolidate partial
stacks to free up bag / bank / tab space.

It is a **single-user, offline, read-only** tool: it reads BagSync's data, analyses
it, and advises. You do the moving in-game.

## How it compares to bag addons (BagBrother / Bagnon)

Addons like **BagBrother** (the engine behind Bagnon/Bagnonium) are inventory
*viewers*: they show what each character owns, offline and in tooltips. OrganizeEntropy
reads the same cross-character inventory but is a *planner*: it works out how to merge
scattered partial stacks into as few slots as possible and tells you exactly what to
move. It is split into an in-game addon that *exports* data and this desktop program
that *computes* the plan - because an addon can only read data for the character you
are logged into; it cannot move items between your characters for you.

## What it does today

1. Reads BagSync **SavedVariables** (`BagSync.lua`) - every item across all
   characters, guilds and the Warband bank.
2. Imports item metadata (name, quality, stack size, bind type, bind category) from
   the bundled companion addon **OrganizeItemsThroughBagSyncExport**.
3. Stores everything in a local SQLite database (`OrganizeEntropy.db`, beside the exe).
4. Lets you pick which characters and guilds take part (Participation tab); the
   Warband is always included. A successful load jumps you straight there.
5. Computes consolidation opportunities (Consolidation tab): per item it shows the
   bind type, max stack, owners, totals, the minimum slots needed and how many you
   could save. Only items that can actually move are listed; click any column header
   to sort (ascending / descending / default). A detail panel lists the sources and
   concrete "Move N x Item FROM ... TO ..." steps you can copy.

One button does the heavy lifting: **"Do the magic!"** synchronises your inventory and
imports item data together.

The companion addon is **bundled inside the exe and deployed to your AddOns folder
automatically** at startup - you do not have to install it by hand.

## How moveability is decided

- **Free / BoE / BoU / Warbound / Account-Bound** -> moveable among your own
  characters. Items on different realms, or bound to the Warband, travel through the
  account-wide **Warband bank** (BoE/BoU become Soulbound once equipped/used).
- **BoP / Quest / Soulbound** -> bound to one character; such stacks are only merged
  within that character and are excluded from cross-character suggestions.

## Running a prebuilt build (no Delphi needed)

The release is a single standalone Win32 `.exe` (~20 MB). SQLite is compiled in and it
links **no** runtime BPLs, so a guild-mate can run it on any Windows 10/11 PC with no
Delphi, no `sqlite3.dll` and no extra DLLs. Run it from a writable folder (Desktop,
Documents) - it writes its database, INI and the deployed addon next to itself, which
would need admin rights under `Program Files`.

## Prerequisites (to build, or to feed it data)

- WoW with **BagSync** installed. The companion **OrganizeItemsThroughBagSyncExport**
  addon is bundled and auto-deployed (no manual copy).
- In-game: open bags / bank / guild bank / Warband bank, run `/cie export`, then `/reload`.
- To build: Delphi 12 (Community Edition is fine). FireDAC's SQLite driver ships with
  Delphi - no separate install.

## Still on the wish list

- Empty-slot move suggestions (BagSync records the items that exist, not free slots).
- Routing cross-character / cross-realm moves explicitly through the Warband bank in
  the suggested steps (currently in design).
- Multi-run diff (what moved / sold / was acquired between two imports).
- Auto-bumping the companion addon's `.toc` interface version after a patch.

## Licensing

This tool (and the bundled companion addon) is MIT-licensed (see `LICENSE`). It only
*reads* the data BagSync saves; it does not bundle or redistribute BagSync, which is
All Rights Reserved by Xruptor (https://github.com/Xruptor/BagSync). See `README_TOO`
for the full writeup.
