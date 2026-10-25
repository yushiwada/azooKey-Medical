import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController, NSMenuItemValidation { // swiftlint:disable:this type_name
    var segmentsManager: SegmentsManager
    private(set) var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    private var replaceSuggestionWindow: NSWindow
    private var replaceSuggestionsViewController: ReplaceSuggestionsViewController

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false
    /// 選んだ文を指示として実行する機能の状態（入力欄をまたいで1つ）
    var selectionPrompt: SelectionPromptState { SelectionPromptState.shared }
    /// 打った文章の記憶を入力欄ごとに分けるための印（この入力コントローラは入力欄ごとに作られる）
    private let typedHistorySuffix = UUID().uuidString
    /// この入力欄の記憶の名前（入力欄を離れたときに、アプリに問い合わせずに消すため）
    private var lastTypedHistoryKey: String?

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window = NSWindow(contentViewController: contentViewController)
        window.styleMask = [.borderless]
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = UserDefaults.standard.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let applicationDirectoryURL = if #available(macOS 13, *) {
            URL.applicationSupportDirectory
            .appending(path: "azooKey", directoryHint: .isDirectory)
            .appending(path: "memory", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("azooKey", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        }

        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.azooKeyMacIdentifier)
        self.segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL
        )

        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: predictionViewController)
        self.replaceSuggestionWindow = Self.makeCandidateWindow(contentViewController: replaceSuggestionsViewController)

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        self.segmentsManager.delegate = self
        self.setupMenu()
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        // Register custom input table (if available) for `.tableName` usage
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        // ピン留めプロンプトのキャッシュを更新
        self.reloadPinnedPromptsCache()
        self.segmentsManager.activate()

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        }
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        // 入力欄を離れたら、その欄で打った文章の記憶を消す（別の文書の文章が文脈に混ざらないように）
        if let key = self.lastTypedHistoryKey {
            TypedHistory.shared.reset(app: key)
        }
        TypedHistory.shared.purgeExpired()
        self.segmentsManager.deactivate()
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        // Unicode入力モードの場合は状態だけリセットして終了
        // マウスクリック等でOSがMarkedTextを確定した場合、IME側からは消せないため
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.segmentsManager.isEmpty {
            return
        }
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        if let client = sender as? IMKTextInput {
            self.commitText(text, client: client)
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            let englishMode = value == "com.apple.inputmethod.Roman"

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    self.inputLanguage = .english
                    self.segmentsManager.stopJapaneseInput()
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    let (clientAction, clientActionCallback) = self.inputState.event(
                        eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0x00),
                        userAction: .かな,
                        inputLanguage: self.inputLanguage,
                        liveConversionEnabled: false,
                        enableDebugWindow: false,
                        enableSuggestion: false
                    )
                    _ = self.handleClientAction(
                        clientAction,
                        clientActionCallback: clientActionCallback,
                        client: self.client()
                    )
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        // azooKey Medical: 範囲選択してショートカット（既定は Option+Return）で、選んだ文をAIへの指示として実行する
        if let handled = self.handleSelectionPromptKey(event, client: client) {
            return handled
        }
        guard event.type == .keyDown else {
            return false
        }
        // 入力ソフトが使わずにアプリへ渡したキー（改行・削除・カーソル移動など）だけを、覚えた文章に反映する
        let wasEmpty = self.segmentsManager.isEmpty
        let handled = self.handleKeyDown(event, client: client)
        if !handled, wasEmpty {
            self.recordPassThroughKey(event, client: client)
        }
        return handled
    }

    /// 打った文章の記憶の名前（アプリと入力欄ごと）
    func typedHistoryKey(client: IMKTextInput) -> String? {
        guard let app = client.bundleIdentifier() else {
            return nil
        }
        let key = "\(app)#\(self.typedHistorySuffix)"
        self.lastTypedHistoryKey = key
        return key
    }

    /// 文字列を確定してアプリに渡し、前の文章として覚える。
    /// 英数モードで打った文字と、パスワードの欄など（安全な入力の状態）で打った文字は覚えない
    @MainActor func commitText(_ text: String, client: IMKTextInput) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        guard Config.UseTypedHistory().value, self.inputLanguage == .japanese, !IsSecureEventInputEnabled(),
              let key = self.typedHistoryKey(client: client) else {
            return
        }
        TypedHistory.shared.append(text, app: key)
    }

    /// 入力中でないときにアプリへそのまま渡ったキー（改行・削除・カーソル移動など）を、覚えた文章に反映する
    @MainActor func recordPassThroughKey(_ event: NSEvent, client: IMKTextInput) {
        guard Config.UseTypedHistory().value, let key = self.typedHistoryKey(client: client) else {
            return
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // ⌘ や ⌃ を使う操作（取り消し・貼り付け・行頭へ移動など）は文章やカーソルを変えうるので、覚えた文章を忘れる
        if !modifiers.isDisjoint(with: [.command, .control]) {
            TypedHistory.shared.reset(app: key)
            return
        }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if modifiers.isEmpty {
                TypedHistory.shared.appendNewline(app: key)
            } else {
                TypedHistory.shared.reset(app: key)
            }
        case 51: // Delete
            if modifiers.isEmpty {
                TypedHistory.shared.deleteBackward(app: key)
            } else {
                TypedHistory.shared.reset(app: key)
            }
        case 123, 124, 125, 126: // 矢印
            if modifiers == [.shift] {
                // Shift と矢印で範囲を選んでいるとき。選んだ文の手前を探すのには使い、次に打ち始めるときに忘れる
                TypedHistory.shared.markCursorUncertain(app: key)
            } else {
                TypedHistory.shared.reset(app: key)
            }
        case 115, 119, 116, 121, 117, 48: // Home・End・PageUp・PageDown・前方削除・Tab
            TypedHistory.shared.reset(app: key)
        default:
            break
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor func handleKeyDown(_ event: NSEvent, client: IMKTextInput) -> Bool {
        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                        return true
                    }
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)
        let charactersForOptionDirectInput = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(
            characters: charactersForOptionDirectInput,
            modifierFlags: eventModifiers,
            inputLanguage: inputLanguage,
            inputState: inputState,
            typeBackSlash: Config.TypeBackSlash().value
           ) {
            self.commitText(text, client: client)
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        return true
                    }
                }
                if !self.segmentsManager.isEmpty {
                    _ = self.handleClientAction(.submitHalfWidthRomanCandidate, clientActionCallback: .transition(.none), client: client)
                    self.switchInputLanguage(.english, client: client)
                    return true
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        return true
                    }
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // If AI backend is off, ignore the suggest action
            if !aiBackendEnabled {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: AI backend is off")
                return false
            }

            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.segmentsManager.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                self.segmentsManager.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                return self.handleClientAction(.showPromptInputWindow, clientActionCallback: .fallthrough, client: client)
            } else {
                self.segmentsManager.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        let (clientAction, clientActionCallback) = inputState.event(
            eventCore: event.keyEventCore,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            // azooKey Medical: Ctrl+S で候補を出す機能は、設定で ON にしたときだけ（既定は元の azooKey と同じく Ctrl+S をアプリに渡す）
            enableSuggestion: aiBackendEnabled && Config.ControlSSuggestion().value
        )
        return handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client)
    }

    private var inputStyle: InputStyle {
        switch Config.InputStyle().value {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }

    // この種のコードは複雑にしかならないので、lintを無効にする
    // swiftlint:disable:next cyclomatic_complexity
    @MainActor func handleClientAction(_ clientAction: ClientAction, clientActionCallback: ClientActionCallback, client: IMKTextInput) -> Bool {
        // return only false
        switch clientAction {
        case .showCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterFirstCandidatePreviewMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: false)
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: true)
            self.segmentsManager.update(requestRichCandidates: true)
        case .appendToMarkedText(let string):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let string):
            self.commitText(string, client: client)
        case .editSegment(let count):
            self.segmentsManager.editSegment(count: count)
        case .commitMarkedText:
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.commitText(text, client: client)
        case .commitMarkedTextAndAppendToMarkedText(let string):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.commitText(text, client: client)
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.commitText(text, client: client)
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .submitSelectedCandidate:
            self.submitSelectedCandidate()
        case .removeLastMarkedText:
            self.segmentsManager.deleteBackwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .selectPrevCandidate:
            self.segmentsManager.requestSelectingPrevCandidate()
        case .selectNextCandidate:
            self.segmentsManager.requestSelectingNextCandidate()
        case .selectNumberCandidate(let num):
            self.segmentsManager.requestSelectingRow(self.candidatesViewController.getNumberCandidate(num: num))
            self.submitSelectedCandidate()
            self.segmentsManager.requestResettingSelection()
        case .submitHiraganaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toHiragana()
            })
        case .submitKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana()
            })
        case .submitHankakuKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .submitFullWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            })
        case .submitHalfWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .enableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: false)
        case .stopComposition:
            self.segmentsManager.stopComposition()
        case .forgetMemory:
            self.segmentsManager.forgetMemory()
        case .selectInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .commitMarkedTextAndSelectInputLanguage(let language):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            self.commitText(text, client: client)
            self.switchInputLanguage(language, client: client)
        // PredictiveSuggestion
        case .requestPredictiveSuggestion:
            // 「つづき」を直接入力し、コンテキストを渡す
            self.segmentsManager.insertAtCursorPosition("つづき", inputStyle: self.inputStyle)
            self.requestReplaceSuggestion()
        case .acceptPredictionCandidate:
            self.acceptPredictionCandidate()
        // ReplaceSuggestion
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectNextCandidate()
        case .selectPrevReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectPrevCandidate()
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate()
        case .hideReplaceSuggestionWindow:
            self.replaceSuggestionWindow.setIsVisible(false)
            self.replaceSuggestionWindow.orderOut(nil)
        // Selected Text Transform
        case .showPromptInputWindow:
            self.segmentsManager.appendDebugMessage("Executing showPromptInputWindow")
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.segmentsManager.appendDebugMessage("Executing transformSelectedText with text: '\(selectedText)' and prompt: '\(prompt)'")
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        // Unicode Input (Shift+Ctrl+U)
        case .enterUnicodeInputMode:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .appendToUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .removeLastUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                let character = String(Character(unicodeScalar))
                self.commitText(character, client: client)
            }
        case .cancelUnicodeInput:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            // 選択中の候補を確定
            self.submitSelectedCandidate()
            // 残りのテキストがあればひらがなのまま確定
            if !self.segmentsManager.isEmpty {
                let text = self.segmentsManager.convertTarget
                self.commitText(text, client: client)
                self.segmentsManager.stopComposition()
            }
        // MARK: 特殊ケース
        case .consume:
            // 何もせず先に進む
            break
        case .fallthrough:
            return false
        }

        switch clientActionCallback {
        case .fallthrough:
            break
        case .transition(let inputState):
            // 遷移した時にreplaceSuggestionWindowをhideする
            if inputState != .replaceSuggestion {
                self.replaceSuggestionWindow.orderOut(nil)
            }
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage, client: client)
            }
            self.inputState = inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty), .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            self.inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
        }

        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        return true
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("\(Bundle.main.bundleIdentifier ?? "").Roman")
            self.segmentsManager.stopJapaneseInput()
        case .japanese:
            client.selectMode("\(Bundle.main.bundleIdentifier ?? "").Japanese")
        }
    }

    func refreshCandidateWindow() {
        switch self.segmentsManager.getCurrentCandidateWindow(inputState: self.inputState) {
        case .selecting(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = true
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = false
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        let predictions = self.requestPreferredPredictionCandidates()
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }

        self.lastPredictionCandidates = candidates.map(\.text)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )

        if Config.LiveConversion().value {
            self.predictionWindow.orderFront(nil)
            return
        }

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        let frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        )
        self.predictionWindow.setFrame(frame.cgRect, display: true)
    }

    private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { text in
            Candidate(
                text: text,
                value: 0,
                composingCount: .surfaceCount(text.count),
                lastMid: 0,
                data: []
            )
        }
        guard !candidates.isEmpty else {
            return
        }
        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )
        self.predictionWindow.orderFront(nil)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    @MainActor
    private func acceptPredictionCandidate() {
        let predictions = self.requestPreferredPredictionCandidates()
        guard let prediction = predictions.first else {
            return
        }
        let deleteCount = prediction.deleteCount
        if deleteCount > 0 {
            self.segmentsManager.deleteBackwardFromCursorPosition(count: deleteCount)
        }
        let appendText = prediction.appendText

        guard !appendText.isEmpty else {
            return
        }

        self.segmentsManager.insertAtCursorPosition(appendText, inputStyle: .direct)
    }

    private func requestPreferredPredictionCandidates() -> [SegmentsManager.PredictionCandidate] {
        SegmentsManager.preferredPredictionCandidates(
            typoCorrectionCandidates: self.segmentsManager.requestTypoCorrectionPredictionCandidates(),
            predictionCandidates: self.segmentsManager.requestPredictionCandidates()
        )
    }

    var retryCount = 0
    let maxRetries = 3

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.segmentsManager.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.segmentsManager.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    func refreshMarkedText() {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState)
        for part in currentMarkedText where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        self.client()?.setMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @MainActor
    func submitCandidate(_ candidate: Candidate) {
        if let client = self.client() {
            // インサートを行う前にコンテキストを取得する
            let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30)
            self.commitText(candidate.text, client: client)
            // アプリケーションサポートのディレクトリを準備しておく
            self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext ?? "")
        }
    }

    @MainActor
    func submitSelectedCandidate() {
        if let candidate = self.segmentsManager.selectedCandidate {
            self.submitCandidate(candidate)
            self.segmentsManager.requestResettingSelection()
        }
    }
}

