import SwiftUI

/// The tutorial occupies the main window. Only the active surface is mounted,
/// so the native canvas cannot receive input behind the tutorial.
struct WorkspaceRootView: View {
    let workspace: Workspace
    @Bindable var onboarding: OnboardingState
    var animates = true
    var startup: AppStartupState? = nil
    @State private var opensSampleAfterTutorial = false

    var body: some View {
        ZStack {
            if let startup, !startup.isReady {
                switch startup.phase {
                case .splash:
                    LaunchSplashView(progress: startup.splashProgress)
                case .models:
                    ModelDownloadView(presentation: startup.downloadPresentation,
                                      onRetry: startup.models.retry,
                                      onPauseResume: startup.models.togglePause)
                case .ready:
                    EmptyView()
                }
            } else if onboarding.isPresented {
                OnboardingView(onboarding: onboarding, animates: animates, onFinish: finishTutorial)
            } else {
                ContentView(workspace: workspace, configuresWindow: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .frame(minWidth: CanvasPanelLayout.minimumWindowSize.width,
               minHeight: CanvasPanelLayout.minimumWindowSize.height)
        .background(WindowConfiguration(onEscape: handleEscape))
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onExitCommand { _ = handleEscape() }
        .onChange(of: workspace.busy) { _, _ in openRequestedSampleWhenReady() }
    }

    private func handleEscape() -> Bool {
        if let startup, !startup.isReady { return true }
        if onboarding.isPresented {
            finishTutorial(false)
            return true
        }
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
        guard opensSampleAfterTutorial, !onboarding.isPresented, !workspace.busy else { return }
        opensSampleAfterTutorial = false
        workspace.openSample()
    }
}
