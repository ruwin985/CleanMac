import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class FeedbackWindowController: NSWindowController, NSWindowDelegate {
    static let shared = FeedbackWindowController()

    private init() {
        let rootView = FeedbackWindowView()
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 632),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "提供反馈"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.contentViewController = hostingController

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindowAndActivate() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct FeedbackWindowView: View {
    @StateObject private var model = FeedbackFormViewModel()
    @FocusState private var focusedField: FeedbackField?
    @State private var isEmailFeedbackExpanded = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 28, y: 18)
                .padding(24)

            HStack(alignment: .top, spacing: 28) {
                feedbackArtwork
                    .frame(width: 164, height: 164)
                    .padding(.top, 22)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("提供反馈")
                                .font(.system(size: 29, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.primary.opacity(0.9))
                            Text("请提供关于您问题的详细描述、建议或漏洞报告。国内用户推荐优先通过腾讯问卷提交，便于我们集中整理和跟进。")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        tencentSurveyEntry

                        emailFeedbackEntry
                    }
                    .padding(.vertical, 22)
                    .padding(.trailing, 24)
                }
            }
            .padding(.leading, 40)
            .padding(.trailing, 28)
        }
        .frame(minWidth: 760, minHeight: 632)
        .onAppear {
            focusedField = .name
        }
    }

    private var tencentSurveyEntry: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text("腾讯问卷反馈")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                Text("打开浏览器提交问卷，并自动带上当前填写内容与匿名系统配置。")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("打开问卷") {
                model.openTencentSurvey()
            }
            .buttonStyle(FeedbackSecondaryButtonStyle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                )
        )
    }

    private var emailFeedbackEntry: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    isEmailFeedbackExpanded.toggle()
                    if !isEmailFeedbackExpanded {
                        focusedField = nil
                    }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 36, height: 36)
                        .background(
                            Circle()
                                .fill(Color.accentColor.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("邮件反馈")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary.opacity(0.9))
                        Text(isEmailFeedbackExpanded ? "填写详细内容后，将打开系统邮件应用发送。" : "没有腾讯问卷时可改用邮件提交，支持附件和匿名系统配置。")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Text(isEmailFeedbackExpanded ? "收起" : "展开")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor.opacity(0.10))
                        )

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isEmailFeedbackExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)

            if isEmailFeedbackExpanded {
                VStack(spacing: 12) {
                    VStack(spacing: 10) {
                        pickerField
                        textField("您的姓名", text: $model.name, field: .name)
                        textField("您的联系邮箱", text: $model.email, field: .email)
                        messageField
                    }

                    attachmentRow
                    diagnosticsRow

                    HStack(spacing: 12) {
                        if let status = model.statusMessage {
                            Label(status, systemImage: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.statusIsError ? .red : .green)
                        }

                        Spacer()

                        Button("发送邮件") {
                            model.submit()
                        }
                        .buttonStyle(FeedbackPrimaryButtonStyle(disabled: !model.canSubmit || model.isSubmitting))
                        .disabled(!model.canSubmit || model.isSubmitting)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isEmailFeedbackExpanded ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isEmailFeedbackExpanded)
    }

    private var pickerField: some View {
        Menu {
            ForEach(FeedbackCategory.allCases, id: \.self) { category in
                Button(category.rawValue) { model.category = category }
            }
        } label: {
            fieldContainer {
                HStack {
                    Text(model.category.rawValue)
                        .foregroundStyle(.primary.opacity(0.86))
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
    }

    private func textField(_ placeholder: String, text: Binding<String>, field: FeedbackField) -> some View {
        fieldContainer {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .focused($focusedField, equals: field)
        }
        .frame(height: 42)
    }

    private var messageField: some View {
        fieldContainer(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("填写您的反馈")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary.opacity(0.85))
                        .padding(.top, 2)
                        .padding(.leading, 4)
                }

                TextEditor(text: $model.message)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.92))
                    .focused($focusedField, equals: .message)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -8)
            }
            .frame(height: 118)
        }
    }

    private var attachmentRow: some View {
        HStack(spacing: 10) {
            Button {
                model.pickAttachment()
            } label: {
                Label(model.attachmentButtonTitle, systemImage: "paperclip")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            if let attachmentName = model.attachmentName {
                Text(attachmentName)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    private var diagnosticsRow: some View {
        Toggle(isOn: $model.includeDiagnostics) {
            HStack(spacing: 6) {
                Text("发送匿名系统配置文件")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.82))
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary.opacity(0.85))
                    .help("包含 macOS 版本、应用版本与设备型号，不会读取私人文件内容。")
            }
        }
        .toggleStyle(.checkbox)
    }

    private var feedbackArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.accentColor.opacity(0.10), radius: 24, y: 12)

            if let appIcon = NSImage(named: "AppIcon") {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(14)
            } else {
                Image(systemName: "app.badge")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    private func fieldContainer<Content: View>(alignment: Alignment = .center, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: alignment) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
            content()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }
}

private enum FeedbackField: Hashable {
    case name
    case email
    case message
}

enum FeedbackCategory: String, CaseIterable {
    case feedback = "反馈"
    case suggestion = "建议"
    case bug = "漏洞报告"
    case question = "疑问"
}

@MainActor
final class FeedbackFormViewModel: ObservableObject {
    private static let tencentSurveyURLInfoKey = "CleanMacTencentSurveyURL"
    private static let tencentSurveyURLEnvironmentKey = "CLEANMAC_TENCENT_SURVEY_URL"
    private static let defaultTencentSurveyURLString = "https://wj.qq.com/s2/27497302/29c4/"

