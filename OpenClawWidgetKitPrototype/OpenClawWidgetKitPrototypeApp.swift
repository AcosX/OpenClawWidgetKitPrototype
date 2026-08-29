import SwiftUI

@main
struct OpenClawWidgetKitPrototypeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentMinSize)
    }
}
