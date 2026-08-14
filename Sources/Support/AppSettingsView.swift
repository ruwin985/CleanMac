import SwiftUI

struct AppSettingsView: View {
    @AppStorage("launchMenuBarAtLogin") private var launchMenuBarAtLogin = true
    @EnvironmentObject private var licenseManager: LicenseManager

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

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("授权")
                    .font(.system(size: 16, weight: .bold, design: .rounded))

                Text(licenseDescription)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("购买授权码") {
                        licenseManager.openPurchasePage()
                    }
                    .disabled(licenseManager.purchaseURL == nil)

                    Button("申请退款") {
                        licenseManager.openRefundPage()
                    }
                    .disabled(licenseManager.refundURL == nil)
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 440, height: 350)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            launchMenuBarAtLogin = LoginItemRegistrar.launchMenuBarAtLogin
            licenseManager.refresh()
        }
    }

    private var licenseDescription: String {
        switch licenseManager.state {
        case .trial:
            return "当前处于 1 天试用期，\(licenseManager.statusText)。试用结束后再次启动会显示全屏授权蒙层。"
        case let .licensed(info):
            if let email = info.email, !email.isEmpty {
                return "已完成买断授权，购买邮箱：\(email)。"
            }
            return "已完成买断授权，交易号：\(info.transactionID)。"
        case .locked:
            return "试用已结束，请购买后输入授权码继续使用。"
        }
    }
}
