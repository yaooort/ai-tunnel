import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct AITunnelApp: App {
    @NSApplicationDelegateAdaptor(AITunnelAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @State private var showsServerSettings = false

    var body: some Scene {
        Window("AI Tunnel", id: "main") {
            TunnelWindow(model: model, appDelegate: appDelegate, showsServerSettings: $showsServerSettings)
        }
        .defaultSize(width: 600, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("连接") {
                Button(model.isRunning ? "断开连接" : "连接") {
                    if model.isRunning { model.disconnect() } else { model.connect() }
                }
                .disabled(showsServerSettings || (!model.isRunning && !model.canConnect))
                .keyboardShortcut("k", modifiers: [.command, .shift])

                ServerConfigurationCommand(model: model, isPresented: $showsServerSettings)

                Divider()
                Button("复制公网地址", action: model.copyPublicURL)
                    .disabled(!model.hasCredentials)
                Button("打开公网地址", action: model.openPublicURL)
                    .disabled(!model.hasCredentials)
            }
        }

        MenuBarExtra {
            TunnelMenu(model: model, showsServerSettings: $showsServerSettings)
        } label: {
            Label("AI Tunnel：\(model.statusText)", systemImage: model.status.menuSymbol)
        }
    }
}

@MainActor
final class AITunnelAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var reopenMainWindow: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopenMainWindow?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.shutdown()
        return .terminateNow
    }
}

