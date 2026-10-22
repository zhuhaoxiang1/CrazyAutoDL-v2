import Foundation

@main
struct AccountStoreTests {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let fileManager = FileManager.default

        let empty = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: empty) }
        check(AccountStore.load(directory: empty).isEmpty, "No saved credentials means no accounts")

        let legacy = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: legacy) }
        check(TokenStore.saveSession(AutoDLSession(token: "legacy-test-credential", isSubAccount: true), directory: legacy),
              "Write a single-account session from an older version")
        let migrated = AccountStore.load(directory: legacy)
        check(migrated.count == 1, "Upgrade turns the old session into one account")
        check(migrated.first?.token == "legacy-test-credential" && migrated.first?.isSubAccount == true,
              "Upgrade keeps the token and account type")
        check(migrated.first?.name == "账号 1", "Upgraded account gets a default name")
        check(TokenStore.loadSession(directory: legacy) == nil, "Old session file is removed after migration")
        check(AccountStore.load(directory: legacy) == migrated, "Migration only happens once and keeps the account ID")

        let multi = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: multi) }
        let accounts = [
            AutoDLAccount(name: "实验室", token: "first-test-credential", isSubAccount: false),
            AutoDLAccount(name: "个人", token: "second-test-credential", isSubAccount: true)
        ]
        check(AccountStore.save(accounts, directory: multi), "Save two accounts")
        check(AccountStore.load(directory: multi) == accounts, "Restore both accounts in order with names")
        let file = multi.appendingPathComponent("accounts.json")
        let permissions = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "Keep the accounts file private")
        check(AccountStore.save([], directory: multi) && AccountStore.load(directory: multi).isEmpty,
              "Removing the last account leaves nothing behind")
        check(accounts[0].tokenHint == "first••••••tial", "Token hint never shows the full token")

        // Sign-out must be able to clear credentials even when an empty list cannot be written.
        let purged = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: purged.path)
            try? fileManager.removeItem(at: purged)
        }
        check(AccountStore.save(accounts, directory: purged), "Save accounts before purging")
        check(TokenStore.saveSession(AutoDLSession(token: "legacy-test-credential", isSubAccount: false), directory: purged),
              "A legacy session file can sit next to the accounts file")
        check(AccountStore.purge(directory: purged), "Purge reports success once nothing is left")
        check(!fileManager.fileExists(atPath: purged.appendingPathComponent("accounts.json").path)
                && !fileManager.fileExists(atPath: purged.appendingPathComponent("session.token").path),
              "Purge removes both credential files")
        check(AccountStore.load(directory: purged).isEmpty, "Nothing is restored after a purge")

        // A directory the user cannot modify: purge must say the credential is still there.
        let locked = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: locked)
        }
        check(AccountStore.save(accounts, directory: locked), "Save into a fresh directory")
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        check(!AccountStore.purge(directory: locked), "Purge reports failure while the credential file remains")
        check(fileManager.fileExists(atPath: locked.appendingPathComponent("accounts.json").path),
              "The file really is still there")

        print("AccountStoreTests: \(checks) checks passed")
    }
}
