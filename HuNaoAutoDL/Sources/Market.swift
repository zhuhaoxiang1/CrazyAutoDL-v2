import Foundation
import SwiftUI

/// One machine as returned by `/user/machine/list`, trimmed to what the market view needs.
///
/// `gpu_idle_num` alone is NOT what can be rented. Measured against AutoDL's own market counts (`gpu_type`) over
/// 35 models in three data centers, the cards that really can be rented are the idle cards of machines that are
/// `on_line == 2` and still have a free instance slot (`binding_instance_num < max_instance_num`). Counting every
/// idle card overstated availability by 10x or more (e.g. 210 "idle" RTX 4090 in a region where 0 were rentable).
struct MarketMachine: Identifiable, Equatable {
    let id: String
    let alias: String
    let gpuName: String
    let regionName: String
    let regionSign: String
    let gpuNumber: Int
    let gpuIdle: Int
    /// Hourly pay-as-you-go price in yuan. AutoDL reports it in thousandths of a yuan.
    let hourlyPrice: Double?
    /// AutoDL `on_line`: 2 is online and rentable; other values (3, 4, 5, 6) are not, whatever their idle count.
    var onLine: Int = 2
    var bindingInstances: Int = 0
    /// 0 means the limit is unknown, which counts as no limit.
    var maxInstances: Int = 0
    /// How much data disk (bytes) can be added on top of the base one; nil when the list did not say.
    var maxDataDiskExpand: Int64? = nil

    /// Whether a NEW instance can be created here now: online and an instance slot is free.
    var isRentable: Bool {
        onLine == 2 && (maxInstances == 0 || bindingInstances < maxInstances)
    }

    /// Whether an EXISTING instance of the user's on this machine can start: it already owns its slot, so a full
    /// slot count does not block it, but the machine must be online.
    var isOnline: Bool { onLine == 2 }

    static func parse(_ raw: [String: Any]) -> MarketMachine? {
        guard let id = jsonString(raw["machine_id"]) else { return nil }
        let price = jsonDouble(raw["payg_price"]).map { $0 / 1000 }
        return MarketMachine(
            id: id,
            alias: jsonString(raw["machine_alias"]) ?? id,
            gpuName: jsonString(raw["gpu_name"]) ?? jsonString(raw["gpu_type_name"]) ?? "GPU",
            regionName: jsonString(raw["region_name"]) ?? "未知区域",
            regionSign: jsonString(raw["region_sign"]) ?? "",
            gpuNumber: jsonInt(raw["gpu_number"]) ?? jsonInt(raw["gpu_num"]) ?? 0,
            gpuIdle: max(0, jsonInt(raw["gpu_idle_num"]) ?? 0),
            hourlyPrice: price,
            onLine: jsonInt(raw["on_line"]) ?? 2,
            bindingInstances: jsonInt(raw["binding_instance_num"]) ?? 0,
            maxInstances: jsonInt(raw["max_instance_num"]) ?? 0,
            maxDataDiskExpand: jsonInt64(raw["max_data_disk_expand_size"])
        )
    }
}

/// Machines of one GPU model inside one region pool.
struct MarketCell: Equatable {
    let regionSign: String
    let machines: [MarketMachine]

    var idleGPUs: Int { machines.reduce(0) { $0 + $1.gpuIdle } }
    var machineCount: Int { machines.count }
    var cheapest: Double? { machines.compactMap(\.hourlyPrice).min() }
    /// Largest idle count on a single machine: a multi-card instance can only land on one machine.
    var bestSingleMachine: Int { machines.map(\.gpuIdle).max() ?? 0 }
}

struct MarketRow: Identifiable, Equatable {
    let gpuName: String
    let machines: [MarketMachine]
    let error: String?

    var id: String { gpuName }
    var idleGPUs: Int { machines.reduce(0) { $0 + $1.gpuIdle } }
    var cheapest: Double? { machines.compactMap(\.hourlyPrice).min() }

    func cell(in regionSign: String) -> MarketCell? {
        let list = machines.filter { $0.regionSign == regionSign }
        return list.isEmpty ? nil : MarketCell(regionSign: regionSign, machines: list)
    }
}

struct MarketRegion: Identifiable, Equatable {
    let sign: String
    let name: String
    var id: String { sign }
}

/// A region pool from AutoDL's public region list. Pools sharing a name (e.g. west-B..E) form one data center.
struct CatalogRegion: Identifiable, Equatable {
    let sign: String
    let name: String
    let dataCenter: String

    var id: String { sign }

    static func parse(_ raw: [String: Any]) -> CatalogRegion? {
        guard let sign = jsonString(raw["region_sign"]), !sign.isEmpty else { return nil }
        if let visible = raw["visible"] as? Bool, !visible { return nil }
        return CatalogRegion(
            sign: sign,
            name: jsonString(raw["region_name"]) ?? sign,
            dataCenter: jsonString(raw["data_center"]) ?? ""
        )
    }
}

/// One GPU model's card counts in a region (or across several), idle ones included or not.
struct GPUTypeStat: Identifiable, Equatable {
    let name: String
    let idle: Int
    let total: Int

