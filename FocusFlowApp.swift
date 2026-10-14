import SwiftUI
import Combine
import AVFoundation
import AppKit

// MARK: - App Models
struct FocusTask: Identifiable {
    let id: UUID
    var title: String
    var estimatedMinutes: Int
    var timeSpentSeconds: Int = 0
    var icon: String
    var iconColor: Color
    var isLocked: Bool = false
    var isCompleted: Bool = false

    var expectedTime: String {
        "\(estimatedMinutes)m"
    }

    var formattedTimeSpent: String {
        let mins = timeSpentSeconds / 60
        let secs = timeSpentSeconds % 60
        if mins >= 60 {
            let hours = mins / 60
            let remMins = mins % 60
            return "\(hours)h \(remMins)m"
        } else if mins > 0 {
            return "\(mins)m"
        } else if secs > 0 {
            return "\(secs)s"
        } else {
            return "0m"
        }
    }

    var progress: Double {
        let target = max(estimatedMinutes * 60, 1)
        return min(max(Double(timeSpentSeconds) / Double(target), 0.0), 1.0)
    }

    init(id: UUID = UUID(), title: String, estimatedMinutes: Int = 25, timeSpentSeconds: Int = 0, icon: String = "checkmark.circle", iconColor: Color = .orange, isLocked: Bool = false, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.estimatedMinutes = estimatedMinutes
        self.timeSpentSeconds = timeSpentSeconds
        self.icon = icon
        self.iconColor = iconColor
        self.isLocked = isLocked
        self.isCompleted = isCompleted
    }
}
typealias StudyTask = FocusTask


// MARK: - App Entry
@main
struct FocusFlowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 850, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - View Models & State
@MainActor
class TimerViewModel: ObservableObject {
    // MARK: Focus Timer States
    @Published var timeRemaining: Int = 25 * 60
    @Published var totalTime: Int = 25 * 60
    @Published var currentSession: Int = 1
    @Published var totalSessions: Int = 4
    @Published var preciseProgress: Double = 1.0
    @Published var isTimerRunning: Bool = false
    var targetEndDate: Date?
    private var fractionalRemaining: TimeInterval?

    // Custom Duration States
    @Published var customMinutes: Int = 25
    @Published var customSeconds: Int = 0
    private var customDurationSeconds: Int = 25 * 60

    // Preset & Modes
    @Published var activePreset: String = "Focus"
    private var isBreakPreset: Bool { activePreset == "Short Break" || activePreset == "Long Break" }
    private var isFocusPreset: Bool { !isBreakPreset }

    // MARK: Stopwatch States
    @Published var stopwatchTime: Int = 0
    @Published var preciseStopwatchProgress: Double = 0.0
    @Published var isStopwatchRunning: Bool = false
    @Published var lapTimes: [String] = []
    private var stopwatchStartDate: Date?
    private var stopwatchFractional: TimeInterval?

    // Task States
    @Published var tasks: [FocusTask] = [
        FocusTask(title: "Deep Work Session", estimatedMinutes: 25, timeSpentSeconds: 0, icon: "star.fill", iconColor: .orange),
        FocusTask(title: "Project Review & Planning", estimatedMinutes: 30, timeSpentSeconds: 0, icon: "doc.text.fill", iconColor: .blue),
        FocusTask(title: "Core Development & Refactor", estimatedMinutes: 45, timeSpentSeconds: 0, icon: "laptopcomputer", iconColor: .purple),
        FocusTask(title: "Inbox & Team Follow-ups", estimatedMinutes: 15, timeSpentSeconds: 0, icon: "tray.fill", iconColor: .teal)
    ]
    @Published var activeTaskIndex: Int = 0
    @Published var completedSessions: Int = 0
    @Published var focusedSeconds: Int = 0
    @Published var notes: [String] = []
    @Published var dailyGoalHours: Int = 4

    // Alerts
    @Published var showPresetAlert: Bool = false
    @Published var showResetAlert: Bool = false
    @Published var showNoteEditor: Bool = false
    @Published var noteDraft: String = ""
    var pendingPreset: (name: String, minutes: Int)? = nil
    @Published var autoStartNextSession: Bool = false

    // Master 50Hz Timer Engine
    private var timerSubscription: AnyCancellable?

    // Active Timer Mode: "Pomodoro" or "Custom Timer"
    @Published var activeMode: String = "Pomodoro"
    var isRunning: Bool { isTimerRunning || isStopwatchRunning }

    // MARK: Mode Switching within Timer Sessions
    func changeMode(to newMode: String) {
        if isTimerRunning { stopTimer() }
        if newMode == "Pomodoro" {
            activePreset = "Focus"
            totalTime = 25 * 60
            timeRemaining = totalTime
            preciseProgress = 1.0
        } else if newMode == "Custom Timer" {
            activePreset = "Custom"
            totalTime = customDurationSeconds
            timeRemaining = totalTime
            customMinutes = totalTime / 60
            customSeconds = totalTime % 60
            preciseProgress = 1.0
        }
    }

    // MARK: Master Engine
    private func updateMasterEngine() {
        if isTimerRunning || isStopwatchRunning {
            if timerSubscription == nil {
                timerSubscription = Timer.publish(every: 0.02, on: .main, in: .common)
                    .autoconnect()
                    .sink { [weak self] _ in
                        self?.tick()
                    }
            }
        } else {
            timerSubscription?.cancel()
            timerSubscription = nil
        }
    }

