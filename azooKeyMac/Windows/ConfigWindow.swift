import Cocoa
import Core
import SwiftUI

struct ConfigWindow: View {
    @ConfigState private var liveConversion = Config.LiveConversion()
    @ConfigState private var multiLineLeftContext = Config.MultiLineLeftContext()
    @ConfigState private var useTypedHistory = Config.UseTypedHistory()
    @ConfigState private var useDocumentTitle = Config.UseDocumentTitle()
    @ConfigState private var useRightSideContext = Config.UseRightSideContext()
    @ConfigState private var medicalDictionary = Config.MedicalDictionary()
    @ConfigState private var medicalContextBoost = Config.MedicalContextBoost()
    @State private var selectionPromptShortcut: Core.KeyboardShortcut = Config.SelectionPromptShortcut().value
    @ConfigState private var selectionPromptEnabled = Config.SelectionPromptEnabled()
    @ConfigState private var controlSSuggestion = Config.ControlSSuggestion()
    /// 選んだ文の実行のキーに選べない組み合わせを選んだときの知らせ
    @State private var selectionPromptShortcutWarning: String?
    @ConfigState private var inputStyle = Config.InputStyle()
    @ConfigState private var typeBackSlash = Config.TypeBackSlash()
    @ConfigState private var punctuationStyle = Config.PunctuationStyle()
    @ConfigState private var typeHalfSpace = Config.TypeHalfSpace()
    @ConfigState private var optionDirectFullWidthInput = Config.OptionDirectFullWidthInput()
    @ConfigState private var zenzaiProfile = Config.ZenzaiProfile()
    @ConfigState private var openAiApiKey = Config.OpenAiApiKey()
    @ConfigState private var openAiModelName = Config.OpenAiModelName()
    @ConfigState private var openAiApiEndpoint = Config.OpenAiApiEndpoint()
    @ConfigState private var learning = Config.Learning()
    @ConfigState private var inferenceLimit = Config.ZenzaiInferenceLimit()
    @ConfigState private var debugWindow = Config.DebugWindow()
    @ConfigState private var debugPredictiveTyping = Config.DebugPredictiveTyping()
    @ConfigState private var debugTypoCorrection = Config.DebugTypoCorrection()
    @ConfigState private var userDictionary = Config.UserDictionary()
    @ConfigState private var systemUserDictionary = Config.SystemUserDictionary()
    @ConfigState private var keyboardLayout = Config.KeyboardLayout()
    @ConfigState private var aiBackend = Config.AIBackendPreference()

    @State private var selectedTab: Tab = .basic
    @State private var zenzaiProfileHelpPopover = false
    @State private var zenzaiInferenceLimitHelpPopover = false
    @State private var openAiApiKeyPopover = false
    @State private var connectionTestInProgress = false
    @State private var showingRomajiTableEditor = false
    @State private var connectionTestResult: String?
    @State private var localModels: [String] = []
    @State private var localModelsMessage: String?
    /// 接続先が Ollama か（モデルを入れる機能は Ollama のときだけ）
    @State private var endpointIsOllama = false
    /// いま入れているモデルと、その進み具合
    @State private var pullingModel: String?
    @State private var pullStatus: String?
    @State private var pullFraction: Double?
    @State private var pullTask: Task<Void, Never>?
    @State private var pullMessage: String?
    @State private var systemUserDictionaryUpdateMessage: SystemUserDictionaryUpdateMessage?
    /// azooKeyユーザ辞書の件数。辞書は別の画面で編集するので、保存されるたびに数え直す
    @State private var userDictionaryItemCount = Self.countUserDictionaryItems()
    @State private var showingLearningResetConfirmation = false
    @State private var learningResetMessage: LearningResetMessage?
    @State private var foundationModelsAvailability: FoundationModelsAvailability?
    @State private var availabilityCheckDone = false
    @State private var debugTypoCorrectionState: DebugTypoCorrectionState = .notDownloaded
    @State private var debugTypoCorrectionDownloadInProgress = false
    @State private var debugTypoCorrectionErrorMessage: String?

