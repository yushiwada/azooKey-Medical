"""辞書に入れる語から、変換を乱す語を規則で外す（build_all.sh の 7/8）。
JMED-DICT の「出現形」と「出現形よみ」は医療文書から機械的に集めたもので、読みの合わない組や語の断片が混ざっている。
これらは「せい→性欲減退」「からだ→体を」のように、普段の入力で1位に出てしまう（強く効かせる版で特に目立つ）。
  (a) 読みが表記に合わない: 表記の1字ずつ（漢字は変換エンジンの辞書の1字の語と Sudachi の語の読み、仮名はそのまま）を
      読みに割り当てられない組（例: せい→性欲減退、のうこう→脳震盪、さかと→左かかと）。連濁・促音化・連声は許す。
      字の読みは変換エンジンの2字の語からも補う（頬筋＝きょうきん → 頬＝きょう）。漢方などの決まった読みは readings_extra.tsv に置く。
      どちらにもない読みは、合わない語どうしで同じ読みが何語にも出るときだけ JMED-DICT から補う（掌蹠＝しょうせき。main を参照）
  (b) 語の断片（自分が正規形の語は除かない）
      (b1) よく使われる語の頭か尻尾が欠けた語。切れ目が Sudachi の語（mode C）の途中にあり、元の語の頻度が
           20以上かつ断片の20倍以上のもの（例: 立腺肥大症←前立腺肥大症、全身性エリテマトー←全身性エリテマトーデス）
      (b2) 漢字などのあとにカタカナ語の頭だけが付いた語。続きのある元の語（切れ目が Sudachi のカタカナ語の途中）の頻度が
           5以上かつ断片の2倍以上で、そこで語が切れる例（後ろが漢字など）より多いもの（例: 経皮的冠動脈インター）。
           長音だけを欠いた書き方（マーカ、レーザ）は除かない
  (c) 助詞などが付いた語・文: 末尾か先頭のひらがなが助詞だけのもの（例: 体を、皮膚など、の治）、
      動詞に助動詞が付いて終わるもの（例: 変わらず、認めません、腫大した）
  (d) 普段の語と同じ短い読み（4字以下）で、もとの変換（医療の辞書なし）の1位が普段の語のもの
      (d1) 表記に英数字か交ぜ書きのひらがなを含み、1位の点数が -14 以上: 両方の辞書から外す（例: いちぶ→I部、てんこう→手ん甲）
      (d2) 医療文書でもまれ（頻度10未満）で、1位がとてもよく使う語（点数 -11 以上）: 強く効かせる版（strong）だけから外す
           （例: けっか→血痂〔結果〕、かんじゃ→寒邪〔患者〕）
使い方:
  python -I clean_entries.py <sources/jmed> <作業ディレクトリ(filter)> <needed_missing.tsv> <出力.tsv> <strong から外す語.tsv> <外した語の一覧.tsv>
         --anco <CliTool> --azk-dict <変換エンジンの辞書のフォルダ(Dictionary)>
  Sudachi（sudachipy と sudachidict_core）の入った Python で動かす。
外した語の一覧は「区分<TAB>規則<TAB>読み<TAB>表記<TAB>種類<TAB>頻度<TAB>根拠」（区分は c・b・a・d1 の順に1つだけ付け、d2 は残す語のうち strong だけから外す語）。
データから補った字の読みは、一覧の名前の .tsv を .readings.tsv にしたファイルに書く。
"""
import argparse
import bisect
import csv
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

try:
    import sudachipy
    from sudachipy import Dictionary, SplitMode
except ImportError:
    sys.exit("Sudachi がない。pip install sudachipy sudachidict_core を入れた Python で動かす（build_all.sh では SUDACHI_PY=<python>）")

FILES = ["DISEASE_mini.csv", "MEDICATION_mini.csv", "BODY_mini.csv", "TEST_mini.csv"]
MANIFEST = "chunks.sha256"
# build_medical_tsv.py が表記から外す文字。括弧つきの表記（「PCI(経皮的冠動脈インターベンション)」など）は、ここで区切って断片の判定に使う
SPLIT = re.compile(r"[\s、。，．,.()（）「」『』\[\]【】/／;；:：・…\"'＋+＝=?？!！<>＜＞]+")
KANJI = re.compile(r"[一-鿿㐀-䶿〆]")
KANA_CHAR = re.compile(r"[ぁ-ゖァ-ヺー]")
HIRA_CHAR = re.compile(r"[ぁ-ゖ]")
HIRA_RUN_END = re.compile(r"[ぁ-ゖ]+$")
HIRA_RUN_START = re.compile(r"^[ぁ-ゖ]+")
KATA_CHAR = re.compile(r"[ァ-ヺー]")
KATA_END = re.compile(r"[ァ-ヺー]$")
KATA_ONLY = re.compile(r"^[ァ-ヺー]+$")
LATIN_DIGIT = re.compile(r"[A-Za-z0-9Α-Ωα-ω]")
ANSI = re.compile(r"\x1b\[[0-9;]*m")