    var id: String { name }
    /// AutoDL lists CPU-only machines next to the GPUs; they are not something to wait for a card on.
    var isCPUOnly: Bool { name.uppercased().hasPrefix("CPU") }

    /// `data` is a list of `{ "<model>": { "idle_gpu_num": n, "total_gpu_num": m } }`.
    static func parseList(_ data: Any?) -> [GPUTypeStat] {
        guard let list = data as? [[String: Any]] else { return [] }
        return list
            .flatMap { entry in
                entry.compactMap { name, value -> GPUTypeStat? in
                    guard let stats = value as? [String: Any] else { return nil }
                    return GPUTypeStat(
                        name: name,
                        idle: max(0, jsonInt(stats["idle_gpu_num"]) ?? 0),
                        total: max(0, jsonInt(stats["total_gpu_num"]) ?? 0)
                    )
                }
            }
            .sorted { ($0.idle, $0.total, $1.name) > ($1.idle, $1.total, $0.name) }
    }
}

/// "Tell me when this model has idle cards in this region."
/// `minCards` is per machine: a multi-card instance can only land on a single machine.
struct RegionAlertRule: Codable, Identifiable, Equatable {
    let regionSign: String
    let regionName: String
    let gpuName: String
    var minCards: Int
    /// When set, the first sighting of a matching machine clones `cloneSourceID` onto it (pay-as-you-go, system disk
    /// + data disk, sparse-file optimisation). One-shot: switched off again as soon as a clone is attempted.
    var autoClone = false
    var cloneSourceID: String?
    var cloneAuthorizationID = UUID().uuidString

    var id: String { "\(regionSign)|\(gpuName)" }
}

extension RegionAlertRule {
    /// Rules saved before auto-clone existed have no such keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        regionSign = try c.decode(String.self, forKey: .regionSign)
        regionName = try c.decode(String.self, forKey: .regionName)
        gpuName = try c.decode(String.self, forKey: .gpuName)
        minCards = try c.decode(Int.self, forKey: .minCards)
        autoClone = try c.decodeIfPresent(Bool.self, forKey: .autoClone) ?? false
        cloneSourceID = try c.decodeIfPresent(String.self, forKey: .cloneSourceID)
        cloneAuthorizationID = try c.decodeIfPresent(String.self, forKey: .cloneAuthorizationID) ?? UUID().uuidString
    }
}

/// One GPU model inside a single region.
struct ModelSummary: Identifiable, Equatable {
    let gpuName: String
    let machines: [MarketMachine]

    var id: String { gpuName }
    var idleGPUs: Int { machines.reduce(0) { $0 + $1.gpuIdle } }
    var machineCount: Int { machines.count }
    /// A multi-card instance can only land on one machine, so this is what a clone can actually use.
    var bestSingleMachine: Int { machines.map(\.gpuIdle).max() ?? 0 }
    var cheapest: Double? { machines.compactMap(\.hourlyPrice).min() }
}

/// Everything rentable in one region right now: machines with at least one idle card, every model.
struct RegionSnapshot: Equatable {
    let regionSign: String
    let machines: [MarketMachine]
    let fetchedAt: Date

    var regionName: String { machines.first?.regionName ?? regionSign }
    /// Machines a new instance could land on. Everything shown as "available" is computed from these.
    var rentableMachines: [MarketMachine] { machines.filter(\.isRentable) }
    var idleGPUs: Int { rentableMachines.reduce(0) { $0 + $1.gpuIdle } }

    /// Models, most idle cards first. Only rentable machines count.
    var models: [ModelSummary] {
        Dictionary(grouping: rentableMachines, by: \.gpuName)
            .map { ModelSummary(gpuName: $0.key, machines: $0.value) }
            .sorted { ($0.idleGPUs, $1.gpuName) > ($1.idleGPUs, $0.gpuName) }
    }

    func machine(withID id: String) -> MarketMachine? {
        guard !id.isEmpty else { return nil }
        return machines.first { $0.id.lowercased() == id.lowercased() }
    }
}

struct MarketSnapshot: Equatable {
    let rows: [MarketRow]
    let fetchedAt: Date

    /// Columns, busiest region first so the useful ones sit on the left.
    var regions: [MarketRegion] {
        var idleBySign: [String: Int] = [:]
        var nameBySign: [String: String] = [:]
        for machine in rows.flatMap(\.machines) {
            idleBySign[machine.regionSign, default: 0] += machine.gpuIdle
            nameBySign[machine.regionSign] = machine.regionName
        }
        return idleBySign
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { MarketRegion(sign: $0.key, name: nameBySign[$0.key] ?? $0.key) }
    }
}

struct RuleScanStatus: Equatable {
    var lastSuccess: Date?
    var lastError: String?

    var isStale: Bool { lastError != nil }
}

