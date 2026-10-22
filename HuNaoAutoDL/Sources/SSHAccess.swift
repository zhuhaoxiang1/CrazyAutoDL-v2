import Foundation

struct ProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs a child process and waits for it. Output goes to temporary files instead of pipes: `ssh` with
/// ControlPersist leaves a background master behind, and a pipe it inherits would never reach EOF.
enum ProcessRunner {
    nonisolated static func runSync(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> ProcessResult {
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appendingPathComponent("hunao-proc-\(UUID().uuidString).out")
        let errURL = directory.appendingPathComponent("hunao-proc-\(UUID().uuidString).err")
        for url in [outURL, errURL] {
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }

        func text(_ url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return ProcessResult(
            status: process.terminationStatus,
            stdout: text(outURL),
            stderr: text(errURL),
            timedOut: timedOut
        )
    }

    nonisolated static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            try runSync(executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
    }
}

enum SSHAccessError: LocalizedError {
    case noPassword
    case keyGeneration(String)
    case invalidPublicKey
    case rejected(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noPassword:
            return "AutoDL 没有返回这台实例的 root 密码，请在实例详情里手动执行 ssh-copy-id。"
        case .keyGeneration(let message):
            return "生成 SSH 密钥失败：\(message)"
        case .invalidPublicKey:
            return "~/.ssh/id_ed25519.pub 不是有效的公钥。"
        case .rejected(let message):
            return message.isEmpty ? "服务器拒绝了密码登录。" : message
        case .timedOut:
            return "连接超时，请确认实例已开机。"
        }
    }
}

/// Passwordless SSH to AutoDL instances: checks the alias, and installs the local public key with the
/// root password AutoDL returned. The password only travels in a child process's environment.
enum SSHAccess {
    static let sshPath = "/usr/bin/ssh"
    static let keygenPath = "/usr/bin/ssh-keygen"

    /// Fixed script that prints `$HUNAO_SSH_PASSWORD`. It contains no secret, so it is safe to leave on disk.
    static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$HUNAO_SSH_PASSWORD\"\n"

    static func sshDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".ssh", isDirectory: true)
    }

    static func privateKeyURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        sshDirectory(home: home).appendingPathComponent("id_ed25519")
    }

    // MARK: - Check

    static func checkArguments(alias: String) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", alias, "true"]
    }

    /// Reads an `ssh <alias> true` outcome. 255 is ssh's own failure, so the message tells a refused key
    /// apart from a host that is not reachable (yet).
    static func classify(_ result: ProcessResult) -> SSHKeyStatus {
        if result.succeeded { return .ready }
        if result.timedOut { return .unreachable }
        let message = result.stderr.lowercased()
        if message.contains("permission denied") || message.contains("too many authentication failures") {
            return .needsSetup
        }
        if message.contains("host key verification failed") || message.contains("remote host identification has changed") {
            return .failed("主机密钥与记录不一致，请检查 ~/.ssh/hunao_known_hosts")
        }
        return .unreachable
    }

    static func check(alias: String) async -> SSHKeyStatus {
        do {
            let result = try await ProcessRunner.run(sshPath, arguments: checkArguments(alias: alias), timeout: 20)
            return classify(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Setup

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Adds `publicKey` to authorized_keys once and fixes the permissions sshd insists on.
    static func installCommand(publicKey: String) -> String {
        let key = shellQuote(publicKey)
        return "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
            + "grep -qxF \(key) ~/.ssh/authorized_keys || printf '%s\\n' \(key) >> ~/.ssh/authorized_keys; "
            + "chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"
    }

    static func passwordLoginArguments(alias: String, command: String) -> [String] {
        [
            "-o", "BatchMode=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
            // The password session must not become (or reuse) a shared master connection.
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            alias,
            command
        ]
    }

    /// Returns the single-line public key for `id_ed25519`, creating the key pair first when it is missing.
    static func ensurePublicKey(home: URL = FileManager.default.homeDirectoryForCurrentUser) async throws -> String {
        let privateKey = privateKeyURL(home: home)
        let publicKey = privateKey.appendingPathExtension("pub")
        if !FileManager.default.fileExists(atPath: privateKey.path) {
            try FileManager.default.createDirectory(
                at: sshDirectory(home: home),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let result = try await ProcessRunner.run(
                keygenPath,
                arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "hunao-autodl", "-f", privateKey.path],
                timeout: 30
            )
            guard result.succeeded else { throw SSHAccessError.keyGeneration(result.stderr) }
        } else if !FileManager.default.fileExists(atPath: publicKey.path) {
            // Private key without its .pub: derive it instead of generating a different key.
            let result = try await ProcessRunner.run(keygenPath, arguments: ["-y", "-f", privateKey.path], timeout: 30)
            guard result.succeeded else { throw SSHAccessError.keyGeneration(result.stderr) }
            try (result.stdout + "\n").write(to: publicKey, atomically: true, encoding: .utf8)
        }
        let line = (try? String(contentsOf: publicKey, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard line.hasPrefix("ssh-") || line.hasPrefix("ecdsa-") || line.hasPrefix("sk-") else {
            throw SSHAccessError.invalidPublicKey
        }
        return line
    }

    static func askpassURL() throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HuNaoAutoDL-v2", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("ssh-askpass.sh")
        let existing = try? String(contentsOf: url, encoding: .utf8)
        if existing != askpassScript {
            try askpassScript.write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Logs in with the root password once and installs the local public key.
    static func install(alias: String, password: String?) async throws {
        guard let password, !password.isEmpty else { throw SSHAccessError.noPassword }
        let publicKey = try await ensurePublicKey()
        let askpass = try askpassURL()
        let result = try await ProcessRunner.run(
            sshPath,
            arguments: passwordLoginArguments(alias: alias, command: installCommand(publicKey: publicKey)),
            environment: [
                "SSH_ASKPASS": askpass.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "HUNAO_SSH_PASSWORD": password
            ],
            timeout: 40
        )
        if result.timedOut { throw SSHAccessError.timedOut }
        guard result.succeeded else {
            if result.stderr.lowercased().contains("permission denied") {
                throw SSHAccessError.rejected("root 密码被拒绝，可能已在 AutoDL 控制台里改过。")
            }
            throw SSHAccessError.rejected(lastLine(of: result.stderr))
        }
    }

    private static func lastLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }
}
