#!/bin/bash
# ほかの Mac に入れるための配布ファイル（zip）を作る。
# 既定は公開用。次をすべて満たすアプリだけを zip にする（満たさなければ止める）:
#   識別名が local.azookeymedical.inputmethod.azooKeyMac・署名と権限が想定どおり・中の医療用語の辞書が DICT_SRC と同じで、
#   その BUILD_INFO に PUBLIC=1 がある・コードカバレッジの計測とホームフォルダのパスが入っていない
# PERSONAL=1 を付けると手元用（識別名と辞書を問わない）。名前に personal を付け、「個人用・再配布不可」の注意書きを入れる
# まとめるアプリは、既定ではこの Mac に入っている版（~/Library/Input Methods/azooKeyMac.app。APP_SRC=<アプリ> で変えられる）
# UNIVERSAL=1 を付けると、Apple Silicon と Intel の両方で動く版をビルドし直してまとめる。
#   公開用は、refs/heads/medical を取り出した変更のない作業ツリーでだけ作る。
#   ビルドはホームフォルダの外の一時フォルダで行う（実行ファイルにユーザ名入りのパスが残らないように。DERIVED=<フォルダ> で変えられる）
# 使い方: bash medical/scripts/make_dist.sh
# できるもの: medical/dist/azooKey-Medical-YYYYMMDD-HHMMSS.zip（手元用は azooKey-Medical-personal-…）と、その SHA-256（….zip.sha256）
#   zip の中身（名前はほかの OS でも化けないように英数字）: azooKeyMac.app、install.command、BUILD_STAMP.txt、
#   THIRD_PARTY_NOTICES.txt（ライセンス文）、DICTIONARY_SOURCES.txt（辞書の出典）、手元用は PERSONAL_USE_ONLY.txt も
set -euo pipefail

MED="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$MED/.." && pwd)"
# shellcheck source=app_checks.sh
source "$MED/scripts/app_checks.sh"
DIST="${DIST_DIR:-$MED/dist}"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$MED/build/xcodebuild_dist.log"
DICT_SRC="${DICT_SRC:-$MED/dictionaries/build/app_dictionary}"
APP_SRC="${APP_SRC:-$HOME/Library/Input Methods/azooKeyMac.app}"
case "${PERSONAL:-0}" in
  1) PERSONAL=1; NAME="azooKey-Medical-personal-$STAMP" ;;
  0) PERSONAL=0; NAME="azooKey-Medical-$STAMP" ;;
  *) echo "PERSONAL は 0 か 1: ${PERSONAL}"; exit 1 ;;
esac
# まとめる途中のものは一時フォルダに置き、できあがってから medical/dist へ移す（途中で止まったときに dist に残さない）
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/azkm-dist-work.XXXXXX")
WORK="$TMPROOT/$NAME"
ZIP="$DIST/$NAME.zip"
APP="$WORK/azooKeyMac.app"
mkdir -p "$DIST" "$MED/build" "$WORK"
ENTS=""
trap '[ -n "$ENTS" ] && rm -f "$ENTS"' EXIT
COMMIT="不明（この Mac に入っていた版をまとめた）"

# アプリの中身を変えたあとに署名し直す（権限は今の署名のものを引き継ぐ）
sign_again() {
  ENTS=$(mktemp "${TMPDIR:-/tmp}/azkm-ents.XXXXXX")
  codesign -d --entitlements - --xml "$APP" > "$ENTS"
  codesign --force --sign - --entitlements "$ENTS" "$APP"
  rm -f "$ENTS"
  ENTS=""
}