# (b) 語の断片
FRAG_MIN_REF = 20       # (b1) 元の語の頻度の下限
FRAG_RATIO = 20         # (b1) 元の語の頻度 ÷ 断片の頻度の下限
KATA_MIN_REF = 5        # (b2) カタカナ語が続く元の語の頻度の合計の下限
KATA_RATIO = 2          # (b2) それ ÷ 断片の頻度の下限
KATA_MAX_FREQ = 10      # (b2) 断片とみなす語の頻度の上限（これ未満。「筋ジス」のようによく使う略し方は除かない）
# (c) 末尾・先頭のひらがなが、これらの助詞の組み合わせだけなら外す
#    （「か」「さ」は交ぜ書き〔右眼か＝右眼窩、尿沈さ＝尿沈渣〕と重なるので使わない。先頭では「は」「や」「が」も使わない〔はえ幼虫、やもや病、が口そう〕）
TRAIL_PARTICLES = ["を", "が", "は", "に", "へ", "で", "と", "の", "も", "や", "から", "まで", "より", "など", "だけ", "のみ",
                   "ずつ", "づつ", "くらい", "ぐらい", "ほど", "とも", "しか", "にて", "にかけて", "について", "として",
                   "において", "による", "により", "によって", "および", "ならびに", "または", "もしくは"]
LEAD_PARTICLES = ["の", "を", "に", "へ", "と", "で", "など", "より"]  # 「から」「も」は から咳（空咳）・もの忘れ と重なる
# (c) 文の終わりとみなす助動詞（直前が動詞か助動詞のとき）
CLAUSE_AUX = {"ない", "ず", "た", "だ", "ぬ", "ます", "れる", "れ", "られる", "られ", "せる", "させる", "たい", "なし", "ねば"}
# (d) 普段の語とぶつかる短い語
SHORT_READING = 4
COMMON_SCORE = -14.0       # (d1) 普段の語とみなす、もとの変換の1位の点数の下限（strong の語は -9.4、weak の語は -17.4 で出る）
VERY_COMMON_SCORE = -11.0  # (d2) とてもよく使う語とみなす点数の下限（結果 -8.8、一部 -9.1、患者 -10.9、性能 -10.7）
RARE_FREQ = 10             # (d2) まれな語とみなす JMED-DICT の頻度の上限（これ未満）


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def to_hiragana(text):
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in text)


# ---------------------------------------------------------------- 読みの照合（a）
VOICE = dict(zip("かきくけこさしすせそたちつてとはひふへほ", "がぎぐげござじずぜぞだぢづでどばびぶべぼ"))
HALF = dict(zip("はひふへほ", "ぱぴぷぺぽ"))
RENJO = dict(zip("あいうえお", "なにぬねの"))  # 連声（反応＝はんのう、観音＝かんのん）
SMALL2BIG = dict(zip("ぁぃぅぇぉゃゅょゎゕゖ", "あいうえおやゆよわかけ"))


def norm_reading(text):
    """照合用に読みをそろえる: ひらがな、ヴ→ぶなど、ぢ→じ・づ→ず、小さい仮名→大きい仮名、長音を消す"""
    text = to_hiragana(text)
    for a, b in (("ゔぁ", "ば"), ("ゔぃ", "び"), ("ゔぇ", "べ"), ("ゔぉ", "ぼ"), ("ゔ", "ぶ"), ("ぢ", "じ"), ("づ", "ず")):
        text = text.replace(a, b)
    return "".join(SMALL2BIG.get(c, c) for c in text if c != "ー")


def variants(reading):
    """連濁・半濁・連声・促音化した形も含めた読みの集合（照合用にそろえたもの）"""
    out = {reading}
    if reading and reading[0] in VOICE:
        out.add(VOICE[reading[0]] + reading[1:])
    if reading and reading[0] in HALF:
        out.add(HALF[reading[0]] + reading[1:])
    if reading and reading[0] in RENJO:
        out.add(RENJO[reading[0]] + reading[1:])
    for x in list(out):
        if len(x) >= 2 and x[-1] in "つちくき":
            out.add(x[:-1] + "っ")
    return {norm_reading(x) for x in out if x}


def kana_reading(text):
    """Sudachi の読み（カタカナ）をひらがなに。カタカナ以外を含むとき（未知語など）は None"""
    return to_hiragana(text) if re.fullmatch(r"[ァ-ヺー]+", text) else None


