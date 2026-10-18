# FocusFlow: Release Readiness & Verification Checklist

**Document Purpose**: Living engineering release checklist and distribution readiness assessment.
**Author**: Senior Software Engineer & Release-Readiness Reviewer
**Engineering Status Date**: 18 October 2026
**Target Distribution**: First publicly validated FocusFlow release — version to be determined

---

## 1. Verified Source Baseline

All engineering verification through Task 8 is anchored to the following independently approved baseline:

- **Verified Source Commit**: [`3e9d88c863a29cc908044e7efbcad94f0aae7660`](https://github.com/deepak-singh-jethi/FocusFlow/commit/3e9d88c863a29cc908044e7efbcad94f0aae7660)
- **Automated Test Baseline**: **476 passed, 0 failures** (executed in 10.84s).
- **CI Workflow Run**: [GitHub Actions Run #39138658657](https://github.com/deepak-singh-jethi/FocusFlow/actions/runs/39138658657) on `macos-14` (Xcode 15.4).
- **Production Compilation**: `swift build -c release` passed with zero errors.
- **Milestone Scope**: Tasks 1 through 8 completed and approved through independent source audits.
- **Documentation Notice**: Subsequent documentation-only commits update repository reference materials and will bear their own distinct Git commit SHAs while preserving this underlying source verification baseline.

---

## 2. Release-Readiness Matrix

| Functional / Release Area | Current Verification Status | Evidence / Current State | Release Gate Impact |
|---|---|---|---|
| **Core Timer Functionality** | **Automated Verification Passed** | 476 tests pass; wall-clock anchoring, sleep/wake reconciliation, and exact-once transitions verified. | Meets technical bar. |
| **Stopwatch & Lap Tracking** | **Automated Verification Passed** | Split times, lap deletion re-indexing, and `HH:mm:ss` formatting verified. | Meets technical bar. |
| **Task Time Attribution** | **Automated Verification Passed** | Strict segment settlement, unassigned time preservation, and task deletion safety verified. | Meets technical bar. |
| **Midnight & Timezone Analytics** | **Automated Verification Passed** | Calendar-day bounding and `significantTimeChangeNotification` refresh verified. | Meets technical bar. |
| **Persistence & Backup Recovery** | **Automated Verification Passed** | Atomic write-before-replace, write coalescing, and automatic `.bak` recovery verified. | Meets technical bar. |
| **Crash / Force-Quit Recovery** | **Automated Verification Passed**; Hardware QA Pending | 48 numbered scenarios plus audit/deadline suites pass (476 total tests); physical OS-level `kill -9` validation remains pending. | Requires manual QA. |
| **Release Compilation** | **Passed** | Clean release binary compiled via SPM on macOS 14. | Meets technical bar. |
| **Task 9 — Idle Time Review** | **NOT STARTED** | Planned idle-time user notification and prompt handling remains to be implemented. | **Blocks Public Release**. |
| **Physical-Mac GUI Validation** | **Pending** | Layout, animations, window transitions, and menu-bar docking require physical Mac testing. | **Blocks Public Release**. |
| **Physical Sleep/Wake Validation** | **Pending** | Hardware lid close/open across timer deadlines requires manual verification. | **Blocks Public Release**. |
| **Actual Force Quit / SIGKILL** | **Pending** | Manual termination via Activity Monitor and command line requires physical verification. | **Blocks Public Release**. |
| **Fresh Release DMG** | **Pending** | Committed preview DMG (`releases/FocusFlow-Preview-macOS14-arm64.dmg`) is from commit `da23a3ca84` and lacks Tasks 7–8 fixes. | **Blocks Public Release**. |
| **Clean-Machine Installation** | **Pending** | First-launch permissions and Gatekeeper prompt testing on unprovisioned Mac pending. | **Blocks Public Release**. |
| **Developer ID Code Signing** | **Pending** | Currently ad-hoc signed (`codesign --sign -`); requires Apple Developer ID Application certificate. | **Blocks Public Release**. |
| **Apple Gatekeeper Notarization** | **Pending** | Requires submission to Apple Notary Service via `notarytool` and ticket stapling. | **Blocks Public Release**. |
| **Final Public Release Approval** | **NOT APPROVED** | Pending completion of Task 9, manual QA sign-off, fresh DMG, and notarization. | **Release Blocked**. |

---

## 3. Next Milestone: Task 9 — Idle Time Review

**Status**: **NOT STARTED**

### High-Level Milestone Intent
Task 9 addresses user prompting and session accounting when system or application idle time occurs during active focus sessions.

### Strict Boundaries & Constraints
- Task 9 has **not yet been designed, implemented, or approved**.
- No architecture, UI mockups, detection algorithms, or threshold values are assumed in current documentation.
- Task 9 will be implemented under a separate engineering instruction prompt with dedicated unit and regression test coverage.
- Independent source review will be required before Task 9 is merged into the approved baseline.

---

## 4. Manual macOS Verification Checklist

The following tests must be performed on physical macOS hardware (macOS 14+ Sonoma on Apple Silicon) prior to release sign-off:

### Application Launch & UI Navigation
- [ ] **Fresh Launch**: Launch FocusFlow with no existing Application Support data. Verify successful initialization, correct default timer configuration, and the expected predefined sample tasks without crashes or corrupted state.
- [ ] **Primary Navigation**: Seamless switching between Focus Timer, Tasks, Insights, Soundscapes, and Settings without window jumping.
- [ ] **Menu-Bar Companion**: Status-bar icon clicks open companion popover; dock-hiding and window coordination behave consistently.
- [ ] **Fullscreen Mode**: Entry into fullscreen focus mode hides sidebar and non-essential chrome; `Esc` key cleanly exits fullscreen.

### Timer & Session Controls
- [ ] **Session Progression**: Start, pause, resume, reset, and skip controls function with precise second-by-second countdown display.
- [ ] **Preset Switching**: Switching between Pomodoro (25m), Short Break (5m), Deep Work (50m), Long Break (15m), and Custom intervals.
- [ ] **Conflict Resolution Modal**: Attempting to switch modes or presets during an active session prompts the HUD confirmation dialog; "Keep Current Session" preserves countdown.
- [ ] **Auto-Start Policy**: Verified Focus $\to$ Break and Break $\to$ Focus transitions with Auto-Start ON (timer starts immediately) and OFF (timer waits paused).
- [ ] **Custom Interval Inputs**: Stepper buttons and in-place numeric text entry accept valid values and reject invalid/negative inputs.

### Stopwatch & Laps
- [ ] **Continuous Tracking**: Elapsed timer runs smoothly with sub-second precision.
- [ ] **Hour Formatting Transition**: Elapsed time formats as `mm:ss` below one hour and dynamically transitions to `HH:mm:ss` after 3600 seconds.
- [ ] **Lap Recording**: Recording multiple laps populates the scrollable lap history with split times and lap duration metrics.
- [ ] **Lap Deletion**: Deleting intermediate laps updates sequential lap numbering (Lap 1, Lap 2, etc.) while preserving cumulative split checkpoints.

### Task Management & Attribution
- [ ] **Active Linkage**: Selecting a task links it to the active timer; focus seconds accumulate against the task in real time.
- [ ] **Task Switching Under Load**: Changing selected task while timer is running settles accumulated time to the prior task before attributing new time to the new task.
- [ ] **Task Deletion / Completion**: Deleting or completing an active task during a running timer safely dissociates subsequent time without data loss.

### Durability, Hardware Lifecycle & Fault Injection
- [ ] **Normal Quit & Relaunch**: Quitting while paused or idle restores exact timer seconds, active preset, selected task, and notes upon relaunch.
- [ ] **Physical Force Quit**: Terminating FocusFlow via macOS Activity Monitor during an active countdown restores the session in a paused state upon relaunch with checkpointed focus time preserved.
- [ ] **Isolated SIGKILL**: Terminating FocusFlow via `kill -9` in an isolated test environment restores paused session without process-downtime overcount.
- [ ] **Hardware Display Sleep**: Putting display to sleep for 5 minutes during countdown; waking display shows correct wall-clock elapsed time.
- [ ] **Lid Close Across Expiry**: Closing laptop lid before deadline and opening after deadline reconciles completion, caps focus credit at the original deadline, and transitions to break preset.
- [ ] **Midnight Boundary Crossing**: Running a session across 00:00:00 local time; Insights view correctly attributes pre-midnight time to yesterday and post-midnight time to today.
- [ ] **System Timezone Change**: Changing system timezone in System Settings triggers immediate refresh of daily and weekly analytics buckets.
- [ ] **Storage Corruption Recovery**: Intentionally corrupting `focusflow_data.json` with garbage bytes; launching FocusFlow automatically restores from `focusflow_data.json.bak`.
- [ ] **Write Error Warnings**: Setting storage directory permissions to read-only (`chmod 555`); FocusFlow displays non-intrusive warning banner without crashing.
- [ ] **Idempotent Relaunch**: Repeatedly quitting and reopening the app without active sessions does not duplicate session records or increment completed session counters.

### Audio & System Integration
- [ ] **Ambient Soundscapes**: Playback of Rain, Ocean, and Forest recordings; volume slider adjusts gain smoothly; switching scenes crossfades cleanly.
- [ ] **System Notifications**: Granting notification permissions delivers native macOS completion alerts when timers expire in the background.

---

## 5. Data-Safety Testing Precautions

> [!CAUTION]
> **Data Safety Directive**: All destructive fault-injection tests (file corruption, SIGKILL, permission locking) must be executed exclusively against disposable test accounts or custom storage directories.
>
> To isolate testing from real user data, set the custom storage directory environment variable or create an isolated backup:
> ```bash
> # Backup existing user data before testing
> cp -R ~/Library/Application\ Support/FocusFlow /tmp/FocusFlow_UserBackup_$(date +%Y%m%d%H%M%S)
> ```

---

## 6. DMG Packaging & Distribution Workflow

Following the completion of Task 9, the production distribution pipeline must execute the following sequence in strict order:

1. **Milestone Completion**: Finish Task 9 implementation, automated testing, and independent source review.
2. **Source Freeze**: Record and tag the exact verified source commit SHA on `main`.
3. **Automated Verification**: Run the full automated regression suite (`swift test --scratch-path /tmp/focusflow-build`) and confirm 476+ passing tests with 0 failures.
4. **Production Compilation**: Execute production release compilation (`swift build -c release --scratch-path /tmp/focusflow-build`).
5. **Application Bundle Assembly**: Assemble the complete `FocusFlow.app` bundle containing the freshly built release binary in `Contents/MacOS/FocusFlow` alongside valid `Contents/Info.plist`.
   > [!NOTE]
   > The existing `scripts/create_dmg.sh` currently performs an ad-hoc preview-packaging workflow (copying the release binary into a pre-existing app bundle and applying an ad-hoc signature `codesign --sign -`). It is intended solely for developer previews and must **not** be treated as a verified commercial signing and notarization pipeline.
6. **Resource & Asset Audit**: Verify that runtime application resources are fresh, complete, and properly positioned:
   - Audio soundscapes in `FocusFlow.app/Contents/Resources/Soundscapes/*.mp3`
   - Application icon in `FocusFlow.app/Contents/Resources/AppIcon.icns`
   - Bundle metadata in `FocusFlow.app/Contents/Info.plist`
   *(Note: `FocusFlow.entitlements` is a code signing configuration input, not a runtime application asset inside `Contents/Resources`.)*
7. **Developer ID Code Signing & Hardened Runtime**: Sign the assembled `FocusFlow.app` bundle using an official Apple Developer ID Application certificate, supplying `FocusFlow.entitlements` and enabling Hardened Runtime:
   ```bash
   codesign --force --options runtime --deep --sign "Developer ID Application: YourName (TeamID)" --entitlements FocusFlow.entitlements FocusFlow.app
   ```
8. **Application Signature Verification**: Verify code signature validity, certificate chain, and entitlement conformance before packaging:
   ```bash
   codesign --verify --deep --strict --verbose=2 FocusFlow.app
   spctl --assess --type execute --verbose FocusFlow.app
   ```
9. **Distribution DMG Packaging**: Package the signed, verified `FocusFlow.app` bundle into a clean, read-only UDZO compressed disk image (`FocusFlow-macOS14-arm64.dmg`).
10. **DMG Code Signing**: Sign the distribution disk image with the Developer ID Application certificate:
    ```bash
    codesign --sign "Developer ID Application: YourName (TeamID)" releases/FocusFlow-macOS14-arm64.dmg
    ```
11. **Apple Notarization**: Submit the distribution DMG to the Apple Notary Service via `notarytool`:
    ```bash
    xcrun notarytool submit releases/FocusFlow-macOS14-arm64.dmg --keychain-profile "notarytool-profile" --wait
    ```
12. **Ticket Stapling & Gatekeeper Verification**: Staple the notarization ticket to the disk image and assess Gatekeeper installation acceptance:
    ```bash
    xcrun stapler staple releases/FocusFlow-macOS14-arm64.dmg
    spctl -a -vv -t install releases/FocusFlow-macOS14-arm64.dmg
    ```
13. **Clean-Machine Installation QA**: Mount the DMG on an unprovisioned Mac without Xcode or developer tools; drag `FocusFlow.app` to `/Applications`; verify clean first launch without Gatekeeper warnings.
14. **Final Release Approval**: Review the end-to-end distribution checklist and sign off on public availability.

---

## 7. Release Acceptance Gates

FocusFlow will be approved for public distribution only when all ten gates are satisfied:

- [ ] **Gate 1**: Zero open critical data-integrity defects.
- [ ] **Gate 2**: Tasks 1 through 9 completed and independently approved.
- [ ] **Gate 3**: 100% green automated test suite across all functional domains.
- [ ] **Gate 4**: SPM production release build compiles cleanly on macOS 14+.
- [ ] **Gate 5**: Physical-Mac manual QA checklist fully executed and signed off.
- [ ] **Gate 6**: Distribution DMG built directly from the approved source commit.
- [ ] **Gate 7**: Clean-machine drag-and-drop installation verified.
- [ ] **Gate 8**: Developer ID code signing and Hardened Runtime verified.
- [ ] **Gate 9**: Apple Gatekeeper notarization confirmed and ticket stapled.
- [ ] **Gate 10**: Repository documentation synchronized to the released commit.
