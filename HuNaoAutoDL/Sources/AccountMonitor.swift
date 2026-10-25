import Foundation
import SwiftUI

/// The monitored instance dropped out of the instance list. Automation stays paused until a target is chosen again.
struct LostTarget: Equatable {
    let id: String
    let name: String
}

/// A no-card boot whose real `start_mode` has not been read back yet.
private struct PendingModeCheck {
    let name: String
    let deadline: Date
    var announcedUnconfirmed = false
}

/// Written before the paid POST. A lost response must survive relaunch without authorizing another order.
struct PendingCloneOrder: Codable, Identifiable {
    var id = UUID().uuidString
    let sourceID: String
    let sourceName: String
    let regionSign: String
    let machineID: String
    let expansion: Int64
    var uuid: String?
}

/// One signed-in AutoDL account. It polls its own instances, balance and target-host GPUs and runs
/// auto-start and alerts whether or not it is the account currently shown in the window.
@MainActor
final class AccountMonitor: ObservableObject, Identifiable {
    @Published private(set) var account: AutoDLAccount
    @Published private(set) var instances: [AutoDLInstance] = []
    @Published private(set) var selectedInstanceID: String?
    @Published private(set) var stock: GPUStock?
    @Published private(set) var balance: AccountBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var billing: BillingSnapshot?
    @Published private(set) var billingError: String?
    @Published private(set) var isBillingLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var activity: [ActivityEvent] = []
    @Published private(set) var actionInstanceID: String?
    @Published private(set) var isAutoStarting = false
    /// Instances with a power request in flight or awaiting confirmation, whether started by hand or automatically.
    @Published private(set) var busyInstanceIDs: Set<String> = []
    @Published private(set) var lostTarget: LostTarget?
    @Published private(set) var autoStartEnabled: Bool
    @Published private(set) var signedInAt: Date?
    /// Set when AutoDL rejects the token. The account stays in the list so it can be signed in again.
    @Published private(set) var authFailure: String?
    @Published private(set) var pendingCloneOrders: [String: PendingCloneOrder] = [:]
    @Published private(set) var preparingCloneSourceID: String?
    @Published private(set) var cloneInFlight = false

    nonisolated let id: String

    /// Instance IDs seen on this account, kept after a sign-out so a new login can be matched to it.
    private(set) var knownInstanceIDs: Set<String> = []

    private weak var app: AppModel?
    private let defaults: UserDefaults
    private let apiSession: URLSession?
    private let marketFallback: MarketStore?
    private var cloneMarket: MarketStore? { app?.market ?? marketFallback }
    private var instancesFetchedAt: Date?
    private var monitoringTask: Task<Void, Never>?
    /// Bumped whenever the session changes (sign-in, re-login with the same token, expiry, removal). Every async path
    /// captures it up front and drops its result, errors included, if it no longer matches.
    private var sessionGeneration = 0
    /// Bumped whenever the monitored target changes, so a stock reading for the old target is never applied to the new one.
    private var targetVersion = 0
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh = false
    private var autoSuppressedUntil: [String: Date] = [:]
    private var pendingModeChecks: [String: PendingModeCheck] = [:]
    private var isStopped = false
    /// Pauses between the refreshes that follow a no-card boot, and how long an unread `start_mode` is waited for
    /// (nil: the longer of 90 s and three poll intervals). Overridable so tests need not wait out the real schedule.
    var noCardCheckSchedule: [UInt64] = [3_000_000_000, 8_000_000_000, 20_000_000_000]
    var noCardCheckWindow: TimeInterval?
    private var gpuWasAvailable = false
    private var didNotifyForAvailability = false
    private var didNotifyForLowBalance = false
    private var lastAutoAttemptAt: Date?
    private var autoStartingID: String?
    private var consecutiveErrors = 0

    private var selectedInstanceKey: String { Self.selectedInstanceKey(account.id) }
    private var autoStartKey: String { Self.autoStartKey(account.id) }

    private static func selectedInstanceKey(_ id: String) -> String { "hunao.selectedInstanceUUID.\(id)" }
    private static func autoStartKey(_ id: String) -> String { "hunao.autoStartEnabled.\(id)" }

    init(
        account: AutoDLAccount,
        app: AppModel?,
        inheritLegacySettings: Bool = false,
        defaults: UserDefaults = .standard,
        session: URLSession? = nil,
        market: MarketStore? = nil
    ) {
        self.defaults = defaults
        self.apiSession = session
        self.marketFallback = market
        let autoStartKey = Self.autoStartKey(account.id)
        let selectedKey = Self.selectedInstanceKey(account.id)
        if inheritLegacySettings {
            // The first account after upgrading keeps the old single-account choices.
            if defaults.object(forKey: autoStartKey) == nil,
               defaults.object(forKey: AppModel.legacyAutoStartKey) != nil {
                defaults.set(defaults.bool(forKey: AppModel.legacyAutoStartKey), forKey: autoStartKey)
            }
            if defaults.string(forKey: selectedKey) == nil,
               let legacy = defaults.string(forKey: AppModel.legacySelectedInstanceKey) {
                defaults.set(legacy, forKey: selectedKey)
            }
            defaults.removeObject(forKey: AppModel.legacyAutoStartKey)
            defaults.removeObject(forKey: AppModel.legacySelectedInstanceKey)
        }
        self.id = account.id
        self.account = account
        self.app = app
        autoStartEnabled = defaults.bool(forKey: autoStartKey)
        selectedInstanceID = defaults.string(forKey: selectedKey)
        if let data = defaults.data(forKey: pendingCloneKey),
           let orders = try? JSONDecoder().decode([String: PendingCloneOrder].self, from: data) {
            pendingCloneOrders = orders
            if !orders.isEmpty {
                addActivity(kind: .warning, title: "有克隆订单待核对", detail: "之前的克隆尚未确认，不会自动重复下单；请到区域页核对")
            }
        }
    }

    // MARK: - Derived state

    private var pollInterval: TimeInterval { app?.pollInterval ?? 15 }
    /// Stands in for the app-wide switch when no `AppModel` owns this monitor (tests).
    var monitoringPausedFallback = false
    private var isPaused: Bool { app?.monitoringPaused ?? monitoringPausedFallback }
    private var lowBalanceThreshold: Double { app?.lowBalanceThreshold ?? 20 }

    var isLowBalance: Bool {
        guard let balance else { return false }
        return balance.available < lowBalanceThreshold
    }