def load_azk_words(anco, azk_dict):
    """変換エンジンの辞書から、1字の語（漢字）と2字の語（漢字2字）の読みを集める。CliTool の dict read を読みの頭の文字ごとに呼ぶ"""
    louds = Path(azk_dict) / "louds"
    targets = []
    for p in sorted(louds.glob("*.louds")):
        m = re.fullmatch(r"\[([0-9A-F]+)\]", p.stem)
        targets.append(chr(int(m.group(1), 16)) if m else p.stem)
    if not targets:
        sys.exit(f"変換エンジンの辞書がない: {louds}")
    single, pair = defaultdict(set), defaultdict(set)
    for t in targets:
        for pattern, table in ((".", single), ("..", pair)):
            res = subprocess.run([anco, "dict", "read", t, "-d", str(azk_dict), "--word", pattern],
                                 capture_output=True, text=True)
            if res.returncode != 0:
                sys.exit(f"CliTool dict read が失敗した（{t}）: {res.stderr.strip()[:200]}")
            for line in res.stdout.splitlines():
                m = re.match(r"Ruby: (\S+) Word: (\S+) Value:", ANSI.sub("", line))
                if m and all(KANJI.match(c) or c == "々" for c in m.group(2)) and KANJI.match(m.group(2)[0]):
                    r = kana_reading(m.group(1))
                    if r:
                        table[m.group(2)].add(r)
    n1, n2 = sum(map(len, single.values())), sum(map(len, pair.values()))
    if n1 < 10000 or n2 < 50000:
        sys.exit(f"変換エンジンの辞書から読めた語が少ない（1字 {n1}・2字 {n2}）。CliTool の dict read の出力の形が変わったかもしれない")
    return single, pair


# 音読みらしい読み（頭の1字＋小さいゃゅょ＋う・ん・い・つ・く・き・ち）。データから字の読みを補うのは、音読みらしい読みがまだない字だけ
ON_LIKE = re.compile(r"^[あ-おか-ぢつ-もやゆよら-ろわ][ゃゅょ]?[うんいつくきち]?$")
ON_LIKE_NORM = re.compile(r"^[あ-おか-ぢつ-もやゆよら-ろわ][やゆよ]?[うんいつくきち]?$")  # 小さい仮名をそろえたあとの形