    private func tick() {
        // 1. Tick Focus Timer smoothly if running
        if isTimerRunning, let target = targetEndDate {
            let remaining = target.timeIntervalSinceNow
            if remaining <= 0 {
                preciseProgress = 0.0
                let uncounted = timeRemaining
                timeRemaining = 0
                if isFocusPreset && uncounted > 0 {
                    focusedSeconds += uncounted
                    if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                        tasks[activeTaskIndex].timeSpentSeconds += uncounted
                    }
                }
                handleSessionComplete()
            } else {
                if totalTime > 0 {
                    preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
                }
                let newTime = Int(ceil(remaining))
                if timeRemaining != newTime {
                    let delta = timeRemaining - newTime
                    timeRemaining = newTime
                    if isFocusPreset && delta > 0 {
                        focusedSeconds += delta
                        if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                            tasks[activeTaskIndex].timeSpentSeconds += delta
                        }
                    }
                }
            }
        }

        // 2. Tick Stopwatch smoothly if running
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if stopwatchTime != newTime {
                let delta = newTime - stopwatchTime
                stopwatchTime = newTime
                if delta > 0 && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                    focusedSeconds += delta
                }
            }
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
    }

    // MARK: Focus Timer Core Controls
    func startTimer() {
        guard !isTimerRunning else { return }
        isTimerRunning = true
        let remainingInterval = fractionalRemaining ?? TimeInterval(timeRemaining)
        targetEndDate = Date().addingTimeInterval(remainingInterval)
        preciseProgress = totalTime > 0 ? min(max(remainingInterval / Double(totalTime), 0.0), 1.0) : 1.0
        fractionalRemaining = nil
        updateMasterEngine()
    }

    func stopTimer() {
        if isTimerRunning, let target = targetEndDate {
            let remaining = max(0, target.timeIntervalSinceNow)
            fractionalRemaining = remaining
            let newRemaining = max(Int(ceil(remaining)), 0)
            if isFocusPreset, newRemaining < timeRemaining {
                let delta = timeRemaining - newRemaining
                focusedSeconds += delta
                if tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                }
            }
            timeRemaining = newRemaining
            if totalTime > 0 {
                preciseProgress = min(max(remaining / Double(totalTime), 0.0), 1.0)
            }
        }
        isTimerRunning = false
        targetEndDate = nil
        updateMasterEngine()
    }

    func toggleTimer() {
        if isTimerRunning {
            stopTimer()
        } else {
            startTimer()
        }
    }

    func resetFocusTimer() {
        stopTimer()
        fractionalRemaining = nil
        timeRemaining = totalTime
        preciseProgress = 1.0
    }

    func resetTimer() {
        resetFocusTimer()
    }

    // MARK: Stopwatch Core Controls
    func startStopwatch() {
        guard !isStopwatchRunning else { return }
        isStopwatchRunning = true
        let offset = stopwatchFractional ?? TimeInterval(stopwatchTime)
        stopwatchStartDate = Date().addingTimeInterval(-offset)
        preciseStopwatchProgress = (offset.truncatingRemainder(dividingBy: 60.0)) / 60.0
        stopwatchFractional = nil
        updateMasterEngine()
    }

    func stopStopwatch() {
        if isStopwatchRunning, let start = stopwatchStartDate {
            let elapsed = Date().timeIntervalSince(start)
            let newTime = max(Int(elapsed), 0)
            if newTime > stopwatchTime {
                let delta = newTime - stopwatchTime
                if delta > 0 && tasks.indices.contains(activeTaskIndex) && !tasks[activeTaskIndex].isCompleted {
                    tasks[activeTaskIndex].timeSpentSeconds += delta
                    focusedSeconds += delta
                }
            }
            stopwatchFractional = elapsed
            stopwatchTime = newTime
            preciseStopwatchProgress = (elapsed.truncatingRemainder(dividingBy: 60.0)) / 60.0
        }
        isStopwatchRunning = false
        stopwatchStartDate = nil
        updateMasterEngine()
    }

    func toggleStopwatch() {
        if isStopwatchRunning {
            stopStopwatch()
        } else {
            startStopwatch()
        }
    }

    func resetStopwatch() {
        stopStopwatch()
        stopwatchFractional = nil
        stopwatchTime = 0
        lapTimes.removeAll()
        preciseStopwatchProgress = 0.0
    }

    func recordLap() {
        lapTimes.insert(stopwatchTimeString, at: 0)
    }

    func requestReset(isStopwatch: Bool = false) {
        if isStopwatch {
            if stopwatchTime > 0 {
                showResetAlert = true
            } else {
                resetStopwatch()
            }
        } else {
            if timeRemaining < totalTime {
                showResetAlert = true
            } else {
                resetFocusTimer()
            }
        }
    }

    func recordLapOrNote(isStopwatch: Bool = false) {
        if isStopwatch {
            recordLap()
        } else {
            noteDraft = ""
            showNoteEditor = true
        }
    }
    
    func addTask(title: String = "New Task", expectedMinutes: Int = 25) {
        let newTask = FocusTask(title: title, estimatedMinutes: expectedMinutes, icon: "checkmark.circle", iconColor: .cyan)
        tasks.append(newTask)
        if tasks.count == 1 || !tasks.indices.contains(activeTaskIndex) || tasks[activeTaskIndex].isCompleted {
            activeTaskIndex = tasks.count - 1
        }
    }

    func selectTask(at index: Int) {
        guard tasks.indices.contains(index), !tasks[index].isCompleted else { return }
        activeTaskIndex = index
    }

    func toggleTaskCompletion(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].isCompleted.toggle()
        if activeTaskIndex == index && tasks[index].isCompleted {
            advanceToNextAvailableTask(after: index)
        }
    }

    func removeTask(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks.remove(at: index)
        if tasks.isEmpty {
            activeTaskIndex = 0
        } else if index < activeTaskIndex {
            activeTaskIndex -= 1
        } else if activeTaskIndex >= tasks.count {
            activeTaskIndex = tasks.count - 1
        }
    }

    func resetTaskTime(at index: Int) {
        guard tasks.indices.contains(index) else { return }
        tasks[index].timeSpentSeconds = 0
    }

    func saveNote() {
        let trimmed = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notes.insert(trimmed, at: 0)
        noteDraft = ""
        showNoteEditor = false
    }

    func removeLap(at index: Int) {
        guard lapTimes.indices.contains(index) else { return }
        lapTimes.remove(at: index)
    }
    
    func requestPresetChange(name: String, minutes: Int) {
        guard minutes > 0 else { return }
        if timeRemaining < totalTime {
            pendingPreset = (name, minutes)
            showPresetAlert = true
        } else {
            applyPreset(name: name, minutes: minutes)
        }
    }

    func setCustomDuration(minutes: Int, seconds: Int) {
        let safeM = max(0, min(minutes, 360))
        let safeS = max(0, min(seconds, 59))
        let total = max(5, safeM * 60 + safeS)
        
        customMinutes = total / 60
        customSeconds = total % 60
        customDurationSeconds = total
        
        if isTimerRunning { stopTimer() }
        fractionalRemaining = nil
        activeMode = "Custom Timer"
        activePreset = "Custom"
        totalTime = total
        timeRemaining = total
        preciseProgress = 1.0
    }

    func adjustCustomDuration(by minutes: Int) {
        guard !isTimerRunning else { return }
        let currentTotal = totalTime
        let newTotal = min(max(currentTotal + minutes * 60, 5), 360 * 60)
        customDurationSeconds = newTotal
        customMinutes = newTotal / 60
        customSeconds = newTotal % 60
        activeMode = "Custom Timer"
        activePreset = "Custom"
        totalTime = newTotal
        timeRemaining = newTotal
        preciseProgress = 1.0
    }
    
    func applyPendingPreset() {
        if let preset = pendingPreset {
            applyPreset(name: preset.name, minutes: preset.minutes)
            pendingPreset = nil
        }
    }

    func cancelPendingPreset() {
        pendingPreset = nil
    }
    
    private func applyPreset(name: String, minutes: Int) {
        stopTimer()
        fractionalRemaining = nil
        activeMode = "Pomodoro"
        activePreset = name
        totalTime = minutes * 60
        timeRemaining = totalTime
        preciseProgress = 1.0
    }
    
    // MARK: Session Flow
    func skipSession() {
        stopTimer()
        fractionalRemaining = nil
        if isBreakPreset {
            applyPreset(name: "Focus", minutes: 25)
        } else {
            advanceSession()
        }
    }
    
    private func handleSessionComplete() {
        stopTimer()
        fractionalRemaining = nil
        
        // Completion chime (native macOS alert sound)
        if let chime = NSSound(named: NSSound.Name("Glass")) {
            chime.play()
        } else {
            NSSound.beep()
        }

        if isFocusPreset {
            completedSessions += 1
            if tasks.indices.contains(activeTaskIndex) {
                tasks[activeTaskIndex].isCompleted = true
                advanceToNextAvailableTask(after: activeTaskIndex)
            }

            let isFinalSession = currentSession >= totalSessions
            currentSession = isFinalSession ? (autoStartNextSession ? currentSession : 1) : currentSession + 1
            let nextBreakPreset = isFinalSession ? "Long Break" : "Short Break"
            let nextBreakMinutes = isFinalSession ? 15 : 5

            applyPreset(name: nextBreakPreset, minutes: nextBreakMinutes)
            if autoStartNextSession {
                startTimer()
            }
            return
        } else {
            if activePreset == "Long Break" {
                currentSession = 1
            }
            applyPreset(name: "Focus", minutes: 25)
            if autoStartNextSession {
                startTimer()
            }
            return
        }
    }
    
    private func advanceSession() {
        if currentSession < totalSessions {
            currentSession += 1
        } else {
            currentSession = 1
        }
        
        // Advance to next task if available
        advanceToNextAvailableTask(after: activeTaskIndex)
        
        timeRemaining = totalTime
        preciseProgress = 1.0
    }

    private func advanceToNextAvailableTask(after index: Int) {
        guard !tasks.isEmpty else { activeTaskIndex = 0; return }
        for offset in 1...tasks.count {
            let candidate = (max(index, -1) + offset) % tasks.count
            if !tasks[candidate].isCompleted {
                activeTaskIndex = candidate
                return
            }
        }
        activeTaskIndex = -1
    }
    
    // MARK: UI Helpers
    var timerTimeString: String {
        let minutes = timeRemaining / 60
        let seconds = timeRemaining % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var stopwatchTimeString: String {
        let minutes = stopwatchTime / 60
        let seconds = stopwatchTime % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var timeString: String {
        timerTimeString
    }

    var formattedCustomDuration: String {
        let m = totalTime / 60
        let s = totalTime % 60
        if m > 0 && s > 0 {
            return "\(m)m \(s)s"
        } else if m > 0 {
            return "\(m) min"
        } else {
            return "\(s)s"
        }
    }
    
    var fillAmount: Double {
        preciseProgress
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = TimerViewModel()
    @StateObject private var audioPlayer = AmbientAudioPlayer()
    @State private var sidebarSelection: String = "Focus Timer"
    @State private var isFocusState = false
    @State private var showingWorkspace = false
    @AppStorage("clockStyle") private var clockStyle = "Digital"
    
    let bgMain = Color(red: 0.08, green: 0.09, blue: 0.13)
    let bgSidebar = Color(red: 0.11, green: 0.12, blue: 0.16)
    let accentGradient = LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    
    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                
                ZStack {
                    if sidebarSelection == "Focus Timer" {
                        DashboardTimerView(
                            viewModel: viewModel,
                            gradient: accentGradient,
                            clockStyle: $clockStyle,
                            isFocusState: $isFocusState,
                            showingWorkspace: $showingWorkspace,
                            isStopwatchMode: false,
                            onSwitchToStopwatch: {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    sidebarSelection = "Stopwatch & Laps"
                                }
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                        ))
                    } else if sidebarSelection == "Stopwatch & Laps" {
                        DashboardTimerView(
                            viewModel: viewModel,
                            gradient: accentGradient,
                            clockStyle: $clockStyle,
                            isFocusState: $isFocusState,
                            showingWorkspace: $showingWorkspace,
                            isStopwatchMode: true,
                            onSwitchToTimer: {
                                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                    sidebarSelection = "Focus Timer"
                                }
                            }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                        ))
                    } else {
                        VStack(spacing: 0) {
                            // Persistent Mini Bar if Focus Timer is running or active
                            if viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime {
                                PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer) {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                        sidebarSelection = "Focus Timer"
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            // Persistent Mini Bar if Stopwatch is running or has elapsed time
                            if viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0 {
                                PersistentCrossModeMiniBar(viewModel: viewModel, type: .stopwatch) {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                        sidebarSelection = "Stopwatch & Laps"
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.top, (viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime) ? 4 : 14)
                                .padding(.bottom, 6)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            selectedPage
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985)),
                            removal: .opacity
                        ))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(bgMain)
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: sidebarSelection)

            if isFocusState {
                FocusStateView(viewModel: viewModel, clockStyle: $clockStyle, isPresented: $isFocusState, isStopwatch: sidebarSelection == "Stopwatch & Laps")
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
                    .zIndex(100)
            }
        }
        .animation(.spring(response: 0.40, dampingFraction: 0.80), value: isFocusState)
        .background(bgMain)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showingWorkspace) {
            RightPanelView(viewModel: viewModel, showLaps: sidebarSelection == "Stopwatch & Laps")
                .frame(minWidth: 390, idealWidth: 430, minHeight: 520)
                .background(bgMain)
        }
    }

    private var sidebar: some View {
        SidebarView(gradient: accentGradient, selection: $sidebarSelection, viewModel: viewModel)
            .frame(width: 252)
            .background(bgSidebar)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch sidebarSelection {
        case "Tasks", "Study Tasks": TasksView(viewModel: viewModel)
        case "Focus Soundscapes": SoundscapesView(audioPlayer: audioPlayer)
        case "Insights & Stats": InsightsView(viewModel: viewModel)
        default: SettingsView(viewModel: viewModel)
        }
    }
}

// MARK: - Sidebar View
struct SidebarView: View {
    let gradient: LinearGradient
    @Binding var selection: String
    @ObservedObject var viewModel: TimerViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(gradient)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("FocusFlow")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("FOCUS SPACE")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(.gray)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WORKSPACE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    SidebarItem(
                        icon: "hourglass",
                        title: "Focus Timer",
                        badge: (viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime) ? viewModel.timerTimeString : nil,
                        isSelected: selection == "Focus Timer",
                        gradient: gradient
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Focus Timer"
                        }
                    }

                    SidebarItem(
                        icon: "stopwatch",
                        title: "Stopwatch & Laps",
                        badge: (viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0) ? viewModel.stopwatchTimeString : nil,
                        isSelected: selection == "Stopwatch & Laps",
                        gradient: gradient
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Stopwatch & Laps"
                        }
                    }

                    SidebarItem(
                        icon: "checklist",
                        title: "Tasks",
                        badge: viewModel.tasks.isEmpty ? nil : "\(viewModel.tasks.filter(\.isCompleted).count)/\(viewModel.tasks.count)",
                        isSelected: selection == "Tasks" || selection == "Study Tasks"
                    ) {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Tasks"
                        }
                    }
                    SidebarItem(icon: "headphones", title: "Focus Soundscapes", isSelected: selection == "Focus Soundscapes") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Focus Soundscapes"
                        }
                    }
                    SidebarItem(icon: "chart.bar", title: "Insights & Stats", isSelected: selection == "Insights & Stats") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Insights & Stats"
                        }
                    }
                    SidebarItem(icon: "gearshape", title: "Settings", isSelected: selection == "Settings") {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            selection = "Settings"
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            DailyProgressWidget(gradient: gradient, focusedSeconds: viewModel.focusedSeconds, goalHours: viewModel.dailyGoalHours)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 18)
        }
    }
}

// MARK: - Persistent Cross-Mode Mini Bar
struct PersistentCrossModeMiniBar: View {
    enum BarType {
        case focusTimer
        case stopwatch
    }

    @ObservedObject var viewModel: TimerViewModel
    let type: BarType
    var onSwitch: () -> Void

    @State private var isBarHovered = false
    @State private var isPlayHovered = false
    @State private var isSwitchHovered = false

    private var barColor: Color {
        switch type {
        case .focusTimer:
            return viewModel.activePreset.contains("Break") ? .teal : .orange
        case .stopwatch:
            return .cyan
        }
    }

