import SwiftUI

@main
struct OpenDeploymentApp: App {
    @StateObject private var feed = DeploymentFeed()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(feed)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                feed.start()
            case .background:
                feed.stop()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
