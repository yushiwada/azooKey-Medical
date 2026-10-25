import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

public final class SegmentsManager {
    public init(
        kanaKanjiConverter: KanaKanjiConverter,
        applicationDirectoryURL: URL,
        containerURL: URL?,
        context: Context = Context()
    ) {
        self.kanaKanjiConverter = kanaKanjiConverter
        self.applicationDirectoryURL = applicationDirectoryURL
        self.containerURL = containerURL
        self.context = context
    }

    /// テストなどの設定注入のための型。外部には設定を露出させない。
    public struct Context {
        public init() {}
        init(useZenzai: Bool) {
            self.useZenzai = useZenzai
        }

        var useZenzai: Bool = true
    }

    public weak var delegate: (any SegmentManagerDelegate)?
    /// 話題（タイトル）と後ろの文章を、打つたびにアプリへ問い合わせないよう1秒間覚えておく
    private var contextCache: (topic: String?, right: String?, time: Date)?
    private var kanaKanjiConverter: KanaKanjiConverter
    private let applicationDirectoryURL: URL
    private let containerURL: URL?
    private let context: Context

    private var composingText: ComposingText = ComposingText()
    private var lastInputStyle: InputStyle = .direct

    private var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }
    private var userDictionary: Config.UserDictionary.Value {
        Config.UserDictionary().value
    }
    private var systemUserDictionary: Config.SystemUserDictionary.Value {
        Config.SystemUserDictionary().value
    }
    private var zenzaiPersonalizationLevel: Config.ZenzaiPersonalizationLevel.Value {
        Config.ZenzaiPersonalizationLevel().value
    }
    private var rawCandidates: ConversionResult?

    private var selectionIndex: Int?
    private var didExperienceSegmentEdition = false
    private var lastOperation: Operation = .other
    private var shouldShowCandidateWindow = false

    private var isShowingAdditionalCandidates = false
    private var additionalCandidates: [CandidatePresentation] = []
    private var showingAdditionalCandidateCount = 0
    private var isFixingAdditionalCandidateTop = false

    private var shouldShowDebugCandidateWindow: Bool = false
    private var debugCandidates: [Candidate] = []

    private var replaceSuggestions: [Candidate] = []
    private var suggestSelectionIndex: Int?
    private var backspaceAdjustedPredictionCandidate: PredictionCandidate?
    private var backspaceTypoCorrectionLock: BackspaceTypoCorrectionLock?

    public struct PredictionCandidate: Sendable, Equatable {
        public var displayText: String
        public var appendText: String
        public var deleteCount: Int = 0
    }

    struct BackspaceTypoCorrectionLock: Sendable {
        var displayText: String
        var targetReading: String
    }

    private func candidateReading(_ candidate: Candidate) -> String {
        candidate.data.map(\.ruby).joined()
    }

    public func makeCandidatePresentations(_ candidates: [Candidate]) -> [CandidatePresentation] {
        let additionalPresentations = self.additionalCandidatePresentationsForSelectionIndex
        return candidates.indices.map { index in
            if index < additionalPresentations.count {
                return .init(candidate: candidates[index], displayContext: additionalPresentations[index].displayContext)
            }
            return .init(candidate: candidates[index])
        }
    }

    private lazy var zenzaiPersonalizationMode: ConvertRequestOptions.ZenzaiMode.PersonalizationMode? = self.getZenzaiPersonalizationMode()

    /// azooKey Medical: 個人に合わせた言語モデル（別アプリ Tuner が作るもの）は、Tuner との連携（App Group）を外したので使わない
    private func getZenzaiPersonalizationMode() -> ConvertRequestOptions.ZenzaiMode.PersonalizationMode? {
        nil
    }

    private enum Operation: Sendable {
        case insert
        case delete
        case editSegment
        case other
    }

    public func appendDebugMessage(_ string: String) {
        // azooKey Medical: デバッグ用の表示を ON にしていないときは集めない（打った文章や選んだ文章がメモリに残らないように）
        guard Config.DebugWindow().value else {
            return
        }
        self.debugCandidates.insert(
            Candidate(
                text: string.replacingOccurrences(of: "\n", with: "\\n"),
                value: 0,
                composingCount: .surfaceCount(0),
                lastMid: 0,
                data: []
            ),
            at: 0
        )
        while self.debugCandidates.count > 100 {
            self.debugCandidates.removeLast()
        }
    }

    private func zenzaiMode(leftSideContext: String?, requestRichCandidates: Bool) -> ConvertRequestOptions.ZenzaiMode {
        if !self.context.useZenzai {
            return .off
        }
        return .on(
            weight: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/ggml-model-Q5_K_M.gguf", isDirectory: false),
            inferenceLimit: Config.ZenzaiInferenceLimit().value,
            requestRichCandidates: requestRichCandidates,
            personalizationMode: self.zenzaiPersonalizationMode,
            versionDependentMode: {
                let context = self.currentTopicAndRightContext(leftSideContext: leftSideContext)
                return .v3(
                    .init(
                        profile: Config.ZenzaiProfile().value,
                        topic: context.topic,
                        leftSideContext: leftSideContext,
                        rightSideContext: context.right
                    )
                )
            }()
        )
    }

    // MARK: - ノートのタイトルを「話題」として、カーソルの後ろの文章を「後ろの文脈」として変換AIに渡す（azooKey Medical で追加）

    /// 変換AIに渡す話題（ノートのタイトル）と後ろの文章。
    /// 後ろの文章は、変換モデル zenz-v3.2 が後ろの文脈として受け取る（変換エンジン 2026-05-10 以降の版で使える）。
    /// 打つたびにアプリへ問い合わせないよう、1秒間は前の結果を使い回す
    private func currentTopicAndRightContext(leftSideContext: String?) -> (topic: String?, right: String?) {
        let now = Date()
        if let cached = self.contextCache, now.timeIntervalSince(cached.time) < 1.0 {
            return (cached.topic, cached.right)
        }
        var topic: String?
        if Config.UseDocumentTitle().value,
           let title = Self.documentTitle(head: self.delegate?.getDocumentHead(maxCount: 300), leftSideContext: leftSideContext) {
            topic = String(title.prefix(20))
        }
        var right: String?
        if Config.UseRightSideContext().value {
            right = Self.cleanRightSideContext(self.delegate?.getRightSideContext(maxCount: 20))
        }
        self.contextCache = (topic, right, now)
        return (topic, right)
    }

    /// 文書の先頭からタイトルを取り出す。YAML の front matter は飛ばし、最初の見出し（なければ最初の空でない行）を使う。
    /// 日付や「メモ」のような中身のないタイトル、いま打っている行そのものは使わない
    static func documentTitle(head: String?, leftSideContext: String?) -> String? {
        guard let head, !head.isEmpty else {
            return nil
        }
        // CRLF や CR の改行でも分ける（"\r\n" は1文字として扱われるので、文字が改行かどうかで分ける）
        var lines = head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines[(end + 1)...])
        }
        // タイトルは最初の空でない行（見出しの # は外す）。後ろの行の # はハッシュタグのことがあるので使わない
        guard let line = lines.first(where: { !$0.isEmpty }) else {
            return nil
        }
        let title = Self.strippingHeadingMarks(line)
        // いま打っている行がタイトルの行なら使わない（打ちかけの文字そのものを話題にしない）
        if let leftSideContext, !leftSideContext.contains(where: \.isNewline) {
            let current = Self.strippingHeadingMarks(leftSideContext.trimmingCharacters(in: .whitespaces))
            if !current.isEmpty, title.hasPrefix(current) || current.hasPrefix(title) {
                return nil
            }
        }
        return Self.isInformative(title) ? title : nil
    }

    /// 見出しの記号（行の頭の # と空白）を外す
    static func strippingHeadingMarks(_ line: String) -> String {
        String(line.drop(while: { $0 == "#" || $0 == " " || $0 == "\u{3000}" }))
    }

    /// カーソルの後ろの文章を、同じ行のぶんだけ取り出す（空なら nil）
    static func cleanRightSideContext(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let line = (text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }

    private static let genericTitles: Set<String> = ["メモ", "ノート", "日記", "無題", "Untitled", "TODO", "Todo", "todo", "下書き", "ログ"]

    /// 話題として意味のある文字列か（日付・数字だけ・短すぎる・決まり文句は除く）
    static func isInformative(_ text: String) -> Bool {
        let meaningful = text.filter { $0.isLetter && !$0.isASCII }
        guard meaningful.count >= 2, !genericTitles.contains(text) else {
            return false
        }
        // 「2026年10月24日」のような日付も除く
        let dateLike = text.allSatisfy { $0.isNumber || "-/.:年月日（）() 曜火水木金土月".contains($0) }
        return !dateLike
    }

    private var metadata: ConvertRequestOptions.Metadata {
        if let tag = PackageMetadata.gitTag {
            .init(versionString: "azooKey on macOS (\(tag))")
        } else if let commit = PackageMetadata.gitCommit {
            .init(versionString: "azooKey on macOS (\(commit.prefix(7)))")
        } else {
            .init(versionString: "azooKey on macOS (unknown version)")
        }
    }

    private func options(
        leftSideContext: String?,
        requestRichCandidates: Bool,
        requireJapanesePrediction: ConvertRequestOptions.PredictionMode,
        requireEnglishPrediction: ConvertRequestOptions.PredictionMode
    ) -> ConvertRequestOptions {
        let canUseDebugTypoCorrection = Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights()
        return .init(
            requireJapanesePrediction: requireJapanesePrediction,
            requireEnglishPrediction: requireEnglishPrediction,
            keyboardLanguage: .ja_JP,
            englishCandidateInRoman2KanaInput: false,
            fullWidthRomanCandidate: true,
            learningType: Config.Learning().value.learningType,
            memoryDirectoryURL: self.azooKeyMemoryDir,
            sharedContainerURL: self.userDictionaryDirectory(leftSideContext: leftSideContext),
            textReplacer: .withDefaultEmojiDictionary(),
            specialCandidateProviders: KanaKanjiConverter.defaultSpecialCandidateProviders,
            zenzaiMode: self.zenzaiMode(leftSideContext: leftSideContext, requestRichCandidates: requestRichCandidates),
            experimentalZenzaiPredictiveInput: true,
            typoCorrectionMode: .automatic,
            metadata: self.metadata
        )
    }

    private static let medicalDictionaryRoot = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Resources/medical_dictionary", isDirectory: true)

    /// 医療の文脈かを判定する語の一覧（同梱の markers.txt。1行1語）
    private static let medicalMarkers: Set<String> = {
        let url = medicalDictionaryRoot.appendingPathComponent("markers.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return Set(text.split(separator: "\n").map { String($0) }.filter { $0.count >= 2 })
    }()
    private static let medicalMarkerMaxLength = medicalMarkers.map(\.count).max() ?? 0

    /// 前の文章に医療の語が含まれていれば医療の文脈とみなす
    static func isMedicalContext(_ context: String?) -> Bool {
        guard let context, !context.isEmpty, medicalMarkerMaxLength >= 2 else {
            return false
        }
        let chars = Array(context)
        for start in chars.indices {
            let maxLength = min(medicalMarkerMaxLength, chars.count - start)
            guard maxLength >= 2 else { break }
            for length in 2...maxLength where medicalMarkers.contains(String(chars[start..<(start + length)])) {
                return true
            }
        }
        return false
    }

    /// 変換エンジンがコンパイル済みの user 辞書（user.louds など）を探す場所。
    /// 医療用語の辞書は、もとの辞書では候補にも出ない語だけを弱く効かせた版（weak）を使い、
    /// 同音の語のどれにするかは前の文章を見て変換AIが決める。
    /// 実験的な設定が ON で前の文章が医療の内容なら、強く効かせる版（strong）を使う（評価では差し引きの得がなかったので既定は OFF）。
    /// 元の azooKey は学習データと同じ場所を渡している
    private func userDictionaryDirectory(leftSideContext: String?) -> URL {
        guard Config.MedicalDictionary().value else {
            return self.azooKeyMemoryDir
        }
        let useStrong = Config.MedicalContextBoost().value && Self.isMedicalContext(leftSideContext)
        for name in useStrong ? ["strong", "weak"] : ["weak"] {
            let directory = Self.medicalDictionaryRoot.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("user.louds").path) {
                return directory
            }
        }
        return self.azooKeyMemoryDir
    }

    private func hasDebugTypoCorrectionWeights() -> Bool {
        DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: self.downloadedInputN5LMDir)
    }

    public var azooKeyMemoryDir: URL {
        self.applicationDirectoryURL
    }

    public var downloadedInputN5LMDir: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.applicationDirectoryURL.deletingLastPathComponent()
        )
    }

    @MainActor
    public func activate() {
        self.contextCache = nil
        self.shouldShowCandidateWindow = false
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
        self.zenzaiPersonalizationMode = self.getZenzaiPersonalizationMode()
    }

    @MainActor
    public func deactivate() {
        self.kanaKanjiConverter.stopComposition()
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.composingText.stopComposition()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// この入力を打ち切る
    public func stopComposition() {
        self.contextCache = nil
        self.composingText.stopComposition()
        self.kanaKanjiConverter.stopComposition()
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    @MainActor
    /// 日本語入力自体をやめる
    public func stopJapaneseInput() {
        self.rawCandidates = nil
        self.didExperienceSegmentEdition = false
        self.lastOperation = .other
        self.kanaKanjiConverter.commitUpdateLearningData()
        self.shouldShowCandidateWindow = false
        self.selectionIndex = nil
        self.resetAdditionalCandidates()
        self.backspaceAdjustedPredictionCandidate = nil
        self.backspaceTypoCorrectionLock = nil
        self.lastInputStyle = .direct
    }

    /// 変換キーを押したタイミングで入力の区切りを示す
    @MainActor
    public func insertCompositionSeparator(inputStyle: InputStyle, skipUpdate: Bool = false) {
        guard self.composingText.input.last?.piece != .compositionSeparator else {
            // すでに末尾がcompositionSeparatorの場合は何もしない
            return
        }
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: inputStyle)])
        self.lastOperation = .insert
        if !skipUpdate {
            self.updateRawCandidate()
        }
    }

    @MainActor
    public func insertAtCursorPosition(_ string: String, inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(string, inputStyle: inputStyle)
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func insertAtCursorPosition(pieces: [InputPiece], inputStyle: InputStyle) {
        self.lastInputStyle = inputStyle
        self.composingText.insertAtCursorPosition(pieces.map { .init(piece: $0, inputStyle: inputStyle) })
        self.lastOperation = .insert
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
    }

    @MainActor
    public func editSegment(count: Int) {
        // 現在選ばれているprefix candidateが存在する場合、まずそれに合わせてカーソルを移動する
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            var afterComposingText = self.composingText
            afterComposingText.prefixComplete(composingCount: candidates[selectionIndex].composingCount)
            let prefixCount = self.composingText.convertTarget.count - afterComposingText.convertTarget.count
            _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + prefixCount)
        }
        if count > 0 {
            if self.composingText.isAtEndIndex && !self.didExperienceSegmentEdition {
                // 現在のカーソルが右端にある場合、左端の次に移動する
                _ = self.composingText.moveCursorFromCursorPosition(count: -self.composingText.convertTargetCursorPosition + count)
            } else {
                // それ以外の場合、右に広げる
                _ = self.composingText.moveCursorFromCursorPosition(count: count)
            }
        } else {
            _ = self.composingText.moveCursorFromCursorPosition(count: count)
        }
        if self.composingText.isAtStartIndex {
            // 最初にある場合は一つ右に進める
            _ = self.composingText.moveCursorFromCursorPosition(count: 1)
        }
        self.lastOperation = .editSegment
        self.didExperienceSegmentEdition = true
        self.shouldShowCandidateWindow = true
        self.selectionIndex = nil
        self.updateRawCandidate()
    }

    @MainActor
    public func deleteBackwardFromCursorPosition(count: Int = 1) {
        var previousComposingText = self.composingText.prefixToCursorPosition()
        if !self.composingText.isAtEndIndex {
            // 右端に持っていく
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            // 一度segmentの編集状態もリセットにする
            self.didExperienceSegmentEdition = false
            previousComposingText = self.composingText.prefixToCursorPosition()
        }
        self.composingText.deleteBackwardFromCursorPosition(count: count)
        self.lastOperation = .delete
        // ライブ変換がオフの場合は変換候補ウィンドウを出したい
        self.shouldShowCandidateWindow = !self.liveConversionEnabled
        self.updateRawCandidate()
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        let currentConvertTarget = self.composingText.convertTarget
        guard count == 1 else {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
            return
        }
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
            if self.backspaceAdjustedPredictionCandidate == nil {
                self.backspaceTypoCorrectionLock = nil
            }
            return
        }
        self.backspaceTypoCorrectionLock = self.lmBasedBackspaceTypoCorrectionLock(previousComposingText: previousComposingText)
        if let lock = self.backspaceTypoCorrectionLock {
            self.backspaceAdjustedPredictionCandidate = Self.makeBackspaceTypoCorrectionPredictionCandidate(
                currentConvertTarget: currentConvertTarget,
                targetReading: lock.targetReading,
                displayText: lock.displayText
            )
        } else {
            self.backspaceAdjustedPredictionCandidate = nil
        }
    }

    @MainActor
    public func forgetMemory() {
        if let selectedCandidate {
            self.kanaKanjiConverter.forgetMemory(selectedCandidate)
            self.appendDebugMessage("\(#function): forget \(selectedCandidate.data.map {$0.word})")
        }
    }

    private var candidates: [Candidate]? {
        guard let rawCandidates = self.rawCandidatesList else {
            return self.isShowingAdditionalCandidates
                ? self.additionalCandidatesForSelectionIndex
                : nil
        }
        return self.isShowingAdditionalCandidates
            ? self.additionalCandidatesForSelectionIndex + rawCandidates
            : rawCandidates
    }

    private var rawCandidatesList: [Candidate]? {
        guard let rawCandidates else {
            return nil
        }
        if !self.didExperienceSegmentEdition {
            if rawCandidates.firstClauseResults.contains(where: { self.composingText.isWholeComposingText(composingCount: $0.composingCount) }) {
                // firstClauseCandidateがmainResultsと同じサイズの場合は、何もしない方が良い
                return rawCandidates.mainResults
            } else {
                // 変換範囲がエディットされていない場合
                let seenAsFirstClauseResults = rawCandidates.firstClauseResults.mapSet(transform: \.text)
                return rawCandidates.firstClauseResults + rawCandidates.mainResults.filter {
                    !seenAsFirstClauseResults.contains($0.text)
                }
            }
        } else {
            return rawCandidates.mainResults
        }
    }

    private var candidateOffsetByAdditionalCandidates: Int {
        self.isShowingAdditionalCandidates ? self.showingAdditionalCandidateCount : 0
    }

    private var additionalCandidatesForSelectionIndex: [Candidate] {
        self.additionalCandidatePresentationsForSelectionIndex.map(\.candidate)
    }

    private var additionalCandidatePresentationsForSelectionIndex: [CandidatePresentation] {
        guard self.isShowingAdditionalCandidates else {
            return []
        }
        guard self.candidateOffsetByAdditionalCandidates > 0 else {
            return []
        }
        return Array(self.additionalCandidates.suffix(self.candidateOffsetByAdditionalCandidates))
    }

    public var convertTarget: String {
        self.composingText.convertTarget
    }

    public var isEmpty: Bool {
        self.composingText.isEmpty
    }

    public func getCleanLeftSideContext(maxCount: Int) -> String? {
        if Config.MultiLineLeftContext().value {
            // 前の行も含める（箇条書きのメモで文脈が前の行にある場合に効く）。各行の先頭の空白は除く
            return self.delegate?.getLeftSideContext(maxCount: 40).map {
                $0.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0.drop(while: \.isWhitespace)) }
                    .joined(separator: "\n")
            }
        }
        return self.delegate?.getLeftSideContext(maxCount: 30).map {
            var last = $0.split(separator: "\n", omittingEmptySubsequences: false).last ?? $0[...]
            // 前方の空白を削除する
            while last.first?.isWhitespace ?? false {
                last = last.dropFirst()
            }
            return String(last)
        }
    }

    /// Updates the `self.rawCandidates` based on the current input context.
    ///
    /// This function is responsible for handling candidate conversion,
    /// taking into account partial confirmations and optionally fetching rich candidates.
    /// It also allows an override for the left-side context when necessary.
    ///
    /// - Parameters:
    ///   - requestRichCandidates: A Boolean flag indicating whether to fetch rich candidates (default is `false`). Generating rich candidates takes longer time.
    ///   - forcedLeftSideContext: An optional string that overrides the left-side context (default is `nil`).
    ///
    /// - Note:
    ///   This function is executed on the `@MainActor` to ensure UI consistency.
    @MainActor private func updateRawCandidate(requestRichCandidates: Bool = false, forcedLeftSideContext: String? = nil) {
        if self.lastOperation != .delete {
            self.backspaceAdjustedPredictionCandidate = nil
            self.backspaceTypoCorrectionLock = nil
        }
        self.resetAdditionalCandidates()
        // 不要
        if composingText.isEmpty {
            self.rawCandidates = nil
            self.kanaKanjiConverter.stopComposition()
            return
        }
        // ユーザ辞書情報の更新
        var userDictionary: [DicdataElement] = userDictionary.items.map {
            .init(word: $0.word, ruby: $0.reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        self.appendDebugMessage("userDictionaryCount: \(userDictionary.count)")
        let systemUserDictionary: [DicdataElement] = systemUserDictionary.items.map {
            .init(word: $0.word, ruby: $0.reading.toKatakana(), cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -5)
        }
        self.appendDebugMessage("systemUserDictionaryCount: \(systemUserDictionary.count)")
        userDictionary.append(contentsOf: consume systemUserDictionary)

        /// 日付・時刻変換を事前に入れておく
        let dynamicShortcuts: [DicdataElement] =
            [
                ("M/d", -18, DateTemplateLiteral.CalendarType.western),
                ("yyyy/MM/dd", -18.1, .western),
                ("yyyy-MM-dd", -18.2, .western),
                ("M月d日（E）", -18.3, .western),
                ("yyyy年M月d日", -18.4, .western),
                ("Gyyyy年M月d日", -18.5, .japanese),
                ("E曜日", -18.6, .western)
            ].flatMap { (format, value: PValue, type) in
                [
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-2", deltaUnit: 60 * 60 * 24).export(), ruby: "オトトイ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "-1", deltaUnit: 60 * 60 * 24).export(), ruby: "キノウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "キョウ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "1", deltaUnit: 60 * 60 * 24).export(), ruby: "アシタ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value),
                    .init(word: DateTemplateLiteral(format: format, type: type, language: .japanese, delta: "2", deltaUnit: 60 * 60 * 24).export(), ruby: "アサッテ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: value)
                ]
            } + [
                // 月
                .init(word: DateTemplateLiteral(format: "MM月", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コンゲツ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                // 年
                .init(word: DateTemplateLiteral(format: "yyyy年", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "Gyyyy年", type: .japanese, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "コトシ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                // 時刻
                .init(word: DateTemplateLiteral(format: "HH:mm", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18),
                .init(word: DateTemplateLiteral(format: "HH時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.1),
                .init(word: DateTemplateLiteral(format: "aK時mm分", type: .western, language: .japanese, delta: "0", deltaUnit: 1).export(), ruby: "イマ", cid: CIDData.固有名詞.cid, mid: MIDData.一般.mid, value: -18.2)
            ]

        self.kanaKanjiConverter.importDynamicUserDictionary(consume userDictionary, shortcuts: dynamicShortcuts)

        let prefixComposingText = self.composingText.prefixToCursorPosition()
        let leftSideContext = forcedLeftSideContext ?? self.getCleanLeftSideContext(maxCount: 30)
        let result = self.kanaKanjiConverter.requestCandidates(
            prefixComposingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: requestRichCandidates,
                requireJapanesePrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled,
                requireEnglishPrediction: Config.DebugPredictiveTyping().value ? .manualMix : .disabled
            )
        )
        self.rawCandidates = result
    }

    @MainActor public func update(requestRichCandidates: Bool) {
        self.updateRawCandidate(requestRichCandidates: requestRichCandidates)
        self.shouldShowCandidateWindow = true
    }

    /// - note: 画面更新との整合性を保つため、この関数の実行前に左文脈を取得し、これを引数として与える
    @MainActor public func prefixCandidateCommited(_ candidate: Candidate, leftSideContext: String) {
        self.kanaKanjiConverter.setCompletedData(candidate)
        self.kanaKanjiConverter.updateLearningData(candidate)
        self.composingText.prefixComplete(composingCount: candidate.composingCount)

        if !self.composingText.isEmpty {
            // カーソルを右端に移動する
            _ = self.composingText.moveCursorFromCursorPosition(count: self.composingText.convertTarget.count - self.composingText.convertTargetCursorPosition)
            self.didExperienceSegmentEdition = false
            self.shouldShowCandidateWindow = true
            self.selectionIndex = nil
            self.updateRawCandidate(requestRichCandidates: true, forcedLeftSideContext: leftSideContext + candidate.text)
        }
    }

    public enum CandidateWindow: Sendable {
        case hidden
        case composing([Candidate], selectionIndex: Int?)
        case selecting([Candidate], selectionIndex: Int?)
    }

    public func requestSetCandidateWindowState(visible: Bool) {
        self.shouldShowCandidateWindow = visible
    }

    public func requestDebugWindowMode(enabled: Bool) {
        self.shouldShowDebugCandidateWindow = enabled
    }

    @MainActor
    public func requestSelectingNextCandidate() {
        self.isFixingAdditionalCandidateTop = false
        self.selectionIndex = (self.selectionIndex ?? -1) + 1
    }

    @MainActor
    public func requestSelectingPrevCandidate() {
        let selectionIndex = self.selectionIndex ?? 0

        if self.isFixingAdditionalCandidateTop && self.isShowingAdditionalCandidates {
            if self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
                self.showingAdditionalCandidateCount += 1
            }
            self.selectionIndex = 0
            return
        }

        if selectionIndex == 0, !self.isShowingAdditionalCandidates {
            self.showAdditionalCandidatesIfNeeded()
            let additionalCount = self.candidateOffsetByAdditionalCandidates
            if additionalCount > 0 {
                self.isFixingAdditionalCandidateTop = true
                self.selectionIndex = 0
                return
            }
        }
        if selectionIndex == 0, self.isShowingAdditionalCandidates, self.candidateOffsetByAdditionalCandidates < self.additionalCandidates.count {
            self.isFixingAdditionalCandidateTop = true
            self.showingAdditionalCandidateCount += 1
            self.selectionIndex = 0
            return
        }
        self.selectionIndex = max(0, selectionIndex - 1)
    }

    public func requestSelectingRow(_ index: Int) {
        if self.isFixingAdditionalCandidateTop, index != 0 {
            self.isFixingAdditionalCandidateTop = false
        }
        self.selectionIndex = max(0, index)
    }

    public func requestSelectingSuggestionRow(_ row: Int) {
        suggestSelectionIndex = row
    }

    public func stopSuggestionSelection() {
        self.selectionIndex = nil
    }

    public func requestResettingSelection() {
        self.selectionIndex = nil
        self.isFixingAdditionalCandidateTop = false
        self.resetAdditionalCandidates()
    }

    public var selectedCandidate: Candidate? {
        if let selectionIndex, let candidates, candidates.indices.contains(selectionIndex) {
            return candidates[selectionIndex]
        }
        return nil
    }

    public func getCurrentCandidateWindow(inputState: InputState) -> CandidateWindow {
        switch inputState {
        case .none, .previewing, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            return .hidden
        case .composing:
            if !self.liveConversionEnabled, let firstCandidate = self.rawCandidates?.mainResults.first {
                return .composing([firstCandidate], selectionIndex: 0)
            } else {
                return .hidden
            }
        case .selecting:
            if self.shouldShowDebugCandidateWindow {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, debugCandidates.count - 1))
                return .selecting(debugCandidates, selectionIndex: self.selectionIndex)
            } else if self.shouldShowCandidateWindow, let candidates, !candidates.isEmpty {
                self.selectionIndex = max(0, min(self.selectionIndex ?? 0, candidates.count - 1))
                return .selecting(candidates, selectionIndex: self.selectionIndex)
            } else {
                return .hidden
            }
        }
    }

    public struct MarkedText: Sendable, Equatable, Hashable, Sequence {
        public enum FocusState: Sendable, Equatable, Hashable {
            case focused
            case unfocused
            case none
        }

        public struct Element: Sendable, Equatable, Hashable {
            public var content: String
            public var focus: FocusState
        }
        var text: [Element]

        public var selectionRange: NSRange

        public func makeIterator() -> Array<Element>.Iterator {
            text.makeIterator()
        }

        var isEmpty: Bool {
            self.text.isEmpty
        }
    }

    @MainActor
    public func getModifiedRubyCandidate(inputState: InputState, _ transform: (String) -> String) -> Candidate {
        let (ruby, composingCount): (String, ComposingCount) = switch inputState {
        case .selecting:
            if let selectedRuby = selectedCandidate?.data.map({ $0.ruby }).joined() {
                // `selectedCandidate.data` の全ての `ruby` を連結して返す
                (selectedRuby, .surfaceCount(selectedRuby.count))
            } else {
                // 選択範囲なしの場合はconvertTargetを返す
                (self.convertTarget, .inputCount(self.composingText.input.count))
            }
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            (self.convertTarget, .inputCount(self.composingText.input.count))
        }
        let candidateText = transform(ruby)
        return Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: ruby,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
    }

    @MainActor
    public func getModifiedRomanCandidate(inputState: InputState = .composing, _ transform: (String) -> String) -> Candidate {
        let targetComposingText: ComposingText
        switch inputState {
        case .selecting:
            targetComposingText = self.composingText.prefixToCursorPosition()
        case .composing, .previewing, .none, .replaceSuggestion, .attachDiacritic, .unicodeInput:
            targetComposingText = self.composingText
        }
        let inputString = targetComposingText.input.map(\.piece).inputString(preferIntention: false)
        let composingCount: ComposingCount = .inputCount(targetComposingText.input.count)
        let candidateText = transform(inputString)
        let candidate = Candidate(
            text: candidateText,
            value: 0,
            composingCount: composingCount,
            lastMid: 0,
            data: [DicdataElement(
                word: candidateText,
                ruby: inputString,
                cid: CIDData.固有名詞.cid,
                mid: MIDData.一般.mid,
                value: 0
            )]
        )
        return candidate
    }

    @MainActor
    private func createAdditionalCandidates() -> [CandidatePresentation] {
        let candidates: [(candidate: Candidate, annotationText: String?)] = [
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0 }, "英数"),
            (self.getModifiedRomanCandidate(inputState: .selecting) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, "全角英数"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, "半角カナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toKatakana() }, "カタカナ"),
            (self.getModifiedRubyCandidate(inputState: .selecting) { $0.toHiragana() }, "ひらがな")
        ]
        return candidates.map {
            .init(
                candidate: $0.candidate,
                displayContext: .init(annotationText: $0.annotationText)
            )
        }
    }

    @MainActor
    private func showAdditionalCandidatesIfNeeded() {
        if self.isShowingAdditionalCandidates {
            return
        }
        guard !self.convertTarget.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        let candidates = self.createAdditionalCandidates()
        guard !candidates.isEmpty else {
            self.resetAdditionalCandidates()
            return
        }
        self.additionalCandidates = candidates
        self.isShowingAdditionalCandidates = true
        self.showingAdditionalCandidateCount = 1
    }

    private func resetAdditionalCandidates() {
        self.isShowingAdditionalCandidates = false
        self.additionalCandidates = []
        self.showingAdditionalCandidateCount = 0
        self.isFixingAdditionalCandidateTop = false
    }

    @MainActor
    public func commitMarkedText(inputState: InputState) -> String {
        let markedText = self.getCurrentMarkedText(inputState: inputState)
        let text = markedText.reduce(into: "") {$0.append(contentsOf: $1.content)}
        if let candidate = self.candidates?.first(where: {$0.text == text}) {
            self.prefixCandidateCommited(candidate, leftSideContext: "")
        }
        self.stopComposition()
        return text
    }

    // サジェスト候補を設定するメソッド
    public func setReplaceSuggestions(_ candidates: [Candidate]) {
        self.replaceSuggestions = candidates
        self.suggestSelectionIndex = nil
    }

    // サジェスト候補の選択状態をリセット
    public func resetSuggestionSelection() {
        suggestSelectionIndex = nil
    }

    public func requestTypoCorrectionPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugTypoCorrection().value else {
            return []
        }
        guard let backspaceAdjustedPredictionCandidate else {
            return []
        }
        return [backspaceAdjustedPredictionCandidate]
    }

    public static func preferredPredictionCandidates(
        typoCorrectionCandidates: [PredictionCandidate],
        predictionCandidates: [PredictionCandidate]
    ) -> [PredictionCandidate] {
        if !typoCorrectionCandidates.isEmpty {
            return typoCorrectionCandidates
        }
        return predictionCandidates
    }

    public static func shouldPresentTypoCorrectionPredictionCandidate(
        candidateDisplayText: String,
        previousComposingDisplayText: String
    ) -> Bool {
        // 削除前の previousComposingText と同じ表示候補は、訂正候補としては提示しない。
        candidateDisplayText != previousComposingDisplayText
    }

    public func requestPredictionCandidates() -> [PredictionCandidate] {
        guard Config.DebugPredictiveTyping().value else {
            return []
        }

        let target = self.composingText.convertTarget
        guard !target.isEmpty else {
            return []
        }

        guard let rawCandidates else {
            return []
        }

        for candidate in rawCandidates.predictionResults {
            let reading = candidateReading(candidate)
            guard !reading.isEmpty else {
                continue
            }
            if let predictionCandidate = Self.makePredictionCandidate(
                currentTarget: target,
                candidateReading: reading,
                displayText: candidate.text
            ) {
                return [predictionCandidate]
            }
        }

        return []
    }

    static func makePredictionCandidate(
        currentTarget: String,
        candidateReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        var matchTarget = currentTarget
        var deleteCount = 0
        if let last = matchTarget.last,
           last.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) }) {
            matchTarget.removeLast()
            deleteCount = 1
        }
        guard matchTarget.count >= 2 else {
            return nil
        }

        let readingHiragana = candidateReading.toHiragana()
        let matchTargetHiragana = matchTarget.toHiragana()
        guard readingHiragana.hasPrefix(matchTargetHiragana) else {
            return nil
        }
        guard matchTargetHiragana.count < readingHiragana.count else {
            return nil
        }

        let appendText = String(readingHiragana.dropFirst(matchTargetHiragana.count))
        guard !appendText.isEmpty else {
            return nil
        }

        return .init(displayText: displayText, appendText: appendText, deleteCount: deleteCount)
    }

    private func requestTypoCorrectionCandidates(composingText targetComposingText: ComposingText, inputStyle: InputStyle) -> [String] {
        guard Config.DebugTypoCorrection().value && self.hasDebugTypoCorrectionWeights() else {
            return []
        }
        guard !targetComposingText.isEmpty else {
            return []
        }

        let leftSideContext = self.getCleanLeftSideContext(maxCount: 30) ?? ""
        let typoCandidates = self.kanaKanjiConverter.experimentalRequestTypoCorrection(
            leftSideContext: leftSideContext,
            composingText: targetComposingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            ),
            inputStyle: inputStyle,
            config: .init(
                languageModel: .ngram(.init(prefix: self.downloadedInputN5LMDir.path + "/lm_", n: 5, d: 0.75)),
                beamSize: 16,
                topK: 32,
                nBest: 3
            )
        )

        var seen: Set<String> = []
        return typoCandidates.compactMap { candidate in
            let text = candidate.convertedText.toHiragana()
            guard !text.isEmpty else {
                return nil
            }
            guard seen.insert(text).inserted else {
                return nil
            }
            return text
        }
    }

    private func convertedText(reading: String, leftSideContext: String?) -> String? {
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(reading, inputStyle: .direct)

        let result = self.kanaKanjiConverter.requestCandidates(
            composingText,
            options: options(
                leftSideContext: leftSideContext,
                requestRichCandidates: false,
                requireJapanesePrediction: .disabled,
                requireEnglishPrediction: .disabled
            )
        )
        return result.mainResults.first?.text
    }

    @MainActor
    private func lmBasedBackspaceTypoCorrectionLock(previousComposingText: ComposingText) -> BackspaceTypoCorrectionLock? {
        let typoCorrectionCandidates = self.requestTypoCorrectionCandidates(
            composingText: previousComposingText,
            inputStyle: self.lastInputStyle
        )
        guard let correctedReading = typoCorrectionCandidates.first else {
            return nil
        }

        let correctedDisplayText = self.convertedText(
            reading: correctedReading,
            leftSideContext: self.getCleanLeftSideContext(maxCount: 30)
        ) ?? correctedReading
        let previousComposingDisplayText = self.convertedText(
            reading: previousComposingText.convertTarget,
            leftSideContext: self.getCleanLeftSideContext(maxCount: 30)
        ) ?? previousComposingText.convertTarget
        guard Self.shouldPresentTypoCorrectionPredictionCandidate(
            candidateDisplayText: correctedDisplayText,
            previousComposingDisplayText: previousComposingDisplayText
        ) else {
            return nil
        }

        return .init(displayText: correctedDisplayText, targetReading: correctedReading)
    }

    static func makeBackspaceTypoCorrectionPredictionCandidate(
        currentConvertTarget: String,
        targetReading: String,
        displayText: String
    ) -> PredictionCandidate? {
        let operation = Self.makeSuffixEditOperation(from: currentConvertTarget, to: targetReading)
            ?? Self.makeSuffixEditOperation(from: currentConvertTarget.toHiragana(), to: targetReading)
        guard let operation else {
            return nil
        }
        return .init(displayText: displayText, appendText: operation.appendText, deleteCount: operation.deleteCount)
    }

    private static func makeSuffixEditOperation(from currentText: String, to targetText: String) -> (appendText: String, deleteCount: Int)? {
        let sharedPrefixLength = zip(currentText, targetText).prefix(while: ==).count
        let deleteCount = currentText.count - sharedPrefixLength
        let appendText = String(targetText.dropFirst(sharedPrefixLength))
        guard deleteCount > 0 || !appendText.isEmpty else {
            return nil
        }
        return (appendText, deleteCount)
    }

    // swiftlint:disable:next cyclomatic_complexity
    public func getCurrentMarkedText(inputState: InputState) -> MarkedText {
        switch inputState {
        case .none, .attachDiacritic:
            return MarkedText(text: [], selectionRange: .notFound)
        case .composing:
            let text = if self.lastOperation == .delete {
                // 削除のあとは常にひらがなを示す
                self.composingText.convertTarget
            } else if self.liveConversionEnabled,
                      self.composingText.convertTarget.count > 1,
                      let firstCandidate = self.rawCandidates?.mainResults.first {
                // それ以外の場合、ライブ変換が有効なら
                firstCandidate.text
            } else {
                // それ以外
                self.composingText.convertTarget
            }
            return MarkedText(text: [.init(content: text, focus: .none)], selectionRange: .notFound)
        case .previewing:
            if let fullCandidate = self.rawCandidates?.mainResults.first,
               self.composingText.isWholeComposingText(composingCount: fullCandidate.composingCount) {
                return MarkedText(text: [.init(content: fullCandidate.text, focus: .none)], selectionRange: .notFound)
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .selecting:
            if let candidates, !candidates.isEmpty {
                self.selectionIndex = min(self.selectionIndex ?? 0, candidates.count - 1)
                var afterComposingText = self.composingText
                afterComposingText.prefixComplete(composingCount: candidates[self.selectionIndex!].composingCount)
                return MarkedText(
                    text: [
                        .init(content: candidates[self.selectionIndex!].text, focus: .focused),
                        .init(content: afterComposingText.convertTarget, focus: .unfocused)
                    ],
                    selectionRange: NSRange(location: candidates[self.selectionIndex!].text.count, length: 0)
                )
            } else {
                return MarkedText(text: [.init(content: self.composingText.convertTarget, focus: .none)], selectionRange: .notFound)
            }
        case .replaceSuggestion:
            // サジェスト候補の選択状態を独立して管理
            if let index = suggestSelectionIndex,
               replaceSuggestions.indices.contains(index) {
                return MarkedText(
                    text: [.init(content: replaceSuggestions[index].text, focus: .focused)],
                    selectionRange: NSRange(location: replaceSuggestions[index].text.count, length: 0)
                )
            } else {
                return MarkedText(
                    text: [.init(content: composingText.convertTarget, focus: .none)],
                    selectionRange: .notFound
                )
            }
        case .unicodeInput(let codePoint):
            // Unicode入力モード: "U+" + コードポイントを表示
            let displayText = "U+" + codePoint
            return MarkedText(
                text: [.init(content: displayText, focus: .none)],
                selectionRange: NSRange(location: displayText.count, length: 0)
            )
        }
    }
}

public protocol SegmentManagerDelegate: AnyObject {
    func getLeftSideContext(maxCount: Int) -> String?
    /// カーソル（入力中の文字列）より後ろの文章（azooKey Medical で追加）
    func getRightSideContext(maxCount: Int) -> String?
    /// 文書の先頭の文章（タイトルを取り出すのに使う。azooKey Medical で追加）
    func getDocumentHead(maxCount: Int) -> String?
}

public extension SegmentManagerDelegate {
    func getRightSideContext(maxCount: Int) -> String? { nil }
    func getDocumentHead(maxCount: Int) -> String? { nil }
}

private extension ComposingText {
    func isWholeComposingText(composingCount: ComposingCount) -> Bool {
        var c = self
        c.prefixComplete(composingCount: composingCount)
        return c.isEmpty
    }
}
