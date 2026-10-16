# FocusFlow

FocusFlow is a native macOS productivity application crafted in Swift, SwiftUI, and AppKit. It combines a customizable focus timer, precision stopwatch with lap capture, generalized task management with live time tracking, ambient audio soundscapes, and a dedicated menu-bar companion into a unified, distraction-free workspace.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-green)
![Build Status](https://img.shields.io/badge/tests-123%20passed-brightgreen)

---

## Features

### Focus Timer & Interval Sessions
- **Configurable Presets**: Pomodoro (25m), Short Break (5m), Deep Work (50m), Long Break (15m), and custom durations.
- **Clock Face Variations**: Minimal Digital, Smooth Continuous Progress Ring, and Classic Analog minute dial.
- **Fullscreen Focus Mode**: Distraction-free presentation showing only the active clock, subtle progress, and an accessible exit control (with `Esc` keyboard shortcut).
- **Session Controls**: Start, pause, resume, reset, and skip controls with accurate countdown display.

### Precision Stopwatch & Lap Tracking
- **Elapsed Time Tracking**: Second and sub-second tracking with dynamic hour/minute/second formatting (`HH:mm:ss` / `mm:ss`).
- **Lap Management**: Capture split times and lap durations with fastest and slowest lap visual indicators.
- **Compact Popover Integration**: Scrollable lap history inside the menu-bar companion.

### Task Management & Time Allocation
- **Universal Task Organizer**: Organize tasks by category, tags, and priorities.
- **Active Focus Linkage**: Accumulate focus time automatically against active tasks during running timer and stopwatch sessions.
- **Inline Editing & Progress**: Toggle completion, edit task titles, and monitor accumulated focus time in real time.

### Insights & Analytics
- **Daily Goals & Streaks**: Visual progress toward daily focus targets.
- **Weekly Analytics**: Detailed day-by-day distribution of completed focus sessions and hours logged.

### Ambient Soundscapes
- **Audio Generator**: Native `AVAudioPlayer` playback with multi-channel support for Rain, Ocean, and Forest recordings.
- **Smooth Playback**: Background audio with cross-fading and adjustable volume controls.

### Native macOS Integration & Menu-Bar Companion
- **Dual Presentation**: Full desktop application workspace and companion menu-bar popover (`MenuBarExtra`).
- **Menu-Bar Status Display**: Live countdown and mode indicator directly in the macOS status bar, deterministically driven by the active companion tab (`Focus Timer` vs `Stopwatch`).
- **Inline Switch Confirmation**: Compact in-popover confirmation when requesting preset or mode changes while a timer is active, preventing accidental session loss.
- **Consistent Display**: Paused countdowns and live sessions show exact remaining time (e.g., `04:54` rather than resetting to `05:00`).

### Durability, Backup & Recovery
- **Persistent Storage**: Automatic local JSON persistence in `~/Library/Application Support/FocusFlow/focusflow_data.json`.
- **Automatic Backup Rotation**: Safe write-before-replace atomic saves and automatic backup creation (`focusflow_data.backup.json`).
- **Disaster Recovery**: Automatic restoration from valid backup if primary storage file encounters data corruption.
- **Save-Failure Notifications**: Published storage error state with visible warnings and non-destructive retry flow.
- **Session Continuity**: Paused timers, running stopwatch offsets, and elapsed session segments survive application quit and relaunch.

---

## Installation

### Apple Silicon Preview DMG

A pre-packaged disk image is available for Apple Silicon Macs running macOS 14.0 or later:

1. Download [`releases/FocusFlow-Preview-macOS14-arm64.dmg`](releases/FocusFlow-Preview-macOS14-arm64.dmg).
2. Open the disk image and drag **FocusFlow.app** to your `/Applications` folder.
3. Open FocusFlow from Applications or Spotlight.

> [!NOTE]
> This is a developer preview build with an ad-hoc signature. It is not currently signed with an Apple Developer ID or notarized through Apple Gatekeeper. On first launch, macOS may require right-clicking the app and selecting **Open**, or allowing it in **System Settings > Privacy & Security**.

---

## Building & Testing

### Requirements
- **macOS**: 14.0 (Sonoma) or later
- **Swift**: 5.9 or later
- **Xcode**: 15.0+ or Xcode Command Line Tools
- **Architecture**: Apple Silicon (arm64) or Universal

### Build with Swift Package Manager

```bash
# Build release executable
swift build -c release

# Run the test suite
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
│   └── FocusFlowTests.swift                  # Comprehensive regression and unit test suite
├── Assets/Soundscapes/                       # Bundled ambient audio files (Rain, Ocean, Forest)
├── scripts/
│   ├── create_dmg.sh                         # Automated DMG packaging and layout script
│   └── make_dmg_background.swift             # Programmatic DMG background artwork generator
└── releases/                                 # Packaged preview DMG and application bundle
```

---

## Quality & CI Status

FocusFlow is continuously validated via GitHub Actions on macOS 14:

- **Automated Tests**: **123 passed, 0 failures**
- **Release Build**: Successful production compilation
- **Verified Source Commit**: `6d9a4e7`
- **Verified Release DMG Commit**: `b76e47d`
- **CI Workflow**: [`FocusFlow CI (.github/workflows/build.yml)`](.github/workflows/build.yml)

> [!NOTE]
> While the automated test suite exercises core state transitions, data persistence, timer math, and error recovery, automated testing alone does not guarantee that the application is completely free of bugs under all edge cases.

---

## Known Remaining Issues

1. **Stopwatch Lap Deletion**: Deleting intermediate laps from the laps list may lead to inconsistent split duration calculations for subsequent laps.
2. **Persistence Write Consolidation**: Multiple rapid actions can schedule overlapping delayed writes that would benefit from debounced consolidation.
3. **Midnight Boundary Accounting**: Focus time accumulated during sessions spanning across midnight is currently attributed to the starting calendar day rather than splitting across days.

---

## Distribution Status

FocusFlow is currently distributed as a developer preview. Apple Developer ID code signing, hardened runtime entitlement provisioning, and Apple Gatekeeper notarization are pending for future commercial distribution.
