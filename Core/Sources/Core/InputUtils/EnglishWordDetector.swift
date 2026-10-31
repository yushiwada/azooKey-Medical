#if canImport(AppKit)
import AppKit
#endif
import Foundation
import KanaKanjiConverterModule

/// azooKey Medical: 日本語のローマ字入力のまま打った英単語（kinoucomputerwotukatta の computer など）を見つけ、その部分を英字のまま残すための判別。
///
/// - かなに変われない英字（死んだ文字。computer の m など）があるときだけ探す。普通の日本語の入力は死んだ文字がないので、すぐに抜ける
/// - 打っている途中で続きを待っている末尾の英字（tenki を打つ途中の ten の n など）は死んだ文字にしない。
///   区切りの後（final）は末尾の英字も死んだ文字として見る（ただし末尾の n は「ん」になるので除く）
/// - 死んだ文字より前の、かなにきれいに変わる位置から始まり、死んだ文字を含む英単語を探す。残りの部分も同じように調べる
enum EnglishWordDetector {
    /// 英字のまま残す範囲
    struct Detection: Sendable, Equatable {
        /// 入力要素の添字の範囲
        var range: Range<Int>
        /// 表示する文字（略語を大文字にするとき。nil なら打った文字のまま）
        var displayText: String?
    }

    /// 英単語として探す長さの上限
    static let maxWordLength = 24

    /// よく使う医療の略語。小文字で打っても、この表の形で出す（2文字でもよい）。
    /// ra・pe・mi のようにローマ字としてかなに変わるものは死んだ文字がないので、表にあっても日本語のまま
    static let abbreviations: [String: String] = [
        "ct": "CT", "mri": "MRI", "ecg": "ECG", "crp": "CRP", "wbc": "WBC", "rbc": "RBC", "plt": "PLT", "hb": "Hb",
        "ast": "AST", "alt": "ALT", "ldh": "LDH", "ck": "CK", "bun": "BUN", "cre": "Cre", "egfr": "eGFR",
        "bp": "BP", "hr": "HR", "rr": "RR", "icu": "ICU", "er": "ER", "dm": "DM", "ckd": "CKD", "copd": "COPD",
        "pe": "PE", "mi": "MI", "ra": "RA", "sle": "SLE", "dic": "DIC", "pci": "PCI", "cpr": "CPR", "cpa": "CPA",
        "dnr": "DNR", "aed": "AED", "ef": "EF", "gcs": "GCS", "jcs": "JCS"
    ]

    /// 英単語の前に来やすい助詞（この後から始まる英単語を優先する）
    private static let particlesBeforeWord: Set<Character> = ["は", "が", "を", "に", "で", "と", "の", "も", "へ", "や"]
    /// 英単語の後に続きやすいかなの頭（助詞・する・です など）
    private static let naturalFollowingKana: Set<Character> = ["を", "が", "は", "に", "で", "と", "の", "も", "へ", "や", "か", "な", "ね", "よ", "す", "さ", "し", "せ", "だ"]
    private static let naturalFollowingPrefixes: Set<String> = ["って", "じゃ", "まで"]

    /// 英字のまま残す範囲を返す
    /// - Parameters:
    ///   - elements: 入力要素の並び（カーソルは末尾にあるものとする）
    ///   - final: 区切りを入れた後か（末尾の英字を、続きを待っていないものとして見る）
    ///   - isEnglishWord: 英単語かどうかを答える関数（3文字以上の語に対して呼ぶ）
    static func detect(_ elements: [ComposingText.InputElement], final: Bool, isEnglishWord: (String) -> Bool) -> [Detection] {
        // 区切りが途中にある入力は、区切りをまたいでかなに変わることがあるので扱わない
        if elements.dropLast().contains(where: { $0.piece == .compositionSeparator }) {
            return []
        }
        let letters = elements.map(Self.romanLetter(of:))
        return withoutActuallyEscaping(isEnglishWord) { isEnglishWord in
            var detections: [Detection] = []
            var index = 0
            while index < elements.count {
                guard letters[index] != nil else {
                    index += 1
                    continue
                }
                var end = index
                while end < elements.count, letters[end] != nil {
                    end += 1
                }
                // 後ろがローマ字入力の区切りや記号なら、末尾の n は「ん」になり、ほかの英字は残る。
                // 後ろが英語の入力などで打った要素なら、末尾の英字は続きを待っているものと同じに扱う（にほn＋英語で打った語 の n など）
                let closed = end < elements.count ? Self.isRomanInput(elements[end].inputStyle) : final
                let search = RunSearch(
                    letters: letters[index..<end].compactMap { $0 },
                    closed: closed,
                    table: .defaultRomanToKana,
                    isEnglishWord: isEnglishWord
                )
                for detection in search.detections() {
                    let range = (detection.range.lowerBound + index)..<(detection.range.upperBound + index)
                    detections.append(Detection(range: range, displayText: detection.displayText))
                }
                index = end
            }
            return detections
        }
    }

