import SwiftUI

struct AppSettingsView: View {
    @AppStorage("launchMenuBarAtLogin") private var launchMenuBarAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            Toggle(isOn: Binding(
                get: { launchMenuBarAtLogin },
                set: { newValue in
                    launchMenuBarAtLogin = newValue
                    LoginItemRegistrar.launchMenuBarAtLogin = newValue
                }
            )) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登录时自动启动状态栏")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("登录 macOS 后自动启动 `CleanMacMenuBar`。")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Spacer()
        }
        .padding(24)
        .frame(width: 420, height: 220)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            launchMenuBarAtLogin = LoginItemRegistrar.launchMenuBarAtLogin
        }
    }
}
