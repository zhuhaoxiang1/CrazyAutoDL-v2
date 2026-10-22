import SwiftUI

/// What the user can do in one region: their instances there (can the home machine start? can it be cloned?)
/// and every model that currently has idle cards.
struct RegionPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var market: MarketStore
    let regionSign: String
    let regionName: String

    @State private var expandedModels: Set<String> = []
    @State private var customModel = ""

    private var mine: [AutoDLInstance] {
        model.instances.filter { market.canonicalSign(for: $0.regionSign) == regionSign }
    }

    private var snapshot: RegionSnapshot? { market.regionSnapshots[regionSign] }

    /// The instance the cards are judged against: the monitor target if it lives here, otherwise the first one.
    private var focus: AutoDLInstance? {
        mine.first { $0.id == model.selectedInstanceID } ?? mine.first
    }

    private var requiredCards: Int { focus?.gpuCount ?? 1 }

    private var myModels: Set<String> { Set(mine.map(\.gpuName)) }
    private var myMachines: Set<String> { Set(mine.map { $0.machineID.lowercased() }) }

    var body: some View {
        VStack(spacing: 14) {
            instancesSection
            rulesSection
            modelsSection
        }
    }

    // MARK: My instances in this region

    private var instancesSection: some View {
        TermSection("本区我的实例") {
            Text(mine.isEmpty ? "无" : "\(mine.count) 台")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)
        } content: {
            if mine.isEmpty {
                Text("你在这个区没有实例。可以在下面挑一张有空闲的卡，再去 AutoDL 把实例克隆过来。")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(mine.enumerated()), id: \.element.id) { index, instance in
                        if index > 0 {
                            Rectangle().fill(AppTheme.border.opacity(0.6)).frame(height: 1)
                        }
                        RegionInstanceRow(
                            instance: instance,
                            isTarget: instance.id == model.selectedInstanceID,
                            verdict: verdict(for: instance),
                            home: snapshot?.machine(withID: instance.machineID),
                            ownIdle: ownMachineIdle(for: instance),
                            targetTotal: instance.id == model.selectedInstanceID ? model.stock?.totalGPUs : nil,
                            onSelect: { model.selectInstance(instance.id) }
                        )
                    }
                }
                .padding(.vertical, -4)
            }
        }
    }

    /// Idle cards on the instance's own machine that it can actually start on. The instance already owns its
    /// instance slot, so a full slot count does not matter, but the machine has to be online.
    private func ownMachineIdle(for instance: AutoDLInstance) -> Int {
        if let snapshot {
            guard let home = snapshot.machine(withID: instance.machineID) else { return 0 }
            return home.isOnline ? home.gpuIdle : 0
        }
        return instance.homeIdle ?? 0
    }

    struct Verdict {
        let label: String
        let tint: Color
    }

    /// Answers "can I get a card in this region?" for one instance, from the home machine outwards.
    private func verdict(for instance: AutoDLInstance) -> Verdict {
        switch instance.state {
        case .running where !instance.isNoCardMode:
            return Verdict(label: "运行中 · 占用 GPU", tint: AppTheme.mint)
        case .running:
            // No-card mode holds no GPU, so judge whether a GPU start would work, like a stopped instance.
            guard let snapshot else { return Verdict(label: "无卡运行 · 未占用 GPU", tint: AppTheme.aqua) }
            let idle = ownMachineIdle(for: instance)
            if idle >= instance.gpuCount {
                return Verdict(label: "无卡运行 · 本机有 \(idle) 张空卡，关机后可用 GPU 开机", tint: AppTheme.aqua)
            }
            return Verdict(label: "无卡运行 · 本机暂无空卡", tint: AppTheme.aqua)
        case .starting, .stopping: return Verdict(label: instance.state.label, tint: AppTheme.amber)
        case .unknown: return Verdict(label: "状态未知", tint: AppTheme.violet)
        case .stopped: break
        }
        guard let snapshot else {
            return Verdict(label: market.regionErrors[regionSign] == nil ? "扫描中…" : "扫描失败", tint: AppTheme.textTertiary)
        }

        let homeIdle = ownMachineIdle(for: instance)
        if homeIdle >= instance.gpuCount {
            return Verdict(label: "本机有 \(homeIdle) 张空卡 · 可直接开机", tint: AppTheme.mint)
        }

        let sameModel = snapshot.rentableMachines.filter {
            $0.gpuName == instance.gpuName
                && $0.id.lowercased() != instance.machineID.lowercased()
                && $0.gpuIdle >= instance.gpuCount
        }
        if !sameModel.isEmpty {
            return Verdict(label: "本机已满 · 本区另有 \(sameModel.count) 台 \(instance.gpuName) 可克隆", tint: AppTheme.aqua)
        }
        if snapshot.models.contains(where: { $0.bestSingleMachine >= instance.gpuCount }) {
            return Verdict(label: "本区没有空的 \(instance.gpuName) · 可换型号克隆", tint: AppTheme.amber)
        }
        return Verdict(label: "本区暂无可用空卡", tint: AppTheme.rose)
    }

    // MARK: Alert rules

    private var rules: [RegionAlertRule] { market.rules(in: regionSign) }

    private func addRule(_ gpuName: String) {
        market.addRule(regionSign: regionSign, regionName: regionName, gpuName: gpuName, minCards: requiredCards)
        model.requestNotificationAccessIfNeeded()
    }

    /// Models that can be added, with the region's idle/total counts. Comes from AutoDL's own model list for the
    /// region, so names are spelled exactly as the alerts need them. Falls back to guesses if that list is missing.
    private var addableModels: [(name: String, detail: String)] {
        let taken = Set(rules.map(\.gpuName))
        if let types = market.gpuTypesByRegion[regionSign]?.filter({ !$0.isCPUOnly }), !types.isEmpty {
            return types
                .filter { !taken.contains($0.name) }
                .map { ($0.name, "空闲 \($0.idle) / 共 \($0.total)") }
        }
        var seen = Set<String>()
        let all = (snapshot?.models.map(\.gpuName) ?? []) + Array(myModels).sorted() + MarketStore.suggestions
        return all.filter { !taken.contains($0) && seen.insert($0).inserted }.map { ($0, "") }
    }

    private var rulesSection: some View {
        TermSection("区域通知 · \(regionName)") {
            Text(rules.isEmpty ? "未设置" : "\(rules.count) 条规则 · 后台每 25 秒扫描")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if rules.isEmpty {
                    Text("选一个或几个型号，它们在本区出现空卡时通知你（单机至少 N 张，一次出现只提醒一次）。")
                        .scaledFont(size: 12)
                        .foregroundStyle(AppTheme.textTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                        ForEach(rules) { rule in
                            ruleChip(rule)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Menu {
                        ForEach(addableModels, id: \.name) { item in
                            Button(item.detail.isEmpty ? item.name : "\(item.name)    \(item.detail)") { addRule(item.name) }
                        }
                    } label: {
                        Text("+ 添加型号")
                            .scaledFont(size: 11, weight: .medium)
                            .foregroundStyle(AppTheme.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .overlay {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(AppTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()

                    TextField("输入型号名回车添加", text: $customModel)
                        .textFieldStyle(.plain)
                        .scaledFont(size: 11)
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 8)
                        .frame(width: 176, height: 26)
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(AppTheme.border, lineWidth: 1)
                        }
                        .onSubmit {
                            addRule(customModel)
                            customModel = ""
                        }
                        .help("型号名需与 AutoDL 一致，例如 RTX 4090、vGPU-48GB。写错只会一直没有提醒。")

                    Text(market.gpuTypesByRegion[regionSign] == nil ? "型号列表加载中，也可以手输" : "下拉里是本区真实存在的型号，没有空卡的也能先加")
                        .scaledFont(size: 10.5)
                        .foregroundStyle(AppTheme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func ruleChip(_ rule: RegionAlertRule) -> some View {
        let hits = market.matches(for: rule)
        let scanFailure = market.ruleScanStatus[rule.id]?.lastError
        let live = !hits.isEmpty && scanFailure == nil
        return HStack(spacing: 8) {
            Text(live ? "●" : "○")
                .scaledFont(size: 10)
                .foregroundStyle(live ? AppTheme.mint : AppTheme.textTertiary)
            Text(rule.gpuName)
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                let steps = [1, 2, 4, 8]
                let next = steps.first { $0 > rule.minCards } ?? 1
                market.setMinCards(id: rule.id, next)
            } label: {
                Text("≥\(rule.minCards) 卡")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(AppTheme.aqua)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(AppTheme.aqua.opacity(0.4), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("单机至少 \(rule.minCards) 张空闲才提醒，点击切换 1 / 2 / 4 / 8")
            Text(scanFailure != nil
                 ? (hits.isEmpty ? "扫描失败" : "数据过期 · 上次 \(hits.count) 台")
                 : (live ? "现有 \(hits.count) 台" : "暂无"))
                .scaledFont(size: 10.5)
                .foregroundStyle(scanFailure != nil ? AppTheme.amber : (live ? AppTheme.mint : AppTheme.textTertiary))
                .help(scanFailure.map { "最近一次扫描失败：\($0)。显示的是上一次成功的结果，不再是实时数据。" } ?? "")
            Button {
                market.removeRule(id: rule.id)
            } label: {
                Text("×")
                    .scaledFont(size: 13, weight: .bold)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("删除这条规则")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(live ? AppTheme.mint.opacity(0.4) : AppTheme.border, lineWidth: 1)
        }
    }

    // MARK: Models with idle cards

    private var modelsSection: some View {
        TermSection("本区空闲显卡 · 按型号") {
            if market.loadingRegions.contains(regionSign) {
                Text("扫描中…")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(AppTheme.amber)
            } else if let snapshot {
                let pools = market.groupSigns(for: regionSign).count
                Text("\(pools > 1 ? "含 \(pools) 个池 · " : "")\(snapshot.idleGPUs) 张 · \(snapshot.machines.count) 台 · 更新于 \(AppFormat.time.string(from: snapshot.fetchedAt))")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
            }
        } content: {
            if let snapshot {
                if snapshot.models.isEmpty {
                    Text("这个区现在没有任何空闲显卡。")
                        .scaledFont(size: 12)
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                } else {
                    modelTable(snapshot)
                }
            } else if let error = market.regionErrors[regionSign] {
                Text("扫描失败：\(error)")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.rose)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                Text("正在扫描这个区的空闲显卡…")
                    .scaledFont(size: 12)
                    .foregroundStyle(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            }
        }
    }

    private func modelTable(_ snapshot: RegionSnapshot) -> some View {
        // Models of my own instances first, then by idle cards.
        let models = snapshot.models.sorted {
            let a = myModels.contains($0.gpuName), b = myModels.contains($1.gpuName)
            if a != b { return a }
            return ($0.idleGPUs, $1.gpuName) > ($1.idleGPUs, $0.gpuName)
        }
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 14)
                columnTitle("型号").frame(width: 170, alignment: .leading)
                columnTitle("空闲卡").frame(width: 56, alignment: .trailing)
                columnTitle("台数").frame(width: 44, alignment: .trailing)
                columnTitle("单机最多").frame(width: 72, alignment: .trailing)
                columnTitle("最低价").frame(width: 76, alignment: .trailing)
                columnTitle("克隆 ≥\(requiredCards) 卡").frame(width: 100, alignment: .leading)
                columnTitle("通知").frame(width: 36, alignment: .center)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)

            ForEach(models) { item in
                Rectangle().fill(AppTheme.border.opacity(0.7)).frame(height: 1)
                modelRow(item)
                if expandedModels.contains(item.id) {
                    machineList(item)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(AppTheme.textTertiary)
            .lineLimit(1)
    }

    private func modelRow(_ item: ModelSummary) -> some View {
        let mineHere = myModels.contains(item.gpuName)
        let fits = item.bestSingleMachine >= requiredCards
        return HStack(spacing: 12) {
            Text(expandedModels.contains(item.id) ? "▾" : "▸")
                .foregroundStyle(AppTheme.textTertiary)
                .frame(width: 14)
            HStack(spacing: 6) {
                if mineHere {
                    Text("◆").foregroundStyle(AppTheme.mint)
                }
                Text(item.gpuName)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 170, alignment: .leading)
            Text("\(item.idleGPUs)")
                .fontWeight(.bold)
                .foregroundStyle(fits ? AppTheme.mint : AppTheme.amber)
                .frame(width: 56, alignment: .trailing)
            Text("\(item.machineCount)")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 44, alignment: .trailing)
            Text("\(item.bestSingleMachine)")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 72, alignment: .trailing)
            Text(item.cheapest.map { String(format: "¥%.2f/h", $0) } ?? "—")
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 76, alignment: .trailing)
            Text(fits ? "✓ 可克隆" : "分散")
                .fontWeight(.semibold)
                .foregroundStyle(fits ? AppTheme.mint : AppTheme.amber)
                .frame(width: 100, alignment: .leading)
                .help(fits ? "单机最多 \(item.bestSingleMachine) 张空闲，够 \(requiredCards) 卡实例" : "空闲卡分散在多台机器上，单机最多 \(item.bestSingleMachine) 张")
            bell(for: item.gpuName)
                .frame(width: 36)
            Spacer(minLength: 0)
        }
        .scaledFont(size: 12)
        .monospacedDigit()
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) {
                if expandedModels.contains(item.id) { expandedModels.remove(item.id) } else { expandedModels.insert(item.id) }
            }
        }
    }

    private func bell(for gpuName: String) -> some View {
        let existing = market.rule(regionSign: regionSign, gpuName: gpuName)
        return Button {
            if let existing {
                market.removeRule(id: existing.id)
            } else {
                addRule(gpuName)
            }
        } label: {
            Image(systemName: existing == nil ? "bell" : "bell.fill")
                .scaledFont(size: 12, weight: .semibold)
                .foregroundStyle(existing == nil ? AppTheme.textTertiary : AppTheme.amber)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(existing == nil ? "\(gpuName) 在本区出现空卡时通知我" : "已开启通知（≥\(existing?.minCards ?? 1) 卡），点击关闭")
    }

    private func machineList(_ item: ModelSummary) -> some View {
        let machines = item.machines.sorted { ($0.gpuIdle, $1.id) > ($1.gpuIdle, $0.id) }
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(machines.prefix(14)) { machine in
                let isMine = myMachines.contains(machine.id.lowercased())
                HStack(spacing: 12) {
                    Text(isMine ? "◆" : " ")
                        .foregroundStyle(AppTheme.mint)
                        .frame(width: 14)
                    Text(machine.alias)
                        .foregroundStyle(isMine ? AppTheme.mint : AppTheme.textSecondary)
                        .lineLimit(1)
                        .frame(width: 120, alignment: .leading)
                    AsciiBar(
                        fraction: machine.gpuNumber > 0 ? Double(machine.gpuIdle) / Double(machine.gpuNumber) : 0,
                        cells: max(machine.gpuNumber, 1),
                        tint: machine.gpuIdle >= requiredCards ? AppTheme.mint : AppTheme.amber,
                        size: 11.5
                    )
                    Text("\(machine.gpuIdle)/\(machine.gpuNumber) 空闲")
                        .foregroundStyle(AppTheme.textSecondary)
                        .frame(width: 86, alignment: .leading)
                    Text(machine.hourlyPrice.map { String(format: "¥%.2f/h", $0) } ?? "—")
                        .foregroundStyle(AppTheme.textTertiary)
                    if isMine {
                        Text("你的本机")
                            .foregroundStyle(AppTheme.mint)
                    }
                    Spacer(minLength: 0)
                }
                .scaledFont(size: 11.5)
                .monospacedDigit()
            }
            if machines.count > 14 {
                Text("… 还有 \(machines.count - 14) 台")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
                    .padding(.leading, 26)
            }
        }
        .padding(.leading, 26)
    }
}

/// `◎ ● name  GPU ×n  [slots 2/8]  verdict  [action]`
private struct RegionInstanceRow: View {
    let instance: AutoDLInstance
    let isTarget: Bool
    let verdict: RegionPanel.Verdict
    let home: MarketMachine?
    let ownIdle: Int
    let targetTotal: Int?
    let onSelect: () -> Void

    @State private var hovered = false

    private var slotTotal: Int? { instance.homeTotal ?? home?.gpuNumber ?? targetTotal }
    private var slotIdle: Int { ownIdle }

    var body: some View {
        HStack(spacing: 14) {
            Text(isTarget ? "◎" : " ")
                .foregroundStyle(AppTheme.mint)
                .frame(width: 12)
            Text(instance.isNoCardMode ? "◌" : "●")
                .scaledFont(size: 10)
                .foregroundStyle(instance.statusTint)
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text("\(instance.gpuName) ×\(instance.gpuCount)\(instance.isNoCardMode ? " · 无卡" : "")")
                    .scaledFont(size: 10.5)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            slotBar
                .frame(width: 190, alignment: .leading)

            Text(verdict.label)
                .fontWeight(.semibold)
                .foregroundStyle(verdict.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            InstancePowerButton(instance: instance)
        }
        .scaledFont(size: 12)
        .monospacedDigit()
        .padding(.vertical, 8)
        .background(.white.opacity(isTarget ? 0.035 : (hovered ? 0.025 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .help("主机 \(instance.machineID.isEmpty ? "待同步" : instance.machineID) · \(instance.chargeLabel)\n释放 \(instance.releaseLabel)\n内存 \(instance.memoryFreeLabel) · 存储 \(instance.storageFreeLabel) 剩余\n点击设为监控目标")
    }

    /// Home machine's cards: how many of them are idle right now.
    @ViewBuilder
    private var slotBar: some View {
        if instance.holdsGPU {
            Text("占用中")
                .foregroundStyle(AppTheme.textTertiary)
        } else if let total = slotTotal, total > 0 {
            let idle = slotIdle
            HStack(spacing: 8) {
                AsciiBar(
                    fraction: Double(idle) / Double(total),
                    cells: total,
                    tint: idle >= instance.gpuCount ? AppTheme.mint : AppTheme.textTertiary,
                    size: 12
                )
                Text("\(idle)/\(total)")
                    .foregroundStyle(idle >= instance.gpuCount ? AppTheme.mint : AppTheme.textTertiary)
            }
            .help("本机共 \(total) 张卡，现在空闲 \(idle) 张")
        } else {
            Text(instance.homeIdle == nil && home == nil ? "本机 0 空闲" : "—")
                .foregroundStyle(AppTheme.textTertiary)
        }
    }
}
