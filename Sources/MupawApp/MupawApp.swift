import AppKit
import SwiftUI

@main
struct MupawApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    appDelegate.onTerminate = {
                        model.shutdown()
                    }
                }
        }
        .defaultSize(width: 980, height: 680)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
private final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}
