import Foundation

/// キーボードショートカットを表す構造体
public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var key: String
    public var modifiers: KeyEventCore.ModifierFlag

    public init(key: String, modifiers: KeyEventCore.ModifierFlag) {
        self.key = key
        self.modifiers = modifiers
    }

    /// デフォルトのショートカット（Control+S）
    public static let defaultTransformShortcut = KeyboardShortcut(
        key: "s",
        modifiers: .control
    )

    /// 選んだ文を AI への指示として実行するショートカットの初期値（Option+Return。azooKey Medical で追加）
    public static let defaultSelectionPromptShortcut = KeyboardShortcut(
        key: "\r",
        modifiers: .option
    )

    /// macOS 15 以降、OS が「コンテキストメニューを表示」に使うキー（Control+Return）。
    /// OS が IME より先に受け取るので、IME のショートカットには使えない
    public static let systemContextMenuShortcut = KeyboardShortcut(
        key: "\r",
        modifiers: .control
    )

    /// 表示用の文字列（例: "⌃S"）
    public var displayString: String {
        var result = ""

        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }

        switch key {
        case "\r":
            result += "⏎"
        case " ":
            result += "Space"
        case "\t":
            result += "⇥"
        default:
            result += key.uppercased()
        }
        return result
    }
}

protocol KeyboardShortcutConfigItem: ConfigItem<KeyboardShortcut> {
    static var `default`: KeyboardShortcut { get }
}

extension KeyboardShortcutConfigItem {
    public var value: KeyboardShortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.key) else {
                return Self.default
            }
            do {
                let decoded = try JSONDecoder().decode(KeyboardShortcut.self, from: data)
                return decoded
            } catch {
                return Self.default
            }
        }
        nonmutating set {
            do {
                let encoded = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(encoded, forKey: Self.key)
            } catch {
                // エンコード失敗時は何もしない
            }
        }
    }
}

extension Config {
    /// いい感じ変換のキーボードショートカット
    public struct TransformShortcut: KeyboardShortcutConfigItem {
        public init() {}

        public static let `default`: KeyboardShortcut = .defaultTransformShortcut
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.transform_shortcut"
    }

    /// 選んだ文を AI への指示として実行するキーボードショートカット（azooKey Medical で追加）
    public struct SelectionPromptShortcut: KeyboardShortcutConfigItem {
        public init() {}

        public static let `default`: KeyboardShortcut = .defaultSelectionPromptShortcut
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.selection_prompt_shortcut"
    }
}