    /// 判別の結果に合わせて入力方式を付け直した要素の並びと、その各要素が元のどの要素にあたるか（判別のために足した区切りは nil）を返す
    static func apply(_ detections: [Detection], to elements: [ComposingText.InputElement]) -> (elements: [ComposingText.InputElement], sources: [Int?]) {
        var result: [ComposingText.InputElement] = []
        var sources: [Int?] = []
        result.reserveCapacity(elements.count + detections.count)
        sources.reserveCapacity(elements.count + detections.count)
        var next = 0
        for detection in detections where next <= detection.range.lowerBound && detection.range.upperBound <= elements.count {
            for index in next..<detection.range.lowerBound {
                result.append(elements[index])
                sources.append(index)
            }
            // 英単語の直前のローマ字が n で終わるときは、区切りを入れて「ん」にする（にほn＋apple → にほん＋apple）
            if let separator = Self.separatorBeforeWord(at: detection.range.lowerBound, notBefore: next, in: elements) {
                result.append(separator)
                sources.append(nil)
            }
            // 略語の表示は打った英字と同じ長さのものだけ（要素と1文字ずつ対応させる）
            let display: [Character]? = detection.displayText.flatMap { $0.count == detection.range.count ? Array($0) : nil }
            for (offset, index) in detection.range.enumerated() {
                guard let character = display?[offset] ?? Self.romanLetter(of: elements[index]) else {
                    result.append(elements[index])
                    sources.append(index)
                    continue
                }
                result.append(.init(piece: .character(character), inputStyle: .direct))
                sources.append(index)
            }
            next = detection.range.upperBound
        }
        for index in next..<elements.count {
            result.append(elements[index])
            sources.append(index)
        }
        return (result, sources)
    }

    /// 日本語のローマ字入力で打った英字（a〜z・A〜Z）なら、その文字
    static func romanLetter(of element: ComposingText.InputElement) -> Character? {
        guard Self.isRomanInput(element.inputStyle) else {
            return nil
        }
        // 変換の表は、意図した文字（intention）があればそれで引く
        let character: Character? = switch element.piece {
        case .character(let c): c
        case .key(intention: let intention, input: let input, modifiers: _): intention ?? input
        case .compositionSeparator: nil
        }
        guard let character, character.isASCIILetter else {
            return nil
        }
        return character
    }

    /// 既定のローマ字かな変換の表を使う入力方式か（アプリは .mapped(id: .defaultRomanToKana) で入れる）
    static func isRomanInput(_ style: InputStyle) -> Bool {
        style == .roman2kana || style == .mapped(id: .defaultRomanToKana)
    }

    /// 打った英字が英単語（または表にある略語）なら、表示する文字を返す
    static func englishWord(_ typed: String, isEnglishWord: (String) -> Bool) -> String? {
        let lowercased = typed.lowercased()
        if typed == lowercased || typed == typed.uppercased(), let abbreviation = Self.abbreviations[lowercased] {
            return abbreviation
        }
        guard typed.count >= 3, isEnglishWord(typed) else {
            return nil
        }
        return typed
    }

    private static func separatorBeforeWord(at start: Int, notBefore lowerLimit: Int, in elements: [ComposingText.InputElement]) -> ComposingText.InputElement? {
        var head = start
        while head > lowerLimit, Self.romanLetter(of: elements[head - 1]) != nil {
            head -= 1
        }
        guard head < start else {
            return nil
        }
        let table = RomanTable.defaultRomanToKana
        var conversion = RomanConversion()
        for (index, letter) in zip(head..<start, elements[head..<start].compactMap(Self.romanLetter(of:))) {
            conversion.add(letter, at: index, table: table)
        }
        let pending = conversion.pendingLength(table: table)
        guard pending > 0, table.separatorRules[String(conversion.text.suffix(pending))] != nil else {
            return nil
        }
        return .init(piece: .compositionSeparator, inputStyle: elements[start - 1].inputStyle)
    }

