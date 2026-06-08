# 🎞️ The Projection Room

A sleek, modern web GUI for your movie log — a private screening-room aesthetic over the
same `movies.json` database driven by the `MovieTracker.ps1` CLI. The GUI and the CLI read and
write the **identical file** (preserving the embedded `_metadata` command reference and the
canonical field order), so they stay perfectly in sync.

No build step, no npm, no extra runtime — just **PowerShell 7 + a browser**, both of which ship
with / are free on Windows.

## ▶ Launch

**Double-click `Projection Room.cmd`.** It starts a tiny local server and opens the app in your
default browser automatically.

Prefer the terminal?

```powershell
pwsh -ExecutionPolicy Bypass -File .\MovieTrackerWeb.ps1
```

Options: `-Port 8080` (default `7777`, auto-increments if busy) · `-NoBrowser` (don't auto-open).

To **stop** the server: press `Ctrl+C` in its window, or click the ⏻ button in the app.

## ✨ Features

- **The Ledger** — a dashboard with at-a-glance stats (titles, hours in the dark, average
  rating, screenings this year), a rating-distribution chart, top genres, a watch-activity
  timeline, most-watched directors, and your latest screenings.
- **The Library** — a **poster wall** of genre-tinted typographic cards (real posters drop in
  automatically when available online), plus a dense, sortable **ledger** list view.
- **Live search & filters** — by title/director/genre/actor/studio/notes, status, genre, minimum
  rating, and decade; sort by added, watched, rating, title, year, or runtime.
- **Detail drawer** — full metadata, your notes, a screening-history timeline (re-watch aware),
  and one-click rate / mark-watched / edit / delete.
- **Add / edit** — with optional **iTunes metadata + poster lookup**, status & rating pickers,
  multi-date watch logging, and a first-time-vs-re-watch toggle.
- **Copy for LLM** — exports the token-minimized library plus the command reference to your
  clipboard (mirrors the CLI's `Copy-MovieDbToClipboard`).
- **Keyboard shortcuts** — `/` search · `n` new · `d` ledger · `l` library · `g` toggle wall/list
  · `r` surprise me · `Esc` close.

## 🔌 Offline & online

The app is fully functional and good-looking **offline** — posters and metadata from iTunes are
an optional enhancement. If the iTunes API is unreachable, titles simply render as elegant
typographic posters and you can enter metadata by hand. Fetched posters are cached locally under
`.cache/` so they load instantly next time.

## 🗂️ Files

| File | Purpose |
|------|---------|
| `Projection Room.cmd` | One-click launcher (double-click this) |
| `MovieTrackerWeb.ps1` | Local web server + launcher |
| `web/` | The single-page app (`index.html`, `styles.css`, `app.js`) |
| `MovieTracker.ps1` | The original CLI engine (unchanged) |
| `movies.json` | The shared data store |