    var balanceLabel: String {
        balance?.formattedAvailable ?? "—"
    }

    var selectedInstance: AutoDLInstance? {
        guard let selectedInstanceID else { return nil }
        return instances.first { $0.id == selectedInstanceID }
    }

    var runningCount: Int {
        instances.filter { $0.state == .running }.count
    }

    /// Running instances that were booted without a GPU.
    var noCardCount: Int {
        instances.filter(\.isNoCardMode).count
    }

    func isBusy(_ instanceID: String) -> Bool {
        busyInstanceIDs.contains(instanceID)
    }

    var autoStartSubtitle: String {
        if autoStartEnabled {
            if isPaused { return "监控已暂停，自动开机不会触发" }
            if lostTarget != nil, selectedInstance == nil {
                return "监控目标已消失，自动开机已暂停"
            }
            if selectedInstance?.isNoCardMode == true {
                return "无卡运行中，关机后才会自动抢卡开机"
            }
            return selectedInstance?.state == .stopped
                ? "守候空闲卡，出现即开机"
                : "等待实例关机后接管"
        }
        return "只提醒，不自动开机"
    }

    var availabilityHeadline: String {
        if isPaused, selectedInstance != nil { return "监控已暂停" }
        if selectedInstance == nil, lostTarget != nil { return "监控目标已消失" }
        guard let instance = selectedInstance else { return "等待选择实例" }
        guard let stock else {
            return lastError == nil ? "正在读取显卡状态" : "显卡状态暂不可用"
        }
        if instance.isNoCardMode {
            return "无卡模式运行中 · 未占用 GPU"
        }
        if instance.state == .running {
            return "实例正在使用 GPU"
        }
        if instance.state == .starting {
            return "实例正在启动"
        }
        if instance.state == .stopping {
            return "实例正在关机"
        }
        if stock.isAvailable {
            return "发现空闲显卡"
        }
        if stock.incomplete {
            return "库存查询不完整"
        }
        if !stock.machineFound {
            return "目标主机暂未放出空卡"
        }
        return "正在等待空闲显卡"
    }

    var availabilityCaption: String {
        if isPaused, selectedInstance != nil { return "不再后台轮询、提醒或自动开机，点“恢复监控”继续" }
        if selectedInstance == nil, let lostTarget {
            return "「\(lostTarget.name)」不在实例列表中，已暂停自动开机，请重新选择监控目标"
        }
        guard let instance = selectedInstance else {
            return "先在 AutoDL 创建一个实例"
        }
        guard let stock else {
            return "刷新间隔 \(Int(pollInterval)) 秒"
        }
        if instance.isNoCardMode {
            return stock.isAvailable
                ? "本机有 \(stock.idleGPUs) 张空卡 · 关机后可用 GPU 重新开机"
                : "本机暂无空卡 · 无卡运行不占用显卡"
        }
        if stock.isAvailable {
            return autoStartEnabled ? "自动开机已就绪" : "自动开机已关闭，仅发送提醒"
        }
        if stock.incomplete {
            return "目标主机不在已查询的结果页内，无法判断是否有空卡"
        }
        if !stock.machineFound {
            return "目标主机 \(instance.machineID.isEmpty ? "ID 缺失" : instance.machineID) 暂无空闲卡"
        }
        return "已监测目标主机 · \(Int(pollInterval)) 秒刷新"
    }

    // MARK: - Lifecycle

    /// Connects a token saved from an earlier run.
    func bootstrap() async {
        let generation = sessionGeneration
        let token = account.token
        do {
            let connection = try await AutoDLAPI.connect(
                token: token,
                preferSubAccount: account.isSubAccount,
                session: apiSession
            )
            guard isCurrent(generation) else { return }
            if account.isSubAccount != connection.api.isSubAccount {
                account.isSubAccount = connection.api.isSubAccount
                app?.persistAccounts()
            }
            signedInAt = Date()
            applyInstances(connection.instances)
            addActivity(
                kind: .success,
                title: "已自动连接 AutoDL",
                detail: connection.instances.isEmpty ? "账号下暂无实例" : "正在守护 \(connection.instances.count) 个实例"
            )
            startMonitoring(immediately: true)
        } catch let error as AutoDLError where error.isAuthFailure {
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            guard isCurrent(generation) else { return }
            signedInAt = Date()
            lastError = error.localizedDescription
            addActivity(kind: .error, title: "首次同步失败", detail: error.localizedDescription)
            startMonitoring(immediately: true)
        }
    }

    /// Starts monitoring right after a successful sign-in, reusing the instance list it fetched.
    func activate(instances list: [AutoDLInstance], saved: Bool) {
        isStopped = false
        beginSession()
        signedInAt = Date()
        lastError = nil
        applyInstances(list)
        addActivity(
            kind: .success,
            title: "登录成功",
            detail: saved ? "Token 已保存到本机受保护文件" : "Token 已在本次运行中生效"
        )
        if list.isEmpty {
            addActivity(kind: .info, title: "账号下暂无实例", detail: "请先在 AutoDL 创建实例")
        }
        startMonitoring(immediately: true)
    }

    func updateCredentials(token: String, isSubAccount: Bool, instances list: [AutoDLInstance], saved: Bool) {
        account.token = token
        account.isSubAccount = isSubAccount
        authFailure = nil
        activate(instances: list, saved: saved)
    }

    func rename(_ name: String) {
        account.name = name
    }

    /// Stops polling for good, e.g. when the account is removed.
    func stop(forgetSettings: Bool) {
        isStopped = true
        beginSession()
        monitoringTask?.cancel()
        monitoringTask = nil
        if forgetSettings {
            for sourceID in knownInstanceIDs { cloneMarket?.disableAutoClones(sourceID: sourceID) }
            defaults.removeObject(forKey: selectedInstanceKey)
            defaults.removeObject(forKey: autoStartKey)
        }
    }

    func applyDemo(
        instances: [AutoDLInstance],
        selectedInstanceID: String?,
        stock: GPUStock?,
        balance: AccountBalance,
        billing: BillingSnapshot?,
        activity: [ActivityEvent],
        autoStart: Bool
    ) {
        isStopped = true
        signedInAt = Date().addingTimeInterval(-86_400 * 3)
        self.instances = instances
        knownInstanceIDs = Set(instances.map(\.id))
        self.selectedInstanceID = selectedInstanceID
        self.stock = stock
        self.balance = balance
        self.billing = billing
        self.activity = activity
        lastUpdated = Date()
        autoStartEnabled = autoStart
    }