class ReadingChecker:
    """表記の1字ずつ（または Sudachi・変換エンジンの語ごと）に読みを割り当てて、読み全体を作れるかを確かめる"""

    def __init__(self, single, pair, sudachi, tok_a, tok_c):
        self.sudachi = sudachi
        self.tok = (tok_a, tok_c)
        self.pair = pair
        self.raw = defaultdict(set)   # 字 → 読み（そろえる前）
        for ch, rs in single.items():
            self.raw[ch] |= rs
        self.looked_up = set()
        self.cache = {}
        self.compound_cache = {}
        self.learned = defaultdict(set)  # JMED-DICT から補った2字の語の読み
        # 変換エンジンの2字の語から1字の読みを補う（例: 腓骨＝ひこつ → 腓＝ひ）。2語以上で同じになる読みだけ
        support = defaultdict(set)
        for word, rs in pair.items():
            if len(word) != 2 or "々" in word:
                continue
            x, y = word
            for r in rs:
                for rx in self.raw_of(x):
                    if r.startswith(rx) and 1 <= len(r) - len(rx) <= 4:
                        support[(y, r[len(rx):])].add(word)
                for ry in self.raw_of(y):
                    if r.endswith(ry) and 1 <= len(r) - len(ry) <= 4:
                        support[(x, r[:-len(ry)])].add(word)
        self.from_pairs = 0
        for (ch, r), words in support.items():
            # 音読みらしい形だけ（「口頬＝こうきょう」から「頬＝うきょう」のような読みを作らないため）
            if len(words) >= 2 and r not in self.raw[ch] and ON_LIKE.match(r):
                self.raw[ch].add(r)
                self.from_pairs += 1

    def raw_of(self, ch):
        if ch not in self.looked_up:
            self.looked_up.add(ch)
            for m in self.sudachi.lookup(ch):
                r = kana_reading(m.reading_form())
                if r:
                    self.raw[ch].add(r)
        return self.raw[ch]

    def has_on_like(self, ch):
        return any(ON_LIKE.match(r) for r in self.raw_of(ch))

    def add_reading(self, ch, reading):
        self.raw_of(ch)
        self.raw[ch].add(reading)
        self.cache.pop(ch, None)

    def readings_of(self, ch):
        if ch not in self.cache:
            rs = self.raw_of(ch)
            self.cache[ch] = set().union(*(variants(r) for r in rs)) if rs else set()
        return self.cache[ch]

    def compound(self, sub):
        if sub not in self.compound_cache:
            rs = set()
            for r in self.pair.get(sub, set()) | self.learned.get(sub, set()):
                rs |= variants(r)
            for m in self.sudachi.lookup(sub):
                r = kana_reading(m.reading_form())
                if r:
                    rs |= variants(r)
            self.compound_cache[sub] = rs
        return self.compound_cache[sub]

    @staticmethod
    def units(surface):
        """表記を単位に分ける: K（漢字1字）、N（仮名の続き）、W（英数字・記号の続き。読みは何でもよい）"""
        out = []
        i = 0
        while i < len(surface):
            c = surface[i]
            if KANJI.match(c) or c in "々ヶヵ":
                out.append(("K", c, i, i + 1))
                i += 1
            elif KANA_CHAR.match(c):
                j = i
                while j < len(surface) and KANA_CHAR.match(surface[j]) and surface[j] not in "ヶヵ":
                    j += 1
                out.append(("N", surface[i:j], i, j))
                i = j
            else:
                j = i
                while j < len(surface) and not (KANJI.match(surface[j]) or surface[j] in "々ヶヵ" or KANA_CHAR.match(surface[j])):
                    j += 1
                out.append(("W", surface[i:j], i, j))
                i = j
        return out

    def options(self, us):
        """単位ごとの読みの候補: ("set", 読みの集合) か ("any", 最短, 最長)"""
        opts = []
        for k, (typ, text, _, _) in enumerate(us):
            if typ == "K":
                if text in "ヶヵ":
                    rs = {"か", "が", "け", "こ"}
                elif text == "々":
                    rs = self.readings_of(us[k - 1][1]) if k > 0 and us[k - 1][0] == "K" else set()
                else:
                    rs = self.readings_of(text)
                opts.append(("set", rs) if rs else ("any", 1, 6))
            elif typ == "N":
                opts.append(("set", {norm_reading(text)}))
            elif LATIN_DIGIT.search(text):
                opts.append(("any", 1, 40))
            else:
                opts.append(("any", 0, 40))
        return opts

    def spans(self, surface, us):
        """複数の単位にまたがる読み: Sudachi の語として引ける漢字2〜4字と、Sudachi で区切った語（送り仮名つきを含む）"""
        start_of = {u[2]: k for k, u in enumerate(us)}
        end_of = {u[3]: k for k, u in enumerate(us)}
        out = defaultdict(set)  # (始まりの単位, 終わりの単位の次) → 読み
        for a in range(len(us)):
            for L in range(2, 5):
                if a + L <= len(us) and all(us[a + x][0] == "K" for x in range(L)):
                    sub = "".join(us[a + x][1] for x in range(L))
                    out[(a, a + L)] |= self.compound(sub)
        for tok in self.tok:
            pos = 0
            for m in tok.tokenize(surface):
                s, e = pos, pos + len(m.surface())
                pos = e
                r = kana_reading(m.reading_form())
                if r and s in start_of and e in end_of and end_of[e] >= start_of[s]:
                    out[(start_of[s], end_of[e] + 1)] |= variants(r)
        return out

    def reach(self, reading, us, opts, spans):
        n = len(us)
        fwd = [set() for _ in range(n + 1)]
        fwd[0].add(0)
        for a in range(n):
            if not fwd[a]:
                continue
            for j in fwd[a]:
                o = opts[a]
                if o[0] == "set":
                    for x in o[1]:
                        if reading.startswith(x, j):
                            fwd[a + 1].add(j + len(x))
                else:
                    for L in range(o[1], o[2] + 1):
                        if j + L <= len(reading):
                            fwd[a + 1].add(j + L)
                for (s, e), rs in spans.items():
                    if s == a:
                        for x in rs:
                            if reading.startswith(x, j):
                                fwd[e].add(j + len(x))
        return fwd

    def ok(self, surface, reading):
        reading = norm_reading(reading)
        us = self.units(surface)
        fwd = self.reach(reading, us, self.options(us), self.spans(surface, us))
        return len(reading) in fwd[len(us)]

    def residuals(self, surface, reading, width=1):
        """漢字 width 字（1か2）だけ読みが分からないとみなしたときに、そこに当たる読みが1通りに決まれば
        (その字, 読み, 前の字, 後ろの字) を返す（データから読みを補うのに使う）"""
        reading = norm_reading(reading)
        us = self.units(surface)
        spans = self.spans(surface, us)
        opts = self.options(us)
        out = []
        for k in range(len(us) - width + 1):
            block = us[k:k + width]
            if any(u[0] != "K" or u[1] in "々ヶヵ" for u in block):
                continue
            pre_spans = {key: v for key, v in spans.items() if key[1] <= k}
            post_spans = {(s - k - width, e - k - width): v for (s, e), v in spans.items() if s >= k + width}
            starts = self.reach(reading, us[:k], opts[:k], pre_spans)[k]
            post_us, post_opts = us[k + width:], opts[k + width:]
            cands = set()
            for j in starts:
                for L in range(width, 4 * width + 2):
                    if j + L > len(reading):
                        break
                    rest = reading[j + L:]
                    if len(rest) in self.reach(rest, post_us, post_opts, post_spans)[len(post_us)]:
                        cands.add(reading[j:j + L])
            if len(cands) == 1:
                text = "".join(u[1] for u in block)
                prev_c = surface[block[0][2] - 1] if block[0][2] > 0 else "^"
                next_c = surface[block[-1][3]] if block[-1][3] < len(surface) else "$"
                out.append((text, next(iter(cands)), prev_c, next_c))
        return out

    def known_compound(self, sub):
        return bool(self.pair.get(sub)) or any(kana_reading(m.reading_form()) for m in self.sudachi.lookup(sub))

    def add_compound(self, sub, reading):
        self.learned[sub].add(reading)
        self.compound_cache.pop(sub, None)


