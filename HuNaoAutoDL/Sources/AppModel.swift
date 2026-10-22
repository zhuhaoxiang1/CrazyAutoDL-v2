import Combine
import Foundation
import SwiftUI
import UserNotifications

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case market
    case billing
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: return "监控台"
        case .market: return "算力市场"
        case .billing: return "账单"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: return "dot.radiowaves.left.and.right"
        case .market: return "chart.bar.doc.horizontal"
        case .billing: return "chart.bar.xaxis"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let legacyAutoStartKey = "hunao.autoStartEnabled"
    static let legacySelectedInstanceKey = "hunao.selectedInstanceUUID"

    @Published private(set) var phase: SessionPhase = .checking
    @Published var selectedSection: SidebarSection = .dashboard
    let market = MarketStore()
    @Published private(set) var monitors: [AccountMonitor] = []
    @Published private(set) var currentAccountID: String?
    @Published private(set) var isAddingAccount = false
    @Published private(set) var isLoggingIn = false
    @Published var loginError: String?
    @Published private(set) var pollInterval: TimeInterval
    @Published private(set) var lowBalanceThreshold: Double
    @Published private(set) var fontScale: Double
    /// While paused nothing polls in the background and nothing alerts or auto-starts; a manual refresh still shows data.
    @Published private(set) var monitoringPaused = false
    @Published var toast: ToastMessage?

    let notifications = NotificationService.shared

    private let defaults = UserDefaults.standard
    private let isDemo: Bool
    private var toastDismissTask: Task<Void, Never>?
    private var currentRelay: AnyCancellable?

    private enum DefaultsKey {
        static let currentAccount = "hunao.currentAccountID"
        static let pollInterval = "hunao.pollIntervalSeconds"
        static let lowBalanceThreshold = "hunao.lowBalanceThreshold"
        static let fontScale = "hunao.fontScale"
        static let monitoringPaused = "hunao.monitoringPaused"
    }

    // MARK: - Current account

    /// The account shown in the window. Every account keeps monitoring in the background.
    var current: AccountMonitor? {
        monitors.first { $0.id == currentAccountID } ?? monitors.first
    }

    var hasMultipleAccounts: Bool { monitors.count > 1 }
    var currentAccountName: String { current?.account.name ?? "AutoDL 账户" }

    var instances: [AutoDLInstance] { current?.instances ?? [] }
    var selectedInstanceID: String? { current?.selectedInstanceID }
    var selectedInstance: AutoDLInstance? { current?.selectedInstance }
    var stock: GPUStock? { current?.stock }
    var balance: AccountBalance? { current?.balance }
    var balanceError: String? { current?.balanceError }
    var billing: BillingSnapshot? { current?.billing }
    var billingError: String? { current?.billingError }
    var isBillingLoading: Bool { current?.isBillingLoading ?? false }
    var isRefreshing: Bool { current?.isRefreshing ?? false }
    var lastUpdated: Date? { current?.lastUpdated }
    var lastError: String? { current?.lastError }
    var activity: [ActivityEvent] { current?.activity ?? [] }
    var actionInstanceID: String? { current?.actionInstanceID }
    var isAutoStarting: Bool { current?.isAutoStarting ?? false }
    var lostTarget: LostTarget? { current?.lostTarget }
    func isBusy(_ instanceID: String) -> Bool { current?.isBusy(instanceID) ?? false }
    var autoStartEnabled: Bool { current?.autoStartEnabled ?? false }
    var signedInAt: Date? { current?.signedInAt }
    var tokenHint: String { current?.account.tokenHint ?? "" }
    var isLowBalance: Bool { current?.isLowBalance ?? false }
    var balanceLabel: String { current?.balanceLabel ?? "—" }
    var runningCount: Int { current?.runningCount ?? 0 }
    var autoStartSubtitle: String { current?.autoStartSubtitle ?? "只提醒，不自动开机" }
    var availabilityHeadline: String { current?.availabilityHeadline ?? "等待选择实例" }
    var availabilityCaption: String { current?.availabilityCaption ?? "先在 AutoDL 创建一个实例" }

    var isAnyAutoStartEnabled: Bool {
        monitors.contains { $0.autoStartEnabled && $0.authFailure == nil }
    }

    /// The login screen covers the app while adding an account or when the shown account needs to sign in again.
    var isShowingAuth: Bool {
        phase == .loggedOut || isAddingAccount || current?.authFailure != nil
    }

    var authTitle: String {
        if isAddingAccount { return "添加 AutoDL 账号" }
        if phase == .signedIn, let current, current.authFailure != nil {
            return hasMultipleAccounts ? "重新登录「\(current.account.name)」" : "重新登录 AutoDL"
        }
        return "登录 AutoDL"
    }

    var canCancelAuth: Bool {
        isAddingAccount || monitors.contains { $0.id != current?.id && $0.authFailure == nil }
    }

    func refreshNow() { current?.refreshNow() }

    /// Starts the background scan for region alert rules. Idempotent; called once the window exists.
    func startRegionWatch() {
        market.startWatching(
            account: { [weak self] in
                guard let monitor = self?.current, monitor.authFailure == nil, !monitor.account.token.isEmpty else {
                    return nil
                }
                return monitor.account
            },
            chargeType: { [weak self] in
                guard let type = self?.selectedInstance?.chargeType, !type.isEmpty else { return "payg" }
                return type
            },
            onAlert: { [weak self] title, body, id in
                Task { @MainActor in
                    guard let self else { return }
                    self.presentToast(kind: .warning, title: title, message: body)
                    await self.notifications.send(
                        title: title,
                        body: body,
                        identifier: id,
                        threadIdentifier: "hunao.autodl.region"
                    )
                }
            }
        )
    }

    /// Asks for notification permission the first time a rule is created, so the alert can actually be shown.
    func requestNotificationAccessIfNeeded() {
        Task {
            await notifications.refreshAuthorizationStatus()
            if notifications.authorizationStatus == .notDetermined {
                _ = await notifications.requestAuthorization()
            }
        }
    }
    func refreshBilling(force: Bool = false) { current?.refreshBilling(force: force) }
    func selectInstance(_ id: String) { current?.selectInstance(id) }
    func setAutoStart(_ enabled: Bool) { current?.setAutoStart(enabled) }
    func powerOn(instance: AutoDLInstance, noCard: Bool = false) { current?.powerOn(instance: instance, noCard: noCard) }
    func powerOff(instance: AutoDLInstance) { current?.powerOff(instance: instance) }

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")

        let defaults = UserDefaults.standard
        let storedInterval = defaults.double(forKey: DefaultsKey.pollInterval)
        pollInterval = (8...120).contains(storedInterval) ? storedInterval : 15

        let storedThreshold = defaults.double(forKey: DefaultsKey.lowBalanceThreshold)
        lowBalanceThreshold = (1...10_000).contains(storedThreshold) ? storedThreshold : 20

        let storedScale = defaults.double(forKey: DefaultsKey.fontScale)
        fontScale = (0.85...1.3).contains(storedScale) ? storedScale : 1.0
        monitoringPaused = defaults.bool(forKey: DefaultsKey.monitoringPaused)
        market.watchPaused = monitoringPaused

        if isDemo {
            applyDemoData()
            return
        }

        let accounts = AccountStore.load()
        guard !accounts.isEmpty else {
            phase = .loggedOut
            return
        }
        monitors = accounts.map {
            AccountMonitor(account: $0, app: self, inheritLegacySettings: accounts.count == 1)
        }
        let saved = defaults.string(forKey: DefaultsKey.currentAccount)
        currentAccountID = monitors.first { $0.id == saved }?.id ?? monitors.first?.id
        bindCurrent()
        phase = .checking
        Task { await bootstrapAll() }
    }

    private func applyDemoData() {
        let seed = DemoData.seed()
        let lab = AccountMonitor(
            account: AutoDLAccount(id: "demo-lab", name: "实验室", token: "", isSubAccount: false),
            app: self
        )
        lab.applyDemo(
            instances: seed.instances,
            selectedInstanceID: seed.selectedInstanceID,
            stock: seed.stock,
            balance: seed.balance,
            billing: seed.billing,
            activity: seed.activity,
            autoStart: true
        )
        let personal = AccountMonitor(
            account: AutoDLAccount(id: "demo-personal", name: "个人", token: "", isSubAccount: false),
            app: self
        )
        personal.applyDemo(
            instances: Array(seed.instances.suffix(1)),
            selectedInstanceID: seed.instances.last?.id,
            stock: nil,
            balance: AccountBalance(cash: 42.80, blocked: 0, voucher: 0, paymentMethod: "balance", fetchedAt: Date()),
            billing: nil,
            activity: [],
            autoStart: false
        )
        monitors = [lab, personal]
        currentAccountID = lab.id
        pollInterval = 15
        fontScale = 1.0
        bindCurrent()
        phase = .signedIn

        let arguments = ProcessInfo.processInfo.arguments
        if let argument = arguments.first(where: { $0.hasPrefix("--section=") }),
           let section = SidebarSection(rawValue: String(argument.dropFirst("--section=".count))) {
            selectedSection = section
        }
    }

    private func bootstrapAll() async {
        let currentID = current?.id
        for monitor in monitors where monitor.id != currentID {
            Task { await monitor.bootstrap() }
        }
        await current?.bootstrap()
        phase = .signedIn
        notifications.activate()
        requestNotificationPermissionIfNeeded()
    }

    private func bindCurrent() {
        // Only the account on screen redraws the window; background accounts poll silently.
        currentRelay = current?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Accounts

    func switchAccount(to id: String) {
        guard currentAccountID != id, monitors.contains(where: { $0.id == id }) else { return }
        currentAccountID = id
        if !isDemo {
            defaults.set(id, forKey: DefaultsKey.currentAccount)
        }
        bindCurrent()
    }

    func beginAddAccount() {
        loginError = nil
        Task {
            // Start from a clean web session so the login page does not reuse the account already added.
            await LoginWebSession.clearAndWait()
            isAddingAccount = true
        }
    }

    func cancelAuth() {
        loginError = nil
        if isAddingAccount {
            isAddingAccount = false
            return
        }
        if let other = monitors.first(where: { $0.id != current?.id && $0.authFailure == nil }) {
            switchAccount(to: other.id)
        }
    }

    func renameAccount(_ id: String, to rawName: String) {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))
        guard !name.isEmpty, let monitor = monitors.first(where: { $0.id == id }),
              monitor.account.name != name
        else { return }
        monitor.rename(name)
        persistAccounts()
        objectWillChange.send()
    }

    func removeAccount(_ id: String) {
        guard let monitor = monitors.first(where: { $0.id == id }) else { return }
        monitor.stop(forgetSettings: true)
        monitors.removeAll { $0.id == id }
        // The sign-out must not look successful while the token is still on disk: the next launch would log back in.
        var credentialsRemoved = isDemo || persistAccounts()
        if !credentialsRemoved && monitors.isEmpty {
            credentialsRemoved = AccountStore.purge()
        }
        if !credentialsRemoved {
            presentToast(
                kind: .error,
                title: "本地凭证删除失败",
                message: "磁盘上的登录凭证没能清除，下次启动可能仍会自动登录。请检查磁盘空间或文件权限，或手动删除 Application Support/HuNaoAutoDL-v2/accounts.json。"
            )
        }

        if currentAccountID == id {
            currentAccountID = monitors.first?.id
            if let next = currentAccountID {
                defaults.set(next, forKey: DefaultsKey.currentAccount)
            } else {
                defaults.removeObject(forKey: DefaultsKey.currentAccount)
            }
            bindCurrent()
        }

        if monitors.isEmpty {
            LoginWebSession.clear()
            phase = .loggedOut
            isAddingAccount = false
            loginError = nil
        }
        notifications.activate()
    }

    /// Signs out of the account on screen; other accounts keep running.
    func logout() {
        if let id = current?.id {
            removeAccount(id)
        }
    }

    @discardableResult
    func persistAccounts() -> Bool {
        guard !isDemo else { return false }
        return AccountStore.save(monitors.map(\.account))
    }

    func accountDidExpire(_ monitor: AccountMonitor) {
        LoginWebSession.clear()
        let message = hasMultipleAccounts ? "「\(monitor.account.name)」需要重新登录" : "请重新连接 AutoDL"
        presentToast(kind: .error, title: "登录已失效", message: message)
        if monitor.id != current?.id {
            Task {
                await notifications.send(
                    title: "登录已失效",
                    body: "\(message)，该账号的监控和自动开机已暂停。",
                    identifier: "hunao.auth.expired.\(monitor.id)"
                )
            }
        }
    }

    private func nextAccountName() -> String {
        let used = Set(monitors.map(\.account.name))
        var index = monitors.count + 1
        while used.contains("账号 \(index)") {
            index += 1
        }
        return "账号 \(index)"
    }

    // MARK: - Sign in

    @discardableResult
    func signIn(token rawToken: String) async -> Bool {
        let candidate = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, !isLoggingIn else { return false }

        let reauthTarget = isAddingAccount ? nil : monitors.first { $0.id == current?.id && $0.authFailure != nil }
        if let existing = monitors.first(where: { $0.account.token == candidate }), existing.id != reauthTarget?.id {
            loginError = "这个账号已经添加过（\(existing.account.name)）。要添加另一个账号，请先在网页里退出 AutoDL，再登录另一个账号。"
            return false
        }

        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }

        do {
            let connection = try await AutoDLAPI.connect(token: candidate)
            let list = connection.instances
            let isSubAccount = connection.api.isSubAccount
            let instanceIDs = Set(list.map(\.id))

            // A new token whose instances belong to an account we already have refreshes that account;
            // signing in to a different account from the re-login screen adds it instead of overwriting.
            var target = reauthTarget
            if let reauthTarget, !instanceIDs.isEmpty, !reauthTarget.knownInstanceIDs.isEmpty,
               instanceIDs.isDisjoint(with: reauthTarget.knownInstanceIDs) {
                target = nil
            }
            if target == nil {
                target = monitors.first {
                    !instanceIDs.isEmpty && !instanceIDs.isDisjoint(with: $0.knownInstanceIDs)
                }
            }

            if let target {
                target.updateCredentials(token: candidate, isSubAccount: isSubAccount, instances: list, saved: true)
                if !persistAccounts() {
                    target.addActivity(kind: .warning, title: "Token 未能写入本机", detail: "仅在本次运行中生效")
                }
                switchAccount(to: target.id)
                if isAddingAccount {
                    presentToast(kind: .info, title: "账号已存在", message: "已更新「\(target.account.name)」的登录凭证")
                }
            } else {
                let account = AutoDLAccount(name: nextAccountName(), token: candidate, isSubAccount: isSubAccount)
                let monitor = AccountMonitor(account: account, app: self, inheritLegacySettings: monitors.isEmpty)
                monitors.append(monitor)
                monitor.activate(instances: list, saved: persistAccounts())
                switchAccount(to: monitor.id)
                if hasMultipleAccounts {
                    presentToast(
                        kind: .success,
                        title: "已添加「\(account.name)」",
                        message: "两个账号会同时监控，点左下角账号可以切换查看。"
                    )
                }
            }

            isAddingAccount = false
            loginError = nil
            phase = .signedIn
            notifications.activate()
            requestNotificationPermissionIfNeeded()
            return true
        } catch let error as AutoDLError where error.isAuthFailure {
            loginError = "Token 无效或已过期，请重新扫码或登录"
        } catch {
            loginError = error.localizedDescription
        }
        return false
    }

    // MARK: - Settings

    func setMonitoringPaused(_ paused: Bool) {
        guard monitoringPaused != paused else { return }
        monitoringPaused = paused
        defaults.set(paused, forKey: DefaultsKey.monitoringPaused)
        market.watchPaused = paused
        monitors.forEach { $0.monitoringPauseChanged(paused) }
    }

    func setPollInterval(_ seconds: TimeInterval) {
        let normalized = min(max(seconds, 8), 120)
        guard pollInterval != normalized else { return }
        pollInterval = normalized
        defaults.set(normalized, forKey: DefaultsKey.pollInterval)
        current?.addActivity(kind: .info, title: "刷新间隔已调整", detail: "每 \(Int(normalized)) 秒检查一次")
        monitors.forEach { $0.restartMonitoring() }
    }

    func setLowBalanceThreshold(_ value: Double) {
        let normalized = min(max(value, 1), 10_000)
        guard abs(normalized - lowBalanceThreshold) > 0.001 else { return }
        lowBalanceThreshold = normalized
        defaults.set(normalized, forKey: DefaultsKey.lowBalanceThreshold)
        current?.addActivity(
            kind: .info,
            title: "余额提醒阈值已更新",
            detail: "可用余额低于 \(AccountBalance.currency(normalized)) 时提醒"
        )
        monitors.forEach { $0.lowBalanceThresholdChanged() }
    }

    func setFontScale(_ value: Double) {
        let stepped = (min(max(value, 0.85), 1.3) * 20).rounded() / 20
        guard abs(stepped - fontScale) > 0.001 else { return }
        fontScale = stepped
        defaults.set(stepped, forKey: DefaultsKey.fontScale)
    }

    // MARK: - Notifications

    func requestNotifications() {
        Task {
            await notifications.requestAuthorization()
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        Task {
            await notifications.refreshAuthorizationStatus()
            if notifications.authorizationStatus == .notDetermined {
                _ = await notifications.requestAuthorization()
            }
        }
    }

    func sendTestNotification() {
        Task {
            if notifications.authorizationStatus == .notDetermined {
                _ = await notifications.requestAuthorization()
            }
            let delivered = await notifications.sendTestNotification()
            if !delivered {
                presentToast(
                    kind: .warning,
                    title: "通知发送失败",
                    message: "请在系统设置中允许胡闹AutoDL发送通知"
                )
            } else if !notifications.alertsEnabled {
                presentToast(
                    kind: .warning,
                    title: "通知已送达",
                    message: "横幅提醒已关闭，请在系统设置中把通知样式改为「横幅」"
                )
            } else {
                presentToast(
                    kind: .info,
                    title: "测试通知已发送",
                    message: "如果没有看到横幅，请检查系统通知设置"
                )
            }
        }
    }

    func openNotificationSettings() {
        notifications.openSystemNotificationSettings()
    }

    // MARK: - UI helpers

    func presentToast(kind: ActivityKind, title: String, message: String) {
        let newToast = ToastMessage(kind: kind, title: title, message: message)
        toast = newToast
        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.toast?.id == newToast.id {
                self?.toast = nil
            }
        }
    }

    func dismissToast(_ toast: ToastMessage) {
        if self.toast?.id == toast.id {
            self.toast = nil
        }
    }
}