/// Market scan state. It only fetches while the market page is on screen, so it adds no background polling.
@MainActor
final class MarketStore: ObservableObject {
    @Published private(set) var snapshot: MarketSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var watchlist: [String]
    @Published private(set) var regionSnapshots: [String: RegionSnapshot] = [:]
    @Published private(set) var regionErrors: [String: String] = [:]
    @Published private(set) var loadingRegions: Set<String> = []
    @Published private(set) var alertRules: [RegionAlertRule] = []
    /// Every region pool AutoDL runs (public list); empty until the first load.
    @Published private(set) var regionCatalog: [CatalogRegion] = []
    /// Model counts per region pool, with models that have nothing idle.
    @Published private(set) var gpuTypesByRegion: [String: [GPUTypeStat]] = [:]
    /// Model counts across all region pools, for pickers that are not tied to one region.
    @Published private(set) var allGPUTypes: [GPUTypeStat] = []
    private var gpuTypesFetchedAt: [String: Date] = [:]

    /// Rule id -> whether the next "has cards" observation should notify. Re-armed once the cards are gone,
    /// so a model that stays available is announced once, not on every scan.
    /// Machines that currently satisfy each rule, kept so the rule chips can show "现有 N 台".
    @Published private(set) var ruleHits: [String: [MarketMachine]] = [:]
    /// Per rule: when the background scan last succeeded and why the latest one failed, if it did. A failed scan
    /// keeps the old hits but they are no longer live, and the chips say so.
    @Published private(set) var ruleScanStatus: [String: RuleScanStatus] = [:]
    /// Machines the last scan of each region returned; big regions are polled less often.
    private var regionMachineCounts: [String: Int] = [:]
    private var armed: [String: Bool] = [:]
    /// While the background watcher runs it is the only thing that fires alerts, so two sources never disagree.
    private var watcherRunning = false
    /// Set by the app-wide "pause monitoring" switch: the background region scan idles and raises no alerts.
    var watchPaused = false {
        didSet { if watchPaused != oldValue { watchVersion += 1 } }
    }
    private var watchVersion = 0
    private var watchTask: Task<Void, Never>?
    private var regionWatchTasks: [String: Task<Void, Never>] = [:]
    private var onAlert: ((_ title: String, _ body: String, _ id: String) -> Void)?
    /// Runs the clone for a rule that just matched; returns whether one was really started.
    private var onClone: ((_ rule: RegionAlertRule, _ hits: [MarketMachine]) -> Bool)?
    /// Rules each source's last started clone disarmed, so a failed clone can put them back.
    private var spentCloneRules: [String: [RegionAlertRule]] = [:]
    /// Re-tries a source still has: a clone that loses the race for a card is retried a few times, never forever.
    private var cloneRetriesLeft: [String: Int] = [:]
    static let maxCloneAttempts = 3
    /// Region scan pace while a rule in it has auto-clone armed: a card is often gone within seconds.
    static let fastScanNanos: UInt64 = 1_000_000_000
    static let idleScanSeconds: TimeInterval = 25

    /// Names AutoDL uses in the `gpu_type_name` filter. The first five were seen in a live region query;
    /// the rest are common models whose exact spelling is unconfirmed (a wrong name just returns an empty row).
    /// Offered as suggestions, never added automatically.
    static let suggestions = [
        "RTX 6000D", "RTX 5090", "RTX 5090 D", "vGPU-48GB", "vGPU-32GB",
        "RTX 4090", "RTX 3090", "A100-SXM4-80GB", "H800"
    ]

    private static let defaultsKey = "hunao.market.watchlist"
    private static let rulesKey = "hunao.market.alertRules"
    private static let attemptsKey = "hunao.market.cloneAttemptsRemaining"
    private let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