# ---------------------------------------------------------------- 入力
def load_jmed(src):
    """正規形が自分自身の表記の集合と、表記（括弧などで区切った片も）→ (頻度の最大, 読みの集合)"""
    canonical = set()
    pieces_freq = defaultdict(int)
    pieces_read = defaultdict(set)
    for name in FILES:
        with open(src / name, encoding="utf-8-sig", newline="") as f:
            for row in csv.DictReader(f):
                surface = unicodedata.normalize("NFKC", (row.get("出現形") or "").strip())
                if not surface or surface == "-1":
                    continue
                forms = unicodedata.normalize("NFKC", (row.get("正規形") or "").strip())
                if surface in {x.strip() for x in forms.split(";")}:
                    canonical.add(surface)
                try:
                    freq = int(row.get("FREQ:GLOBAL") or 0)
                except ValueError:
                    freq = 0
                readings = set()
                for raw in (row.get("出現形よみ") or "").split(";"):
                    r = to_hiragana(unicodedata.normalize("NFKC", raw).replace(" ", "").replace("　", ""))
                    if r and r != "-1":
                        readings.add(r)
                for piece in SPLIT.split(surface):
                    if piece:
                        pieces_freq[piece] = max(pieces_freq[piece], freq)
                        pieces_read[piece] |= readings
    return canonical, pieces_freq, pieces_read


def load_top1(workdir, wanted):
    """確認結果から、読み → (もとの変換の1位, 点数)。問題と結果の組は select_entries.py と同じ方法で確かめる"""
    manifest = workdir / MANIFEST
    if not manifest.exists():
        sys.exit(f"{manifest} がない（select_entries.py prepare を先に実行する）")
    top1 = {}
    for line in open(manifest, encoding="utf-8"):
        sha, name = line.split()
        path = workdir / name
        if not path.exists() or sha256_of(path) != sha:
            sys.exit(f"{name} が prepare のときと違う（prepare からやり直す）")
        if not name.startswith("chunk"):
            continue
        result = workdir / name.replace("chunk", "result", 1)
        stamp = result.with_name(result.name + ".chunk-sha256")
        if not result.exists() or not stamp.exists() or stamp.read_text(encoding="utf-8").strip() != sha:
            sys.exit(f"{result.name} が今の {name} に対する結果ではない（確認をやり直す）")
        items = json.load(open(path, encoding="utf-8"))
        results = json.load(open(result, encoding="utf-8"))["items"]
        if len(items) != len(results):
            sys.exit(f"{result.name} の件数 {len(results)} が {name} の {len(items)} と違う")
        for item, res in zip(items, results):
            if res.get("query") != item["query"]:
                sys.exit(f"{result.name} の結果が問題と対応しない: {item['query']} / {res.get('query')}")
            q = item["query"]
            if q in wanted and q not in top1 and res.get("outputs"):
                top1[q] = (res["outputs"][0]["text"], float(res["outputs"][0]["score"]))
        del items, results
    return top1


# ---------------------------------------------------------------- 規則
def segment_particles(text, particles):
    """text を助詞の並びに分けられるか"""
    ok = [False] * (len(text) + 1)
    ok[0] = True
    for i in range(len(text)):
        if ok[i]:
            for p in particles:
                if text.startswith(p, i):
                    ok[i + len(p)] = True
    return ok[len(text)]


