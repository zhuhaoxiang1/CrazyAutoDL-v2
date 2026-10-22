import AppKit
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var notifications = NotificationService.shared

    var body: some View {
        DashboardContent(market: model.market, notifications: notifications)
    }
}

private struct DashboardContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var market: MarketStore
    @ObservedObject var notifications: NotificationService

    /// `--region=<sign>` opens on that region; used for screenshots and quick checks.
    @State private var selectedRegion: String? = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--region=") }
        .map { String($0.dropFirst("--region=".count)) }

    private var chargeType: String {
        guard let type = model.selectedInstance?.chargeType, !type.isEmpty else { return "payg" }
        return type
    }

    /// Regions where the account has instances, in the order the instances list them.
    private var myRegions: [MarketRegion] {
        var seen = Set<String>()
        // Instances in different pools of one data center (west-B and west-E) share a tab.
        return model.instances.compactMap { instance in
            guard !instance.regionSign.isEmpty else { return nil }
            let sign = market.canonicalSign(for: instance.regionSign)
            guard seen.insert(sign).inserted else { return nil }
            let fallback = instance.regionName.isEmpty ? instance.displayRegion : instance.regionName
            return MarketRegion(sign: sign, name: market.groupName(for: sign) ?? fallback)
        }
    }

    private var activeRegion: String {
        let sign = selectedRegion ?? model.selectedInstance?.regionSign ?? myRegions.first?.sign ?? ""
        return market.canonicalSign(for: sign)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                header

                if let error = model.lastError {
                    errorBanner(error)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(alignment: .top, spacing: 14) {
                    targetSection
                        .frame(maxWidth: .infinity)
                    autoPowerSection
                        .frame(width: 300)
                }
                .fixedSize(horizontal: false, vertical: true)

                regionTabs
                RegionPanel(
                    market: market,
                    regionSign: activeRegion,
                    regionName: tabRegions.first { $0.sign == activeRegion }?.name ?? activeRegion
                )
                statusBar
                logSection
            }
            .padding(.bottom, 22)
        }
        .scrollIndicators(.never)
        .animation(.smooth(duration: 0.32), value: model.lastError)
        .animation(.smooth(duration: 0.32), value: model.stock)
        // Only the focused region is polled (one query per 100 machines), so switching tabs is what costs requests.
        .task(id: "\(activeRegion)|\(chargeType)") {
            guard !activeRegion.isEmpty else { return }
            await market.loadCatalogIfNeeded(account: model.current?.account)
            while !Task.isCancelled {
                await market.refreshGPUTypes(account: model.current?.account, regionSign: activeRegion)
                await market.refreshRegion(
                    account: model.current?.account,
                    regionSign: activeRegion,
                    chargeType: chargeType
                )
                try? await Task.sleep(nanoseconds: market.suggestedScanInterval(for: activeRegion))
            }
        }
        .onChange(of: model.selectedInstanceID) { _, id in
            // Following the monitor target keeps the region view on the instance the user just picked.
            if let instance = model.instances.first(where: { $0.id == id }), !instance.regionSign.isEmpty {
                selectedRegion = instance.regionSign
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("监控台")
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                    targetMenu
                }

                Text(
                    model.isRefreshing
                        ? "$ watch --interval \(Int(model.pollInterval))s   # 同步中…"
                        : "$ watch --interval \(Int(model.pollInterval))s   # 同步于 \(AppFormat.relative(model.lastUpdated))"
                )
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
                .lineLimit(1)
            }

            Spacer()

            balanceChip

            Button {
                model.setMonitoringPaused(!model.monitoringPaused)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.monitoringPaused ? "play.fill" : "pause.fill")
                        .scaledFont(size: 10, weight: .bold)
                    Text(model.monitoringPaused ? "恢复监控" : "暂停监控")
                        .scaledFont(size: 11, weight: .semibold)
                }
                .foregroundStyle(model.monitoringPaused ? AppTheme.amber : AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(model.monitoringPaused ? "恢复后台轮询与提醒" : "暂停后台轮询、提醒与自动开机")

            IconButton(
                symbol: "arrow.clockwise",
                action: { model.refreshNow() },
                isActive: model.isRefreshing,
                help: "立即刷新"
            )
        }
    }

    private var targetMenu: some View {
        Menu {
            if model.instances.isEmpty {
                Text("暂无实例")
            } else {
                ForEach(model.instances) { instance in
                    Button {
                        model.selectInstance(instance.id)
                    } label: {
                        if instance.id == model.selectedInstanceID, model.lostTarget == nil {
                            Label("\(instance.name) · \(instance.gpuName)", systemImage: "checkmark")
                        } else {
                            Text("\(instance.name) · \(instance.gpuName)")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text("◎")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(AppTheme.mint)
                Text(model.selectedInstance?.name ?? (model.lostTarget == nil ? "未选择实例" : "目标已消失，请重选"))
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("▾")
                    .scaledFont(size: 10)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(AppTheme.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.instances.isEmpty)
        .help("切换监控目标")
    }

    private var balanceChip: some View {
        HStack(spacing: 8) {
            Text("余额")
                .scaledFont(size: 11, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary)
            Text(model.balance == nil ? "同步中" : model.balanceLabel)
                .scaledFont(size: 14, weight: .bold)
                .foregroundStyle(model.isLowBalance ? AppTheme.amber : AppTheme.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .panel()
        .help(balanceHelp)
    }

    private var balanceHelp: String {
        guard let balance = model.balance else {
            return "正在同步 AutoDL 账户余额"
        }
        return "现金 \(balance.formattedCash) · 代金券 \(balance.formattedVoucher) · 冻结 \(balance.formattedBlocked)"
    }

    // MARK: Target

    private var targetSection: some View {
        TermSection("监控目标") {
            if let instance = model.selectedInstance {
                StatusPill(label: instance.statusLabel, tint: instance.statusTint)
            }
        } content: {
            if let instance = model.selectedInstance {
                let idle = model.stock?.idleGPUs
                let total = model.stock?.totalGPUs
                let available = model.stock?.isAvailable == true

                HStack(alignment: .top, spacing: 26) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(idle.map(String.init) ?? "—")
                            .scaledFont(size: 44, weight: .bold)
                            .foregroundStyle(available ? AppTheme.mint : AppTheme.textPrimary)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text(total.map { "/ \($0) 卡空闲" } ?? "空闲 GPU")
                            .scaledFont(size: 11.5, weight: .medium)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    .frame(minWidth: 96, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.availabilityHeadline)
                            .scaledFont(size: 18, weight: .semibold)
                            .foregroundStyle(available ? AppTheme.mint : AppTheme.textPrimary)
                            .lineLimit(1)

                        Text("\(instance.name) · \(instance.gpuName) ×\(instance.gpuCount) · \(instance.displayRegion) · \(instance.machineID.isEmpty ? "主机待同步" : instance.machineID)")
                            .scaledFont(size: 11.5)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)

                        HStack(spacing: 10) {
                            AsciiBar(
                                fraction: slotFraction(idle: idle, total: total),
                                cells: slotCells(total ?? instance.gpuCount),
                                tint: available ? AppTheme.mint : AppTheme.textTertiary,
                                size: 16
                            )
                            Text(idle.map { "\($0)/\(total ?? instance.gpuCount)" } ?? "待同步")
                                .scaledFont(size: 12, weight: .semibold)
                                .foregroundStyle(available ? AppTheme.mint : AppTheme.textTertiary)
                                .monospacedDigit()
                        }

                        Text(model.availabilityCaption)
                            .scaledFont(size: 11)
                            .foregroundStyle(AppTheme.textTertiary)
                            .lineLimit(2)

                        Text("内存 \(instance.memoryFreeLabel) · 存储 \(instance.storageFreeLabel) 剩余")
                            .scaledFont(size: 10.5)
                            .foregroundStyle(AppTheme.textTertiary)
                            .help("\(instance.memoryDetailLabel)\n\(instance.storageDetailLabel)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(model.lostTarget.map { "监控目标「\($0.name)」已不在实例列表中，自动开机已暂停。请在右上角的目标菜单中重新选择。" }
                    ?? "还没有可监控的实例。请在 AutoDL 控制台创建实例，刷新后会出现在这里。")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
    }

    /// Few cards get fat segments so `2/8` still reads as a bar; many cards fall back to one cell per card.
    private func slotCells(_ cards: Int) -> Int {
        let count = max(cards, 1)
        return count <= 8 ? count * 3 : min(count * 2, 32)
    }

    private func slotFraction(idle: Int?, total: Int?) -> Double {
        guard let idle, let total, total > 0 else { return 0 }
        return Double(idle) / Double(total)
    }

    // MARK: Auto power

    private var autoPowerSection: some View {
        TermSection("自动开机") {
            CustomSwitch(isOn: model.autoStartEnabled) {
                model.setAutoStart(!model.autoStartEnabled)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if model.isAutoStarting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(AppTheme.mint)
                        Text("正在抢占空闲显卡…")
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(AppTheme.mint)
                    }
                } else {
                    Text(model.autoStartSubtitle)
                        .scaledFont(size: 12)
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(3)
                }

                Text(model.autoStartEnabled ? "● 空闲即抢，成功后通知我" : "○ 已关闭，有卡时只提醒我")
                    .scaledFont(size: 11)
                    .foregroundStyle(model.autoStartEnabled ? AppTheme.mint.opacity(0.85) : AppTheme.amber)

                Spacer(minLength: 0)

                if let instance = model.selectedInstance {
                    HStack {
                        Text(instance.name)
                            .scaledFont(size: 11.5, weight: .semibold)
                            .foregroundStyle(AppTheme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        InstancePowerButton(instance: instance)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: Region tabs

    /// One tab per region the account has instances in, plus any region picked from "其他区" for browsing.
    private var tabRegions: [MarketRegion] {
        var regions = myRegions
        if !activeRegion.isEmpty, !regions.contains(where: { $0.sign == activeRegion }) {
            let name = market.knownRegions.first { $0.sign == activeRegion }?.name ?? activeRegion
            regions.append(MarketRegion(sign: activeRegion, name: name))
        }
        return regions
    }

    private var regionTabs: some View {
        HStack(spacing: 8) {
            Text("区域")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)

            ForEach(tabRegions) { region in
                regionTab(region)
            }

            let others = market.knownRegions.filter { region in !tabRegions.contains { $0.sign == region.sign } }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { region in
                        Button("\(region.name)（\(market.groupSigns(for: region.sign).count) 个池）") { selectedRegion = region.sign }
                    }
                } label: {
                    Text("+ 其他区")
                        .scaledFont(size: 11, weight: .medium)
                        .foregroundStyle(AppTheme.textSecondary)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(AppTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            Spacer(minLength: 0)

            Button {
                model.selectedSection = .market
            } label: {
                Text("按型号看全部区 →")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func regionTab(_ region: MarketRegion) -> some View {
        let selected = region.sign == activeRegion
        let mine = model.instances.filter { market.canonicalSign(for: $0.regionSign) == region.sign }
        let running = mine.filter(\.holdsGPU).count
        let noCard = mine.filter(\.isNoCardMode).count
        return Button {
            selectedRegion = region.sign
        } label: {
            HStack(spacing: 7) {
                Text(region.name)
                    .scaledFont(size: 12, weight: selected ? .bold : .medium)
                    .foregroundStyle(selected ? AppTheme.textPrimary : AppTheme.textSecondary)
                if !mine.isEmpty {
                    Text("◆\(mine.count)")
                        .scaledFont(size: 10.5, weight: .semibold)
                        .foregroundStyle(AppTheme.mint)
                    if running > 0 {
                        Text("▶\(running)")
                            .scaledFont(size: 10.5, weight: .semibold)
                            .foregroundStyle(AppTheme.mint.opacity(0.7))
                    }
                    if noCard > 0 {
                        Text("◌\(noCard)")
                            .scaledFont(size: 10.5, weight: .semibold)
                            .foregroundStyle(AppTheme.aqua.opacity(0.85))
                    }
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(selected ? AppTheme.mint.opacity(0.10) : Color.white.opacity(0.03),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(selected ? AppTheme.mint.opacity(0.55) : AppTheme.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(market.groupSigns(for: region.sign).joined(separator: " / ")) · 我在这里有 \(mine.count) 台实例：\(running) 台占用 GPU 运行，\(noCard) 台无卡运行（▶ GPU，◌ 无卡）")
    }

    // MARK: Log

    private var logSection: some View {
        TermSection("实时动态") {
            Text("\(model.activity.count) 条")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
        } content: {
            if model.activity.isEmpty {
                Text("还没有监控动态。实例状态变化、空闲提醒和自动开机会记录在这里。")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.activity.prefix(10))) { event in
                        LogLine(event: event)
                    }
                }
            }
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 18) {
            statusItem("轮询", "\(Int(model.pollInterval))s", AppTheme.aqua)
            statusItem("余额", model.balance == nil ? "同步中" : model.balanceLabel, model.isLowBalance ? AppTheme.amber : AppTheme.mint)
            statusItem("通知", notificationLabel, notificationTint)
            statusItem("凭证", "本机", AppTheme.mint)

            Spacer(minLength: 0)

            if notifications.authorizationStatus == .denied {
                Button("开启系统通知") { model.openNotificationSettings() }
                    .buttonStyle(.plain)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(AppTheme.amber)
            }
            Button("设置 →") {
                withAnimation(.smooth(duration: 0.3)) { model.selectedSection = .settings }
            }
            .buttonStyle(.plain)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .panel()
    }

    private func statusItem(_ key: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
            Text(value)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(tint)
        }
    }

    private var notificationLabel: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional: return "已开启"
        case .denied: return "已关闭"
        case .notDetermined: return "待授权"
        @unknown default: return "未知"
        }
    }

    private var notificationTint: Color {
        switch notifications.authorizationStatus {
        case .authorized, .provisional: return AppTheme.mint
        case .denied: return AppTheme.rose
        case .notDetermined: return AppTheme.amber
        @unknown default: return AppTheme.textTertiary
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text("!")
                .scaledFont(size: 12, weight: .bold)
                .foregroundStyle(AppTheme.amber)
            Text(message)
                .scaledFont(size: 11.5, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button("重试") { model.refreshNow() }
                .scaledFont(size: 11.5, weight: .semibold)
                .foregroundStyle(AppTheme.mint)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .panel()
    }
}

/// `01:26:11  ✓ title  detail`
private struct LogLine: View {
    let event: ActivityEvent

    private var glyph: String {
        switch event.kind {
        case .info: return "›"
        case .success: return "✓"
        case .warning: return "!"
        case .error: return "✗"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(AppFormat.time.string(from: event.date))
                .foregroundStyle(AppTheme.textTertiary)
            Text(glyph)
                .fontWeight(.bold)
                .foregroundStyle(event.kind.tint)
                .frame(width: 10)
            (Text(event.title).foregroundStyle(AppTheme.textPrimary).fontWeight(.semibold)
                + Text(event.detail.isEmpty ? "" : "  \(event.detail)").foregroundStyle(AppTheme.textTertiary))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .scaledFont(size: 12)
        .monospacedDigit()
    }
}
