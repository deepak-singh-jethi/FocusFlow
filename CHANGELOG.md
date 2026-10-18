# Changelog

All notable changes to the FocusFlow project are documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Planned Engineering Milestones
- **Task 9 — Idle Time Review**: User notification, prompt presentation, and session handling when system or application idle time is detected during active focus sessions.
- **Release Packaging**:
  - Apple Developer ID Application code signing and Hardened Runtime provisioning.
  - Apple Gatekeeper notarization via `notarytool`.
  - Re-compilation and generation of the final public distribution DMG.
- **Optimization (Deferred)**:
  - Decoupling continuous clock rendering from the 10Hz Combine timer loop to SwiftUI GPU `TimelineView`.

---

## [Engineering Milestone — 18 October 2026: Task 8 Completion & Data Integrity Hardening]

**Verified Source Commit**: [`3e9d88c863a29cc908044e7efbcad94f0aae7660`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660)
**CI Baseline**: [GitHub Actions Run #39138658657](https://github.com/deepak-singh-jethi/FocusFlow/actions/runs/39138658657) (476 passed, 0 failures)

### Added
- **Atomic Completion Transactions**: Introduced `isCompletingSessionTransaction` guard in `TimerViewModel`. Suppresses nested saves and commits record creation, completion count increments, and preset transitions to disk in a single synchronous transaction upon countdown expiry.
- **Periodic Crash Recovery Checkpoints**: Added periodic persistence of `ActiveSessionRecoveryState` snapshots targeting ~15-second intervals during running countdowns.
- **Segment-Accurate Multi-Task Recovery**: Implemented segment duration calculation bounding recovered time strictly to `segmentCreditedSeconds`, conserving total session duration across task transitions.
- **Conservative Recovery Validation**: Implemented snapshot validation in `validateRecoveryState` to detect malformed or inconsistent recovery metadata on launch.
- **Comprehensive Task 8 Regression Suite**: Added 50 Task 8 automated test scenarios and 13 dedicated Defect A/B and edge-case regression tests (expanding suite to 476 tests).

### Fixed
- **Defect A (Normal Completion Atomic Persistence)**: Resolved issue where `vm.tick()` expiry could write an intermediate snapshot to disk (record finalized, but `completedSessions` still 0 and preset still Focus) before delayed callbacks executed. Commit: [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660).
- **Defect B (Multi-Task Recovery Inflation)**: Resolved issue where legacy expired session recovery computed duration as `max(segmentCreditedSeconds, totalTime - timeRemaining)`, fabricating phantom focus time in multi-task sessions. Commit: [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660).
- **Forced-Save Deadline Boundary Finalization**: Fixed `settleActiveTimeForSnapshot` to finalize expired focus records, clear running state, increment `completedSessions`, and apply preset transitions during forced saves at or after deadlines. Commit: [`b0960ad`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b0960ad56cf607d1148429e2e4501c622bec58fb).
- **Checkpoint Validation & Atomic Accounting**: Enforced duration bounds and task attribution integrity during crash recovery restoration. Commit: [`e0e7e4f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e0e7e4f9aabc646c85f74619bc6f41db9711953e).
- **Initial Checkpoint Recovery Mechanism**: Added durable checkpoint recovery for interrupted sessions. Commit: [`3f85f13`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3f85f1346d7cd49944b652b03359d3f77ef8bb0d).

---

## [Engineering Milestone — 17 October 2026: Tasks 5, 6, and 7 Completion]

### Fixed
- **Task 7 (Sleep/Wake & Deadline Finalization)**:
  - Eliminated deadline boundary race condition in `skipSession`. Commit: [`991fd11`](https://github.com/deepak-singh-jethi/FocusFlow/commit/991fd115bd259d40b01dc34a7f6b54d6525286d7).
  - Settled pending focus time before finalizing sessions. Commit: [`50fe1b5`](https://github.com/deepak-singh-jethi/FocusFlow/commit/50fe1b5b0a550e10ca2b0e98dbf862a83976c59e).
  - Hardened application termination handling and fractional deadline calculations. Commit: [`a1ad2a2`](https://github.com/deepak-singh-jethi/FocusFlow/commit/a1ad2a2b9ecd82fffc59bd0a24455b1377edfb0c).
  - Preserved original deadline across all focus finalization paths. Commit: [`ed74970`](https://github.com/deepak-singh-jethi/FocusFlow/commit/ed74970838f8ef8f578c98d4ca2910576bf42366).
  - Reconciled sleep/wake expiry against wall-clock deadlines, eliminating focus overcount. Commit: [`c65be9b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/c65be9be4063304a9b6e23058e8fcd5e59a75817).
- **Task 6 (Persistence Coalescing)**:
  - Implemented generational request tracking (`pendingSaveRequestCount`) to reject stale delayed save callbacks. Commit: [`4c7ab97`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4c7ab977a39474db87ee8295ef840b4e41eafb1c).
  - Consolidated rapid save requests into a single debounced write with forced-save bypass. Commit: [`da377f6`](https://github.com/deepak-singh-jethi/FocusFlow/commit/da377f600e15ce9a1f5cb200ad9161da8e6e151e).
- **Task 5 (Midnight & Timezone Analytics)**:
  - Made midnight test scheduler callbacks synchronous on MainActor. Commit: [`abf784c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/abf784c3b688ec2af397e37ed3cad82b93202eca).
  - Hardened midnight scheduling and timezone refresh tests. Commit: [`859a136`](https://github.com/deepak-singh-jethi/FocusFlow/commit/859a13692a0f84094e5a34b93ed20eee7960b73c).
  - Excluded future time and hardened lifecycle refresh via `significantTimeChangeNotification`. Commit: [`2017a8b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/2017a8ba89ca01d38450b3852bbcefd1ef075de1).
  - Accurately attributed focus time across midnight boundaries into appropriate calendar-day buckets. Commit: [`7c2b66f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/7c2b66fdf001a2aea50ea9f421f89bbbe1450252).
- **Window Management**:
  - Preserved window visibility when native macOS fullscreen exit encounters edge cases. Commit: [`3df730e`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3df730e7ee96df568600d8d7b3ca9be4713da2ef).
  - Safely closed native fullscreen window without orphaned AppKit window state. Commit: [`e3a2191`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e3a2191b4c919d77f805a96324dbe39e1ff95f40).

---

## [Engineering Milestone — 16 October 2026: Tasks 2, 3, 4, Menu-Bar Companion & Data Protection]

### Added
- **Menu-Bar Companion & Switch Confirmation**:
  - Implemented compact 316 pt inline timer switch confirmation card inside `MenuBarCompanionView`. Commit: [`a4eafd6`](https://github.com/deepak-singh-jethi/FocusFlow/commit/a4eafd6ca4237f8149e356c9a3bf3ebcfcb59670).
  - Synchronized paused countdown display and isolated status-bar icon presentation. Commit: [`6d9a4e7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/6d9a4e7f33d7b7fa25bece3f6bb91a0c8fec5695).
- **Automatic Backup & Disaster Recovery**:
  - Implemented automatic backup creation (`focusflow_data.json.bak`) on atomic saves and automatic recovery when primary data is corrupted. Commit: [`711e422`](https://github.com/deepak-singh-jethi/FocusFlow/commit/711e422204c3cf7b2b73715c0a373b9e4a3bb5d7).
  - Implemented save-failure warning banners, corruption propagation guards, and non-destructive retry flow. Commits: [`709f861`](https://github.com/deepak-singh-jethi/FocusFlow/commit/709f8611915ea78d05ceb1156e79d1d1f0ea58a8), [`09c0e99`](https://github.com/deepak-singh-jethi/FocusFlow/commit/09c0e998782f0bcda6dbe0a331f479dca68dd263).

### Fixed
- **Task 4 (Restart Restoration)**:
  - Restored selected task UUID, active preset, custom durations, and session counts upon relaunch. Commit: [`654f654`](https://github.com/deepak-singh-jethi/FocusFlow/commit/654f654f195214f3e120a53eb58656033e6b7f65).
  - Validated restored duration bounds against preset limits. Commit: [`4465b0b`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4465b0b23af32d85555c7bf90e98a2bf14b3b0ba).
- **Task 3 (Task Attribution Integrity)**:
  - Prevented retroactive stopwatch attribution upon new task creation. Commit: [`4edd3a1`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4edd3a1fd3d69715a704936ebe742e18d888dea8).
  - Preserved unassigned focus segments during active task transitions. Commit: [`aefa599`](https://github.com/deepak-singh-jethi/FocusFlow/commit/aefa599b648b0ba462f64061177667fd856c9e1a).
  - Settled old task credit before switching active tasks. Commit: [`e17d650`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e17d650c28937179f8fd54649732165000e858a6).
- **Task 2 (Stopwatch Lap Integrity)**:
  - Preserved lap checkpoints and sequential numbering across deletions. Commit: [`4dca67e`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4dca67efa9cb308a34c5b25d211855f4114f92df).
  - Formatted elapsed time as `HH:mm:ss` after one hour. Commit: [`4d6d565`](https://github.com/deepak-singh-jethi/FocusFlow/commit/4d6d56543b59df95b45f2f534ef0dc64f1d63683).
  - Restored running/paused stopwatch progress across app restarts. Commit: [`eaa36b0`](https://github.com/deepak-singh-jethi/FocusFlow/commit/eaa36b0805c6d32890539b00cf40212d26d564fa).

---

## [Engineering Milestone — 15 October 2026: Task 1 Continuity & Architecture]

### Added
- **Modular Swift Architecture**: Refactored monolithic prototype into a clean SPM modular layout with Models, ViewModels, Views, Components, and Services. Commit: [`fc035a7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/fc035a75669b22e173eecb2d2db73b18536ec6f1).
- **Relaxed Master Engine**: Replaced 50Hz Combine publisher with 10Hz relaxed timer loop (`1c1b9d7`).
- **Initial Persistence**: Implemented `FocusStorageService` for local JSON persistence in Application Support (`1c1b9d7`).
- **Mode Conflict Resolution**: Added Obsidian HUD mode switch conflict confirmation dialogs (`0cef82e`, `7b4aa71`).
- **Timer Continuity**: Preserved running timer progress when switching between focus and break modes (`11edaa8`, `e586ce5`).

---

## Automated Test Milestone History

The automated test suite in `Tests/FocusFlowTests/FocusFlowTests.swift` progressed through verified milestones:

| Milestone Date | Milestone Description | Test Count | Result | Reference Commit |
|---|---|---|---|---|
| **16 Oct 2026** | Initial Architectural & Reliability Baseline | 123 tests | 0 failures | [`6d9a4e7`](https://github.com/deepak-singh-jethi/FocusFlow/commit/6d9a4e7f33d7b7fa25bece3f6bb91a0c8fec5695) |
| **17 Oct 2026** | Task 7 Sleep/Wake & Deadline Finalization Approval | 373 tests | 0 failures | [`991fd11`](https://github.com/deepak-singh-jethi/FocusFlow/commit/991fd115bd259d40b01dc34a7f6b54d6525286d7) |
| **18 Oct 2026** | Task 8 Initial Checkpoint Recovery Implementation | 424 tests | 0 failures | [`3f85f13`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3f85f1346d7cd49944b652b03359d3f77ef8bb0d) |
| **18 Oct 2026** | Task 8 Audit Correction: Checkpoint Validation | 442 tests | 0 failures | [`e0e7e4f`](https://github.com/deepak-singh-jethi/FocusFlow/commit/e0e7e4f9aabc646c85f74619bc6f41db9711953e) |
| **18 Oct 2026** | Task 8 Audit Correction: Deadline Boundary Expiry | 463 tests | 0 failures | [`b0960ad`](https://github.com/deepak-singh-jethi/FocusFlow/commit/b0960ad56cf607d1148429e2e4501c622bec58fb) |
| **18 Oct 2026** | Task 8 Final Approved: Atomic Completion & Segment Credit | 476 tests | 0 failures | [`3e9d88c`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660) |