private struct TunnelWindow: View {
    @ObservedObject var model: AppModel
    let appDelegate: AITunnelAppDelegate
    @Binding var showsServerSettings: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var showsLogs = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusPanel
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Form {
                Section {
                    HStack(spacing: 12) {
                        Text("中转服务器")
                        Spacer(minLength: 8)
                        Text(model.hasCredentials ? model.connectionSettings.serverAddress : "尚未配置")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(model.hasCredentials ? "编辑配置…" : "配置服务器…") {
                            showsServerSettings = true
                        }
                        .disabled(model.isRunning)
                        .help(model.isRunning ? "请先断开连接，再修改服务器配置" : "设置自己的中转服务器")
                    }
                    HStack(spacing: 12) {
                        Text("公网地址")
                        Spacer(minLength: 8)
                        Text(model.publicURL)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button(action: model.copyPublicURL) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制公网地址")
                        .accessibilityLabel("复制公网地址")
                        .disabled(!model.hasCredentials)
                        Button(action: model.openPublicURL) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("在浏览器中打开公网地址")
                        .accessibilityLabel("在浏览器中打开公网地址")
                        .disabled(!model.hasCredentials)
                    }
                    HStack {
                        Text("本机端口")
                        Spacer()
                        Text("127.0.0.1 :")
                            .foregroundStyle(.secondary)
                            .font(.system(.body, design: .monospaced))
                        TextField("", text: $model.localPort, prompt: Text("8080"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 76)
                            .disabled(model.isRunning)
                            .accessibilityLabel("本机服务端口")
                            .accessibilityHint("请输入 1 到 65535 之间的端口号")
                    }
                } header: {
                    Text("连接设置")
                } footer: {
                    Text("本机服务协议需与服务器转发配置一致。更改端口前请先断开连接。")
                }

                Section {
                    Toggle("打开应用后自动连接", isOn: $model.autoConnect)
                    Toggle("登录时启动应用", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                } header: {
                    Text("启动设置")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(-1)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if model.status == .connecting || model.status == .reconnecting {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(model.statusText)
                    }
                    Text(actionHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(action: performPrimaryAction) {
                        Label(
                            model.isRunning ? "断开连接" : "连接",
                            systemImage: model.isRunning ? "stop.fill" : "link"
                        )
                        .frame(minWidth: 92)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isRunning && !model.canConnect)
                    .keyboardShortcut(.defaultAction)
                }

                DisclosureGroup(isExpanded: $showsLogs) {
                    logPanel
                        .padding(.top, 10)
                } label: {
                    HStack(spacing: 6) {
                        Text("连接日志")
                        if !model.logs.isEmpty {
                            Text("\(model.logs.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }

                Text("关闭窗口后继续运行 · 退出应用会断开连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 560, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showsServerSettings) {
            ServerConfigurationSheet(model: model)
        }
        .onAppear {
            appDelegate.model = model
            appDelegate.reopenMainWindow = {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("AI Tunnel")
                    .font(.title2.weight(.semibold))
                Text("将本机服务连接到公网")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("HTTP/2")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle()
                    .fill(model.status.indicatorColor)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(model.statusText)
                    .font(.headline)
                Spacer()
            }
            Text(model.hasCredentials ? model.detailText : "请先配置自己的中转服务器，再开始连接。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.errorMessage, !error.isEmpty {
                Divider()
                Label {
                    Text(error)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .font(.callout)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65))
        }
        .accessibilityElement(children: .combine)
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                if model.logs.isEmpty {
                    Text("暂无日志。连接后会在这里显示运行状态。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(model.logs.joined(separator: "\n"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(10)
            .frame(height: 140)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.65))
            }
            .accessibilityLabel("连接日志内容")

            HStack {
                Text("日志用于查看连接与重连状态")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清空", action: model.clearLogs)
                    .disabled(model.logs.isEmpty)
                Button("在访达中显示", action: model.revealLogs)
            }
            .controlSize(.small)
        }
    }

    private func performPrimaryAction() {
        if model.isRunning { model.disconnect() } else { model.connect() }
    }

    private var actionHint: String {
        if model.isRunning { return "网络恢复后会自动重连" }
        if !model.hasCredentials { return "先点击“配置服务器”完成设置" }
        if !model.canConnect { return "请输入有效的本机端口" }
        return "点击连接即可使用公网地址"
    }
}

private struct TunnelMenu: View {
    @ObservedObject var model: AppModel
    @Binding var showsServerSettings: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("AI Tunnel · \(model.statusText)")
        Text(model.publicURL)
        Divider()
        Button(model.isRunning ? "断开连接" : "连接") {
            if model.isRunning { model.disconnect() } else { model.connect() }
        }
        .disabled(showsServerSettings || (!model.isRunning && !model.canConnect))
        ServerConfigurationCommand(model: model, isPresented: $showsServerSettings)
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("复制公网地址", action: model.copyPublicURL)
            .disabled(!model.hasCredentials)
        Button("打开公网地址", action: model.openPublicURL)
            .disabled(!model.hasCredentials)
        Divider()
        Button("退出 AI Tunnel") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

private struct ServerConfigurationCommand: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.hasCredentials ? "编辑服务器配置…" : "配置服务器…") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
            isPresented = true
        }
        .disabled(model.isRunning)
    }
}

private struct ServerConfigurationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionSettings
    @State private var serverPortText: String
    @State private var remotePortText: String
    @State private var showsAdvanced = false
    @State private var formError: String?
    @State private var importNotice: String?

    init(model: AppModel) {
        self.model = model
        let settings = model.connectionSettings
        _draft = State(initialValue: settings)
        _serverPortText = State(initialValue: String(settings.serverPort))
        _remotePortText = State(initialValue: String(settings.remotePort))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("服务器配置")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button("导入连接文件…", action: importConnectionFile)
                        .disabled(model.isRunning)
                }
                Text("填写自己的中转服务器，或导入服务器生成的 .connection.json 文件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)

            Divider()

            Form {
                Section("连接服务器") {
                    TextField("服务器地址", text: $draft.serverAddress, prompt: Text("tunnel.example.com 或公网 IP"))
                        .help("仅填写域名或 IP，不需要 http:// 或 https://")
                    TextField("连接端口", text: $serverPortText, prompt: Text("7000"))
                    TextField("TLS 证书域名", text: $draft.tlsServerName, prompt: Text("tunnel.example.com"))
                        .help("填写中转服务器 TLS 证书对应的域名")
                    TextField("公网 HTTPS 地址", text: $draft.publicURL, prompt: Text("https://api.example.com"))
                }

                Section {
                    SecureField("认证 Token", text: $draft.token)
                        .accessibilityHint("填写服务器设置的认证凭据，内容不会明文显示")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CA 证书（PEM）")
                            Spacer()
                            Button("导入 CA 文件…", action: importCAFile)
                        }
                        TextEditor(text: $draft.caCertificatePEM)
                            .font(.system(size: 11, design: .monospaced))
                            .disableAutocorrection(true)
                            .scrollContentBackground(.hidden)
                            .padding(5)
                            .frame(height: 130)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color(nsColor: .separatorColor))
                            }
                            .accessibilityLabel("PEM 格式 CA 证书")
                        Text("粘贴完整证书，包含 BEGIN CERTIFICATE 和 END CERTIFICATE 行。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("服务器认证")
                } footer: {
                    Text("保存后，连接配置存放在本机钥匙串。认证 Token 始终隐藏显示。")
                }

                Section {
                    DisclosureGroup("高级设置", isExpanded: $showsAdvanced) {
                        TextField("服务器映射端口", text: $remotePortText, prompt: Text("18080"))
                            .help("必须与 Caddy 的上游端口及 frps 允许的端口一致")
                    }
                } footer: {
                    Text("服务器映射端口默认为 18080，需要与服务端转发配置一致。")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(model.isRunning)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                if let formError {
                    Label(formError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let importNotice {
                    Label(importNotice, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text(model.isRunning ? "请先断开连接，再保存配置。" : "更改仅在点击保存后生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.isRunning)
                }
            }
            .padding(20)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 620, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func cancel() {
        draft.token = ""
        dismiss()
    }

    private func save() {
        guard !model.isRunning else { return }
        formError = nil
        importNotice = nil
        guard let serverPort = validatedPort(serverPortText), let remotePort = validatedPort(remotePortText) else {
            formError = "连接端口和服务器映射端口必须是 1 到 65535 的整数。"
            return
        }
        var settings = draft
        settings.serverAddress = settings.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.tlsServerName = settings.tlsServerName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.publicURL = settings.publicURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.serverPort = serverPort
        settings.remotePort = remotePort
        do {
            try model.saveConnectionSettings(settings)
            draft.token = ""
            dismiss()
        } catch {
            // Do not expose decoder errors, file contents, or credentials in the interface.
            formError = "配置未保存。请检查服务器字段、认证 Token 和 PEM 证书，并确认登录钥匙串已解锁。"
        }
    }

    private func validatedPort(_ text: String) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }

    private func importConnectionFile() {
        guard !model.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "导入服务器连接文件"
        panel.prompt = "载入"
        panel.allowedContentTypes = [.json]
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard fileSize <= 128 * 1024 else {
                formError = "连接文件过大，请选择服务器导出的 .connection.json 文件。"
                importNotice = nil
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 128 * 1024 else {
                formError = "连接文件过大，请选择服务器导出的 .connection.json 文件。"
                importNotice = nil
                return
            }
            let document = try JSONDecoder().decode(ImportedConnectionDocument.self, from: data)
            guard document.schemaVersion == 1 else {
                formError = "连接文件版本不受支持，请重新从服务器导出。"
                importNotice = nil
                return
            }
            let settings = document.settings
            draft = settings
            serverPortText = String(settings.serverPort)
            remotePortText = String(settings.remotePort)
            formError = nil
            importNotice = "连接文件已载入，点击保存后生效。"
        } catch {
            formError = "无法载入连接文件，请选择完整的 .connection.json 文件。"
            importNotice = nil
        }
    }

    private func importCAFile() {
        guard !model.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 PEM 格式 CA 证书"
        panel.prompt = "载入"
        panel.allowedContentTypes = ["pem", "crt", "cer", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard fileSize <= 64 * 1024 else {
                formError = "证书文件过大，请选择 PEM 文本格式的 CA 证书。"
                importNotice = nil
                return
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard data.count <= 64 * 1024, let certificate = String(data: data, encoding: .utf8),
                  certificate.contains("-----BEGIN CERTIFICATE-----"),
                  certificate.contains("-----END CERTIFICATE-----") else {
                formError = "请选择 PEM 文本格式的 CA 证书，文件需包含完整的证书起止行。"
                importNotice = nil
                return
            }
            draft.caCertificatePEM = certificate
            formError = nil
            importNotice = "CA 证书已载入，点击保存后生效。"
        } catch {
            formError = "无法读取 CA 证书，请重新选择 PEM 文本格式的证书文件。"
            importNotice = nil
        }
    }
}

private struct ImportedConnectionDocument: Decodable {
    let schemaVersion: Int
    let serverAddress: String
    let serverPort: Int
    let tlsServerName: String
    let publicURL: String
    let remotePort: Int
    let token: String
    let caCertificatePEM: String

    var settings: ConnectionSettings {
        ConnectionSettings(serverAddress: serverAddress, serverPort: serverPort,
                           tlsServerName: tlsServerName, publicURL: publicURL,
                           remotePort: remotePort, token: token, caCertificatePEM: caCertificatePEM)
    }
}

private extension ConnectionStatus {
    var indicatorColor: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }

    var menuSymbol: String {
        switch self {
        case .connected: "network"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.circle"
        case .disconnected: "link"
        }
    }
}