    private static func startsNaturally(_ text: [Character]) -> Bool {
        guard let first = text.first else {
            return true
        }
        return Self.naturalFollowingKana.contains(first) || Self.naturalFollowingPrefixes.contains(String(text.prefix(2)))
    }
}

// MARK: - ローマ字かな変換のようすを、打った位置つきで追う
extension EnglishWordDetector {
    /// ローマ字かな変換の表（変換エンジンの既定の表を文字列に書き出したものから作る）
    struct RomanTable: Sendable {
        /// 英字だけのキー → 出力（ka → か、kk → っk）
        var rules: [String: String] = [:]
        /// 「X{any character}」の X → 出力のうち {any character} より前（n → ん）
        var anyRules: [String: String] = [:]
        /// 「X{composition-separator}」の X → 出力（n → ん）
        var separatorRules: [String: String] = [:]
        /// キーの先頭になりうる英字の並び（キーそのものより短いもの）。末尾がこれなら、続きを待っている
        var pendingPrefixes: Set<String> = []
        var maxKeyLength = 0
        var maxPendingLength = 0
        var maxSeparatorKeyLength = 0

        /// 変換エンジンの既定のローマ字かな変換の表
        static let defaultRomanToKana = RomanTable(exported: (try? InputStyleManager.exportTable(InputTable.defaultRomanToKana)) ?? "")

        init(exported: String) {
            let anyToken = "{any character}"
            let separatorToken = "{composition-separator}"
            for line in exported.split(separator: "\n") {
                let columns = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard columns.count == 2 else {
                    continue
                }
                let key = String(columns[0])
                let value = String(columns[1])
                if key.hasSuffix(anyToken) && value.hasSuffix(anyToken) {
                    let head = String(key.dropLast(anyToken.count))
                    guard !head.isEmpty, !head.contains("{") else {
                        continue
                    }
                    self.anyRules[head] = String(value.dropLast(anyToken.count))
                    self.addPendingPrefixes(of: head, includingWhole: true)
                    self.maxKeyLength = max(self.maxKeyLength, head.count + 1)
                } else if key.hasSuffix(separatorToken) {
                    let head = String(key.dropLast(separatorToken.count))
                    guard !head.isEmpty, !head.contains("{"), !value.contains("{") else {
                        continue
                    }
                    self.separatorRules[head] = value
                    self.addPendingPrefixes(of: head, includingWhole: true)
                    self.maxSeparatorKeyLength = max(self.maxSeparatorKeyLength, head.count)
                } else if !key.isEmpty, !key.contains("{"), !value.contains("{") {
                    self.rules[key] = value
                    self.addPendingPrefixes(of: key, includingWhole: false)
                    self.maxKeyLength = max(self.maxKeyLength, key.count)
                }
            }
            self.maxPendingLength = self.pendingPrefixes.map(\.count).max() ?? 0
        }

        private mutating func addPendingPrefixes(of key: String, includingWhole: Bool) {
            let characters = Array(key)
            let maxLength = includingWhole ? characters.count : characters.count - 1
            guard maxLength >= 1 else {
                return
            }
            for length in 1...maxLength {
                self.pendingPrefixes.insert(String(characters.prefix(length)))
            }
        }
    }

    /// 変換エンジンの表と同じ決まり（末尾から一番長く合うキーを使う。英字だけのキーを {any character} のキーより先に使う）で英字をかなに変えていき、
    /// どの英字がかなにならずに残ったかを、打った位置つきで追う
    struct RomanConversion {
        private(set) var text: [Character] = []
        /// text の各文字が、かなにならずに残った英字ならその打った位置（かななら nil）
        private(set) var sources: [Int?] = []
        private(set) var letterCount = 0

