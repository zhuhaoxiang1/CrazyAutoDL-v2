import SwiftUI

/// Cross-region GPU availability: one row per watched model, one column per region pool.
struct MarketView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        MarketContent(market: model.market)
    }
}

private struct MarketContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var market: MarketStore
    @State private var expanded: Set<String> = []
    @State private var newName = ""

    private static let refreshInterval: UInt64 = 20_000_000_000

    /// Models of the account's own instances come first and can't be removed; the user's extras follow.
    private var pinnedNames: [String] {
        var seen = Set<String>()
        return (model.current?.instances ?? []).map(\.gpuName).filter { seen.insert($0).inserted }
    }

    private var watchedNames: [String] {
        var seen = Set<String>()
        return (pinnedNames + market.watchlist).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private var chargeType: String {
        model.selectedInstance?.chargeType.isEmpty == false ? (model.selectedInstance?.chargeType ?? "payg") : "payg"
    }

    /// (model, region) pairs where the account already has an instance, marked `◆` in the matrix.
    private var ownedSpots: Set<String> {
        Set((model.current?.instances ?? []).map { "\($0.gpuName)|\($0.regionSign)" })
    }

    private func requiredCards(for gpuName: String) -> Int {
        (model.current?.instances ?? []).filter { $0.gpuName == gpuName }.map(\.gpuCount).max() ?? 1
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 14) {
                header
                watchBar
                matrix
                legend
            }
            .padding(.bottom, 22)
        }
        .scrollIndicators(.never)
        .task {
            await market.loadCatalogIfNeeded(account: model.current?.account)
        }
        .task(id: watchedNames.joined(separator: "|")) {
            while !Task.isCancelled {
                await market.refresh(account: model.current?.account, gpuNames: watchedNames, chargeType: chargeType)
                try? await Task.sleep(nanoseconds: Self.refreshInterval)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("算力市场")
                        .scaledFont(size: 22, weight: .semibold)
                        .foregroundStyle(AppTheme.textPrimary)
                    if market.isLoading {
                        StatusPill(label: "扫描中", tint: AppTheme.amber)
                    } else if let fetched = market.snapshot?.fetchedAt {
                        StatusPill(label: "更新于 \(AppFormat.time.string(from: fetched))", tint: AppTheme.mint)
                    }
                }
                Text("$ scan --models \(watchedNames.count) --regions all   # 只统计至少有 1 张空闲卡的机器，页面打开时每 20 秒刷新")
                    .scaledFont(size: 11)
                    .foregroundStyle(AppTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            IconButton(
                symbol: "arrow.clockwise",
                action: {
                    Task {
                        await market.refresh(
                            account: model.current?.account,
                            gpuNames: watchedNames,
                            chargeType: chargeType
                        )
                    }
                },
                isActive: market.isLoading,
                help: "立即扫描"
            )
        }
    }

    // MARK: Watch list

    private var watchBar: some View {
        HStack(spacing: 8) {
            Text("关注")
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.textTertiary)

            ForEach(watchedNames, id: \.self) { name in
                watchChip(name, pinned: pinnedNames.contains(name))
            }

            Menu {
                // AutoDL's own model list when loaded (spelled correctly, with idle/total); guesses otherwise.
                let real = market.allGPUTypes.filter { !$0.isCPUOnly && !watchedNames.contains($0.name) }
                if real.isEmpty {
                    ForEach(MarketStore.suggestions.filter { !watchedNames.contains($0) }, id: \.self) { name in
                        Button(name) { market.add(name) }
                    }
                } else {
                    ForEach(real) { type in
                        Button("\(type.name)    空闲 \(type.idle) / 共 \(type.total)") { market.add(type.name) }
                    }
                }
            } label: {
                Text("+ 添加型号")
                    .scaledFont(size: 11, weight: .medium)
                    .foregroundStyle(AppTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(AppTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            TextField("输入型号名回车添加", text: $newName)
                .textFieldStyle(.plain)
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textPrimary)
                .padding(.horizontal, 8)
                .frame(width: 168, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(AppTheme.border, lineWidth: 1)
                }
                .onSubmit {
                    market.add(newName)
                    newName = ""
                }
                .help("型号名需与 AutoDL 一致，例如 RTX 4090、A100-SXM4-80GB")

            Spacer(minLength: 0)
        }
    }

    private func watchChip(_ name: String, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            if pinned {
                Text("◆")
                    .scaledFont(size: 9)
                    .foregroundStyle(AppTheme.mint)
            }
            Text(name)
                .scaledFont(size: 11, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
            if !pinned {
                Button {
                    market.remove(name)
                } label: {
                    Text("×")
                        .scaledFont(size: 12, weight: .bold)
                        .foregroundStyle(AppTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("移除")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(AppTheme.border, lineWidth: 1)
        }
        .help(pinned ? "你的实例使用的型号，自动关注" : name)
    }

    // MARK: Matrix

    @ViewBuilder
    private var matrix: some View {
        if let snapshot = market.snapshot {
            let rows = watchedNames.compactMap { name in snapshot.rows.first { $0.gpuName == name } }
            let regions = MarketSnapshot(rows: rows, fetchedAt: snapshot.fetchedAt).regions
            TermSection("空闲矩阵 · 型号 × 区域") {
                Text("\(rows.reduce(0) { $0 + $1.idleGPUs }) 张空闲")
                    .scaledFont(size: 11, weight: .semibold)
                    .foregroundStyle(AppTheme.mint)
            } content: {
                if rows.isEmpty {
                    emptyHint("还没有关注的型号。")
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                        GridRow {
                            columnTitle("型号")
                                .frame(width: 150, alignment: .leading)
                            ForEach(regions) { region in
                                VStack(alignment: .leading, spacing: 1) {
                                    columnTitle(region.name)
                                    Text(region.sign)
                                        .scaledFont(size: 10)
                                        .foregroundStyle(AppTheme.textTertiary)
                                }
                                .frame(minWidth: 84, maxWidth: .infinity, alignment: .leading)
                            }
                            columnTitle("合计")
                                .frame(width: 56, alignment: .trailing)
                            columnTitle("最低价")
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.bottom, 8)

                        ForEach(rows) { row in
                            Divider().gridCellColumns(regions.count + 3).overlay(AppTheme.border)

                            GridRow {
                                rowTitle(row)
                                    .frame(width: 150, alignment: .leading)
                                ForEach(regions) { region in
                                    cell(row: row, region: region)
                                        .frame(minWidth: 84, maxWidth: .infinity, alignment: .leading)
                                }
                                Text("\(row.idleGPUs)")
                                    .scaledFont(size: 13, weight: .bold)
                                    .foregroundStyle(row.idleGPUs > 0 ? AppTheme.textPrimary : AppTheme.textTertiary)
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                                Text(row.cheapest.map { String(format: "¥%.2f/h", $0) } ?? "—")
                                    .scaledFont(size: 12, weight: .medium)
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .monospacedDigit()
                                    .frame(width: 76, alignment: .trailing)
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(row.id) }

                            if expanded.contains(row.id) {
                                machineList(row)
                                    .gridCellColumns(regions.count + 3)
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                }
            }
        } else {
            TermSection("空闲矩阵 · 型号 × 区域") {
                emptyHint(market.isLoading ? "正在扫描各区余量…" : "登录后会在这里显示各型号、各区的空闲 GPU。")
            }
        }
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(AppTheme.textTertiary)
            .lineLimit(1)
    }

    private func rowTitle(_ row: MarketRow) -> some View {
        HStack(spacing: 7) {
            Text(expanded.contains(row.id) ? "▾" : "▸")
                .scaledFont(size: 11)
                .foregroundStyle(AppTheme.textTertiary)
            Text(row.gpuName)
                .scaledFont(size: 12.5, weight: .semibold)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if row.error != nil {
                Text("!")
                    .scaledFont(size: 12, weight: .bold)
                    .foregroundStyle(AppTheme.rose)
                    .help(row.error ?? "")
            }
        }
    }

    @ViewBuilder
    private func cell(row: MarketRow, region: MarketRegion) -> some View {
        let owned = ownedSpots.contains("\(row.gpuName)|\(region.sign)")
        if let cell = row.cell(in: region.sign) {
            let required = requiredCards(for: row.gpuName)
            let fits = cell.bestSingleMachine >= required
            let tint = fits ? AppTheme.mint : AppTheme.amber
            HStack(spacing: 6) {
                if owned {
                    Text("◆")
                        .scaledFont(size: 9)
                        .foregroundStyle(AppTheme.mint)
                }
                Text("\(cell.idleGPUs)")
                    .scaledFont(size: 15, weight: .bold)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                Text("/\(cell.machineCount)台")
                    .scaledFont(size: 10.5)
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .help(
                fits
                    ? "\(region.name)：单机最多 \(cell.bestSingleMachine) 张空闲，可满足 \(required) 卡实例"
                    : "\(region.name)：共 \(cell.idleGPUs) 张空闲但分散在多台机器，单机最多 \(cell.bestSingleMachine) 张，凑不齐 \(required) 卡"
            )
        } else {
            HStack(spacing: 6) {
                if owned {
                    Text("◆")
                        .scaledFont(size: 9)
                        .foregroundStyle(AppTheme.mint)
                }
                Text("·")
                    .scaledFont(size: 14)
                    .foregroundStyle(AppTheme.textTertiary.opacity(0.6))
            }
        }
    }

    private func machineList(_ row: MarketRow) -> some View {
        let machines = row.machines.sorted { ($0.gpuIdle, $1.id) > ($1.gpuIdle, $0.id) }
        return VStack(alignment: .leading, spacing: 5) {
            if machines.isEmpty {
                Text(row.error.map { "查询失败：\($0)" } ?? "目前没有空闲的 \(row.gpuName)。")
                    .scaledFont(size: 11.5)
                    .foregroundStyle(row.error == nil ? AppTheme.textTertiary : AppTheme.rose)
            }
            ForEach(machines) { machine in
                HStack(spacing: 14) {
                    Text(machine.regionName)
                        .frame(width: 84, alignment: .leading)
                    Text(machine.alias)
                        .frame(width: 84, alignment: .leading)
                        .lineLimit(1)
                    AsciiBar(
                        fraction: machine.gpuNumber > 0 ? Double(machine.gpuIdle) / Double(machine.gpuNumber) : 0,
                        cells: max(machine.gpuNumber, 1),
                        tint: machine.gpuIdle >= requiredCards(for: row.gpuName) ? AppTheme.mint : AppTheme.amber,
                        size: 11.5
                    )
                    Text("\(machine.gpuIdle)/\(machine.gpuNumber) 空闲")
                        .frame(width: 86, alignment: .leading)
                    Text(machine.hourlyPrice.map { String(format: "¥%.2f/h", $0) } ?? "—")
                        .frame(width: 70, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .scaledFont(size: 11.5)
                .foregroundStyle(AppTheme.textSecondary)
                .monospacedDigit()
            }
        }
        .padding(.leading, 20)
        .padding(.top, 2)
    }

    private func toggle(_ id: String) {
        withAnimation(.easeOut(duration: 0.15)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            legendItem("◆", AppTheme.mint, "你的实例所在区")
            legendItem("12", AppTheme.mint, "单机空闲卡 ≥ 你的实例卡数，可直接克隆")
            legendItem("12", AppTheme.amber, "有空闲但分散，凑不齐")
            legendItem("n台", AppTheme.textTertiary, "有空闲卡的机器数")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private func legendItem(_ mark: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(mark)
                .scaledFont(size: 11, weight: .bold)
                .foregroundStyle(tint)
            Text(text)
                .scaledFont(size: 10.5)
                .foregroundStyle(AppTheme.textTertiary)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .scaledFont(size: 12)
            .foregroundStyle(AppTheme.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 70)
    }
}
