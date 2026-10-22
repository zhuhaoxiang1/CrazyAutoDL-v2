import Foundation

struct AutoDLAccount: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var token: String
    var isSubAccount: Bool

    init(id: String = UUID().uuidString, name: String, token: String, isSubAccount: Bool) {
        self.id = id
        self.name = name
        self.token = token
        self.isSubAccount = isSubAccount
    }

    var tokenHint: String {
        guard token.count > 12 else { return "••••••••" }
        return "\(token.prefix(5))••••••\(token.suffix(4))"
    }
}

enum AccountStore {
    private static let fileManager = FileManager.default
    private static let fileName = "accounts.json"

    private static var directoryURL: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HuNaoAutoDL-v2", isDirectory: true)
    }

    /// Loads saved accounts, moving a single-account `session.token` from older versions into the list.
    static func load(directory: URL? = nil) -> [AutoDLAccount] {
        guard let directory = directory ?? directoryURL else { return [] }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
           let accounts = try? JSONDecoder().decode([AutoDLAccount].self, from: data) {
            return accounts.filter { !$0.token.isEmpty }
        }
        guard let legacy = TokenStore.loadSession(directory: directory) else { return [] }
        let migrated = [AutoDLAccount(name: "账号 1", token: legacy.token, isSubAccount: legacy.isSubAccount)]
        if save(migrated, directory: directory) {
            TokenStore.deleteToken(directory: directory)
        }
        return migrated
    }

    /// Removes every credential file. True only when none is left on disk; used when an empty list cannot be written.
    @discardableResult
    static func purge(directory: URL? = nil) -> Bool {
        guard let directory = directory ?? directoryURL else { return false }
        let accountsURL = directory.appendingPathComponent(fileName)
        let legacyURL = directory.appendingPathComponent("session.token")
        try? fileManager.removeItem(at: accountsURL)
        try? fileManager.removeItem(at: legacyURL)
        return !fileManager.fileExists(atPath: accountsURL.path) && !fileManager.fileExists(atPath: legacyURL.path)
    }

    @discardableResult
    static func save(_ accounts: [AutoDLAccount], directory: URL? = nil) -> Bool {
        guard let directoryURL = directory ?? Self.directoryURL,
              let data = try? JSONEncoder().encode(accounts)
        else { return false }
        let fileURL = directoryURL.appendingPathComponent(fileName)

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = fileURL
            try? mutableURL.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }
}
