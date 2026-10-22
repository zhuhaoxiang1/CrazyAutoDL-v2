import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppTheme.pageBackground
                .ignoresSafeArea()

            content

            WindowConfigurator()
                .frame(width: 0, height: 0)

            MenuBarBridge()
                .frame(width: 0, height: 0)
        }
        .frame(minWidth: 1_180, minHeight: 720)
        .preferredColorScheme(.dark)
        .environment(\.appFontScale, CGFloat(model.fontScale))
        .animation(.easeOut(duration: 0.2), value: model.phase)
        .overlay(alignment: .topTrailing) {
            if let toast = model.toast {
                ToastBanner(toast: toast) {
                    model.dismissToast(toast)
                }
                .padding(.top, 52)
                .padding(.trailing, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast?.id)
        .task {
            model.notifications.activate()
            model.startRegionWatch()
            await model.notifications.refreshAuthorizationStatus()
        }
    }

    /// `--panel-preview` shows the menu bar panel in the main window; a popover can't be screenshotted.
    private static let panelPreview = ProcessInfo.processInfo.arguments.contains("--panel-preview")

    @ViewBuilder
    private var content: some View {
        if Self.panelPreview {
            QuickPanelView(onOpenDashboard: {}, onOpenConsole: {}, onRefresh: { model.refreshNow() }, onQuit: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 50)
        } else {
            phaseContent
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .checking:
            BootView()
                .transition(.opacity)
        case .loggedOut:
            AuthView()
                .transition(.opacity)
        case .signedIn:
            if model.isShowingAuth {
                AuthView()
                    .transition(.opacity)
            } else {
                mainShell
                    .transition(.opacity)
            }
        }
    }

    private var mainShell: some View {
        HStack(spacing: 14) {
            SidebarView()

            Group {
                switch model.selectedSection {
                case .dashboard:
                    DashboardView()
                case .market:
                    MarketView()
                case .billing:
                    BillingView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 46)
        .padding(.bottom, 16)
    }
}

private struct BootView: View {
    var body: some View {
        VStack(spacing: 14) {
            BrandMark(size: 56)
            ProgressView()
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ToastBanner: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle()
                    .fill(toast.kind.tint.opacity(0.13))
                    .frame(width: 34, height: 34)
                Image(systemName: toast.kind.symbol)
                    .scaledFont(size: 13, weight: .semibold)
                    .foregroundStyle(toast.kind.tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .scaledFont(size: 12, weight: .semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(toast.message)
                    .scaledFont(size: 10)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .scaledFont(size: 8, weight: .bold)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(.white.opacity(0.045), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(13)
        .frame(width: 348, alignment: .leading)
        .panel()
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
