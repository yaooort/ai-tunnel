import AppKit
import Combine
import Darwin
import Foundation
import Security
import ServiceManagement

enum ConnectionStatus: String, Sendable {
    case disconnected, connecting, connected, reconnecting, failed

    var title: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .reconnecting: return "正在重连"
        case .failed: return "连接失败"
        }
    }

    var symbolName: String {
        switch self {
        case .disconnected: return "circle"
        case .connecting, .reconnecting: return "arrow.triangle.2.circlepath"
        case .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }
}

/// The personal build reads its preset connection from the application resources.
private struct ConnectionConfiguration: Codable, Sendable {
    let schemaVersion: Int
    let serverAddress: String
    let serverPort: Int
    let tlsServerName: String
    let publicURL: String
    let remotePort: Int
    let caCertificatePEM: String
    let token: String

    func validate() throws {
        guard schemaVersion == 1 else {
            throw TunnelError.message("连接文件版本不受支持，请重新获取连接文件。")
        }
        let allowedHost = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !serverAddress.isEmpty, serverAddress.count <= 253,
              serverAddress.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              !tlsServerName.isEmpty, tlsServerName.count <= 253,
              tlsServerName.unicodeScalars.allSatisfy({ allowedHost.contains($0) }),
              (1...65535).contains(serverPort), (1...65535).contains(remotePort) else {
            throw TunnelError.message("连接文件中的服务器地址或端口无效。")
        }
        guard let url = URL(string: publicURL), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw TunnelError.message("连接文件中的公网地址必须是有效的 HTTPS 地址。")
        }
        guard (16...4096).contains(token.utf8.count),
              !token.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw TunnelError.message("连接文件中的认证凭据无效。")
        }
        let certificateData = caCertificatePEM
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard caCertificatePEM.contains("-----BEGIN CERTIFICATE-----"),
              let der = Data(base64Encoded: certificateData),
              SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw TunnelError.message("连接文件中的 CA 证书无效。")
        }
    }
}

private enum TunnelError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

private enum ConnectionKeychain {
    static let service = "vip.k-line.aitunnel.connection"
    static let account = "active-connection"

