import Foundation

/// この Mac の中の LLM サーバー（Ollama・LM Studio など）に入っているモデルを調べる（azooKey Medical で追加）
public enum LocalModelList {
    /// 設定画面に並べるモデルの候補（Ollama の名前）
    public struct CatalogEntry: Sendable, Hashable, Identifiable {
        public var id: String { name }
        /// Ollama のモデル名
        public let name: String
        /// 表示名
        public let title: String
        /// ダウンロードの大きさ（GB、ollama.com の表示。2026-10-24 時点）
        public let downloadGB: Double
        /// このメモリ（GB）以上の Mac 向け
        public let memoryGB: Int
        /// 向き不向き。2026-10-24 の比較（質疑応答とメールを中心にした13問）で試していないものは「未評価」
        public let note: String
    }

    public static let catalog: [CatalogEntry] = [
        CatalogEntry(name: "gemma4:e2b-it-qat", title: "Gemma 4 E2B", downloadGB: 4.3, memoryGB: 8, note: "メール・敬語・英訳・誤字直しは正確。医療の知識は弱め"),
        CatalogEntry(name: "gemma4:e4b-it-qat", title: "Gemma 4 E4B", downloadGB: 6.1, memoryGB: 16, note: "13問ほぼ正確"),
        CatalogEntry(name: "gemma4:12b-it-qat", title: "Gemma 4 12B", downloadGB: 7.2, memoryGB: 24, note: "未評価"),
        CatalogEntry(name: "gemma4:26b-a4b-it-qat", title: "Gemma 4 26B A4B", downloadGB: 16, memoryGB: 32, note: "未評価"),
        CatalogEntry(name: "gemma4:31b-it-qat", title: "Gemma 4 31B", downloadGB: 19, memoryGB: 48, note: "未評価"),
        CatalogEntry(name: "qwen3.5:4b-q4_K_M", title: "Qwen 3.5 4B", downloadGB: 3.3, memoryGB: 8, note: "誤りが多め（薬の名前を取り違えるなど）"),
        CatalogEntry(name: "qwen3.5:9b-q4_K_M", title: "Qwen 3.5 9B", downloadGB: 6.6, memoryGB: 16, note: "未評価"),
    ]

    /// chat/completions の接続先から、同じサーバーの別の道（path）の URL を作る。この Mac の中のサーバーでなければエラー
    static func serverURL(chatEndpoint: String, path: String) throws -> URL {
        guard var components = URLComponents(string: chatEndpoint) else {
            throw OpenAIError.invalidURL
        }
        components.path = path
        components.query = nil
        guard let url = components.url else {
            throw OpenAIError.invalidURL
        }
        guard LocalEndpointPolicy.isAllowed(url) else {
            throw LocalOnlyError.nonLocalEndpoint(chatEndpoint)
        }
        return url
    }

    /// chat/completions の接続先から、モデルの一覧（OpenAI 互換の /v1/models）を取る
    public static func fetch(chatEndpoint: String) async throws -> [String] {
        guard let components = URLComponents(string: chatEndpoint) else {
            throw OpenAIError.invalidURL
        }
        var basePath = components.path
        while basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let suffix = "/chat/completions"
        let path = basePath.hasSuffix(suffix) ? String(basePath.dropLast(suffix.count)) + "/models" : "/v1/models"
        let url = try serverURL(chatEndpoint: chatEndpoint, path: path)
        let (data, response) = try await LocalEndpointPolicy.session.data(for: URLRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.noServerResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw OpenAIError.invalidResponseStatus(code: httpResponse.statusCode, body: String(bytes: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
        // 文章がこの Mac の外へ送られるモデル（Ollama のクラウドのモデル）は一覧に出さない
        let remote = await remoteModelNames(chatEndpoint: chatEndpoint) ?? []
        return models.filter { !isCloudModelName($0) && !remote.contains(canonicalName($0)) }.sorted()
    }

    /// Ollama のクラウドのモデルの名前か（例: gpt-oss:120b-cloud、gemma4:cloud）。
    /// このモデルを頼むと、この Mac の Ollama が文章を ollama.com へ送る
    public static func isCloudModelName(_ name: String) -> Bool {
        let tag = name.lowercased().split(separator: "/").last.map(String.init) ?? name.lowercased()
        return tag.hasSuffix(":cloud") || tag.hasSuffix("-cloud")
    }

    /// 文章がこの Mac の外へ送られるモデルか。名前に加えて、Ollama の一覧（/api/tags）で外のサーバーを指すモデルも調べる
    public static func isRemoteModel(_ name: String, chatEndpoint: String) async -> Bool {
        if isCloudModelName(name) {
            return true
        }
        guard let remote = await remoteModelNames(chatEndpoint: chatEndpoint) else {
            return false
        }
        return remote.contains(canonicalName(name))
    }

    private static let remoteCache = RemoteModelCache()

    /// Ollama の一覧で、外のサーバーを指すモデル（remote_host か remote_model があるもの）の名前。Ollama でなければ nil。
    /// 送るたびに問い合わせないよう、1分間は前の結果を使う
    static func remoteModelNames(chatEndpoint: String) async -> Set<String>? {
        if let cached = await remoteCache.value(for: chatEndpoint) {
            return cached
        }
        guard let url = try? serverURL(chatEndpoint: chatEndpoint, path: "/api/tags") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await LocalEndpointPolicy.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return nil
        }
        var remote = Set<String>()
        for model in models {
            let host = model["remote_host"] as? String ?? ""
            let remoteModel = model["remote_model"] as? String ?? ""
            guard !host.isEmpty || !remoteModel.isEmpty, let name = (model["name"] as? String) ?? (model["model"] as? String) else {
                continue
            }
            remote.insert(canonicalName(name))
        }
        await remoteCache.set(remote, for: chatEndpoint)
        return remote
    }

    /// 接続先が Ollama かどうか（モデルを入れる機能は Ollama のときだけ使える）
    public static func isOllama(chatEndpoint: String) async -> Bool {
        guard let url = try? serverURL(chatEndpoint: chatEndpoint, path: "/api/version") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await LocalEndpointPolicy.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["version"] is String
    }

    /// Ollama がいまメモリに読み込んでいるモデルの名前。Ollama でなければ nil
    public static func loadedModels(chatEndpoint: String) async -> [String]? {
        guard let url = try? serverURL(chatEndpoint: chatEndpoint, path: "/api/ps") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, response) = try? await LocalEndpointPolicy.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return nil
        }
        return models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
    }

