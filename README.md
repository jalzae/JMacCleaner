# JMacCleaner

Tiny macOS SwiftUI app to see and kill unnecessary background processes — stray
`node` daemons, orphaned Electron helpers, dev servers — with a per-process
kill and a one-button **Kill All Junk**. Root-owned processes trigger the
native macOS administrator password prompt (one prompt per batch); the app
itself never runs as root.

## Build & run

```bash
swift run -c debug          # quick dev run (bare executable)
Scripts/make_app.sh         # build release + assemble build/JMacCleaner.app
open build/JMacCleaner.app  # double-clickable app with dock presence
```

## Use

- Main table: PID, name, CPU, memory, **port**, user, path. Sort by any column,
  filter with the search field (search matches ports too — type `3000` to find
  the dev server). Auto-refreshes every 2 s (pause with ⌘E).
- Port column: listening TCP ports via `lsof`, refreshed each tick. Orange = has
  listeners. Works for other users' processes too (postgres on 5432, root
  servers).
- Trash icon = flagged junk (red = kill-all eligible, orange = cautious).
  Shield icon = protected; kill buttons are disabled with the reason shown.
- Click **Kill All Junk** → confirm sheet splits the list into "stopped
  directly" and "need your password" → one admin prompt covers all root kills.
- Double-click any row (or context menu → Inspect) for the detail inspector.

## Safety model

Kill buttons never trust the UI list:

1. `ProcessSafety` re-checks at kill time: zombies, this app + its ancestors,
   essential macOS processes, signed system paths (`/System/`, `/usr/libexec/`,
   `/sbin/`, …), and session hosts (Terminal, VS Code, shells, `claude`) —
   including **anything descended from a session host**, which is why Claude
   Code running on `node` is never flagged.
2. Junk is allowlist-only: a process is junk because a positive rule matched
   (dev daemon names, orphaned Electron helpers, known dev tools). Essential
   apps are excluded structurally, not by enumeration.
3. Batch kills re-sample fresh, re-classify, and intersect with the requested
   pids before signaling (protects against pid reuse).

Cautious tier: redis, mongod, postgres, ngrok… are visible as junk but excluded
from Kill All unless "Include cautious junk" is enabled.

## Tests

```bash
swift test
```

Covers: dev-daemon junk classification, orphaned vs. live Electron helpers,
Claude-in-Terminal protection, caution-tier opt-in, every protected system
name, system path prefixes, zombie guard, ancestor-chain walks (incl. cycles),
pid-reuse CPU reset, rate arithmetic.
