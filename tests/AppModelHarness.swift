import AppKit
import Darwin
import Foundation
import Security

private struct HarnessFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class TestContext {
    let identifier = UUID().uuidString
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let model: AppModel

    var runtime: URL { directory.appendingPathComponent("runtime", isDirectory: true) }
    var logDirectory: URL { directory.appendingPathComponent("logs", isDirectory: true) }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AITunnel-test-\(identifier)", isDirectory: true)
        suite = "vip.k-line.aitunnel.tests.\(identifier)"
        guard let isolatedDefaults = UserDefaults(suiteName: suite) else {
            throw HarnessFailure(message: "Cannot create isolated UserDefaults.")
        }
        defaults = isolatedDefaults
        model = AppModel(defaults: isolatedDefaults, keychainServiceSuffix: identifier,
                         runtimeDirectoryOverride: directory.appendingPathComponent("runtime"),
                         logDirectoryOverride: directory.appendingPathComponent("logs"),
                         presetConnectionURL: nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    func duplicateModel(presetConnectionURL: URL? = nil) -> AppModel {
        AppModel(defaults: defaults, keychainServiceSuffix: identifier,
                 runtimeDirectoryOverride: runtime, logDirectoryOverride: logDirectory,
                 presetConnectionURL: presetConnectionURL)
    }

    func keychainSnapshot() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vip.k-line.aitunnel.connection.\(identifier)",
            kSecAttrAccount as String: "active-connection",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw HarnessFailure(message: "Cannot inspect isolated test Keychain item.")
        }
        return data
    }

    func cleanup() {
        model.shutdown()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vip.k-line.aitunnel.connection.\(identifier)",
            kSecAttrAccount as String: "active-connection",
        ]
        SecItemDelete(query as CFDictionary)
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@main
@MainActor
private struct AppModelHarness {
    static func main() async {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.isEmpty {
                try await runSelfTests()
            } else {
                try await runLive(arguments)
            }
        } catch {
            emit(["event": "failure", "message": error.localizedDescription])
            Darwin.exit(1)
        }
    }

    private static func emit(_ object: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw HarnessFailure(message: message) }
    }

    private static func eventually(timeout: TimeInterval = 5,
                                   _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private static func fixture(in directory: URL, token: String) throws -> URL {
        let certificate = directory.appendingPathComponent("test-ca.crt")
        let key = directory.appendingPathComponent("test-ca.key")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        child.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                           "-subj", "/CN=AITunnel-Isolated-Test", "-keyout", key.path,
                           "-out", certificate.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        child.waitUntilExit()
        try check(child.terminationStatus == 0, "Cannot create isolated test certificate.")
        let object: [String: Any] = [
            "schemaVersion": 1, "serverAddress": "127.0.0.1", "serverPort": 7000,
            "tlsServerName": "test.invalid", "publicURL": "https://test.invalid",
            "remotePort": 18080,
            "caCertificatePEM": try String(contentsOf: certificate, encoding: .utf8),
            "token": token,
        ]
        let url = directory.appendingPathComponent("test-connection.json")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func malformedFixture(_ source: URL, directory: URL,
                                         change: (inout [String: Any]) -> Void) throws -> URL {
        let data = try Data(contentsOf: source)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessFailure(message: "Invalid local test fixture.")
        }
        change(&object)
        let url = directory.appendingPathComponent("invalid-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    private static func runSelfTests() async throws {
        guard !FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/vip.k-line.aitunnel.frpc.plist") else {
            throw HarnessFailure(message: "System daemon is installed. Run lifecycle tests after uninstalling it.")
        }
        let context = try TestContext()
        defer { context.cleanup(); unsetenv("AI_TUNNEL_HARNESS_MODE") }
        let model = context.model
        model.connect()
        try check(!model.isRunning && model.errorMessage != nil, "Missing credentials were not rejected.")
        emit(["event": "pass", "test": "missing_credentials"])

        let token = "ISOLATED_TEST_SECRET_\(UUID().uuidString)"
        let valid = try fixture(in: context.directory, token: token)
        try verifyPresetConfiguration(valid, token: token)
        let invalidVariants: [(String, (inout [String: Any]) -> Void)] = [
            ("schema", { $0["schemaVersion"] = 2 }),
            ("server", { $0["serverAddress"] = "host\nserverPort=1" }),
            ("port", { $0["serverPort"] = 65536 }),
            ("certificate", { $0["caCertificatePEM"] = "not-a-certificate" }),
            ("credential", { $0["token"] = "short" }),
            ("public_url", { $0["publicURL"] = "http://test.invalid" }),
        ]
        for (name, change) in invalidVariants {
            let invalid = try malformedFixture(valid, directory: context.directory, change: change)
            var rejected = false
            do { try model.importConnection(from: invalid) } catch { rejected = true }
            try check(rejected && !model.hasCredentials, "Invalid import was accepted: \(name).")
        }
        let malformed = context.directory.appendingPathComponent("malformed.json")
        try Data("{invalid json}".utf8).write(to: malformed)
        var malformedRejected = false
        do { try model.importConnection(from: malformed) } catch { malformedRejected = true }
        try check(malformedRejected, "Malformed JSON was accepted.")
        emit(["event": "pass", "test": "import_validation", "cases": invalidVariants.count + 1])

        try model.importConnection(from: valid)
        try check(model.hasCredentials, "Valid import did not enable connecting.")
        let restored = context.duplicateModel()
        try check(restored.hasCredentials, "Keychain configuration did not restore.")
        restored.shutdown()
        let persisted = context.defaults.persistentDomain(forName: context.suite) ?? [:]
        try check(!persisted.values.contains(where: { String(describing: $0).contains(token) }),
                  "Credential was persisted outside Keychain.")
        emit(["event": "pass", "test": "keychain_restore_no_plaintext_defaults"])

        for port in ["0", "65536", "abc", "-1", ""] {
            model.localPort = port
            model.connect()
            try check(!model.isRunning && !model.canConnect && model.errorMessage != nil,
                      "Invalid local port was accepted.")
        }
        model.localPort = "8080"
        emit(["event": "pass", "test": "local_port_validation", "cases": 5])

        setenv("AI_TUNNEL_HARNESS_MODE", "connect", 1)
        setenv("http_proxy", "http://127.0.0.1:1", 1)
        setenv("HTTPS_PROXY", "http://127.0.0.1:1", 1)
        model.connect()
        try check(await eventually { model.status == .connected }, "Fake tunnel never became connected.")
        try check(model.isRunning, "Connected tunnel is not running.")
        model.localPort = "9090"
        try check(model.localPort == "8080", "Port changed while connected.")
        for filename in ["token", "ca.crt", "frpc.toml", "frpc.pid", "client.lock"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: context.runtime.appendingPathComponent(filename).path)
            try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                      "Runtime file is not private: \(filename).")
        }
        try check(await eventually { model.logs.contains(where: { $0.contains("[已隐藏]") }) },
                  "Secret-bearing fake log was not handled.")
        try check(!model.logs.joined().contains(token), "Secret leaked to the UI log.")
        let diskLog = try String(contentsOf: context.logDirectory.appendingPathComponent("frpc.log"), encoding: .utf8)
        try check(!diskLog.contains(token) && !diskLog.contains("TEST_PASSWORD_VALUE"), "Secret leaked to the disk log.")
        let duplicate = context.duplicateModel()
        duplicate.connect()
        try check(!duplicate.isRunning && duplicate.errorMessage != nil, "Duplicate runtime lock was not enforced.")
        duplicate.shutdown()
        try check(FileManager.default.fileExists(atPath: context.runtime.appendingPathComponent("token").path),
                  "Duplicate shutdown deleted active runtime credentials.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Disconnect did not stop the child process.")
        try check(!FileManager.default.fileExists(atPath: context.runtime.appendingPathComponent("token").path),
                  "Disconnect did not remove runtime credentials.")
        emit(["event": "pass", "test": "connection_private_files_redaction_proxy_environment_duplicate_lock_disconnect"])

        setenv("AI_TUNNEL_HARNESS_MODE", "login-only", 1)
        model.connect()
        try check(await eventually { model.logs.contains(where: { $0.contains("login to server success") }) },
                  "Login-only fake never authenticated.")
        try? await Task.sleep(for: .milliseconds(150))
        try check(model.status == .connecting, "Login success incorrectly marked the tunnel connected.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Login-only child did not stop.")
        emit(["event": "pass", "test": "login_success_is_not_proxy_success"])

        setenv("AI_TUNNEL_HARNESS_MODE", "proxy-error", 1)
        model.connect()
        try check(await eventually { model.status == .failed }, "Proxy registration failure was not shown as failed.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Proxy-error child did not stop.")
        emit(["event": "pass", "test": "remote_port_conflict_is_failed"])

        setenv("AI_TUNNEL_HARNESS_MODE", "restart-once", 1)
        model.connect()
        try check(await eventually { model.status == .reconnecting }, "Unexpected process exit did not enter recovery.")
        try check(await eventually { model.status == .connected }, "Unexpected process exit did not recover.")
        try check(model.logs.contains(where: { $0.contains("状态码 42") }), "Recovery did not record the exit reason.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Recovered child did not stop.")
        emit(["event": "pass", "test": "unexpected_exit_recovers_with_backoff"])

        setenv("AI_TUNNEL_HARNESS_MODE", "crash", 1)
        model.connect()
        try check(await eventually { model.status == .reconnecting }, "Crashing child did not enter recovery.")
        model.disconnect()
        try? await Task.sleep(for: .milliseconds(1300))
        try check(!model.isRunning && model.status == .disconnected,
                  "User disconnect did not cancel the pending process restart.")
        emit(["event": "pass", "test": "user_disconnect_cancels_pending_restart"])

        setenv("AI_TUNNEL_HARNESS_MODE", "reconnect", 1)
        model.connect()
        try check(await eventually { model.status == .connected }, "Reconnect fake never initially connected.")
        try check(await eventually { model.status == .reconnecting }, "Control closure did not enter reconnecting.")
        try check(await eventually { model.status == .connected }, "Control closure did not recover.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Reconnected child did not stop.")
        emit(["event": "pass", "test": "control_connection_loss_recovers"])

        let largeLog = Data(repeating: 65, count: 2 * 1024 * 1024 + 1)
        try largeLog.write(to: context.logDirectory.appendingPathComponent("frpc.log"))
        setenv("AI_TUNNEL_HARNESS_MODE", "connect", 1)
        model.connect()
        try check(await eventually { model.status == .connected }, "Rotation test did not connect.")
        try check(FileManager.default.fileExists(atPath: context.logDirectory.appendingPathComponent("frpc.previous.log").path),
                  "Oversized log did not rotate.")
        model.disconnect()
        try check(await eventually { !model.isRunning }, "Rotation child did not stop.")
        model.clearLogs()
        try check(model.logs.isEmpty, "Clearing logs did not clear UI history.")
        let attributes = try FileManager.default.attributesOfItem(atPath: context.logDirectory.appendingPathComponent("frpc.log").path)
        try check((attributes[.size] as? NSNumber)?.intValue == 0, "Clearing logs did not truncate current disk log.")
        emit(["event": "pass", "test": "log_rotation_and_clear"])

        model.connect()
        try check(await eventually { model.status == .connected }, "Shutdown test did not connect.")
        let pidText = try String(contentsOf: context.runtime.appendingPathComponent("frpc.pid"), encoding: .utf8)
        guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HarnessFailure(message: "Shutdown test PID is invalid.")
        }
        model.shutdown()
        try check(await eventually { Darwin.kill(pid, 0) != 0 }, "Shutdown left the child process running.")
        try check(!model.isRunning && !FileManager.default.fileExists(atPath: context.runtime.appendingPathComponent("token").path),
                  "Shutdown left runtime credentials behind.")
        emit(["event": "pass", "test": "application_shutdown_stops_child_and_cleans_runtime"])
        emit(["event": "complete", "mode": "isolated_self_tests", "passed": 15])
    }

    private static func verifyPresetConfiguration(_ valid: URL, token: String) throws {
        let context = try TestContext()
        defer { context.cleanup() }
        try check(try context.keychainSnapshot() == nil, "Preset test unexpectedly has an old Keychain item.")
        let presetOnly = context.duplicateModel(presetConnectionURL: valid)
        defer { presetOnly.shutdown() }
        try check(presetOnly.hasCredentials && presetOnly.canConnect && presetOnly.errorMessage == nil,
                  "Valid preset did not enable connecting without an import.")
        try check(try context.keychainSnapshot() == nil, "Preset startup wrote credentials to Keychain.")
        emit(["event": "pass", "test": "preset_starts_without_import_or_keychain_item"])

        try context.model.importConnection(from: valid)
        guard let oldItem = try context.keychainSnapshot() else {
            throw HarnessFailure(message: "Cannot seed isolated old connection for fallback checks.")
        }
        let preferredPreset = try malformedFixture(valid, directory: context.directory) {
            $0["publicURL"] = "https://preset.test.invalid"
        }
        let presetOverOldItem = context.duplicateModel(presetConnectionURL: preferredPreset)
        defer { presetOverOldItem.shutdown() }
        try check(presetOverOldItem.hasCredentials && presetOverOldItem.canConnect &&
                  presetOverOldItem.publicURL == "https://preset.test.invalid",
                  "Preset did not take priority over the old Keychain connection.")
        try check(try context.keychainSnapshot() == oldItem, "Preset startup changed the old Keychain item.")
        emit(["event": "pass", "test": "preset_precedes_old_keychain_without_mutation"])

        let invalidSchema = try malformedFixture(valid, directory: context.directory) { $0["schemaVersion"] = 99 }
        let malformed = context.directory.appendingPathComponent("malicious-preset.json")
        try Data(("{\"token\":\"" + token + "\", invalid}").utf8).write(to: malformed)
        let missing = context.directory.appendingPathComponent("missing-preset.json")
        for invalidPreset in [invalidSchema, malformed, missing] {
            let invalidModel = context.duplicateModel(presetConnectionURL: invalidPreset)
            defer { invalidModel.shutdown() }
            try check(!invalidModel.hasCredentials && !invalidModel.canConnect && invalidModel.errorMessage != nil,
                      "Invalid preset silently fell back to the old Keychain connection.")
            let visibleError = (invalidModel.errorMessage ?? "") + invalidModel.detailText + invalidModel.logs.joined()
            try check(!visibleError.contains(token), "Invalid preset exposed a credential in a visible error.")
            try check(try context.keychainSnapshot() == oldItem, "Invalid preset changed the old Keychain item.")
        }
        emit(["event": "pass", "test": "invalid_preset_never_falls_back_or_exposes_credentials", "cases": 3])
    }

    private static func runLive(_ arguments: [String]) async throws {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--connection", "--port", "--duration"].contains(key), index + 1 < arguments.count,
                  options[key] == nil else {
                throw HarnessFailure(message: "Usage: --connection FILE --port PORT --duration SECONDS")
            }
            options[key] = arguments[index + 1]
            index += 2
        }
        guard let connection = options["--connection"],
              let duration = Double(options["--duration"] ?? "15"), (1...600).contains(duration) else {
            throw HarnessFailure(message: "Connection file and duration between 1 and 600 seconds are required.")
        }
        let context = try TestContext()
        defer { context.cleanup() }
        let model = context.duplicateModel(presetConnectionURL: URL(fileURLWithPath: connection))
        defer { model.shutdown() }
        guard model.hasCredentials else {
            throw HarnessFailure(message: model.errorMessage ?? "The connection preset is invalid.")
        }
        model.localPort = options["--port"] ?? "8080"
        guard model.canConnect else { throw HarnessFailure(message: "Invalid local port or unavailable credentials.") }
        model.connect()
        guard model.isRunning else {
            throw HarnessFailure(message: model.errorMessage ?? "Could not start the tunnel.")
        }
        let started = Date()
        var previousStatus = ""
        var previousDetail = ""
        var everConnected = false
        while Date().timeIntervalSince(started) < duration {
            everConnected = everConnected || model.status == .connected
            if model.status.rawValue != previousStatus || model.detailText != previousDetail {
                previousStatus = model.status.rawValue
                previousDetail = model.detailText
                emit(["event": "state", "status": model.status.rawValue, "detail": model.detailText,
                      "elapsedSeconds": Int(Date().timeIntervalSince(started)), "running": model.isRunning])
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        model.disconnect()
        _ = await eventually(timeout: 3) { !model.isRunning }
        emit(["event": "complete", "mode": "connection", "everConnected": everConnected,
              "runtimeStopped": !model.isRunning])
        try check(everConnected, "Tunnel never reached proxy registration success during the observation window.")
    }
}
