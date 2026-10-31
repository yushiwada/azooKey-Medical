@testable import Core
import KanaKanjiConverterModule
import Testing

/// テストで英単語とみなす語（macOS の綴りの辞書の代わり。辞書が実際に通す短い語・珍しい語も入れてある）
private let englishWords: Set<String> = [
    "computer", "compute", "meeting", "meetings", "ting", "tings", "test", "tests", "patient", "ent", "data", "ten", "sit",
    "kin", "kino", "app", "apple", "hates", "detest", "Excel", "net", "nonet", "check", "checks", "report", "reports", "port",
    "contest", "back", "plan", "after", "aft", "create", "carry", "tomorrow", "morrow", "nothing", "thing", "doc", "doctor"
]

private func romanElements(_ typed: String, style: InputStyle = .roman2kana) -> [ComposingText.InputElement] {
    typed.map { ComposingText.InputElement(piece: .character($0), inputStyle: style) }
}

/// 判別して入力方式を付け直したときの表示。final なら、アプリと同じく末尾に区切りを入れてから判別する
private func display(_ elements: [ComposingText.InputElement], final: Bool = false, words: Set<String> = englishWords) -> String {
    var elements = elements
    if final {
        elements.append(.init(piece: .compositionSeparator, inputStyle: elements.last?.inputStyle ?? .roman2kana))
    }
    let detections = EnglishWordDetector.detect(elements, final: final) { words.contains($0) }
    var text = ComposingText()
    text.insertAtCursorPosition(EnglishWordDetector.apply(detections, to: elements).elements)
    return text.convertTarget
}

private func display(_ typed: String, final: Bool = false, words: Set<String> = englishWords) -> String {
    display(romanElements(typed), final: final, words: words)
}

@Test func testEnglishWordInsideJapaneseStaysEnglish() {
    #expect(display("kinoucomputerwotukatta") == "きのうcomputerをつかった")
    #expect(display("meetingnoshiryou") == "meetingのしりょう")
    #expect(display("testsuru") == "testする")
    #expect(display("ctwotoru") == "CTをとる")
}

@Test func testPlainJapaneseIsUnchanged() {
    #expect(display("tenki") == "てんき")
    #expect(display("masita") == "ました")
    #expect(display("konnnichiha") == "こんにちは")
    // data は「だた」ときれいにかなになるので英語にしない
    #expect(display("data") == "だた")
    #expect(display("kyouhaiitenkidesune") == "きょうはいいてんきですね")
}

@Test func testPendingConsonantWhileTypingIsNotEnglish() {
    // tenki を打つ途中
    #expect(display("ten") == "てn")
    #expect(display("kak") == "かk")
    // 末尾の g は続きを待っているので、区切りまでは日本語のまま
    #expect(display("meeting") == "めえちんg")
    #expect(display("meeting", final: true) == "meeting")
    #expect(display("patient", final: true) == "patient")
    // 区切りの後でも、末尾の n は「ん」になるので英語にしない
    #expect(display("ten", final: true) == "てん")
}

@Test func testPreferredSplits() {
    // test＋する（tests＋うる にしない）、meeting＋する（mee＋ting にもしない）
    #expect(display("meetingsuru") == "meetingする")
    #expect(display("testsu") == "testす")
    #expect(display("tests") == "tests")
    // app＋ぇ にしない
    #expect(display("apple") == "apple")
    // 「これは」＋test＋「する」（これ＋hates＋つる にしない）、「ここで」＋test（ここ＋detest にしない）
    #expect(display("korehatestsuru") == "これはtestする")
    #expect(display("kokodetestsuru") == "ここでtestする")
    #expect(display("kinoucomputerdetestsita") == "きのうcomputerでtestした")
    // 「その」＋net（そ＋nonet にしない）、打ち始めから続く長い語は前から（to＋morrow にしない）
    #expect(display("sononet", final: true) == "そのnet")
    #expect(display("tomorrow", final: true) == "tomorrow")
    // patient を pati＋ent にしない
    #expect(display("kanojohapatientdesu") == "かのじょはpatientです")
    #expect(display("contest", final: true) == "contest")
}