    private enum Tab: String, CaseIterable, Hashable {
        case basic = "基本"
        case customize = "カスタマイズ"
        case advanced = "詳細設定"

        var icon: String {
            switch self {
            case .basic: return "star"
            case .customize: return "slider.horizontal.3"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private enum LearningResetMessage {
        case success
        case error(String)
    }

    private enum SystemUserDictionaryUpdateMessage {
        case error(any Error)
        case successfulUpdate
    }

    private var azooKeyApplicationSupportDirectoryURL: URL {
        if #available(macOS 13, *) {
            URL.applicationSupportDirectory
                .appending(path: "azooKey", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("azooKey", isDirectory: true)
        }
    }

    private var debugTypoCorrectionModelDirectoryURL: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.azooKeyApplicationSupportDirectoryURL
        )
    }

    private var debugTypoCorrectionStatusText: String {
        if self.debugTypoCorrectionDownloadInProgress {
            return "ダウンロード中..."
        }
        switch self.debugTypoCorrectionState {
        case .downloaded:
            return "重み: ダウンロード済み"
        case .failed:
            return "重み: ダウンロード失敗"
        case .notDownloaded:
            return "重み: ダウンロード未実施"
        }
    }

    @MainActor
    private func refreshDebugTypoCorrectionState() async {
        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        let state = await Task.detached(priority: .utility) {
            DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
        }.value
        self.debugTypoCorrectionState = state
        if state != .failed {
            self.debugTypoCorrectionErrorMessage = nil
        }
    }

