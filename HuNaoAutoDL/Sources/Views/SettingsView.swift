import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var notifications = NotificationService.shared

    /// `--group=<account|alerts|appearance>` opens on that group; used for screenshots.
    @State private var group: SettingsGroup = ProcessInfo.processInfo.arguments
        .first { $0.hasPrefix("--group=") }
        .flatMap { SettingsGroup(rawValue: String($0.dropFirst("--group=".count))) } ?? .account

    @State private var accountToRemove: AutoDLAccount?
    @State private var editingAccountID: String?
    @State private var draftName = ""

    private let intervalChoices: [TimeInterval] = [1, 3, 10, 15, 30, 60]
    private let balanceThresholdChoices: [Double] = [10, 20, 50, 100]
    private let fontScaleChoices: [Double] = [0.85, 0.9, 1.0, 1.1, 1.2, 1.3]

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                header

                HStack(alignment: .top, spacing: 18) {
                    groupNav
                        .frame(width: 168)

                    groupContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(.bottom, 26)
        }
        .scrollIndicators(.never)
        .defaultScrollAnchor(.top)
        .alert(
            "移除「\(accountToRemove?.name ?? "")」？",
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button("移除", role: .destructive) {
                model.removeAccount(account.id)
                accountToRemove = nil
            }
            Button("取消", role: .cancel) {
                accountToRemove = nil
            }
        } message: { _ in
            Text(model.hasMultipleAccounts
                 ? "本机保存的 Token 会被删除，这个账号的监控和自动开机也会停止，其他账号不受影响。"
                 : "本机保存的 Token 会被删除，监控和自动开机也会停止。")
        }
    }

    // MARK: Groups

    private var groupNav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsGroup.allCases) { item in
                SettingsGroupItem(
                    group: item,
                    isSelected: group == item,
                    needsAttention: needsAttention(item)
                ) {
                    group = item
                }
            }
        }
        .padding(8)
        .panel()
    }

    private func needsAttention(_ item: SettingsGroup) -> Bool {
        switch item {
        case .account: return model.monitors.contains { $0.authFailure != nil }
        case .alerts: return notifications.authorizationStatus == .denied
        default: return false
        }
    }

    @ViewBuilder
    private var groupContent: some View {
        switch group {
        case .account:
            accountCard
        case .alerts:
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 16) {
                    automationCard
                    notificationCard
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 16) {
                    balanceCard
                }
                .frame(maxWidth: .infinity)
            }
        case .appearance:
            appearanceCard
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("设置")
                    .scaledFont(size: 22, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                StatusPill(label: "本地运行", tint: AppTheme.mint)
            }
            Text("调整检查节奏、通知方式与账户连接。")
                .scaledFont(size: 11.5)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountCard: some View {
        SettingsCard(
            title: model.hasMultipleAccounts ? "账号（\(model.monitors.count)）" : "账号",
            symbol: "person.2",
            tint: AppTheme.aqua
        ) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 0) {
                    ForEach(Array(model.monitors.enumerated()), id: \.element.id) { index, monitor in
                        if index > 0 {
                            Rectangle()
                                .fill(.white.opacity(0.06))
                                .frame(height: 0.6)
                        }
                        accountRow(monitor)
                    }
                }

                HStack {
                    Button {
                        model.beginAddAccount()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .scaledFont(size: 9, weight: .bold)
                            Text("添加账号")
                        }
                    }
                    .buttonStyle(ActionButtonStyle(tint: AppTheme.mint, prominent: true))

                    Spacer()

                    Text("Token 仅保存在本机，当前用户可读")
                        .scaledFont(size: 9)
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
        }
    }

    private func accountRow(_ monitor: AccountMonitor) -> some View {
        let isCurrent = monitor.id == model.current?.id
        let isEditing = editingAccountID == monitor.id

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextField("账号备注", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(size: 11.5)
                        .frame(maxWidth: 180)
                        .onSubmit { commitRename(monitor) }
                } else {
                    HStack(spacing: 6) {
                        Text(monitor.account.name)
                            .scaledFont(size: 12, weight: .semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)
                        Button {
                            draftName = monitor.account.name
                            editingAccountID = monitor.id
                        } label: {
                            Image(systemName: "pencil")
                                .scaledFont(size: 9, weight: .semibold)
                                .foregroundStyle(AppTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("修改备注名")
                    }
                }
                Text(accountSubtitle(monitor))
                    .scaledFont(size: 9, design: .monospaced)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isEditing {
                Button("保存") { commitRename(monitor) }
                    .buttonStyle(ActionButtonStyle(tint: AppTheme.mint))
                Button("取消") { editingAccountID = nil }
                    .buttonStyle(ActionButtonStyle(tint: .white))
            } else {
                if monitor.authFailure != nil {
                    StatusPill(label: "需重新登录", tint: AppTheme.amber)
                } else if isCurrent {
                    StatusPill(label: "当前查看", tint: AppTheme.mint)
                } else {
                    StatusPill(label: monitor.autoStartEnabled ? "自动开机中" : "监控中", tint: AppTheme.aqua)
                }

                if monitor.authFailure != nil {
                    Button("重新登录") { model.switchAccount(to: monitor.id) }
                        .buttonStyle(ActionButtonStyle(tint: AppTheme.amber))
                } else if !isCurrent {
                    Button("切换") { model.switchAccount(to: monitor.id) }
                        .buttonStyle(ActionButtonStyle(tint: AppTheme.aqua))
                }

                Button {
                    accountToRemove = monitor.account
                } label: {
                    Image(systemName: "trash")
                        .scaledFont(size: 9, weight: .semibold)
                }
                .buttonStyle(ActionButtonStyle(tint: AppTheme.rose))
                .help("移除这个账号")
            }
        }
        .padding(.vertical, 10)
    }

    private func accountSubtitle(_ monitor: AccountMonitor) -> String {
        var parts = [monitor.account.tokenHint]
        if monitor.account.isSubAccount {
            parts.append("子账号")
        }
        if monitor.authFailure == nil {
            parts.append("\(monitor.instances.count) 台实例")
            if monitor.balance != nil {
                parts.append("余额 \(monitor.balanceLabel)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func commitRename(_ monitor: AccountMonitor) {
        model.renameAccount(monitor.id, to: draftName)
        editingAccountID = nil
    }

    private var appearanceCard: some View {
        SettingsCard(
            title: "界面字号",
            symbol: "textformat.size",
            tint: AppTheme.violet
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("全局字号")
                            .scaledFont(size: 11.5, weight: .semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text("整个界面的文字会按比例缩放")
                            .scaledFont(size: 9.5)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    Spacer()
                    Text("\(Int((model.fontScale * 100).rounded()))%")
                        .scaledFont(size: 11, weight: .bold)
                        .foregroundStyle(AppTheme.aqua)
                        .monospacedDigit()
                }

                ChoiceChips(
                    choices: fontScaleChoices,
                    isSelected: { abs(model.fontScale - $0) < 0.001 },
                    label: { "\(Int(($0 * 100).rounded()))%" },
                    tint: AppTheme.aqua,
                    select: { model.setFontScale($0) }
                )
            }
        }
    }

    private var balanceCard: some View {
        SettingsCard(
            title: "账户余额",
            symbol: model.isLowBalance ? "exclamationmark.circle.fill" : "yensign.circle.fill",
            tint: model.isLowBalance ? AppTheme.amber : AppTheme.mint
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(model.balanceLabel)
                        .scaledFont(size: 24, weight: .semibold)
                        .foregroundStyle(model.isLowBalance ? AppTheme.amber : AppTheme.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())

                    Text("可用资金")
                        .scaledFont(size: 9.5, weight: .medium)
                        .foregroundStyle(AppTheme.textTertiary)

                    Spacer()

                    StatusPill(
                        label: model.isLowBalance ? "余额偏低" : "余额充足",
                        tint: model.isLowBalance ? AppTheme.amber : AppTheme.mint
                    )
                }

                VStack(spacing: 9) {
                    SettingRow(label: "现金余额", value: model.balance?.formattedCash ?? "—", mono: true)
                    SettingRow(label: "代金券", value: model.balance?.formattedVoucher ?? "—", mono: true)
                    SettingRow(label: "冻结余额", value: model.balance?.formattedBlocked ?? "—", mono: true)
                }
                .padding(12)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.05), lineWidth: 0.6)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("余额不足提醒阈值")
                            .scaledFont(size: 10, weight: .medium)
                            .foregroundStyle(AppTheme.textSecondary)
                        Spacer()
                        Text(AccountBalance.currency(model.lowBalanceThreshold))
                            .scaledFont(size: 10, weight: .bold)
                            .foregroundStyle(AppTheme.amber)
                            .monospacedDigit()
                    }

                    ChoiceChips(
                        choices: balanceThresholdChoices,
                        isSelected: { abs(model.lowBalanceThreshold - $0) < 0.001 },
                        label: { AccountBalance.currency($0) },
                        tint: AppTheme.amber,
                        select: { model.setLowBalanceThreshold($0) }
                    )
                }

                if let error = model.balanceError {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.exclamationmark")
                            .scaledFont(size: 9, weight: .semibold)
                        Text("余额同步失败：\(error)")
                            .lineLimit(2)
                    }
                    .scaledFont(size: 9.5, weight: .medium)
                    .foregroundStyle(AppTheme.rose)
                }

                HStack(spacing: 8) {
                    Button {
                        model.refreshNow()
                    } label: {
                        HStack(spacing: 5) {
                            if model.isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                                    .scaleEffect(0.75)
                            }
                            Text(model.isRefreshing ? "同步中…" : "刷新余额")
                        }
                    }
                    .buttonStyle(ActionButtonStyle(tint: .white))
                    .disabled(model.isRefreshing)

                    Spacer()

                    Text("更新于 \(AppFormat.relative(model.balance?.fetchedAt))")
                        .scaledFont(size: 8.5, weight: .medium)
                        .foregroundStyle(AppTheme.textTertiary)
                }

                Text("余额低于阈值时提醒一次；余额恢复后，下一次低于阈值会重新提醒。")
                    .scaledFont(size: 9)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationCard: some View {
        SettingsCard(
            title: "通知权限",
            symbol: notificationSymbol,
            tint: notifications.authorizationStatus == .denied ? AppTheme.rose : AppTheme.amber
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("空闲卡与自动开机提醒")
                        .scaledFont(size: 11.5, weight: .medium)
                        .foregroundStyle(AppTheme.textSecondary)
                    Spacer()
                    StatusPill(label: notificationLabel, tint: notificationTint)
                }

                Text("关闭自动开机时，目标主机一旦出现空闲卡就会提醒；自动开机成功和余额不足时也会通知。请保持胡闹AutoDL 在运行。")
                    .scaledFont(size: 10)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        handleNotificationAction()
                    } label: {
                        Text(notificationActionLabel)
                    }
                    .buttonStyle(ActionButtonStyle(tint: notificationTint, prominent: true))

                    Button {
                        model.sendTestNotification()
                    } label: {
                        Text("发送测试")
                    }
                    .buttonStyle(ActionButtonStyle(tint: .white))
                    .disabled(notifications.authorizationStatus == .denied)
                    .opacity(notifications.authorizationStatus == .denied ? 0.45 : 1)
                }
            }
        }
    }

    private var automationCard: some View {
        SettingsCard(
            title: "监控与自动开机",
            symbol: "bolt.badge.clock.fill",
            tint: AppTheme.mint
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("自动开机")
                            .scaledFont(size: 11.5, weight: .semibold)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(model.autoStartSubtitle)
                            .scaledFont(size: 9.5)
                            .foregroundStyle(AppTheme.textTertiary)
                    }
                    Spacer()
                    CustomSwitch(isOn: model.autoStartEnabled) {
                        model.setAutoStart(!model.autoStartEnabled)
                    }
                }

                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 0.6)

                VStack(alignment: .leading, spacing: 9) {
                    Text("检查频率")
                        .scaledFont(size: 10, weight: .medium)
                        .foregroundStyle(AppTheme.textSecondary)

                    ChoiceChips(
                        choices: intervalChoices,
                        isSelected: { model.pollInterval == $0 },
                        label: { "\(Int($0)) 秒" },
                        tint: AppTheme.mint,
                        select: { model.setPollInterval($0) }
                    )
                }

                Text("抢占依赖轮询，建议 10–15 秒。1–3 秒仅建议短时间抢卡使用，过于频繁可能触发 AutoDL 接口限流。")
                    .scaledFont(size: 9.5)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationSymbol: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional: return "bell.fill"
        case .denied: return "bell.slash.fill"
        case .notDetermined: return "bell.badge.fill"
        @unknown default: return "bell.fill"
        }
    }

    private var notificationLabel: String {
        switch notifications.authorizationStatus {
        case .authorized: return "已开启"
        case .provisional: return "临时开启"
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

    private var notificationActionLabel: String {
        switch notifications.authorizationStatus {
        case .denied: return "打开系统设置"
        case .notDetermined: return "允许通知"
        default: return "打开通知设置"
        }
    }

    private func handleNotificationAction() {
        switch notifications.authorizationStatus {
        case .notDetermined:
            model.requestNotifications()
        default:
            model.openNotificationSettings()
        }
    }
}

enum SettingsGroup: String, CaseIterable, Identifiable {
    case account
    case alerts
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号"
        case .alerts: return "提醒"
        case .appearance: return "外观"
        }
    }

    var hint: String {
        switch self {
        case .account: return "登录 · 多账号"
        case .alerts: return "轮询 · 余额 · 通知"
        case .appearance: return "字号"
        }
    }
}