@Test func testNBeforeEnglishWordBecomesN() {
    // にほn＋apple ではなく、にほん＋apple
    #expect(display("nihonapple") == "にほんapple")
    #expect(display("kakunincheck", final: true) == "かくにんcheck")
}

@Test func testWordsNotInDictionaryStayAsTyped() {
    // 英単語が見つからなければ何もしない（打ち間違いなど）
    #expect(display("arigatpu") == "ありがtぷ")
    #expect(display("kinoukomputerwotukatta") == "きのうこmぷてrをつかった")
}

@Test func testAbbreviations() throws {
    #expect(display("mriwotoru") == "MRIをとる")
    #expect(display("crpga") == "CRPが")
    #expect(display("egfrga") == "eGFRが")
    // 表にあっても、ローマ字としてかなになる略語は死んだ文字がないので日本語のまま（大文字で打てば、かなにならずにそのまま出る）
    for typed in ["ra", "pe", "mi"] {
        #expect(EnglishWordDetector.abbreviations[typed] != nil)
    }
    #expect(display("rawotoru") == "らをとる")
    #expect(display("pewotoru") == "ぺをとる")
    #expect(display("miwotoru") == "みをとる")
    #expect(display("RAwotoru") == "RAをとる")
    #expect(display("MRIwotoru") == "MRIをとる")
    // 大文字・小文字が混ざったものは略語にしない
    #expect(EnglishWordDetector.englishWord("Ct") { _ in false } == nil)
    #expect(EnglishWordDetector.englishWord("CT") { _ in false } == "CT")
    #expect(EnglishWordDetector.englishWord("ct") { _ in false } == "CT")
}

@Test func testCapitalizedWord() {
    #expect(display("watasihaExcelwotukau") == "わたしはExcelをつかう")
}

@Test func testJapaneseTypedWithShiftIsNotSplit() {
    // 小文字にすればかなにきれいに変わるので、Kin＋おう や Ten＋き にしない（今までどおりの表示）
    let words: Set<String> = ["Kin", "kin", "Kino", "Ten", "ten"]
    #expect(display("Kinou", words: words) == "Kいのう")
    #expect(display("Tenki", final: true, words: words) == "Tえんき")
}

@Test func testSearchContinuesAfterUnknownWord() {
    // github が辞書になくても、後ろの repository は英字にする
    let words: Set<String> = ["repository"]
    #expect(display("githubnirepository", words: words) == "ぎてゅbにれぽしとry")
    #expect(display("githubnirepository", final: true, words: words) == "ぎてゅbにrepository")
}

@Test func testLongerWordWinsWhenBothFit() {
    // pho＋ね、web＋して より、phone・website
    #expect(display("phone", words: ["pho", "phone"]) == "phone")
    #expect(display("website", words: ["web", "site", "website"]) == "website")
}

#if canImport(AppKit)
@Test func testSpellingCheckerCaseHandling() {
    let checker = EnglishSpellingChecker()
    #expect(checker.isEnglishWord("computer"))
    #expect(checker.isEnglishWord("Excel"))
    #expect(checker.isEnglishWord("COMPUTER"))
    #expect(!checker.isEnglishWord("kinou"))
    // 綴りの辞書は、途中に大文字がある語や大文字だけの短い語を調べずに通すので、小文字にして調べている
    #expect(!checker.isEnglishWord("iPho"))
    #expect(!checker.isEnglishWord("KINOU"))
}
#endif

@Test func testAppInputStyleAndKeyPieces() {
    // アプリは .mapped(id: .defaultRomanToKana) と .key で入れる
    let elements = "kinoucomputerwotukatta".map {
        ComposingText.InputElement(piece: .key(intention: nil, input: $0, modifiers: []), inputStyle: .mapped(id: .defaultRomanToKana))
    }
    #expect(display(elements) == "きのうcomputerをつかった")
}

