import AppKit
import SwiftUI

@main
struct AITunnelApp: App {
    @NSApplicationDelegateAdaptor(AITunnelAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("AI Tunnel", id: "main") {
            TunnelWindow(model: model, appDelegate: appDelegate)
        }
        .defaultSize(width: 600, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("连接") {
                Button(model.isRunning ? "断开连接" : "连接") {
                    if model.isRunning { model.disconnect() } else { model.connect() }
                }
                .disabled(!model.isRunning && !model.canConnect)
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()
                Button("复制公网地址", action: model.copyPublicURL)
                Button("打开公网地址", action: model.openPublicURL)
            }
        }

        MenuBarExtra {
            TunnelMenu(model: model)
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
                        Text("公网地址")
                        Spacer(minLength: 8)
                        Text(model.publicURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button(action: model.copyPublicURL) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制公网地址")
                        .accessibilityLabel("复制公网地址")
                        Button(action: model.openPublicURL) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                        .help("在浏览器中打开公网地址")
                        .accessibilityLabel("在浏览器中打开公网地址")
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
            Text(model.detailText)
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
        if !model.hasCredentials { return "应用连接配置不可用，请重新安装" }
        if !model.canConnect { return "请输入有效的本机端口" }
        return "点击连接即可使用公网地址"
    }
}

private struct TunnelMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("AI Tunnel · \(model.statusText)")
        Text(model.publicURL)
        Divider()
        Button(model.isRunning ? "断开连接" : "连接") {
            if model.isRunning { model.disconnect() } else { model.connect() }
        }
        .disabled(!model.isRunning && !model.canConnect)
        Button("打开主窗口") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("复制公网地址", action: model.copyPublicURL)
        Button("打开公网地址", action: model.openPublicURL)
        Divider()
        Button("退出 AI Tunnel") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
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