extension azooKeyMacInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        Task { @MainActor in
            self.submitSelectedCandidate()
        }
    }

    func candidateSelectionChanged(_ row: Int) {
        Task { @MainActor in
            self.segmentsManager.requestSelectingRow(row)
        }
    }
}

extension azooKeyMacInputController: SegmentManagerDelegate {
    func getLeftSideContext(maxCount: Int) -> String? {
        let endIndex = client().markedRange().location
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        // 同じ行の文字のみコンテキストに含める
        let leftSideContext = self.client().string(from: leftRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage("\(#function): leftSideContext=\(leftSideContext ?? "nil")")
        // azooKey Medical: アプリが前の文章を返さない（Notion や Chrome など）ときは、IME が覚えている確定済みの文章で補う
        guard Config.UseTypedHistory().value, let client = self.client(), let key = self.typedHistoryKey(client: client) else {
            return leftSideContext
        }
        let location: Int? = endIndex == NSNotFound ? nil : endIndex
        TypedHistory.shared.checkCursor(app: key, location: location)
        TypedHistory.shared.noteCompositionStart(app: key, location: location)
        return TypedHistory.merge(fromClient: leftSideContext, history: TypedHistory.shared.text(app: key), maxCount: maxCount)
    }

    func getRightSideContext(maxCount: Int) -> String? {
        let marked = client().markedRange()
        let selected = client().selectedRange()
        let base = marked.location != NSNotFound ? marked : selected
        guard base.location != NSNotFound else {
            return nil
        }
        let start = base.location + base.length
        let length = min(maxCount, max(client().length() - start, 0))
        guard length > 0 else {
            return nil
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        let text = self.client().string(from: NSRange(location: start, length: length), actualRange: &actual)
        // 頼んだ場所と違う所の文字が返ってきたら使わない（Chromium 系は手元に持っている部分だけを返すことがある）
        if actual.location != NSNotFound, actual.location != start {
            return nil
        }
        return text
    }

    func getDocumentHead(maxCount: Int) -> String? {
        var length = min(maxCount, client().length())
        // 打ちかけの文字（変換前の文字）は、文書のタイトルとして使わない
        let marked = client().markedRange()
        if marked.location != NSNotFound {
            length = min(length, marked.location)
        }
        guard length > 0 else {
            return nil
        }
        var actual = NSRange(location: NSNotFound, length: 0)
        let text = self.client().string(from: NSRange(location: 0, length: length), actualRange: &actual)
        if actual.location != NSNotFound, actual.location != 0 {
            return nil
        }
        return text
    }
}

extension azooKeyMacInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        self.segmentsManager.requestSelectingSuggestionRow(row)
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
                if let client = self.client() {
                    // 選択された候補をテキストとして挿入
                    self.commitText(candidate.text, client: client)
                    // サジェスト候補ウィンドウを非表示にする
                    self.replaceSuggestionWindow.setIsVisible(false)
                    self.replaceSuggestionWindow.orderOut(nil)
                    // 変換状態をリセット
                    self.segmentsManager.stopComposition()
                }
            }
        }
    }
}

