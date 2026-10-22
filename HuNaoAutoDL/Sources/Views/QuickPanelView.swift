import SwiftUI

/// Menu bar popover: a three-second glance at the monitored instance plus the few controls worth reaching from here.
struct QuickPanelView: View {
    @EnvironmentObject private var model: AppModel

    let onOpenDashboard: () -> Void
    let onOpenConsole: () -> Void
    let onRefresh: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.phase == .signedIn {
                targetSection
                PanelRegionSummary(market: model.market)
                instanceChips
                automationSection
                quickActions
            } else if model.phase == .checking {
                checkingCard
            } else {
                disconnectedCard
            }

            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(AppTheme.pageBackground)
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("胡闹AutoDL")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(AppTheme.textPrimary)
                HStack(spacing: 5) {
                    Text("●")
                        .scaledFont(size: 8)
                        .foregroundStyle(modeTint)
                    Text(model.hasMultipleAccounts ? "\(modeLabel) · \(model.currentAccountName)" : modeLabel)
                        .scaledFont(size: 10.5, weight: .medium)
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            squareButton(
                symbol: model.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                tint: model.isRefreshing ? AppTheme.mint : AppTheme.textSecondary,
                help: "立即刷新",
                action: onRefresh
            )
            .disabled(model.phase != .signedIn || model.isRefreshing)

            squareButton(symbol: "macwindow", tint: AppTheme.textSecondary, help: "打开监控台", action: onOpenDashboard)
        }
    }

    private func squareButton(symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Target

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(model.runningCount)")
                    .scaledFont(size: 26, weight: .bold)
                    .foregroundStyle(model.runningCount > 0 ? AppTheme.mint : AppTheme.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("/ \(model.instances.count) 台运行中")
                    .scaledFont(size: 11.5, weight: .medium)
                    .foregroundStyle(AppTheme.textSecondary)
                if let noCard = model.current?.noCardCount, noCard > 0 {
                    Text("· 其中 \(noCard) 台无卡")
                        .scaledFont(size: 11.5, weight: .medium)
                        .foregroundStyle(AppTheme.aqua)
                }

                Spacer()

                Text(model.balance == nil ? "余额 …" : "余额 \(model.balanceLabel)")
                    .scaledFont(size: 11.5, weight: .bold)
                    .foregroundStyle(model.isLowBalance ? AppTheme.amber : AppTheme.mint)
                    .monospacedDigit()
            }

            Rectangle().fill(AppTheme.border).frame(height: 1)

            if let instance = model.selectedInstance {
                let idle = model.stock?.idleGPUs
                let total = model.stock?.totalGPUs
                let available = model.stock?.isAvailable == true

                HStack(spacing: 8) {
                    Text("◎")
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(AppTheme.mint)
                    Text(instance.name)
                        .scaledFont(size: 12.5, weight: .semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                    StatusPill(label: instance.statusLabel, tint: instance.statusTint)
                    Spacer(minLength: 0)
                }

                Text("\(instance.gpuName) ×\(instance.gpuCount) · \(instance.displayRegion)")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)

                HStack(spacing: 10) {
                    AsciiBar(
                        fraction: slotFraction(idle: idle, total: total),
                        cells: slotCells(total ?? instance.gpuCount),
                        tint: available ? AppTheme.mint : AppTheme.textTertiary,
                        size: 13
                    )
                    Text(idle.map { "\($0)/\(total ?? instance.gpuCount)" } ?? "待同步")
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(available ? AppTheme.mint : AppTheme.textTertiary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                }

                Text(model.availabilityHeadline)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(available ? AppTheme.mint : AppTheme.textSecondary)
                    .lineLimit(1)
                    .help("\(instance.memoryDetailLabel) · \(instance.storageDetailLabel)")
            } else {
                Text(model.lostTarget.map { "「\($0.name)」已不在实例列表中，自动开机已暂停，请在监控台重新选择。" }
                    ?? "还没有可监控的实例，打开监控台刷新看看。")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        }
        .padding(12)
        .panel()
    }

    private func slotFraction(idle: Int?, total: Int?) -> Double {
        guard let idle, let total, total > 0 else { return 0 }
        return Double(idle) / Double(total)
    }

    private func slotCells(_ cards: Int) -> Int {
        let count = max(cards, 1)
        return count <= 8 ? count * 2 : min(count, 24)
    }

    // MARK: Instance chips

    private var instanceChips: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("切换监控目标")
                    .scaledFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(AppTheme.textTertiary)
                Spacer()
            }

            if model.instances.isEmpty {
                Text("实例加载后会出现在这里。")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.instances) { instance in
                            targetChip(instance)
                        }
                    }
                }
            }
        }
    }

    private func targetChip(_ instance: AutoDLInstance) -> some View {
        let isSelected = instance.id == model.selectedInstanceID

        return Button {
            model.selectInstance(instance.id)
        } label: {
            HStack(spacing: 6) {
                Text(instance.isNoCardMode ? "◌" : "●")
                    .scaledFont(size: 8)
                    .foregroundStyle(instance.statusTint)
                Text(instance.name)
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .lineLimit(1)
                if isSelected {
                    Text("✓")
                        .scaledFont(size: 10, weight: .bold)
                        .foregroundStyle(AppTheme.mint)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(
                isSelected ? AppTheme.mint.opacity(0.10) : Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(isSelected ? AppTheme.mint.opacity(0.5) : AppTheme.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(instance.gpuName) × \(instance.gpuCount) · \(instance.displayRegion)\n内存剩余 \(instance.memoryFreeLabel) · 存储剩余 \(instance.storageFreeLabel)")
    }

    // MARK: Auto start

    private var automationSection: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("自动开机")
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(model.autoStartEnabled ? "空闲显卡一出现就自动抢占" : "只提醒，不自动开机")
                    .scaledFont(size: 11)
                    .foregroundStyle(model.autoStartEnabled ? AppTheme.mint.opacity(0.85) : AppTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            CustomSwitch(isOn: model.autoStartEnabled) {
                model.setAutoStart(!model.autoStartEnabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .panel()
    }

    // MARK: Actions

    private var quickActions: some View {
        HStack(spacing: 7) {
            if let instance = model.selectedInstance,
               instance.state.isPoweredOff,
               !model.isBusy(instance.id) {
                quickButton(title: "立即开机", symbol: "play.fill", tint: AppTheme.mint, prominent: true) {
                    model.powerOn(instance: instance)
                }
            }

            if let instance = model.selectedInstance,
               instance.state.isPoweredOff,
               !model.isBusy(instance.id) {
                quickButton(title: "无卡开机", symbol: "play", tint: AppTheme.aqua) {
                    if InstancePowerButton.confirmNoCardIfNeeded(instanceName: instance.name) {
                        model.powerOn(instance: instance, noCard: true)
                    }
                }
            }

            quickButton(title: "刷新", symbol: "arrow.clockwise", tint: .white) {
                onRefresh()
            }

            quickButton(title: "控制台", symbol: "arrow.up.right", tint: .white) {
                onOpenConsole()
            }
        }
    }

    private func quickButton(
        title: String,
        symbol: String,
        tint: Color,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 5) {
                if model.isRefreshing && symbol == "arrow.clockwise" {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                } else {
                    Image(systemName: symbol)
                        .scaledFont(size: 10, weight: .bold)
                }
                Text(title)
                    .scaledFont(size: 11, weight: .semibold)
                    .lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(prominent ? tint : Color.white.opacity(0.04), in: shape)
            .overlay {
                if !prominent {
                    shape.strokeBorder(AppTheme.border, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRefreshing && symbol == "arrow.clockwise")
    }

    // MARK: Signed out

    private var checkingCard: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.aqua)
            Text("正在连接 AutoDL…")
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
        }
        .padding(13)
        .panel()
    }

    private var disconnectedCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("还没有连接 AutoDL")
                .scaledFont(size: 13, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            Text("打开主窗口完成登录，就能在这里快速选择目标、开关自动开机。")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onOpenDashboard) {
                Text("打开登录窗口")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(tint: AppTheme.mint, prominent: true))
        }
        .padding(13)
        .panel()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: onOpenDashboard) {
                HStack(spacing: 5) {
                    Text("打开监控台")
                    Text("↗")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionButtonStyle(tint: AppTheme.aqua))

            squareButton(symbol: "power", tint: AppTheme.textTertiary, help: "退出胡闹AutoDL", action: onQuit)

            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(AppTheme.textTertiary.opacity(0.8))
                .fixedSize()
        }
    }

    // MARK: Mode

    private var modeLabel: String {
        guard model.phase == .signedIn else {
            return model.phase == .checking ? "正在连接" : "等待登录"
        }
        if model.autoStartEnabled {
            return "自动开机 · 守候空闲显卡"
        }
        if model.runningCount > 0 {
            return "运行中 · \(model.runningCount)/\(model.instances.count) 台"
        }
        return "监控中 · 每 \(Int(model.pollInterval)) 秒检查"
    }

    private var modeTint: Color {
        guard model.phase == .signedIn else { return AppTheme.textTertiary }
        if model.autoStartEnabled { return AppTheme.amber }
        if model.runningCount > 0 { return AppTheme.mint }
        return AppTheme.aqua
    }
}

/// Region view in miniature: how many idle cards of the target's model its region has right now,
/// and which alert rules currently have cards. Data comes from whichever scan last covered the region.
private struct PanelRegionSummary: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var market: MarketStore

    private var liveRules: [(rule: RegionAlertRule, hits: [MarketMachine])] {
        market.alertRules
            .map { ($0, market.matches(for: $0)) }
            .filter { !$0.1.isEmpty }
    }

    var body: some View {
        let instance = model.selectedInstance
        let snapshot = instance.flatMap { market.regionSnapshots[market.canonicalSign(for: $0.regionSign)] }
        let sameModel = snapshot?.models.first { $0.gpuName == instance?.gpuName }
        let hasContent = (snapshot != nil && instance != nil) || !liveRules.isEmpty

        if hasContent {
            VStack(alignment: .leading, spacing: 7) {
                if let instance, let snapshot {
                    HStack(spacing: 8) {
                        Text("本区")
                            .scaledFont(size: 10.5, weight: .semibold)
                            .foregroundStyle(AppTheme.textTertiary)
                        Text(snapshot.regionName)
                            .scaledFont(size: 11.5, weight: .semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                        Spacer(minLength: 0)
                        Text(snapshot.idleGPUs == 0 ? "无空卡" : "共 \(snapshot.idleGPUs) 张空闲")
                            .scaledFont(size: 11)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    if let sameModel {
                        Text("\(instance.gpuName)：\(sameModel.idleGPUs) 张 · \(sameModel.machineCount) 台 · 单机最多 \(sameModel.bestSingleMachine)")
                            .scaledFont(size: 11.5, weight: .medium)
                            .foregroundStyle(sameModel.bestSingleMachine >= instance.gpuCount ? AppTheme.mint : AppTheme.amber)
                            .lineLimit(1)
                    } else {
                        Text("\(instance.gpuName)：本区暂无空卡")
                            .scaledFont(size: 11.5, weight: .medium)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                }

                ForEach(liveRules.prefix(3), id: \.rule.id) { item in
                    HStack(spacing: 7) {
                        Image(systemName: "bell.fill")
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(AppTheme.amber)
                        Text("\(item.rule.regionName) \(item.rule.gpuName)")
                            .scaledFont(size: 11, weight: .semibold)
                            .foregroundStyle(AppTheme.amber)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(item.hits.count) 台有卡")
                            .scaledFont(size: 11)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
        }
    }
}
