import SwiftUI

@main
struct IntercomDemoApp: App {
    @StateObject private var calls = IntercomCallCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView(coordinator: calls)
        }
    }
}
