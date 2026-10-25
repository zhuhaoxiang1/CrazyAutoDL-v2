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

        // Auto-clone: one-shot, opt-in, and old saved rules still decode.
        let legacy = Data(#"{"regionSign":"west-E","regionName":"西北B区","gpuName":"RTX 4090","minCards":2}"#.utf8)
        let legacyRule = try! JSONDecoder().decode(RegionAlertRule.self, from: legacy)
        check(!legacyRule.autoClone && legacyRule.cloneSourceID == nil, "Rules saved before auto-clone decode with it off")

        let cloner = MarketStore(defaults: testDefaults)
        for rule in cloner.alertRules { cloner.removeRule(id: rule.id) }
        var cloneCalls: [(rule: String, machines: [String])] = []
        var attemptedRules: [RegionAlertRule] = []
        var cloneStarts = true
        cloner.setAlertHandler { _, _, _ in }
        cloner.setCloneHandler { rule, hits in
            attemptedRules.append(rule)
            cloneCalls.append((rule.cloneSourceID ?? "", hits.map(\.id)))
            return cloneStarts
        }
        cloner.addRule(regionSign: "west-E", regionName: "西北B区", gpuName: "RTX 4090", minCards: 1)
        cloner.ingest(regionSign: "west-E", machines: [m("a", idle: 1)])
        check(cloneCalls.isEmpty, "A rule without the auto-clone opt-in never clones")
        cloner.ingest(regionSign: "west-E", machines: [])
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "src-1")
        check(cloner.alertRules.first?.autoClone == true, "Opt-in is stored on the rule")
        cloner.ingest(regionSign: "west-E", machines: [m("b", idle: 2)])
        check(cloneCalls.count == 1 && cloneCalls[0].rule == "src-1" && cloneCalls[0].machines == ["b"], "Cards appearing clones the chosen source")
        check(cloner.alertRules.first?.autoClone == false, "The opt-in is spent once a clone started")
        cloner.ingest(regionSign: "west-E", machines: [])
        cloner.ingest(regionSign: "west-E", machines: [m("c", idle: 2)])
        check(cloneCalls.count == 1, "A later sighting does not clone again without a new opt-in")

        // Several armed rules on one source: the first clone spends them all.
        cloneStarts = true
        cloner.addRule(regionSign: "west-E", regionName: "西北B区", gpuName: "RTX 5090", minCards: 1)
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "src-1")
        cloner.setAutoClone(id: "west-E|RTX 5090", enabled: true, sourceID: "src-1")
        let callsBefore = cloneCalls.count
        cloner.ingest(regionSign: "west-E", machines: [m("e", idle: 2), machine("f", model: "RTX 5090", region: "west-E", idle: 2)])
        check(cloneCalls.count == callsBefore + 1, "Two armed rules on one source clone only once")
        check(cloner.alertRules.allSatisfy { !$0.autoClone }, "A started clone disarms every rule for the same source")
        cloner.ingest(regionSign: "west-E", machines: [])
        cloner.removeRule(id: "west-E|RTX 5090")

        // Arming while cards are already free clones at the next scan; a failed order puts the rules back, 3 times at most.
        cloneStarts = true
        cloner.ingest(regionSign: "west-E", machines: [machine("g", idle: 2)])
        let callsWhileFree = cloneCalls.count
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "src-2")
        cloner.ingest(regionSign: "west-E", machines: [machine("g", idle: 2)])
        check(cloneCalls.count == callsWhileFree + 1, "Arming with cards already free clones on the next scan")
        check(cloner.alertRules.first { $0.id == "west-E|RTX 4090" }?.autoClone == false, "...and that spends the opt-in")
        check(cloner.restoreAutoClone(for: attemptedRules.last!) == 2, "A failed order re-arms the rule, 2 attempts left")
        check(cloner.alertRules.first { $0.id == "west-E|RTX 4090" }?.autoClone == true, "The rule is armed again")
        cloner.ingest(regionSign: "west-E", machines: [machine("h", idle: 2)])
        check(cloneCalls.count == callsWhileFree + 2, "The re-armed rule retries on the next scan")
        check(cloner.restoreAutoClone(for: attemptedRules.last!) == 1, "The second failure leaves one attempt")
        cloner.ingest(regionSign: "west-E", machines: [machine("i", idle: 2)])
        check(cloneCalls.count == callsWhileFree + 3, "Three attempts include the initial order")
        check(cloner.restoreAutoClone(for: attemptedRules.last!) == nil, "A third failure cannot authorize a fourth attempt")
        cloner.ingest(regionSign: "west-E", machines: [])

        cloneStarts = false
        let callsBeforeRefused = cloneCalls.count
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "src-1")
        cloner.ingest(regionSign: "west-E", machines: [])
        cloner.ingest(regionSign: "west-E", machines: [m("d", idle: 2)])
        check(cloneCalls.count == callsBeforeRefused + 1 && cloner.alertRules.first?.autoClone == true, "A refused clone keeps the opt-in")
        cloneStarts = true
        cloner.ingest(regionSign: "west-E", machines: [m("eligible-later", idle: 2)])
        check(cloneCalls.count == callsBeforeRefused + 2, "A later eligible machine is checked even when cards never disappeared")
        let staleAttempt = attemptedRules.last!
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "new-source")
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: false, sourceID: nil)
        check(cloner.restoreAutoClone(for: staleAttempt) == nil, "An old failure cannot undo a newer source choice or cancellation")
        cloner.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: nil)
        check(cloner.alertRules.first?.autoClone == false, "Auto-clone cannot be armed without a source instance")
        for rule in cloner.alertRules { cloner.removeRule(id: rule.id) }

        // The clone request mirrors the console's: pay-as-you-go, both disks, sparse optimisation, expansion aligned.
        let source = AutoDLInstance.parse([
            "uuid": "src-1", "name": "dev", "status": "shutdown", "req_gpu_amount": 2, "region_sign": "west-E",
            "machine_id": "old", "charge_type": "daily", "expand_data_disk_size": 200 * 1_073_741_824,
            "private_image_uuid": "img-9", "reproduction_id": 7
        ])!
        check(source.expandDataDiskBytes == 200 * 1_073_741_824 && source.privateImageUUID == "img-9" && source.reproductionID == 7,
              "Instance parsing keeps what a clone needs")
        let roomy = MarketMachine(id: "m1", alias: "m1", gpuName: "RTX 4090", regionName: "x", regionSign: "west-E",
                                  gpuNumber: 8, gpuIdle: 4, hourlyPrice: 2, maxDataDiskExpand: 500 * 1_073_741_824)
        let tight = MarketMachine(id: "m2", alias: "m2", gpuName: "RTX 4090", regionName: "x", regionSign: "west-E",
                                  gpuNumber: 8, gpuIdle: 4, hourlyPrice: 2, maxDataDiskExpand: 100 * 1_073_741_824)
        var image = AutoDLAPI.CloneImage()
        image.baseImageUUID = "pytorch-base"
        let body = try! AutoDLAPI.cloneBody(source: source, image: image, machine: roomy)
        let info = body["instance_info"] as! [String: Any]
        let price = body["price_info"] as! [String: Any]
        check(body["instance_uuid"] as? String == "src-1", "Clone body names the source instance")
        check(info["machine_id"] as? String == "m1" && info["charge_type"] as? String == "payg", "Clone targets the machine, pay-as-you-go")
        check(info["req_gpu_amount"] as? Int == 2 && price["num"] as? Int == 2, "Clone keeps the source's card count")
        check(info["copy_data_disk_after_clone"] as? Bool == true && info["ft_sparse"] as? Bool == true, "Data disk and sparse optimisation are on")
        check(info["expand_data_disk"] as? Int64 == 200 * 1_073_741_824 && price["expand_data_disk"] as? Int64 == 200 * 1_073_741_824, "Data disk expansion is aligned with the source")
        check(AutoDLAPI.machineFitsCloneDisk(source: source, machine: roomy), "A machine whose expansion limit covers the source fits")
        check(!AutoDLAPI.machineFitsCloneDisk(source: source, machine: tight), "A machine that cannot expand as far as the source is refused")
        let unknownLimit = MarketMachine(id: "m3", alias: "m3", gpuName: "RTX 4090", regionName: "x", regionSign: "west-E",
                                         gpuNumber: 8, gpuIdle: 4, hourlyPrice: 2)
        check(!AutoDLAPI.machineFitsCloneDisk(source: source, machine: unknownLimit), "An unreported expansion limit cannot be confirmed, so it is refused")
        let plain = AutoDLInstance.parse(["uuid": "src-3", "name": "p", "status": "shutdown", "req_gpu_amount": 1, "region_sign": "west-E", "expand_data_disk_size": 0])!
        check(AutoDLAPI.machineFitsCloneDisk(source: plain, machine: unknownLimit), "A source with no expanded data disk fits any machine")
        check(AutoDLAPI.cloneExpandBytes(source: source, machine: tight) == 200 * 1_073_741_824, "The clone never asks for less data disk than the source has")
        let unknownSource = AutoDLInstance.parse(["uuid": "unknown", "usage_info": ["data_disk_total_size": 250 * 1_073_741_824]])!
        check(unknownSource.expandDataDiskBytes == nil, "A missing source expansion stays unknown even with a reported total")
        check(!AutoDLAPI.machineFitsCloneDisk(source: unknownSource, machine: roomy), "An unknown source capacity cannot pass the disk gate")
        check((try? AutoDLAPI.cloneBody(source: unknownSource, image: image, machine: roomy)) == nil, "The paid API body also rejects unknown source capacity")
        check((try? AutoDLAPI.cloneBody(source: source, image: image, machine: tight)) == nil, "The API body refuses to bypass the capacity gate")
        check(AutoDLInstance.parse(["uuid": "bad", "expand_data_disk_size": -1])?.expandDataDiskBytes == nil, "Negative expansion is unknown, not zero")

        let migration = MarketStore(defaults: testDefaults)
        migration.addRule(regionSign: "west-E", regionName: "西北B区", gpuName: "RTX 4090")
        migration.setAutoClone(id: "west-E|RTX 4090", enabled: true, sourceID: "migration-source")
        let consent = migration.alertRules[0].cloneAuthorizationID
        migration.setRegionCatalog(catalog)
        check(migration.alertRules[0].autoClone && migration.alertRules[0].cloneSourceID == "migration-source", "Catalog normalization preserves clone settings")
        check(migration.alertRules[0].cloneAuthorizationID == consent, "Normalization keeps the consent identity")
        migration.setRegionCatalog(catalog)
        check(migration.alertRules[0].autoClone, "Reloading the same catalog cannot silently turn off cloning")
        var pausedCalls = 0
        migration.setCloneHandler { _, _ in pausedCalls += 1; return false }
        migration.watchPaused = true
        migration.ingest(regionSign: "west-B", machines: [m("paused", idle: 2)])
        check(pausedCalls == 0, "Manual region ingests cannot trigger cloning while paused")
        migration.watchPaused = false
        migration.ingest(regionSign: "west-B", machines: [m("resumed", idle: 2)])
        check(pausedCalls == 1, "A fresh scan after resume can trigger the armed rule")

        let budget = MarketStore(defaults: testDefaults)
        for rule in budget.alertRules { budget.removeRule(id: rule.id) }
        budget.addRule(regionSign: "region-budget", regionName: "预算测试", gpuName: "RTX 4090")
        budget.setAutoClone(id: "region-budget|RTX 4090", enabled: true, sourceID: "budget-source")
        var budgetAttempt: RegionAlertRule?
        budget.setCloneHandler { rule, _ in budgetAttempt = rule; return true }
        budget.ingest(regionSign: "region-budget", machines: [machine("budget-1", region: "region-budget", idle: 2)])
        check(budget.restoreAutoClone(for: budgetAttempt!) == 2, "Two attempts remain before relaunch")
        let resumedBudget = MarketStore(defaults: testDefaults)
        resumedBudget.setCloneHandler { rule, _ in budgetAttempt = rule; return true }
        resumedBudget.ingest(regionSign: "region-budget", machines: [machine("budget-2", region: "region-budget", idle: 2)])
        check(resumedBudget.restoreAutoClone(for: budgetAttempt!) == 1, "Relaunch does not reset the attempt budget")
        resumedBudget.ingest(regionSign: "region-budget", machines: [machine("budget-3", region: "region-budget", idle: 2)])
        check(resumedBudget.restoreAutoClone(for: budgetAttempt!) == nil, "The original three-attempt limit survives relaunch")

        print("RegionAlertTests passed (\(checks) checks)")
    }
}
