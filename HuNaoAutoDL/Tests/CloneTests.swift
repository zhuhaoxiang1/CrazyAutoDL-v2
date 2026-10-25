import Foundation

extension MonitorTests {
    @MainActor
    final class CloneFixture {
        let defaults: UserDefaults
        let suite = "hunao.tests.clone.\(UUID().uuidString)"
        let session: URLSession
        let market: MarketStore
        let monitor: AccountMonitor
        let source: AutoDLInstance

        init(autoStart: Bool = false, arm: Bool = true, status: String = "shutdown", startMode: String = "gpu") {
            defaults = UserDefaults(suiteName: suite)!
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            session = URLSession(configuration: config)
            market = MarketStore(defaults: defaults, session: session)
            let account = AutoDLAccount(id: "clone-account", name: "测试", token: "offline-clone-credential", isSubAccount: false)
            defaults.set("A", forKey: "hunao.selectedInstanceUUID.\(account.id)")
            defaults.set(autoStart, forKey: "hunao.autoStartEnabled.\(account.id)")
            monitor = AccountMonitor(account: account, app: nil, defaults: defaults, session: session, market: market)
            monitor.cloneConfirmationWindow = 0.08
            monitor.cloneConfirmationNanos = 10_000_000
            source = AutoDLInstance.parse(MonitorTests.cloneRaw("A", status: status, mode: startMode))!
            market.addRule(regionSign: "region-a", regionName: "测试区", gpuName: "RTX 4090")
            market.setCloneHandler { [weak monitor] rule, hits in monitor?.autoClone(rule: rule, hits: hits) ?? false }
            if arm { self.arm() }
            monitor.activate(instances: [source], saved: false)
        }

