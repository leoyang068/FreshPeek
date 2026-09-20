import SwiftUI

@main
struct FridgeAssistantApp: App {
    @StateObject private var inventory = InventoryStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await inventory.connectToCloud()
                }
                .environmentObject(inventory)
                .environment(\.locale, Locale(identifier: "en_US"))
                .preferredColorScheme(.light)
        }
    }
}