    private var icon: String {
        switch type {
        case .focusTimer:
            return viewModel.activePreset.contains("Break") ? "cup.and.saucer.fill" : "flame.fill"
        case .stopwatch:
            return "stopwatch.fill"
        }
    }

    private var label: String {
        switch type {
        case .focusTimer:
            return "\(viewModel.activePreset.uppercased()) SESSION ACTIVE"
        case .stopwatch:
            return "STOPWATCH ACTIVE"
        }
    }

    private var timeText: String {
        switch type {
        case .focusTimer:
            return viewModel.timerTimeString
        case .stopwatch:
            return viewModel.stopwatchTimeString
        }
    }

    private var isRunning: Bool {
        switch type {
        case .focusTimer:
            return viewModel.isTimerRunning
        case .stopwatch:
            return viewModel.isStopwatchRunning
        }
    }

    private var switchButtonText: String {
        switch type {
        case .focusTimer:
            return "Open Focus Timer"
        case .stopwatch:
            return "Open Stopwatch"
        }
    }

    private func triggerSwitch() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            onSwitch()
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Live Status Indicator & Session Label
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(isRunning ? barColor.opacity(0.3) : Color.gray.opacity(0.15))
                        .frame(width: 14, height: 14)
                    Circle()
                        .fill(isRunning ? barColor : Color.gray)
                        .frame(width: 8, height: 8)
                }

                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(barColor)
                    Text(label)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.0)
                        .foregroundColor(barColor)
                }
            }

            Spacer()

            // Big Live Time Display + Mini Progress if timer
            HStack(spacing: 12) {
                Text(timeText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)

                if type == .focusTimer {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [barColor, .pink], startPoint: .leading, endPoint: .trailing))
                                .frame(width: geo.size.width * max(0.001, viewModel.preciseProgress))
                                .animation(.linear(duration: 0.025), value: viewModel.preciseProgress)
                        }
                    }
                    .frame(width: 70, height: 5)
                }
            }

            Spacer()

            // Play / Pause Toggle
            Button {
                if type == .focusTimer {
                    viewModel.toggleTimer()
                } else {
                    viewModel.toggleStopwatch()
                }
            } label: {
                Image(systemName: isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.white.opacity(isPlayHovered ? 0.22 : 0.09), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(isPlayHovered ? 0.45 : 0.18), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .contentShape(Circle())
            .onHover { h in
                isPlayHovered = h
                if h { NSCursor.pointingHand.set() } else if !isBarHovered { NSCursor.arrow.set() }
            }
            .help(isRunning ? "Pause" : "Resume")

            // Switch to full screen button
            Button(action: triggerSwitch) {
                HStack(spacing: 5) {
                    Text(switchButtonText)
                        .font(.system(size: 11, weight: .bold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .background(
                    LinearGradient(colors: [barColor, barColor.opacity(0.75)], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(Color.white.opacity(isSwitchHovered ? 0.55 : 0.22), lineWidth: 1))
                .shadow(color: barColor.opacity(isSwitchHovered ? 0.55 : 0.25), radius: 6)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .onHover { h in
                isSwitchHovered = h
                if h { NSCursor.pointingHand.set() } else if !isBarHovered { NSCursor.arrow.set() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Color(red: isBarHovered ? 0.14 : 0.118, green: isBarHovered ? 0.15 : 0.128, blue: isBarHovered ? 0.21 : 0.178),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    LinearGradient(
                        colors: [
                            barColor.opacity(isBarHovered ? 0.65 : 0.38),
                            Color.white.opacity(isBarHovered ? 0.20 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isBarHovered ? 1.5 : 1
                )
        )
        .shadow(color: barColor.opacity(isBarHovered ? 0.28 : 0.10), radius: isBarHovered ? 12 : 6, y: 2)
        .scaleEffect(isBarHovered ? 1.004 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isBarHovered)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { h in
            isBarHovered = h
            if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture {
            triggerSwitch()
        }
        .help(type == .focusTimer ? "Click anywhere to open Focus Timer" : "Click anywhere to open Stopwatch")
    }
}

// Legacy wrapper
struct PersistentMiniTimerBar: View {
    @ObservedObject var viewModel: TimerViewModel
    var onReturn: () -> Void

    var body: some View {
        PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer, onSwitch: onReturn)
    }
}

// MARK: - Custom High-Contrast Confirmation Modal
struct CustomConfirmModal: View {
    let title: String
    let message: String
    let icon: String
    let iconColor: Color
    let confirmTitle: String
    let isDestructive: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var isConfirmHovered = false
    @State private var isCancelHovered = false

    private var confirmGradient: LinearGradient {
        if isDestructive {
            return LinearGradient(colors: [Color.red.opacity(0.85), Color(red: 0.85, green: 0.15, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            return LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.4, blue: 0.28)], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        ZStack {
            // Full-screen high-contrast dark scrim that completely blocks out the glowing background digits!
            Color.black.opacity(0.72)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Opaque Obsidian Modal Card
            VStack(spacing: 20) {
                // Header Icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.16))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(iconColor)
                }

                // Title & Message with Crisp Silver/White Typography
                VStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(white: 0.80))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 8)

                // Action Buttons
                HStack(spacing: 12) {
                    Button(action: onCancel) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(Color.white.opacity(isCancelHovered ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(isCancelHovered ? 0.25 : 0.12), lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onHover { h in
                        isCancelHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.escape, modifiers: [])

                    Button(action: onConfirm) {
                        Text(confirmTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(isDestructive ? .white : Color(red: 0.1, green: 0.05, blue: 0.05))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background(confirmGradient, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(isConfirmHovered ? 0.35 : 0.15), lineWidth: 1))
                            .shadow(color: isDestructive ? Color.red.opacity(isConfirmHovered ? 0.45 : 0.25) : Color.orange.opacity(isConfirmHovered ? 0.45 : 0.25), radius: 8)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .onHover { h in
                        isConfirmHovered = h
                        if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(26)
            .frame(width: 380)
            .background(
                Color(red: 0.14, green: 0.15, blue: 0.20),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.60), radius: 30, y: 12)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isConfirmHovered)
    }
}

struct SidebarItem: View {
    var icon: String
    var title: String
    var badge: String? = nil
    var isSelected: Bool
    var gradient: LinearGradient? = nil
    var action: () -> Void
    @State private var isHovered = false

    private var itemBackground: Color {
        isHovered ? Color.white.opacity(0.065) : Color.white.opacity(0.001)
    }

    private var itemBorder: Color {
        isSelected ? Color.orange.opacity(0.3) : (isHovered ? Color.white.opacity(0.12) : Color.clear)
    }

    private var itemForeground: Color {
        isSelected ? .orange : (isHovered ? .white : .gray.opacity(0.85))
    }

    private var titleForeground: Color {
        isSelected ? .white : (isHovered ? .white : .gray.opacity(0.85))
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(itemForeground)
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(titleForeground)
                    .lineLimit(1)
                    .minimumScaleFactor(0.80)
                
                Spacer()

                if let badge = badge {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(title == "Stopwatch & Laps" ? Color.cyan : Color.orange)
                            .frame(width: 5, height: 5)
                        Text(badge)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(title == "Stopwatch & Laps" ? .cyan : .orange)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background((title == "Stopwatch & Laps" ? Color.cyan : Color.orange).opacity(0.16), in: Capsule())
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9)
                            .fill((gradient ?? LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)).opacity(0.14))
                    } else {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(itemBackground)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(itemBorder, lineWidth: 1)
            )
            .shadow(color: isSelected ? .orange.opacity(0.15) : .clear, radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

struct DailyProgressWidget: View {
    let gradient: LinearGradient
    let focusedSeconds: Int
    let goalHours: Int

    private var progress: Double {
        let goal = max(goalHours * 3600, 1)
        return min(Double(focusedSeconds) / Double(goal), 1)
    }

    private var durationLabel: String {
        let minutes = focusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("DAILY FOCUS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1)
                    .foregroundColor(.gray)
                Spacer()
                Image(systemName: "flame.fill")
                    .foregroundColor(.orange)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(durationLabel)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("/ \(goalHours)h")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Spacer(minLength: 0)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(gradient).frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 6)
            Text("Keep your focus streak going")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.8))
        }
        .padding(14)
        .background(Color.white.opacity(0.02))
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}



// The dashboard owns the clock area within a unified Focus Stage; supporting information opens only when requested.
struct DashboardTimerView: View {
    @ObservedObject var viewModel: TimerViewModel
    let gradient: LinearGradient
    @Binding var clockStyle: String
    @Binding var isFocusState: Bool
    @Binding var showingWorkspace: Bool
    var isStopwatchMode: Bool = false
    var onSwitchToStopwatch: (() -> Void)? = nil
    var onSwitchToTimer: (() -> Void)? = nil

    @State private var isPresetHovered = false
    @State private var showingCustomPicker = false
    @State private var isCustomPillHovered = false

    private var primaryActionTitle: String {
        if isStopwatchMode {
            if viewModel.isStopwatchRunning { return "Pause" }
            return viewModel.stopwatchTime == 0 ? "Start" : "Resume"
        } else {
            if viewModel.isTimerRunning { return "Pause" }
            return viewModel.timeRemaining == viewModel.totalTime ? "Start" : "Resume"
        }
    }

    private var sessionTitle: String {
        if isStopwatchMode { return "Stopwatch" }
        if viewModel.activeMode == "Custom Timer" { return "Custom · \(viewModel.formattedCustomDuration)" }
        return "\(viewModel.activePreset) · \(viewModel.formattedCustomDuration)"
    }

    private var sessionIcon: String {
        isStopwatchMode ? "stopwatch" : "timer"
    }

    private var pageTitle: String {
        if isStopwatchMode { return "Stopwatch" }
        if viewModel.activeMode == "Custom Timer" { return "Custom timer" }
        if viewModel.activePreset == "Short Break" || viewModel.activePreset == "Long Break" { return "Break timer" }
        return "Focus timer"
    }

    private var pageSubtitle: String {
        if isStopwatchMode {
            return viewModel.isStopwatchRunning ? "Stopwatch in progress" : "Track exact split times & laps"
        } else {
            return viewModel.isTimerRunning ? "Session in progress" : "Make space for your next session"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 720
            let availableW = geometry.size.width
            let availableH = geometry.size.height

            // Generous responsive container width:
            // Scales smoothly up to 1340pt on wide/fullscreen monitors while maintaining elegant margins
            let stageMaxWidth: CGFloat = min(availableW - (compact ? 32 : 64), max(680, min(availableW * 0.90, 1340)))

            // Smooth responsive clock size:
            // On compact (<720h): ~255pt
            // On standard (720-900h): ~320 - 400pt
            // On large / fullscreen (>900h): ~430 - 520pt!
            let rawClockSize = min(availableW * 0.52, availableH * 0.46)
            let clockSize: CGFloat = max(255, min(rawClockSize, 520))

            // Normalized stage height: Digital, Ring, and Analog share the SAME vertical stage footprint
            // Scales gracefully on fullscreen (up to 540pt) with ZERO jumping when switching styles
            let rawStageHeight = availableH * 0.48
            let clockStageHeight: CGFloat = max(290, min(rawStageHeight, 540))

            VStack(spacing: compact ? 12 : 20) {
                // Top Header: Page Title and Navigation Shortcuts
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pageTitle)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text(pageSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) {
                            showingWorkspace = true
                        }
                    } label: {
                        Label("Workspace", systemImage: "rectangle.rightthird.inset.filled")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 104, minHeight: 38)
                    }
                    .buttonStyle(DashboardButtonStyle())

                    Button {
                        withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                            isFocusState = true
                        }
                    } label: {
                        Label("Focus State", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(minWidth: 114, minHeight: 38)
                    }
                    .buttonStyle(DashboardButtonStyle())
                }
                .frame(maxWidth: stageMaxWidth)

                // Persistent Cross-Mode Floating Mini Bar
                if isStopwatchMode {
                    if viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime {
                        PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer) {
                            onSwitchToTimer?()
                        }
                        .frame(maxWidth: stageMaxWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                } else {
                    if viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0 {
                        PersistentCrossModeMiniBar(viewModel: viewModel, type: .stopwatch) {
                            onSwitchToStopwatch?()
                        }
                        .frame(maxWidth: stageMaxWidth)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }

                Spacer(minLength: 4)

                // The Focus Stage Card: Houses the clock, preset toggles, and unified controls dock
                VStack(spacing: compact ? 16 : 24) {
                    // Stage Header: Preset selector (or Stopwatch Mode Pill) & Style segmented pills
                    HStack(spacing: 12) {
                        if isStopwatchMode {
                            HStack(spacing: 8) {
                                Image(systemName: "stopwatch.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.cyan)
                                Text("STOPWATCH MODE")
                                    .font(.system(size: 11, weight: .bold))
                                    .tracking(1.0)
                                    .foregroundColor(.cyan)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 38)
                            .background(Color.cyan.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.cyan.opacity(0.32), lineWidth: 1))
                        } else {
                            Menu {
                                Section("Timer sessions") {
                                    ForEach([("Focus", 25), ("Short Break", 5), ("Long Break", 15), ("Exam Run", 50)], id: \.0) { preset in
                                        Button { viewModel.requestPresetChange(name: preset.0, minutes: preset.1) } label: {
                                            Label("\(preset.0) · \(preset.1) min", systemImage: viewModel.activeMode == "Pomodoro" && viewModel.activePreset == preset.0 ? "checkmark" : "timer")
                                        }
                                    }
                                    Button {
                                        viewModel.changeMode(to: "Custom Timer")
                                        showingCustomPicker = true
                                    } label: {
                                        Label("Custom duration...", systemImage: "slider.horizontal.3")
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: sessionIcon)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.orange)
                                    Text(sessionTitle)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.gray)
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 38)
                                .background(
                                    Color.orange.opacity(isPresetHovered ? 0.20 : 0.12),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.orange.opacity(isPresetHovered ? 0.55 : 0.32), lineWidth: 1)
                                )
                                .contentShape(Capsule())
                            }
                            .menuStyle(.borderlessButton)
                            .contentShape(Capsule())
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isPresetHovered = hovering
                                }
                                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                            .accessibilityLabel("Session: \(sessionTitle)")

                            if viewModel.activeMode == "Custom Timer" {
                                HStack(spacing: 6) {
                                    Button {
                                        showingCustomPicker = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 11, weight: .bold))
                                            Text("Set time")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 14)
                                        .frame(minHeight: 38)
                                        .background(
                                            Color.white.opacity(isCustomPillHovered ? 0.16 : 0.08),
                                            in: Capsule()
                                        )
                                        .overlay(
                                            Capsule().stroke(Color.white.opacity(isCustomPillHovered ? 0.35 : 0.16), lineWidth: 1)
                                        )
                                        .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Capsule())
                                    .onHover { hovering in
                                        isCustomPillHovered = hovering
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                    .popover(isPresented: $showingCustomPicker, arrowEdge: .bottom) {
                                        CustomDurationPopover(viewModel: viewModel, isPresented: $showingCustomPicker)
                                    }

                                    Button { viewModel.adjustCustomDuration(by: -1) } label: {
                                        Image(systemName: "minus")
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(width: 38, height: 38)
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .disabled(viewModel.isTimerRunning || viewModel.totalTime <= 10)
                                    .buttonStyle(DashboardButtonStyle())
                                    .help("Decrease by 1 minute")

                                    Button { viewModel.adjustCustomDuration(by: 1) } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 12, weight: .bold))
                                            .frame(width: 38, height: 38)
                                            .contentShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .disabled(viewModel.isTimerRunning || viewModel.totalTime >= 360 * 60)
                                    .buttonStyle(DashboardButtonStyle())
                                    .help("Increase by 1 minute")
                                }
                            }
                        }

                        Spacer()

                        // Style Segmented Control with Full-Area Hit Testing & Hover States
                        HStack(spacing: 3) {
                            ForEach(["Digital", "Ring", "Analog"], id: \.self) { style in
                                StyleSegmentButton(
                                    title: style,
                                    icon: style == "Digital" ? "textformat.123" : (style == "Ring" ? "circle" : "clock"),
                                    isSelected: clockStyle == style
                                ) {
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                        clockStyle = style
                                    }
                                }
                            }
                        }
                        .padding(4)
                        .background(Color.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
                    }

                    // Main Clock Stage with Stable Height & Smooth Scaling
                    ClockFaceView(viewModel: viewModel, style: clockStyle, size: clockSize, isStopwatch: isStopwatchMode)
                        .frame(height: clockStageHeight)
                        .frame(maxWidth: .infinity)

                    // Unified Action Button Dock with Tactile Hover & 100% Hit Testing
                    HStack(spacing: 12) {
                        CapsuleActionButton(
                            icon: (isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? "pause.fill" : "play.fill",
                            title: primaryActionTitle,
                            isPrimary: true,
                            isCyan: isStopwatchMode
                        ) {
                            if isStopwatchMode {
                                viewModel.toggleStopwatch()
                            } else {
                                viewModel.toggleTimer()
                            }
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .frame(minWidth: 145)

                        CapsuleActionButton(
                            icon: "arrow.counterclockwise",
                            title: "Reset",
                            isPrimary: false
                        ) {
                            viewModel.requestReset(isStopwatch: isStopwatchMode)
                        }
                        .frame(minWidth: 95)

                        if !isStopwatchMode {
                            CapsuleActionButton(
                                icon: "forward.end.fill",
                                title: "Skip",
                                isPrimary: false
                            ) {
                                viewModel.skipSession()
                            }
                            .frame(minWidth: 90)
                        }

                        CapsuleActionButton(
                            icon: isStopwatchMode ? "flag" : "square.and.pencil",
                            title: isStopwatchMode ? "Lap" : "Note",
                            isPrimary: false
                        ) {
                            viewModel.recordLapOrNote(isStopwatch: isStopwatchMode)
                        }
                        .frame(minWidth: 90)
                    }
                    .frame(maxWidth: .infinity)

                    // Integrated Stopwatch Laps View
                    if isStopwatchMode {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("LAPS & SPLITS")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundColor(.gray)
                                Spacer()
                                if !viewModel.lapTimes.isEmpty {
                                    Text("\(viewModel.lapTimes.count) recorded")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.cyan)
                                }
                            }
                            .frame(maxWidth: min(560, stageMaxWidth))

                            if viewModel.lapTimes.isEmpty {
                                HStack(spacing: 8) {
                                    Image(systemName: "flag")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.6))
                                    Text("Press 'Lap' to record splits (or Space to pause)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.7))
                                }
                                .frame(maxWidth: min(560, stageMaxWidth))
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.05), lineWidth: 1))
                            } else {
                                ScrollView {
                                    VStack(spacing: 6) {
                                        ForEach(Array(viewModel.lapTimes.enumerated()), id: \.offset) { index, lapTime in
                                            HStack {
                                                HStack(spacing: 6) {
                                                    Image(systemName: "flag.fill")
                                                        .font(.system(size: 9))
                                                        .foregroundColor(index == 0 ? .cyan : .gray.opacity(0.5))
                                                    Text("Lap \(viewModel.lapTimes.count - index)")
                                                        .font(.system(size: 12, weight: index == 0 ? .semibold : .medium))
                                                        .foregroundColor(index == 0 ? .white : .gray)
                                                }
                                                Spacer()
                                                Text(lapTime)
                                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                                    .foregroundColor(index == 0 ? .cyan : .white.opacity(0.85))
                                            }
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .background(Color.white.opacity(index == 0 ? 0.05 : 0.025), in: RoundedRectangle(cornerRadius: 8))
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(index == 0 ? Color.cyan.opacity(0.25) : Color.white.opacity(0.04), lineWidth: 1))
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                                .frame(maxWidth: min(560, stageMaxWidth), maxHeight: compact ? 110 : 140)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(compact ? 20 : 28)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.white.opacity(0.02))
                        .background(
                            RadialGradient(
                                colors: [(isStopwatchMode ? Color.cyan : Color.orange).opacity((isStopwatchMode ? viewModel.isStopwatchRunning : viewModel.isTimerRunning) ? 0.038 : 0.015), Color.clear],
                                center: .center,
                                startRadius: 40,
                                endRadius: 460
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.11), Color.white.opacity(0.03)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: Color.black.opacity(0.22), radius: 24, y: 10)
                .frame(maxWidth: stageMaxWidth)

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 14 : 22)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockSize)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: stageMaxWidth)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStageHeight)
            .animation(.spring(response: 0.38, dampingFraction: 0.88), value: clockStyle)
        }
        .overlay {
            if viewModel.showPresetAlert {
                CustomConfirmModal(
                    title: "Change Preset?",
                    message: "Changing to \(viewModel.pendingPreset?.name ?? "a new preset") will end your current session progress.",
                    icon: "exclamationmark.triangle.fill",
                    iconColor: .orange,
                    confirmTitle: "Change Preset",
                    isDestructive: true,
                    onConfirm: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.applyPendingPreset()
                            viewModel.showPresetAlert = false
                        }
                    },
                    onCancel: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.cancelPendingPreset()
                            viewModel.showPresetAlert = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
            }
            if viewModel.showResetAlert {
                CustomConfirmModal(
                    title: isStopwatchMode ? "Reset Stopwatch?" : "Reset Focus Timer?",
                    message: isStopwatchMode ? "This will reset your stopwatch and clear all recorded lap splits." : "This will reset your active focus session back to the beginning.",
                    icon: "arrow.counterclockwise.circle.fill",
                    iconColor: .red,
                    confirmTitle: "Reset Session",
                    isDestructive: true,
                    onConfirm: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            if isStopwatchMode {
                                viewModel.resetStopwatch()
                            } else {
                                viewModel.resetFocusTimer()
                            }
                            viewModel.showResetAlert = false
                        }
                    },
                    onCancel: {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            viewModel.showResetAlert = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.94).combined(with: .opacity),
                    removal: .scale(scale: 0.94).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showPresetAlert)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: viewModel.showResetAlert)
        .sheet(isPresented: $viewModel.showNoteEditor) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add a focus note").font(.title2.weight(.semibold))
                TextField("What do you want to remember?", text: $viewModel.noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { viewModel.saveNote() }
                HStack {
                    Button("Cancel") { viewModel.showNoteEditor = false }
                    Spacer()
                    Button("Save Note") { viewModel.saveNote() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 400)
        }
    }
}