if [ "${UNIVERSAL:-0}" = 1 ]; then
  if [ "$PERSONAL" = 0 ]; then
    # 公開用は、公開するブランチの中身そのものからだけ作る
    MEDICAL_REV=$(git -C "$REPO" rev-parse --verify -q refs/heads/medical) || { echo "refs/heads/medical がない"; exit 1; }
    HEAD_REV=$(git -C "$REPO" rev-parse HEAD)
    if [ "$HEAD_REV" != "$MEDICAL_REV" ]; then
      echo "公開用は refs/heads/medical を取り出してから作る（今は $(git -C "$REPO" rev-parse --abbrev-ref HEAD) の ${HEAD_REV:0:7}、medical は ${MEDICAL_REV:0:7}）"
      exit 1
    fi
    if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
      echo "作業ツリーに変更があるので中止（git status で確かめる）"
      exit 1
    fi
    DERIVED="${DERIVED:-$(mktemp -d /private/tmp/azkm-dist.XXXXXX)}"
  else
    DERIVED="${DERIVED:-$MED/build/DerivedData-dist}"
  fi
  COMMIT=$(git -C "$REPO" rev-parse HEAD)
  if [ -n "$(git -C "$REPO" status --porcelain)" ]; then
    COMMIT="${COMMIT}（作業ツリーに変更あり）"
  fi
  echo "[1/5] Apple Silicon と Intel の両方向けにビルド中（ログ: ${LOG}、ビルドの場所: ${DERIVED}）"
  # コードカバレッジの計測は切る（scheme のテストの設定から Release にも入っていた）
  if ! xcodebuild -project "$REPO/azooKeyMac.xcodeproj" -scheme azooKeyMac -configuration Release \
      -derivedDataPath "$DERIVED" -skipPackagePluginValidation -skipMacroValidation \
      ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
      CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
      ENABLE_HARDENED_RUNTIME=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
      ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO build >"$LOG" 2>&1; then
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
  ditto "$DERIVED/Build/Products/Release/azooKeyMac.app" "$APP"
  if [ -d "$APP/Contents/Resources/medical_dictionary" ]; then
    mkdir -p "$MED/build/old"
    mv "$APP/Contents/Resources/medical_dictionary" "$MED/build/old/medical_dictionary-dist-$STAMP"
  fi
  if [ -f "$DICT_SRC/weak/user.louds" ] && [ -f "$DICT_SRC/strong/user.louds" ]; then
    echo "    医療用語の辞書を同梱する（${DICT_SRC}）"
    [ "$PERSONAL" = 1 ] || check_public_dictionary "$DICT_SRC"
    ditto "$DICT_SRC" "$APP/Contents/Resources/medical_dictionary"
  elif [ "$PERSONAL" = 0 ]; then
    echo "公開用の辞書がない: ${DICT_SRC}（bash medical/dictionaries/build_all.sh で作る）"
    exit 1
  fi
  # 実行ファイルからデバッグ用の記号を外す。ソースのフォルダの場所（ホームフォルダのパス）が記録されていて、
  # ビルドの場所をホームの外にしても残るため。配る版では要らない（署名はこのあと付け直す）
  strip -S "$APP/Contents/MacOS/azooKeyMac" 2>/dev/null
  sign_again
else
  echo "[1/5] この Mac に入っている版をまとめる（${APP_SRC}。Intel の Mac 向けは UNIVERSAL=1 を付けて実行）"
  [ -d "$APP_SRC" ] || { echo "アプリがない: $APP_SRC"; exit 1; }
  ditto "$APP_SRC" "$APP"
fi

echo "[2/5] 署名・権限・中身を確かめる"
codesign --verify --deep --strict "$APP"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
check_entitlements "$APP" "$BUNDLE_ID"
check_model_files "$APP/Contents/Resources/ggml-model-Q5_K_M.gguf" "$APP"/Contents/Resources/lm_*.marisa
ARCHS=$(lipo -archs "$APP/Contents/MacOS/azooKeyMac")
echo "    実行ファイルの種類: $ARCHS"
DICT_IN_APP="$APP/Contents/Resources/medical_dictionary"
if [ "$PERSONAL" = 0 ]; then
  if [ "$BUNDLE_ID" != "$PUBLIC_BUNDLE_ID" ]; then
    echo "公開用の識別名（${PUBLIC_BUNDLE_ID}）ではない: ${BUNDLE_ID}（手元用の版を自分の Mac に移すだけなら PERSONAL=1 を付ける）"
    exit 1
  fi
  check_public_dictionary "$DICT_IN_APP"
  check_dictionary_matches "$APP" "$DICT_SRC"
  check_no_coverage "$APP/Contents/MacOS/azooKeyMac"
  check_no_home_paths "$APP"
else
  if ! check_no_coverage "$APP/Contents/MacOS/azooKeyMac"; then
    echo "    [!] 手元用なので続ける（medical/scripts/build_install.sh でビルドし直すと計測なしになる）"
  fi
fi
echo "    $(describe_app "$APP")"

echo "[3/5] 導入スクリプトを入れる"
cat > "$WORK/install.command" <<'INSTALL'
#!/bin/bash
# azooKey Medical を、この Mac に入れる（sudo 不要）。
# 使い方: ターミナルで  bash ~/Downloads/azooKey-Medical-*/install.command
# 入れる前に、アプリの署名と、この Mac で動く種類かを確かめる。
# 前の版は消さずに ~/Library/Application Support/azooKey-Medical/old/ へ移す
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Input Methods"
APP="azooKeyMac.app"
KEEP="$HOME/Library/Application Support/azooKey-Medical"
STAMP=$(date +%Y%m%d-%H%M%S)

