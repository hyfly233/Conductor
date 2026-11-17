import SwiftUI

@main
struct ConductorApp: App {
    @StateObject private var controller = ConductorController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Label(controller.displayStatusTitle, systemImage: controller.displayStatusSymbol)
        }

        Window("Conductor", id: "control") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 900, height: 640)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandGroup(after: .appInfo) {
                OpenControlPanelCommand()
            }
        }
    }
}

private struct OpenControlPanelCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开控制面板") {
            openWindow(id: "control")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}