// Custom Duration Popover for Precision Minutes and Seconds Time Input
struct CustomDurationPopover: View {
    @ObservedObject var viewModel: TimerViewModel
    @Binding var isPresented: Bool

    @State private var minutes: Int = 25
    @State private var seconds: Int = 0
    @State private var minutesString: String = "25"
    @State private var secondsString: String = "00"

    private var totalSeconds: Int {
        minutes * 60 + seconds
    }

    private var formattedDisplay: String {
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom Duration")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("Set exact minutes and seconds")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray.opacity(0.6))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }

            // Dual Stepper Controls (Minutes & Seconds)
            HStack(spacing: 14) {
                // Minutes Box
                VStack(spacing: 6) {
                    Text("MINUTES")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            adjustMinutes(by: -5)
                        } label: {
                            Text("-5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes < 5)

                        Button {
                            adjustMinutes(by: -1)
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes <= 0)

                        TextField("25", text: $minutesString)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .textFieldStyle(.plain)
                            .frame(width: 48, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .onChange(of: minutesString) { _, newVal in
                                let digits = newVal.filter { $0.isNumber }
                                let val = min(Int(digits) ?? 0, 360)
                                minutes = val
                                if digits != newVal || val > 360 {
                                    minutesString = "\(val)"
                                }
                            }

                        Button {
                            adjustMinutes(by: 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 360)

                        Button {
                            adjustMinutes(by: 5)
                        } label: {
                            Text("+5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(minutes >= 355)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }

                // Seconds Box
                VStack(spacing: 6) {
                    Text("SECONDS")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundColor(.gray)

                    HStack(spacing: 6) {
                        Button {
                            adjustSeconds(by: -10)
                        } label: {
                            Text("-10")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(seconds < 10 && minutes == 0)

                        Button {
                            adjustSeconds(by: -5)
                        } label: {
                            Text("-5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(seconds <= 0 && minutes == 0)

                        TextField("00", text: $secondsString)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .textFieldStyle(.plain)
                            .frame(width: 44, height: 32)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .onChange(of: secondsString) { _, newVal in
                                let digits = newVal.filter { $0.isNumber }
                                let val = min(Int(digits) ?? 0, 59)
                                seconds = val
                                if digits != newVal || val > 59 {
                                    secondsString = String(format: "%02d", val)
                                }
                            }

                        Button {
                            adjustSeconds(by: 5)
                        } label: {
                            Text("+5")
                                .font(.system(size: 11, weight: .bold))
                                .frame(width: 26, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)

                        Button {
                            adjustSeconds(by: 10)
                        } label: {
                            Text("+10")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 28, height: 32)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06), lineWidth: 1))
                }
            }

            // Quick Preset Chips
            VStack(alignment: .leading, spacing: 6) {
                Text("QUICK PRESETS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.0)
                    .foregroundColor(.gray)

                HStack(spacing: 6) {
                    ForEach([("30s", 0, 30), ("1m", 1, 0), ("5m", 5, 0), ("10m", 10, 0), ("15m", 15, 0), ("25m", 25, 0), ("45m", 45, 0), ("60m", 60, 0)], id: \.0) { chip in
                        Button {
                            selectQuickPreset(min: chip.1, sec: chip.2)
                        } label: {
                            Text(chip.0)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(minutes == chip.1 && seconds == chip.2 ? .orange : .white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    minutes == chip.1 && seconds == chip.2 ? Color.orange.opacity(0.18) : Color.white.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(minutes == chip.1 && seconds == chip.2 ? Color.orange.opacity(0.4) : Color.white.opacity(0.08), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Preview & Actions
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    Text(formattedDisplay)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.04), in: Capsule())

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .buttonStyle(DashboardButtonStyle())

                Button {
                    viewModel.setCustomDuration(minutes: minutes, seconds: seconds)
                    isPresented = false
                } label: {
                    Text("Apply & Set Timer")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.1, green: 0.05, blue: 0.05))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.4, blue: 0.28)], startPoint: .leading, endPoint: .trailing),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(totalSeconds < 5)
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(width: 440)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .onAppear {
            let total = viewModel.totalTime
            minutes = total / 60
            seconds = total % 60
            minutesString = "\(minutes)"
            secondsString = String(format: "%02d", seconds)
        }
    }

    private func adjustMinutes(by delta: Int) {
        minutes = max(0, min(minutes + delta, 360))
        minutesString = "\(minutes)"
    }

    private func adjustSeconds(by delta: Int) {
        let newSec = seconds + delta
        if newSec < 0 {
            if minutes > 0 {
                minutes -= 1
                minutesString = "\(minutes)"
                seconds = 60 + newSec
            } else {
                seconds = 0
            }
        } else if newSec >= 60 {
            minutes = min(360, minutes + (newSec / 60))
            minutesString = "\(minutes)"
            seconds = newSec % 60
        } else {
            seconds = newSec
        }
        secondsString = String(format: "%02d", seconds)
    }

    private func selectQuickPreset(min: Int, sec: Int) {
        minutes = min
        seconds = sec
        minutesString = "\(min)"
        secondsString = String(format: "%02d", sec)
    }
}

// Dedicated Style Segment Button with 100% Hit Testing & Tactile Hover State
struct StyleSegmentButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : (isHovered ? .white : .gray))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .background(
                Capsule()
                    .fill(
                        isSelected ?
                        Color.white.opacity(0.14) :
                        (isHovered ? Color.white.opacity(0.08) : Color.white.opacity(0.001))
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected ? Color.white.opacity(0.20) :
                        (isHovered ? Color.white.opacity(0.14) : Color.clear),
                        lineWidth: 1
                    )
            )
            .shadow(color: isSelected ? Color.white.opacity(0.08) : Color.clear, radius: 4)
            .scaleEffect(isHovered && !isSelected ? 1.03 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// Unified Modern Capsule Action Button with Full Hit-Testing and Rich Hover Glow
struct CapsuleActionButton: View {
    var icon: String
    var title: String
    var isPrimary: Bool = false
    var isCyan: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    private var primaryGradient: LinearGradient {
        if isCyan {
            return LinearGradient(colors: [Color.cyan, Color(red: 0.0, green: 0.65, blue: 0.95)], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [Color.orange, Color(red: 1.0, green: 0.38, blue: 0.28)], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var primaryShadowColor: Color {
        if isCyan {
            return Color.cyan.opacity(isHovered ? 0.55 : 0.38)
        } else {
            return Color.orange.opacity(isHovered ? 0.55 : 0.38)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundColor(isPrimary ? Color(red: 0.10, green: 0.05, blue: 0.05) : (isHovered ? .white : Color.white.opacity(0.92)))
            .padding(.horizontal, isPrimary ? 24 : 18)
            .frame(minHeight: 46)
            .background(
                Group {
                    if isPrimary {
                        Capsule().fill(primaryGradient)
                    } else {
                        Capsule().fill(Color.white.opacity(isHovered ? 0.11 : 0.045))
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(
                        isPrimary ? Color.white.opacity(isHovered ? 0.38 : 0.25) : Color.white.opacity(isHovered ? 0.22 : 0.09),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary ? primaryShadowColor : (isHovered ? Color.white.opacity(0.06) : Color.clear),
                radius: isHovered ? 14 : 10,
                y: 3
            )
            .scaleEffect(isHovered ? 1.025 : 1.0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// Upgraded DashboardButtonStyle with Full-Area Hit Testing, Hover Glow, and Pointer Cursor
struct DashboardButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        DashboardButtonBody(configuration: configuration, selected: selected)
    }

    private struct DashboardButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minHeight: 40)
                .foregroundColor(selected ? .orange : (isHovered ? .white : .white.opacity(0.82)))
                .padding(.horizontal, 14)
                .background(
                    selected ? Color.orange.opacity(0.18) :
                    Color.white.opacity(configuration.isPressed ? 0.15 : (isHovered ? 0.10 : 0.05)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            selected ? Color.orange.opacity(0.45) :
                            (isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.08)),
                            lineWidth: 1
                        )
                )
                .shadow(color: isHovered ? (selected ? Color.orange.opacity(0.25) : Color.white.opacity(0.05)) : Color.clear, radius: 6)
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.98 : (isHovered ? 1.02 : 1.0))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
        }
    }
}

// Upgraded PrimaryDashboardButtonStyle with Hover Feedback and Pointer Cursor
struct PrimaryDashboardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryDashboardButtonBody(configuration: configuration)
    }

    private struct PrimaryDashboardButtonBody: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(minHeight: 46)
                .foregroundColor(Color(red: 0.10, green: 0.05, blue: 0.05))
                .padding(.horizontal, 22)
                .background(
                    LinearGradient(colors: [.orange, Color(red: 1.0, green: 0.38, blue: 0.28)], startPoint: .leading, endPoint: .trailing),
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
                )
                .shadow(color: Color.orange.opacity(isHovered ? 0.55 : 0.35), radius: isHovered ? 12 : 8, y: 2)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.02 : 1.0))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
        }
    }
}

// Clock Face Dispatcher
struct ClockFaceView: View {
    @ObservedObject var viewModel: TimerViewModel
    let style: String
    let size: CGFloat
    var minimal = false
    var isStopwatch: Bool = false

    var body: some View {
        Group {
            switch style {
            case "Analog":
                AnalogDialView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            case "Ring":
                RingClockView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            default:
                DigitalClockView(viewModel: viewModel, size: size, minimal: minimal, isStopwatch: isStopwatch)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.84), value: style)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isStopwatch ? "Stopwatch, \(viewModel.stopwatchTimeString)" : "\(viewModel.activePreset), \(viewModel.timerTimeString)")
    }
}

// Digital Clock Face with Smooth Scaling for Fullscreen
struct DigitalClockView: View {
    @ObservedObject var viewModel: TimerViewModel
    let size: CGFloat
    var minimal: Bool = false
    var isStopwatch: Bool = false

    private var subtitle: String {
        if isStopwatch { return "STOPWATCH" }
        return viewModel.activePreset.uppercased()
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    var body: some View {
        VStack(spacing: max(10, size * 0.03)) {
            if !minimal {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isStopwatch ? Color.cyan : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(subtitle)
                        .font(.system(size: max(11, min(16, size * 0.032)), weight: .bold))
                        .tracking(2.2)
                        .foregroundColor(isStopwatch ? .cyan : .orange)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background((isStopwatch ? Color.cyan : Color.orange).opacity(0.12), in: Capsule())
            }

            Text(timeDisplay)
                .font(.system(size: min(size * 0.38, 205), weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(isRunning ? 0.35 : 0.0), radius: 28)

            if !minimal && !isStopwatch && viewModel.tasks.indices.contains(viewModel.activeTaskIndex) {
                let task = viewModel.tasks[viewModel.activeTaskIndex]
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: max(11, min(14, size * 0.026))))
                        .foregroundColor(.orange)
                    Text(task.title)
                        .font(.system(size: max(12, min(17, size * 0.034)), weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                    Text("·")
                        .foregroundColor(.gray.opacity(0.6))
                    Text("\(task.formattedTimeSpent) spent")
                        .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold, design: .rounded))
                        .foregroundColor(.orange)
                }
                .lineLimit(1)
                .frame(maxWidth: min(size * 1.4, 720))
            }

            if !minimal && !isStopwatch {
                VStack(spacing: 8) {
                    GeometryReader { bar in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule()
                                .fill(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing))
                                .frame(width: bar.size.width * max(0.001, viewModel.preciseProgress))
                                .shadow(color: .orange.opacity(0.4), radius: 4)
                                .animation(.linear(duration: 0.025), value: viewModel.preciseProgress)
                        }
                    }
                    .frame(width: min(size * 1.30, 720), height: max(6, min(10, size * 0.018)))

                    HStack {
                        Text("\(Int(viewModel.preciseProgress * 100))% completed")
                            .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold))
                            .foregroundColor(.gray)
                        Spacer()
                        Text(viewModel.timeRemaining >= 60 ? "\(viewModel.timeRemaining / 60) min remaining" : "\(viewModel.timeRemaining)s remaining")
                            .font(.system(size: max(11, min(14, size * 0.026)), weight: .semibold))
                            .foregroundColor(.gray)
                    }
                    .frame(width: min(size * 1.30, 720))
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}

// Ring Clock Face with Smooth Scaling for Fullscreen
struct RingClockView: View {
    @ObservedObject var viewModel: TimerViewModel
    let size: CGFloat
    var minimal: Bool = false
    var isStopwatch: Bool = false

    private var subtitle: String {
        if isStopwatch { return "STOPWATCH" }
        return viewModel.activePreset.uppercased()
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var progress: Double {
        isStopwatch ? viewModel.preciseStopwatchProgress : viewModel.preciseProgress
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    var body: some View {
        let strokeWidth: CGFloat = max(12, min(28, size * 0.045))
        let ringDiameter = size * 0.85

        ZStack {
            // Background track
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: strokeWidth)
                .frame(width: ringDiameter, height: ringDiameter)

            // Dynamic progress ring with continuous 60fps flowing sweep
            Circle()
                .trim(from: 0, to: max(0.0008, progress))
                .stroke(
                    LinearGradient(
                        colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color.pink],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: ringDiameter, height: ringDiameter)
                .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(isRunning ? 0.45 : 0.2), radius: 8)
                .animation(.linear(duration: 0.025), value: progress)

            // Center Content
            VStack(spacing: max(6, size * 0.022)) {
                if !minimal {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isStopwatch ? Color.cyan : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(subtitle)
                            .font(.system(size: max(11, min(15, size * 0.032)), weight: .bold))
                            .tracking(2)
                            .foregroundColor(isStopwatch ? .cyan : .orange)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background((isStopwatch ? Color.cyan : Color.orange).opacity(0.12), in: Capsule())
                }

                Text(timeDisplay)
                    .font(.system(size: min(size * 0.24, 135), weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                if !minimal && !isStopwatch && viewModel.tasks.indices.contains(viewModel.activeTaskIndex) {
                    let task = viewModel.tasks[viewModel.activeTaskIndex]
                    VStack(spacing: 2) {
                        Text(task.title)
                            .font(.system(size: max(11, min(15, size * 0.030)), weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                        Text("\(task.formattedTimeSpent) spent · \(task.expectedTime) est.")
                            .font(.system(size: max(10, min(12, size * 0.024)), weight: .semibold, design: .rounded))
                            .foregroundColor(.orange)
                    }
                    .frame(maxWidth: size * 0.68)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}

// Precision Horology Analog Dial with Smooth Scaling for Fullscreen
struct AnalogDialView: View {
    @ObservedObject var viewModel: TimerViewModel
    let size: CGFloat
    var minimal: Bool = false
    var isStopwatch: Bool = false

    private var scaleMinutes: Int {
        isStopwatch ? 60 : max(60, Int(ceil(Double(viewModel.totalTime) / 3600)) * 60)
    }

    private var progress: Double {
        if isStopwatch {
            return viewModel.preciseStopwatchProgress
        }
        let total = Double(max(scaleMinutes * 60, 1))
        guard let target = viewModel.targetEndDate, viewModel.isTimerRunning else {
            return min(max(Double(viewModel.timeRemaining) / total, 0), 1)
        }
        return min(max(target.timeIntervalSinceNow / total, 0), 1)
    }

    private var timeDisplay: String {
        isStopwatch ? viewModel.stopwatchTimeString : viewModel.timerTimeString
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    var body: some View {
        let dialDiameter = size * 0.88

        VStack(spacing: max(10, size * 0.024)) {
            ZStack {
                // Outer Bezel & Subtle Depth
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(red: 0.12, green: 0.13, blue: 0.18), Color(red: 0.07, green: 0.075, blue: 0.10)],
                            center: .center,
                            startRadius: 0,
                            endRadius: dialDiameter * 0.5
                        )
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.20), Color.white.opacity(0.04), Color.white.opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: max(2, dialDiameter * 0.006)
                            )
                    )
                    .frame(width: dialDiameter, height: dialDiameter)

                // Concentric Interior Track Grooves
                Circle()
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                    .frame(width: dialDiameter * 0.84, height: dialDiameter * 0.84)
                Circle()
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                    .frame(width: dialDiameter * 0.44, height: dialDiameter * 0.44)

                // Luminous Active Countdown / Elapsed Arc along Track
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        LinearGradient(
                            colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color.pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: max(3.5, dialDiameter * 0.012), lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: dialDiameter * 0.84, height: dialDiameter * 0.84)
                    .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.45), radius: 6)
                    .animation(.linear(duration: 0.025), value: progress)

                // 60-Minute Precision Tick Marks
                ForEach(0..<60, id: \.self) { mark in
                    let isMajor = mark.isMultiple(of: 5)
                    Capsule()
                        .fill(isMajor ? Color.white.opacity(0.85) : Color.white.opacity(0.25))
                        .frame(
                            width: isMajor ? max(2, dialDiameter * 0.006) : max(1, dialDiameter * 0.003),
                            height: isMajor ? max(8, dialDiameter * 0.026) : max(4, dialDiameter * 0.013)
                        )
                        .offset(y: -dialDiameter * 0.42)
                        .rotationEffect(.degrees(Double(mark) * 6))
                }

                // 12-Position Numerals
                ForEach(0..<12, id: \.self) { label in
                    let angle = Double(label) * .pi / 6
                    let numRadius = dialDiameter * 0.34
                    let minuteVal = label * scaleMinutes / 12
                    Text("\(minuteVal)")
                        .font(.system(size: max(10, dialDiameter * 0.035), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(label == 0 ? (isStopwatch ? .cyan : .orange) : Color.white.opacity(0.75))
                        .position(
                            x: dialDiameter * 0.5 + sin(angle) * numRadius,
                            y: dialDiameter * 0.5 - cos(angle) * numRadius
                        )
                }

                // Horological Needle Pointer
                Group {
                    // Counterweight tail
                    Capsule()
                        .fill(Color(red: 0.18, green: 0.19, blue: 0.26))
                        .frame(width: max(3.5, dialDiameter * 0.013), height: dialDiameter * 0.08)
                        .offset(y: dialDiameter * 0.04)

                    // Slender Tapered Pointer Hand
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: isStopwatch ? [Color.cyan, Color.blue] : [Color.orange, Color(red: 1.0, green: 0.4, blue: 0.25)],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(width: max(3, dialDiameter * 0.011), height: dialDiameter * 0.25)
                        .offset(y: -dialDiameter * 0.125)
                        .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.4), radius: 6)

                    // Outer Track Pip Indicator
                    Circle()
                        .fill(isStopwatch ? Color.cyan : Color.orange)
                        .frame(width: max(6, dialDiameter * 0.018), height: max(6, dialDiameter * 0.018))
                        .offset(y: -dialDiameter * 0.42)
                        .shadow(color: (isStopwatch ? Color.cyan : Color.orange).opacity(0.6), radius: 4)
                }
                .rotationEffect(.degrees(progress * 360))
                .animation(.linear(duration: 0.025), value: progress)

                // Precision Dual-Ring Center Hub
                Circle()
                    .fill(Color(red: 0.14, green: 0.15, blue: 0.20))
                    .frame(width: max(14, dialDiameter * 0.06), height: max(14, dialDiameter * 0.06))
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                Circle()
                    .fill(isStopwatch ? Color.cyan : Color.orange)
                    .frame(width: max(6, dialDiameter * 0.024), height: max(6, dialDiameter * 0.024))
            }
            .frame(width: dialDiameter, height: dialDiameter)

            // Integrated Readout Pill
            if !minimal {
                HStack(spacing: 8) {
                    Circle()
                        .fill(isRunning ? (isStopwatch ? Color.cyan : Color.orange) : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(timeDisplay)
                        .font(.system(size: max(18, dialDiameter * 0.055), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundColor(.white)
                    Text(isStopwatch ? "ELAPSED" : "REMAINING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.4)
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: size)
    }
}

struct FocusStateView: View {
    @ObservedObject var viewModel: TimerViewModel
    @Binding var clockStyle: String
    @Binding var isPresented: Bool
    var isStopwatch: Bool = false

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    private var actionTitle: String {
        if isStopwatch {
            if viewModel.isStopwatchRunning { return "Pause" }
            return viewModel.stopwatchTime == 0 ? "Start" : "Resume"
        } else {
            if viewModel.isTimerRunning { return "Pause" }
            return viewModel.timeRemaining == viewModel.totalTime ? "Start" : "Resume"
        }
    }

    private func toggleRunning() {
        if isStopwatch {
            viewModel.toggleStopwatch()
        } else {
            viewModel.toggleTimer()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.055, green: 0.06, blue: 0.09).ignoresSafeArea()
                
                Button {
                    toggleRunning()
                } label: {
                    ClockFaceView(viewModel: viewModel, style: clockStyle, size: min(geometry.size.width * 0.72, geometry.size.height * 0.74, 680), minimal: true, isStopwatch: isStopwatch)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.40, dampingFraction: 0.80)) {
                                isPresented = false
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                Text("Exit Focus State")
                                Text("Esc")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .frame(minHeight: 40)
                        }
                        .buttonStyle(DashboardButtonStyle())
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    
                    Spacer()

                    VStack(spacing: 12) {
                        CapsuleActionButton(
                            icon: isRunning ? "pause.fill" : "play.fill",
                            title: actionTitle,
                            isPrimary: true,
                            isCyan: isStopwatch
                        ) {
                            toggleRunning()
                        }
                        .keyboardShortcut(.space, modifiers: [])
                        .frame(minWidth: 145)

                        // Clean, native macOS keyboard shortcut legend
                        HStack(spacing: 12) {
                            HStack(spacing: 5) {
                                Text("Space")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.75))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                Text(isRunning ? "to pause" : "to resume")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.50))
                            }

                            Text("·")
                                .foregroundColor(.white.opacity(0.25))

                            HStack(spacing: 5) {
                                Text("Esc")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.75))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.12), lineWidth: 1))
                                Text("to exit")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white.opacity(0.50))
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .padding(24)
            }
            .onExitCommand { isPresented = false }
        }
    }
}

struct SecondaryButton: View {
    var icon: String
    var title: String
    var action: () -> Void
    
    var body: some View {
        CapsuleActionButton(icon: icon, title: title, isPrimary: false, action: action)
    }
}

// MARK: - Right Panel View
struct RightPanelView: View {
    @ObservedObject var viewModel: TimerViewModel
    var showLaps: Bool = false
    @Environment(\.dismiss) private var dismiss
    @State private var showingAddTask = false
    @State private var newTaskTitle = ""
    @State private var newTaskMinutes = 25
    @State private var isCloseHovered = false
    @State private var isAddTaskHovered = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(showLaps ? "Stopwatch" : "Your workspace")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(.white)
                        Text(showLaps ? "Record and review your splits" : "A clear plan for this session")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    Spacer(minLength: 0)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(isCloseHovered ? .white : .gray)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(isCloseHovered ? 0.12 : 0.06), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isCloseHovered = hovering }
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help("Close workspace")
                }
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Focus Tasks")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { showingAddTask = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                            Text("Task")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(isAddTaskHovered ? 0.14 : 0.06))
                        .cornerRadius(6)
                        .foregroundColor(isAddTaskHovered ? .white : .gray)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isAddTaskHovered = hovering }
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
                
                VStack(spacing: 6) {
                    ForEach(Array(viewModel.tasks.enumerated()), id: \.element.id) { index, task in
                        let isActive = index == viewModel.activeTaskIndex && !task.isCompleted
                        let status = task.isCompleted ? "Completed" : (isActive ? "Active" : "Upcoming")
                        Button {
                            viewModel.selectTask(at: index)
                        } label: {
                            TaskRow(
                                icon: task.icon,
                                iconColor: isActive ? .orange : task.iconColor,
                                title: task.title,
                                time: task.expectedTime,
                                timeSpent: task.formattedTimeSpent,
                                progress: task.progress,
                                status: status,
                                isActive: isActive,
                                isLocked: false,
                                isCompleted: task.isCompleted
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .disabled(task.isCompleted)
                        .onHover { hovering in
                            if hovering && !task.isCompleted { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(viewModel.tasks.filter(\.isCompleted).count) of \(viewModel.tasks.count) tasks complete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.gray)
                    Spacer(minLength: 0)
                }
            }

            Divider().overlay(Color.white.opacity(0.08))

            if showLaps {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lap Times")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Newest split at the top")
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.8))
                    }
                    if viewModel.lapTimes.isEmpty {
                        emptyState(icon: "flag", title: "No laps yet", detail: "Start the stopwatch and record a split.")
                    } else {
                        VStack(spacing: 7) {
                            ForEach(Array(viewModel.lapTimes.enumerated()), id: \.offset) { index, lapTime in
                                HStack {
                                    Text("Lap \(viewModel.lapTimes.count - index)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.gray)
                                    Spacer()
                                    Text(lapTime)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.white)
                            }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset Cards")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Quick Session launches")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        PresetCard(title: "Focus", time: "(25m)", isSelected: viewModel.activePreset == "Focus") { viewModel.requestPresetChange(name: "Focus", minutes: 25) }
                        PresetCard(title: "Short Break", time: "(5m)", isSelected: viewModel.activePreset == "Short Break") { viewModel.requestPresetChange(name: "Short Break", minutes: 5) }
                        PresetCard(title: "Long Break", time: "(15m)", isSelected: viewModel.activePreset == "Long Break") { viewModel.requestPresetChange(name: "Long Break", minutes: 15) }
                        PresetCard(title: "Exam Run", time: "(50m)", isSelected: viewModel.activePreset == "Exam Run", hasSparkle: true) { viewModel.requestPresetChange(name: "Exam Run", minutes: 50) }
                    }
                }
            }
                if !viewModel.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("RECENT NOTES")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundColor(.gray)
                        ForEach(viewModel.notes.prefix(3), id: \.self) { note in
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.85))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(.horizontal, 17)
            .padding(.bottom, 22)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingAddTask) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Create a task").font(.title2.weight(.semibold))
                TextField("Task name", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                Stepper("Estimated time: \(newTaskMinutes) minutes", value: $newTaskMinutes, in: 5...180, step: 5)
                HStack {
                    Button("Cancel") { showingAddTask = false }
                    Spacer()
                    Button("Add task") {
                        viewModel.addTask(title: newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines), expectedMinutes: newTaskMinutes)
                        newTaskTitle = ""
                        newTaskMinutes = 25
                        showingAddTask = false
                    }
                    .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 410)
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20)).foregroundColor(.gray.opacity(0.7))
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            Text(detail).font(.system(size: 11)).foregroundColor(.gray).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Tasks View
struct TasksView: View {
    @ObservedObject var viewModel: TimerViewModel
    @State private var showingAddTask = false
    @State private var newTaskTitle = ""
    @State private var expectedMinutes = 25
    @State private var isAddHovered = false