// Suggest Candidate
extension azooKeyMacInputController {
    // MARK: - Replace Suggestion Request Handling
    @MainActor func requestReplaceSuggestion() {
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 開始")

        // リクエスト開始時に前回の候補をクリアし、ウィンドウを非表示にする
        self.segmentsManager.setReplaceSuggestions([])
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)

        // Get selected backend preference
        let preference = Config.AIBackendPreference().value

        // If backend is off, do nothing
        if preference == .off {
            self.segmentsManager.appendDebugMessage("AI backend is off, skipping suggestion")
            return
        }

        let composingText = self.segmentsManager.convertTarget

        // プロンプトを取得
        let prompt = self.getLeftSideContext(maxCount: 100) ?? ""

        self.segmentsManager.appendDebugMessage("プロンプト取得成功: \(prompt) << \(composingText)")

        let apiKey = Config.OpenAiApiKey().value
        let modelName = Config.OpenAiModelName().value
        let request = OpenAIRequest(prompt: prompt, target: composingText, modelName: modelName)
        self.segmentsManager.appendDebugMessage("APIリクエスト準備完了: prompt=\(prompt), target=\(composingText), modelName=\(modelName)")

        // Get selected backend
        let backend: AIBackend
        switch preference {
        case .off:
            // Already checked above, but defensive programming
            self.segmentsManager.appendDebugMessage("Unexpected .off state in backend selection")
            return
        case .foundationModels:
            backend = .foundationModels
        case .openAI:
            backend = .openAI
        }
        self.segmentsManager.appendDebugMessage("Using backend: \(backend.rawValue)")

