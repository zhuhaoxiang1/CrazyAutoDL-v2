import Foundation

struct AutoDLSession: Codable, Equatable {
    let token: String
    let isSubAccount: Bool

    static func decode(_ data: Data) -> AutoDLSession? {
        if let session = try? JSONDecoder().decode(Self.self, from: data), !session.token.isEmpty {
            return session
        }
        // 兼容旧版本直接保存的 Token；连接时会重新识别账号类型。
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.hasPrefix("{") else { return nil }
        return AutoDLSession(token: token, isSubAccount: false)
    }
}
