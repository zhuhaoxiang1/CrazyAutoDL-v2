import Foundation

struct SSHEndpoint: Equatable {
    let host: String
    let port: Int
    let user: String

    /// Parses AutoDL's `ssh_command`, e.g. `ssh -p 54635 root@connect.weste.seetacloud.com`.
    static func parse(_ command: String?) -> SSHEndpoint? {
        guard let command else { return nil }
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        var port = 22
        var target: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "-p", index + 1 < tokens.count, let value = Int(tokens[index + 1]) {
                port = value
                index += 1
            } else if token.hasPrefix("-p"), let value = Int(token.dropFirst(2)) {
                port = value
            } else if token.contains("@"), !token.hasPrefix("-") {
                target = token
            }
            index += 1
        }
        guard let target else { return nil }
        let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, (1...65_535).contains(port) else { return nil }
        return SSHEndpoint(host: parts[1], port: port, user: parts[0])
    }

    /// The key OpenSSH uses for this endpoint in known_hosts.
    var knownHostsKey: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

extension AutoDLInstance {
    var sshEndpoint: SSHEndpoint? { SSHEndpoint.parse(sshCommand) }
}

struct SSHHostEntry: Equatable {
    let alias: String
    /// Extra pattern on the same `Host` line, used for the stable monitoring-target alias.
    var extraAlias: String? = nil
    let instanceID: String
    let endpoint: SSHEndpoint
}

/// Builds the SSH aliases 胡闹AutoDL keeps in `~/.ssh/hunao_autodl.conf` and the files around it.
enum SSHConfigManager {
    static let managedFileName = "hunao_autodl.conf"
    static let knownHostsFileName = "hunao_known_hosts"
    static let includeLine = "Include ~/.ssh/hunao_autodl.conf"
    static let preferredTargetAlias = "autodl"
    static let fallbackTargetAlias = "autodl-target"

    /// Lowercases and turns anything outside `[a-z0-9-]` into `-`, collapsing runs and trimming the ends.
    static func sanitize(_ value: String) -> String {
        var result = ""
        for scalar in value.lowercased().unicodeScalars {
            let allowed = ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
            if allowed {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("-") {
                result.append("-")
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// One alias per instance: `autodl-<name>`. The result does not depend on the order of `items`:
    /// a name shared by several instances gets the account name, then the instance ID, appended.
    static func aliases(for items: [(instance: AutoDLInstance, accountName: String)]) -> [String: String] {
        let reserved: Set<String> = [preferredTargetAlias, fallbackTargetAlias]
        func base(_ instance: AutoDLInstance) -> String {
            let name = sanitize(instance.name)
            return "autodl-" + (name.isEmpty ? sanitize(instance.shortID) : name)
        }

        var byBase: [String: [(instance: AutoDLInstance, accountName: String)]] = [:]
        for item in items {
            byBase[base(item.instance), default: []].append(item)
        }

        var result: [String: String] = [:]
        for (alias, group) in byBase {
            if group.count == 1, !reserved.contains(alias) {
                result[group[0].instance.id] = alias
                continue
            }
            var withAccount: [String: Int] = [:]
            var candidates: [String: String] = [:]
            for item in group {
                let account = sanitize(item.accountName)
                let candidate = account.isEmpty ? alias : alias + "-" + account
                candidates[item.instance.id] = candidate
                withAccount[candidate, default: 0] += 1
            }
            for item in group {
                let candidate = candidates[item.instance.id] ?? alias
                let unique = withAccount[candidate] == 1 && !reserved.contains(candidate)
                result[item.instance.id] = unique ? candidate : candidate + "-" + sanitize(item.instance.shortID)
            }
        }
        return result
    }

    /// Whether a `Host` line in the user's own config already claims this alias.
    static func configDefinesHost(_ alias: String, in config: String) -> Bool {
        for line in config.split(whereSeparator: \.isNewline) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let keyword = tokens.first, keyword.lowercased() == "host" else { continue }
            if tokens.dropFirst().contains(where: { String($0) == alias }) {
                return true
            }
        }
        return false
    }

    static func render(_ entries: [SSHHostEntry], identityFile: String = "~/.ssh/id_ed25519") -> String {
        var lines = [
            "# 由胡闹AutoDL 自动生成，会随实例变化被覆盖，请不要手动编辑。",
            ""
        ]
        for entry in entries {
            lines += [
                "Host " + ([entry.alias] + (entry.extraAlias.map { [$0] } ?? [])).joined(separator: " "),
                "    # instance \(entry.instanceID)",
                "    HostName \(entry.endpoint.host)",
                "    Port \(entry.endpoint.port)",
                "    User \(entry.endpoint.user)",
                "    IdentityFile \(identityFile)",
                "    IdentitiesOnly yes",
                "    StrictHostKeyChecking accept-new",
                "    UserKnownHostsFile ~/.ssh/\(knownHostsFileName)",
                "    ServerAliveInterval 30",
                "    ServerAliveCountMax 3",
                "    ControlMaster auto",
                "    ControlPath ~/.ssh/cm-%C",
                "    ControlPersist 10m",
                ""
            ]
        }
        // Host blocks in an included file keep applying to the lines after the Include,
        // so hand control back to "all hosts" for the rest of ~/.ssh/config.
        lines.append("Match all")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `host:port → instance ID` recorded in a previously rendered file.
    static func recordedInstances(in rendered: String) -> [String: String] {
        var result: [String: String] = [:]
        var instanceID: String?
        var host: String?
        var port = 22
        func flush() {
            if let instanceID, let host {
                result[SSHEndpoint(host: host, port: port, user: "").knownHostsKey] = instanceID
            }
        }
        for rawLine in rendered.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Host ") || line == "Match all" {
                flush()
                instanceID = nil
                host = nil
                port = 22
            } else if line.hasPrefix("# instance ") {
                instanceID = String(line.dropFirst("# instance ".count))
            } else if line.hasPrefix("HostName ") {
                host = String(line.dropFirst("HostName ".count))
            } else if line.hasPrefix("Port "), let value = Int(line.dropFirst("Port ".count)) {
                port = value
            }
        }
        flush()
        return result
    }

    /// Endpoints whose saved host key belongs to a different instance now (AutoDL reuses host:port).
    static func staleKnownHostsKeys(previous: String, entries: [SSHHostEntry]) -> Set<String> {
        let recorded = recordedInstances(in: previous)
        var stale: Set<String> = []
        for entry in entries {
            let key = entry.endpoint.knownHostsKey
            if let old = recorded[key], old != entry.instanceID {
                stale.insert(key)
            }
        }
        return stale
    }

    /// Adds the Include line at the very top of ~/.ssh/config, or returns nil when it is already there.
    static func addingInclude(to config: String) -> String? {
        let present = config.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == includeLine
        }
        guard !present else { return nil }
        return "# 胡闹AutoDL 自动维护的 AutoDL 实例别名\n\(includeLine)\n\n" + config
    }
}

/// The block 胡闹AutoDL keeps in ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md.
enum AgentContextBlock {
    static let startMarker = "<!-- hunao-autodl:start -->"
    static let endMarker = "<!-- hunao-autodl:end -->"