    @MainActor
    private func downloadDebugTypoCorrectionWeights() {
        guard !self.debugTypoCorrectionDownloadInProgress else {
            return
        }
        self.debugTypoCorrectionDownloadInProgress = true
        self.debugTypoCorrectionErrorMessage = nil

        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        Task {
            do {
                try await DebugTypoCorrectionWeights.downloadWeights(modelDirectoryURL: modelDirectoryURL)
                let state = await Task.detached(priority: .utility) {
                    DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
                }.value
                await MainActor.run {
                    self.debugTypoCorrectionState = state
                    self.debugTypoCorrectionErrorMessage = state == .failed ? "ダウンロード後の整合性チェックに失敗しました" : nil
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            } catch {
                await MainActor.run {
                    self.debugTypoCorrectionState = .failed
                    self.debugTypoCorrectionErrorMessage = error.localizedDescription
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            }
        }
    }

    private func openAzooKeyDataDirectoryInFinder() {
        do {
            try FileManager.default.createDirectory(
                at: self.azooKeyApplicationSupportDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([self.azooKeyApplicationSupportDirectoryURL])
        } catch {
            // no-op
        }
    }

    private func getErrorMessage(for error: OpenAIError) -> String {
        switch error {
        case .invalidURL:
            return "エラー: 無効なURL形式です"
        case .noServerResponse:
            return "エラー: サーバーから応答がありません"
        case .invalidResponseStatus(let code, let body):
            return getHTTPErrorMessage(code: code, body: body)
        case .parseError(let message):
            return "エラー: レスポンス解析失敗 - \(message)"
        case .invalidResponseStructure:
            return "エラー: 予期しないレスポンス形式"
        }
    }

    private func getHTTPErrorMessage(code: Int, body: String) -> String {
        switch code {
        case 401:
            return "エラー: APIキーが無効です"
        case 403:
            return "エラー: アクセスが拒否されました"
        case 404:
            return "エラー: エンドポイントが見つかりません"
        case 429:
            return "エラー: レート制限に達しました"
        case 500...599:
            return "エラー: サーバーエラー (コード: \(code))"
        default:
            return "エラー: HTTPステータス \(code)\n詳細: \(body.prefix(100))..."
        }
    }

    /// この Mac の LLM サーバーに入っているモデルの一覧を取り直す
    func refreshLocalModels() async {
        let endpoint = openAiApiEndpoint.value.isEmpty ? Config.OpenAiApiEndpoint.default : openAiApiEndpoint.value
        endpointIsOllama = await LocalModelList.isOllama(chatEndpoint: endpoint)
        do {
            localModels = try await LocalModelList.fetch(chatEndpoint: endpoint)
            localModelsMessage = localModels.isEmpty ? (endpointIsOllama ? "モデルが入っていません。下の「モデルを入れる」から入れてください" : "モデルが入っていません。LLM のアプリでモデルを入れてください") : nil
        } catch {
            localModels = []
            if case .invalidResponseStatus(let code, _)? = error as? OpenAIError, code == 401 || code == 403 {
                localModelsMessage = "このサーバーは API キーを求めています。azooKey Medical は、キーの要らないこの Mac の中のサーバーにだけ対応しています"
            } else if let localOnly = error as? LocalOnlyError {
                localModelsMessage = localOnly.localizedDescription
            } else {
                localModelsMessage = "ローカルLLMに接続できません。Ollama などが起動しているか確かめてください"
            }
        }
    }

    /// モデルの候補1行（入っていなければ「入れる」、入っていれば「使う」）
    @ViewBuilder
    private func modelCatalogRow(_ entry: LocalModelList.CatalogEntry) -> some View {
        let installed = localModels.map(LocalModelList.canonicalName).contains(LocalModelList.canonicalName(entry.name))
        let size = entry.downloadGB.rounded() == entry.downloadGB ? String(Int(entry.downloadGB)) : String(entry.downloadGB)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(entry.title)（\(entry.name)）")
                Text(verbatim: "ダウンロード \(size)GB・メモリ \(entry.memoryGB)GB 以上の Mac 向け。\(entry.note)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if LocalModelList.physicalMemoryGB < entry.memoryGB {
                    Text(verbatim: "この Mac（\(LocalModelList.physicalMemoryGB)GB）ではメモリが足りず、遅くなるか動きません")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if pullingModel == entry.name {
                    if let pullFraction {
                        ProgressView(value: pullFraction)
                    }
                    Text(verbatim: pullStatus ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if installed {
                if LocalModelList.canonicalName(openAiModelName.value) == LocalModelList.canonicalName(entry.name) {
                    Text("使用中")
                        .foregroundColor(.secondary)
                } else {
                    Button("使う") {
                        $openAiModelName.wrappedValue = entry.name
                    }
                }
            } else if pullingModel == entry.name {
                Button("中止") {
                    pullTask?.cancel()
                }
            } else {
                Button("入れる") {
                    startPull(entry.name)
                }
                .disabled(pullingModel != nil)
            }
        }
    }

    /// Ollama にモデルを入れて、終わったらそのモデルを使う
    private func startPull(_ name: String) {
        let endpoint = openAiApiEndpoint.value.isEmpty ? Config.OpenAiApiEndpoint.default : openAiApiEndpoint.value
        pullingModel = name
        pullStatus = "準備しています"
        pullFraction = nil
        pullMessage = nil
        pullTask = Task { @MainActor in
            do {
                try await LocalModelList.pull(model: name, chatEndpoint: endpoint) { status, fraction in
                    await MainActor.run {
                        pullFraction = fraction
                        pullStatus = Self.pullStatusText(status, fraction: fraction)
                    }
                }
                await refreshLocalModels()
                $openAiModelName.wrappedValue = name
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                pullMessage = cancelled ? "\(name) のダウンロードを中止しました（途中まで落とした分は Ollama が残します）" : "\(name) を入れられませんでした: \(error.localizedDescription)"
            }
            pullingModel = nil
            pullTask = nil
        }
    }

    /// Ollama が返す状態の文を、日本語の短い文にする
    private static func pullStatusText(_ status: String, fraction: Double?) -> String {
        switch status {
        case "pulling manifest":
            return "準備しています"
        case "verifying sha256 digest":
            return "ファイルを確かめています"
        case "writing manifest", "removing unused layers", "success":
            return "仕上げています"
        default:
            if let fraction {
                return "ダウンロード中 \(Int(fraction * 100))%"
            }
            return "ダウンロード中"
        }
    }

    func testConnection() async {
        connectionTestInProgress = true
        connectionTestResult = nil

        do {
            let testRequest = OpenAIRequest(
                prompt: "テスト",
                target: "",
                modelName: openAiModelName.value.isEmpty ? Config.OpenAiModelName.default : openAiModelName.value
            )
            _ = try await OpenAIClient.sendRequest(
                testRequest,
                apiKey: openAiApiKey.value.isEmpty ? "local" : openAiApiKey.value,
                apiEndpoint: openAiApiEndpoint.value
            )

            connectionTestResult = "接続成功"
        } catch let error as OpenAIError {
            connectionTestResult = getErrorMessage(for: error)
        } catch {
            connectionTestResult = "エラー: \(error.localizedDescription)"
        }

        connectionTestInProgress = false
    }

    @MainActor
    private func resetLearningData() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            learningResetMessage = .error("学習データのリセットに失敗しました")
            Task {
                try? await Task.sleep(for: .seconds(30))
                if case .error = learningResetMessage {
                    learningResetMessage = nil
                }
            }
            return
        }

        appDelegate.kanaKanjiConverter.resetMemory()
        learningResetMessage = .success

        // 10秒後にメッセージを消す
        Task {
            try? await Task.sleep(for: .seconds(10))
            if case .success = learningResetMessage {
                learningResetMessage = nil
            }
        }
    }

    /// 「追加」を押して何も入れなかった行は数えない
    private static func countUserDictionaryItems() -> Int {
        Config.UserDictionary().value.items.filter { !$0.isBlank }.count
    }

    @ViewBuilder
    private func helpButton(helpContent: LocalizedStringKey, isPresented: Binding<Bool>) -> some View {
        if #available(macOS 14, *) {
            Button("ヘルプ", systemImage: "questionmark") {
                isPresented.wrappedValue = true
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .popover(isPresented: isPresented) {
                Text(helpContent).padding()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // カスタムタブバー
            HStack(spacing: 4) {
                ForEach([Tab.basic, Tab.customize, Tab.advanced], id: \.self) { tab in
                    Button(
                        action: {
                            selectedTab = tab
                        },
                        label: {
                            HStack(spacing: 5) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(selectedTab == tab ? Color(nsColor: .controlAccentColor) : Color(nsColor: .secondaryLabelColor))
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ? .medium : .regular))
                                    .foregroundColor(selectedTab == tab ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedTab == tab ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(
                                        selectedTab == tab ? Color(nsColor: .separatorColor).opacity(0.5) : Color.clear,
                                        lineWidth: 0.5
                                    )
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                        }
                    )
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.3))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // コンテンツエリア（選択されたタブのみ表示）
            Group {
                if selectedTab == .basic {
                    basicTabView
                } else if selectedTab == .customize {
                    customizeTabView
                } else {
                    advancedTabView
                }
            }
        }
        .frame(width: 600, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main)) { _ in
            self.userDictionaryItemCount = Self.countUserDictionaryItems()
        }
        .sheet(isPresented: $showingRomajiTableEditor) {
            RomajiTableEditorWindow(base: CustomInputTableStore.loadTable()) { exported in
                do {
                    _ = try CustomInputTableStore.save(exported: exported)
                    CustomInputTableStore.registerIfExists()
                } catch {
                    print("Failed to save custom input table: \(error)")
                }
            }
        }
    }

    // MARK: - 基本タブ
    @ViewBuilder
    private var basicTabView: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    Picker("使う AI", selection: $aiBackend) {
                        Text("オフ").tag(Config.AIBackendPreference.Value.off)

                        if let availability = foundationModelsAvailability, !availability.isAvailable {
                            Text("Apple Intelligence（この Mac では使えません）").tag(Config.AIBackendPreference.Value.foundationModels)
                        } else {
                            Text("Apple Intelligence（Mac の中）").tag(Config.AIBackendPreference.Value.foundationModels)
                        }

                        Text("ローカルLLM（この Mac の中のサーバー）").tag(Config.AIBackendPreference.Value.openAI)
                    }
                    .onAppear {
                        if !availabilityCheckDone {
                            foundationModelsAvailability = FoundationModelsClientCompat.checkAvailability()
                            availabilityCheckDone = true

                            let hasSetAIBackend = UserDefaults.standard.bool(forKey: "hasSetAIBackendManually")
                            if !hasSetAIBackend,
                               aiBackend.value == .off,
                               let availability = foundationModelsAvailability,
                               availability.isAvailable {
                                aiBackend.value = .foundationModels
                                UserDefaults.standard.set(true, forKey: "hasSetAIBackendManually")
                            }

                            if aiBackend.value == .foundationModels,
                               let availability = foundationModelsAvailability,
                               !availability.isAvailable {
                                aiBackend.value = .off
                            }
                        }
                    }
                    .onChange(of: aiBackend.value) { _ in
                        UserDefaults.standard.set(true, forKey: "hasSetAIBackendManually")
                    }
                }

                Toggle("範囲を選んでキーを押すと、選んだ文をAIへの指示として実行する", isOn: $selectionPromptEnabled)
                HStack {
                    Text("選んだ文を指示として実行するキー")
                    Spacer()
                    KeyboardShortcutRecorder(shortcut: $selectionPromptShortcut, defaultShortcut: .defaultSelectionPromptShortcut)
                        .frame(width: 120, height: 24)
                }
                .disabled(!selectionPromptEnabled.value)
                .onChange(of: selectionPromptShortcut) { newValue in
                    // ⌃・⌥・⌘ のどれも使わない組み合わせ（Shift+A など）は、普段の入力を奪うので選べない
                    guard !newValue.modifiers.isDisjoint(with: [.control, .option, .command]) else {
                        selectionPromptShortcutWarning = "⌃・⌥・⌘ のどれかを含む組み合わせにしてください"
                        selectionPromptShortcut = Config.SelectionPromptShortcut().value
                        return
                    }
                    if newValue == Config.TransformShortcut().value {
                        selectionPromptShortcutWarning = "いい感じ変換と同じキーです。別のキーにしてください"
                        selectionPromptShortcut = Config.SelectionPromptShortcut().value
                        return
                    }
                    selectionPromptShortcutWarning = nil
                    Config.SelectionPromptShortcut().value = newValue
                }
                if let selectionPromptShortcutWarning {
                    Text(selectionPromptShortcutWarning)
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if selectionPromptShortcut == .systemContextMenuShortcut {
                    Text("Control+Return は macOS がメニューを出すのに使うため、IME に届きません。別のキーにしてください")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text(verbatim: "例: 「明日の打ち合わせの時間を確認するメールを書いて」を選んで \(selectionPromptShortcut.displayString)。範囲を選んでいないときは、キーはそのままアプリに渡ります。今ある文を書き直すときは、その文を選んで \(Config.TransformShortcut().value.displayString)（いい感じ変換）を押し、指示を打ちます。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("何も選んでいないときの \(Config.TransformShortcut().value.displayString) で、続きの文の候補をAIに出させる（元の azooKey の機能）", isOn: $controlSSuggestion)

                if aiBackend.value == .openAI {
                    HStack {
                        Text("Ollama や LM Studio などを、この Mac で動かしておいてください。IME はこの Mac の中のサーバーにだけ接続します。文章が外へ送られる Ollama のクラウドのモデル（名前が cloud で終わるもの）は使いません。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        helpButton(
                            helpContent: "OpenAI 互換の chat/completions に送ります。接続先は 127.0.0.1・localhost・::1 だけを受け付けます。",
                            isPresented: $openAiApiKeyPopover
                        )
                    }
                    HStack {
                        Picker("モデル", selection: $openAiModelName) {
                            ForEach(localModels, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            if !localModels.contains(openAiModelName.value) {
                                Text(openAiModelName.value.isEmpty ? "（未選択）" : openAiModelName.value).tag(openAiModelName.value)
                            }
                        }
                        Button("一覧を更新") {
                            Task {
                                await refreshLocalModels()
                            }
                        }
                    }
                    .onAppear {
                        Task {
                            await refreshLocalModels()
                        }
                    }
                    Text("この Mac（メモリ \(LocalModelList.physicalMemoryGB)GB）のおすすめ: \(LocalModelList.recommendedModel())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let localModelsMessage {
                        Text(localModelsMessage)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    if endpointIsOllama {
                        DisclosureGroup("モデルを入れる（Ollama）") {
                            ForEach(LocalModelList.catalog) { entry in
                                modelCatalogRow(entry)
                            }
                            Text("ダウンロードは Ollama が行います。入れたモデルは、上の「モデル」で切り替えられます。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if let pullMessage {
                                Text(pullMessage)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    TextField("モデル名（一覧にないとき）", text: $openAiModelName, prompt: Text("例: qwen3.5:4b-q4_K_M"))
                    TextField("接続先", text: $openAiApiEndpoint, prompt: Text("例: http://127.0.0.1:11434/v1/chat/completions"))
                        .help("Ollama: http://127.0.0.1:11434/v1/chat/completions\nLM Studio: http://127.0.0.1:1234/v1/chat/completions")

                    HStack {
                        Button("接続テスト") {
                            Task {
                                await testConnection()
                            }
                        }
                        .disabled(connectionTestInProgress)

                        if connectionTestInProgress {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    if let result = connectionTestResult {
                        Text(result)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label("AI（選んだ文の実行・いい感じ変換）", systemImage: "sparkles")
            }

            Section {
                LabeledContent {
                    HStack {
                        Text("\(self.userDictionaryItemCount)件のアイテム")
                        Button("編集") {
                            (NSApplication.shared.delegate as? AppDelegate)!.openUserDictionaryEditorWindow()
                        }
                    }
                } label: {
                    Text("azooKeyユーザ辞書")
                }
                LabeledContent {
                    HStack {
                        switch self.systemUserDictionaryUpdateMessage {
                        case .none:
                            if let updated = self.systemUserDictionary.value.lastUpdate {
                                let date = updated.formatted(date: .omitted, time: .omitted)
                                Text("最終更新: \(date) / \(self.systemUserDictionary.value.items.count)件のアイテム")
                            } else {
                                Text("未設定")
                            }
                        case .error(let error):
                            Text("読み込みエラー: \(error.localizedDescription)")
                        case .successfulUpdate:
                            Text("読み込みに成功しました / \(self.systemUserDictionary.value.items.count)件のアイテム")
                        }
                        Button("読み込む") {
                            do {
                                let systemUserDictionaryEntries = try SystemUserDictionaryHelper.fetchEntries()
                                self.systemUserDictionary.value.items = systemUserDictionaryEntries.map {
                                    .init(word: $0.phrase, reading: $0.shortcut)
                                }
                                self.systemUserDictionary.value.lastUpdate = .now
                                self.systemUserDictionaryUpdateMessage = .successfulUpdate
                            } catch {
                                self.systemUserDictionaryUpdateMessage = .error(error)
                            }
                        }
                        Button("リセット") {
                            self.systemUserDictionary.value.lastUpdate = nil
                            self.systemUserDictionary.value.items = []
                            self.systemUserDictionaryUpdateMessage = nil
                        }
                    }
                } label: {
                    Text("システムのユーザ辞書")
                }
            } header: {
                Label("ユーザ辞書", systemImage: "book.closed")
            }

            Section {
                Toggle("ライブ変換を有効化", isOn: $liveConversion)
                Toggle("前の行も文脈として使う", isOn: $multiLineLeftContext)
                Toggle("打った文章を覚えて文脈に使う（アプリが前の文章を返さないとき。メモリのみ）", isOn: $useTypedHistory)
                Toggle("ノートのタイトルも参考にする（実験的）", isOn: $useDocumentTitle)
                Toggle("カーソルの後ろの文章も参考にする（実験的）", isOn: $useRightSideContext)
                Toggle("医療用語の辞書を使う", isOn: $medicalDictionary)
                Toggle("医療の文脈では医療用語を強める（実験的）", isOn: $medicalContextBoost)
                HStack {
                    TextField("変換プロフィール", text: $zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                    helpButton(
                        helpContent: """
                    Zenzaiはあなたのプロフィールを考慮した変換を行うことができます。
                    名前や仕事、趣味などを入力すると、それに合わせた変換が自動で推薦されます。
                    （実験的な機能のため、精度が不十分な場合があります）
                    """,
                        isPresented: $zenzaiProfileHelpPopover
                    )
                }
            } header: {
                Label("変換設定", systemImage: "brain")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - カスタマイズタブ
    @ViewBuilder
    private var customizeTabView: some View {
        Form {
            Section {
                Toggle("円記号の代わりにバックスラッシュを入力", isOn: $typeBackSlash)
                Toggle("スペースは常に半角を入力", isOn: $typeHalfSpace)
                Toggle("Optionキーで直接全角英数を入力", isOn: $optionDirectFullWidthInput)
                Picker("句読点の種類", selection: $punctuationStyle) {
                    Text("、と。").tag(Config.PunctuationStyle.Value.`kutenAndToten`)
                    Text("、と．").tag(Config.PunctuationStyle.Value.periodAndToten)
                    Text("，と。").tag(Config.PunctuationStyle.Value.kutenAndComma)
                    Text("，と．").tag(Config.PunctuationStyle.Value.periodAndComma)
                }
            } header: {
                Label("入力オプション", systemImage: "character.cursor.ibeam")
            }

            Section {
                Picker("履歴学習", selection: $learning) {
                    Text("学習する").tag(Config.Learning.Value.inputAndOutput)
                    Text("学習を停止").tag(Config.Learning.Value.onlyOutput)
                    Text("学習を無視").tag(Config.Learning.Value.nothing)
                }
                LabeledContent {
                    HStack {
                        switch learningResetMessage {
                        case .none:
                            EmptyView()
                        case .success:
                            Text("履歴学習データをリセットしました")
                                .foregroundColor(.green)
                        case .error(let message):
                            Text("エラー: \(message)")
                                .foregroundColor(.red)
                        }
                        Spacer()
                        Button("リセット") {
                            showingLearningResetConfirmation = true
                        }
                        .confirmationDialog(
                            "履歴学習データをリセットしますか？",
                            isPresented: $showingLearningResetConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button("リセット", role: .destructive) {
                                resetLearningData()
                            }
                            Button("キャンセル", role: .cancel) {}
                        }
                    }
                } label: {
                    Text("履歴学習データ")
                }
            } header: {
                Label("学習", systemImage: "memorychip")
            }

            Section {
                Picker("入力方式", selection: $inputStyle) {
                    Text("デフォルト").tag(Config.InputStyle.Value.default)
                    Text("かな入力（JIS）").tag(Config.InputStyle.Value.defaultKanaJIS)
                    Text("かな入力（US）").tag(Config.InputStyle.Value.defaultKanaUS)
                    Text("AZIK").tag(Config.InputStyle.Value.defaultAZIK)
                    Text("カスタム").tag(Config.InputStyle.Value.custom)
                }
                if inputStyle.value == .custom {
                    LabeledContent {
                        Button("編集") {
                            showingRomajiTableEditor = true
                        }
                    } label: {
                        Text("カスタム入力テーブル")
                    }
                }
            } header: {
                Label("入力方式", systemImage: "keyboard")
            }

            Section {
                Picker("キーボード配列", selection: $keyboardLayout) {
                    Text("QWERTY").tag(Config.KeyboardLayout.Value.qwerty)
                    Text("Australian").tag(Config.KeyboardLayout.Value.australian)
                    Text("British").tag(Config.KeyboardLayout.Value.british)
                    Text("Colemak").tag(Config.KeyboardLayout.Value.colemak)
                    Text("Dvorak").tag(Config.KeyboardLayout.Value.dvorak)
                    Text("Dvorak - QWERTY ⌘").tag(Config.KeyboardLayout.Value.dvorakQwertyCommand)
                }
            } header: {
                Label("キーボード配列", systemImage: "keyboard.badge.ellipsis")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 詳細設定タブ
    @ViewBuilder
    private var advancedTabView: some View {
        Form {
            Section {
                HStack {
                    TextField("変換プロフィール", text: $zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                    helpButton(
                        helpContent: """
                    Zenzaiはあなたのプロフィールを考慮した変換を行うことができます。
                    名前や仕事、趣味などを入力すると、それに合わせた変換が自動で推薦されます。
                    （実験的な機能のため、精度が不十分な場合があります）
                    """,
                        isPresented: $zenzaiProfileHelpPopover
                    )
                }
                HStack {
                    TextField(
                        "Zenzaiの推論上限",
                        text: Binding(
                            get: {
                                String(self.$inferenceLimit.wrappedValue)
                            },
                            set: {
                                if let value = Int($0), (1 ... 50).contains(value) {
                                    self.$inferenceLimit.wrappedValue = value
                                }
                            }
                        )
                    )
                    Stepper("", value: $inferenceLimit, in: 1 ... 50)
                        .labelsHidden()
                    helpButton(helpContent: "推論上限を小さくすると、入力中のもたつきが改善されることがあります。", isPresented: $zenzaiInferenceLimitHelpPopover)
                }
            } header: {
                Label("Zenzai設定", systemImage: "cpu")
            }

            Section {
                Toggle("デバッグウィンドウを有効化", isOn: $debugWindow)
                Toggle("開発中の予測入力を有効化", isOn: $debugPredictiveTyping)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("開発中の入力訂正を有効化", isOn: $debugTypoCorrection)
                    if self.debugTypoCorrection.value {
                        HStack {
                            Text(self.debugTypoCorrectionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if self.debugTypoCorrectionDownloadInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Spacer()
                            switch self.debugTypoCorrectionState {
                            case .downloaded:
                                EmptyView()
                            case .failed, .notDownloaded:
                                // azooKey Medical は外部からのダウンロードを行わないので、重みは取れない
                                Text("この版では使えません（外部からダウンロードしないため）")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if case .failed = self.debugTypoCorrectionState,
                           let errorMessage = self.debugTypoCorrectionErrorMessage {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .onAppear {
                    guard self.debugTypoCorrection.value else {
                        return
                    }
                    Task { @MainActor in
                        await self.refreshDebugTypoCorrectionState()
                    }
                }
                .onChange(of: self.debugTypoCorrection.value) { enabled in
                    if enabled {
                        Task { @MainActor in
                            await self.refreshDebugTypoCorrectionState()
                        }
                    } else {
                        self.debugTypoCorrectionState = .notDownloaded
                        self.debugTypoCorrectionDownloadInProgress = false
                        self.debugTypoCorrectionErrorMessage = nil
                    }
                }
                // azooKey Medical: 「パーソナライズ」（別アプリ Tuner が作る言語モデル）は、Tuner との連携を外したので選べない
                LabeledContent("アプリデータ") {
                    HStack {
                        Button("Finderで開く") {
                            self.openAzooKeyDataDirectoryInFinder()
                        }
                    }
                }
            } header: {
                Label("開発者向け設定", systemImage: "hammer")
            }

            Section {
                LabeledContent("Version") {
                    Text(PackageMetadata.gitTag ?? PackageMetadata.gitCommit ?? "Unknown Version")
                        .monospaced()
                        .bold()
                        .copyable([
                            PackageMetadata.gitTag ?? PackageMetadata.gitCommit ?? "Unknown Version"
                        ])
                }
                .textSelection(.enabled)
            } header: {
                Label("アプリ情報", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

#Preview {
    ConfigWindow()
}
