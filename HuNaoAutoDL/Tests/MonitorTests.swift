import Foundation

/// Scripted AutoDL server: every request is answered (or held) by `handler`, nothing leaves the process.
final class StubProtocol: URLProtocol {
    enum Reply {
        case respond(Int, [String: Any])
        case hold(String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: ((String, [String: Any]) -> Reply)?
    nonisolated(unsafe) private static var _held: [String: [StubProtocol]] = [:]
    nonisolated(unsafe) private static var _log: [(path: String, body: [String: Any])] = []

    static func setHandler(_ handler: @escaping (String, [String: Any]) -> Reply) {
        lock.lock(); defer { lock.unlock() }
        _handler = handler
    }

    static var log: [(path: String, body: [String: Any])] {
        lock.lock(); defer { lock.unlock() }
        return _log
    }

    static func count(_ suffix: String) -> Int {
        log.filter { $0.path.hasSuffix(suffix) }.count
    }

    static func heldCount(_ key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return _held[key]?.count ?? 0
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _handler = nil
        _held = [:]
        _log = []
    }

    static func release(_ key: String, with reply: Reply) {
        lock.lock()
        let pending = _held[key] ?? []
        _held[key] = nil
        lock.unlock()
        for item in pending { item.finish(reply) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func bodyDictionary(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(buffer, count: read)
            }
            stream.close()
            data = collected
        }
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    override func startLoading() {
        let path = request.url!.path
        let body = Self.bodyDictionary(of: request)
        Self.lock.lock()
        Self._log.append((path, body))
        let handler = Self._handler
        Self.lock.unlock()
        guard let reply = handler?(path, body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch reply {
        case .hold(let key):
            Self.lock.lock()
            Self._held[key, default: []].append(self)
            Self.lock.unlock()
        case .respond:
            finish(reply)
        }
    }

    func finish(_ reply: Reply) {
        guard case .respond(let status, let json) = reply else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@main
struct MonitorTests {
    nonisolated(unsafe) static var checks = 0

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        checks += 1
    }

    static func ok(_ data: Any) -> StubProtocol.Reply { .respond(200, ["code": "Success", "data": data]) }

    static func raw(
        _ id: String,
        status: String = "shutdown",
        cards: Int = 1,
        startMode: String? = nil
    ) -> [String: Any] {
        var item: [String: Any] = [
            "uuid": id, "name": "inst-\(id)", "status": status, "machine_id": "machine-\(id)",
            "gpu_type_name": "RTX 4090", "req_gpu_amount": cards, "region_sign": "region-a", "charge_type": "payg"
        ]
        if let startMode { item["start_mode"] = startMode }
        return item
    }

    static func machines(_ entries: [(String, Int)], total: Int? = nil) -> StubProtocol.Reply {
        let list = entries.map { ["machine_id": $0.0, "gpu_idle_num": $0.1, "gpu_all_num": 8] as [String: Any] }
        return ok(["list": list, "result_total": total ?? list.count])
    }

    @MainActor
    static func waitUntil(_ message: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { preconditionFailure("Timed out waiting for: \(message)") }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    static func settle() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @MainActor
    static func makeMonitor(selected: String?, autoStart: Bool = false) -> (AccountMonitor, UserDefaults, () -> Void) {
        let suite = "hunao.tests.monitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let account = AutoDLAccount(id: "acct-test", name: "测试", token: "offline-test-credential", isSubAccount: false)
        if let selected { defaults.set(selected, forKey: "hunao.selectedInstanceUUID.\(account.id)") }
        defaults.set(autoStart, forKey: "hunao.autoStartEnabled.\(account.id)")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let monitor = AccountMonitor(account: account, app: nil, defaults: defaults, session: session)
        return (monitor, defaults, {
            // Stop first so no late timer fires a request; the session is left to be freed with the process.
            monitor.stop(forgetSettings: false)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @MainActor
    static func main() async throws {
        try await targetLoss()
        try await staleStock()
        try await powerOnExclusion()
        try await staleAuthFailure()
        try await noCardVerification()
        try await stockPagination()
        try await pausedMonitoring()
        refundNetting()
        print("MonitorTests: \(checks) checks passed; no external network requests")
    }

    // 1. A target that vanishes must not hand automation to another instance.
    @MainActor
    static func targetLoss() async throws {
        StubProtocol.reset()
        var list = [raw("A"), raw("B")]
        StubProtocol.setHandler { path, body in
            switch true {
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 2), ("machine-B", 2)])
            default: return ok([:])
            }
        }
        let (monitor, defaults, cleanup) = makeMonitor(selected: "A", autoStart: true)
        defer { cleanup() }
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("initial refresh") { monitor.stock != nil || StubProtocol.count("/user/machine/list") > 0 }
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 2), ("machine-B", 2)])
            default: return ok([:])
            }
        }
        list = [raw("B")]
        monitor.refreshNow()
        await waitUntil("target flagged lost") { monitor.lostTarget != nil }
        await settle()
        check(monitor.selectedInstance == nil, "No instance is selected once the target is gone")
        check(monitor.lostTarget?.id == "A", "The vanished target is remembered")
        check(StubProtocol.count("/instance/power_on") == 0, "A vanished target never powers on another instance")
        check(StubProtocol.count("/user/machine/list") == 0, "No stock is queried for an instance nobody picked")
        check(defaults.string(forKey: "hunao.selectedInstanceUUID.acct-test") == "A", "The stored choice survives")
        check(monitor.availabilityHeadline == "监控目标已消失", "The headline says the target vanished")

        list = [raw("A"), raw("B")]
        monitor.refreshNow()
        await waitUntil("target recovered") { monitor.lostTarget == nil }
        check(monitor.selectedInstance?.id == "A", "A target that reappears is picked up again")
    }