    struct Server: Equatable {
        /// nil when AutoDL has not given the instance an SSH address yet.
        let alias: String?
        let instance: AutoDLInstance
        let accountName: String
        let isTarget: Bool
        let keyStatus: SSHKeyStatus
    }

    static func render(servers: [Server], targetAlias: String?, showAccounts: Bool) -> String {
        let running = servers.filter { $0.instance.state == .running }
        let others = servers.filter { $0.instance.state != .running }

        var lines = [
            startMarker,
            "## 我的 AutoDL 实例（由胡闹AutoDL 自动维护）",
            ""
        ]
        if running.isEmpty {
            lines.append("当前没有正在运行的实例。需要时请让用户在胡闹AutoDL 里开机。")
        } else {
            lines.append("正在运行：")
            for server in running {
                lines.append("- " + describe(server, targetAlias: targetAlias, showAccounts: showAccounts))
            }
        }
        if !others.isEmpty {
            let names = others.map { "\($0.alias ?? $0.instance.name)（\($0.instance.state.label)）" }.joined(separator: "、")
            lines.append("")
            lines.append("未运行：\(names)。开机后才能连接。")
        }
        lines += [
            "",
            "- 连接：`ssh -o BatchMode=yes <别名> '<命令>'`，传文件用 `scp`/`rsync` 加同样的别名。已配置免密和连接复用，不要自己写 askpass、expect 或 sshpass。",
            "- 标为「免密待配置」的实例连不上时，请提醒用户在胡闹AutoDL 的「我的实例」里点「配置免密」。",
            "- 数据和模型放在 `/root/autodl-tmp`（数据盘）；下载前先 `source /etc/network_turbo`，直接在服务器上下载，不要经本机中转。",
            "- 这份列表在胡闹AutoDL 运行时自动更新，可能比实际状态晚一会儿；连不上时先用 `ssh -o BatchMode=yes <别名> true` 确认。",
            endMarker
        ]
        return lines.joined(separator: "\n")
    }

    private static func describe(_ server: Server, targetAlias: String?, showAccounts: Bool) -> String {
        let instance = server.instance
        guard let alias = server.alias else {
            return "`\(instance.name)` · \(instance.gpuName) ×\(instance.gpuCount) · \(instance.displayRegion) · 暂时没有 SSH 地址，稍后再试"
        }
        var parts = [
            "`\(alias)`",
            "\(instance.gpuName) ×\(instance.gpuCount)",
            instance.displayRegion
        ]
        if showAccounts {
            parts.append("账号「\(server.accountName)」")
        }
        parts.append(server.keyStatus == .ready ? "已免密" : "免密待配置")
        var line = parts.joined(separator: " · ")
        if server.isTarget, let targetAlias {
            line += "（监控目标，也可用 `\(targetAlias)`）"
        }
        return line
    }

    /// Replaces the marked block, appends it when missing, or removes it when `block` is nil.
    static func applying(_ block: String?, to content: String) -> String {
        if let start = content.range(of: startMarker),
           let end = content.range(of: endMarker, range: start.upperBound..<content.endIndex) {
            let before = String(content[..<start.lowerBound])
            let after = String(content[end.upperBound...])
            guard let block else {
                let trimmedBefore = before.replacingOccurrences(of: "\\n+$", with: "", options: .regularExpression)
                let trimmedAfter = after.replacingOccurrences(of: "^\\n+", with: "", options: .regularExpression)
                if trimmedBefore.isEmpty { return trimmedAfter }
                return trimmedAfter.isEmpty ? trimmedBefore + "\n" : trimmedBefore + "\n\n" + trimmedAfter
            }
            return before + block + after
        }
        guard let block else { return content }
        if content.isEmpty { return block + "\n" }
        let separator = content.hasSuffix("\n\n") ? "" : (content.hasSuffix("\n") ? "\n" : "\n\n")
        return content + separator + block + "\n"
    }
}

enum SSHKeyStatus: Equatable {
    case unknown
    case checking
    case ready
    case needsSetup
    case installing
    case unreachable
    case failed(String)

    var label: String {
        switch self {
        case .unknown, .checking: return "检测中"
        case .ready: return "免密 ✓"
        case .needsSetup: return "免密待配置"
        case .installing: return "正在配置免密"
        case .unreachable: return "暂时连不上"
        case .failed: return "免密配置失败"
        }
    }
}
