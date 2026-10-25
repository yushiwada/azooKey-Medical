// 入力ソースを登録する（選択中の入力ソースは切り替えない）。
// macOS 26 では他社製の入力ソースをプログラムから有効にしても残らないので、最後はシステム設定で追加する。
// 使い方: swift register_input_source.swift <アプリのパス> [--disable]
import Carbon
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: register_input_source.swift <app path> [--disable]")
    exit(2)
}
let appURL = URL(fileURLWithPath: args[1])
let disable = args.contains("--disable")
guard let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
      let bundleID = info["CFBundleIdentifier"] as? String else {
    print("Info.plist から識別名を読めない: \(appURL.path)")
    exit(1)
}

func stringProperty(_ source: TISInputSource, _ key: CFString) -> String? {
    guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
    return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func sources() -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: bundleID] as CFDictionary
    return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
}

if !disable {
    let status = TISRegisterInputSource(appURL as CFURL)
    print("TISRegisterInputSource: \(status == noErr ? "OK" : "error \(status)")")
}
for source in sources() {
    let id = stringProperty(source, kTISPropertyInputSourceID) ?? "?"
    let status = disable ? TISDisableInputSource(source) : TISEnableInputSource(source)
    print("\(disable ? "disable" : "enable") \(id): \(status == noErr ? "OK" : "error \(status)")")
}
