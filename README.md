# MotionTracker

An *Aliens* (1986)-inspired motion-tracker hunting compass for **Ashita v4**, built for **CatsEyeXI (CEXI)**.

MotionTracker is a fan adaptation of atom0s's original **`filterscan`** addon. filterscan's Wide Scan name/id filtering is still the core of how targets get matched here — none of this would exist without that base, so full credit to atom0s for it. Everything layered on top is new:

- Continuous scanning of the client's own nearby-entity memory, so mobs and NMs alert too — not just the static NPCs Wide Scan's own `npclist.dat` lookup can resolve.
- An animated, multi-target "motion tracker"-style radar popup compass, styled after the prop's dark screen and glowing cyan rings, with a sonar-style pulse expanding out from the center (trailing a soft afterglow) instead of a spinning sweep line.
- Blips that scale toward the center as a target gets closer, colored amber/yellow for your 5 closest (labeled) contacts and blue for everything further out.
- Distance-based sound cues (a normal "found" alert, a "close" alert once inside a configurable range, and an "all clear" when the last target drops off).
- Diagnostic tooling (`scandebug`, `deathdebug`) built out to chase down false positives and false negatives caused by this server's lottery-pop NM mechanics.

This is an unofficial fan project made for personal/community use — not affiliated with, endorsed by, or sponsored by 20th Century Studios or the *Alien*/*Aliens* franchise. "Motion tracker" and the display styling here are just an homage.

## Install

1. Copy the `motiontracker` folder (this whole folder, including `lib\`) into your Ashita `addons\` directory, so you end up with `addons\motiontracker\motiontracker.lua`.
2. Load it in-game with `/addon load motiontracker`, or add `/addon load motiontracker` to your Ashita startup script/plugin list to load it automatically.
3. (Optional) Drop your own `.wav` files into `addons\motiontracker\sounds\` if you want to override the bundled alert sounds — see the `/mtalert sound` family of commands below.

### Important: works with `/filterscan` too, but check for the stock addon

MotionTracker aliases **both** `/motiontracker` and `/filterscan` to the same filter-setting command, so anyone used to typing `/filterscan <mob>` out of habit doesn't have to relearn anything.

However, if the **original, stock Ashita `filterscan` addon is also loaded**, it also owns `/filterscan` — and it will generally claim that command instead of MotionTracker. This isn't a bug in MotionTracker; it's just how Ashita resolves a command name that two loaded addons both register. If you've got the stock addon loaded and `/filterscan` doesn't seem to be doing anything (or the chat tag on the "Widescan filter set to:" line reads `[filterscan]` instead of `[motiontracker]`), that's the tell. Fix it with:

```
/addon unload filterscan
```

(and remove it from your startup script if you don't need it anymore). `/motiontracker` is unaffected either way, so it's the safest command to use if both addons might be loaded.

## Setting a filter

```
/motiontracker <name or id>[,<name or id>...]
/filterscan <name or id>[,<name or id>...]
```

Comma-separated list of any mix of:
- Mob/NPC name (or partial name), case-insensitive
- Target index, in hex (e.g. `0x2D`)
- Wide Scan list index
- Server ID (decimal) — matched against the client's own local entity memory only, since Wide Scan's packet doesn't carry a server ID. Useful on this server since a given pop point's Server ID is fixed and never changes, so once you know it you can filter on it directly.

Setting a new filter immediately clears whatever was previously tracked (compass blips, sound state) rather than waiting for the old targets to time out.

Run `/motiontracker` (or `/filterscan`) with no arguments to clear the filter.

## Alert settings — `/mtalert`

| Command | Effect |
|---|---|
| `/mtalert test` | Fire a test alert (sound + popup) |
| `/mtalert edit` | Keep the popup up; hold Shift and drag it to reposition |
| `/mtalert toggle` | Enable/disable sound *and* popup together |
| `/mtalert togglesound` | Enable/disable sound only |
| `/mtalert togglepopup` | Enable/disable the popup compass only |
| `/mtalert localscan` | Toggle scanning nearby entity memory (catches mobs/NMs, not just Wide Scan NPCs) |
| `/mtalert idle` | Toggle keeping the compass up (animated) even with nothing tracked |
| `/mtalert sound <file>` | Set the "found" alert `.wav` (in `addon\sounds\`) |
| `/mtalert soundnear <file>` | Set the "close" alert `.wav` (within the near distance) |
| `/mtalert soundidle <file>` | Set the "all clear" `.wav` (plays when the last target drops off) |
| `/mtalert near <yalms>` | Set the "close" distance threshold |
| `/mtalert range <yalms>` | Distance at which a blip sits on the ring edge; closer targets draw nearer the center |
| `/mtalert duration <secs>` | How long the popup stays up per alert |
| `/mtalert move <x> <y>` | Reposition the popup |
| `/mtalert size <radius>` | Resize the popup |

A couple of debug commands (`scandebug`, `deathdebug`) are also still fully functional but left out of the in-game `/mtalert` listing so they don't clutter it for everyday use — see below.

## Debug commands

These stay in the addon and work exactly as before; they're just hidden from the plain `/mtalert` help listing.

- **`/mtalert scandebug`** — for every local-scan slot whose name/id matches your filter, prints a diagnostic line (name, target index, server id, HP%, actor pointer, render flags, status, spawn flags, position, distance and vertical offset from you) to your normal chat log, *before* the status/HP gating is applied. This is the tool to reach for if something isn't detecting, or is detecting a phantom that shouldn't be there.
- **`/mtalert deathdebug`** — logs death-message handling, useful for chasing "still shows as tracked after a kill" issues.

## A note on this server's pop mechanics

CatsEyeXI hands out a **fixed, permanent Server ID per pop point** rather than a fresh one per spawn — the same pop point's Server ID doesn't change between kills. MotionTracker's local-scan death-tracking accounts for this: a "dead" mark on a Server ID is cleared as soon as HP > 0 is seen for it again, rather than waiting for the entity to fully leave the client's local entity table (which, on this server, it may never actually do if the next spawn reuses the same ID). Without this, a pop point could get permanently blacklisted after its first kill.

## Credits / License

- Original `filterscan` addon and its Wide Scan filtering logic: **atom0s** (Ashita Development Team).
- Everything else (local-memory scanning, the animated popup compass, sound cues, diagnostics, and this whole "motion tracker" concept): this fan adaptation.

`filterscan` was originally released under the GPLv3, and this addon is derived from it, so the full GPLv3 text is included as `LICENSE` in this package to keep that chain of attribution intact — the addon's own source header keeps a friendlier, in-universe credit to atom0s instead of the full legal boilerplate, but the license terms still apply to the whole work.

Developed for and tested on **CatsEyeXI (CEXI)**.
