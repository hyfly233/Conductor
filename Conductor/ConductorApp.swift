import SwiftUI

@main
struct ConductorApp: App {
    @StateObject private var controller = ConductorController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            Label(controller.status.title, systemImage: controller.status.symbolName)
        }

        Window("Conductor", id: "control") {
            ContentView(controller: controller)
        }
    }
}
