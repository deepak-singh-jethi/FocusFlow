import SwiftUI

// MARK: - Main Content View (Type-Safe Navigation Coordinator)
public struct ContentView: View {
    @ObservedObject public var viewModel: TimerViewModel
    @ObservedObject public var audioPlayer: AmbientAudioPlayer
    @State private var sidebarSelection: NavigationTab = .focusTimer
    @AppStorage("isSidebarCollapsed") private var isSidebarCollapsed: Bool = false
    @State private var isFocusState = false
    @State private var showingWorkspace = false
    @AppStorage("clockStyle") private var clockStyle = "Digital"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFullScreen: Bool = false

    let bgMain = Color(red: 0.08, green: 0.09, blue: 0.13)
    let bgSidebar = Color(red: 0.11, green: 0.12, blue: 0.16)
    let accentGradient = LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    public init(viewModel: TimerViewModel? = nil, audioPlayer: AmbientAudioPlayer? = nil) {
        self.viewModel = viewModel ?? TimerViewModel()
        self.audioPlayer = audioPlayer ?? AmbientAudioPlayer()
    }

    private var hasBanner: Bool {
        viewModel.isPersistenceBlocked || viewModel.isSaveFailed || (viewModel.didRecoverFromBackup && viewModel.showRecoveryNotice)
    }

    private var topClearance: CGFloat {
        WindowLayoutMetrics.topClearance(isFullScreen: isFullScreen)
    }

    private var contentTopPadding: CGFloat {
        hasBanner ? WindowLayoutMetrics.postBannerSpacing : topClearance
    }

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar

                VStack(spacing: 0) {
                    if viewModel.isPersistenceBlocked {
                        storageErrorBanner
                    } else if viewModel.isSaveFailed {
                        saveFailureBanner
                    } else if viewModel.didRecoverFromBackup && viewModel.showRecoveryNotice {
                        recoverySuccessBanner
                    }

                    ZStack {
                        if sidebarSelection == .focusTimer {
                            DashboardTimerView(
                                viewModel: viewModel,
                                gradient: accentGradient,
                                clockStyle: $clockStyle,
                                isFocusState: $isFocusState,
                                showingWorkspace: $showingWorkspace,
                                isStopwatchMode: false,
                                topPadding: contentTopPadding,
                                onSwitchToStopwatch: {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                        sidebarSelection = .stopwatch
                                    }
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                                removal: .opacity
                            ))
                        } else if sidebarSelection == .stopwatch {
                            DashboardTimerView(
                                viewModel: viewModel,
                                gradient: accentGradient,
                                clockStyle: $clockStyle,
                                isFocusState: $isFocusState,
                                showingWorkspace: $showingWorkspace,
                                isStopwatchMode: true,
                                topPadding: contentTopPadding,
                                onSwitchToTimer: {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                        sidebarSelection = .focusTimer
                                    }
                                }
                            )
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.985)),
                                removal: .opacity
                            ))
                        } else {
                            let hasFocusMiniBar = viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime || viewModel.hasPreservedSession
                            let hasStopwatchMiniBar = viewModel.isStopwatchRunning || viewModel.stopwatchTime > 0
                            let hasAnyMiniBar = hasFocusMiniBar || hasStopwatchMiniBar

                            VStack(spacing: 0) {
                                // Persistent Mini Bar if Focus Timer is running or active
                                if hasFocusMiniBar {
                                    PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer) {
                                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                            viewModel.restorePreservedSessionIfNeeded()
                                            sidebarSelection = .focusTimer
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, contentTopPadding)
                                    .padding(.bottom, 6)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                // Persistent Mini Bar if Stopwatch is running or has elapsed time
                                if hasStopwatchMiniBar {
                                    PersistentCrossModeMiniBar(viewModel: viewModel, type: .stopwatch) {
                                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                            sidebarSelection = .stopwatch
                                        }
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.top, hasFocusMiniBar ? 4 : contentTopPadding)
                                    .padding(.bottom, 6)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                                }

                                selectedPageView(topPadding: hasAnyMiniBar ? WindowLayoutMetrics.postMiniBarSpacing : contentTopPadding)
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
                    .clipped()
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82), value: sidebarSelection)
            .animation(
                reduceMotion ? .linear(duration: 0.05) : .spring(response: 0.32, dampingFraction: 0.85),
                value: isSidebarCollapsed
            )

            if isFocusState {
                FocusStateView(viewModel: viewModel, clockStyle: $clockStyle, isPresented: $isFocusState, isStopwatch: sidebarSelection == .stopwatch)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
                    .zIndex(100)
            }

            if let activeInterval = viewModel.idleReviewCoordinator.activeReviewInterval {
                let taskTitle: String? = {
                    if let taskId = activeInterval.taskId, let found = viewModel.tasks.first(where: { $0.id == taskId }) {
                        return found.title
                    }
                    return nil
                }()
                IdleReviewModalView(coordinator: viewModel.idleReviewCoordinator, interval: activeInterval, taskTitle: taskTitle)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96).combined(with: .opacity),
                        removal: .scale(scale: 0.96).combined(with: .opacity)
                    ))
                    .zIndex(110)
            }
        }
        .animation(.spring(response: 0.40, dampingFraction: 0.80), value: isFocusState)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: viewModel.idleReviewCoordinator.activeReviewInterval != nil)
        .background(bgMain)
        .sheet(isPresented: $showingWorkspace) {
            RightPanelView(viewModel: viewModel, showLaps: sidebarSelection == .stopwatch)
                .frame(minWidth: 390, idealWidth: 430, minHeight: 520)
                .background(bgMain)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                isFullScreen = false
            }
        }
        .onAppear {
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                isFullScreen = window.styleMask.contains(.fullScreen)
            }
        }
    }

    private var sidebar: some View {
        SidebarView(
            gradient: accentGradient,
            selection: $sidebarSelection,
            isCollapsed: $isSidebarCollapsed,
            viewModel: viewModel,
            topPadding: topClearance
        )
        .frame(width: isSidebarCollapsed ? SidebarTokens.collapsedWidth : SidebarTokens.sidebarWidth)
        .background(SidebarTokens.sidebarBackground)
    }

    @ViewBuilder
    private func selectedPageView(topPadding: CGFloat) -> some View {
        switch sidebarSelection {
        case .tasks: TasksView(viewModel: viewModel, topPadding: topPadding)
        case .soundscapes: SoundscapesView(audioPlayer: audioPlayer, topPadding: topPadding)
        case .insights: InsightsView(viewModel: viewModel, topPadding: topPadding)
        default: SettingsView(viewModel: viewModel, topPadding: topPadding)
        }
    }

    @ViewBuilder
    private var storageErrorBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved Data Protection Alert")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(viewModel.storageErrorMessage ?? "Saved data could not be loaded because the save file is corrupted or unreadable. Automatic saving is blocked to protect your existing file.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, isFullScreen ? 8 : (WindowLayoutMetrics.titlebarChromeHeight + 4))
        .padding(.bottom, 10)
        .background(Color.red.opacity(0.28))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.red.opacity(0.5)),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var recoverySuccessBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Data Recovered Successfully")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(viewModel.recoveryNoticeMessage ?? "Saved data was safely recovered from your local backup.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.dismissRecoveryNotice()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, isFullScreen ? 8 : (WindowLayoutMetrics.titlebarChromeHeight + 4))
        .padding(.bottom, 10)
        .background(Color.green.opacity(0.22))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.green.opacity(0.4)),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var saveFailureBanner: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes Not Saved")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                Text(viewModel.saveErrorMessage ?? "Recent changes may not have been saved due to a storage error.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.85))
            }
            Spacer()
            Button {
                viewModel.retrySave()
            } label: {
                Text("Retry")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.6))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, isFullScreen ? 8 : (WindowLayoutMetrics.titlebarChromeHeight + 4))
        .padding(.bottom, 10)
        .background(Color.orange.opacity(0.25))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.orange.opacity(0.4)),
            alignment: .bottom
        )
    }
}