        mutating func add(_ letter: Character, at index: Int, table: RomanTable) {
            let lookback = self.trailingLetterCount(limit: max(0, table.maxKeyLength - 1))
            for headLength in stride(from: lookback, through: 0, by: -1) {
                let head = Array(self.text.suffix(headLength))
                let headSources = self.sources.suffix(headLength).compactMap { $0 }
                if let output = table.rules[String(head) + String(letter)] {
                    self.replaceTail(headLength, with: output, key: head + [letter], keySources: headSources + [index])
                    return
                }
                if headLength > 0, let output = table.anyRules[String(head)] {
                    self.replaceTail(headLength, with: output + String(letter), key: head + [letter], keySources: headSources + [index])
                    return
                }
            }
            self.append(letter, source: index)
        }

        /// 区切りを入れたときの変化（末尾の n → ん）
        mutating func close(table: RomanTable) {
            let lookback = self.trailingLetterCount(limit: table.maxSeparatorKeyLength)
            for headLength in stride(from: lookback, through: 1, by: -1) {
                let head = Array(self.text.suffix(headLength))
                if let output = table.separatorRules[String(head)] {
                    self.replaceTail(headLength, with: output, key: head, keySources: self.sources.suffix(headLength).compactMap { $0 })
                    return
                }
            }
        }

        /// 末尾で続きを待っている英字の数
        func pendingLength(table: RomanTable) -> Int {
            let lookback = self.trailingLetterCount(limit: table.maxPendingLength)
            for length in stride(from: lookback, through: 1, by: -1) where table.pendingPrefixes.contains(String(self.text.suffix(length))) {
                return length
            }
            return 0
        }

        /// ここで区切っても英字が残らない（末尾の n は区切りで「ん」になる）なら、区切ったときの最後のかなを返す
        func cleanBoundary(at index: Int, table: RomanTable) -> CleanBoundary? {
            let pending = self.pendingLength(table: table)
            guard self.letterCount == pending else {
                return nil
            }
            guard pending > 0 else {
                return CleanBoundary(index: index, lastKana: self.text.last)
            }
            guard let output = table.separatorRules[String(self.text.suffix(pending))], !output.contains(where: \.isASCIILetter) else {
                return nil
            }
            return CleanBoundary(index: index, lastKana: output.last ?? self.text.dropLast(pending).last)
        }

        private func trailingLetterCount(limit: Int) -> Int {
            var count = 0
            while count < limit, count < self.sources.count, self.sources[self.sources.count - 1 - count] != nil {
                count += 1
            }
            return count
        }

        private mutating func replaceTail(_ count: Int, with output: String, key: [Character], keySources: [Int]) {
            self.letterCount -= self.sources.suffix(count).filter { $0 != nil }.count
            self.text.removeLast(count)
            self.sources.removeLast(count)
            let outputCharacters = Array(output)
            var outputSources = [Int?](repeating: nil, count: outputCharacters.count)
            // 出力の末尾の英字は、キーの末尾の同じ英字にあたる（kk → っk の k、ny → ny など）
            var outputIndex = outputCharacters.count - 1
            var keyIndex = min(key.count, keySources.count) - 1
            while outputIndex >= 0, keyIndex >= 0, outputCharacters[outputIndex].isASCIILetter, outputCharacters[outputIndex] == key[keyIndex] {
                outputSources[outputIndex] = keySources[keyIndex]
                outputIndex -= 1
                keyIndex -= 1
            }
            for (character, source) in zip(outputCharacters, outputSources) {
                // 対応の分からない英字は、いま打った英字にあたるものとする
                self.append(character, source: character.isASCIILetter ? (source ?? keySources.last) : nil)
            }
        }

        private mutating func append(_ character: Character, source: Int?) {
            self.text.append(character)
            self.sources.append(source)
            if source != nil {
                self.letterCount += 1
            }
        }
    }

    /// かなにきれいに変わる区切り
    struct CleanBoundary {
        /// 区切りの位置（その前までがかなになる）
        var index: Int
        /// 区切ったときの最後のかな
        var lastKana: Character?
    }