    /// Ollama の名前をそろえる（タグを省いた名前は latest を指す）
    public static func canonicalName(_ name: String) -> String {
        let last = name.split(separator: "/").last.map(String.init) ?? name
        return last.contains(":") ? name : name + ":latest"
    }

    /// モデルを Ollama に入れる（ダウンロードは Ollama が行う）。onProgress には状態の文と、分かれば 0〜1 の進み具合を渡す
    public static func pull(model: String, chatEndpoint: String, onProgress: @Sendable (String, Double?) async -> Void) async throws {
        let url = try serverURL(chatEndpoint: chatEndpoint, path: "/api/pull")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await LocalEndpointPolicy.session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            // 失敗のときも、Ollama は理由を {"error": ...} で返す
            for try await line in bytes.lines {
                if let data = line.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let error = json["error"] as? String {
                    throw PullError.server(error)
                }
            }
            throw OpenAIError.noServerResponse
        }
        // 部品（layer）ごとの大きさと、受け取った量
        var totals: [String: Double] = [:]
        var completed: [String: Double] = [:]
        var shownFraction: Double?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let error = json["error"] as? String {
                throw PullError.server(error)
            }
            let status = json["status"] as? String ?? ""
            if let digest = json["digest"] as? String, let total = json["total"] as? Double {
                totals[digest] = total
                completed[digest] = json["completed"] as? Double ?? 0
            }
            let sum = totals.values.reduce(0, +)
            if sum > 0 {
                // 新しい部品が見つかると全体の大きさが増えるので、表示が戻らないよう大きい方を使う
                shownFraction = max(shownFraction ?? 0, completed.values.reduce(0, +) / sum)
            }
            await onProgress(status, shownFraction)
            if status == "success" {
                return
            }
        }
        throw PullError.incomplete
    }

    public enum PullError: LocalizedError, Sendable {
        case server(String)
        case incomplete

        public var errorDescription: String? {
            switch self {
            case .server(let message):
                return "Ollama がエラーを返しました: \(message)"
            case .incomplete:
                return "ダウンロードが途中で終わりました"
            }
        }
    }

    /// この Mac のメモリに合うおすすめのモデル（Ollama の名前）。
    /// 2026-10-24 の比較（質疑応答とメールを中心にした13問）で決めた。8GB の Mac は 8GB 用の候補の比較で決める
    public static func recommendedModel(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        let gigabytes = Double(physicalMemory) / 1_073_741_824
        if gigabytes <= 8.5 {
            return "gemma4:e2b-it-qat"
        }
        return "gemma4:e4b-it-qat"
    }

    /// この Mac のメモリの大きさ（GB、整数に丸める）
    public static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }
}

/// Ollama の一覧の問い合わせ結果を、接続先ごとに1分間だけ覚える
actor RemoteModelCache {
    private var entries: [String: (names: Set<String>, time: Date)] = [:]

    func value(for endpoint: String) -> Set<String>? {
        guard let entry = self.entries[endpoint], Date().timeIntervalSince(entry.time) < 60 else {
            return nil
        }
        return entry.names
    }

    func set(_ names: Set<String>, for endpoint: String) {
        self.entries[endpoint] = (names, Date())
    }
}
