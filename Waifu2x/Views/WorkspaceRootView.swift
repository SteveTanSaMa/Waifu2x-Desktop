import SwiftUI

/// Startup and the tutorial occupy the main window while settings has its own
/// scene. The workspace stays inert until launch verification has completed.
struct WorkspaceRootView: View {
    let workspace: Workspace
    @Bindable var onboarding: OnboardingState
    var animates = true
    var startup: AppStartupState? = nil
    @State private var opensSampleAfterTutorial = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reducesMotion: Bool { systemReduceMotion || !animates || startup?.usesReducedMotion == true }
    private var showsDestination: Bool { startup == nil || startup?.phase == .revealing || startup?.isReady == true }
    private var isRevealing: Bool { startup?.phase == .revealing }
    private var revealAnimation: Animation? {
        guard animates, let startup, startup.revealDuration > 0 else { return nil }
        return .easeInOut(duration: reducesMotion ? min(startup.revealDuration, 0.18) : startup.revealDuration)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if showsDestination {
                destination
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: reducesMotion ? 0 : 8)),
                                            removal: .identity))
            }
            if let startup, !startup.isReady {
                Group {
                    if startup.showsModelPreparation {
                        ModelDownloadView(presentation: startup.downloadPresentation,
                                          onRetry: startup.models.retry,
                                          onPauseResume: startup.models.togglePause)
                    } else {
                        LaunchSplashView(progress: startup.splashProgress)
                    }
                }
                .opacity(isRevealing ? 0 : 1)
                .scaleEffect(isRevealing && !reducesMotion ? 0.985 : 1)
                .offset(y: isRevealing && !reducesMotion ? -6 : 0)
                // The retained outgoing view must never eat a tutorial click.
                .allowsHitTesting(startup.phase == .splash || startup.phase == .models)
                .accessibilityHidden(isRevealing)
                .transition(.identity)
            }
        }
        .animation(isRevealing ? revealAnimation : nil, value: startup?.phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .frame(minWidth: CanvasPanelLayout.minimumWindowSize.width,
               minHeight: CanvasPanelLayout.minimumWindowSize.height)
        .background(WindowConfiguration(onEscape: handleEscape))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onExitCommand { _ = handleEscape() }
        .onChange(of: workspace.busy) { _, _ in openRequestedSampleWhenReady() }
        .onChange(of: startup?.isReady) { _, _ in openRequestedSampleWhenReady() }
    }

    private var destination: some View {
        Group {
            if onboarding.isPresented {
                OnboardingView(onboarding: onboarding, animates: animates, onFinish: finishTutorial)
            } else {
                ContentView(workspace: workspace, configuresWindow: false)
                    .disabled(startup?.isReady == false)
                    .allowsHitTesting(startup?.isReady != false)
                    .accessibilityHidden(startup?.isReady == false)
            }
        }
    }

    private func handleEscape() -> Bool {
        if let startup, !startup.isReady, startup.phase != .revealing { return true }
        if onboarding.isPresented {
            finishTutorial(false)
            return true
        }
        if let startup, !startup.isReady { return true }
        guard !workspace.activePanels.isEmpty || workspace.isProcessing else { return false }
        workspace.dismissPanelOrCancel()
        return true
    }

    private func finishTutorial(_ opensSample: Bool) {
        opensSampleAfterTutorial = opensSample
        onboarding.complete()
        openRequestedSampleWhenReady()
    }

    private func openRequestedSampleWhenReady() {
        guard opensSampleAfterTutorial, startup?.isReady != false,
              !onboarding.isPresented, !workspace.busy else { return }
        opensSampleAfterTutorial = false
        workspace.openSample()
    }
}