    /// 英字の並びの一部を変換したようす
    struct RomanAnalysis {
        /// かなにならずに残り、もう変われない英字（死んだ文字）の位置
        var deadIndices: [Int]
        /// 末尾に、続きを待っている英字があるか
        var hasPending: Bool
        /// かなにきれいに変わる区切り（範囲の頭も含む）
        var cleanBoundaries: [CleanBoundary]
        /// 続きを待っている英字がない位置（その後のかなの変わり方は、前とつながらない）
        var settledIndices: [Int]
        /// 変換した文字
        var text: [Character]

        init(letters: [Character], range: Range<Int>, closed: Bool, table: RomanTable) {
            var conversion = RomanConversion()
            var cleanBoundaries = [CleanBoundary(index: range.lowerBound, lastKana: nil)]
            var settledIndices: [Int] = []
            for index in range {
                conversion.add(letters[index], at: index, table: table)
                if let boundary = conversion.cleanBoundary(at: index + 1, table: table) {
                    cleanBoundaries.append(boundary)
                }
                if conversion.pendingLength(table: table) == 0 {
                    settledIndices.append(index + 1)
                }
            }
            if closed {
                conversion.close(table: table)
            }
            let pendingLength = closed ? 0 : conversion.pendingLength(table: table)
            self.deadIndices = Array(conversion.sources.compactMap { $0 }.dropLast(pendingLength))
            self.hasPending = pendingLength > 0
            self.cleanBoundaries = cleanBoundaries
            self.settledIndices = settledIndices
            self.text = conversion.text
        }
    }
}

// MARK: - 英単語の候補を探す
private extension EnglishWordDetector {
    /// ローマ字入力の英字が続いた部分の中で、英単語を探す
    struct RunSearch {
        /// 打った英字
        let letters: [Character]
        /// かなへの変わり方を見るための英字（小文字にしたもの。Shift を押したまま打った Kinou の K を死んだ文字にしない）
        let lowercasedLetters: [Character]
        /// 後ろに区切りや記号があるか（末尾の英字は続きを待っていない）
        let closed: Bool
        let table: RomanTable
        let isEnglishWord: (String) -> Bool

        init(letters: [Character], closed: Bool, table: RomanTable, isEnglishWord: @escaping (String) -> Bool) {
            self.letters = letters
            self.lowercasedLetters = letters.map { $0.lowercased().first ?? $0 }
            self.closed = closed
            self.table = table
            self.isEnglishWord = isEnglishWord
        }

        func detections() -> [Detection] {
            var detections: [Detection] = []
            var start = 0
            while start < self.letters.count {
                let analysis = self.analyze(start..<self.letters.count)
                // 死んだ文字がなければ、ここから後ろは日本語のまま
                guard let firstDead = analysis.deadIndices.first else {
                    break
                }
                guard let best = self.bestCandidate(analysis, firstDead: firstDead) else {
                    // この死んだ文字を含む英単語がない（打ち間違い・辞書にない語）。かなの変わり方が前とつながらない所から、続きを探す
                    guard let next = analysis.settledIndices.first(where: { $0 > firstDead }) else {
                        break
                    }
                    start = next
                    continue
                }
                detections.append(Detection(range: best.range, displayText: best.displayText))
                start = best.range.upperBound
            }
            return detections
        }

        private func analyze(_ range: Range<Int>) -> RomanAnalysis {
            RomanAnalysis(letters: self.lowercasedLetters, range: range, closed: self.closed, table: self.table)
        }

        /// かなにきれいに変わる区切りから始まり、最初の死んだ文字を含む英単語のうち、一番よいもの
        private func bestCandidate(_ analysis: RomanAnalysis, firstDead: Int) -> Candidate? {
            var best: Candidate?
            for boundary in analysis.cleanBoundaries where boundary.index <= firstDead && firstDead - boundary.index < EnglishWordDetector.maxWordLength {
                let start = boundary.index
                let lowerEnd = max(firstDead + 1, start + 2)
                let upperEnd = min(self.letters.count, start + EnglishWordDetector.maxWordLength)
                guard lowerEnd <= upperEnd else {
                    continue
                }
                for end in lowerEnd...upperEnd {
                    guard let candidate = self.candidate(start..<end, after: boundary) else {
                        continue
                    }
                    if best.map({ candidate.isPreferred(over: $0) }) ?? true {
                        best = candidate
                    }
                }
            }
            return best
        }

