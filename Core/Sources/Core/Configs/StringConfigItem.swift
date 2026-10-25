//
//  StringConfigItem.swift
//  azooKeyMac
//
//  Created by miwa on 2024/04/27.
//

import Foundation

protocol StringConfigItem: ConfigItem<String> {}

extension StringConfigItem {
    public var value: String {
        get {
            UserDefaults.standard.string(forKey: Self.key) ?? ""
        }
        nonmutating set {
            UserDefaults.standard.set(newValue, forKey: Self.key)
        }
    }
}

extension Config {
    public struct ZenzaiProfile: StringConfigItem {
        public init() {}

        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.ZenzaiProfile"
    }
}

extension Config {
    /// OpenAIモデル名
    public struct OpenAiModelName: StringConfigItem {
        public init() {}

        public static let `default`: String = LocalModelList.recommendedModel()  // azooKey Medical: この Mac のメモリに合うモデル（Ollama の名前）
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.OpenAiModelName"

        /// 保存していないとき（空のとき）は、おすすめのモデルを使う。空のまま送ると、サーバーが「モデルの指定がない」と断る
        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// OpenAI API エンドポイント
    public struct OpenAiApiEndpoint: StringConfigItem {
        public init() {}

        public static let `default` = "http://127.0.0.1:11434/v1/chat/completions"  // azooKey Medical: この Mac の Ollama
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.OpenAiApiEndpoint"

        public var value: String {
            get {
                let stored = UserDefaults.standard.string(forKey: Self.key) ?? ""
                return stored.isEmpty ? Self.default : stored
            }
            nonmutating set {
                UserDefaults.standard.set(newValue, forKey: Self.key)
            }
        }
    }

    /// プロンプト履歴（JSON形式で保存）
    public struct PromptHistory: StringConfigItem {
        public static let key: String = "dev.ensan.inputmethod.azooKeyMac.preference.PromptHistory"
    }
}
