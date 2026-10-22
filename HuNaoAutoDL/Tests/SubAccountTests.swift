import Foundation

final class MockAutoDLProtocol: URLProtocol {
    static var respond: (URLRequest) throws -> (Int, [String: Any]) = { _ in
        throw URLError(.badServerResponse)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (status, body) = try Self.respond(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@main
struct SubAccountTests {
    static func main() async throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAutoDLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixtureToken = "offline-test-credential"
        let emptyInstances: [String: Any] = ["code": "Success", "data": ["list": []]]
        let denied: [String: Any] = ["code": "PermissionDenied", "msg": "无当前资源访问权限"]
        var paths: [String] = []

        MockAutoDLProtocol.respond = { request in
            paths.append(request.url!.path)
            return (200, emptyInstances)
        }
        let main = try await AutoDLAPI.connect(token: fixtureToken, session: session)
        check(!main.api.isSubAccount, "Main accounts keep their original routes")
        check(paths == ["/api/v1/instance"], "Main account login sends one read-only request")

        paths = []
        MockAutoDLProtocol.respond = { request in
            paths.append(request.url!.path)
            return (200, request.url!.path == "/api/v1/instance" ? denied : emptyInstances)
        }
        let sub = try await AutoDLAPI.connect(token: fixtureToken, session: session)
        check(sub.api.isSubAccount, "Recognize sub accounts after explicit resource access denial")
        check(paths == ["/api/v1/instance", "/api/v1/sub_user/instance"], "Retry only the read-only instance listing")

        paths = []
        let restored = try await AutoDLAPI.connect(token: fixtureToken, preferSubAccount: true, session: session)
        check(restored.api.isSubAccount, "Restored sessions keep the account type")
        check(paths == ["/api/v1/sub_user/instance"], "Do not probe the main account on each restart")

        for response in [
            (200, ["code": "AuthorizeFailed", "msg": "登录超时"] as [String: Any]),
            (403, [:] as [String: Any]),
            (500, [:] as [String: Any]),
            (200, ["code": "OtherError", "msg": "服务暂不可用"] as [String: Any])
        ] {
            paths = []
            MockAutoDLProtocol.respond = { request in
                paths.append(request.url!.path)
                return response
            }
            do {
                _ = try await AutoDLAPI.connect(token: fixtureToken, session: session)
                preconditionFailure("Expected connection failure")
            } catch {
                check(paths == ["/api/v1/instance"], "Never change account type for unrelated failures")
            }
        }

        paths = []
        MockAutoDLProtocol.respond = { request in
            paths.append(request.url!.path)
            return (200, denied)
        }
        do {
            _ = try await AutoDLAPI.connect(token: fixtureToken, session: session)
            preconditionFailure("Must preserve denied sub-account permissions")
        } catch {
            check(paths.count == 2, "Denied sub accounts stop after the single fallback")
        }

        for isSubAccount in [false, true] {
            paths = []
            MockAutoDLProtocol.respond = { request in
                paths.append(request.url!.path)
                let path = request.url!.path
                if path.hasSuffix("/wallet") {
                    return (200, ["code": "Success", "data": ["assets": 1000]])
                }
                if path.hasSuffix("/bill/list") {
                    return (200, ["code": "Success", "data": ["list": [], "result_total": 0]])
                }
                return (200, emptyInstances)
            }
            let api = AutoDLAPI(token: fixtureToken, isSubAccount: isSubAccount, session: session)
            _ = try await api.fetchInstances()
            _ = try await api.fetchBalance()
            _ = try await api.fetchBills(from: Date(), to: Date())
            let instance = AutoDLInstance.parse(["uuid": "fixture-instance", "machine_id": "fixture-machine"])!
            _ = try await api.fetchGPUStock(for: instance)
            // Power operations are intercepted by URLProtocol and never reach AutoDL.
            try await api.powerOn(instanceUUID: "fixture-instance")
            try await api.powerOff(instanceUUID: "fixture-instance")
            let prefix = isSubAccount ? "/api/v1/sub_user" : "/api/v1"
            check(paths == ["/instance", "/wallet", "/bill/list", "/user/machine/list", "/instance/power_on", "/instance/power_off"].map { prefix + $0 }, "All existing operations must use the verified account scope")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = AutoDLSession(token: fixtureToken, isSubAccount: true)
        check(TokenStore.saveSession(saved, directory: directory), "Save sub-account credentials atomically")
        check(TokenStore.loadSession(directory: directory) == saved, "Restore token and account type together")
        let file = directory.appendingPathComponent("session.token")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        check(permissions.intValue == 0o600, "Keep private credential file permissions")
        let mainSession = AutoDLSession(token: fixtureToken, isSubAccount: false)
        check(TokenStore.saveSession(mainSession, directory: directory), "Switch account types")
        check(TokenStore.loadSession(directory: directory) == mainSession, "Never reuse the previous account type")
        try Data((fixtureToken + "\n").utf8).write(to: file)
        check(TokenStore.loadSession(directory: directory) == mainSession, "Read existing plain-text token files")
        check(AutoDLSession.decode(Data()) == nil, "Reject empty credential files")
        check(AutoDLSession.decode(Data("{broken".utf8)) == nil, "Reject malformed session JSON")
        TokenStore.deleteToken(directory: directory)
        check(TokenStore.loadSession(directory: directory) == nil, "Sign out deletes both token and account type")
        print("SubAccountTests: \(checks) checks passed; no external network requests")
    }
}
