import Foundation

enum TokenStore {
    private static let fileManager = FileManager.default

    private static var directoryURL: URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("HuNaoAutoDL-v2", isDirectory: true)
    }

    static func loadSession(directory: URL? = nil) -> AutoDLSession? {
        guard let directory = directory ?? directoryURL,
              let data = try? Data(contentsOf: directory.appendingPathComponent("session.token"))
        else { return nil }
        return AutoDLSession.decode(data)
    }

    @discardableResult
    static func saveSession(_ session: AutoDLSession, directory: URL? = nil) -> Bool {
        guard !session.token.isEmpty,
              let directoryURL = directory ?? Self.directoryURL,
              let data = try? JSONEncoder().encode(session)
        else { return false }
        let tokenURL = directoryURL.appendingPathComponent("session.token")

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
            try data.write(to: tokenURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tokenURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = tokenURL
            try? mutableURL.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    static func deleteToken(directory: URL? = nil) {
        guard let directory = directory ?? directoryURL else { return }
        let tokenURL = directory.appendingPathComponent("session.token")
        try? fileManager.removeItem(at: tokenURL)
    }
}