        func arm() { market.setAutoClone(id: "region-a|RTX 4090", enabled: true, sourceID: "A") }
        func scan(_ id: String = "new-machine", cap: Int64 = 500 * 1_073_741_824) {
            market.ingest(regionSign: "region-a", machines: [
                MarketMachine(id: id, alias: id, gpuName: "RTX 4090", regionName: "测试区", regionSign: "region-a",
                              gpuNumber: 8, gpuIdle: 2, hourlyPrice: 1, maxDataDiskExpand: cap)
            ])
        }
        func close() {
            monitor.stop(forgetSettings: false)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    static func cloneRaw(_ id: String, status: String = "shutdown", mode: String = "gpu", expansionGB: Int64 = 200) -> [String: Any] {
        var value = raw(id, status: status, startMode: mode)
        value["expand_data_disk_size"] = expansionGB * 1_073_741_824
        return value
    }

    static func cloneReply(path: String, source: [String: Any]? = nil) -> StubProtocol.Reply {
        switch true {
        case path.hasSuffix("/instance/snapshot"):
            return ok(["image": ["image_type": "public", "image_name": "offline-base"]])
        case path.hasSuffix("/instance"): return ok(["list": [source ?? cloneRaw("A")]])
        case path.hasSuffix("/wallet"): return ok(["assets": 100_000])
        case path.hasSuffix("/user/machine/list"): return machines([("machine-A", 0)])
        default: return ok([:])
        }
    }

    @MainActor
    static func cloneRegressions() async {
        // A success with an unreadable UUID, a timeout, and HTTP 500 must all keep the order guard.
        for response in [ok([:]), StubProtocol.Reply.fail(URLError(.timedOut)), .respond(500, [:]), .respond(200, ["message": "unrecognized response"]), .respond(200, ["code": "TEST_INTERNAL_ERROR", "msg": "模拟内部错误，不能确认是否创建"])] {
            StubProtocol.reset()
            StubProtocol.setHandler { path, _ in
                if path.hasSuffix("/order/instance/clone/payg") { return response }
                return cloneReply(path: path)
            }
            let f = CloneFixture(autoStart: true)
            f.scan()
            await waitUntil("unknown order settled") { !f.monitor.cloneInFlight }
            check(StubProtocol.count("/order/instance/clone/payg") == 1, "Exactly one paid POST on an ambiguous response")
            check(f.monitor.pendingCloneOrders["A"] != nil, "An ambiguous order remains protected")
            check(!f.monitor.autoStartEnabled, "Submitting a clone disables the source's auto-start")
            check(StubProtocol.count("/instance/power_on") == 0, "Auto-start cannot race an armed clone")
            f.monitor.setAutoStart(true)
            f.monitor.powerOn(instance: f.source)
            await settle()
            check(!f.monitor.autoStartEnabled && StubProtocol.count("/instance/power_on") == 0, "An unresolved clone also blocks a later source start")
            f.arm(); f.scan("another-machine")
            await settle()
            check(StubProtocol.count("/order/instance/clone/payg") == 1, "Re-arming cannot bypass an unknown order")
            let reopened = AccountMonitor(account: f.monitor.account, app: nil, defaults: f.defaults, session: f.session, market: f.market)
            check(reopened.pendingCloneOrders["A"] != nil, "The order guard survives a new monitor/relaunch")
            reopened.stop(forgetSettings: false)
            let addedAccount = AutoDLAccount(id: "re-added-account", name: "重新添加", token: "offline-re-added", isSubAccount: false)
            let readded = AccountMonitor(account: addedAccount, app: nil, defaults: f.defaults, session: f.session, market: f.market)
            readded.activate(instances: [f.source], saved: false)
            check(readded.pendingCloneOrders["A"] != nil, "A changed local account ID cannot bypass the source UUID order guard")
            readded.stop(forgetSettings: true)
            check(!f.market.alertRules[0].autoClone, "Removing an account revokes its outstanding clone rules")
            let order = f.monitor.pendingCloneOrders["A"]!
            f.monitor.acknowledgeCloneOrder(sourceID: "A", orderID: "outdated-order")
            check(f.monitor.pendingCloneOrders["A"] != nil, "An obsolete review cannot clear a newer order")
            f.monitor.acknowledgeCloneOrder(sourceID: "A", orderID: order.id)
            check(f.monitor.pendingCloneOrders.isEmpty && !f.market.alertRules[0].autoClone, "An explicit matching review releases protection without automatically ordering again")
            f.close()
        }

        // Cancel, pause/resume, remove the account, or replace the source config while snapshot is pending.
        for action in ["cancel", "cancel-button", "pause", "stop", "config"] {
            StubProtocol.reset()
            var currentSource = cloneRaw("A")
            StubProtocol.setHandler { path, _ in
                if path.hasSuffix("/instance/snapshot") { return .hold("snapshot") }
                return cloneReply(path: path, source: currentSource)
            }
            let f = CloneFixture()
            f.scan()
            await waitUntil("snapshot waiting") { StubProtocol.heldCount("snapshot") == 1 }
            switch action {
            case "cancel": f.market.setAutoClone(id: "region-a|RTX 4090", enabled: false, sourceID: nil)
            case "cancel-button": f.monitor.cancelPreparingClone(sourceID: "A")
            case "pause":
                f.monitor.monitoringPausedFallback = true
                f.monitor.monitoringPauseChanged(true)
                f.monitor.monitoringPausedFallback = false
                f.monitor.monitoringPauseChanged(false)
            case "stop": f.monitor.stop(forgetSettings: false)
            default:
                currentSource = cloneRaw("A", expansionGB: 400)
                f.monitor.refreshNow()
                await waitUntil("new source capacity read") { f.monitor.instances.first?.expandDataDiskBytes == 400 * 1_073_741_824 }
            }
            StubProtocol.release("snapshot", with: ok(["image": ["image_type": "public", "image_name": "offline-base"]]))
            await waitUntil("cancelled preparation settled") { !f.monitor.cloneInFlight }
            check(StubProtocol.count("/order/instance/clone/payg") == 0, "No order after \(action) during snapshot await")
            f.close()
        }

        // Refusing a too-small machine must not consume the ability to use the next suitable machine.
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/order/instance/clone/payg") { return .fail(URLError(.timedOut)) }
            return cloneReply(path: path)
        }
        let disk = CloneFixture()
        disk.scan("small", cap: 100 * 1_073_741_824)
        check(!disk.monitor.cloneInFlight && disk.market.alertRules[0].autoClone, "Insufficient disk keeps the rule armed")
        disk.scan("large")
        await waitUntil("eligible machine ordered") { !disk.monitor.cloneInFlight }
        check(StubProtocol.count("/order/instance/clone/payg") == 1, "Capacity becoming sufficient triggers without an empty scan")
        disk.close()

        // Explicit structured rejection is retried within a total budget of three orders.
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/order/instance/clone/payg") {
                return .respond(200, ["code": "MachineGpuNumUpdateFailed", "msg": "该主机空闲GPU数量不足，请更换主机。"])
            }
            return cloneReply(path: path)
        }
        let rejected = CloneFixture()
        for attempt in 1...3 {
            rejected.scan("machine-\(attempt)")
            await waitUntil("rejected attempt settled") { !rejected.monitor.cloneInFlight }
            check(StubProtocol.count("/order/instance/clone/payg") == attempt, "Exactly \(attempt) total attempts")
            check(rejected.monitor.pendingCloneOrders.isEmpty, "An explicit rejection does not leave an unknown order")
        }
        rejected.scan("fourth-machine")
        check(StubProtocol.count("/order/instance/clone/payg") == 3 && !rejected.market.alertRules[0].autoClone, "No fourth order")
        rejected.close()

        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/order/instance/clone/payg") { return .respond(200, ["code": "TORecharge", "msg": "余额不足"]) }
            return cloneReply(path: path)
        }
        let permanent = CloneFixture()
        permanent.scan()
        await waitUntil("permanent rejection settled") { !permanent.monitor.cloneInFlight }
        check(!permanent.market.alertRules[0].autoClone && permanent.monitor.pendingCloneOrders.isEmpty, "A permanent rejection never re-arms the rules")
        permanent.close()

        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/order/instance/clone/payg") { return .hold("old-order") }
            return cloneReply(path: path)
        }
        let stale = CloneFixture()
        stale.scan()
        await waitUntil("old paid request pending") { StubProtocol.heldCount("old-order") == 1 }
        stale.market.setAutoClone(id: "region-a|RTX 4090", enabled: true, sourceID: "B")
        stale.market.setAutoClone(id: "region-a|RTX 4090", enabled: false, sourceID: nil)
        StubProtocol.release("old-order", with: .respond(200, ["code": "MachineGpuNumUpdateFailed", "msg": "该主机空闲GPU数量不足，请更换主机。"]))
        await waitUntil("old rejection settled") { !stale.monitor.cloneInFlight }
        check(!stale.market.alertRules[0].autoClone && stale.market.alertRules[0].cloneSourceID == nil, "An old asynchronous rejection cannot undo a later cancellation/source choice")
        stale.close()

        // A known order is confirmed from actual GPU mode and disk expansion; a smaller disk stays pending.
        for (expansion, mode): (Int64, String) in [(100, "gpu"), (200, ""), (200, "non_gpu"), (200, "gpu")] {
            StubProtocol.reset()
            var ordered = false
            StubProtocol.setHandler { path, _ in
                if path.hasSuffix("/order/instance/clone/payg") { ordered = true; return ok("new-instance") }
                if path.hasSuffix("/instance") && ordered {
                    return ok(["list": [cloneRaw("A"), cloneRaw("new-instance", status: "running", mode: mode, expansionGB: expansion)]])
                }
                return cloneReply(path: path)
            }
            let f = CloneFixture()
            f.scan()
            await waitUntil("creation verification settled") { !f.monitor.cloneInFlight }
            check((f.monitor.pendingCloneOrders["A"] == nil) == (expansion == 200 && mode == "gpu"), "Only explicit GPU mode with aligned capacity is confirmed")
            if expansion == 100 || mode != "gpu" {
                check(f.monitor.activity.contains { $0.title == "克隆订单待确认" }, "A verification deadline reports an unresolved order")
            }
            f.close()
        }

        // A power-on already in flight owns the same source lock; a running GPU source is also excluded.
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/instance/power_on") { return .hold("power") }
            if path.hasSuffix("/user/machine/list") { return machines([("machine-A", 2)]) }
            return cloneReply(path: path)
        }
        let power = CloneFixture(autoStart: true, arm: false)
        await waitUntil("source power-on held") { StubProtocol.heldCount("power") == 1 }
        power.arm(); power.scan()
        check(!power.monitor.cloneInFlight, "A clone cannot overlap the source power-on lock")
        power.close()
        StubProtocol.release("power", with: ok([:]))
        await settle()

        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in cloneReply(path: path, source: cloneRaw("A", status: "running")) }
        let running = CloneFixture(status: "running")
        running.scan()
        check(!running.monitor.cloneInFlight, "A source already using GPUs does not auto-clone")
        running.close()

        await cloneScanContext()
    }

    @MainActor
    static func cloneScanContext() async {
        StubProtocol.reset()
        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/machine/region/gpu_type") { return .hold("aggregate") }
            if path.hasSuffix("/user/machine/list") {
                return ok(["list": [["machine_id": "m", "gpu_name": "RTX 4090", "gpu_idle_num": 2, "region_sign": "region-a"]]])
            }
            return ok([:])
        }
        let suite = "hunao.tests.clone-scan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let market = MarketStore(defaults: defaults, session: URLSession(configuration: config))
        market.addRule(regionSign: "region-a", regionName: "测试区", gpuName: "RTX 4090")
        market.setAutoClone(id: "region-a|RTX 4090", enabled: true, sourceID: "source-A")
        let visible = AutoDLAccount(id: "B", name: "B", token: "offline-visible-B", isSubAccount: false)
        let owner = AutoDLAccount(id: "A", name: "A", token: "offline-source-A", isSubAccount: false)
        var calls = 0
        market.setCloneHandler { _, _ in calls += 1; return true }
        let scan = Task { await market.watchRegion(account: visible, regionSign: "region-a", chargeType: "monthly", accountForSource: { _ in owner }) }
        await waitUntil("clone processed before aggregate count") { calls == 1 }
        let request = StubProtocol.log.first { $0.path.hasSuffix("/user/machine/list") }!
        check(request.authorization == owner.token, "Clone scan uses the source account even when another account is visible")
        check(request.body["charge_type"] as? String == "payg", "Clone scan stays payg when the selected instance is monthly")
        StubProtocol.release("aggregate", with: ok([]))
        await scan.value

        StubProtocol.setHandler { path, _ in
            if path.hasSuffix("/user/machine/list") { return .hold("old-scan") }
            return ok([])
        }
        market.setAutoClone(id: "region-a|RTX 4090", enabled: true, sourceID: "source-A")
        let oldScan = Task { await market.watchRegion(account: visible, regionSign: "region-a", chargeType: "monthly", accountForSource: { _ in owner }) }
        await waitUntil("scan waiting before pause") { StubProtocol.heldCount("old-scan") == 1 }
        market.watchPaused = true
        market.watchPaused = false
        StubProtocol.release("old-scan", with: ok(["list": [["machine_id": "m", "gpu_name": "RTX 4090", "gpu_idle_num": 2, "region_sign": "region-a"]]]))
        await oldScan.value
        check(calls == 1, "A pre-pause scan cannot trigger after pause/resume")
    }
}