    @Published var category: FeedbackCategory = .feedback
    @Published var name: String = ""
    @Published var email: String = ""
    @Published var message: String = ""
    @Published var includeDiagnostics = true
    @Published var attachmentURL: URL?
    @Published var statusMessage: String?
    @Published var statusIsError = false
    @Published var isSubmitting = false

    var attachmentName: String? { attachmentURL?.lastPathComponent }
    var attachmentButtonTitle: String { attachmentURL == nil ? "附加文件…" : "更换附件…" }

    var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .image, .pdf, .plainText, .rtf, .data,
            UTType(filenameExtension: "zip") ?? .data
        ]
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.attachmentURL = panel.url
        }
    }

    func openTencentSurvey() {
        guard let surveyURL = tencentSurveyURL else {
            statusMessage = "腾讯问卷入口尚未配置。"
            statusIsError = true
            return
        }

        NSWorkspace.shared.open(surveyURL)
        statusMessage = attachmentURL == nil ? "已打开腾讯问卷，请在浏览器中提交。" : "已打开腾讯问卷，附件需在问卷页重新上传。"
        statusIsError = false
    }

    func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        statusMessage = nil
        statusIsError = false

        let service = NSSharingService(named: .composeEmail)
        service?.recipients = ["ruwin211@126.com"]
        service?.subject = "[CleanMac][\(category.rawValue)] 来自 \(name) 的反馈"

        var bodySections: [String] = [
            "类型：\(category.rawValue)",
            "姓名：\(name)",
            "联系邮箱：\(email)",
            "",
            "反馈内容：",
            message
        ]

        if includeDiagnostics {
            bodySections.append(contentsOf: ["", "匿名系统配置：", diagnosticsSummary()])
        }

        var items: [Any] = [bodySections.joined(separator: "\n")]
        if let attachmentURL {
            items.append(attachmentURL)
        }

        guard let service else {
            isSubmitting = false
            statusMessage = "当前系统未配置邮件发送服务。"
            statusIsError = true
            return
        }

        service.perform(withItems: items)
        isSubmitting = false
        statusMessage = "已打开邮件窗口，请确认后发送。"
        statusIsError = false
    }

    private func diagnosticsSummary() -> String {
        let diagnostics = feedbackDiagnostics()

        return [
            "设备名称：\(diagnostics.deviceName)",
            "macOS：\(diagnostics.macOSVersion)",
            "应用版本：\(diagnostics.appVersion) (\(diagnostics.build))"
        ].joined(separator: "\n")
    }

    private var tencentSurveyURL: URL? {
        let rawValue = configuredValue(
            infoKey: Self.tencentSurveyURLInfoKey,
            environmentKey: Self.tencentSurveyURLEnvironmentKey
        ) ?? Self.defaultTencentSurveyURLString

        guard var components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }

        let prefillItems = tencentSurveyPrefillItems()
        let prefillNames = Set(prefillItems.map(\.name))
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { prefillNames.contains($0.name) }
        queryItems.append(contentsOf: prefillItems)
        components.queryItems = queryItems

        return components.url
    }

    private func tencentSurveyPrefillItems() -> [URLQueryItem] {
        let diagnostics = feedbackDiagnostics()
        var values: [(String, String?)] = [
            ("source", "cleanmac_mac_app"),
            ("channel", "tencent_wenjuan"),
            ("feedback_type", category.rawValue),
            ("name", trimmedNonEmpty(name)),
            ("email", trimmedNonEmpty(email)),
            ("message", trimmedNonEmpty(message)),
            ("include_diagnostics", includeDiagnostics ? "1" : "0"),
            ("locale", Locale.current.identifier),
            ("request_id", UUID().uuidString)
        ]

        if includeDiagnostics {
            values.append(contentsOf: [
                ("device_name", diagnostics.deviceName),
                ("macos_version", diagnostics.macOSVersion),
                ("app_version", diagnostics.appVersion),
                ("build", diagnostics.build),
                ("arch", diagnostics.architecture)
            ])
        }

        if let attachmentName {
            values.append(("attachment_name", attachmentName))
        }

        return values.compactMap { name, value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URLQueryItem(name: name, value: value)
        }
    }

    private func feedbackDiagnostics() -> FeedbackDiagnostics {
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersion
        let model = Host.current().localizedName ?? "Mac"
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        return FeedbackDiagnostics(
            deviceName: model,
            macOSVersion: "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)",
            appVersion: appVersion,
            build: build,
            architecture: Self.currentArchitecture
        )
    }

    private func configuredValue(infoKey: String, environmentKey: String) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment[environmentKey],
           !environmentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return environmentValue
        }
        if let bundleValue = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String,
           !bundleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleValue
        }
        return nil
    }

    private func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private struct FeedbackDiagnostics {
    let deviceName: String
    let macOSVersion: String
    let appVersion: String
    let build: String
    let architecture: String
}

private struct FeedbackPrimaryButtonStyle: ButtonStyle {
    let disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(disabled ? Color.gray.opacity(0.45) : Color.accentColor.opacity(configuration.isPressed ? 0.78 : 0.96))
                    .shadow(color: disabled ? .clear : Color.accentColor.opacity(0.22), radius: 14, y: 7)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private struct FeedbackSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.24, dampingFraction: 0.82), value: configuration.isPressed)
    }
}