    private var totalSpentLabel: String {
        let total = viewModel.tasks.reduce(0) { $0 + $1.timeSpentSeconds }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Header
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tasks")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                        Text("Choose what to focus on next and track time spent.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button {
                        newTaskTitle = ""
                        expectedMinutes = 25
                        showingAddTask = true
                    } label: {
                        Label("Add Task", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 16)
                            .frame(minHeight: 40)
                            .background(Color.orange.opacity(isAddHovered ? 0.26 : 0.16), in: Capsule())
                            .overlay(Capsule().stroke(Color.orange.opacity(isAddHovered ? 0.52 : 0.25), lineWidth: 1))
                            .foregroundColor(.orange)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) { isAddHovered = hovering }
                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                    }
                }
                .padding(.top, 30)

                // Metric Summary Cards
                HStack(spacing: 12) {
                    metricCard(title: "TOTAL TASKS", value: "\(viewModel.tasks.count)", icon: "checklist")
                    metricCard(title: "COMPLETED", value: "\(viewModel.tasks.filter(\.isCompleted).count)", icon: "checkmark.circle")
                    metricCard(title: "TIME LOGGED", value: totalSpentLabel, icon: "clock.arrow.circlepath")
                    metricCard(title: "UP NEXT", value: viewModel.tasks.indices.contains(viewModel.activeTaskIndex) ? viewModel.tasks[viewModel.activeTaskIndex].title : "Nothing queued", icon: "arrow.turn.down.right")
                }

                // Task List Cards
                VStack(spacing: 10) {
                    ForEach(Array(viewModel.tasks.enumerated()), id: \.element.id) { index, task in
                        let active = index == viewModel.activeTaskIndex && !task.isCompleted
                        
                        VStack(spacing: 8) {
                            HStack(spacing: 14) {
                                // Checkbox Toggle
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        viewModel.toggleTaskCompletion(at: index)
                                    }
                                } label: {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundColor(task.isCompleted ? .green : .gray.opacity(0.8))
                                        .frame(width: 32, height: 32)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .contentShape(Circle())
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                }

                                // Task Icon
                                Image(systemName: task.icon)
                                    .font(.system(size: 15))
                                    .foregroundColor(active ? .orange : task.iconColor)
                                    .frame(width: 22)

                                // Title and Time Info
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.title)
                                        .font(.system(size: 14, weight: active ? .semibold : .medium))
                                        .foregroundColor(task.isCompleted ? .gray : .white)
                                        .strikethrough(task.isCompleted)

                                    HStack(spacing: 8) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock")
                                                .font(.system(size: 10))
                                            Text("\(task.formattedTimeSpent) spent")
                                                .font(.system(size: 11, weight: task.timeSpentSeconds > 0 ? .semibold : .regular))
                                        }
                                        .foregroundColor(task.timeSpentSeconds > 0 ? .orange : .gray)

                                        Text("·")
                                            .foregroundColor(.gray.opacity(0.5))

                                        Text("\(task.expectedTime) est.")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray)

                                        if task.progress >= 1.0 && !task.isCompleted {
                                            Text("· Est. reached")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(.green.opacity(0.85))
                                        }
                                    }
                                }

                                Spacer()

                                // Status / Actions
                                if active {
                                    HStack(spacing: 5) {
                                        Circle().fill(Color.orange).frame(width: 6, height: 6)
                                        Text("ACTIVE")
                                            .font(.system(size: 9, weight: .bold))
                                            .tracking(0.8)
                                    }
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.orange.opacity(0.12), in: Capsule())
                                } else if !task.isCompleted {
                                    Button {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            viewModel.selectTask(at: index)
                                        }
                                    } label: {
                                        Text("Set Active")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.9))
                                            .padding(.horizontal, 12)
                                            .frame(minHeight: 32)
                                            .background(Color.white.opacity(0.08), in: Capsule())
                                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 1))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Capsule())
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                }

                                // Reset time spent button (if > 0)
                                if task.timeSpentSeconds > 0 && !task.isCompleted {
                                    Button {
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                            viewModel.resetTaskTime(at: index)
                                        }
                                    } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                            .font(.system(size: 11))
                                            .foregroundColor(.gray.opacity(0.7))
                                            .frame(width: 28, height: 28)
                                            .background(Color.white.opacity(0.04), in: Circle())
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .contentShape(Circle())
                                    .onHover { hovering in
                                        if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                    }
                                    .help("Reset time spent on this task")
                                }

                                // Delete task
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        viewModel.removeTask(at: index)
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12))
                                        .foregroundColor(.gray.opacity(0.65))
                                        .frame(width: 28, height: 28)
                                        .background(Color.white.opacity(0.04), in: Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .contentShape(Circle())
                                .onHover { hovering in
                                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                                }
                                .help("Delete task")
                            }

                            // Progress Bar for task time
                            if task.progress > 0 {
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.07))
                                        Capsule()
                                            .fill(task.isCompleted ? Color.green : (active ? Color.orange : Color.gray.opacity(0.5)))
                                            .frame(width: bar.size.width * CGFloat(task.progress))
                                    }
                                }
                                .frame(height: 3)
                                .padding(.horizontal, 4)
                            }
                        }
                        .padding(14)
                        .background(Color.white.opacity(active ? 0.055 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Color.orange.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1))
                    }
                }

                if viewModel.tasks.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "checklist").font(.system(size: 28)).foregroundColor(.gray)
                        Text("Your list is clear").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        Text("Add a task to start planning your next focus session.").font(.system(size: 12)).foregroundColor(.gray)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(30)
                    .background(Color.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showingAddTask) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create a Task")
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                    Text("Set a title and estimated focus time.")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                TextField("Task name (e.g. Design Spec, Code Review, Reading)", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTask)

                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK ESTIMATE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundColor(.gray)

                    HStack(spacing: 8) {
                        ForEach([15, 25, 45, 60, 90], id: \.self) { mins in
                            Button {
                                expectedMinutes = mins
                            } label: {
                                Text("\(mins)m")
                                    .font(.system(size: 11, weight: expectedMinutes == mins ? .bold : .medium))
                                    .foregroundColor(expectedMinutes == mins ? .orange : .white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(expectedMinutes == mins ? Color.orange.opacity(0.2) : Color.white.opacity(0.06), in: Capsule())
                                    .overlay(Capsule().stroke(expectedMinutes == mins ? Color.orange.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Stepper("Estimated time: \(expectedMinutes) minutes", value: $expectedMinutes, in: 5...360, step: 5)

                HStack {
                    Button("Cancel") { showingAddTask = false }
                    Spacer()
                    Button("Add Task", action: addTask)
                        .keyboardShortcut(.defaultAction)
                        .disabled(newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        viewModel.addTask(title: title, expectedMinutes: expectedMinutes)
        showingAddTask = false
    }

    private func metricCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(.system(size: 15)).foregroundColor(.orange)
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }
}
typealias StudyTasksView = TasksView


// MARK: - Ambient Soundscapes
@MainActor
final class AmbientAudioPlayer: ObservableObject {
    @Published private(set) var selectedSound = "Rain"
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackError: String?
    @Published var volume: Double = 0.32 {
        didSet { player?.volume = Float(volume) }
    }
    private var player: AVAudioPlayer?

    func toggle(_ sound: String) {
        if isPlaying && selectedSound == sound {
            stop()
            return
        }
        guard ["Rain", "Ocean", "Forest"].contains(sound) else { return }
        playbackError = nil
        guard let url = Bundle.main.url(forResource: sound, withExtension: "mp3", subdirectory: "Soundscapes") else {
            playbackError = "The \(sound) recording is missing from this app build."
            return
        }
        do {
            let audio = try AVAudioPlayer(contentsOf: url)
            audio.numberOfLoops = -1
            audio.volume = 0
            audio.prepareToPlay()
            guard audio.play() else {
                playbackError = "Could not play the \(sound) recording."
                return
            }
            let outgoing = player
            player = audio
            selectedSound = sound
            audio.setVolume(Float(volume), fadeDuration: 0.8)
            outgoing?.setVolume(0, fadeDuration: 0.8)
            if let outgoing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { outgoing.stop() }
            }
            isPlaying = true
        } catch {
            playbackError = "Could not open the \(sound) recording."
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

}

struct SoundscapesView: View {
    @ObservedObject var audioPlayer: AmbientAudioPlayer
    private let sounds: [(String, String, String)] = [
        ("Rain", "cloud.rain.fill", "Steady rainfall with gentle drops"),
        ("Ocean", "water.waves", "Slow surf and rolling swells"),
        ("Forest", "leaf.fill", "Breeze and distant birdsong")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Focus Soundscapes")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Choose a scene and set a comfortable volume.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, 30)

                HStack(spacing: 12) {
                    ForEach(sounds, id: \.0) { sound, icon, detail in
                        SoundscapeCard(
                            sound: sound,
                            icon: icon,
                            detail: detail,
                            isPlaying: audioPlayer.isPlaying && audioPlayer.selectedSound == sound
                        ) {
                            audioPlayer.toggle(sound)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundColor(.orange)
                        Text(audioPlayer.isPlaying ? "Playing \(audioPlayer.selectedSound)" : "Choose a soundscape to begin")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                        Spacer()
                        if audioPlayer.isPlaying {
                            Button("Stop") { audioPlayer.stop() }
                                .buttonStyle(DashboardButtonStyle())
                        }
                    }
                    if let playbackError = audioPlayer.playbackError {
                        Text(playbackError)
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    HStack(spacing: 12) {
                        Image(systemName: audioPlayer.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(.gray)
                            .frame(width: 20)
                        Slider(value: $audioPlayer.volume, in: 0...1)
                            .tint(.orange)
                            .accessibilityLabel("Soundscape volume")
                        Text("\(Int(audioPlayer.volume * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                .padding(17)
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

struct SoundscapeCard: View {
    let sound: String
    let icon: String
    let detail: String
    let isPlaying: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var strokeColor: Color {
        if isPlaying { return Color.orange.opacity(0.55) }
        return isHovered ? Color.white.opacity(0.2) : Color.white.opacity(0.06)
    }

    private var cardBackground: Color {
        isHovered ? Color.white.opacity(0.075) : Color.white.opacity(0.035)
    }

    private var statusColor: Color {
        if isPlaying { return .orange }
        return isHovered ? .white : .gray
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 6) {
                    Text(sound)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    Text(isPlaying ? "Playing" : "Play")
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusColor)
            }
            .frame(maxWidth: .infinity, minHeight: 165, alignment: .leading)
            .padding(17)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(strokeColor, lineWidth: 1))
            .shadow(color: isHovered ? (isPlaying ? Color.orange.opacity(0.25) : Color.white.opacity(0.06)) : Color.clear, radius: 8)
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Insights and Settings
struct InsightsView: View {
    @ObservedObject var viewModel: TimerViewModel

    private var completedTasks: Int { viewModel.tasks.filter(\.isCompleted).count }
    private var focusLabel: String {
        let minutes = viewModel.focusedSeconds / 60
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Insights & Stats")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Your progress since opening FocusFlow.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, 30)

                HStack(spacing: 12) {
                    insightCard(title: "FOCUS TIME", value: focusLabel, icon: "clock")
                    insightCard(title: "SESSIONS", value: "\(viewModel.completedSessions)", icon: "checkmark.circle")
                    insightCard(title: "TASKS DONE", value: "\(completedTasks)/\(viewModel.tasks.count)", icon: "checklist")
                }

                VStack(alignment: .leading, spacing: 15) {
                    Text("Daily focus goal")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(focusLabel).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(.white)
                        Text("of \(viewModel.dailyGoalHours) hours").font(.system(size: 12)).foregroundColor(.gray)
                    }
                    ProgressView(value: min(Double(viewModel.focusedSeconds) / Double(max(viewModel.dailyGoalHours * 3600, 1)), 1))
                        .tint(.orange)
                    Text("Focus time is counted while a focus or custom timer is active.")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .padding(19)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Time logged by task")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    if viewModel.tasks.isEmpty {
                        Text("No tasks added yet.")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(viewModel.tasks) { task in
                                HStack {
                                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(task.isCompleted ? .green : .gray)
                                        .font(.system(size: 13))
                                    Text(task.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(task.isCompleted ? .gray : .white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(task.formattedTimeSpent) / \(task.expectedTime)")
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundColor(task.timeSpentSeconds > 0 ? .orange : .gray)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(19)
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private func insightCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundColor(.orange)
            Text(value).font(.system(size: 20, weight: .bold)).foregroundColor(.white)
            Text(title).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: TimerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settings")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                    Text("Tune the focus cycle to fit your day.")
                        .font(.system(size: 13))
                        .foregroundColor(.gray)
                }
                .padding(.top, 30)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Sessions per cycle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("The session counter starts over after this many.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Stepper("\(viewModel.totalSessions)", value: $viewModel.totalSessions, in: 1...12)
                            .labelsHidden()
                        Text("\(viewModel.totalSessions)")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 20)
                    }
                    .padding(17)

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Daily focus goal")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Used in your daily progress and insights.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Stepper("\(viewModel.dailyGoalHours) hours", value: $viewModel.dailyGoalHours, in: 1...12)
                            .labelsHidden()
                        Text("\(viewModel.dailyGoalHours)h")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 30)
                    }
                    .padding(17)

                    Divider().overlay(Color.white.opacity(0.08))

                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Auto-start next session")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            Text("Continue the next interval when a timer ends.")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Toggle("Auto-start next session", isOn: $viewModel.autoStartNextSession)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.orange)
                    }
                    .padding(17)
                }
                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.06), lineWidth: 1))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 30)
            .frame(maxWidth: 1_050)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .onChange(of: viewModel.totalSessions) { _, newTotal in
            if viewModel.currentSession > newTotal {
                viewModel.currentSession = 1
            }
        }
    }
}

struct TaskRow: View {
    var icon: String
    var iconColor: Color
    var title: String
    var time: String
    var timeSpent: String = "0m"
    var progress: Double = 0.0
    var status: String
    var isActive: Bool
    var isLocked: Bool = false
    var isCompleted: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .rotationEffect(icon == "triangle.fill" ? .degrees(-90) : .zero)
                .foregroundColor(iconColor)
                .font(.system(size: 14))
                .frame(width: 16)
                .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title)
                        .font(.system(size: 14, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isCompleted ? .gray.opacity(0.6) : (isActive ? .white : .gray.opacity(0.85)))
                        .strikethrough(isCompleted, color: .gray.opacity(0.6))
                    Spacer()
                    Text(isLocked ? "Locked" : time)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isLocked ? .gray : (isActive ? .orange : .gray.opacity(0.65)))
                }
                
                HStack(spacing: 6) {
                    if isCompleted {
                        Text("Completed")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.green.opacity(0.85))
                        if timeSpent != "0m" {
                            Text("· \(timeSpent) logged")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    } else if isActive {
                        Text("● Active · \(timeSpent) spent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.orange)
                    } else if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 11))
                            .foregroundColor(.gray.opacity(0.65))
                        if timeSpent != "0m" {
                            Text("· \(timeSpent) spent")
                                .font(.system(size: 11))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                }

                if progress > 0 && !isCompleted {
                    GeometryReader { p in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.08))
                            Capsule().fill(isActive ? Color.orange : Color.gray.opacity(0.45))
                                .frame(width: p.size.width * CGFloat(progress))
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(isActive ? Color.orange.opacity(0.08) : Color.clear)
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isActive ? Color.orange.opacity(0.24) : Color.clear, lineWidth: 1))
    }
}

struct PresetCard: View {
    var title: String
    var time: String
    var isSelected: Bool
    var hasSparkle: Bool = false
    var action: () -> Void
    
    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? .orange : .white)
                    Text(time)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .orange.opacity(0.8) : .gray)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isSelected ? Color.orange.opacity(0.12) : Color.white.opacity(0.04))
                .cornerRadius(10)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.orange.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1))
                
                if hasSparkle {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundColor(.gray.opacity(0.4))
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(PlainButtonStyle())
    }
}
