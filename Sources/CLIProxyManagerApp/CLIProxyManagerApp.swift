import SwiftUI

@main
struct CLIProxyManagerApp: App {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                DashboardView()
            } else {
                OnboardingView()
                    .toolbar {
                        Button("대시보드로 이동") {
                            hasCompletedOnboarding = true
                        }
                    }
            }
        }
        .windowStyle(.titleBar)
    }
}
