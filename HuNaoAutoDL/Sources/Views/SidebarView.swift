import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 18)
                .padding(.top, 20)
                .padding(.bottom, 22)

            divider

            VStack(spacing: 2) {
                ForEach(SidebarSection.allCases) { section in
                    SidebarItem(
                        section: section,
                        isSelected: model.selectedSection == section) {
                        model.selectedSection = section
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer(minLength: 24)

            accountCard
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .panel()
    }

    private var brand: some View {
        HStack(spacing: 11) {
            BrandMark(size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("胡闹AutoDL")
                    .scaledFont(size: 14, weight: .bold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("$ gpu-sentinel")
                    .scaledFont(size: 10)
                    .foregroundStyle(AppTheme.mint.opacity(0.8))
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(AppTheme.border)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }

    private var accountCard: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.monitors) { monitor in
                    Button {
                        model.switchAccount(to: monitor.id)
                    } label: {
                        if monitor.id == model.current?.id {
                            Label(menuTitle(for: monitor), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: monitor))
                        }
                    }
                }
                Divider()
                Button("添加账号…") {
                    model.beginAddAccount()
                }
                Button("管理账号…") {
                    model.selectedSection = .settings
                }
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.currentAccountName)
                            .scaledFont(size: 10, weight: .semibold)
                            .foregroundStyle(AppTheme.textPrimary.opacity(0.88))
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(balanceTint)
                                .frame(width: 4, height: 4)
                            Text(model.balance == nil ? "余额同步中" : "余额 \(model.balanceLabel)")
                                .scaledFont(size: 8.5, weight: .medium)
                                .foregroundStyle(model.isLowBalance ? AppTheme.amber.opacity(0.88) : AppTheme.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if otherAccountNeedsLogin {
                        Circle()
                            .fill(AppTheme.amber)
                            .frame(width: 6, height: 6)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .scaledFont(size: 8.5, weight: .semibold)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(accountHelp)

            Button {
                model.selectedSection = .settings
            } label: {
                Image(systemName: "gearshape.fill")
                    .scaledFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 25, height: 25)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func menuTitle(for monitor: AccountMonitor) -> String {
        if monitor.authFailure != nil {
            return "\(monitor.account.name) · 需重新登录"
        }
        if monitor.balance != nil {
            return "\(monitor.account.name) · \(monitor.balanceLabel)"
        }
        return monitor.account.name
    }

    private var otherAccountNeedsLogin: Bool {
        model.monitors.contains { $0.id != model.current?.id && $0.authFailure != nil }
    }

    private var accountHelp: String {
        var lines = ["切换账号或添加新账号"]
        if let balance = model.balance {
            lines.append("现金 \(balance.formattedCash) · 代金券 \(balance.formattedVoucher) · 冻结 \(balance.formattedBlocked)")
        }
        if otherAccountNeedsLogin {
            lines.append("有账号需要重新登录")
        }
        return lines.joined(separator: "\n")
    }

    private var balanceTint: Color {
        guard model.balance != nil else { return AppTheme.textTertiary }
        return model.isLowBalance ? AppTheme.amber : AppTheme.mint
    }
}

private struct SidebarItem: View {
    let section: SidebarSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: section.symbol)
                    .scaledFont(size: 12.5, weight: .semibold)
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)
                    .frame(width: 22)

                Text(section.title)
                    .scaledFont(size: 12.5, weight: isSelected ? .semibold : .medium)
                    .foregroundStyle(isSelected ? AppTheme.textPrimary : AppTheme.textSecondary)

                Spacer()

            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                .white.opacity(isSelected ? 0.07 : (hovered ? 0.04 : 0)),
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(AppTheme.mint)
                        .frame(width: 2, height: 18)
                }
            }
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}