    static func load(service: String) throws -> ConnectionConfiguration? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TunnelError.message("无法读取钥匙串中的连接配置（\(status)）。请解锁登录钥匙串后重试。")
        }
        let configuration = try JSONDecoder().decode(ConnectionConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    static func save(_ configuration: ConnectionConfiguration, service: String) throws {
        let data = try JSONEncoder().encode(configuration)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "AI Tunnel 连接凭据"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw TunnelError.message("无法保存连接凭据到钥匙串（\(status)）。")
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var localPort: String = "8080" {
        didSet {
            guard !restoringLocalPort else { return }
            if isRunning {
                restoringLocalPort = true
                localPort = oldValue
                restoringLocalPort = false
                return
            }
            defaults.set(localPort, forKey: "aiTunnel.localPort")
        }
    }
    @Published private(set) var status: ConnectionStatus = .disconnected
    @Published private(set) var statusText: String = "未连接"
    @Published private(set) var detailText: String = "点击连接，将本机服务连接到公网。"
    @Published private(set) var logs: [String] = []
    @Published private(set) var hasCredentials: Bool = false
    @Published var autoConnect: Bool = false {
        didSet { defaults.set(autoConnect, forKey: "aiTunnel.autoConnect") }
    }
    @Published private(set) var launchAtLogin: Bool = false
    @Published var errorMessage: String?

    var publicURL: String { configuration?.publicURL ?? "https://tunnel.example.com" }
    var canConnect: Bool { hasCredentials && !isRunning && validatedPort != nil }
    var isRunning: Bool { wantsConnection || process != nil }

    private let defaults: UserDefaults
    private let keychainService: String
    private let runtimeOverride: URL?
    private let logOverride: URL?
    private let fileManager = FileManager.default
    private var configuration: ConnectionConfiguration?
    private var process: Process?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var runIdentifier: UUID?
    private var wantsConnection = false
    private var restoringLocalPort = false
    private var restartAttempt = 0
    private var restartTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var lockDescriptor: Int32 = -1
    private let maximumLogLines = 400
    private let maximumLogBytes = 2 * 1024 * 1024

    private var supportDirectory: URL {
        if let runtimeOverride { return runtimeOverride.deletingLastPathComponent() }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AITunnel", isDirectory: true)
    }
    private var runtimeDirectory: URL {
        runtimeOverride ?? supportDirectory.appendingPathComponent("runtime", isDirectory: true)
    }
    private var logDirectory: URL {
        logOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AITunnel", isDirectory: true)
    }
    private var logFile: URL { logDirectory.appendingPathComponent("frpc.log") }
    private var validatedPort: Int? {
        guard !localPort.isEmpty, localPort.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(localPort), (1...65535).contains(port) else { return nil }
        return port
    }

    init(defaults: UserDefaults = .standard, keychainServiceSuffix: String? = nil,
         runtimeDirectoryOverride: URL? = nil, logDirectoryOverride: URL? = nil,
         presetConnectionURL: URL? = Bundle.main.url(forResource: "preset-connection", withExtension: "json")) {
        self.defaults = defaults
        keychainService = ConnectionKeychain.service + (keychainServiceSuffix.map { "." + $0 } ?? "")
        runtimeOverride = runtimeDirectoryOverride
        logOverride = logDirectoryOverride
        localPort = defaults.string(forKey: "aiTunnel.localPort") ?? "8080"
        autoConnect = defaults.bool(forKey: "aiTunnel.autoConnect")
        refreshLaunchAtLogin()
        do {
            if let presetConnectionURL {
                // A self-use build is ready on first launch, without a Keychain prompt.
                configuration = try Self.readConfiguration(from: presetConnectionURL)
            } else {
                configuration = try ConnectionKeychain.load(service: keychainService)
            }
            hasCredentials = configuration != nil
            if hasCredentials {
                detailText = "点击连接，将 127.0.0.1:\(localPort) 连接到公网。"
            } else {
                errorMessage = "应用连接配置缺失，请重新安装完整的 AI Tunnel。"
                detailText = "应用连接配置缺失。"
            }
        } catch {
            errorMessage = "无法读取应用连接配置，请重新安装完整的 AI Tunnel。"
            detailText = "应用连接配置不可用。"
        }
        if autoConnect && hasCredentials {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                self?.connect()
            }
        }
    }

    /// Kept for isolated developer verification; the personal app needs no import flow.
    func importConnection(from url: URL) throws {
        guard !isRunning else {
            throw TunnelError.message("请先断开连接，再导入新的连接配置。")
        }
        let imported = try Self.readConfiguration(from: url)
        try ConnectionKeychain.save(imported, service: keychainService)
        configuration = imported
        hasCredentials = true
        errorMessage = nil
        setStatus(.disconnected, detail: "点击连接，将 127.0.0.1:\(localPort) 连接到公网。")
        appendLog("已加载连接配置。")
    }

    private static func readConfiguration(from url: URL) throws -> ConnectionConfiguration {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 128 * 1024 else {
            throw TunnelError.message("连接文件过大，请选择正确的 JSON 连接文件。")
        }
        let data = try Data(contentsOf: url)
        let imported: ConnectionConfiguration
        do {
            imported = try JSONDecoder().decode(ConnectionConfiguration.self, from: data)
        } catch {
            throw TunnelError.message("连接文件格式不正确，请选择完整的 AI Tunnel 连接 JSON。")
        }
        try imported.validate()
        return imported
    }

    func connect() {
        guard !isRunning else { return }
        guard configuration != nil else {
            errorMessage = "应用连接配置不可用，请重新安装完整的 AI Tunnel。"
            return
        }
        guard validatedPort != nil else {
            errorMessage = "本机端口必须是 1 到 65535 的整数。"
            return
        }
        guard !fileManager.fileExists(atPath: "/Library/LaunchDaemons/vip.k-line.aitunnel.frpc.plist") else {
            errorMessage = "已安装 AI Tunnel 系统后台服务。请先使用卸载脚本移除系统服务，再使用界面连接，避免重复占用转发端口。"
            return
        }
        errorMessage = nil
        do {
            try prepareDirectories()
            try acquireRuntimeLock()
        } catch {
            setStatus(.failed, detail: "无法准备本机隧道运行环境。")
            errorMessage = error.localizedDescription
            return
        }
        wantsConnection = true
        restartAttempt = 0
        setStatus(.connecting, detail: "正在建立加密隧道，等待服务器确认转发端口。")
        appendLog("开始连接，本机服务端口 \(localPort)。")
        startProcess()
    }

    func disconnect() {
        wantsConnection = false
        restartTask?.cancel()
        restartTask = nil
        stopTask?.cancel()
        setStatus(.disconnected, detail: "已断开连接，公网转发已停止。")
        appendLog("用户断开连接。")
        guard let currentProcess = process else {
            cleanRuntimeFiles()
            releaseRuntimeLock()
            return
        }
        if currentProcess.isRunning { currentProcess.terminate() }
        let identifier = runIdentifier
        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self,
                  self.runIdentifier == identifier, let child = self.process,
                  child.isRunning, !self.wantsConnection else { return }
            Darwin.kill(child.processIdentifier, SIGKILL)
        }
    }

    func copyPublicURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL, forType: .string)
    }

    func openPublicURL() {
        guard let url = URL(string: publicURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLaunchAtLogin()
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                errorMessage = "请在系统设置 → 通用 → 登录项中允许 AI Tunnel 登录启动。"
            }
        } catch {
            refreshLaunchAtLogin()
            errorMessage = "无法修改登录启动设置，请将 AI Tunnel 放入应用程序文件夹后重试。"
        }
    }

    func clearLogs() {
        logs.removeAll()
        try? secureWrite(Data(), to: logFile)
    }

    func revealLogs() {
        try? prepareDirectories()
        if !fileManager.fileExists(atPath: logFile.path) {
            try? secureWrite(Data(), to: logFile)
        }
        NSWorkspace.shared.activateFileViewerSelecting([logFile])
    }

    /// Called from applicationWillTerminate. Do not leave the bundled frpc orphaned.
    func shutdown() {
        wantsConnection = false
        restartTask?.cancel()
        stopTask?.cancel()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let child = process, child.isRunning {
            child.terminate()
            let deadline = Date().addingTimeInterval(1)
            while child.isRunning && Date() < deadline { usleep(20_000) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        process = nil
        runIdentifier = nil
        outputPipe = nil
        cleanRuntimeFiles()
        releaseRuntimeLock()
    }

    private func refreshLaunchAtLogin() {
        let serviceStatus = SMAppService.mainApp.status
        launchAtLogin = serviceStatus == .enabled || serviceStatus == .requiresApproval
    }

    private func setStatus(_ newStatus: ConnectionStatus, detail: String) {
        status = newStatus
        statusText = newStatus.title
        detailText = detail
    }

    private func startProcess() {
        guard wantsConnection, let configuration, let port = validatedPort else { return }
        do {
            try writeRuntimeConfiguration(configuration, localPort: port)
            guard let resourceURL = Bundle.main.resourceURL else {
                throw TunnelError.message("应用资源缺失，请重新安装完整的 AI Tunnel.app。")
            }
            let executable = resourceURL.appendingPathComponent("bin/frpc")
            guard fileManager.isExecutableFile(atPath: executable.path) else {
                throw TunnelError.message("应用内的 frpc 程序缺失或没有执行权限，请重新安装应用。")
            }
            let child = Process()
            child.executableURL = executable
            child.arguments = ["-c", runtimeDirectory.appendingPathComponent("frpc.toml").path]
            child.currentDirectoryURL = runtimeDirectory
            // frp reads http_proxy even when transport.proxyURL is empty.
            child.environment = ProcessInfo.processInfo.environment.filter {
                !$0.key.lowercased().hasSuffix("_proxy")
            }
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = pipe
            child.standardInput = FileHandle.nullDevice
            let identifier = UUID()
            outputBuffer.removeAll(keepingCapacity: true)
            runIdentifier = identifier
            outputPipe = pipe
            process = child
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor [weak self] in self?.consumeOutput(data, identifier: identifier) }
            }
            child.terminationHandler = { [weak self] child in
                let exitStatus = child.terminationStatus
                Task { @MainActor [weak self] in
                    self?.processDidExit(identifier: identifier, exitStatus: exitStatus)
                }
            }
            try child.run()
            try secureWrite(Data("\(child.processIdentifier)\n".utf8),
                            to: runtimeDirectory.appendingPathComponent("frpc.pid"))
        } catch {
            // A launched process must be stopped even if writing its PID file failed.
            outputPipe?.fileHandleForReading.readabilityHandler = nil
            if let child = process, child.isRunning { child.terminate() }
            process = nil
            outputPipe = nil
            runIdentifier = nil
            wantsConnection = false
            cleanRuntimeFiles()
            releaseRuntimeLock()
            setStatus(.failed, detail: "无法启动本机隧道。")
            errorMessage = error.localizedDescription
            appendLog("本机隧道启动失败。")
        }
    }

    private func consumeOutput(_ data: Data, identifier: UUID) {
        guard runIdentifier == identifier else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 10) {
            let line = String(decoding: outputBuffer[..<newline], as: UTF8.self)
            outputBuffer.removeSubrange(...newline)
            processLogLine(line)
        }
        // Keep memory bounded even if a child unexpectedly emits a line without a newline.
        if outputBuffer.count > 64 * 1024 {
            processLogLine(String(decoding: outputBuffer.prefix(64 * 1024), as: UTF8.self))
            outputBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func processLogLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        appendLog(line)
        guard wantsConnection else { return }
        let lower = line.lowercased()
        if lower.contains("start proxy success") {
            restartAttempt = 0
            setStatus(.connected, detail: "隧道已建立，公网请求将转发到 127.0.0.1:\(localPort)。")
        } else if lower.contains("login to server success") {
            setStatus(status == .reconnecting ? .reconnecting : .connecting,
                      detail: "服务器认证成功，正在注册转发端口。")
        } else if lower.contains("connect to local service") &&
                    (lower.contains("error") || lower.contains("refused") || lower.contains("failed")) {
            detailText = "隧道已建立，但本机 \(localPort) 服务不可达，请确认业务服务正在运行。"
        } else if lower.contains("start error") || lower.contains("start proxy error") {
            setStatus(.failed, detail: "转发端口注册失败，隧道尚不可用。可展开日志查看原因，frpc 将继续尝试注册。")
        } else if lower.contains("login to server failed") || lower.contains("connect to server error") ||
                    lower.contains("control connection closed") || lower.contains("session shutdown") ||
                    lower.contains("connection closed") || lower.contains("reconnect to server") {
            setStatus(.reconnecting, detail: "隧道连接中断，正在自动重连。")
        } else if lower.contains("try to connect to server") && status == .connected {
            setStatus(.reconnecting, detail: "正在重新连接中转服务器。")
        }
    }

    private func processDidExit(identifier: UUID, exitStatus: Int32) {
        guard runIdentifier == identifier else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if !outputBuffer.isEmpty {
            processLogLine(String(decoding: outputBuffer, as: UTF8.self))
            outputBuffer.removeAll(keepingCapacity: true)
        }
        process = nil
        outputPipe = nil
        runIdentifier = nil
        stopTask?.cancel()
        stopTask = nil
        cleanRuntimeFiles()
        guard wantsConnection else {
            releaseRuntimeLock()
            setStatus(.disconnected, detail: "已断开连接，公网转发已停止。")
            return
        }
        restartAttempt += 1
        let delay = min(30, 1 << min(restartAttempt - 1, 5))
        setStatus(.reconnecting, detail: "隧道进程已退出，将在 \(delay) 秒后自动恢复。")
        appendLog("frpc 退出，状态码 \(exitStatus)，\(delay) 秒后重启。")
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.startProcess()
        }
    }

    private func prepareDirectories() throws {
        for directory in [supportDirectory, runtimeDirectory, logDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    private func acquireRuntimeLock() throws {
        guard lockDescriptor == -1 else { return }
        let path = runtimeDirectory.appendingPathComponent("client.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw TunnelError.message("无法创建运行锁，请检查应用支持目录权限。")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw TunnelError.message("另一个 AI Tunnel 实例正在连接，请先断开另一实例。")
        }
        _ = fchmod(descriptor, 0o600)
        lockDescriptor = descriptor
    }

    private func releaseRuntimeLock() {
        guard lockDescriptor >= 0 else { return }
        _ = flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }

    private func writeRuntimeConfiguration(_ configuration: ConnectionConfiguration, localPort: Int) throws {
        try prepareDirectories()
        let tokenFile = runtimeDirectory.appendingPathComponent("token")
        let caFile = runtimeDirectory.appendingPathComponent("ca.crt")
        try secureWrite(Data(configuration.token.utf8), to: tokenFile)
        try secureWrite(Data(configuration.caCertificatePEM.utf8), to: caFile)
        let configurationText = """
        serverAddr = \(tomlString(configuration.serverAddress))
        serverPort = \(configuration.serverPort)
        loginFailExit = false

        auth.method = "token"
        auth.additionalScopes = ["NewWorkConns"]
        auth.tokenSource.type = "file"
        auth.tokenSource.file.path = \(tomlString(tokenFile.path))

        transport.protocol = "tcp"
        transport.proxyURL = ""
        transport.dialServerTimeout = 10
        transport.dialServerKeepalive = 15
        transport.tcpMux = true
        transport.tcpMuxKeepaliveInterval = 30
        transport.heartbeatInterval = -1
        transport.heartbeatTimeout = -1
        transport.tls.enable = true
        transport.tls.serverName = \(tomlString(configuration.tlsServerName))
        transport.tls.trustedCaFile = \(tomlString(caFile.path))

        log.to = "console"
        log.level = "info"
        log.disablePrintColor = true

        [[proxies]]
        name = "ai-http2"
        type = "tcp"
        localIP = "127.0.0.1"
        localPort = \(localPort)
        remotePort = \(configuration.remotePort)
        """
        try secureWrite(Data(configurationText.utf8), to: runtimeDirectory.appendingPathComponent("frpc.toml"))
    }

    private func cleanRuntimeFiles() {
        // A second GUI instance must never delete the active instance's credentials.
        guard lockDescriptor >= 0 else { return }
        for filename in ["token", "ca.crt", "frpc.toml", "frpc.pid"] {
            try? fileManager.removeItem(at: runtimeDirectory.appendingPathComponent(filename))
        }
    }

    /// Create a private temporary file before atomically replacing its destination.
    private func secureWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer {
            Darwin.close(descriptor)
            try? fileManager.removeItem(at: temporary)
        }
        try data.withUnsafeBytes { buffer in
            guard let start = buffer.baseAddress else { return }
            var written = 0
            while written < data.count {
                let count = Darwin.write(descriptor, start.advanced(by: written), data.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0, Darwin.rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    private func sanitizedLog(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        if let token = configuration?.token, !token.isEmpty {
            result = result.replacingOccurrences(of: token, with: "[已隐藏]")
        }
        result = result.replacingOccurrences(
            of: "(?i)(token|password|authorization|secret)([\\s:=]+)([^\\s,;]+)",
            with: "$1$2[已隐藏]", options: .regularExpression)
        return String(result.prefix(16 * 1024))
    }

    private func appendLog(_ rawLine: String) {
        let sanitized = sanitizedLog(rawLine)
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(sanitized)"
        logs.append(line)
        if logs.count > maximumLogLines { logs.removeFirst(logs.count - maximumLogLines) }
        do {
            try prepareDirectories()
            if let size = try? fileManager.attributesOfItem(atPath: logFile.path)[.size] as? NSNumber,
               size.intValue >= maximumLogBytes {
                let previous = logDirectory.appendingPathComponent("frpc.previous.log")
                try? fileManager.removeItem(at: previous)
                try fileManager.moveItem(at: logFile, to: previous)
            }
            if !fileManager.fileExists(atPath: logFile.path) { try secureWrite(Data(), to: logFile) }
            let descriptor = Darwin.open(logFile.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            _ = fchmod(descriptor, 0o600)
            let data = Data((line + "\n").utf8)
            data.withUnsafeBytes { buffer in
                if let start = buffer.baseAddress { _ = Darwin.write(descriptor, start, data.count) }
            }
        } catch {
            // Logging failure must not prevent the tunnel from reconnecting.
        }
    }
}