def particle_rule(surface, tokens):
    """(c) の理由（当たらなければ None）"""
    m = HIRA_RUN_END.search(surface)
    if m and m.start() > 0 and not HIRA_CHAR.match(surface[m.start() - 1]) and segment_particles(m.group(), TRAIL_PARTICLES):
        return "c-末尾の助詞", f"末尾「{m.group()}」"
    m = HIRA_RUN_START.match(surface)
    if m and m.end() < len(surface) and segment_particles(m.group(), LEAD_PARTICLES):
        return "c-先頭の助詞", f"先頭「{m.group()}」"
    if len(tokens) >= 2:
        last, prev = tokens[-1], tokens[-2]
        if last[1] == "助動詞" and ((last[0] in CLAUSE_AUX and prev[1] in ("動詞", "助動詞"))
                                  or (last[0] == "ん" and prev[0] == "ませ")):
            return "c-文の終わり", "Sudachi: " + "/".join(t[0] for t in tokens[-3:])
    return None


class FragmentFinder:
    """(b) 語の断片"""

    def __init__(self, pieces_freq, pieces_read, canonical, tok_a, tok_c):
        self.freq = pieces_freq
        self.read = pieces_read
        self.canonical = canonical
        self.tok_a = tok_a
        self.tok_c = tok_c
        self.fw = sorted(pieces_freq)
        self.bw = sorted(p[::-1] for p in pieces_freq)
        self.bounds_cache = {}
        self.kata_cache = {}

    def bounds(self, text):
        """Sudachi（mode C）の語の切れ目の位置"""
        if text not in self.bounds_cache:
            pos, b = 0, {0}
            for m in self.tok_c.tokenize(text):
                pos += len(m.surface())
                b.add(pos)
            self.bounds_cache[text] = b
        return self.bounds_cache[text]

    def kata_word_at(self, text, cut):
        """cut の両側がカタカナで、cut を含む Sudachi の語（mode A）が辞書にあるカタカナ語なら、その語"""
        if not (0 < cut < len(text) and KATA_CHAR.match(text[cut - 1]) and KATA_CHAR.match(text[cut])):
            return None
        if text not in self.kata_cache:
            spans, pos = [], 0
            for m in self.tok_a.tokenize(text):
                s, e = pos, pos + len(m.surface())
                pos = e
                if not m.is_oov() and KATA_ONLY.match(m.surface()):
                    spans.append((s, e, m.surface()))
            self.kata_cache[text] = spans
        return next((w for s, e, w in self.kata_cache[text] if s < cut < e), None)

    def longer(self, surface):
        """surface で始まる語・終わる語（自分より長いもの）"""
        i = bisect.bisect_left(self.fw, surface)
        while i < len(self.fw) and self.fw[i].startswith(surface):
            if self.fw[i] != surface:
                yield "頭", self.fw[i]
            i += 1
        rs = surface[::-1]
        i = bisect.bisect_left(self.bw, rs)
        while i < len(self.bw) and self.bw[i].startswith(rs):
            if self.bw[i] != rs:
                yield "尾", self.bw[i][::-1]
            i += 1

    def find(self, reading, surface, freq):
        if surface in self.canonical:
            return None
        best = None
        # (b2) の対象: 漢字などのあとにカタカナで終わる語
        b2 = freq < KATA_MAX_FREQ and not KATA_ONLY.match(surface) and bool(KATA_END.search(surface))
        inside, inside_best, complete = 0, None, 0
        for side, whole in self.longer(surface):
            if HIRA_CHAR.search(whole) and not HIRA_CHAR.search(surface):
                continue
            if not any(reading in r and len(r) > len(reading) for r in self.read[whole]):
                continue
            cut = len(surface) if side == "頭" else len(whole) - len(surface)
            w = self.freq[whole]
            if cut not in self.bounds(whole) and (best is None or w > best[1]):
                best = (whole, w)
            if b2 and side == "頭":
                nxt = whole[cut]
                if not KATA_CHAR.match(nxt):
                    complete += w
                elif nxt != "ー" and self.kata_word_at(whole, cut):
                    inside += w
                    if inside_best is None or w > inside_best[1]:
                        inside_best = (whole, w)
        if best and best[1] >= FRAG_MIN_REF and best[1] >= FRAG_RATIO * max(1, freq):
            return "b1-長い語の一部", f"{best[0]}（頻度 {best[1]}）"
        if inside_best and inside >= KATA_MIN_REF and inside >= KATA_RATIO * max(1, freq) and inside > complete:
            return "b2-カタカナ語の頭だけ", f"{inside_best[0]}（続く語の頻度 {inside}・ここで切れる語の頻度 {complete}）"
        return None


