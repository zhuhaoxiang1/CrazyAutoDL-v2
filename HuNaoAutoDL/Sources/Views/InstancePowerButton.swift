import AppKit
import SwiftUI

/// Start / stop controls for one instance. A stopped instance gets two start buttons: GPU and no-card.
/// Stopping asks first: with auto-start on, the instance would be taken back.
struct InstancePowerButton: View {
    @EnvironmentObject private var model: AppModel
    let instance: AutoDLInstance

    private var isActing: Bool { model.isBusy(instance.id) }
    private var isDisabled: Bool { isActing || instance.state.isBusy || instance.state == .unknown }

    var body: some View {
        HStack(spacing: 6) {
            if instance.state.isPoweredOff {
                noCardButton
            }
            mainButton
        }
    }

    private var mainButton: some View {
        Button {
            if instance.state == .running {
                confirmStopAndPowerOff()
            } else {
                model.powerOn(instance: instance)
            }
        } label: {
            HStack(spacing: 5) {
                if isActing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: instance.state == .running ? "stop.fill" : "play.fill")
                        .scaledFont(size: 10, weight: .bold)
                }
                Text(
                    instance.state == .running
                        ? "关机"
                        : (instance.state.isBusy ? instance.state.label : "开机")
                )
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(
            ActionButtonStyle(
                tint: instance.state == .running ? AppTheme.rose : AppTheme.mint,
                prominent: instance.state != .running
            )
        )
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .help(instance.state == .running ? "关机" : "用 GPU 开机（按 GPU 计费）")
    }

    private var noCardButton: some View {
        Button {
            if Self.confirmNoCardIfNeeded(instanceName: instance.name) {
                model.powerOn(instance: instance, noCard: true)
            }
        } label: {
            Text("无卡")
                .frame(minWidth: 30)
        }
        .buttonStyle(ActionButtonStyle(tint: AppTheme.aqua))
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .help("无卡模式开机：不分配 GPU，只开机器，用来传数据、改环境，计费更低")
    }

    /// Until a no-card boot has been seen to really come up as `non_gpu`, the request parameter is unproven.
    static func confirmNoCardIfNeeded(instanceName: String) -> Bool {
        guard !UserDefaults.standard.bool(forKey: AccountMonitor.noCardVerifiedKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "用无卡模式开机 \(instanceName)？"
        alert.informativeText = """
        无卡开机用到的接口参数还没在你的账号上验证过。如果 AutoDL 没有认它，实例可能会按 GPU 模式开机并按 GPU 计费。

        开机后胡闹AutoDL 会自动检查实例的实际模式：确认是无卡就不再询问；如果发现是 GPU 模式，会立刻提醒你关机。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "无卡开机")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmStopAndPowerOff() {
        let alert = NSAlert()
        alert.messageText = "关闭 \(instance.name)？"
        alert.informativeText = "关机后如果自动开机已开启，胡闹AutoDL 会在目标主机出现空闲卡时再次开机。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关机")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            model.powerOff(instance: instance)
        }
    }
}
