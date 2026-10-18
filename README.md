# FocusFlow

FocusFlow is a native macOS productivity application crafted in Swift, SwiftUI, and AppKit. It combines a customizable focus timer, precision stopwatch with lap capture, generalized task management with live time tracking, daily and weekly analytics, ambient audio soundscapes, and a dedicated menu-bar companion into a unified, distraction-free workspace.

[![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)](https://www.apple.com/macos/sonoma/)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-green)](https://www.apple.com/mac/)
[![FocusFlow CI](https://github.com/deepak-singh-jethi/FocusFlow/actions/workflows/build.yml/badge.svg)](https://github.com/deepak-singh-jethi/FocusFlow/actions/workflows/build.yml)
[![Automated Tests](https://img.shields.io/badge/tests-476%20passed-brightgreen)](https://github.com/deepak-singh-jethi/FocusFlow/actions/runs/39138658657)

---

## Features

### Focus Timer & Interval Sessions
- **Configurable Presets**: Pomodoro (25m), Short Break (5m), Deep Work (50m), Long Break (15m), and custom minute/second durations.
- **Clock Face Variations**: Minimal Digital, Smooth Continuous Progress Ring, and Classic Analog minute dial.
- **Session Controls**: Start, pause, resume, reset, and skip controls with accurate countdown display.
- **Original Deadline Anchoring**: Strict wall-clock countdown math (`targetEndDate = Date().addingTimeInterval(...)`) preventing cumulative timer drift across runloop delays.
- **Sleep/Wake & Deadline Finalization**: Authoritative wall-clock reconciliation after system sleep; elapsed focus time is strictly capped at the original deadline, eliminating overcount.
- **Exact-Once Session Transitions**: Guaranteed atomic Focus $\to$ Break and Break $\to$ Focus transitions with configurable auto-start policy.
- **Conflict-Aware Session Switching**: In-place HUD confirmation dialogs in both desktop and menu-bar companion protect in-progress sessions from accidental cancellation.
- **Fullscreen Focus Mode**: Distraction-free presentation showing only the active clock, subtle progress, and an accessible exit control (with `Esc` keyboard shortcut).

### Precision Stopwatch & Lap Tracking
- **Elapsed Time Tracking**: Second and sub-second tracking with dynamic hour/minute/second formatting (`HH:mm:ss` after one hour, `mm:ss` prior).
- **Lap Management**: Capture split times and lap durations with fastest and slowest lap indicators.
- **Lap Checkpoint Integrity**: Deleting individual laps recalculates indices sequentially while preserving cumulative timing checkpoints.
- **Restart Continuity**: Active elapsed time and recorded laps survive application termination and restore accurately in a paused state.
- **Compact Popover Integration**: Constrained, scrollable lap history inside the companion menu-bar popover.

### Task Management & Time Allocation
- **Universal Task Organizer**: Organize tasks by category, tags, and priorities with inline title editing and completion toggling.
- **Active Focus Linkage**: Accumulate focus time automatically against active tasks during running timer and stopwatch sessions.
- **Segment-Accurate Attribution**: Switching active tasks during a running session finalizes the prior task's segment immediately; unassigned focus time is preserved without retroactive attribution.
- **Task Lifecycle Safety**: Deleting or completing an active task during a running session cleanly dissociates subsequent elapsed time without corrupting historical records.

### Insights & Analytics
- **Daily Goals & Streaks**: Visual progress toward daily focus targets.
- **Weekly Analytics**: Detailed day-by-day distribution of completed focus sessions and hours logged.
- **Accurate Midnight Allocation**: Calendar-day attribution splits or bounds sessions crossing midnight, ensuring focus time is allocated strictly to the local calendar day in which it occurred.
- **Timezone & Calendar Refresh**: Automatically recalculates daily and weekly buckets upon system timezone changes or day boundaries (`significantTimeChangeNotification`).
- **Future-Time Exclusion**: Session records are strictly bounded to current time, preventing clock-skew inflation.

### Ambient Soundscapes
- **Bundled Recordings**: Plays bundled Rain, Ocean, and Forest MP3 recordings using `AVAudioPlayer`.
- **Playback Controls**: Supports adjustable volume and smooth crossfades when switching between soundscapes.
- **Multi-Path Resource Resolution**: Robust audio locator hierarchy checking app bundle subdirectories, root bundle resources, and developer paths.

### Native macOS Integration & Menu-Bar Companion
- **Dual Presentation**: Full desktop application workspace and companion menu-bar popover (`MenuBarExtra`) with `.menuBarExtraStyle(.window)`.
- **Deterministic Status-Bar Display**: Status-bar clock and icon are driven deterministically by the active companion tab (`Focus Timer` vs `Stopwatch`), preventing display hijacking.
- **Inline Switch Confirmation**: Compact 316 pt modal card directly inside the popover to prevent accidental session loss.
- **Consistent Display**: Paused countdowns display exact remaining time (e.g., `04:54` rather than resetting to `05:00`) alongside dynamic Resume controls.

### Durability, Backup & Crash Recovery
- **Persistent Storage**: Automatic local JSON persistence in `~/Library/Application Support/FocusFlow/focusflow_data.json`.
- **Automatic Backup Rotation**: Safe write-before-replace atomic saves and automatic backup creation (`focusflow_data.json.bak`).
- **Disaster Recovery**: Automatic restoration from valid backup if primary storage file encounters data corruption, with forensic preservation of damaged files.
- **Write Coalescing & Stale Callback Rejection**: Consolidates rapid save requests using generational tracking; delayed async callbacks cannot overwrite newer disk commits.
- **Save-Failure Notifications**: Published storage error state with visible warnings and non-destructive retry flow.
- **Crash/Force-Quit Checkpoints**: Periodic active-session checkpoints write recoverable metadata to disk under normal running conditions.
- **Interrupted Session Recovery**: Interrupted running sessions restore in a paused state upon relaunch; process downtime is never credited as focus work.
- **Atomic Session Completion**: Normal countdown expiry commits record creation, counter increments, preset transitions, and cleared recovery metadata in a single atomic transaction.
- **Multi-Task Recovery Conservation**: Legacy expired session recovery bounds credited time strictly to the current segment (`segmentCreditedSeconds`), conserving exact duration across multi-task sessions.

> [!NOTE]
> **Recovery Point Notice**: Under active running conditions, FocusFlow targets a periodic checkpoint interval of approximately 15 seconds. Actual durability depends on successful disk commits and system load; it is a best-effort recovery checkpoint rather than an unconditional zero-data-loss guarantee.

---

## Installation

### Apple Silicon Preview DMG

A pre-packaged disk image is available for Apple Silicon Macs running macOS 14.0 or later:

1. Download [`releases/FocusFlow-Preview-macOS14-arm64.dmg`](releases/FocusFlow-Preview-macOS14-arm64.dmg).
2. Open the disk image and drag **FocusFlow.app** to your `/Applications` folder.
3. Open FocusFlow from Applications or Spotlight.

> [!IMPORTANT]
> **Preview DMG Provenance Notice**: The committed preview DMG in `releases/FocusFlow-Preview-macOS14-arm64.dmg` was packaged at commit `da23a3ca84` (17 October 2026). It **does not contain the subsequent Task 7 (sleep/wake finalization) or Task 8 (crash recovery & atomic completion) source fixes**. The DMG will be re-built and verified from source prior to official release.

> [!NOTE]
> This is a developer preview build with an ad-hoc signature. It is not currently signed with an Apple Developer ID or notarized through Apple Gatekeeper. On first launch, macOS may require right-clicking the app and selecting **Open**, or allowing it in **System Settings > Privacy & Security**.

---

## Building & Testing

### Requirements
- **macOS**: 14.0 (Sonoma) or later
- **Swift**: 5.9 or later
- **Xcode**: 15.0+ or Xcode Command Line Tools
- **Architecture**: Apple Silicon (`arm64`) or Universal

### Build with Swift Package Manager

```bash
# Build release executable
swift build -c release

# Run the full automated test suite (476 tests)
swift test

# Launch the app from the terminal
swift run FocusFlow
```

---

## Project Structure

```
FocusFlow/
├── Package.swift                             # Swift Package manifest (macOS 14+ target)
├── Sources/FocusFlow/
│   ├── FocusFlowApp.swift                    # @main entry point, MainWindow & MenuBarExtra
│   ├── Models/
│   │   ├── FocusTask.swift                   # Identifiable task model and time calculation
│   │   └── NavigationTab.swift               # Strongly-typed workspace navigation enum
│   ├── ViewModels/
│   │   └── TimerViewModel.swift              # Central @MainActor state machine and timer engine
│   ├── Services/
│   │   ├── AmbientAudioPlayer.swift          # Multi-path audio locator and AVFoundation player
│   │   ├── FocusStorageService.swift         # Atomic JSON persistence, backup rotation & recovery
│   │   └── NotificationService.swift         # User notification scheduling and dispatch
│   ├── Components/
│   │   ├── ButtonStyles.swift                # Tactile hover, press, and capsule styles
│   │   ├── ClockFaces.swift                  # Digital, Ring, and Analog clock face implementations
│   │   ├── CustomConfirmModal.swift          # Reusable modal dialog with keyboard shortcuts
│   │   ├── CustomDurationPopover.swift       # Stepper controls for custom intervals
│   │   ├── InPlaceTimeInputView.swift        # Inline numeric duration inputs
│   │   ├── PersistentCrossModeMiniBar.swift  # Bottom persistent navigation bar
│   │   └── TimerConflictSwitchModal.swift    # Full-size desktop preset conflict confirmation
│   └── Views/
│       ├── ContentView.swift                 # Root navigation and window coordination
│       ├── DashboardTimerView.swift          # Primary timer and stopwatch stage
│       ├── FocusStateView.swift              # Minimalist distraction-free fullscreen view
│       ├── InsightsView.swift                # Focus charts and session analytics
│       ├── MenuBarCompanionView.swift        # Compact menu-bar popover, controls & inline modal
│       ├── RightPanelView.swift              # Slide-out drawer sheet
│       ├── SettingsView.swift                # User preferences and session configuration
│       ├── SidebarView.swift                 # Collapsible primary navigation sidebar
│       ├── SoundscapesView.swift             # Audio scene selection cards
│       └── TasksView.swift                   # Task manager with inline time tracking
├── Tests/FocusFlowTests/
│   └── FocusFlowTests.swift                  # Comprehensive unit & regression test suite (476 tests)
├── Assets/Soundscapes/                       # Bundled ambient audio files (Rain, Ocean, Forest)
├── docs/
│   ├── SENIOR_ENGINEER_REVIEW_REPORT.md      # Architecture review, Task 1–8 matrix & invariants
│   └── RELEASE_READINESS.md                  # Release checklist, manual QA, and distribution status
├── CHANGELOG.md                              # Chronological engineering history and commit links
├── scripts/
│   ├── create_dmg.sh                         # Automated DMG packaging and layout script
│   └── make_dmg_background.swift             # Programmatic DMG background artwork generator
└── releases/                                 # Packaged preview DMG and application bundle
```

---

## Quality & CI Status

FocusFlow is continuously validated via GitHub Actions on `macos-14`:

- **Engineering Milestones**: Tasks 1–8 completed and approved through independent source review (as of 18 October 2026).
- **Verified Source Commit**: [`3e9d88c863a29cc908044e7efbcad94f0aae7660`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660)
- **Automated Tests**: **476 passed, 0 failures** (verified 18 October 2026).
- **Release Build**: Successful production compilation in GitHub Actions.
- **CI Workflow Run**: [FocusFlow CI Run #39138658657](https://github.com/deepak-singh-jethi/FocusFlow/actions/runs/39138658657).
- **Next Milestone**: Task 9 — Idle Time Review (**NOT STARTED**).

---

## Known Remaining Issues & Release Scope

The following items define the remaining engineering and distribution scope prior to public release:

1. **Task 9 — Idle Time Review**: Planned user prompting and handling for detected idle periods during active sessions remains to be designed and implemented.
2. **Physical-Mac Force Quit / SIGKILL Verification**: Automated tests verify ViewModel recovery against simulated process kills; manual OS-level verification on physical hardware remains pending.
3. **Full GUI & Hardware Sleep/Wake Validation**: Live hardware verification of display sleep, lid close/open, and fullscreen transitions across multiple monitors remains pending.
4. **Preview DMG Rebuild**: The committed preview DMG (`releases/FocusFlow-Preview-macOS14-arm64.dmg`) must be re-compiled and verified against the latest source commit following Task 9.
5. **Code Signing & Notarization**: Apple Developer ID Application signing, Hardened Runtime configuration, and Apple Gatekeeper notarization are pending for public distribution.
6. **Test Compilation Warnings**: Three unused-variable warnings currently appear during test compilation in `FocusFlowTests.swift`.
7. **Rendering Optimization (Deferred)**: Complete decoupling of clock animations to SwiftUI GPU `TimelineView` remains a deferred optimization opportunity.

---

## Documentation Links

- [Senior Engineer Architectural Review & Audit Report](docs/SENIOR_ENGINEER_REVIEW_REPORT.md)
- [Changelog & Historical Milestones](CHANGELOG.md)
- [Release Readiness & Manual QA Checklist](docs/RELEASE_READINESS.md)
