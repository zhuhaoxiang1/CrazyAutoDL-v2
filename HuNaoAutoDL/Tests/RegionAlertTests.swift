import Foundation

@main
struct RegionAlertTests {
    @MainActor
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        func machine(_ id: String, model: String = "RTX 4090", region: String = "beijing-b", idle: Int) -> MarketMachine {
            MarketMachine(
                id: id, alias: id, gpuName: model, regionName: "北京B区", regionSign: region,
                gpuNumber: 8, gpuIdle: idle, hourlyPrice: 2.28
            )
        }

        // A throwaway defaults domain: the test must never read or rewrite the real app's saved rules.
        let suiteName = "hunao.tests.region-alerts.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let store = MarketStore(defaults: testDefaults)

        var fired: [(title: String, id: String)] = []
        store.setAlertHandler { title, _, id in fired.append((title, id)) }

        store.addRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "RTX 4090", minCards: 2)
        store.addRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "H800", minCards: 1)
        store.addRule(regionSign: "shanghai-a", regionName: "上海A区", gpuName: "RTX 4090", minCards: 1)
        check(store.alertRules.count == 3, "Three rules were added")
        store.addRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "RTX 4090", minCards: 1)
        check(store.alertRules.count == 3, "The same region and model is never added twice")

        // Cards exist but no single machine has 2 -> a 2-card instance can't land there.
        store.ingest(regionSign: "beijing-b", machines: [machine("a", idle: 1), machine("b", idle: 1)])
        check(fired.isEmpty, "Scattered single cards do not satisfy a >=2 rule")

        // One machine gets 3 free cards -> fire once.
        store.ingest(regionSign: "beijing-b", machines: [machine("a", idle: 1), machine("c", idle: 3)])
        check(fired.count == 1, "Cards appearing fires exactly one alert")
        check(fired.first?.title == "北京B区 有空闲 RTX 4090", "Alert names the region and model")
        check(fired.first?.id == "hunao.region.beijing-b|RTX 4090", "Alert id is stable per rule")

        // Still available on the next scans -> stays quiet.
        store.ingest(regionSign: "beijing-b", machines: [machine("c", idle: 3)])
        store.ingest(regionSign: "beijing-b", machines: [machine("c", idle: 2)])
        check(fired.count == 1, "Cards staying available does not repeat the alert")

        // Cards disappear, then come back -> fire again.
        store.ingest(regionSign: "beijing-b", machines: [])
        check(fired.count == 1, "Cards disappearing is silent")
        store.ingest(regionSign: "beijing-b", machines: [machine("d", idle: 2)])
        check(fired.count == 2, "Cards returning after running out fires again")

        // Other model / other region must not trigger this region's rules.
        store.ingest(regionSign: "beijing-b", machines: [machine("e", model: "RTX 5090", idle: 8)])
        check(fired.count == 2, "A different model does not trigger the rule")
        store.ingest(regionSign: "shanghai-a", machines: [machine("s", region: "shanghai-a", idle: 1)])
        check(fired.count == 3, "The Shanghai rule fires on Shanghai data")
        check(fired.last?.id == "hunao.region.shanghai-a|RTX 4090", "Shanghai alert uses its own id")
        store.ingest(regionSign: "beijing-b", machines: [machine("e", model: "H800", idle: 1)])
        check(fired.count == 4, "The H800 rule fires when H800 appears")

        // Raising the threshold re-arms and respects the new value.
        store.ingest(regionSign: "beijing-b", machines: [machine("f", idle: 2)])
        let before = fired.count
        store.setMinCards(id: "beijing-b|RTX 4090", 4)
        store.ingest(regionSign: "beijing-b", machines: [machine("f", idle: 2)])
        check(fired.count == before, "2 free cards no longer satisfy a >=4 rule")
        store.ingest(regionSign: "beijing-b", machines: [machine("f", idle: 4)])
        check(fired.count == before + 1, "4 free cards satisfy the raised rule")

        // Removing a rule silences it.
        store.removeRule(id: "beijing-b|RTX 4090")
        store.ingest(regionSign: "beijing-b", machines: [])
        let afterRemove = fired.count
        store.ingest(regionSign: "beijing-b", machines: [machine("g", idle: 8)])
        check(fired.count == afterRemove, "A removed rule never fires")

        // Persistence round trip.
        let reloaded = MarketStore(defaults: testDefaults)
        check(reloaded.alertRules.contains { $0.id == "shanghai-a|RTX 4090" }, "Rules survive a restart")
        for rule in reloaded.alertRules { reloaded.removeRule(id: rule.id) }

        // No-card boot verification: parsing start_mode and judging what AutoDL actually did.
        func instance(_ status: String, _ mode: String?) -> AutoDLInstance {
            var raw: [String: Any] = ["uuid": "i-1", "name": "t", "status": status]
            if let mode { raw["start_mode"] = mode }
            return AutoDLInstance.parse(raw)!
        }
        check(instance("running", "non_gpu").isNoCardMode, "A running non_gpu instance is in no-card mode")
        check(!instance("running", "gpu").isNoCardMode, "A running gpu instance is not in no-card mode")
        check(!instance("shutdown", "non_gpu").isNoCardMode, "A stopped instance is never reported as running no-card")
        check(instance("running", "gpu").holdsGPU && !instance("running", "non_gpu").holdsGPU, "Only GPU-mode running instances hold a card")
        check(instance("running", "non_gpu").statusLabel == "无卡运行", "No-card instance shows its own label")
        check(instance("running", "gpu").statusLabel == "运行中", "GPU instance keeps the normal label")
        check(instance("running", "non_gpu").noCardBootCheck == .confirmed, "Running as non_gpu confirms the no-card boot")
        check(instance("running", "gpu").noCardBootCheck == .mismatch, "Running as gpu after a no-card request is a mismatch")
        check(instance("running", nil).noCardBootCheck == .pending, "A missing start_mode keeps waiting")
        check(instance("running", "something_new").noCardBootCheck == .pending, "An unknown start_mode is not judged")
        check(instance("starting", "gpu").noCardBootCheck == .pending, "A starting instance may still show the previous mode")
        check(instance("shutdown", "gpu").noCardBootCheck == .pending, "A stopped instance is not judged")
        check(instance("running", "NON_GPU").noCardBootCheck == .confirmed, "start_mode is compared case-insensitively")

        // AutoDL's public region list and per-region model counts (shapes copied from live responses).
        let region = CatalogRegion.parse(["region_sign": "west-E", "region_name": "西北B区", "data_center": "westDC3", "visible": true])
        check(region?.sign == "west-E" && region?.name == "西北B区" && region?.dataCenter == "westDC3", "A region entry parses")
        check(CatalogRegion.parse(["region_name": "x"]) == nil, "A region without a sign is dropped")
        check(CatalogRegion.parse(["region_sign": "hidden-1", "visible": false]) == nil, "Hidden regions are not offered")

        let types = GPUTypeStat.parseList([
            ["vGPU-32GB": ["idle_gpu_num": 9, "total_gpu_num": 608]],
            ["RTX 5090": ["idle_gpu_num": 1, "total_gpu_num": 264]],
            ["RTX PRO 5000": ["idle_gpu_num": 0, "total_gpu_num": 80]],
            ["CPU": ["idle_gpu_num": 0, "total_gpu_num": 320]],
            ["RTX 6000D": ["idle_gpu_num": 25, "total_gpu_num": 405]],
        ] as [[String: Any]])
        check(types.count == 5, "Every model entry parses, including ones with nothing idle")
        check(types.first?.name == "RTX 6000D" && types.first?.idle == 25 && types.first?.total == 405, "Most idle model comes first")
        check(types.contains { $0.name == "RTX PRO 5000" && $0.idle == 0 && $0.total == 80 }, "A model with no idle cards keeps its total")
        check(types.first { $0.name == "CPU" }?.isCPUOnly == true, "CPU-only machines are flagged")
        check(types.first { $0.name == "RTX 5090" }?.isCPUOnly == false, "A GPU model is not flagged as CPU-only")
        check(GPUTypeStat.parseList(nil).isEmpty && GPUTypeStat.parseList("oops").isEmpty, "A malformed payload parses to nothing")

        // Regions are data centers: west-B..E are one "西北B区", and rules/tabs/scans cover all its pools.
        let catalog = [
            CatalogRegion(sign: "west-B", name: "西北B区", dataCenter: "westDC3"),
            CatalogRegion(sign: "west-C", name: "西北B区", dataCenter: "westDC3"),
            CatalogRegion(sign: "west-D", name: "西北B区", dataCenter: "westDC3"),
            CatalogRegion(sign: "west-E", name: "西北B区", dataCenter: "westDC3"),
            CatalogRegion(sign: "cq-A1", name: "重庆A区", dataCenter: "chongqingDC1"),
        ]
        let grouped = MarketStore(defaults: testDefaults)
        for rule in grouped.alertRules { grouped.removeRule(id: rule.id) }
        grouped.setRegionCatalog(catalog)
        check(grouped.groupSigns(for: "west-D") == ["west-B", "west-C", "west-D", "west-E"], "All pools of a data center form one region")
        check(grouped.canonicalSign(for: "west-E") == "west-B", "A pool maps to its data center's first pool")
        check(grouped.canonicalSign(for: "cq-A1") == "cq-A1" && grouped.groupSigns(for: "cq-A1") == ["cq-A1"], "A single-pool region maps to itself")
        check(grouped.canonicalSign(for: "unknown-x") == "unknown-x", "An unknown pool is left alone")
        check(grouped.groupName(for: "west-C") == "西北B区", "The region name comes from the public list")

        grouped.addRule(regionSign: "west-E", regionName: "ignored", gpuName: "RTX 4090", minCards: 1)
        check(grouped.alertRules.count == 1 && grouped.alertRules[0].regionSign == "west-B", "A rule set from one pool is stored for the data center")
        check(grouped.alertRules[0].regionName == "西北B区", "The rule shows the region name, not a pool")
        grouped.addRule(regionSign: "west-C", regionName: "ignored", gpuName: "RTX 4090", minCards: 1)
        check(grouped.alertRules.count == 1, "The same model set from another pool of that region is not a second rule")
        check(grouped.rule(regionSign: "west-B", gpuName: "RTX 4090") != nil, "The rule is found by the data center key")

        var groupedFired: [String] = []
        grouped.setAlertHandler { title, _, _ in groupedFired.append(title) }
        grouped.ingest(regionSign: "west-B", machines: [machine("w1", region: "west-E", idle: 1)])
        check(groupedFired == ["西北B区 有空闲 RTX 4090"], "A machine in any pool of the region fires the region's rule")
        for rule in grouped.alertRules { grouped.removeRule(id: rule.id) }

        // Rules saved while the region list was unknown are keyed by one pool; they migrate once the list arrives.
        let early = MarketStore(defaults: testDefaults)
        for rule in early.alertRules { early.removeRule(id: rule.id) }
        early.addRule(regionSign: "west-E", regionName: "西北B区", gpuName: "H800", minCards: 2)
        early.addRule(regionSign: "west-C", regionName: "西北B区", gpuName: "H800", minCards: 2)
        check(early.alertRules.count == 2, "Before the region list loads, each pool keeps its own rule")
        let reopened = MarketStore(defaults: testDefaults)
        reopened.setRegionCatalog(catalog)
        check(reopened.alertRules.count == 1 && reopened.alertRules[0].regionSign == "west-B", "Old pool rules merge into one data center rule")
        check(reopened.alertRules[0].gpuName == "H800" && reopened.alertRules[0].minCards == 2, "The merged rule keeps its model and threshold")
        for rule in reopened.alertRules { reopened.removeRule(id: rule.id) }

        // The instance list reports the home machine's cards itself.
        let withHome = AutoDLInstance.parse(["uuid": "i-2", "name": "t", "status": "shutdown", "gpu_idle_num": 5, "gpu_all_num": 8])!
        check(withHome.homeIdle == 5 && withHome.homeTotal == 8, "Home machine idle/total come from the instance list")
        let noHome = AutoDLInstance.parse(["uuid": "i-3", "name": "t", "status": "shutdown"])!
        check(noHome.homeIdle == nil && noHome.homeTotal == nil, "Missing home counts stay unknown rather than zero")
        let emptyTotal = AutoDLInstance.parse(["uuid": "i-4", "name": "t", "status": "shutdown", "gpu_idle_num": 0, "gpu_all_num": 0])!
        check(emptyTotal.homeIdle == 0 && emptyTotal.homeTotal == nil, "A zero total is treated as unknown")

        // What counts as available: idle cards only count on machines that are online AND have a free instance slot.
        func raw(_ id: String, onLine: Int?, binding: Int?, max maxSlots: Int?, idle: Int = 4) -> [String: Any] {
            var d: [String: Any] = ["machine_id": id, "gpu_name": "RTX 4090", "gpu_number": 8, "gpu_idle_num": idle,
                                    "region_name": "西北B区", "region_sign": "west-E"]
            if let onLine { d["on_line"] = onLine }
            if let binding { d["binding_instance_num"] = binding }
            if let maxSlots { d["max_instance_num"] = maxSlots }
            return d
        }
        check(MarketMachine.parse(raw("a", onLine: 2, binding: 10, max: 100))!.isRentable, "Online with a free slot is rentable")
        check(!MarketMachine.parse(raw("b", onLine: 3, binding: 10, max: 100))!.isRentable, "on_line 3 is not rentable, whatever its idle count")
        check(!MarketMachine.parse(raw("c", onLine: 6, binding: 10, max: 100))!.isRentable, "on_line 6 is not rentable")
        check(!MarketMachine.parse(raw("d", onLine: 2, binding: 143, max: 143))!.isRentable, "A machine with every instance slot taken is not rentable")
        check(MarketMachine.parse(raw("d", onLine: 2, binding: 143, max: 143))!.isOnline, "A full machine is still online for its own instances")
        check(!MarketMachine.parse(raw("e", onLine: 3, binding: 1, max: 100))!.isOnline, "An offline machine cannot start its own instances")
        check(MarketMachine.parse(raw("f", onLine: nil, binding: nil, max: nil))!.isRentable, "Missing availability fields are not treated as unavailable")
        check(MarketMachine.parse(raw("g", onLine: 2, binding: 5, max: 0))!.isRentable, "An unknown slot limit (0) means no limit")

        func m(_ id: String, onLine: Int = 2, binding: Int = 0, max maxSlots: Int = 100, idle: Int) -> MarketMachine {
            MarketMachine(id: id, alias: id, gpuName: "RTX 4090", regionName: "西北B区", regionSign: "west-E",
                          gpuNumber: 8, gpuIdle: idle, hourlyPrice: 2,
                          onLine: onLine, bindingInstances: binding, maxInstances: maxSlots)
        }
        let mixed = RegionSnapshot(regionSign: "west-E", machines: [
            m("ok", idle: 3), m("offline", onLine: 3, idle: 100), m("full", binding: 100, max: 100, idle: 50),
        ], fetchedAt: Date())
        check(mixed.idleGPUs == 3, "Region idle count ignores offline and slot-full machines")
        check(mixed.models.first?.idleGPUs == 3 && mixed.models.first?.machineCount == 1, "Model summary counts rentable machines only")
        check(mixed.machine(withID: "full")?.gpuIdle == 50, "A slot-full machine can still be looked up for the user's own instance")
        check(mixed.machine(withID: "offline")?.isOnline == false, "The lookup keeps the on_line state")

        let strict = MarketStore(defaults: testDefaults)
        for rule in strict.alertRules { strict.removeRule(id: rule.id) }
        var strictFired = 0
        strict.setAlertHandler { _, _, _ in strictFired += 1 }
        strict.addRule(regionSign: "west-E", regionName: "西北B区", gpuName: "RTX 4090", minCards: 1)
        strict.ingest(regionSign: "west-E", machines: [m("offline", onLine: 3, idle: 100), m("full", binding: 100, max: 100, idle: 50)])
        check(strictFired == 0, "Hundreds of idle cards on unrentable machines must not fire an alert")
        strict.ingest(regionSign: "west-E", machines: [m("offline", onLine: 3, idle: 100), m("ok", idle: 1)])
        check(strictFired == 1, "A rentable machine does fire it")
        for rule in strict.alertRules { strict.removeRule(id: rule.id) }

        print("RegionAlertTests passed (\(checks) checks)")
    }
}