# 版の見分けに使う情報（識別名・版・署名の CDHash・実行ファイルの日時・辞書の種類）
describe() {
  local app="$1" id version cdhash built dict="辞書なし"
  id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || echo "?")
  version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo "?")
  cdhash=$(codesign -dvvv "$app" 2>&1 | sed -n 's/^CDHash=//p' || true)
  built=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$app/Contents/MacOS/azooKeyMac" 2>/dev/null || echo "?")
  if [ -f "$app/Contents/Resources/medical_dictionary/BUILD_INFO" ]; then
    dict="辞書 $(grep -E '^(PUBLIC|CREATED)=' "$app/Contents/Resources/medical_dictionary/BUILD_INFO" | tr '\n' ' ' || true)"
  elif [ -d "$app/Contents/Resources/medical_dictionary" ]; then
    dict="辞書あり"
  fi
  echo "${id} 版 ${version}・署名 ${cdhash:-?}・ビルド ${built}・${dict}"
}

echo "ダウンロードした zip が配布元のものかは、配布元が示す SHA-256 と、zip の SHA-256（shasum -a 256 で出る値）が同じかで確かめられます。"
ZIP="$(dirname "$HERE")/$(basename "$HERE").zip"
if [ -f "$ZIP" ]; then
  echo "  この zip（${ZIP}）の SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
fi
[ -d "$HERE/$APP" ] || { echo "${APP} が見つかりません（zip を展開したフォルダの中の install.command を実行してください）"; exit 1; }

# 1. 署名を確かめる（zip が壊れていないか、中身が書き換えられていないか）
if ! codesign --verify --deep --strict "$HERE/$APP"; then
  echo "アプリの署名を確かめられないので中止します（zip が壊れているか、中身が書き換えられています）"
  exit 1
fi
CDHASH=$(codesign -dvvv "$HERE/$APP" 2>&1 | sed -n 's/^CDHash=//p' || true)
echo "署名を確かめました（CDHash: ${CDHASH:-?}）"

# 2. この Mac で動く種類か（Rosetta の上のターミナルでも、Apple Silicon の Mac なら arm64 として扱う）
MACHINE=$(uname -m)
if [ "$MACHINE" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
  MACHINE=arm64
fi
ARCHS=$(lipo -archs "$HERE/$APP/Contents/MacOS/azooKeyMac")
case " $ARCHS " in
  *" $MACHINE "*) ;;
  *) echo "この Mac（${MACHINE}）では動かない版です（この版の種類: ${ARCHS}）"; exit 1 ;;
esac
NEW_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$HERE/$APP/Contents/Info.plist")
echo "入れる版: $(describe "$HERE/$APP")"
if [ -f "$HERE/BUILD_STAMP.txt" ]; then
  sed -n '1,12p' "$HERE/BUILD_STAMP.txt" | sed 's/^/  /'
fi

# 3. 入っている版を確かめる（同じ識別名のものだけを入れ替える）
if [ -d "$DEST/$APP" ]; then
  OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/$APP/Contents/Info.plist" 2>/dev/null || echo "?")
  if [ "$OLD_ID" != "$NEW_ID" ]; then
    echo "別の ${APP} が入っているので中止します（${OLD_ID}）"
    exit 1
  fi
  echo "前の版: $(describe "$DEST/$APP")"
fi

# 4. 入れる先と同じディスクに写しを作って確かめ、名前の付け替えだけで入れ替える
mkdir -p "$DEST" "$KEEP/staging"
STAGE=$(mktemp -d "$KEEP/staging/$STAMP.XXXXXX")
ditto "$HERE/$APP" "$STAGE/$APP"
# ほかの Mac から持ってきたファイルに付く「ダウンロードした印」を外す（付いたままだと macOS が読み込まない）
xattr -drs com.apple.quarantine "$STAGE/$APP" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE/$APP"
OLD_KEPT=""
if [ -d "$DEST/$APP" ]; then
  # 前の版は消さずに移す（ゴミ箱へは、macOS の保護で移せないことがある）
  mkdir -p "$KEEP/old/$STAMP"
  mv "$DEST/$APP" "$KEEP/old/$STAMP/$APP"
  OLD_KEPT="$KEEP/old/$STAMP/$APP"
fi
if ! mv "$STAGE/$APP" "$DEST/$APP"; then
  if [ -n "$OLD_KEPT" ]; then
    mv "$OLD_KEPT" "$DEST/$APP"
  fi
  echo "入れられませんでした（前の版は元に戻しました）"
  exit 1
