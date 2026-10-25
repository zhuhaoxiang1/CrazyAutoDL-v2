import Foundation

struct AutoDLAPI {
    private let token: String
    private let session: URLSession
    let isSubAccount: Bool

    private static let baseURL = URL(string: "https://www.autodl.com/api/v1")!

    init(token: String, isSubAccount: Bool = false, session: URLSession? = nil) {
        self.token = token
        self.isSubAccount = isSubAccount
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    static func connect(
        token: String,
        preferSubAccount: Bool = false,
        session: URLSession? = nil
    ) async throws -> (api: AutoDLAPI, instances: [AutoDLInstance]) {
        let api = AutoDLAPI(token: token, isSubAccount: preferSubAccount, session: session)
        do {
            return (api, try await api.fetchInstances())
        } catch AutoDLError.api(_, let message) where !preferSubAccount && message.contains("无当前资源访问权限") {
            let subAccountAPI = AutoDLAPI(token: token, isSubAccount: true, session: session)
            return (subAccountAPI, try await subAccountAPI.fetchInstances())
        }
    }

    func fetchInstances(timeout: TimeInterval? = nil) async throws -> [AutoDLInstance] {
        let body: [String: Any] = [
            "date_from": "",
            "date_to": "",
            "page_index": 1,
            "page_size": 100,
            "status": [],
            "charge_type": []
        ]
        let json = try await post(path: "/instance", body: body, timeout: timeout)
        guard let data = json["data"] as? [String: Any],
              let rawList = data["list"] as? [[String: Any]]
        else {
            if let data = json["data"] as? [[String: Any]] {
                return data.compactMap(AutoDLInstance.parse)
            }
            throw AutoDLError.invalidResponse
        }
        return rawList.compactMap(AutoDLInstance.parse)
    }

    func fetchGPUStock(for instance: AutoDLInstance) async throws -> GPUStock {
        func stock(_ result: GPUStockParseResult?, incomplete: Bool = false) -> GPUStock {
            GPUStock(
                idleGPUs: result?.idleGPUs ?? 0,
                totalGPUs: result?.totalGPUs,
                machineID: instance.machineID,
                gpuName: instance.gpuName,
                requiredGPUs: instance.gpuCount,
                checkedAt: Date(),
                machineFound: result?.machineFound ?? false,
                instanceID: instance.id,
                incomplete: incomplete
            )
        }
        guard !instance.machineID.isEmpty else { return stock(nil) }

        // The target host can sit past the first page of a large region/model result, so keep paging until it is
        // found, the result set is exhausted, or the page cap is hit. A capped miss is reported as incomplete
        // rather than as "no free card".
        let pageSize = Self.stockPageSize
        var seen = 0
        for page in 1...Self.stockMaxPages {
            var body: [String: Any] = [
                "default_order": true,
                "gpu_idle_num": max(instance.gpuCount, 1),
                "page_index": page,
                "page_size": pageSize
            ]
            if !instance.gpuName.isEmpty {
                body["gpu_type_name"] = [instance.gpuName]
            }
            if !instance.regionSign.isEmpty {
                body["region_sign_list"] = [instance.regionSign]
            }
            if !instance.chargeType.isEmpty {
                body["charge_type"] = instance.chargeType
            }

            let json = try await post(path: "/user/machine/list", body: body)
            let result = Self.parseMachineStock(json: json, targetMachineID: instance.machineID)
            if result.machineFound { return stock(result) }

            seen += result.pageCount
            if let total = result.resultTotal {
                if seen >= total || result.pageCount == 0 { return stock(result) }
            } else if result.pageCount < pageSize {
                return stock(result)
            }
        }
        return stock(nil, incomplete: true)
    }

    static let stockPageSize = 100
    static let stockMaxPages = 10

    /// Every machine of one GPU model that has at least one idle card, across all regions.
    /// AutoDL rejects this query without a model filter (`DatabaseError`), so a model name is required.
    /// Only machines a new instance could land on are returned (see `MarketMachine.isRentable`).
    func fetchMarketMachines(gpuName: String, chargeType: String, regionSigns: [String] = []) async throws -> [MarketMachine] {
        var machines: [MarketMachine] = []
        var fetched = 0
        var page = 1
        while page <= 4 {
            var body: [String: Any] = [
                "default_order": true,
                "gpu_idle_num": 1,
                "page_index": page,
                "page_size": 500,
                "gpu_type_name": [gpuName]
            ]
            if !regionSigns.isEmpty {
                body["region_sign_list"] = regionSigns
            }
            if !chargeType.isEmpty {
                body["charge_type"] = chargeType
            }
            let json = try await post(path: "/user/machine/list", body: body)
            guard let data = json["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]]
            else { throw AutoDLError.invalidResponse }

            fetched += list.count
            machines += list.compactMap(MarketMachine.parse).filter(\.isRentable)

            let total = jsonInt(data["result_total"]) ?? fetched
            if list.isEmpty || fetched >= total { break }
            page += 1
        }
        return machines
    }

    /// Every region pool AutoDL runs. Public: needs no login.
    static func fetchRegionCatalog() async throws -> [CatalogRegion] {
        guard let url = URL(string: baseURL.absoluteString + "/common") else { throw AutoDLError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("HuNaoAutoDL/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        do {
            (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        } catch {
            throw AutoDLError.network(error.localizedDescription)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let list = payload["region_list"] as? [[String: Any]]
        else { throw AutoDLError.invalidResponse }
        return list.compactMap(CatalogRegion.parse)
    }

    /// Idle and total cards per GPU model across the given region pools, including models with nothing idle.
    /// Several pools in one request come back merged by model name. Requires login.
    func fetchGPUTypes(regionSigns: [String]) async throws -> [GPUTypeStat] {
        let json = try await post(path: "/machine/region/gpu_type", body: ["region_sign_list": regionSigns])
        guard json["data"] is [[String: Any]] else { throw AutoDLError.invalidResponse }
        return GPUTypeStat.parseList(json["data"])
    }

    /// Every machine in one region that has at least one idle card, all GPU models. Unlike the per-model query
    /// this needs no model name, so the region view can list whatever the region has.
    /// `regionSigns` is every pool of one data center. Returns the machines and how many pages that took.
    /// A page of 100 would need 15 requests for a big data center and silently miss machines past a page cap.
    func fetchRegionMachines(regionSigns: [String], chargeType: String) async throws -> (machines: [MarketMachine], pages: Int) {
        var machines: [MarketMachine] = []
        var page = 1
        // The server honours big pages (a 4-pool data center is ~1500 machines), so this is normally one request.
        while page <= 5 {
            var body: [String: Any] = [
                "default_order": true,
                "gpu_idle_num": 1,
                "page_index": page,
                "page_size": 2000,
                "region_sign_list": regionSigns
            ]
            if !chargeType.isEmpty {
                body["charge_type"] = chargeType
            }
            let json = try await post(path: "/user/machine/list", body: body)
            guard let data = json["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]]
            else { throw AutoDLError.invalidResponse }

            machines += list.compactMap(MarketMachine.parse)

            let total = jsonInt(data["result_total"]) ?? machines.count
            if list.isEmpty || machines.count >= total { break }
            page += 1
        }
        return (machines, min(page, 5))
    }

    /// `noCard` boots without a GPU. The `non_gpu` payload is inferred from the `start_mode` value the instance
    /// list reports and is not documented, so the caller must verify the resulting `start_mode`.
    func powerOn(instanceUUID: String, noCard: Bool = false) async throws {
        let body: [String: Any] = [
            "instance_uuid": instanceUUID,
            "payload": noCard ? "non_gpu" : "gpu"
        ]
        _ = try await post(path: "/instance/power_on", body: body)
    }

    func powerOff(instanceUUID: String) async throws {
        let body: [String: Any] = ["instance_uuid": instanceUUID]
        _ = try await post(path: "/instance/power_off", body: body)
    }

    /// The pieces of a source instance's image that a clone request repeats; `/instance/snapshot` is where the
    /// AutoDL console reads them before opening its own clone page.
    struct CloneImage {
        var baseImageUUID = ""
        var cgApplicationInfo: [String: Any] = [:]
    }

    func fetchCloneImage(instanceUUID: String) async throws -> CloneImage {
        let json = try await get(path: "/instance/snapshot", query: ["instance_uuid": instanceUUID])
        guard let data = json["data"] as? [String: Any],
              let image = data["image"] as? [String: Any]
        else { throw AutoDLError.invalidResponse }
        var result = CloneImage()
        // The console sends the public image's name only for public images; private / CodeWithGPU ones go by uuid.
        if jsonString(image["image_type"]) == "public" {
            result.baseImageUUID = jsonString(image["image_name"]) ?? ""
        }
        result.cgApplicationInfo = data["cg_application_info"] as? [String: Any] ?? [:]
        return result
    }

    /// Data disk (bytes) to ask for on the clone: always the source's own expansion, never less.
    static func cloneExpandBytes(source: AutoDLInstance, machine: MarketMachine) -> Int64? {
        source.expandDataDiskBytes
    }

    /// Whether `machine` can give the clone the same data disk the source has. A source without an expanded data
    /// disk fits anywhere; otherwise the machine must report an expansion limit that covers it. An unreported
    /// limit counts as "cannot confirm", so such a machine is not cloned onto.
    static func machineFitsCloneDisk(source: AutoDLInstance, machine: MarketMachine) -> Bool {
        guard let expansion = source.expandDataDiskBytes, expansion >= 0 else { return false }
        guard expansion > 0 else { return true }
        guard let cap = machine.maxDataDiskExpand else { return false }
        return cap >= expansion
    }

    /// The request body of the console's "克隆实例" page, pay-as-you-go, system disk + data disk, sparse-file
    /// optimisation on. Mirrors the field names the console's own page sends.
    static func cloneBody(source: AutoDLInstance, image: CloneImage, machine: MarketMachine) throws -> [String: Any] {
        guard let expand = cloneExpandBytes(source: source, machine: machine),
              machineFitsCloneDisk(source: source, machine: machine),
              machine.isRentable, machine.gpuIdle >= source.gpuCount else {
            throw AutoDLError.clonePrecondition("无法确认目标机器满足源实例的卡数和完整数据盘容量，不下单")
        }
        return [
            "instance_uuid": source.id,
            "instance_info": [
                "machine_id": machine.id,
                "charge_type": "payg",
                "req_gpu_amount": source.gpuCount,
                "base_image_uuid": image.baseImageUUID,
                "instance_name": "",
                "private_image_uuid": source.privateImageUUID,
                "reproduction_uuid": source.reproductionUUID,
                "cg_application_uuid": source.cgApplicationUUID,
                "cg_application_info": image.cgApplicationInfo,
                "expand_data_disk": expand,
                "copy_data_disk_after_clone": true,
                "keep_src_user_service_address_after_clone": false,
                "reproduction_id": source.reproductionID.map { $0 as Any } ?? NSNull(),
                "ft_sparse": true
            ] as [String: Any],
            "price_info": [
                "coupon_id_list": [String](),
                "machine_id": machine.id,
                "charge_type": "payg",
                "duration": 1,
                "num": source.gpuCount,
                "expand_data_disk": expand
            ] as [String: Any]
        ]
    }

    /// Orders a pay-as-you-go clone of `source` onto `machine` and returns the new instance's uuid.
    /// This creates a billed instance; callers must have an explicit opt-in from the user.
    func cloneInstance(source: AutoDLInstance, image: CloneImage, machine: MarketMachine) async throws -> String {
        let json = try await post(
            path: "/order/instance/clone/payg",
            body: try Self.cloneBody(source: source, image: image, machine: machine)
        )
        if let uuid = jsonString(json["data"]), !uuid.isEmpty { return uuid }
        if let data = json["data"] as? [String: Any], let uuid = jsonString(data["uuid"]), !uuid.isEmpty { return uuid }
        throw AutoDLError.invalidResponse
    }

    func instanceExists(uuid: String) async throws -> Bool {
        let json = try await get(path: "/instance/exist", query: ["instance_uuid": uuid])
        if let flag = json["data"] as? Bool { return flag }
        return (jsonInt(json["data"]) ?? 0) != 0
    }

    func fetchBalance() async throws -> AccountBalance {
        let json = try await get(path: "/wallet")
        guard let data = json["data"] as? [String: Any] else {
            throw AutoDLError.invalidResponse
        }

        // AutoDL 钱包接口以千分之一元为单位返回金额。
        let cash = (jsonDouble(data["assets"]) ?? jsonDouble(data["balance"]) ?? 0) / 1000
        let blocked = (jsonDouble(data["blocked_asset"]) ?? jsonDouble(data["blocked_assets"]) ?? 0) / 1000
        let voucher = (jsonDouble(data["voucher_balance"]) ?? jsonDouble(data["voucher"]) ?? 0) / 1000
        return AccountBalance(
            cash: cash,
            blocked: blocked,
            voucher: voucher,
            paymentMethod: jsonString(data["payment_method"]),
            fetchedAt: Date()
        )
    }

    func fetchBills(from start: Date, to end: Date) async throws -> [BillRecord] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = AppTime.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let dateFrom = formatter.string(from: start)
        let dateTo = formatter.string(from: end)

        var records: [BillRecord] = []
        var seen = Set<String>()
        var page = 1
        // 每小时结算一条流水，30 天最多约 720 条，分页取完。
        while page <= 6 {
            let body: [String: Any] = [
                "order_uuid": "",
                "sub_name": "",
                "date_from": dateFrom,
                "date_to": dateTo,
                "page_index": page,
                "page_size": 500,
                "bill_type": ""
            ]
            let json = try await post(path: "/bill/list", body: body)
            guard let data = json["data"] as? [String: Any],
                  let list = data["list"] as? [[String: Any]]
            else { throw AutoDLError.invalidResponse }

            for item in list {
                if let record = BillRecord.parse(item), seen.insert(record.id).inserted {
                    records.append(record)
                }
            }

            let total = jsonInt(data["result_total"]) ?? records.count
            if list.isEmpty || records.count >= total { break }
            page += 1
        }
        return records
    }

    private func get(path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        try await request(method: "GET", path: path, query: query, body: nil)
    }

    private func post(path: String, body: [String: Any], timeout: TimeInterval? = nil) async throws -> [String: Any] {
        try await request(method: "POST", path: path, body: body, timeout: timeout)
    }

    private func request(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]?,
        timeout: TimeInterval? = nil
    ) async throws -> [String: Any] {
        let accountPath = isSubAccount ? "/sub_user" + path : path
        guard var components = URLComponents(string: Self.baseURL.absoluteString + accountPath) else {
            throw AutoDLError.invalidResponse
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw AutoDLError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = max(0.01, min(timeout, 20)) }
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("HuNaoAutoDL/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AutoDLError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AutoDLError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw AutoDLError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AutoDLError.http(status: http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AutoDLError.invalidResponse
        }

        guard let code = jsonString(json["code"]) else { throw AutoDLError.invalidResponse }
        let message = jsonString(json["msg"]) ?? jsonString(json["message"]) ?? ""
        let success = code == "Success" || code == "success" || code == "0"
        guard success else {
            let error = AutoDLError.api(code: code, message: message)
            if error.isAuthFailure { throw AutoDLError.unauthorized }
            throw error
        }
        return json
    }

    private static func parseMachineStock(
        json: [String: Any],
        targetMachineID: String
    ) -> GPUStockParseResult {
        var machines: [[String: Any]] = []
        var resultTotal: Int?
        if let data = json["data"] as? [String: Any] {
            resultTotal = jsonInt(data["result_total"])
            if let list = data["list"] as? [[String: Any]] {
                machines = list
            } else if let list = data["machines"] as? [[String: Any]] {
                machines = list
            } else {
                machines = [data]
            }
        } else if let list = json["data"] as? [[String: Any]] {
            machines = list
        }

        let normalizedTarget = targetMachineID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let target = machines.first { machine in
            let raw = jsonString(machine["machine_id"])
                ?? jsonString(machine["machine_uuid"])
                ?? jsonString(machine["id"])
                ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget
        }

        guard let target else {
            return GPUStockParseResult(
                idleGPUs: 0,
                totalGPUs: nil,
                machineFound: false,
                pageCount: machines.count,
                resultTotal: resultTotal
            )
        }

        let idle = jsonInt(target["gpu_idle_num"])
            ?? jsonInt(target["idle_gpu_num"])
            ?? jsonInt(target["gpu_idle_count"])
            ?? 0
        let explicitTotal = jsonInt(target["gpu_all_num"])
            ?? jsonInt(target["gpu_total_num"])
            ?? jsonInt(target["total_gpu_num"])
        let possibleTotal = jsonInt(target["gpu_num"])
        let total = explicitTotal ?? possibleTotal.map { max($0, idle) }

        return GPUStockParseResult(
            idleGPUs: max(0, idle),
            totalGPUs: total,
            machineFound: true,
            pageCount: machines.count
        )
    }
}