    // 2. A stock reading fetched for the old target must not land on the new one.
    @MainActor
    static func staleStock() async throws {
        StubProtocol.reset()
        let list = [raw("A", cards: 1), raw("B", cards: 4)]
        StubProtocol.setHandler { path, body in
            switch true {
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"):
                return (body["gpu_idle_num"] as? Int) == 1 ? .hold("stock-A") : machines([("machine-B", 0)])
            default: return ok([:])
            }
        }
        let (monitor, _, cleanup) = makeMonitor(selected: "A")
        defer { cleanup() }
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("A's stock request is in flight") { StubProtocol.heldCount("stock-A") == 1 }
        monitor.selectInstance("B")
        StubProtocol.release("stock-A", with: machines([("machine-A", 1)]))
        await waitUntil("B's stock arrives") { monitor.stock?.instanceID == "B" }
        check(monitor.stock?.idleGPUs == 0, "The reading shown belongs to the new target")
        check(StubProtocol.count("/instance/power_on") == 0, "No power-on was issued from the old target's stock")

        monitor.setAutoStart(true)
        await settle()
        check(StubProtocol.count("/instance/power_on") == 0, "Enabling auto-start does not act on a foreign reading")
    }

    // 3. Manual and automatic power-ons share one lock per instance.
    @MainActor
    static func powerOnExclusion() async throws {
        StubProtocol.reset()
        let list = [raw("A")]
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/instance/power_on"): return .hold("power-on")
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 3)])
            default: return ok([:])
            }
        }
        let (monitor, _, cleanup) = makeMonitor(selected: "A", autoStart: true)
        defer { cleanup() }
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("auto power-on in flight") { StubProtocol.heldCount("power-on") == 1 }
        check(monitor.isBusy("A"), "The instance is marked busy")
        monitor.powerOn(instance: monitor.instances[0])
        monitor.powerOn(instance: monitor.instances[0], noCard: true)
        await settle()
        check(StubProtocol.count("/instance/power_on") == 1, "A manual start cannot overlap an automatic one")
        StubProtocol.release("power-on", with: ok([:]))
        await waitUntil("lock released") { !monitor.isBusy("A") }

        // The other way round: a manual no-card start holds off the automatic GPU start.
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/instance/power_on"): return .hold("power-on")
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 3)])
            default: return ok([:])
            }
        }
        let (second, _, cleanup2) = makeMonitor(selected: "A", autoStart: false)
        defer { cleanup2() }
        second.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("first refresh") { second.stock != nil }
        second.powerOn(instance: second.instances[0], noCard: true)
        await waitUntil("manual no-card request sent") { StubProtocol.heldCount("power-on") == 1 }
        second.setAutoStart(true)
        second.refreshNow()
        await settle()
        check(StubProtocol.count("/instance/power_on") == 1, "Auto-start stays out while a no-card start is pending")
        check(StubProtocol.log.last(where: { $0.path.hasSuffix("/power_on") })?.body["payload"] as? String == "non_gpu",
              "The one request was the no-card start")
        StubProtocol.release("power-on", with: ok([:]))
        await waitUntil("lock released again") { !second.isBusy("A") }
    }

    // 4. A late auth failure from an older request must not sign out a renewed session.
    @MainActor
    static func staleAuthFailure() async throws {
        StubProtocol.reset()
        let list = [raw("A")]
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/bill/list"): return .hold("bills")
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 0)])
            default: return ok([:])
            }
        }
        let (monitor, _, cleanup) = makeMonitor(selected: "A")
        defer { cleanup() }
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        monitor.refreshBilling(force: true)
        await waitUntil("billing request in flight") { StubProtocol.heldCount("bills") == 1 }

        // The user signs in again with the very same token.
        monitor.updateCredentials(
            token: "offline-test-credential", isSubAccount: false,
            instances: list.compactMap(AutoDLInstance.parse), saved: false
        )
        StubProtocol.release("bills", with: .respond(401, [:]))
        await settle()
        check(monitor.authFailure == nil, "An old request's 401 does not expire the renewed session")
        check(!monitor.isBillingLoading, "The billing spinner is released")
        check(!monitor.instances.isEmpty, "The renewed session keeps its data")
    }

    // 5. A no-card boot whose mode is never read back must not end silently.
    @MainActor
    static func noCardVerification() async throws {
        StubProtocol.reset()
        var list = [raw("A", status: "shutdown")]
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/instance/power_on"): return ok([:])
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 0)])
            default: return ok([:])
            }
        }
        let (monitor, _, cleanup) = makeMonitor(selected: "A")
        defer { cleanup() }
        monitor.noCardCheckSchedule = [150_000_000, 150_000_000]
        monitor.noCardCheckWindow = 1
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("first refresh") { monitor.stock != nil }
        list = [raw("A", status: "running", startMode: nil)]
        monitor.powerOn(instance: monitor.instances[0], noCard: true)
        await waitUntil("unconfirmed notice", timeout: 8) {
            monitor.activity.contains { $0.title == "无法确认无卡模式" }
        }
        check(true, "The check reports that it could not confirm instead of ending silently")

        // The check stays armed: a later poll that reads `gpu` is still reported.
        list = [raw("A", status: "running", startMode: "gpu")]
        monitor.refreshNow()
        await waitUntil("late mismatch notice") { monitor.activity.contains { $0.title == "无卡开机未生效" } }
        check(true, "A later gpu reading still raises the mismatch warning")
    }

    // 6. The target host may sit on a later page of the stock query.
    @MainActor
    static func stockPagination() async throws {
        StubProtocol.reset()
        StubProtocol.setHandler { path, body in
            guard path.hasSuffix("/user/machine/list") else { return ok([:]) }
            let page = body["page_index"] as? Int ?? 1
            if page == 1 {
                let others = (0..<100).map { ["machine_id": "other-\($0)", "gpu_idle_num": 0] as [String: Any] }
                return ok(["list": others, "result_total": 101])
            }
            return ok(["list": [["machine_id": "machine-A", "gpu_idle_num": 2, "gpu_all_num": 8]], "result_total": 101])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let api = AutoDLAPI(token: "offline-test-credential", session: session)
        let instance = AutoDLInstance.parse(raw("A"))!
        let stock = try await api.fetchGPUStock(for: instance)
        check(stock.machineFound && stock.idleGPUs == 2, "A host on page two is found")
        check(StubProtocol.count("/user/machine/list") == 2, "Exactly the needed pages were requested")
        check(stock.instanceID == "A" && stock.matches(instance), "The reading is stamped with its instance")

        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            let others = (0..<100).map { _ in ["machine_id": "x-\(UUID().uuidString)", "gpu_idle_num": 0] as [String: Any] }
            return path.hasSuffix("/user/machine/list") ? ok(["list": others, "result_total": 100_000]) : ok([:])
        }
        let capped = try await api.fetchGPUStock(for: instance)
        check(!capped.machineFound && capped.incomplete, "Hitting the page cap is reported as incomplete")
        check(StubProtocol.count("/user/machine/list") == AutoDLAPI.stockMaxPages, "The search stops at the page cap")

        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            path.hasSuffix("/user/machine/list")
                ? ok(["list": [["machine_id": "x", "gpu_idle_num": 1]], "result_total": 1]) : ok([:])
        }
        let absent = try await api.fetchGPUStock(for: instance)
        check(!absent.machineFound && !absent.incomplete, "A genuinely absent host is not called incomplete")
    }

    // 8. While monitoring is paused nothing alerts or auto-starts; resuming acts on a card that is free right now.
    @MainActor
    static func pausedMonitoring() async throws {
        StubProtocol.reset()
        let list = [raw("A")]
        StubProtocol.setHandler { path, _ in
            switch true {
            case path.hasSuffix("/instance/power_on"): return ok([:])
            case path.hasSuffix("/instance"): return ok(["list": list])
            case path.hasSuffix("/wallet"): return ok(["assets": 100])
            case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 3)])
            default: return ok([:])
            }
        }
        let (monitor, _, cleanup) = makeMonitor(selected: "A", autoStart: true)
        defer { cleanup() }
        monitor.monitoringPausedFallback = true
        monitor.activate(instances: list.compactMap(AutoDLInstance.parse), saved: false)
        await waitUntil("paused refresh still shows data") { monitor.stock?.idleGPUs == 3 }
        await settle()
        check(StubProtocol.count("/instance/power_on") == 0, "No auto-start while paused")
        check(monitor.availabilityHeadline == "监控已暂停", "The headline says monitoring is paused")
        check(!monitor.activity.contains { $0.title == "发现空闲显卡" }, "No availability event while paused")

        monitor.monitoringPausedFallback = false
        monitor.monitoringPauseChanged(false)
        await waitUntil("auto-start after resume") { StubProtocol.count("/instance/power_on") == 1 }
        check(true, "Resuming acts on a card that is free right now")
    }

    // 7. A refund larger than the day's charges offsets spend on other days.
    @MainActor
    static func refundNetting() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        func record(_ id: String, _ type: String, _ amount: Double, _ at: Date) -> BillRecord {
            BillRecord(
                id: id, createdAt: at, type: type, amount: amount, payByBalance: amount, payByVoucher: 0,
                balanceAfter: nil, gpuType: "RTX 4090", regionName: nil, machineID: nil, chargeDuration: nil,
                chargeFrom: nil, originPrice: nil, discountAmount: 0
            )
        }
        let snapshot = BillingSnapshot(
            records: [record("1", "charge", 10, yesterday), record("2", "refund", 10, now)],
            fetchedAt: now
        )
        check(snapshot.totalSpend(days: 7) == 0, "Net spend over the week is zero, not the charge alone")
        check(snapshot.last7Spend == 0, "Weekly spend nets the refund")
        let series = snapshot.dailySeries(days: 2)
        check(series.last?.net == -10 && series.last?.amount == 0, "The chart bar stays non-negative while the net is signed")
    }
}
