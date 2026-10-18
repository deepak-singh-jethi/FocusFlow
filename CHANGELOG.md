# Changelog

All notable changes to the FocusFlow project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Planned Engineering Milestones
- **Task 9 — Idle Time Review**: User notification, prompt presentation, and session handling when system or application idle time is detected during active focus sessions.
- **Release Packaging Pipeline**:
  - Apple Developer ID Application code signing and Hardened Runtime provisioning.
  - Apple Gatekeeper notarization via `notarytool`.
  - Automated production DMG packaging workflow replacing current ad-hoc script.
- **Optimization (Deferred)**:
  - Decoupling continuous clock rendering from the 10Hz Combine timer loop to SwiftUI GPU `TimelineView`.

---

## [Engineering Milestone — 18 October 2026: Tasks 6, 7 & 8 (Recovery, Deadlines & Coalescing)]

**Verified Source Commit**: [`3e9d88c863a29cc908044e7efbcad94f0aae7660`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660)
**CI Baseline**: [GitHub Actions Run #39138658657](https://github.com/deepak-singh-jethi/FocusFlow/actions/runs/39138658657) (476 passed, 0 failures)

### Added
- **Atomic Completion Transactions (Task 8)**: Introduced `isCompletingSessionTransaction` guard in `TimerViewModel`. Suppresses nested saves and commits record creation, completion count increments, and preset transitions to disk in a single synchronous transaction upon countdown expiry.
- **Periodic Crash Recovery Checkpoints (Task 8)**: Added periodic persistence of `ActiveSessionRecoveryState` snapshots targeting ~15-second intervals during running countdowns.
- **Segment-Accurate Multi-Task Recovery (Task 8)**: Implemented segment duration calculation bounding recovered time strictly to `segmentCreditedSeconds`, conserving total session duration across task transitions.
- **Conservative Recovery Validation (Task 8)**: Implemented snapshot validation in `validateRecoveryState` to detect malformed or inconsistent recovery metadata on launch.
- **Comprehensive Task 8 Regression Coverage**: Added 48 numbered Task 8 automated scenarios, supplemented by audit, deadline, and dedicated Defect A/B regression suites (bringing the overall suite to 476 tests).

### Fixed
- **Defect A (Normal Completion Atomic Persistence - Task 8)**: Resolved issue where `vm.tick()` expiry could write an intermediate snapshot to disk (record finalized, but `completedSessions` still 0 and preset still Focus) before delayed callbacks executed. Commit: [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660).
- **Defect B (Multi-Task Recovery Inflation - Task 8)**: Resolved issue where legacy expired session recovery computed duration as `max(segmentCreditedSeconds, totalTime - timeRemaining)`, fabricating phantom focus time in multi-task sessions. Commit: [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660).
- **Forced-Save Deadline Boundary Finalization (Task 8)**: Fixed `settleActiveTimeForSnapshot` to finalize expired focus records, clear running state, increment `completedSessions`, and apply preset transitions during forced saves at or after deadlines. Commit: [`b0960ad`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b0960ad56cf607d1148429e2e4501c622bec58fb).
- **Checkpoint Validation & Atomic Accounting (Task 8)**: Enforced duration bounds and task attribution integrity during crash recovery restoration. Commit: [`e0e7e4f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e0e7e4f9aabc646c85f74619bc6f41db9711953e).
- **Initial Checkpoint Recovery Mechanism (Task 8)**: Added durable checkpoint recovery for interrupted sessions. Commit: [`3f85f13`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3f85f1346d7cd49944b652b03359d3f77ef8bb0d).
- **Task 7 (Sleep/Wake & Deadline Finalization)**:
  - Eliminated deadline boundary race condition in `skipSession`. Commit: [`991fd11`](https://github.com/deepak-singh-jethi/FocusFlow/commit/991fd115bd259d40b01dc34a7f6b54d6525286d7).
  - Settled pending focus time before finalizing sessions. Commit: [`50fe1b5`](https://github.com/deepak-singh-jethi/FocusFlow/commit/50fe1b5b0a550e10ca2b0e98dbf862a83976c59e).
  - Hardened application termination handling and fractional deadline calculations. Commit: [`a1ad2a2`](https://github.com/deepak-singh-jethi/FocusFlow/commit/a1ad2a2b9ecd82fffc59bd0a24455b1377edfb0c).
  - Preserved original deadline across all focus finalization paths. Commit: [`ed74970`](https://github.com/deepak-singh-jethi/FocusFlow/commit/ed74970838f8ef8f578c98d4ca2910576bf42366).
  - Reconciled sleep/wake expiry against wall-clock deadlines, eliminating focus overcount. Commit: [`c65be9b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/c65be9be4063304a9b6e23058e8fcd5e59a75817).
- **Task 6 (Persistence Coalescing)**:
  - Implemented generational request tracking (`pendingSaveRequestCount`) to reject stale delayed save callbacks. Commit: [`4c7ab97`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4c7ab977a39474db87ee8295ef840b4e41eafb1c).
  - Consolidated rapid save requests into a single debounced write with forced-save bypass. Commit: [`da377f6`](https://github.com/deepak-singh-jethi/FocusFlow/commit/da377f600e15ce9a1f5cb200ad9161da8e6e151e).
- **Window Management & Latency Hardening**:
  - Hardened timezone notification wait loop against CI latency. Commit: [`b54ff78`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b54ff7870383f86faf173f495c8a3710852efb0c).
  - Preserved window visibility when native macOS fullscreen exit encounters edge cases. Commit: [`3df730e`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3df730ebb6f858fc175ce7a34094f64e3c68ce4c).

---

## [Engineering Milestone — 17 October 2026: Tasks 3, 4 & 5 (Midnight Analytics, Restart Restoration & Task Transitions)]

### Fixed
- **Task 5 (Midnight & Timezone Analytics)**:
  - Made midnight test scheduler callbacks synchronous on MainActor. Commit: [`abf784c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/abf784c3b688ec2af397e37ed3cad82b93202eca).
  - Hardened midnight scheduling and timezone refresh tests. Commit: [`859a136`](https://github.com/deepak-singh-jethi/FocusFlow/commit/859a13692a0f84094e5a34b93ed20eee7960b73c).
  - Excluded future time and hardened lifecycle refresh via `significantTimeChangeNotification`. Commit: [`2017a8b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/2017a8ba89ca01d38450b3852bbcefd1ef075de1).
  - Accurately attributed focus time across midnight boundaries into appropriate calendar-day buckets. Commit: [`7c2b66f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/7c2b66fdf001a2aea50ea9f421f89bbbe1450252).
- **Task 4 (Restart Restoration)**:
  - Validated restored duration bounds against preset limits. Commit: [`4465b0b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4465b0b23af32d85555c7bf90e98a2bf14b3b0ba).
  - Restored selected task UUID, active preset, custom durations, and session counts upon relaunch. Commit: [`654f654`](https://github.com/deepak-singh-jethi/FocusFlow/commit/654f654f195214f3e120a53eb58656033e6b7f65).
- **Task 3 (Task Attribution Transitions & Retroactive Protection)**:
  - Prevented retroactive stopwatch attribution upon new task creation. Commit: [`4edd3a1`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4edd3a1fd3d69715a704936ebe742e18d888dea8).
  - Preserved unassigned focus segments during active task transitions. Commit: [`aefa599`](https://github.com/deepak-singh-jethi/FocusFlow/commit/aefa599b648b0ba462f64061177667fd856c9e1a).
- **Window Management**:
  - Safely closed native fullscreen window without orphaned AppKit window state. Commit: [`e3a2191`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e3a2191c55a4df27f8eabb409ad3e1a4986be0d5).
- **Release Preview Packaging**:
  - Updated preview disk image artifact (`FocusFlow-Preview-macOS14-arm64.dmg`). Commit: [`da23a3c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/da23a3ca84769ea930f8034c4270c7c6400e2586).

---

## [Engineering Milestone — 16 October 2026: Tasks 2 & 3, Menu-Bar Companion & Data Protection]

### Added
- **Menu-Bar Companion & Switch Confirmation**:
  - Implemented compact 316 pt inline timer switch confirmation card inside `MenuBarCompanionView`. Commit: [`a4eafd6`](https://github.com/deepak-singh-jethi/FocusFlow/commit/a4eafd60c27b51f129e8804cb92e9c9a6cc007f4).
  - Synchronized paused countdown display and isolated status-bar icon presentation. Commit: [`6d9a4e7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/6d9a4e77e713883ba2c10be24f418984fd05c38d).
  - Updated production preview DMG with timer display and companion fixes. Commit: [`b76e47d`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b76e47dd59b4480fc2d5bd93b170662d5c2fd645).
- **Automatic Backup & Disaster Recovery**:
  - Implemented automatic backup creation (`focusflow_data.json.bak`) on atomic saves and automatic recovery when primary data is corrupted. Commit: [`711e422`](https://github.com/deepak-singh-jethi/FocusFlow/commit/711e42249c4a00fff4f7bdef59de3207f7b07fed).
  - Implemented save-failure warning banners, corruption propagation guards, and non-destructive retry flow. Commits: [`709f861`](https://github.com/deepak-singh-jethi/FocusFlow/commit/709f861733732d16d45852a63163e42111675556), [`09c0e99`](https://github.com/deepak-singh-jethi/FocusFlow/commit/09c0e993e7de28972b6c384e8bbf01b832b5dc07).

### Fixed
- **Task 3 (Task Attribution Initial Settlement)**:
  - Settled old task credit before switching active tasks. Commit: [`e17d650`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e17d650c28937179f8fd54649732165000e858a6).
- **Task 2 (Stopwatch Lap Integrity)**:
  - Preserved lap checkpoints and sequential numbering across deletions. Commit: [`4dca67e`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4dca67efa9cb308a34c5b25d211855f4114f92df).
  - Formatted elapsed time as `HH:mm:ss` after one hour. Commit: [`4d6d565`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4d6d565f991ca3ed5568e768d3c0e657adcb8139).
  - Restored running/paused stopwatch progress across app restarts. Commit: [`eaa36b0`](https://github.com/deepak-singh-jethi/FocusFlow/commit/eaa36b07bd404e35ae8de674e67e0a88090dc16b).
- **Timer Restart Recovery Initial Steps**:
  - Restored running timer progress as paused across restarts. Commit: [`215db7c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/215db7ce240881759994b55801813ef54c2f8b13).
  - Restored paused timer state after app restart. Commit: [`fdef734`](https://github.com/deepak-singh-jethi/FocusFlow/commit/fdef7349945c07d44523a8c435ca430be0d477dd).

---

## [Engineering Milestone — 15 October 2026: Task 1 Continuity, HUD Modals & Selection Controls]

### Added
- **Mode Conflict Resolution**: Added Obsidian HUD mode switch conflict confirmation dialogs. Commits: [`0cef82e`](https://github.com/deepak-singh-jethi/FocusFlow/commit/0cef82ea8d342487b2cf3bd62dbbfb4f6ef848b3), [`7b4aa71`](https://github.com/deepak-singh-jethi/FocusFlow/commit/7b4aa7123ef26c7009f926f73f3b21ecbe552f25).
- **Timer Continuity**: Preserved running timer progress when switching between focus and break modes. Commits: [`11edaa8`](https://github.com/deepak-singh-jethi/FocusFlow/commit/11edaa875fb13c2cce0749820f9c43c1d73c0aac), [`e586ce5`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e586ce520162495bcdc21cfb51f2063ece33d89d).
- **Multi-Mode Integration**: Integrated timer continuity, conflict resolution, analytics, and menu bar companion. Commit: [`e95dcd7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e95dcd785f0a36535dd26f8e28e5b0b9425cb0a0).
- **Session Controls & Formatting**: Fixed skipped session completion count and stopwatch hour formatting. Commit: [`0976d6b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/0976d6b2c673dde47faab64d171eec0bba4f3ea9).

---

## [Engineering Milestone — 14 October 2026: Initial Modular Architecture & Reliability]

### Added
- **Modular Swift Architecture**: Refactored monolithic prototype into a clean SPM modular layout with Models, ViewModels, Views, Components, and Services. Commit: [`fc035a7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/fc035a7c2492ae02a9ce3fa3c99ca16fd48d7558).
- **Senior Engineer Architectural Review**: Added comprehensive architectural review and roadmap report. Commit: [`d64ca38`](https://github.com/deepak-singh-jethi/FocusFlow/commit/d64ca38d6342ba7c34956a3170df6a9330eff4ec).
- **JSON Storage Engine & Relaxed Master Timer**: Implemented `FocusStorageService` for local JSON persistence and replaced 50Hz timer loop with 10Hz relaxed Combine timer. Commit: [`1c1b9d7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/1c1b9d71e10559b6ce05c64c8a6706d3f27accd6).
- **Custom Duration & Modal Polish**: Implemented custom duration modal presentation, clean modal UI, and header notch alignment. Commit: [`c7980ab`](https://github.com/deepak-singh-jethi/FocusFlow/commit/c7980ab3bbf5b65ba5e9ca918e3f3e83926d0ca0).

---

## Automated Test Milestone History

The automated test suite in `Tests/FocusFlowTests/FocusFlowTests.swift` progressed through verified milestones:

| Milestone Date | Milestone Description | Test Suite Breakdown | Result | Reference Commit |
|---|---|---|---|---|
| **16 Oct 2026** | Initial Architectural & Reliability Baseline | 123 unit & regression tests | 0 failures | [`6d9a4e7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/6d9a4e77e713883ba2c10be24f418984fd05c38d) |
| **18 Oct 2026** | Task 7 Sleep/Wake & Deadline Finalization Approval | 373 tests (including Task 7 Scenarios 01–20) | 0 failures | [`991fd11`](https://github.com/deepak-singh-jethi/FocusFlow/commit/991fd115bd259d40b01dc34a7f6b54d6525286d7) |
| **18 Oct 2026** | Task 8 Initial Checkpoint Recovery Implementation | 424 tests (including initial Task 8 scenarios) | 0 failures | [`3f85f13`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3f85f1346d7cd49944b652b03359d3f77ef8bb0d) |
| **18 Oct 2026** | Task 8 Audit Correction: Checkpoint Validation | 442 tests (including F1–F5 audit tests) | 0 failures | [`e0e7e4f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e0e7e4f9aabc646c85f74619bc6f41db9711953e) |
| **18 Oct 2026** | Task 8 Audit Correction: Deadline Boundary Expiry | 463 tests (including Groups A–E tests) | 0 failures | [`b0960ad`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b0960ad56cf607d1148429e2e4501c622bec58fb) |
| **18 Oct 2026** | Task 8 Final Approved: Atomic Completion & Segment Credit | 476 tests (48 numbered scenarios + audit, deadline & Defect A/B suites) | 0 failures | [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660) |
