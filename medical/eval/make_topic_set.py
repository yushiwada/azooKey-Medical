"""title・right の欄を持つ問題（title_pairs.json・right_pairs.json）を、CliTool が読む形に直す。
CliTool（anco.patch を当てたもの）は問題ごとの topic と left_context を読むが、title と right は読まない。
そのまま渡すと、タイトルや後ろの文章なしの評価になる。
使い方: python3 -I make_topic_set.py <問題.json> <出力.json> <ime|full|left>
  ime  … IME と同じ渡し方（Core の SegmentsManager.currentTopicAndRightContext）。タイトルは、意味のあるもの
         （日付・数字だけ・「メモ」などを除く）だけ20文字までにして topic に入れる。後ろの文章は1行目を20文字まで
         right_context に入れる（変換エンジン 04ce2ec 以降の CliTool は right_context を読む）
  full … title か right をそのまま topic に入れる（2026-10-24 の評価に使った title_pairs__topic.json・right_pairs__topic.json と同じ）
  left … right を left_context に入れる（前の文章として渡したときとの比べ用。right_pairs__left.json と同じ）
"""
import json
import sys

GENERIC_TITLES = {"メモ", "ノート", "日記", "無題", "Untitled", "TODO", "Todo", "todo", "下書き", "ログ"}
DATE_CHARS = set("-/.:年月日（）() 曜火水木金土月")
LINE_BREAKS = "\n\r  \x0b\x0c\x85"


def is_informative(text):
    # SegmentsManager.isInformative と同じ: ASCII 以外の文字が2文字以上、決まり文句と日付は除く
    meaningful = [c for c in text if c.isalpha() and not c.isascii()]
    if len(meaningful) < 2 or text in GENERIC_TITLES:
        return False
    return not all(c.isnumeric() or c in DATE_CHARS for c in text)


def first_line(text):
    for i, c in enumerate(text):
        if c in LINE_BREAKS:
            return text[:i]
    return text


def strip_heading(line):
    return line.lstrip("# 　")


def ime_topic(item):
    title = item.get("title")
    if title:
        title = strip_heading(first_line(title).strip())
        left = item.get("left_context") or ""
        current = strip_heading(left.strip()) if not any(c in LINE_BREAKS for c in left) else ""
        typing_title = bool(current) and (title.startswith(current) or current.startswith(title))
        if not typing_title and is_informative(title):
            return title[:20]
    return None


def ime_right_context(item):
    right = item.get("right")
    if right:
        line = first_line(right).strip()
        if line:
            return line[:20]
    return None


def main():
    if len(sys.argv) != 4 or sys.argv[3] not in ("ime", "full", "left"):
        sys.exit(__doc__)
    items = json.load(open(sys.argv[1], encoding="utf-8"))
    mode = sys.argv[3]
    out = []
    for item in items:
        item = dict(item)
        if "title" not in item and "right" not in item:
            sys.exit(f"title も right もない問題がある: {item.get('query')}")
        if mode == "ime":
            topic = ime_topic(item)
            if topic:
                item["topic"] = topic
            right = ime_right_context(item)
            if right:
                item["right_context"] = right
        elif mode == "full":
            item["topic"] = item.get("title") or item.get("right")
        else:
            item["left_context"] = item.get("right") or ""
        out.append(item)
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    print(f"{len(out)} 問を書き出し（{mode}）: {sys.argv[2]}")


if __name__ == "__main__":
    main()
