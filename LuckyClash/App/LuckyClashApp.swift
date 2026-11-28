import SwiftUI

@main
struct LuckyClashApp: App {
    @MainActor static let vpn = PrototypeVPN()
    @AppStorage(AppAppearance.modeKey) private var appearance = "system"
    @AppStorage(AppAppearance.accentKey) private var accentHex = AppAppearance.defaultAccent

    var body: some Scene {
        WindowGroup {
            ContentView(vpn: Self.vpn)
                .environment(\.locale, Locale(identifier: "zh-Hans"))
                .preferredColorScheme(AppAppearance.colorScheme(appearance))
                .tint(AppAppearance.accent(accentHex))
        }
    }
}
