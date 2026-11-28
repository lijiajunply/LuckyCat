import SwiftUI

@main
struct LuckyClashApp: App {
    @MainActor static let vpn = PrototypeVPN()
    @AppStorage(AppAppearance.modeKey) private var appearance = "system"
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage(AppAppearance.accentKey) private var accentHex = AppAppearance.defaultAccent

    var body: some Scene {
        WindowGroup {
            ContentView(vpn: Self.vpn)
                .environment(\.locale, language == "system" ? .autoupdatingCurrent : Locale(identifier: language))
                .preferredColorScheme(AppAppearance.colorScheme(appearance))
                .tint(AppAppearance.accent(accentHex))
        }
    }
}