        // 非同期タスクでリクエストを送信
        Task {
            do {
                self.segmentsManager.appendDebugMessage("APIリクエスト送信中...")
                let predictions = try await AIClient.sendRequest(
                    request,
                    backend: backend,
                    apiKey: apiKey,
                    apiEndpoint: Config.OpenAiApiEndpoint().value,
                    logger: { [weak self] message in
                        self?.segmentsManager.appendDebugMessage(message)
                    }
                )
                self.segmentsManager.appendDebugMessage("APIレスポンス受信成功: \(predictions)")

                // String配列からCandidate配列に変換
                let candidates = predictions.map { text in
                    Candidate(
                        text: text,
                        value: PValue(0),
                        composingCount: .surfaceCount(composingText.count),
                        lastMid: 0,
                        data: [],
                        actions: [],
                        inputable: true
                    )
                }

                self.segmentsManager.appendDebugMessage("候補変換成功: \(candidates.map { $0.text })")

                // 候補をウィンドウに更新
                await MainActor.run {
                    self.segmentsManager.appendDebugMessage("候補ウィンドウ更新中...")
                    if !candidates.isEmpty {
                        self.segmentsManager.setReplaceSuggestions(candidates)
                        self.replaceSuggestionsViewController.updateCandidatePresentations(
                            candidates.map { .init(candidate: $0) },
                            selectionIndex: nil,
                            cursorLocation: getCursorLocation()
                        )
                        self.replaceSuggestionWindow.setIsVisible(true)
                        self.replaceSuggestionWindow.makeKeyAndOrderFront(nil)
                        self.segmentsManager.appendDebugMessage("候補ウィンドウ更新完了")
                    }
                }
            } catch {
                let errorMessage = "APIリクエストエラー: \(error.localizedDescription)"
                self.segmentsManager.appendDebugMessage(errorMessage)

                // ユーザーに通知する。azooKey Medical: 入力ソフトの中で警告の窓（runModal）を出すと、閉じるまで入力が止まるので、小さな表示にする
                await MainActor.run {
                    SelectionPromptState.shared.statusPanel.show("AIの候補を出せませんでした: \(error.localizedDescription)", near: .zero, autoHideAfter: 5)
                }
            }
        }
        self.segmentsManager.appendDebugMessage("requestReplaceSuggestion: 終了")
    }

    // MARK: - Window Management
    @MainActor func hideReplaceSuggestionCandidateView() {
        self.replaceSuggestionWindow.setIsVisible(false)
        self.replaceSuggestionWindow.orderOut(nil)
    }

    @MainActor func submitSelectedSuggestionCandidate() {
        if let candidate = self.replaceSuggestionsViewController.getSelectedCandidate() {
            if let client = self.client() {
                self.commitText(candidate.text, client: client)
                self.replaceSuggestionWindow.setIsVisible(false)
                self.replaceSuggestionWindow.orderOut(nil)
                self.segmentsManager.stopComposition()
            }
        }
    }

    // MARK: - Helper Methods
    private func retrySuggestionRequestIfNeeded(cursorPosition: CGPoint) {
        if retryCount < maxRetries {
            retryCount += 1
            self.segmentsManager.appendDebugMessage("再試行中... (\(retryCount)回目)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestReplaceSuggestion()
            }
        } else {
            self.segmentsManager.appendDebugMessage("再試行上限に達しました。")
            retryCount = 0
        }
    }

}
