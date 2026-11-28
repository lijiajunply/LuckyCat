import SwiftUI
import UIKit

enum AppAppearance {
    static let modeKey = "appearanceMode"
    static let accentKey = "appearanceAccentHex"
    static let defaultAccent = "007AFF"

    static func colorScheme(_ mode: String) -> ColorScheme? {
        switch mode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    static func accent(_ hex: String) -> Color {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return Color(uiColor: .systemBlue)
        }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    static func hex(_ color: Color) -> String? {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("appLanguage") private var language = "system"
    @AppStorage(AppAppearance.modeKey) private var mode = "system"
    @AppStorage(AppAppearance.accentKey) private var accentHex = AppAppearance.defaultAccent

    var body: some View {
        Form {
            Section("语言") {
                Picker("应用语言", selection: $language) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
            }
            Section("外观") {
                Picker("外观模式", selection: $mode) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                ColorPicker("强调色", selection: Binding(
                    get: { AppAppearance.accent(accentHex) },
                    set: { if let hex = AppAppearance.hex($0) { accentHex = hex } }
                ), supportsOpacity: false)
                Button("恢复默认强调色") { accentHex = AppAppearance.defaultAccent }
                    .disabled(accentHex == AppAppearance.defaultAccent)
            }
        }
        .navigationTitle("外观")
    }
}