@Test func testDirectInputIsLeftAsIs() {
    // 英語の入力ソースなどで打った（.direct の）要素はそのまま
    let elements = romanElements("kinou") + "comp".map { ComposingText.InputElement(character: $0, inputStyle: .direct) } + romanElements("wo")
    #expect(EnglishWordDetector.detect(elements, final: false) { englishWords.contains($0) }.isEmpty)
    #expect(display(elements) == "きのうcompを")
    // その直前の n も今までどおり（英語にしない）
    let beforeDirect = romanElements("nihon") + "PC".map { ComposingText.InputElement(character: $0, inputStyle: .direct) }
    #expect(EnglishWordDetector.detect(beforeDirect, final: false) { _ in true }.isEmpty)
}

@Test func testDetectionRangesAndSources() {
    let elements = romanElements("nihonapple")
    let detections = EnglishWordDetector.detect(elements, final: false) { englishWords.contains($0) }
    #expect(detections == [.init(range: 5..<10, displayText: nil)])
    let applied = EnglishWordDetector.apply(detections, to: elements)
    // n の後に区切りを1つ足す
    #expect(applied.elements.count == elements.count + 1)
    #expect(applied.sources == [0, 1, 2, 3, 4, nil, 5, 6, 7, 8, 9])
    #expect(applied.elements[6...].allSatisfy { $0.inputStyle == .direct })

    let abbreviation = EnglishWordDetector.detect(romanElements("ctwotoru"), final: false) { _ in false }
    #expect(abbreviation == [.init(range: 0..<2, displayText: "CT")])
}

@Test func testWordCheckerIsCalledOnlyForCandidates() {
    var asked: [String] = []
    let detections = EnglishWordDetector.detect(romanElements("kyouhaiitenkidesune"), final: true) {
        asked.append($0)
        return true
    }
    // 死んだ文字がない普通の日本語では、英単語の問い合わせをしない
    #expect(detections.isEmpty)
    #expect(asked.isEmpty)
}

/// 判別の中で使うローマ字かな変換が、変換エンジンの ComposingText と同じ結果になることを確かめる
@Test func testRomanConversionMatchesComposingText() {
    let table = EnglishWordDetector.RomanTable.defaultRomanToKana
    #expect(table.separatorRules["n"] == "ん")
    #expect(table.anyRules["n"] == "ん")
    #expect(table.pendingPrefixes.contains("ts"))
    #expect(!table.pendingPrefixes.contains("st"))

    var samples = [
        "kinoucomputerwotukatta", "meetingnoshiryou", "testsuru", "ctwotoru", "tenki", "konnnichiha", "nihonnapple",
        "Excel", "KInou", "kk", "ny", "nya", "xtsu", "ltsu", "tsu", "nn", "nnn", "xn", "zh", "kkt", "carry", "lemon",
        "pencil", "handout", "something", "immunohistochemistry", "dictionary", "effect", "three", "after", "qwerty"
    ]
    // 決まった並びの疑似乱数で、ローマ字らしい文字列とでたらめな文字列を作る
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    let alphabet = Array("aiueonnkstyhmrwgzdbpcfjlqvxAKN")
    for _ in 0..<3000 {
        var sample = ""
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let length = Int(seed >> 59) + 1
        for _ in 0..<length {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            sample.append(alphabet[Int(seed >> 33) % alphabet.count])
        }
        samples.append(sample)
    }
    for sample in samples {
        var conversion = EnglishWordDetector.RomanConversion()
        for (index, letter) in sample.enumerated() {
            conversion.add(letter, at: index, table: table)
        }
        var composingText = ComposingText()
        composingText.insertAtCursorPosition(sample, inputStyle: .roman2kana)
        #expect(String(conversion.text) == composingText.convertTarget, "open: \(sample)")
        // 残った英字は、打った文字と同じで、打った順に並ぶ
        let letters = zip(conversion.text, conversion.sources).compactMap { character, source in source.map { (character, $0) } }
        #expect(letters.allSatisfy { Array(sample)[$0.1] == $0.0 }, "sources: \(sample)")
        #expect(letters.map(\.1) == letters.map(\.1).sorted(), "order: \(sample)")

        conversion.close(table: table)
        composingText.insertAtCursorPosition([.init(piece: .compositionSeparator, inputStyle: .roman2kana)])
        #expect(String(conversion.text) == composingText.convertTarget, "closed: \(sample)")
    }
}
