#!/bin/bash
# azooKey Medical をビルドし、~/Library/Input Methods に入れる（sudo 不要）。
# 使い方: bash medical/scripts/build_install.sh
#   医療用語の辞書は medical/dictionaries/build/app_dictionary にあれば同梱する（作り方は medical/README.md）
#   DICT_SRC=<フォルダ> で別の辞書を指定できる
# ビルドしたものはそのまま使わず、写しを作ってから辞書を入れ替えて署名し直し、確かめてから入れ替える
set -euo pipefail

MED="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MED/.." && pwd)"
# shellcheck source=app_checks.sh
source "$MED/scripts/app_checks.sh"
DEST_DIR="$HOME/Library/Input Methods"
APP_NAME="azooKeyMac.app"
LOG="$MED/build/xcodebuild.log"
DICT_SRC="${DICT_SRC:-$MED/dictionaries/build/app_dictionary}"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$MED/build/old"

# 個人用の ad-hoc 署名でビルドする（Apple Developer の登録は不要）。
# コードカバレッジの計測は切る（scheme のテストの設定から Release にも入り、使うたびに計測のファイルを書き出していた）
BUILD_ARGS=(
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  ENABLE_HARDENED_RUNTIME=NO
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  ENABLE_CODE_COVERAGE=NO
  CLANG_COVERAGE_MAPPING=NO
)

STAGE=""
ENTS=""
cleanup() {
  [ -n "$ENTS" ] && rm -f "$ENTS"
  # 入れ替える前に止まったときの写しは、消さずに old/ へ移す
  if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
    mv "$STAGE" "$MED/build/old/stage-failed-$STAMP"
  fi
}
trap cleanup EXIT

echo "[0/4] 変換AIのモデルと言語モデルが取り込めているかを確かめる"
check_model_files "$REPO/azooKeyMac/Resources/gguf/ggml-model-Q5_K_M.gguf" "$REPO"/azooKeyMac/Resources/base_n5_lm/*.marisa

echo "[1/4] ビルド中（ログ: ${LOG}）"
if ! xcodebuild -project "$REPO/azooKeyMac.xcodeproj" -scheme azooKeyMac -configuration Release \
    -skipPackagePluginValidation -skipMacroValidation \
    "${BUILD_ARGS[@]}" build >"$LOG" 2>&1; then
  echo "ビルドに失敗した（ログ: ${LOG}）"
  # エラーの行がなければ、ログの最後を出す
  ERRORS=$(grep -E 'error:|BUILD FAILED' "$LOG" || true)
  if [ -n "$ERRORS" ]; then
    sed -n '1,30p' <<<"$ERRORS"
  else
    tail -30 "$LOG"
  fi
  exit 1
fi

PRODUCTS_DIR=$(xcodebuild -project "$REPO/azooKeyMac.xcodeproj" -scheme azooKeyMac -configuration Release \
  -skipPackagePluginValidation -skipMacroValidation \
  "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / && !found {print $2; found=1}')  # 途中で読むのをやめると、出力側が止められて失敗扱いになる
BUILT="$PRODUCTS_DIR/$APP_NAME"
[ -d "$BUILT" ] || { echo "ビルド成果物が見つからない: $BUILT"; exit 1; }

# ビルドの成果物（DerivedData の中で使い回される）には手を入れず、写しに辞書を入れる。
# 写しは入れる先と同じディスクに置き、最後は名前の付け替えだけで入れ替える
# 前の作り方でビルドの成果物に直接入れた辞書が残っていれば、消さずに退避する（辞書を指定しないときに古い辞書が残らないように）
if [ -d "$BUILT/Contents/Resources/medical_dictionary" ]; then
  mv "$BUILT/Contents/Resources/medical_dictionary" "$MED/build/old/medical_dictionary-$STAMP"
fi
STAGE="$MED/build/stage-$STAMP"
mkdir -p "$STAGE"
APP="$STAGE/$APP_NAME"
ditto "$BUILT" "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
if [ -f "$DICT_SRC/weak/user.louds" ] && [ -f "$DICT_SRC/strong/user.louds" ]; then
  echo "[+] 医療用語の辞書を同梱する（${DICT_SRC}）"
  ditto "$DICT_SRC" "$APP/Contents/Resources/medical_dictionary"
  check_dictionary_matches "$APP" "$DICT_SRC"
  if [ -f "$DICT_SRC/BUILD_INFO" ]; then
    echo "    $(grep -E '^(PUBLIC|CREATED|ENTRIES)=' "$DICT_SRC/BUILD_INFO" | tr '\n' ' ' || true)"
  else
    echo "    辞書に作り方の記録（BUILD_INFO）がない。古い作り方の辞書かもしれない"
  fi
else
  echo "[!] 医療用語の辞書が見つからないので、辞書なしで入れる（${DICT_SRC}）"
fi
echo "    署名し直す"
ENTS=$(mktemp "${TMPDIR:-/tmp}/azkm-ents.XXXXXX")
codesign -d --entitlements - --xml "$APP" > "$ENTS" 2>/dev/null
codesign --force --sign - --entitlements "$ENTS" "$APP"

echo "[2/4] 署名と権限と中身を確かめる（ネット通信の権限はあるが、接続先はこの Mac の中だけにコードで制限している）"
codesign --verify --deep --strict "$APP"
check_entitlements "$APP" "$BUNDLE_ID"
check_no_coverage "$APP/Contents/MacOS/azooKeyMac"
check_model_files "$APP/Contents/Resources/ggml-model-Q5_K_M.gguf" "$APP"/Contents/Resources/lm_*.marisa
echo "    入れる版: $(describe_app "$APP")"

echo "[3/4] 入力ソースのフォルダへ入れる（${BUNDLE_ID}）"
mkdir -p "$DEST_DIR"
if [ -d "$DEST_DIR/$APP_NAME" ]; then
  # 同じ識別名の前の版だけを、消さずに退避する
  OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_DIR/$APP_NAME/Contents/Info.plist")
  [ "$OLD_ID" = "$BUNDLE_ID" ] || { echo "別の $APP_NAME が入っている（${OLD_ID}）ので中止"; exit 1; }
  echo "    前の版: $(describe_app "$DEST_DIR/$APP_NAME")"
  mv "$DEST_DIR/$APP_NAME" "$MED/build/old/previous-$STAMP.app"
fi
if ! mv "$APP" "$DEST_DIR/$APP_NAME"; then
  # 入れられなかったら前の版を戻す
  [ -d "$MED/build/old/previous-$STAMP.app" ] && mv "$MED/build/old/previous-$STAMP.app" "$DEST_DIR/$APP_NAME"
  echo "入れられなかった（前の版に戻した）"
  exit 1
fi
rmdir "$STAGE" 2>/dev/null || true
STAGE=""
# 動いている前の版を止める（入れ替えたあとに、この場所から起動したものだけ。元の azooKey など、別の場所のものは止めない）
ESCAPED=$(printf '%s' "$DEST_DIR/$APP_NAME/Contents/MacOS/" | sed 's/[][\.*+?(){}|^$]/\\&/g')
pkill -f "^$ESCAPED" 2>/dev/null || true

echo "[4/4] 入力ソースとして登録"
swift "$MED/scripts/register_input_source.swift" "$DEST_DIR/$APP_NAME" || true
echo "完了。システム設定 → キーボード →「入力ソース」の「編集…」→「+」→ 日本語 →「azooKey Medical (日本語)」を追加してください（初回のみ）"