        /// range の英字が英単語（または略語）なら、そこを英字にしたときの候補
        private func candidate(_ range: Range<Int>, after boundary: CleanBoundary) -> Candidate? {
            let typed = String(self.letters[range])
            guard let word = EnglishWordDetector.englishWord(typed, isEnglishWord: self.isEnglishWord) else {
                return nil
            }
            let rest = self.analyze(range.upperBound..<self.letters.count)
            // 前が英字の続きの頭か助詞（「これは」＋test）、後ろが空か助詞・する・です など（test＋「する」）なら自然
            let startsNaturally = range.lowerBound == 0 || boundary.lastKana.map { EnglishWordDetector.particlesBeforeWord.contains($0) } == true
            let endsNaturally = EnglishWordDetector.startsNaturally(rest.text)
            return Candidate(
                range: range,
                displayText: word == typed ? nil : word,
                restDeadCount: rest.deadIndices.count,
                restHasPending: rest.hasPending,
                naturalness: [startsNaturally, endsNaturally].filter { $0 }.count
            )
        }
    }

    struct Candidate {
        var range: Range<Int>
        var displayText: String?
        /// 残りの部分の死んだ文字の数
        var restDeadCount: Int
        /// 残りの部分の末尾に、続きを待っている英字があるか
        var restHasPending: Bool
        /// 前が英字の続きの頭か助詞であること、後ろが空か助詞・する・です などで始まること、のうち満たす数（0〜2）
        var naturalness: Int

        /// (1) 残りの死んだ文字が少ない (2) 残りの末尾に待ちの英字がない
        /// (3) 前後が自然（test＋する を tests＋うる にしない。app＋ぇ にしない） (4) 前から始まる（meeting を mee＋ting にしない）
        /// (5) 長い（phone を pho＋ね に、website を web＋して にしない）
        func isPreferred(over other: Candidate) -> Bool {
            if self.restDeadCount != other.restDeadCount {
                return self.restDeadCount < other.restDeadCount
            }
            if self.restHasPending != other.restHasPending {
                return !self.restHasPending
            }
            if self.naturalness != other.naturalness {
                return self.naturalness > other.naturalness
            }
            if self.range.lowerBound != other.range.lowerBound {
                return self.range.lowerBound < other.range.lowerBound
            }
            return self.range.count > other.range.count
        }
    }
}

/// azooKey Medical: 英単語かどうかを macOS の綴りの辞書（NSSpellChecker。この Mac の中だけで動く）で調べる。
/// 打つたびに同じ語を問い合わせないよう、結果を覚えておく
final class EnglishSpellingChecker {
    /// 入力欄ごとの SegmentsManager で共有する（使うのはメインスレッドからだけ）
    nonisolated(unsafe) static let shared = EnglishSpellingChecker()

    private var cache: [String: Bool] = [:]
    private let maxCacheCount = 10_000
    private var isPrepared = false

    /// 綴りの辞書を前もって起こしておく（初めて調べるときに入力が止まらないように）。2回目からは何もしない
    func prepare() {
        guard !self.isPrepared else {
            return
        }
        self.isPrepared = true
        #if canImport(AppKit)
        let text = "prepare"
        _ = NSSpellChecker.shared.requestChecking(
            of: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            types: NSTextCheckingResult.CheckingType.spelling.rawValue,
            options: nil,
            inSpellDocumentWithTag: 0
        ) { _, _, _, _ in }
        #endif
    }

    func isEnglishWord(_ word: String) -> Bool {
        // 綴りの辞書は、途中に大文字がある語（iPho など）や大文字だけの短い語（TENKI など）を調べずに通すので、
        // 頭だけ大文字の語と小文字だけの語のほかは、小文字にしてから調べる
        let key = word.dropFirst().contains(where: \.isUppercase) ? word.lowercased() : word
        if let cached = self.cache[key] {
            return cached
        }
        let result = Self.checkSpelling(key)
        if self.cache.count >= self.maxCacheCount {
            self.cache.removeAll(keepingCapacity: true)
        }
        self.cache[key] = result
        return result
    }

    private static func checkSpelling(_ word: String) -> Bool {
        #if canImport(AppKit)
        let misspelled = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location == NSNotFound
        #else
        return false
        #endif
    }
}

private extension Character {
    var isASCIILetter: Bool {
        self.isASCII && self.isLetter
    }
}
