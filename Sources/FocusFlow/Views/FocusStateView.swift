import SwiftUI

// MARK: - Focus State View (Full Screen Immersive Focus Mode)
public struct FocusStateView: View {
    @ObservedObject public var viewModel: TimerViewModel
    @Binding public var clockStyle: String
    @Binding public var isPresented: Bool
    public var isStopwatch: Bool = false

    public init(viewModel: TimerViewModel, clockStyle: Binding<String>, isPresented: Binding<Bool>, isStopwatch: Bool = false) {
        self.viewModel = viewModel
        self._clockStyle = clockStyle
        self._isPresented = isPresented
        self.isStopwatch = isStopwatch
    }

    private var isRunning: Bool {
        isStopwatch ? viewModel.isStopwatchRunning : viewModel.isTimerRunning
    }

    private var actionTitle: String {
        if isStopwatch {
            if viewModel.isStopwatchRunning { return "Pause" }
            return viewModel.stopwatchTime == 0 ? "Start" : "Resume"
        } else {
            if viewModel.isCountdownMutationBlocked { return "Waiting for Review" }
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

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.055, green: 0.06, blue: 0.09).ignoresSafeArea()

                Button {
                    toggleRunning()
                } label: {
                    ClockFaceView(viewModel: viewModel, style: clockStyle, size: min(geometry.size.width * 0.72, geometry.size.height * 0.74, 680), minimal: true, isStopwatch: isStopwatch)
                }
                .buttonStyle(.plain)
                .disabled(!isStopwatch && viewModel.isCountdownMutationBlocked)
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
                        .disabled(!isStopwatch && viewModel.isCountdownMutationBlocked)
                        .opacity(!isStopwatch && viewModel.isCountdownMutationBlocked ? 0.6 : 1.0)
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
