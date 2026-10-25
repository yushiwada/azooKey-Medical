import Foundation

protocol BoolConfigItem: ConfigItem<Bool> {
    static var `default`: Bool { get }
}

extension BoolConfigItem {
    public var value: Bool {
        get {
            if let value = UserDefaults.standard.object(forKey: Self.key) {
                value as? Bool ?? Self.default
            } else {
                Self.default
            }
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    /// デバッグウィンドウにd/Dで遷移する設定
    public struct DebugWindow: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.enableDebugWindow"
    }
    /// 予測入力のデバッグ機能を有効化する設定
    public struct DebugPredictiveTyping: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.predictiveTyping"
    }
    /// 入力訂正のデバッグ機能を有効化する設定
    public struct DebugTypoCorrection: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.debug.typoCorrection"
    }
    /// ライブ変換を有効化する設定
    public struct LiveConversion: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.enableLiveConversion"
    }
    /// 前の行も変換の文脈に含める設定（azooKey Medical で追加）
    public struct MultiLineLeftContext: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.multiLineLeftContext"
    }
    /// アプリに同梱した医療用語の辞書を使う設定（azooKey Medical で追加）
    public struct MedicalDictionary: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.medicalDictionary"
    }
    /// 前の文章が医療の内容なら医療用語の辞書を強く効かせる設定（azooKey Medical で追加・実験的）
    public struct MedicalContextBoost: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.medicalContextBoost"
    }
    /// IME で確定した文章を覚えて、アプリが前の文章を返さないときの文脈に使う設定（azooKey Medical で追加。メモリのみ）
    public struct UseTypedHistory: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.useTypedHistory"
    }
    /// ノートのタイトルを話題として変換AIに渡す設定（azooKey Medical で追加・実験的）
    public struct UseDocumentTitle: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.useDocumentTitle"
    }
    /// カーソルの後ろの文章を話題として変換AIに渡す設定（azooKey Medical で追加・実験的）
    public struct UseRightSideContext: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.useRightSideContext"
    }
    /// 範囲を選んでショートカット（既定は Option+Return）を押すと、選んだ文をAIへの指示として実行する（azooKey Medical で追加）
    public struct SelectionPromptEnabled: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.selectionPromptEnabled"
    }
    /// Ctrl+S で、続きの文や言い換えの候補を AI に出させる（元の azooKey の機能）。
    /// azooKey Medical は AI を最初から使うので、元の azooKey と同じ動き（Ctrl+S をアプリに渡す）になるよう、この機能だけ既定で OFF にする
    public struct ControlSSuggestion: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.controlSSuggestion"
    }
    /// 円マークの代わりにバックスラッシュを入力する設定
    public struct TypeBackSlash: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.typeBackSlash"
    }
    /// 「　」の代わりに「 」を入力する設定
    public struct TypeHalfSpace: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.typeHalfSpace"
    }
    /// Optionキー押下時に直接全角英数を入力する設定
    public struct OptionDirectFullWidthInput: BoolConfigItem {
        public init() {}
        static let `default` = false
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.optionDirectFullWidthInput"
    }
    /// AI変換時にコンテキストを含めるかどうか
    public struct IncludeContextInAITransform: BoolConfigItem {
        public init() {}
        static let `default` = true
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.includeContextInAITransform"
    }
}
