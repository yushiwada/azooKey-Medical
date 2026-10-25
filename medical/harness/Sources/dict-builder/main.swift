// TSV（読み<TAB>表記[<TAB>コスト]）から、変換エンジンが読むコンパイル済みの user 辞書（user.louds など）を作る。
// 使い方: dict-builder <charID.chid> <出力ディレクトリ> <TSV> [<TSV> ...]
// 同じ読みと表記の組が複数の TSV にあるときは、先に渡した TSV の行を使う。
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import SwiftUtils

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: dict-builder <charID.chid> <out dir> <tsv> [<tsv> ...]")
    exit(2)
}
let charIDString = try String(contentsOfFile: args[1], encoding: .utf8)
let char2UInt8 = Dictionary(uniqueKeysWithValues: charIDString.enumerated().map { ($0.element, UInt8($0.offset)) })
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let defaultValue: PValue = -8
// 品詞（環境変数 DICT_CID=proper で固有名詞、既定は一般名詞）
let entryCID = ProcessInfo.processInfo.environment["DICT_CID"] == "proper" ? CIDData.固有名詞.cid : CIDData.一般名詞.cid
var seen = Set<String>()
var entries: [DicdataElement] = []
var skipped = 0
for path in args.dropFirst(3) {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 2 else { skipped += 1; continue }
        let ruby = cols[0].trimmingCharacters(in: .whitespaces).toKatakana()
        let word = cols[1].trimmingCharacters(in: .whitespaces)
        // 辞書の文字表にない文字を含む読みは引けないので外す
        guard !ruby.isEmpty, !word.isEmpty, ruby.allSatisfy({ char2UInt8[$0] != nil }) else {
            skipped += 1
            continue
        }
        guard seen.insert(ruby + "\t" + word).inserted else { continue }
        let value = cols.count >= 3 ? (Float(cols[2]).map { PValue($0) } ?? defaultValue) : defaultValue
        entries.append(DicdataElement(word: word, ruby: ruby, cid: entryCID, mid: MIDData.一般.mid, value: value))
    }
}
try DictionaryBuilder.exportDictionary(
    entries: entries,
    to: outDir,
    baseName: "user",
    shardByFirstCharacter: false,
    char2UInt8: char2UInt8
)
print("書き出し: \(entries.count) 語（除外 \(skipped) 行）→ \(outDir.path)")
