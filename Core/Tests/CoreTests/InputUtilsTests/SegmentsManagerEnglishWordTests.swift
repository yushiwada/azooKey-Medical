@testable import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

/// テストで英単語とみなす語（macOS の綴りの辞書の代わり）
private let englishWords: Set<String> = ["computer", "compute", "meeting", "apple"]

private let romanInputStyle: InputStyle = .mapped(id: .defaultRomanToKana)

private func makeSegmentsManager() -> SegmentsManager {
    SegmentsManager(
        kanaKanjiConverter: .withDefaultDictionary(),
        applicationDirectoryURL: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
        containerURL: nil,
        context: .init(useZenzai: false) { englishWords.contains($0) }
    )
}

/// アプリと同じく、日本語入力のローマ字の打鍵を1文字ずつ入れる
@MainActor
private func typeRoman(_ text: String, into manager: SegmentsManager) {
    for character in text {
        manager.insertAtCursorPosition(pieces: [.key(intention: nil, input: character, modifiers: [])], inputStyle: romanInputStyle)
    }
}

/// 設定を切り替えて実行し、元に戻す
@MainActor
private func withAutoEnglishWord(_ enabled: Bool, _ body: () -> Void) {
    let defaults = UserDefaults.standard
    let key = Config.AutoEnglishWord.key
    let original = defaults.object(forKey: key) as? Bool
    defer {
        if let original {
            defaults.set(original, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
    Config.AutoEnglishWord().value = enabled
    body()
}

@Suite(.serialized)
@MainActor
struct SegmentsManagerEnglishWordTests {
    @Test func typingEnglishWordInJapaneseKeepsLetters() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("kinoucomputerwotukatta", into: manager)
            #expect(manager.convertTarget == "きのうcomputerをつかった")
            let marked = manager.getCurrentMarkedText(inputState: .composing).map(\.content).joined()
            #expect(marked.contains("computer"))
        }
    }

    @Test func pendingConsonantBecomesEnglishAfterSeparator() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("meeting", into: manager)
            #expect(manager.convertTarget == "めえちんg")
            manager.insertCompositionSeparator(inputStyle: romanInputStyle)
            #expect(manager.convertTarget == "meeting")
        }
    }

    @Test func enterCommitChecksPendingConsonant() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("kinoumeeting", into: manager)
            #expect(manager.convertTarget == "きのうめえちんg")
            manager.checkEnglishWordsBeforeCommit(inputState: .composing)
            #expect(manager.convertTarget == "きのうmeeting")
            let committed = manager.commitMarkedText(inputState: .composing)
            #expect(committed.hasSuffix("meeting"))
            #expect(manager.isEmpty)

            // アプリ側から確定させられるときは、今までどおり見えているまま確定する
            let other = makeSegmentsManager()
            typeRoman("kinoumeeting", into: other)
            #expect(!other.commitMarkedText(inputState: .composing).contains("meeting"))
        }
    }

    @Test func deletingLettersChecksTheWordAgain() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("kinoucomputer", into: manager)
            #expect(manager.convertTarget == "きのうcomputer")
            manager.deleteBackwardFromCursorPosition()
            #expect(manager.convertTarget == "きのうcompute")
            // comput は英単語ではないので、ローマ字のかなに戻る
            manager.deleteBackwardFromCursorPosition()
            #expect(manager.convertTarget == "きのうこmぷt")
            // 打ち直せば、また英字になる
            typeRoman("er", into: manager)
            #expect(manager.convertTarget == "きのうcomputer")
        }
    }

    @Test func movingSegmentStopsDetectionForThisInput() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("kinou", into: manager)
            manager.editSegment(count: -1)
            manager.deleteBackwardFromCursorPosition()
            typeRoman("computer", into: manager)
            #expect(manager.convertTarget == "きのこmぷてr")
            // 次の入力では、また判別する
            manager.stopComposition()
            typeRoman("computer", into: manager)
            #expect(manager.convertTarget == "computer")
        }
    }

    @Test func settingOffKeepsRomanInput() {
        withAutoEnglishWord(false) {
            let manager = makeSegmentsManager()
            typeRoman("kinoucomputer", into: manager)
            #expect(manager.convertTarget == "きのうこmぷてr")
        }
    }

    @Test func lettersFromEnglishInputSourceAreUnchanged() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("kinou", into: manager)
            // 英語の入力ソースで打った文字は .direct で入る
            manager.insertAtCursorPosition(pieces: "comp".map { .character($0) }, inputStyle: .direct)
            typeRoman("wo", into: manager)
            #expect(manager.convertTarget == "きのうcompを")

            let other = makeSegmentsManager()
            typeRoman("nihon", into: other)
            other.insertAtCursorPosition(pieces: "PC".map { .character($0) }, inputStyle: .direct)
            #expect(other.convertTarget == "にほnPC")
        }
    }

    @Test func nBeforeEnglishWordBecomesN() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("nihonapple", into: manager)
            #expect(manager.convertTarget == "にほんapple")
        }
    }

    @Test func firstClauseCandidateDoesNotSplitEnglishWord() {
        withAutoEnglishWord(true) {
            let manager = makeSegmentsManager()
            typeRoman("meetingnoshiryou", into: manager)
            manager.insertCompositionSeparator(inputStyle: romanInputStyle, skipUpdate: true)
            manager.update(requestRichCandidates: false)
            switch manager.getCurrentCandidateWindow(inputState: .selecting) {
            case .selecting(let candidates, _):
                #expect(candidates.first?.text.hasPrefix("meeting") == true)
            case .hidden, .composing:
                Issue.record("Expected selecting state after requesting candidates.")
            }
        }
    }
}