# ---------------------------------------------------------------- 本体
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("jmed")
    ap.add_argument("workdir")
    ap.add_argument("needed")
    ap.add_argument("out")
    ap.add_argument("strong_exclude")
    ap.add_argument("report")
    ap.add_argument("--anco", required=True, help="CliTool（変換エンジンの辞書の1字の語を読む）")
    ap.add_argument("--azk-dict", required=True, help="変換エンジンの辞書のフォルダ（louds/ のある Dictionary）")
    args = ap.parse_args()
    src, workdir = Path(args.jmed), Path(args.workdir)

    entries = []
    header = []
    for line in open(args.needed, encoding="utf-8"):
        if line.startswith("#"):
            header.append(line)
            continue
        reading, surface, category, freq, flag = line.rstrip("\n").split("\t")
        entries.append((reading, surface, category, int(freq), flag, line))

    sudachi = Dictionary(dict="core")
    tok_a = sudachi.tokenizer(mode=SplitMode.A)
    tok_c = sudachi.tokenizer(mode=SplitMode.C)
    canonical, pieces_freq, pieces_read = load_jmed(src)
    single, pair = load_azk_words(args.anco, args.azk_dict)
    checker = ReadingChecker(single, pair, sudachi, tok_a, tok_c)
    # 漢方などの決まった読みで、どちらの辞書にもないもの（readings_extra.tsv）
    extra_path = Path(__file__).with_name("readings_extra.tsv")
    extra_count = 0
    for line in open(extra_path, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        surface, reading = line.rstrip("\n").split("\t")[:2]
        if len(surface) == 1:
            checker.add_reading(surface, reading)
        else:
            checker.add_compound(surface, reading)
        extra_count += 1

    # (a) の準備: 変換エンジンの辞書にも Sudachi にもない読みを、JMED-DICT の語から補う。合わない語で一部だけ読みが分からないと
    #     みなしたときのその部分の読みが、何語にもわたって同じになるとき
    #   ・漢字2字: 5語以上。その2字が変換エンジンの辞書にも Sudachi にもない語で、前の字と後ろの字がそれぞれ2通り以上あり（語として
    #     独り立ちしている）、読みが1通りのときに足す（掌蹠＝しょうせき、粥腫＝じゅくしゅ、肝蛭＝かんてつ）。片方の字の読みが
    #     分かっていれば、もう片方の字の読みも足す（蹠＝せき、粥＝じゅく）。辞書にある語（運動、腓骨、膣部 など）には足さない。
    #     JMED-DICT には「運動」を「んどう」、「腓骨」を「とうこつ」とする誤りが多くの語に繰り返し出るので、それを正しいとみなさないため
    #   ・漢字1字: 3語以上。音読みらしい読みがまだない字に、前後の字が2通り以上の語で同じになる音読みらしい読みだけ足す
    failing = [(r, s) for r, s, *_ in entries if not checker.ok(s, r)]
    added = []
    for width in (2, 1):
        support = defaultdict(lambda: (set(), set(), set()))
        for r, s in failing:
            for sub, x, prev_c, next_c in checker.residuals(s, r, width):
                words, lefts, rights = support[(sub, x)]
                words.add(s)
                lefts.add(prev_c)
                rights.add(next_c)
        strong = defaultdict(list)
        for (sub, x), (words, lefts, rights) in support.items():
            if len(words) >= (5 if width == 2 else 3):
                strong[sub].append((x, words, lefts, rights))
        for sub, cands in sorted(strong.items()):
            if width == 2:
                if len(cands) != 1 or checker.known_compound(sub):
                    continue
                x, words, lefts, rights = cands[0]
                if len(lefts) < 2 or len(rights) < 2:
                    continue
                # 片方の字はふつうの読みで、もう片方にも読みが残る分け方があること（「右腎＝じん」のような読みを足さない）
                split = next(((k, rest) for k in (0, 1) for r0 in sorted(checker.readings_of(sub[k]))
                              for rest in [x[len(r0):] if k == 0 and x.startswith(r0) else x[:-len(r0)] if k == 1 and x.endswith(r0) else ""]
                              if rest), None)
                if split is None:
                    continue
                checker.add_compound(sub, x)
                added.append((sub, x, len(words), "・".join(sorted(words)[:5])))
                k, rest = split
                other = sub[1 - k]
                if ON_LIKE_NORM.match(rest) and not checker.has_on_like(other):
                    checker.add_reading(other, rest)
                    added.append((other, rest, len(words), f"{sub}（{x}）から"))
            else:
                for x, words, lefts, rights in cands:
                    if len(lefts | rights) >= 2 and ON_LIKE_NORM.match(x) and not checker.has_on_like(sub):
                        checker.add_reading(sub, x)
                        added.append((sub, x, len(words), "・".join(sorted(words)[:5])))
        failing = [(r, s) for r, s in failing if not checker.ok(s, r)]
    failing_set = set(failing)

    top1 = load_top1(workdir, {r for r, *_ in entries if len(r) <= SHORT_READING})
    frag = FragmentFinder(pieces_freq, pieces_read, canonical, tok_a, tok_c)

    dropped = []   # (分類, 規則, 行, 根拠)
    strong_only = []
    kept_lines = []
    counts = defaultdict(int)
    flagged_any = defaultdict(int)
    for reading, surface, category, freq, flag, line in entries:
        tokens = [(m.surface(), m.part_of_speech()[0]) for m in tok_c.tokenize(surface)]
        hits = []
        c = particle_rule(surface, tokens)
        if c:
            hits.append(("c",) + c)
        b = frag.find(reading, surface, freq)
        if b:
            hits.append(("b",) + b)
        if (reading, surface) in failing_set:
            sud = "".join(to_hiragana(m.reading_form()) for m in tok_c.tokenize(surface))
            hits.append(("a", "a-読みが表記に合わない", f"Sudachi の読み「{sud}」"))
        d = None
        if len(reading) <= SHORT_READING and reading in top1 and top1[reading][1] >= COMMON_SCORE:
            t1, score = top1[reading]
            odd = (LATIN_DIGIT.search(surface) and (KANJI.search(surface) or KANA_CHAR.search(surface))) or \
                  (HIRA_CHAR.search(surface) and KANJI.search(surface))
            if odd:
                d = ("d1", "d1-英数字か交ぜ書きの短い語", f"もとの1位「{t1}」{score:.1f}")
            elif freq < RARE_FREQ and score >= VERY_COMMON_SCORE:
                d = ("d2", "d2-まれな短い語（strong だけ）", f"もとの1位「{t1}」{score:.1f}・頻度 {freq}")
        if d:
            hits.append(d)
        for h in hits:
            flagged_any[h[0]] += 1
        main_hit = next((h for h in hits if h[0] != "d2"), None)
        if main_hit:
            dropped.append((main_hit[0], main_hit[1], reading, surface, category, freq, main_hit[2]))
            counts[main_hit[0]] += 1
            continue
        kept_lines.append(line)
        if d and d[0] == "d2":
            strong_only.append((reading, surface, category, freq, d[2]))
            counts["d2"] += 1

    out = Path(args.out)
    tmp = out.with_name(out.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        for h in header:
            f.write(h.replace("# 出典:", "# 変換を乱す語（clean_entries.py）を除いた語。出典:", 1))
        f.writelines(kept_lines)
    tmp.replace(out)
    ex = Path(args.strong_exclude)
    tmp = ex.with_name(ex.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("# 強く効かせる版（strong）だけから外す語（clean_entries.py の d2）。読み\t表記\n")
        for reading, surface, *_ in strong_only:
            f.write(f"{reading}\t{surface}\n")
    tmp.replace(ex)
    rep = Path(args.report)
    order = {"c": 0, "b": 1, "a": 2, "d1": 3, "d2": 4}
    rows = sorted(dropped + [("d2", "d2-まれな短い語（strong だけ）", r, s, c, f, why) for r, s, c, f, why in strong_only],
                  key=lambda x: (order[x[0]], x[1], -x[5], x[2]))
    tmp = rep.with_name(rep.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("区分\t規則\t読み\t表記\t種類\t頻度\t根拠\n")
        for row in rows:
            f.write("\t".join(map(str, row)) + "\n")
    tmp.replace(rep)
    readings_path = rep.with_name(rep.stem + ".readings.tsv")
    tmp = readings_path.with_name(readings_path.name + ".tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("字\t補った読み\t合わなかった語の数\t例\n")
        for row in added:
            f.write("\t".join(map(str, row)) + "\n")
    tmp.replace(readings_path)
    by_rule = defaultdict(int)
    for row in rows:
        by_rule[row[1]] += 1
    print(f"Sudachi {sudachipy.__version__ if hasattr(sudachipy, '__version__') else '?'}・"
          f"変換エンジンの1字の語 {sum(map(len, single.values()))}・2字の語 {sum(map(len, pair.values()))}"
          f"（2字の語から補った1字の読み {checker.from_pairs}、readings_extra.tsv の読み {extra_count}、JMED-DICT から補った読み {len(added)}）")
    print(f"残す {len(kept_lines)} 語 / 外す {len(dropped)} 語（"
          + "・".join(f"{k} {counts[k]}" for k in ("c", "b", "a", "d1")) + f"）、strong だけから外す {counts['d2']} 語")
    print("  規則ごと: " + "・".join(f"{k} {v}" for k, v in sorted(by_rule.items())))
    print("  重なりを含めた該当数: " + "・".join(f"{k} {flagged_any[k]}" for k in ("c", "b", "a", "d1", "d2")))


if __name__ == "__main__":
    main()
