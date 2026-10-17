# Pomodoro

A minimal menu bar timer and timesheet for macOS: a live countdown (or
count-up) in the menu bar, a dropdown with a scrubbable slider and presets, a
floating always-on-top clock, and a weekly timesheet of where your time went.

## Run it

```sh
make run        # build + launch build/Pomodoro.app
make install    # build + copy to /Applications (needed for "Launch at login")
```

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).
Full Xcode is **not** needed. The build calls `swiftc` directly via
`scripts/swiftc.sh`, which also works around a Command Line Tools 16.x bug
("redefinition of module 'SwiftBridging'") that breaks SwiftPM on this machine.

Other targets: `make debug`, `make icon` (regenerate the app icon),
`make snapshots` (render every window to `.context/snapshots/*.png`),
`make uninstall`, `make clean`.

## How it works

| Piece | What it does |
|---|---|
| **Menu bar timer** | Shows the time in an outlined box. Dim when idle/paused, bright while running. Click to open the panel, ⌥-click to start/pause, right-click for a quick menu. |
| **Timer panel** | Type a one-line description of what you're doing, then drag the tick slider (0–120 min by default) or tap a preset. `start` counts down, `count up` runs a stopwatch for tasks of unknown length; `pause` / `resume` / `stop` while running. `…` → save current time as a preset, Timesheet, Settings, Quit. Right-click a preset to remove it. |
| **Floating timer** | Black pill that floats above all windows and Spaces. Drag to move (position is remembered), double-click to pause/resume, hover → × to close. Pulses when time's up. |
| **Timesheet** | Every session is logged with its task and real running time (pauses excluded). Opens on today: a timeline of the day (one row per task), that day's log, then the week's chart by day and task × day grid. Edit, delete or add entries; overnight hours are collapsed. Export a week (or everything) as CSV. Right-click a task to rename or merge it. |
| **Settings** | Edit presets; choose what clicking the menu bar or a preset does; menu bar style/format; floating timer size, opacity, when it appears; completion sound and notification; launch at login. |

## Keyboard

Everything works without the mouse. Press `?` or `⌘/` anywhere in the app (or click ⌨ in the timesheet) to see every shortcut.

**Global shortcuts** (from any app; change them in Settings → Keyboard):
`⌃⌥P` timer panel · `⌃⌥S` start/pause · `⌃⌥U` count up · `⌃⌥X` stop & log ·
`⌃⌥T` timesheet · `⌃⌥F` floating timer.

**Timer panel:** the task field is focused when it opens. Type, then `↩` to
count down or `⌘↩` to count up. As you type, past tasks that match drop down
below, most-used and most-recent first: `↓`/`↑` to pick one, `↩` or `⇥` to take
it, `esc` to hide the list. With no suggestions showing, `↑`/`↓` cycle recent
tasks and `⇥` leaves/returns to the field. Outside the field: `space`/`S` start or pause · `U` count
up · `⌫` stop & log (then type the next task) · `←`/`→` ∓1 min (`⇧` for 5) ·
`1`–`8` presets · `F` floating timer · `⌘T` timesheet · `⌘,` settings · `esc` close.

**Timesheet:** `←`/`→` day · `⇧←`/`⇧→` or `[`/`]` week · `T` today · `↑`/`↓`
select an entry · `↩` edit · `⌫` delete (`↩` confirms) · `N` add (fills the gap
since your last entry) · `R` rename task · `W` log day/week ·
`⌘E`/`⌘⇧E` export · `esc` close.

## Your data

Sessions are stored as readable JSON in
`~/Library/Application Support/Pomodoro/timesheet.json` (Settings → Show Data
File in Finder). The running session is checkpointed every 30 seconds, so a
crash or force-quit loses at most that much. Quitting the app logs whatever is
running. Sessions under 30 seconds are treated as accidental and skipped. A
running count-up pauses automatically when the Mac sleeps; locking the screen
leaves it running unless you turn that on too (both in Settings).

CSV exports open a Save dialog in Downloads. You can choose another folder.
After saving, the timesheet shows the filename and folder, with a **Show in
Finder** button to reveal the CSV. If saving fails, the app shows an error.

## Code map

```
Sources/Pomodoro/
  main.swift                   App entry (menu-bar-only, no Dock icon)
  AppDelegate.swift            Wires everything together
  TimerModel.swift             Countdown / count-up state machine; reports running stretches
  TimeLog.swift                Session store: recording, persistence, crash recovery, CSV
  TimesheetReport.swift        Rolls a week of sessions up by day and task
  TimesheetView.swift          Timesheet window: stats, chart, task grid, log, editor
  Preferences.swift            All settings, persisted to UserDefaults
  StatusItemController.swift   Menu bar item rendering + click handling
  TimerPanelController.swift   Dropdown window, positioning, keyboard
  PanelView.swift              Dropdown UI: TickSlider, preset chips, clock
  FloatingTimerController.swift  Floating window + its SwiftUI face
  SettingsView.swift           Settings window
  Completion.swift             Sound + notification when time's up
  Snapshots.swift              Dev-only: `make snapshots`
Resources/Info.plist           Bundle config (LSUIElement = menu bar app)
scripts/                       build-app.sh, swiftc.sh, make-icon.*
```

Package.swift is included so you can open the project in Xcode if you install
it later (`open Package.swift`).