private struct SettingsGroupItem: View {
    let group: SettingsGroup
    let isSelected: Bool
    let needsAttention: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isSelected ? "▍" : " ")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(AppTheme.mint)

                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .scaledFont(size: 12.5, weight: isSelected ? .bold : .medium)
                        .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    Text(group.hint)
                        .scaledFont(size: 10)
                        .foregroundStyle(AppTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if needsAttention {
                    Text("●")
                        .scaledFont(size: 9)
                        .foregroundStyle(AppTheme.amber)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                .white.opacity(isSelected ? 0.07 : (hovered ? 0.04 : 0)),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    let content: Content

    init(
        title: String,
        symbol: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 20)

                Text(title)
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }
            .padding(.bottom, 18)

            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panel()
    }
}

private struct ChoiceChips: View {
    let choices: [Double]
    let isSelected: (Double) -> Bool
    let label: (Double) -> String
    let tint: Color
    let select: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(choices, id: \.self) { value in
                let selected = isSelected(value)
                let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
                Button {
                    select(value)
                } label: {
                    Text(label(value))
                        .scaledFont(size: 10, weight: .semibold)
                        .foregroundStyle(selected ? Color.black.opacity(0.8) : AppTheme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(selected ? tint : Color.white.opacity(0.045), in: shape)
                        .overlay {
                            if !selected {
                                shape.strokeBorder(.white.opacity(0.06), lineWidth: 0.6)
                            }
                        }
                        .contentShape(shape)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct SettingRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack {
            Text(label)
                .scaledFont(size: 10, weight: .medium)
                .foregroundStyle(AppTheme.textSecondary)
            Spacer()
            Text(value)
                .scaledFont(size: 9.5, weight: .semibold, design: mono ? .monospaced : .default)
                .foregroundStyle(AppTheme.textPrimary.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