    private let defaults: UserDefaults
    private let apiSession: URLSession?

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        self.apiSession = session
        watchlist = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        cloneRetriesLeft = (defaults.dictionary(forKey: Self.attemptsKey) ?? [:]).compactMapValues {
            jsonInt($0).map { min(max($0, 0), Self.maxCloneAttempts) }
        }
        if let data = defaults.data(forKey: Self.rulesKey),
           let rules = try? JSONDecoder().decode([RegionAlertRule].self, from: data) {
            alertRules = rules
        }
        if isDemo {
            snapshot = Self.demoSnapshot()
            regionSnapshots = Self.demoRegions()
            regionCatalog = [
                CatalogRegion(sign: "beijing-b", name: "北京B区", dataCenter: "beijingDC2"),
                CatalogRegion(sign: "neimeng-a", name: "内蒙A区", dataCenter: "neimengDC3"),
                CatalogRegion(sign: "shanghai-a", name: "上海A区", dataCenter: "shanghaiDC1"),
                CatalogRegion(sign: "west-B", name: "西北B区", dataCenter: "westDC3"),
                CatalogRegion(sign: "west-E", name: "西北B区", dataCenter: "westDC3"),
                CatalogRegion(sign: "cq-A1", name: "重庆A区", dataCenter: "chongqingDC1")
            ]
            let demoTypes = [
                GPUTypeStat(name: "RTX 4090", idle: 4, total: 1352),
                GPUTypeStat(name: "RTX 5090", idle: 4, total: 2544),
                GPUTypeStat(name: "vGPU-48GB", idle: 4, total: 250),
                GPUTypeStat(name: "RTX 3080 Ti", idle: 6, total: 88),
                GPUTypeStat(name: "H800", idle: 0, total: 96),
                GPUTypeStat(name: "RTX PRO 6000", idle: 0, total: 351),
                GPUTypeStat(name: "A800-80GB-NVLink", idle: 0, total: 320)
            ]
            gpuTypesByRegion = ["beijing-b": demoTypes, "shanghai-a": [GPUTypeStat(name: "RTX 3090", idle: 3, total: 210)] + demoTypes.prefix(1)]
            allGPUTypes = demoTypes + [GPUTypeStat(name: "RTX 3090", idle: 3, total: 210)]
            alertRules = [
                RegionAlertRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "RTX 4090", minCards: 1),
                RegionAlertRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "RTX 5090", minCards: 4),
                RegionAlertRule(regionSign: "beijing-b", regionName: "北京B区", gpuName: "H800", minCards: 1),
                RegionAlertRule(regionSign: "shanghai-a", regionName: "上海A区", gpuName: "RTX 3090", minCards: 2)
            ]
        }
    }

    func setRegionCatalog(_ regions: [CatalogRegion]) {
        regionCatalog = regions
        normalizeRules()
    }

    // MARK: Region groups

    /// "西北B区" is four pools (west-B..E) that share a data center. People mean the whole thing when they say
    /// the region, so everything region-scoped covers every pool of the data center.
    func groupSigns(for sign: String) -> [String] {
        guard let center = regionCatalog.first(where: { $0.sign == sign })?.dataCenter, !center.isEmpty else {
            return [sign]
        }
        let signs = regionCatalog.filter { $0.dataCenter == center }.map(\.sign).sorted()
        return signs.isEmpty ? [sign] : signs
    }

    /// One key per data center: its first pool's sign. Snapshots, tabs and alert rules are all keyed by it.
    func canonicalSign(for sign: String) -> String {
        groupSigns(for: sign).first ?? sign
    }

    func groupName(for sign: String) -> String? {
        regionCatalog.first { $0.sign == sign }?.name
    }

    /// Rules saved before the region list was known are keyed by a single pool; move them to the data center.
    private func normalizeRules() {
        var seen = Set<String>()
        var changed = false
        var result: [RegionAlertRule] = []
        for rule in alertRules {
            let sign = canonicalSign(for: rule.regionSign)
            let migrated = RegionAlertRule(
                regionSign: sign,
                regionName: groupName(for: sign) ?? rule.regionName,
                gpuName: rule.gpuName,
                minCards: rule.minCards,
                autoClone: rule.autoClone,
                cloneSourceID: rule.cloneSourceID,
                cloneAuthorizationID: rule.cloneAuthorizationID
            )
            if migrated != rule { changed = true }
            if seen.insert(migrated.id).inserted {
                result.append(migrated)
            } else if let index = result.firstIndex(where: { $0.id == migrated.id }) {
                changed = true
                let previous = result[index]
                if !previous.autoClone && migrated.autoClone { result[index] = migrated }
                if previous.autoClone && migrated.autoClone && previous.cloneSourceID != migrated.cloneSourceID {
                    result[index].autoClone = false
                    result[index].cloneSourceID = nil
                    result[index].cloneAuthorizationID = UUID().uuidString
                }
                result[index].minCards = max(previous.minCards, migrated.minCards)
            }
        }
        if changed {
            alertRules = result
            persistRules()
        }
    }

    /// Loads the public region list once, then the all-region model counts (needs login, cached for 10 minutes).
    func loadCatalogIfNeeded(account: AutoDLAccount?) async {
        guard !isDemo else { return }
        if regionCatalog.isEmpty, let regions = try? await AutoDLAPI.fetchRegionCatalog() {
            setRegionCatalog(regions)
        }
        let key = "*"
        if let last = gpuTypesFetchedAt[key], Date().timeIntervalSince(last) < 600 { return }
        guard let account, !account.token.isEmpty, !regionCatalog.isEmpty else { return }
        gpuTypesFetchedAt[key] = Date()
        let api = AutoDLAPI(token: account.token, isSubAccount: account.isSubAccount)
        if let types = try? await api.fetchGPUTypes(regionSigns: regionCatalog.map(\.sign)) {
            allGPUTypes = types
        } else {
            gpuTypesFetchedAt[key] = nil
        }
    }

    /// Model counts for a whole region (every pool of its data center); refreshed at most every two minutes.
    func refreshGPUTypes(account: AutoDLAccount?, regionSign: String) async {
        guard !isDemo, let account, !account.token.isEmpty, !regionSign.isEmpty else { return }
        if let last = gpuTypesFetchedAt[regionSign], Date().timeIntervalSince(last) < 120 { return }
        gpuTypesFetchedAt[regionSign] = Date()
        let api = AutoDLAPI(token: account.token, isSubAccount: account.isSubAccount)
        if let types = try? await api.fetchGPUTypes(regionSigns: groupSigns(for: regionSign)) {
            gpuTypesByRegion[regionSign] = types
        } else {
            gpuTypesFetchedAt[regionSign] = nil
        }
    }

    /// Regions for the "other regions" picker: the full public list, plus any seen in scans.
    var knownRegions: [MarketRegion] {
        var names: [String: String] = [:]
        for region in regionCatalog {
            names[canonicalSign(for: region.sign)] = region.name
        }
        for machine in (snapshot?.rows.flatMap(\.machines) ?? []) {
            names[canonicalSign(for: machine.regionSign)] = names[canonicalSign(for: machine.regionSign)] ?? machine.regionName
        }
        for (sign, region) in regionSnapshots {
            names[sign] = names[sign] ?? region.regionName
        }
        return names.map { MarketRegion(sign: $0.key, name: $0.value) }.sorted { $0.sign < $1.sign }
    }

    /// Scans one whole region (all models). Only the focused region is polled, one query per page of 100 machines.
    func refreshRegion(account: AutoDLAccount?, regionSign: String, chargeType: String) async {
        guard !isDemo, let account, !account.token.isEmpty, !regionSign.isEmpty,
              !loadingRegions.contains(regionSign)
        else { return }
        // The dashboard and the background watcher both call this; a fresh snapshot serves both.
        if let last = regionSnapshots[regionSign]?.fetchedAt, Date().timeIntervalSince(last) < 10 { return }
        loadingRegions.insert(regionSign)
        defer { loadingRegions.remove(regionSign) }

        let api = AutoDLAPI(token: account.token, isSubAccount: account.isSubAccount)
        do {
            let result = try await api.fetchRegionMachines(regionSigns: groupSigns(for: regionSign), chargeType: chargeType)
            if Task.isCancelled { return }
            regionMachineCounts[regionSign] = result.machines.count
            ingest(regionSign: regionSign, machines: result.machines)
        } catch {
            regionErrors[regionSign] = error.localizedDescription
        }
    }

    /// How long to wait before scanning this region again. A data center with many machines returns megabytes
    /// and takes seconds (about 1500 machines took 3.6 s), so it is polled gently.
    func suggestedScanInterval(for regionSign: String) -> UInt64 {
        (regionMachineCounts[regionSign] ?? 0) > 500 ? 60_000_000_000 : 20_000_000_000
    }

    func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !watchlist.contains(trimmed) else { return }
        watchlist.append(trimmed)
        persist()
    }

    func remove(_ name: String) {
        watchlist.removeAll { $0 == name }
        persist()
        if let snapshot {
            self.snapshot = MarketSnapshot(
                rows: snapshot.rows.filter { $0.gpuName != name },
                fetchedAt: snapshot.fetchedAt
            )
        }
    }

    /// Scans each model in turn (not in parallel) to stay gentle with AutoDL's rate limit.
    func refresh(account: AutoDLAccount?, gpuNames: [String], chargeType: String) async {
        guard !isDemo, !isLoading, let account, !account.token.isEmpty, !gpuNames.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let api = AutoDLAPI(token: account.token, isSubAccount: account.isSubAccount)
        var rows: [MarketRow] = []
        for name in gpuNames {
            if Task.isCancelled { return }
            do {
                let machines = try await api.fetchMarketMachines(gpuName: name, chargeType: chargeType)
                rows.append(MarketRow(gpuName: name, machines: machines, error: nil))
            } catch {
                rows.append(MarketRow(gpuName: name, machines: [], error: error.localizedDescription))
            }
        }
        // Merge instead of replace: the dashboard scans only the target model, the market page scans them all.
        let scanned = Set(gpuNames)
        let kept = (snapshot?.rows ?? []).filter { !scanned.contains($0.gpuName) }
        snapshot = MarketSnapshot(rows: kept + rows, fetchedAt: Date())
    }

    private func persist() {
        // Demo mode must not leak its sample data into the real settings.
        guard !isDemo else { return }
        defaults.set(watchlist, forKey: Self.defaultsKey)
    }

    // MARK: Region alerts

    func rules(in regionSign: String) -> [RegionAlertRule] {
        alertRules.filter { $0.regionSign == regionSign }
    }

    func rule(regionSign: String, gpuName: String) -> RegionAlertRule? {
        alertRules.first { $0.regionSign == regionSign && $0.gpuName == gpuName }
    }

    func addRule(regionSign: String, regionName: String, gpuName: String, minCards: Int = 1) {
        let name = gpuName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sign = canonicalSign(for: regionSign)
        guard !name.isEmpty, !sign.isEmpty, rule(regionSign: sign, gpuName: name) == nil else { return }
        alertRules.append(RegionAlertRule(
            regionSign: sign,
            regionName: groupName(for: sign) ?? regionName,
            gpuName: name,
            minCards: minCards
        ))
        persistRules()
    }

    func removeRule(id: String) {
        alertRules.removeAll { $0.id == id }
        armed[id] = nil
        ruleHits[id] = nil
        ruleScanStatus[id] = nil
        persistRules()
    }

    /// Arms or disarms the one-shot auto-clone of `sourceID` for a rule.
    func setAutoClone(id: String, enabled: Bool, sourceID: String?) {
        guard let index = alertRules.firstIndex(where: { $0.id == id }) else { return }
        alertRules[index].autoClone = enabled && sourceID != nil
        alertRules[index].cloneSourceID = enabled ? sourceID : nil
        alertRules[index].cloneAuthorizationID = UUID().uuidString
        if enabled, let sourceID {
            // Cards already free when the user arms it are cloned onto at the next scan, not only new ones.
            armed[id] = true
            cloneRetriesLeft[sourceID] = Self.maxCloneAttempts
        }
        persistRules()
    }

    func isCloneAuthorized(_ rule: RegionAlertRule) -> Bool {
        !watchPaused && alertRules.contains {
            $0.id == rule.id && $0.cloneSourceID == rule.cloneSourceID
                && $0.cloneAuthorizationID == rule.cloneAuthorizationID
        }
    }

    func hasAutoClone(sourceID: String) -> Bool {
        alertRules.contains { $0.autoClone && $0.cloneSourceID == sourceID }
    }

    func disableAutoClones(sourceID: String) {
        for rule in alertRules where rule.cloneSourceID == sourceID {
            setAutoClone(id: rule.id, enabled: false, sourceID: nil)
        }
        spentCloneRules[sourceID] = nil
    }

    /// Only the exact consent consumed by this attempt may be restored. A newer user choice always wins.
    @discardableResult
    func restoreAutoClone(for rule: RegionAlertRule) -> Int? {
        guard isCloneAuthorized(rule), let sourceID = rule.cloneSourceID,
              let left = cloneRetriesLeft[sourceID], left > 0,
              let spent = spentCloneRules[sourceID],
              spent.contains(where: { $0.cloneAuthorizationID == rule.cloneAuthorizationID }) else {
            return nil
        }
        for original in spent {
            guard let index = alertRules.firstIndex(where: {
                $0.id == original.id && $0.cloneAuthorizationID == original.cloneAuthorizationID
                    && $0.cloneSourceID == sourceID
            }) else { continue }
            alertRules[index].autoClone = true
        }
        spentCloneRules[sourceID] = nil
        persistRules()
        return left
    }

    func setMinCards(id: String, _ cards: Int) {
        guard let index = alertRules.firstIndex(where: { $0.id == id }) else { return }
        alertRules[index].minCards = cards
        alertRules[index].cloneAuthorizationID = UUID().uuidString
        armed[id] = true
        ruleHits[id] = nil
        ruleScanStatus[id] = nil
        persistRules()
    }

    /// Machines of the rule's model that could host a `minCards` instance right now.
    func matches(for rule: RegionAlertRule) -> [MarketMachine] {
        if let hits = ruleHits[rule.id] { return hits }
        return (regionSnapshots[rule.regionSign]?.machines ?? [])
            .filter { $0.isRentable && $0.gpuName == rule.gpuName && $0.gpuIdle >= rule.minCards }
            .sorted { ($0.gpuIdle, $1.id) > ($1.gpuIdle, $0.id) }
    }

    private func persistRules() {
        guard !isDemo, let data = try? JSONEncoder().encode(alertRules) else { return }
        defaults.set(data, forKey: Self.rulesKey)
        defaults.set(cloneRetriesLeft, forKey: Self.attemptsKey)
    }

    /// Stores a fresh region scan and runs the alert rules against it.
    func ingest(regionSign: String, machines: [MarketMachine], at date: Date = Date()) {
        regionSnapshots[regionSign] = RegionSnapshot(regionSign: regionSign, machines: machines, fetchedAt: date)
        regionErrors[regionSign] = nil
        if !watcherRunning {
            evaluateRules(in: regionSign)
        }
    }

    /// Where fired alerts go. `startWatching` installs the real one; tests install a recorder.
    func setAlertHandler(_ handler: @escaping (_ title: String, _ body: String, _ id: String) -> Void) {
        onAlert = handler
    }

    /// Where a matching rule's clone goes. Tests install a recorder; the app routes it to the account monitor.
    func setCloneHandler(_ handler: @escaping (_ rule: RegionAlertRule, _ hits: [MarketMachine]) -> Bool) {
        onClone = handler
    }

    /// Fires each rule of the region whose model just went from "no cards" to "has cards".
    private func evaluateRules(in regionSign: String) {
        for rule in rules(in: regionSign) {
            let hits = (regionSnapshots[rule.regionSign]?.machines ?? [])
                .filter { $0.isRentable && $0.gpuName == rule.gpuName && $0.gpuIdle >= rule.minCards }
                .sorted { ($0.gpuIdle, $1.id) > ($1.gpuIdle, $0.id) }
            apply(rule, hits: hits)
        }
    }

    private func markScanFailed(_ rule: RegionAlertRule, _ error: Error) {
        let previous = ruleScanStatus[rule.id]
        ruleScanStatus[rule.id] = RuleScanStatus(lastSuccess: previous?.lastSuccess, lastError: error.localizedDescription)
    }

    /// Records what satisfies the rule and alerts when that goes from nothing to something.
    private func apply(_ rule: RegionAlertRule, hits: [MarketMachine], at date: Date = Date()) {
        guard !watchPaused else { return }
        ruleHits[rule.id] = hits
        ruleScanStatus[rule.id] = RuleScanStatus(lastSuccess: date, lastError: nil)
        if hits.isEmpty {
            armed[rule.id] = true
            return
        }
        if armed[rule.id] ?? true {
            armed[rule.id] = false
            let idle = hits.reduce(0) { $0 + $1.gpuIdle }
            let lines = hits.prefix(3).map { machine in
                "\(machine.alias) \(machine.gpuIdle)/\(machine.gpuNumber)"
                    + (machine.hourlyPrice.map { String(format: " ¥%.2f/h", $0) } ?? "")
            }
            let more = hits.count > 3 ? " 等 \(hits.count) 台" : ""
            onAlert?(
                "\(rule.regionName) 有空闲 \(rule.gpuName)",
                "\(hits.count) 台机器共 \(idle) 张空闲（单机至少 \(rule.minCards) 张）：\(lines.joined(separator: "，"))\(more)",
                "hunao.region.\(rule.id)"
            )
        }

        // One-shot: the opt-in is spent as soon as a clone was really started, so a billed instance is never
        // ordered twice from a single arming.
        // Every other armed rule cloning the same source is spent with it, so seven armed models can never
        // order seven copies of one instance.
        // Read the rule afresh: a clone started for another model a moment ago may have spent this one's opt-in.
        if let live = alertRules.first(where: { $0.id == rule.id }), live.autoClone,
           let source = live.cloneSourceID,
           (cloneRetriesLeft[source] ?? Self.maxCloneAttempts) > 0,
           onClone?(live, hits) == true {
            let spent = alertRules.filter { $0.autoClone && $0.cloneSourceID == live.cloneSourceID }
            spentCloneRules[source] = spent
            cloneRetriesLeft[source] = (cloneRetriesLeft[source] ?? Self.maxCloneAttempts) - 1
            for index in alertRules.indices where alertRules[index].cloneSourceID == source {
                // Keep the consent identity so a pending task can detect a later manual cancellation.
                alertRules[index].autoClone = false
            }
            persistRules()
        }
    }

    /// Clone queries use their source account and payg, and do not wait for the aggregate count query.
    func watchRegion(
        account: AutoDLAccount, regionSign: String, chargeType: String,
        accountForSource: @escaping @MainActor (String) -> AutoDLAccount?
    ) async {
        let version = watchVersion
        let api = AutoDLAPI(token: account.token, isSubAccount: account.isSubAccount, session: apiSession)
        let signs = groupSigns(for: regionSign)
        let ordered = rules(in: regionSign).sorted { $0.autoClone && !$1.autoClone }
        let typesTask = Task { try await api.fetchGPUTypes(regionSigns: signs) }
        await withTaskGroup(of: (RegionAlertRule, Result<[MarketMachine], Error>).self) { group in
            for rule in ordered {
                let owner = rule.autoClone ? rule.cloneSourceID.flatMap(accountForSource) : account
                guard let owner, !owner.token.isEmpty else {
                    markScanFailed(rule, AutoDLError.unauthorized)
                    continue
                }
                let ruleAPI = AutoDLAPI(token: owner.token, isSubAccount: owner.isSubAccount, session: apiSession)
                group.addTask {
                    do {
                        if !rule.autoClone {
                            let types = try await typesTask.value
                            if (types.first { $0.name == rule.gpuName }?.idle ?? 0) < rule.minCards {
                                return (rule, .success([]))
                            }
                        }
                        let machines = try await ruleAPI.fetchMarketMachines(
                            gpuName: rule.gpuName, chargeType: rule.autoClone ? "payg" : chargeType, regionSigns: signs
                        )
                        return (rule, .success(machines))
                    } catch {
                        return (rule, .failure(error))
                    }
                }
            }
            for await (rule, result) in group {
                guard !watchPaused, version == watchVersion,
                      let current = alertRules.first(where: {
                          $0.id == rule.id && $0.cloneAuthorizationID == rule.cloneAuthorizationID
                      }) else { continue }
                switch result {
                case .success(let machines):
                    let hits = machines
                        .filter {
                            $0.isRentable && $0.gpuIdle >= current.minCards && $0.gpuName == current.gpuName
                                && signs.contains($0.regionSign)
                        }
                        .sorted { ($0.gpuIdle, $1.id) > ($1.gpuIdle, $0.id) }
                    apply(current, hits: hits)
                case .failure(let error):
                    markScanFailed(rule, error)
                }
            }
        }
        if let types = try? await typesTask.value, version == watchVersion {
            gpuTypesByRegion[regionSign] = types
            gpuTypesFetchedAt[regionSign] = Date()
        }
    }

    /// Background scan of the regions that have rules, independent of which page is open.
    func startWatching(
        account: @escaping @MainActor () -> AutoDLAccount?,
        chargeType: @escaping @MainActor () -> String,
        accountForSource: @escaping @MainActor (String) -> AutoDLAccount?,
        onAlert: @escaping (_ title: String, _ body: String, _ id: String) -> Void
    ) {
        guard watchTask == nil, !isDemo else { return }
        self.onAlert = onAlert
        watcherRunning = true
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.watchPaused {
                    await self.loadCatalogIfNeeded(account: account())
                    let signs = Set(self.alertRules.map(\.regionSign))
                    for sign in Array(self.regionWatchTasks.keys) where !signs.contains(sign) {
                        self.regionWatchTasks.removeValue(forKey: sign)?.cancel()
                    }
                    for sign in signs where self.regionWatchTasks[sign] == nil {
                        self.regionWatchTasks[sign] = Task { [weak self] in
                            var lastScan = Date.distantPast
                            var failures = 0
                            while !Task.isCancelled {
                                guard let self else { return }
                                let rules = self.rules(in: sign)
                                let fast = rules.contains(where: \.autoClone)
                                let fallback = account() ?? rules.compactMap { $0.cloneSourceID.flatMap(accountForSource) }.first
                                if !self.watchPaused, let fallback,
                                   fast || Date().timeIntervalSince(lastScan) >= Self.idleScanSeconds {
                                    lastScan = Date()
                                    await self.watchRegion(
                                        account: fallback, regionSign: sign, chargeType: chargeType(),
                                        accountForSource: accountForSource
                                    )
                                    let failed = self.rules(in: sign).contains { self.ruleScanStatus[$0.id]?.lastError != nil }
                                    failures = failed ? min(failures + 1, 4) : 0
                                }
                                // Each region owns its delay: a slow/failing region cannot hold up another.
                                try? await Task.sleep(nanoseconds: Self.fastScanNanos << UInt64(failures))
                            }
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: Self.fastScanNanos)
            }
        }
    }

    // MARK: Demo

    private static func demoSnapshot() -> MarketSnapshot {
        func machines(_ gpu: String, _ region: String, _ sign: String, _ price: Double, _ idles: [Int], of total: Int = 8) -> [MarketMachine] {
            idles.enumerated().map { index, idle in
                MarketMachine(
                    id: "\(sign)-\(gpu)-\(index)",
                    alias: String(format: "%@%02d机", String(sign.prefix(1)).uppercased(), index + 1),
                    gpuName: gpu,
                    regionName: region,
                    regionSign: sign,
                    gpuNumber: total,
                    gpuIdle: idle,
                    hourlyPrice: price
                )
            }
        }
        return MarketSnapshot(
            rows: [
                MarketRow(
                    gpuName: "RTX 4090",
                    machines: machines("RTX 4090", "北京B区", "beijing-b", 2.28, [2, 1, 1])
                        + machines("RTX 4090", "西北B区", "west-B", 2.08, [6, 4, 3, 1])
                        + machines("RTX 4090", "重庆A区", "cq-A1", 2.18, [1]),
                    error: nil
                ),
                MarketRow(
                    gpuName: "RTX 5090",
                    machines: machines("RTX 5090", "西北B区", "west-B", 3.58, [1, 1])
                        + machines("RTX 5090", "内蒙A区", "neimeng-a", 3.68, [2]),
                    error: nil
                ),
                MarketRow(
                    gpuName: "A100-SXM4-80GB",
                    machines: machines("A100-SXM4-80GB", "内蒙A区", "neimeng-a", 7.98, [3, 1]),
                    error: nil
                ),
                MarketRow(gpuName: "RTX 3090", machines: [], error: nil)
            ],
            fetchedAt: Date()
        )
    }

    private static func demoRegions() -> [String: RegionSnapshot] {
        func region(_ sign: String, _ name: String, _ entries: [(String, String, Int, Int, Double)]) -> RegionSnapshot {
            // (machine id, model, idle, total, price)
            RegionSnapshot(
                regionSign: sign,
                machines: entries.map { id, model, idle, total, price in
                    MarketMachine(
                        id: id, alias: id.hasPrefix("seetacloud") ? "本机 \(id.suffix(2))" : "\(sign.prefix(2).uppercased())-\(id.suffix(3))",
                        gpuName: model, regionName: name, regionSign: sign,
                        gpuNumber: total, gpuIdle: idle, hourlyPrice: price
                    )
                },
                fetchedAt: Date()
            )
        }
        return [
            "beijing-b": region("beijing-b", "北京B区", [
                ("seetacloud-4090-07", "RTX 4090", 2, 8, 2.28),
                ("bj-4090-112", "RTX 4090", 1, 8, 2.28),
                ("bj-4090-118", "RTX 4090", 1, 8, 2.28),
                ("bj-5090-021", "RTX 5090", 3, 8, 3.58),
                ("bj-5090-024", "RTX 5090", 1, 8, 3.58),
                ("bj-v48-003", "vGPU-48GB", 4, 8, 1.78),
                ("bj-3080-210", "RTX 3080 Ti", 6, 8, 0.98)
            ]),
            "neimeng-a": region("neimeng-a", "内蒙A区", [
                ("bj-a100-9", "A100-SXM4-80GB", 3, 8, 7.98),
                ("nm-4090-044", "RTX 4090", 5, 8, 2.18),
                ("nm-4090-051", "RTX 4090", 2, 8, 2.18),
                ("nm-5090-007", "RTX 5090", 2, 8, 3.68)
            ]),
            "shanghai-a": region("shanghai-a", "上海A区", [
                ("sh-3090-310", "RTX 3090", 2, 8, 1.58),
                ("sh-3090-318", "RTX 3090", 1, 8, 1.58),
                ("sh-4090-071", "RTX 4090", 1, 8, 2.28)
            ])
        ]
    }
}
