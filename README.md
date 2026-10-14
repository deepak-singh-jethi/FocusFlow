# FocusFlow ⏱️

FocusFlow is an elegant, native macOS productivity application crafted in Swift and SwiftUI. It combines a customizable focus timer, precision stopwatch, generalized task management with live time tracking, and ambient soundscapes into a unified workspace.

![macOS 14+](https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple)
![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)
![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-green)
![License](https://img.shields.io/badge/license-MIT-purple)

---

## ✨ Features

- **Focus Timer**:
  - Customizable presets (Pomodoro, Short Break, Deep Work, Long Break) and custom interval ranges.
  - Interactive clock faces: Minimal Digital, Smooth Continuous Progress Ring, and Classic Analog.
  - Immersive Focus Mode with distraction-free typography and controls.
  - Live task association and time accumulation.

- **Precision Stopwatch**:
  - Millisecond-accurate timing with lap tracking, fastest/slowest lap indicators, and split times.
  - Independent background execution.

- **Cross-Mode Persistent Mini-Bar**:
  - Interactive bottom mini-bar that persists across tabs.
  - Click anywhere on the bar with spring animations to immediately navigate to the running timer or stopwatch.
  - Dedicated quick Play/Pause control directly from any view.

- **Generalized Task Manager**:
  - Universal task management for work, study, coding, writing, and custom projects.
  - Real-time elapsed time tracking linked with active focus sessions.
  - Priority flags, tags, and inline completion status.

- **Ambient Soundscapes**:
  - Built-in multi-channel ambient audio generator (Rain, Forest, Ocean) with volume mixing.

- **Weekly Insights & Activity Analytics**:
  - Detailed daily/weekly focus charts and completion history.

---

## 🚀 Building & Running

### Requirements
- macOS 14.0 (Sonoma) or later
- Xcode 15+ / Command Line Tools (`swiftc`)
- Apple Silicon (arm64) or Universal

### Compiling from Source
```bash
# Compile native binary
swiftc -O -target arm64-apple-macos14.0 \
  -framework SwiftUI -framework AppKit -framework Combine -framework AVFoundation \
  FocusFlowApp.swift -o FocusFlow

# Run
./FocusFlow
```

### Packaged DMG
Download the latest preview disk image from [`releases/FocusFlow-Preview-macOS14-arm64.dmg`](releases/FocusFlow-Preview-macOS14-arm64.dmg) and drag `FocusFlow.app` to your Applications folder.

---

## 🛠️ Tech Stack
- **UI Framework**: SwiftUI & AppKit integration
- **State Management**: Combine reactive publishers & Observable state
- **Audio Engine**: AVFoundation `AVAudioPlayer`
- **Design System**: Native macOS dark-mode aesthetic with fluid spring animations
