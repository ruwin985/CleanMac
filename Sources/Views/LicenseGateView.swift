import SwiftUI

struct LicenseStatusPill: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var currentDate = Date()

    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
            Text(statusText)
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.white.opacity(0.09), in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.12), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
        .onReceive(countdownTimer) { date in
            currentDate = date
            if case let .trial(expiresAt) = licenseManager.state,
               date >= expiresAt {
                licenseManager.refresh()
            }
        }
    }

    private var statusText: String {
        switch licenseManager.state {
        case let .trial(expiresAt):
            return "使用剩余 \(remainingTimeText(until: expiresAt))"
        case .licensed:
            return "已授权"
        case .locked:
            return "试用已结束"
        }
    }

    private var iconName: String {
        switch licenseManager.state {
        case .trial:
            return "clock.badge.checkmark"
        case .licensed:
            return "checkmark.seal.fill"
        case .locked:
            return "lock.fill"
        }
    }

    private func remainingTimeText(until expiresAt: Date) -> String {
        let seconds = max(0, Int(expiresAt.timeIntervalSince(currentDate).rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }
}

struct LicenseGateOverlay: View {
    @ObservedObject var licenseManager: LicenseManager
    @State private var licenseCode = ""
    @FocusState private var isLicenseFieldFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.82),
                    Color(red: 0.17, green: 0.16, blue: 0.30).opacity(0.94),
                    Color(red: 0.08, green: 0.11, blue: 0.20).opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(.ultraThinMaterial.opacity(0.24))
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(colors: [.mint, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )

                    Text("CleanMac 试用已结束")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("CleanMac 提供 1 天免费试用，试用结束后可通过淘宝店铺购买一次性买断授权码。下单后联系客服获取授权码，再粘贴到这里继续使用。")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.74))
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                        .frame(maxWidth: 560)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("授权码")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))

                    TextField("CM-XXXXXXX-XXXXXXX-XXXXXXX", text: $licenseCode)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .focused($isLicenseFieldFocused)
                        .onSubmit(activate)
                        .disabled(licenseManager.isActivating)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(.black.opacity(0.26), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(isLicenseFieldFocused ? 0.35 : 0.12), lineWidth: 1)
                        }

                    if let activationErrorMessage = licenseManager.activationErrorMessage {
                        Label(activationErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(licenseManager.hasLicenseServer ? "授权码会联网绑定当前设备；同一授权码达到设备上限后，其他 Mac 需重新购买并使用新授权码。" : "淘宝下单后，请联系客服获取授权码。", systemImage: "envelope.fill")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.52))
                    }
                }
                .frame(maxWidth: 560)

                HStack(spacing: 14) {
                    Button(action: licenseManager.openPurchasePage) {
                        Label("购买授权码", systemImage: "cart.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LicenseGateButtonStyle(kind: .primary))
                    .disabled(licenseManager.purchaseURL == nil)
                    .opacity(licenseManager.purchaseURL == nil ? 0.58 : 1)

                    Button(action: activate) {
                        Label(licenseManager.isActivating ? "正在激活" : "激活使用", systemImage: licenseManager.isActivating ? "arrow.triangle.2.circlepath" : "key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(LicenseGateButtonStyle(kind: .secondary))
                    .disabled(trimmedLicenseCode.isEmpty || licenseManager.isActivating)
                    .opacity((trimmedLicenseCode.isEmpty || licenseManager.isActivating) ? 0.58 : 1)
                }
                .frame(maxWidth: 560)

                Button(action: licenseManager.openRefundPage) {
                    Label("申请退款 / 查看退款政策", systemImage: "arrow.uturn.left.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(LicenseGateButtonStyle(kind: .secondary))
                .disabled(licenseManager.refundURL == nil)
                .opacity(licenseManager.refundURL == nil ? 0.58 : 1)
                .frame(maxWidth: 560)

                if licenseManager.purchaseURL == nil {
                    Text("购买入口尚未配置，请填入 CleanMacPurchaseURL。")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
            }
            .padding(34)
            .frame(width: 680)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 50, y: 28)
        }
        .onAppear {
            isLicenseFieldFocused = true
        }
    }

    private var trimmedLicenseCode: String {
        licenseCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func activate() {
        guard !trimmedLicenseCode.isEmpty else { return }
        licenseManager.activate(with: trimmedLicenseCode)
    }
}

private struct LicenseGateButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(background(isPressed: configuration.isPressed), in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.14), lineWidth: 1) }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }

    private func background(isPressed: Bool) -> some ShapeStyle {
        switch kind {
        case .primary:
            return LinearGradient(
                colors: [
                    Color(red: 0.17, green: 0.82, blue: 0.64).opacity(isPressed ? 0.78 : 1),
                    Color(red: 0.08, green: 0.58, blue: 0.92).opacity(isPressed ? 0.78 : 1)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .secondary:
            return LinearGradient(
                colors: [
                    .white.opacity(isPressed ? 0.10 : 0.16),
                    .white.opacity(isPressed ? 0.06 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
