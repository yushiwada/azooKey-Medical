import Foundation

/// IME を通して確定した文章を、入力欄ごとに直近の分だけ覚えておく（azooKey Medical で追加）。
/// Notion や Chrome のように、入力ソフトへ前の文章を返さないアプリでも、文脈を使って変換するため。
/// 覚えるのはメモリの中だけで、ファイルには保存しない。`app` には、アプリと入力欄を見分ける文字列を渡す
public final class TypedHistory: @unchecked Sendable {  // 中身は NSLock で守っている
    public static let shared = TypedHistory()

    /// アプリごとに覚える文字数
    public static let maxLength = 100
    /// これより長く打たなければ忘れる（秒）
    public static let idleInterval: TimeInterval = 180

    private struct Entry {
        var text: String = ""
        var lastUpdate: Date = .distantPast
        /// いま打っている文字列の始まりの位置（アプリが教えてくれるときだけ）
        var compositionStart: Int?
        /// 次に打ち始めるはずの位置。確定した直後にアプリへ問い合わせると、
        /// Chrome などは古い位置を返すことがあるので、「打ち始めた位置＋確定した文字数」で計算する
        var expectedLocation: Int?
        /// 範囲を選び直したなど、次に打ち始める位置が分からなくなった。次に打ち始めるときに忘れる
        var forgetOnNextComposition = false
    }

    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    /// 確定した文字列を書き足す
    public func append(_ text: String, app: String, now: Date = Date()) {
        guard !text.isEmpty else { return }
        self.update(app: app, now: now) { entry in
            entry.text = String((entry.text + text).suffix(Self.maxLength))
            if let start = entry.compositionStart {
                // NSRange の位置は UTF-16 の単位で数える
                entry.expectedLocation = start + text.utf16.count
                entry.compositionStart = entry.expectedLocation
            } else {
                entry.expectedLocation = nil
            }
        }
    }

    /// 改行を書き足す。Notion などは改行で新しいブロックになり位置の数え方が変わるので、位置は分からないものとする
    public func appendNewline(app: String, now: Date = Date()) {
        self.update(app: app, now: now) { entry in
            entry.text = String((entry.text + "\n").suffix(Self.maxLength))
            entry.compositionStart = nil
            entry.expectedLocation = nil
        }
    }

    /// いま打っている文字列の始まりの位置を記録する（アプリが教えてくれたときに呼ぶ）
    public func noteCompositionStart(app: String, location: Int?) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let location, var entry = self.entries[app] else {
            return
        }
        entry.compositionStart = location
        self.entries[app] = entry
    }

    /// 入力ソフトを通らずにアプリへ渡った削除キー（1文字消す）
    public func deleteBackward(app: String, now: Date = Date()) {
        self.update(app: app, now: now) { entry in
            if !entry.text.isEmpty {
                entry.text.removeLast()
            }
            entry.compositionStart = nil
            entry.expectedLocation = nil
        }
    }

    /// カーソルが動いたなど、覚えた文章が前の文章と合わなくなったとき
    public func reset(app: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[app] = nil
    }

    /// Shift と矢印で範囲を選び直したときなど。選んだ文の手前を探すのには使えるよう、すぐには忘れず、次に打ち始めるときに忘れる
    public func markCursorUncertain(app: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard var entry = self.entries[app] else {
            return
        }
        entry.forgetOnNextComposition = true
        entry.expectedLocation = nil
        self.entries[app] = entry
    }

    /// 入力を始めるときに呼ぶ。アプリが教えるカーソル位置が、最後に確定した位置と違えば忘れる
    public func checkCursor(app: String, location: Int?) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[app] else {
            return
        }
        if entry.forgetOnNextComposition {
            self.entries[app] = nil
            return
        }
        guard let expected = entry.expectedLocation, let location else {
            return
        }
        if location != expected {
            self.entries[app] = nil
        }
    }

    /// 長く打っていない入力欄の分を消す（読まれなくてもメモリに残り続けないように、こまめに呼ぶ）
    public func purgeExpired(now: Date = Date()) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries = self.entries.filter { now.timeIntervalSince($0.value.lastUpdate) <= Self.idleInterval }
    }

    /// 覚えている前の文章（長く打っていなければ空）
    public func text(app: String, now: Date = Date()) -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.entries[app] else {
            return ""
        }
        if now.timeIntervalSince(entry.lastUpdate) > Self.idleInterval {
            self.entries[app] = nil
            return ""
        }
        return entry.text
    }

    /// アプリから受け取った前の文章と、覚えている文章を合わせる。
    /// アプリが何も返さなければ覚えている文章を使い、アプリの文章が覚えている文章の末尾と一致すれば、覚えている方で前に伸ばす
    public static func merge(fromClient: String?, history: String, maxCount: Int) -> String? {
        let client = fromClient ?? ""
        if client.isEmpty {
            return history.isEmpty ? fromClient : String(history.suffix(maxCount))
        }
        if client.count < maxCount, history.count > client.count, history.hasSuffix(client) {
            return String(history.suffix(maxCount))
        }
        return fromClient
    }

    /// 選んだ文が、覚えている文章の最後に打った部分なら、その手前の部分を返す。
    /// アプリが選択範囲の前の文章を返さないとき、その代わりに使う。最後に打った部分でなければ（昔の段落を選んだなど）nil
    public static func textBefore(selection: String, history: String) -> String? {
        let trimmedHistory = history.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty, trimmedHistory.hasSuffix(trimmedSelection) else {
            return nil
        }
        let before = String(trimmedHistory.dropLast(trimmedSelection.count))
        return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : before
    }

    private func update(app: String, now: Date, _ body: (inout Entry) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var entry = self.entries[app] ?? Entry()
        if now.timeIntervalSince(entry.lastUpdate) > Self.idleInterval {
            entry = Entry()
        }
        body(&entry)
        entry.lastUpdate = now
        self.entries[app] = entry
    }
}