    /// Starts a new session: results of requests begun under the previous one are discarded.
    private func beginSession() {
        sessionGeneration += 1
        resetOperations()
    }

    private func resetOperations() {
        cloneCancellationVersion += 1
        cloneImages = [:]
        refreshTask = nil
        pendingRefresh = false
        isRefreshing = false
        isBillingLoading = false
        isAutoStarting = false
        actionInstanceID = nil
        busyInstanceIDs = []
        autoSuppressedUntil = [:]
        pendingModeChecks = [:]
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !isStopped && authFailure == nil && generation == sessionGeneration
    }

    private func makeAPI(token: String) -> AutoDLAPI {
        AutoDLAPI(token: token, isSubAccount: account.isSubAccount, session: apiSession)
    }

    /// An auth failure only counts for the session whose request produced it; a late failure from an older
    /// request must not sign out a session the user has since renewed.
    private func expireIfCurrent(_ generation: Int, reason: String) {
        guard isCurrent(generation) else { return }
        expire(reason: reason)
    }

    private func expire(reason: String) {
        monitoringTask?.cancel()
        monitoringTask = nil
        authFailure = reason
        beginSession()
        instances = []
        stock = nil
        balance = nil
        balanceError = nil
        billing = nil
        billingError = nil
        lastUpdated = nil
        didNotifyForLowBalance = false
        resetAvailabilityEpisode()
        addActivity(kind: .error, title: "登录已失效", detail: reason)
        app?.accountDidExpire(self)
    }

    // MARK: - Monitoring

    func restartMonitoring() {
        guard monitoringTask != nil else { return }
        startMonitoring(immediately: false)
    }

