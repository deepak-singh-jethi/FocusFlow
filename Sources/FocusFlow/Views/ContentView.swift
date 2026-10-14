import SwiftUI

// MARK: - Main Content View (Type-Safe Navigation Coordinator)
public struct ContentView: View {
    @StateObject private var viewModel = TimerViewModel()
    @StateObject private var audioPlayer = AmbientAudioPlayer()
    @State private var sidebarSelection: NavigationTab = .focusTimer
    @State private var isFocusState = false
    @State private var showingWorkspace = false
    @AppStorage("clockStyle") private var clockStyle = "Digital"

    let bgMain = Color(red: 0.08, green: 0.09, blue: 0.13)
    let bgSidebar = Color(red: 0.11, green: 0.12, blue: 0.16)
    let accentGradient = LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar

                ZStack {
                    if sidebarSelection == .focusTimer {
                        DashboardTimerView(
                            viewModel: viewModel,
                            gradient: accentGradient,
                            clockStyle: $clockStyle,
                            isFocusState: $isFocusState,
                            showingWorkspace: $showingWorkspace,
                            isStopwatchMode: false,
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
                        VStack(spacing: 0) {
                            // Persistent Mini Bar if Focus Timer is running or active
                            if viewModel.isTimerRunning || viewModel.timeRemaining < viewModel.totalTime {
                                PersistentCrossModeMiniBar(viewModel: viewModel, type: .focusTimer) {
                                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                        sidebarSelection = .focusTimer
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
                                        sidebarSelection = .stopwatch
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
                FocusStateView(viewModel: viewModel, clockStyle: $clockStyle, isPresented: $isFocusState, isStopwatch: sidebarSelection == .stopwatch)
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
            RightPanelView(viewModel: viewModel, showLaps: sidebarSelection == .stopwatch)
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
        case .tasks: TasksView(viewModel: viewModel)
        case .soundscapes: SoundscapesView(audioPlayer: audioPlayer)
        case .insights: InsightsView(viewModel: viewModel)
        default: SettingsView(viewModel: viewModel)
        }
    }
}
