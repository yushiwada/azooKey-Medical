# build_install.sh と make_dist.sh が読み込む、アプリを確かめる関数（単独では実行しない）
# 使い方: source "$MED/scripts/app_checks.sh"
# どの関数も、問題があれば理由を出して 1 を返す

# 公開する版の識別名
PUBLIC_BUNDLE_ID="local.azookeymedical.inputmethod.azooKeyMac"
# 署名に入っていてよい権限。これと完全に一致すること（足りなくても多くても止める）
EXPECTED_ENTITLEMENTS="com.apple.security.app-sandbox
com.apple.security.files.user-selected.read-only
com.apple.security.network.client
com.apple.security.temporary-exception.mach-register.global-name"

# 変換AIのモデル（gguf）と言語モデル（marisa）が本物か。
# Git LFS で取り込めていないと、中身が案内の文字だけのファイルになり、変換AIなしで黙って動いてしまう
check_model_files() {  # <gguf> [<marisa> ...]
  local f magic
  magic=$(head -c 4 "$1" 2>/dev/null || true)
  if [ "$magic" != GGUF ]; then
    echo "変換AIのモデルが本物でない（先頭が GGUF でない）: $1"
    echo "  Git LFS で取り込めていない。git lfs install のあと、git submodule update --init と git lfs pull をやり直す"
    return 1
  fi
  shift
  for f in "$@"; do
    magic=$(head -c 15 "$f" 2>/dev/null || true)
    if [ "$magic" != "We love Marisa." ]; then
      echo "言語モデルが本物でない（marisa の形式でない）: $f"
      return 1
    fi
  done
  return 0
}

# 署名の権限が想定どおりか。codesign が失敗したときも止める
check_entitlements() {  # <app> <識別名>
  local app="$1" id="$2" xml json
  if ! xml=$(codesign -d --entitlements - --xml "$app" 2>/dev/null) || [ -z "$xml" ]; then
    echo "署名の権限を読めない（codesign が失敗した）: $app"
    return 1
  fi
  if ! json=$(printf '%s' "$xml" | plutil -convert json -o - -); then
    echo "署名の権限を読めない（plist として読めない）: $app"
    return 1
  fi
  if ! printf '%s' "$json" | python3 -I -c '
import json, sys
entitlements = json.load(sys.stdin)
expected = set(sys.argv[1].split())
connection = sys.argv[2] + "_Connection"
problems = []
if set(entitlements) != expected:
    problems.append(f"権限の種類が違う（多い: {sorted(set(entitlements) - expected)} / 足りない: {sorted(expected - set(entitlements))}）")
for key in ("com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-only", "com.apple.security.network.client"):
    if key in entitlements and entitlements[key] is not True:
        problems.append(f"{key} が true でない")
name = entitlements.get("com.apple.security.temporary-exception.mach-register.global-name")
if name not in (connection, [connection]):
    problems.append(f"入力ソフトの通信口の名前が {connection} でない: {name!r}")
if problems:
    sys.exit("\n".join(problems))
' "$EXPECTED_ENTITLEMENTS" "$id"; then
    echo "想定外の権限がある: $app"
    return 1
  fi
  return 0
}

# コードカバレッジの計測が入っていないか（入っていると、使うたびに計測のファイルをアプリの領域に書き出す）
check_no_coverage() {  # <実行ファイル>
  local out
  if ! out=$(otool -l "$1"); then
    echo "実行ファイルを読めない: $1"
    return 1
  fi
  case "$out" in
    *__llvm_prf_cnts*|*__LLVM_COV*)
      echo "コードカバレッジの計測が入っている: $1（ENABLE_CODE_COVERAGE=NO でビルドし直す）"
      return 1
      ;;
  esac
  return 0
}

# ホームフォルダのパス（ユーザ名を含む）がアプリの中に残っていないか。実行ファイルだけでなく、中のファイルをすべて見る
check_no_home_paths() {  # <app>
  local list rc=0
  list=$(mktemp "${TMPDIR:-/tmp}/azkm-homepaths.XXXXXX")
  grep -r -l -F -- "$HOME/" "$1" > "$list" || rc=$?
  if [ "$rc" = 0 ]; then
    echo "ホームフォルダのパス（$HOME/）を含むファイルがある:"
    sed -n '1,20p' "$list"
    rm -f "$list"
    return 1
  elif [ "$rc" != 1 ]; then
    echo "ホームフォルダのパスを探せなかった（grep の失敗 ${rc}）"
    rm -f "$list"
    return 1
  fi
  rm -f "$list"
  return 0
}

# アプリの中の医療用語の辞書が、指定した辞書と同じか
check_dictionary_matches() {  # <app> <辞書のフォルダ>
  local bundled="$1/Contents/Resources/medical_dictionary"
  if [ ! -d "$bundled" ]; then
    echo "アプリに医療用語の辞書が入っていない: $1"
    return 1
  fi
  if ! diff -r -q "$bundled" "$2" > /dev/null 2>&1; then
    echo "アプリの中の辞書が ${2} と違う:"
    diff -r -q "$bundled" "$2" 2>&1 | sed -n '1,10p' || true
    return 1
  fi
  return 0
}

# 公開用の辞書か（辞書の BUILD_INFO に PUBLIC=1 があるか）
check_public_dictionary() {  # <辞書のフォルダ>
  if [ ! -f "$1/BUILD_INFO" ] || ! grep -qx 'PUBLIC=1' "$1/BUILD_INFO"; then
    echo "公開用の辞書ではない（${1}/BUILD_INFO に PUBLIC=1 がない）。PUBLIC=1 で作った辞書を使う: bash medical/dictionaries/build_all.sh"
    return 1
  fi
  return 0
}

# 版の見分けに使う情報を1行で出す（識別名・版・署名の CDHash・実行ファイルの日時・辞書の種類）
describe_app() {  # <app>
  local app="$1" id version cdhash stamp dict="辞書なし"
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || echo "?")
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo "?")
  cdhash=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' || true)
  stamp=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$app/Contents/MacOS/azooKeyMac" 2>/dev/null || echo "?")
  if [ -f "$app/Contents/Resources/medical_dictionary/BUILD_INFO" ]; then
    dict="辞書 $(grep -E '^(PUBLIC|CREATED)=' "$app/Contents/Resources/medical_dictionary/BUILD_INFO" | tr '\n' ' ' || true)"
  elif [ -d "$app/Contents/Resources/medical_dictionary" ]; then
    dict="辞書あり（作り方の記録なし）"
  fi
  echo "${id} 版 ${version}・署名 ${cdhash:-?}・ビルド ${stamp}・${dict}"
}