fi
rmdir "$STAGE" 2>/dev/null || true

# 5. 動いている前の版を止める（入れ替えたあとに、この場所から起動したものだけ。元の azooKey など、ほかの場所のものは止めない）
ESCAPED=$(printf '%s' "$DEST/$APP/Contents/MacOS/" | sed 's/[][\.*+?(){}|^$]/\\&/g')
pkill -f "^$ESCAPED" 2>/dev/null || true
echo "入れました。"
if [ -n "$OLD_KEPT" ]; then
  echo "前の版は ${OLD_KEPT} に移しました（要らなければ消してかまいません）"
fi
echo "次に: システム設定 → キーボード →「入力ソース」の「編集…」→「+」→ 日本語 → 一覧からこの入力ソースを追加してください。"
echo "一覧に出なければ、一度ログアウトしてから追加してください。"
INSTALL
chmod +x "$WORK/install.command"

echo "[4/5] ライセンス文・辞書の出典・版の記録を入れる"
# 第三者の著作物のライセンス文（medical/licenses/*.txt を番号順につなげる）
{
  for f in "$MED"/licenses/*.txt; do
    echo "===== $(basename "$f") ====="
    echo
    cat "$f"
    echo
  done
} > "$WORK/THIRD_PARTY_NOTICES.txt"
# 辞書の出典の表示は、アプリの中の辞書に付いているものを使う（公開用か手元用かで文面が違う）
if [ -f "$DICT_IN_APP/NOTICE.txt" ]; then
  cp "$DICT_IN_APP/NOTICE.txt" "$WORK/DICTIONARY_SOURCES.txt"
elif [ "$PERSONAL" = 0 ]; then
  echo "アプリの中の辞書に出典の表示（NOTICE.txt）がない"
  exit 1
fi
if [ "$PERSONAL" = 1 ]; then
  cat > "$WORK/PERSONAL_USE_ONLY.txt" <<'PERSONAL_NOTE'
個人用・再配布不可

この zip は、作者が自分の Mac に入れるための手元用の版です。人に渡したり、公開したりしないでください。
医療用語の辞書に、日本医学会 医学用語辞典（JAMSMDIC）など再配布できない出典の語が入っていることがあります。
PERSONAL_NOTE
fi
{
  echo "azooKey Medical の配布ファイル（make_dist.sh が作成）"
  if [ "$PERSONAL" = 1 ]; then
    echo "種類: 手元用（個人用・再配布不可）"
  else
    echo "種類: 公開用"
  fi
  echo "作成: $(date '+%Y-%m-%d %H:%M')"
  echo "アプリ: $(describe_app "$APP")"
  echo "実行ファイルの種類: $ARCHS"
  echo "ビルドしたコミット: $COMMIT"
  if [ -f "$DICT_IN_APP/BUILD_INFO" ]; then
    echo "医療用語の辞書: $(grep -E '^(PUBLIC|CREATED|ENTRIES|SCRIPTS_COMMIT)=' "$DICT_IN_APP/BUILD_INFO" | tr '\n' ' ' || true)"
  fi
} > "$WORK/BUILD_STAMP.txt"
if [ "$PERSONAL" = 0 ]; then
  # zip に入れるものすべてに、ホームフォルダのパスがないことを確かめる
  check_no_home_paths "$WORK"
fi

echo "[5/5] zip にまとめる"
if [ -f "$ZIP" ]; then
  mkdir -p "$MED/build/old"
  mv "$ZIP" "$MED/build/old/$NAME-$(date +%H%M%S).zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$WORK" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
echo "$SHA  $(basename "$ZIP")" > "$ZIP.sha256"
# zip にしたフォルダも、中身を確かめられるように dist に置く
if [ -e "$DIST/$NAME" ]; then
  mkdir -p "$MED/build/old"
  mv "$DIST/$NAME" "$MED/build/old/$NAME-$(date +%H%M%S)"
fi
mv "$WORK" "$DIST/$NAME"
rmdir "$TMPROOT" 2>/dev/null || true
ls -lh "$ZIP"
if [ "$PERSONAL" = 1 ]; then
  echo "SHA-256: ${SHA}（${ZIP}.sha256 にも書いた。ほかの Mac に移したあと、この値で zip が壊れていないかを確かめられる）"
else
  echo "SHA-256: ${SHA}（${ZIP}.sha256 にも書いた。配布するときは、この値も一緒に載せる）"
fi
echo "完了: $ZIP"