    private func startMonitoring(immediately: Bool) {
        guard !isStopped else { return }
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self else { return }
            if immediately {
                await self.refreshAll()
            }
            while !Task.isCancelled {
                let cloning = self.instances.contains { self.cloneMarket?.hasAutoClone(sourceID: $0.id) == true }
                let interval = max(min(self.pollInterval, cloning ? 10 : self.pollInterval), 1)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                if self.isPaused { continue }
                await self.refreshAll()
            }
        }
    }

    func refreshNow() {
        Task { await refreshAll(userInitiated: true) }
    }

    /// One refresh loop at a time. A call made while one is running queues exactly one more pass and waits for the
    /// whole loop, so a target switch or a post-power-action check always ends up reading fresh data.
    private func refreshAll(userInitiated: Bool = false) async {
        let generation = sessionGeneration
        guard isCurrent(generation), !account.token.isEmpty else { return }
        if let refreshTask {
            pendingRefresh = true
            await refreshTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            var first = userInitiated
            repeat {
                self.pendingRefresh = false
                await self.refreshOnce(generation: generation, userInitiated: first)
                first = false
            } while self.pendingRefresh && self.isCurrent(generation)
            if generation == self.sessionGeneration {
                self.refreshTask = nil
            }
        }
        refreshTask = task
        await task.value
    }

    private func refreshOnce(generation: Int, userInitiated: Bool) async {
        let token = account.token
        // Background polls stay silent; only a user-initiated refresh shows the spinner.
        if userInitiated { isRefreshing = true }
        defer {
            if generation == sessionGeneration, isRefreshing { isRefreshing = false }
        }

        let api = makeAPI(token: token)
        do {
            let list = try await api.fetchInstances()
            guard isCurrent(generation) else { return }

            applyInstances(list)
            evaluatePendingModeChecks()
            setIfChanged(\.lastError, nil)
            consecutiveErrors = 0

            do {
                let latestBalance = try await api.fetchBalance()
                guard isCurrent(generation) else { return }
                setIfChanged(\.balance, latestBalance)
                setIfChanged(\.balanceError, nil)
                evaluateBalanceAlert()
            } catch let error as AutoDLError where error.isAuthFailure {
                expireIfCurrent(generation, reason: error.localizedDescription)
                return
            } catch {
                guard isCurrent(generation) else { return }
                setIfChanged(\.balanceError, error.localizedDescription)
            }

            guard let instance = selectedInstance else {
                setIfChanged(\.stock, nil)
                lastUpdated = Date()
                return
            }

            let version = targetVersion
            do {
                let latestStock = try await api.fetchGPUStock(for: instance)
                guard isCurrent(generation), version == targetVersion,
                      let current = selectedInstance, latestStock.matches(current)
                else { return }
                setIfChanged(\.stock, latestStock)
                lastUpdated = Date()
                evaluateStock(latestStock, for: current)
            } catch let error as AutoDLError where error.isAuthFailure {
                expireIfCurrent(generation, reason: error.localizedDescription)
                return
            } catch {
                guard isCurrent(generation), version == targetVersion else { return }
                lastError = "显卡状态同步失败：\(error.localizedDescription)"
                stock = nil
                lastUpdated = Date()
                registerFailure(message: lastError ?? "")
            }
        } catch let error as AutoDLError where error.isAuthFailure {
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            guard isCurrent(generation) else { return }
            lastError = error.localizedDescription
            registerFailure(message: error.localizedDescription)
            if userInitiated {
                app?.presentToast(kind: .error, title: "同步失败", message: error.localizedDescription)
            }
        }
    }

    private func registerFailure(message: String) {
        consecutiveErrors += 1
        if consecutiveErrors == 1 || consecutiveErrors % 10 == 0 {
            addActivity(kind: .error, title: "监控同步异常", detail: message)
        }
    }

    // Every @Published write redraws the visible page, so skip writes that change nothing.
    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AccountMonitor, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: - Billing

    func refreshBilling(force: Bool = false) {
        Task { await loadBilling(force: force) }
    }

    private func loadBilling(force: Bool) async {
        let generation = sessionGeneration
        let token = account.token
        guard isCurrent(generation), !token.isEmpty, !isBillingLoading else { return }
        if !force, let billing, Date().timeIntervalSince(billing.fetchedAt) < 120 { return }

        isBillingLoading = true
        defer {
            if generation == sessionGeneration { isBillingLoading = false }
        }

        let calendar = AppTime.calendar
        let end = Date()
        let start = calendar.date(
            byAdding: .day,
            value: -35,
            to: calendar.startOfDay(for: end)
        ) ?? end

        do {
            let records = try await makeAPI(token: token).fetchBills(from: start, to: end)
            guard isCurrent(generation) else { return }
            billing = BillingSnapshot(records: records, fetchedAt: Date())
            billingError = nil
        } catch let error as AutoDLError where error.isAuthFailure {
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            guard isCurrent(generation) else { return }
            billingError = error.localizedDescription
        }
    }

    // MARK: - Target instance

    private func applyInstances(_ list: [AutoDLInstance]) {
        instancesFetchedAt = Date()
        reconcileCloneOrders(list)
        let previousList = instances
        setIfChanged(\.instances, list)
        knownInstanceIDs.formUnion(list.map(\.id))
        let previousSelection = selectedInstanceID
        let stored = defaults.string(forKey: selectedInstanceKey)

        // Only the very first pick may fall back to the head of the list. Once a target exists and then goes
        // missing (released, or just absent from one response), keep it, pause automation and make the user choose
        // again; silently moving to another instance could power on something they never selected.
        let wanted = [stored, previousSelection].compactMap { $0 }
        let next = wanted.lazy.compactMap { id in list.first { $0.id == id } }.first
        let wasLost = lostTarget != nil

        if let next {
            setIfChanged(\.selectedInstanceID, next.id)
            setIfChanged(\.lostTarget, nil)
            if stored != next.id { defaults.set(next.id, forKey: selectedInstanceKey) }
            if wasLost {
                addActivity(kind: .info, title: "监控目标已恢复", detail: "\(next.name) 重新出现在实例列表中")
            }
        } else if let lostID = wanted.first {
            setIfChanged(\.selectedInstanceID, lostID)
            if !wasLost {
                let name = previousList.first { wanted.contains($0.id) }?.name ?? lostID
                lostTarget = LostTarget(id: lostID, name: name)
                let detail = "\(name) 不在实例列表中，已暂停自动开机，请重新选择监控目标"
                addActivity(kind: .warning, title: "监控目标已消失", detail: detail)
                app?.presentToast(kind: .warning, title: alertPrefix + "监控目标已消失", message: detail)
            }
        } else {
            let first = list.first
            setIfChanged(\.selectedInstanceID, first?.id)
            setIfChanged(\.lostTarget, nil)
            if let id = first?.id { defaults.set(id, forKey: selectedInstanceKey) }
        }

        let effective = selectedInstance?.id
        let previousEffective = previousList.contains { $0.id == previousSelection } ? previousSelection : nil
        if effective != previousEffective {
            resetTargetState()
        }
    }

    private func resetTargetState() {
        targetVersion += 1
        stock = nil
        lastUpdated = nil
        resetAvailabilityEpisode()
        lastAutoAttemptAt = nil
    }

    func selectInstance(_ id: String) {
        guard selectedInstanceID != id || lostTarget != nil,
              instances.contains(where: { $0.id == id })
        else { return }
        selectedInstanceID = id
        lostTarget = nil
        defaults.set(id, forKey: selectedInstanceKey)
        resetTargetState()
        lastError = nil
        if let instance = selectedInstance {
            addActivity(kind: .info, title: "已切换监控目标", detail: "\(instance.name) · \(instance.gpuName)")
        }
        Task { await refreshAll(userInitiated: true) }
    }

    private func resetAvailabilityEpisode() {
        gpuWasAvailable = false
        didNotifyForAvailability = false
    }

    private func evaluateStock(_ latestStock: GPUStock, for instance: AutoDLInstance) {
        guard !isPaused, latestStock.matches(instance) else { return }
        let available = latestStock.isAvailable
        let isPoweredOff = instance.state.isPoweredOff

        if available && !gpuWasAvailable {
            addActivity(
                kind: .warning,
                title: "发现空闲显卡",
                detail: "\(instance.machineID) · \(latestStock.idleGPUs) 张 \(instance.gpuName) 空闲"
            )
            if autoStartEnabled {
                addActivity(kind: .info, title: "自动开机已触发", detail: "正在尝试抢占空闲 GPU")
            }
        }

        gpuWasAvailable = available
        if !available {
            didNotifyForAvailability = false
            return
        }

        guard isPoweredOff else { return }

        if autoStartEnabled {
            Task { await attemptAutoPowerOn(instance: instance, stock: latestStock) }
        } else if !didNotifyForAvailability {
            didNotifyForAvailability = true
            notifyGPUAvailable(instance: instance, stock: latestStock)
        }
    }

    private func notifyGPUAvailable(instance: AutoDLInstance, stock: GPUStock) {
        let body = "\(instance.name) 所在主机有 \(stock.idleGPUs) 张 \(instance.gpuName) 空闲，自动开机已关闭。"
        addActivity(kind: .warning, title: "已发送空闲提醒", detail: body)
        alert(kind: .warning, title: "发现空闲 GPU", body: body, identifier: "hunao.gpu.available.\(instance.id)")
    }

    // MARK: - Automation

    func setAutoStart(_ enabled: Bool) {
        if enabled, let selectedInstanceID, hasPendingCloneOrder(sourceID: selectedInstanceID) {
            addActivity(kind: .warning, title: "自动开机未开启", detail: "该实例的克隆订单尚未确认，请先在区域页核对，避免两台同时计费")
            return
        }
        guard autoStartEnabled != enabled else { return }
        autoStartEnabled = enabled
        defaults.set(enabled, forKey: autoStartKey)

        if enabled {
            addActivity(kind: .info, title: "自动开机已开启", detail: "检测到空闲显卡后自动抢占")
            if let instance = selectedInstance,
               instance.state.isPoweredOff,
               let stock,
               stock.matches(instance),
               stock.isAvailable {
                Task { await attemptAutoPowerOn(instance: instance, stock: stock) }
            }
        } else {
            addActivity(kind: .info, title: "自动开机已关闭", detail: "之后仅在有卡空闲时提醒")
            if let instance = selectedInstance,
               instance.state.isPoweredOff,
               let stock,
               stock.isAvailable,
               !didNotifyForAvailability {
                didNotifyForAvailability = true
                notifyGPUAvailable(instance: instance, stock: stock)
            }
        }
    }

    func monitoringPauseChanged(_ paused: Bool) {
        if paused {
            cloneCancellationVersion += 1
            addActivity(kind: .info, title: "监控已暂停", detail: "不再后台轮询，也不会提醒或自动开机")
        } else {
            // A fresh episode: a card that is free right now is reported once on resume.
            resetAvailabilityEpisode()
            addActivity(kind: .info, title: "监控已恢复", detail: "重新开始轮询与提醒")
            Task { await refreshAll() }
        }
    }

    func lowBalanceThresholdChanged() {
        guard let balance else { return }
        if balance.available >= lowBalanceThreshold {
            didNotifyForLowBalance = false
        } else {
            evaluateBalanceAlert()
        }
    }

    private func evaluateBalanceAlert() {
        guard let balance, !isPaused else { return }
        guard balance.available < lowBalanceThreshold else {
            didNotifyForLowBalance = false
            return
        }
        guard !didNotifyForLowBalance else { return }
        didNotifyForLowBalance = true

        let title = "余额不足提醒"
        let voucherNote = balance.voucher > 0 ? "（含代金券 \(balance.formattedVoucher)）" : ""
        let body = "AutoDL 可用余额 \(balance.formattedAvailable)\(voucherNote)，已低于 \(AccountBalance.currency(lowBalanceThreshold))，请及时充值以免影响自动开机。"
        addActivity(kind: .warning, title: title, detail: body)
        alert(kind: .warning, title: title, body: body, identifier: "hunao.balance.low")
    }

    /// Marks an instance as having a power request outstanding. Held from sending the request until the follow-up
    /// refresh has had a chance to show the new status, so a second request cannot race the first.
    private func claimInstance(_ id: String, generation: Int) -> Bool {
        guard generation == sessionGeneration, !busyInstanceIDs.contains(id) else { return false }
        busyInstanceIDs.insert(id)
        return true
    }

    private func releaseInstance(_ id: String, generation: Int) {
        guard generation == sessionGeneration else { return }
        busyInstanceIDs.remove(id)
        if actionInstanceID == id { actionInstanceID = nil }
        if autoStartingID == id {
            autoStartingID = nil
            isAutoStarting = false
        }
    }

    private func confirmThenRelease(_ id: String, generation: Int, after delay: UInt64) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self else { return }
            if self.isCurrent(generation) {
                await self.refreshAll()
            }
            self.releaseInstance(id, generation: generation)
        }
    }

    private func attemptAutoPowerOn(instance: AutoDLInstance, stock: GPUStock) async {
        guard autoStartEnabled, !isPaused, !isStopped, authFailure == nil else { return }
        guard lostTarget == nil, let current = selectedInstance, current.id == instance.id else { return }
        guard current.state.isPoweredOff else { return }
        guard !hasPendingCloneOrder(sourceID: current.id), cloneMarket?.hasAutoClone(sourceID: current.id) != true else { return }
        guard stock.matches(current), stock.isAvailable else { return }
        if let until = autoSuppressedUntil[current.id], until > Date() { return }
        if let lastAutoAttemptAt, Date().timeIntervalSince(lastAutoAttemptAt) < 60 {
            return
        }

        let generation = sessionGeneration
        let token = account.token
        guard !token.isEmpty, claimInstance(current.id, generation: generation) else { return }
        isAutoStarting = true
        autoStartingID = current.id
        lastAutoAttemptAt = Date()

        var confirming = false
        defer {
            if !confirming { releaseInstance(current.id, generation: generation) }
        }

        do {
            try await makeAPI(token: token).powerOn(instanceUUID: current.id)
            guard generation == sessionGeneration else { return }
            let detail = "\(current.name) 正在启动，已抢占 \(stock.idleGPUs) 张空闲 \(current.gpuName)"
            addActivity(kind: .success, title: "自动开机成功", detail: detail)
            alert(kind: .success, title: "自动开机成功", body: detail, identifier: "hunao.autostart.success.\(current.id)")
            confirming = true
            confirmThenRelease(current.id, generation: generation, after: 2_500_000_000)
        } catch let error as AutoDLError where error.isAuthFailure {
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            guard generation == sessionGeneration else { return }
            let detail = error.localizedDescription
            addActivity(kind: .error, title: "自动开机失败", detail: detail)
            app?.presentToast(kind: .error, title: alertPrefix + "自动开机失败", message: detail)
        }
    }

    /// Set once a no-card boot was seen to really come up as `non_gpu`; until then every no-card boot asks first.
    static let noCardVerifiedKey = "hunao.noCardBootVerified"

    func powerOn(instance: AutoDLInstance, noCard: Bool = false) {
        Task { await performPowerAction(instance: instance, turnOn: true, noCard: noCard) }
    }

    func powerOff(instance: AutoDLInstance) {
        Task { await performPowerAction(instance: instance, turnOn: false) }
    }

    private func performPowerAction(instance: AutoDLInstance, turnOn: Bool, noCard: Bool = false) async {
        let generation = sessionGeneration
        let token = account.token
        guard isCurrent(generation), !token.isEmpty else { return }
        if turnOn, hasPendingCloneOrder(sourceID: instance.id) {
            addActivity(kind: .warning, title: "开机已阻止", detail: "克隆订单尚未确认，请先核对，避免源实例与克隆实例同时计费")
            return
        }
        guard claimInstance(instance.id, generation: generation) else {
            app?.presentToast(
                kind: .info,
                title: "实例正在处理指令",
                message: "\(instance.name) 上一条开关机请求尚未完成，请稍候。"
            )
            return
        }
        actionInstanceID = instance.id
        if turnOn { cloneMarket?.disableAutoClones(sourceID: instance.id) }
        // A hand-picked no-card boot must not be overtaken by an automatic GPU boot while the status catches up.
        if turnOn && noCard {
            autoSuppressedUntil[instance.id] = Date().addingTimeInterval(60)
        }

        var confirming = false
        defer {
            if !confirming { releaseInstance(instance.id, generation: generation) }
        }

        do {
            let api = makeAPI(token: token)
            if turnOn {
                try await api.powerOn(instanceUUID: instance.id, noCard: noCard)
            } else {
                try await api.powerOff(instanceUUID: instance.id)
            }
            guard generation == sessionGeneration else { return }
            addActivity(
                kind: .success,
                title: turnOn ? (noCard ? "无卡开机指令已发送" : "手动开机指令已发送") : "手动关机指令已发送",
                detail: instance.name
            )
            if turnOn && noCard {
                beginModeCheck(instanceID: instance.id, name: instance.name, generation: generation)
            }
            confirming = true
            confirmThenRelease(instance.id, generation: generation, after: 2_000_000_000)
        } catch let error as AutoDLError where error.isAuthFailure {
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            guard generation == sessionGeneration else { return }
            if turnOn && noCard { autoSuppressedUntil[instance.id] = nil }
            app?.presentToast(kind: .error, title: turnOn ? "开机失败" : "关机失败", message: error.localizedDescription)
            addActivity(kind: .error, title: turnOn ? "开机失败" : "关机失败", detail: error.localizedDescription)
        }
    }

    // MARK: - No-card start verification

    /// Starts watching what AutoDL actually did after a no-card request. The check lives until a refresh reads a
    /// definite `start_mode`, so slow boots and failed refreshes cannot end it silently: past the deadline the user
    /// is told it could not be confirmed, and a later `gpu` reading is still reported.
    private func beginModeCheck(instanceID: String, name: String, generation: Int) {
        let window = noCardCheckWindow ?? max(90, pollInterval * 3)
        let deadline = Date().addingTimeInterval(window)
        pendingModeChecks[instanceID] = PendingModeCheck(name: name, deadline: deadline)
        let schedule = noCardCheckSchedule
        Task { [weak self] in
            for wait in schedule {
                try? await Task.sleep(nanoseconds: wait)
                guard let self, self.isCurrent(generation), self.pendingModeChecks[instanceID] != nil else { return }
                await self.refreshAll()
            }
            let remaining = max(0, deadline.timeIntervalSinceNow) + 0.5
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, self.isCurrent(generation) else { return }
            self.evaluatePendingModeChecks()
        }
    }

    /// Advances every pending no-card check from the latest instance list.
    private func evaluatePendingModeChecks(now: Date = Date()) {
        for id in Array(pendingModeChecks.keys) {
            guard var check = pendingModeChecks[id] else { continue }
            let current = instances.first { $0.id == id }

            switch current?.noCardBootCheck ?? .pending {
            case .confirmed:
                defaults.set(true, forKey: Self.noCardVerifiedKey)
                addActivity(kind: .success, title: "无卡模式已确认", detail: "\(check.name) 以无卡模式运行，未占用 GPU")
                pendingModeChecks[id] = nil
            case .mismatch:
                let detail = "\(check.name) 已按 GPU 模式开机，会按 GPU 计费。无卡开机的参数可能不被 AutoDL 接受，建议立即关机，并到 AutoDL 网页确认。"
                addActivity(kind: .warning, title: "无卡开机未生效", detail: detail)
                app?.presentToast(kind: .warning, title: alertPrefix + "无卡开机未生效", message: detail)
                alert(kind: .warning, title: "无卡开机未生效", body: detail, identifier: "hunao.nocard.mismatch.\(id)")
                pendingModeChecks[id] = nil
            case .pending:
                if check.announcedUnconfirmed {
                    // Long past the deadline and the instance is down again: nothing left to watch.
                    if current == nil || current?.state.isPoweredOff == true { pendingModeChecks[id] = nil }
                } else if now >= check.deadline {
                    check.announcedUnconfirmed = true
                    pendingModeChecks[id] = check
                    let detail = "\(check.name) 在预期时间内没有读到明确的启动模式（可能仍在启动，或刷新失败）。请到 AutoDL 网页确认它是否按无卡计费；之后若发现按 GPU 模式运行会再提醒。"
                    addActivity(kind: .warning, title: "无法确认无卡模式", detail: detail)
                    app?.presentToast(kind: .warning, title: alertPrefix + "无法确认无卡模式", message: detail)
                }
            }
        }
    }

    // MARK: - Auto clone

    private var lastCloneAt: Date?
    private var cloneCancellationVersion = 0
    private var cloneImages: [String: (image: AutoDLAPI.CloneImage, source: AutoDLInstance, fetchedAt: Date)] = [:]
    private var failedCloneMachines: [String: Date] = [:]
    private var lastCloneSkip: (reason: String, at: Date)?
    private var cloneWarnings: [String: String] = [:]
    var cloneConfirmationWindow: TimeInterval = 60
    var cloneConfirmationNanos: UInt64 = 2_000_000_000
    private var pendingCloneKey: String { "hunao.pendingCloneOrders.\(id)" }
    private func cloneOrderSourceKey(_ sourceID: String) -> String { "hunao.cloneOrderBySource.\(sourceID)" }

    private func hasPendingCloneOrder(sourceID: String) -> Bool {
        pendingCloneOrders[sourceID] != nil || defaults.data(forKey: cloneOrderSourceKey(sourceID)) != nil
    }

    private func sameCloneConfiguration(_ a: AutoDLInstance, _ b: AutoDLInstance) -> Bool {
        a.id == b.id && a.regionSign == b.regionSign && a.gpuCount == b.gpuCount
            && a.expandDataDiskBytes == b.expandDataDiskBytes && a.privateImageUUID == b.privateImageUUID
            && a.reproductionUUID == b.reproductionUUID && a.cgApplicationUUID == b.cgApplicationUUID
            && a.reproductionID == b.reproductionID
    }

    func prefetchCloneImage(sourceID: String) {
        guard !account.token.isEmpty, let source = instances.first(where: { $0.id == sourceID }) else { return }
        let api = makeAPI(token: account.token)
        let generation = sessionGeneration
        Task { [weak self] in
            guard let image = try? await api.fetchCloneImage(instanceUUID: sourceID) else { return }
            guard let self, self.isCurrent(generation) else { return }
            self.cloneImages[sourceID] = (image, source, Date())
        }
    }

    func autoClone(rule: RegionAlertRule, hits: [MarketMachine]) -> Bool {
        guard !isPaused, !isStopped, authFailure == nil, !account.token.isEmpty,
              cloneMarket?.isCloneAuthorized(rule) == true else { return false }
        func skip(_ reason: String) -> Bool {
            if lastCloneSkip?.reason != reason || Date().timeIntervalSince(lastCloneSkip?.at ?? .distantPast) >= 30 {
                addActivity(kind: .warning, title: "自动克隆已跳过", detail: reason)
                lastCloneSkip = (reason, Date())
            }
            return false
        }
        guard let source = instances.first(where: { $0.id == rule.cloneSourceID }) else {
            return skip("找不到克隆源实例，请在区域页重新开启")
        }
        if hasPendingCloneOrder(sourceID: source.id) {
            if let data = defaults.data(forKey: cloneOrderSourceKey(source.id)),
               let order = try? JSONDecoder().decode(PendingCloneOrder.self, from: data) {
                pendingCloneOrders[source.id] = order
            }
            return skip("该源实例已有克隆订单待核对，不会重复下单；请在区域页核对")
        }
        guard source.state == .stopped || source.isNoCardMode else {
            return skip("源实例正在使用 GPU、切换状态或状态未知，暂不克隆")
        }
        guard let fetchedAt = instancesFetchedAt, Date().timeIntervalSince(fetchedAt) <= 30 else {
            return skip("源实例信息已过期，等待实例列表刷新后再检查容量")
        }
        guard source.expandDataDiskBytes != nil else {
            return skip("无法确认源实例的数据盘扩容量，不克隆")
        }
        guard cloneMarket?.canonicalSign(for: source.regionSign) == rule.regionSign else {
            return skip("「\(source.name)」不在 \(rule.regionName)，不能克隆到这里")
        }
        failedCloneMachines = failedCloneMachines.filter { Date().timeIntervalSince($0.value) < 30 }
        let withCards = hits.filter {
            $0.isRentable && $0.gpuIdle >= max(source.gpuCount, rule.minCards) && failedCloneMachines[$0.id] == nil
                && $0.gpuName == rule.gpuName && cloneMarket?.canonicalSign(for: $0.regionSign) == rule.regionSign
        }
        let candidates = withCards
            .filter { AutoDLAPI.machineFitsCloneDisk(source: source, machine: $0) }
            .sorted { ($0.hourlyPrice ?? .infinity, -$0.gpuIdle) < ($1.hourlyPrice ?? .infinity, -$1.gpuIdle) }
        guard let machine = candidates.first else {
            if !withCards.isEmpty {
                let need = Double(source.expandDataDiskBytes ?? 0) / 1_073_741_824
                return skip("有空卡，但这些机器的数据盘可扩容上限不够源实例的 \(Int(need)) GB 扩容，不克隆")
            }
            return skip("没有单机同时空出 \(source.gpuCount) 张卡")
        }
        if cloneInFlight { return skip("上一次克隆还在处理中") }
        if let lastCloneAt, Date().timeIntervalSince(lastCloneAt) < 60 { return skip("距上次克隆不足 60 秒") }
        let generation = sessionGeneration
        guard claimInstance(source.id, generation: generation) else { return skip("源实例正在处理开关机请求") }
        lastCloneAt = Date()
        cloneInFlight = true
        preparingCloneSourceID = source.id
        let version = cloneCancellationVersion
        Task { await performClone(source: source, machine: machine, rule: rule, generation: generation, version: version) }
        return true
    }

    func cancelPreparingClone(sourceID: String) {
        guard preparingCloneSourceID == sourceID else { return }
        cloneCancellationVersion += 1
        cloneMarket?.disableAutoClones(sourceID: sourceID)
        addActivity(kind: .info, title: "已取消待发送的克隆", detail: "尚未下单；已关闭该源实例的自动克隆规则")
    }

    func acknowledgeCloneOrder(sourceID: String, orderID: String) {
        guard !cloneInFlight, pendingCloneOrders[sourceID]?.id == orderID else { return }
        cloneMarket?.disableAutoClones(sourceID: sourceID)
        clearCloneOrder(sourceID: sourceID, orderID: orderID)
        addActivity(kind: .info, title: "克隆订单已人工核对", detail: "如需再次克隆，请重新开启规则；源实例自动开机仍保持关闭")
    }

    private func persistCloneOrders() -> Bool {
        guard let data = try? JSONEncoder().encode(pendingCloneOrders) else { return false }
        for (sourceID, order) in pendingCloneOrders {
            let key = cloneOrderSourceKey(sourceID)
            if let previous = defaults.data(forKey: key) {
                guard let saved = try? JSONDecoder().decode(PendingCloneOrder.self, from: previous), saved.id == order.id else { return false }
            }
        }
        for (sourceID, order) in pendingCloneOrders {
            guard let value = try? JSONEncoder().encode(order) else { return false }
            defaults.set(value, forKey: cloneOrderSourceKey(sourceID))
        }
        defaults.set(data, forKey: pendingCloneKey)
        return defaults.synchronize()
    }

    private func clearCloneOrder(sourceID: String, orderID: String) {
        guard pendingCloneOrders[sourceID]?.id == orderID else { return }
        pendingCloneOrders[sourceID] = nil
        let key = cloneOrderSourceKey(sourceID)
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(PendingCloneOrder.self, from: data), saved.id == orderID {
            defaults.removeObject(forKey: key)
        }
        _ = persistCloneOrders()
    }

    private func reconcileCloneOrders(_ list: [AutoDLInstance]) {
        // The source UUID survives logout/re-adding an account even when its local account ID changes.
        for instance in list {
            if let data = defaults.data(forKey: cloneOrderSourceKey(instance.id)),
               let saved = try? JSONDecoder().decode(PendingCloneOrder.self, from: data) {
                pendingCloneOrders[instance.id] = saved
            }
        }
        for (sourceID, order) in pendingCloneOrders {
            guard let uuid = order.uuid, let instance = list.first(where: { $0.id == uuid }) else { continue }
            let expansionMatches = instance.expandDataDiskBytes == order.expansion
            if !expansionMatches {
                let detail = "\(instance.name) 的数据盘扩容量尚未确认与源实例一致，请到 AutoDL 核对；不会重复下单"
                if cloneWarnings[sourceID] != detail {
                    cloneWarnings[sourceID] = detail
                    alert(kind: .warning, title: "克隆容量待核对", body: detail, identifier: "hunao.clone.disk.\(uuid)")
                    addActivity(kind: .warning, title: "克隆容量待核对", detail: detail)
                }
            } else if instance.state == .running && instance.startMode.lowercased() == "gpu" {
                clearCloneOrder(sourceID: sourceID, orderID: order.id)
                addActivity(kind: .success, title: "克隆实例 GPU 与容量已确认", detail: "\(instance.name) 已以 GPU 模式运行，扩容量已对齐；文件复制完整性请在实例内核对")
            }
        }
    }

    private func performClone(
        source: AutoDLInstance, machine: MarketMachine, rule: RegionAlertRule, generation: Int, version: Int
    ) async {
        defer {
            cloneInFlight = false
            preparingCloneSourceID = nil
            releaseInstance(source.id, generation: generation)
        }
        func authorized() -> Bool {
            isCurrent(generation) && !isPaused && version == cloneCancellationVersion
                && cloneMarket?.isCloneAuthorized(rule) == true
        }
        guard authorized() else { return }
        let api = makeAPI(token: account.token)
        let target = "\(machine.alias) · \(machine.gpuName)"
        var sentOrder: PendingCloneOrder?
        addActivity(kind: .info, title: "自动克隆已触发", detail: "\(source.name) → \(target)（按量计费，系统盘+数据盘）")
        do {
            let image: AutoDLAPI.CloneImage
            if let cached = cloneImages[source.id], Date().timeIntervalSince(cached.fetchedAt) < 300,
               sameCloneConfiguration(cached.source, source) {
                image = cached.image
            } else {
                image = try await api.fetchCloneImage(instanceUUID: source.id)
                guard authorized() else { return }
                cloneImages[source.id] = (image, source, Date())
            }
            guard authorized() else { return }
            guard let latest = instances.first(where: { $0.id == source.id }), sameCloneConfiguration(latest, source),
                  latest.state == .stopped || latest.isNoCardMode,
                  let fetchedAt = instancesFetchedAt, Date().timeIntervalSince(fetchedAt) <= 30 else {
                throw AutoDLError.clonePrecondition("准备期间源实例配置或状态已变化，请刷新后重新开启自动克隆")
            }
            _ = try AutoDLAPI.cloneBody(source: source, image: image, machine: machine)
            guard let expansion = source.expandDataDiskBytes else {
                throw AutoDLError.clonePrecondition("源实例扩容量未知，不下单")
            }
            let order = PendingCloneOrder(
                sourceID: source.id, sourceName: source.name, regionSign: source.regionSign,
                machineID: machine.id, expansion: expansion
            )
            pendingCloneOrders[source.id] = order
            guard persistCloneOrders() else {
                throw AutoDLError.clonePrecondition("无法保存克隆订单保护记录，已停止下单，请先核对本地存储")
            }
            if selectedInstanceID == source.id && autoStartEnabled {
                autoStartEnabled = false
                defaults.set(false, forKey: autoStartKey)
                addActivity(kind: .info, title: "源实例自动开机已关闭", detail: "避免源实例与克隆实例同时占卡计费")
            }
            sentOrder = order
            preparingCloneSourceID = nil
            let uuid = try await api.cloneInstance(source: source, image: image, machine: machine)
            if pendingCloneOrders[source.id]?.id == order.id {
                pendingCloneOrders[source.id]?.uuid = uuid
                _ = persistCloneOrders()
            }
            guard isCurrent(generation) else { return }
            let detail = "\(source.name) → \(target)，订单已提交，新实例 \(uuid) 正在创建"
            addActivity(kind: .success, title: "自动克隆已下单", detail: detail)
            alert(kind: .success, title: "自动克隆已下单", body: detail, identifier: "hunao.clone.success.\(source.id)")
            let deadline = Date().addingTimeInterval(cloneConfirmationWindow)
            while Date() < deadline, isCurrent(generation), !isPaused {
                if let list = try? await api.fetchInstances(timeout: max(0.01, deadline.timeIntervalSinceNow)) {
                    guard isCurrent(generation) else { return }
                    applyInstances(list)
                    if pendingCloneOrders[source.id] == nil { return }
                }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try? await Task.sleep(nanoseconds: min(cloneConfirmationNanos, UInt64(remaining * 1_000_000_000)))
            }
            guard isCurrent(generation), pendingCloneOrders[source.id] != nil else { return }
            let warning = "新实例 \(uuid) 已下单，但尚未确认 GPU 运行及容量；请在 AutoDL 核对创建和数据盘复制状态，不会再次下单。后续刷新会继续核对。"
            addActivity(kind: .warning, title: "克隆订单待确认", detail: warning)
            alert(kind: .warning, title: "克隆订单待确认", body: warning, identifier: "hunao.clone.pending.\(uuid)")
        } catch let error as AutoDLError where error.isAuthFailure {
            if let sentOrder {
                clearCloneOrder(sourceID: source.id, orderID: sentOrder.id)
            }
            expireIfCurrent(generation, reason: error.localizedDescription)
        } catch {
            // Only console-confirmed pre-order rejection codes may release the durable order guard.
            let rejected = (error as? AutoDLError)?.isDefinitiveCloneRejection == true
            if rejected, let sentOrder {
                clearCloneOrder(sourceID: source.id, orderID: sentOrder.id)
            }
            guard isCurrent(generation) else { return }
            let detail = error.localizedDescription
            if sentOrder != nil && !rejected {
                let warning = "\(detail)。下单结果未知，请在区域页核对订单；已停止重试，避免重复创建计费实例。"
                addActivity(kind: .warning, title: "克隆下单结果未知", detail: warning)
                alert(kind: .warning, title: "克隆下单结果未知", body: warning, identifier: "hunao.clone.unknown.\(source.id)")
                return
            }
            addActivity(kind: .error, title: "自动克隆失败", detail: detail)
            var retryNote = ""
            if authorized(), (error as? AutoDLError)?.isRetryableCloneRejection == true {
                failedCloneMachines[machine.id] = Date()
                lastCloneAt = nil
                if let left = cloneMarket?.restoreAutoClone(for: rule) {
                    retryNote = "，已重新守候（还可重试 \(left) 次）"
                    addActivity(kind: .info, title: "自动克隆重新守候", detail: "换一台机器再试，还可重试 \(left) 次")
                }
            }
            app?.presentToast(kind: .error, title: alertPrefix + "自动克隆失败", message: detail + retryNote)
        }
    }

    // MARK: - Messages

    /// With several accounts, toasts and system notifications say which account they are about.
    private var alertPrefix: String {
        (app?.monitors.count ?? 0) > 1 ? "\(account.name) · " : ""
    }

    private func alert(kind: ActivityKind, title: String, body: String, identifier: String) {
        let fullTitle = alertPrefix + title
        app?.presentToast(kind: kind, title: fullTitle, message: body)
        let notifications = app?.notifications
        let accountID = account.id
        Task {
            await notifications?.send(title: fullTitle, body: body, identifier: "\(identifier).\(accountID)")
        }
    }

    func addActivity(kind: ActivityKind, title: String, detail: String = "") {
        activity.insert(ActivityEvent(kind: kind, title: title, detail: detail), at: 0)
        if activity.count > 40 {
            activity = Array(activity.prefix(40))
        }
    }
}
