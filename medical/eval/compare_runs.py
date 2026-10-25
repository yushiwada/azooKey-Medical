"""評価結果を表にする。
使い方: python3 medical/eval/compare_runs.py <結果ディレクトリ> <設定名> [<設定名> ...]
各設定名について <結果ディレクトリ>/<問題セット名>__<設定名>.json を読む。
問題と結果は順に対応させ、件数や読み・前の文章・正解が一致しないときは止める。
"""
import json
import os
import sys

EVAL_DIR = os.path.dirname(os.path.abspath(__file__))
COLUMNS = [
    ("医療の文脈", "context_pairs", "医療の文脈"),
    ("普段の文脈", "context_pairs", "普段の文脈"),
    ("同音異義57", "context_homophones", None),
    ("一般30", "general_regression", None),
    ("医療用語105", "medical_terms", None),
]


def check_pairs(inputs, items, path):
    if len(inputs) != len(items):
        sys.exit(f"{path}: 結果の件数 {len(items)} が問題の数 {len(inputs)} と違う")
    for k, (src, item) in enumerate(zip(inputs, items)):
        want = (src["query"], src.get("left_context") or "", src["answer"][0])
        got = (item.get("query"), item.get("left_context") or "", (item.get("answers") or [None])[0])
        if want != got:
            sys.exit(f"{path}: {k + 1}問目の結果が問題と対応しない（問題 {want} / 結果 {got}）")


def accuracy(set_name, result_path, tag):
    inputs = json.load(open(os.path.join(EVAL_DIR, set_name + ".json"), encoding="utf-8"))
    if not os.path.exists(result_path):
        return "-"
    items = json.load(open(result_path, encoding="utf-8"))["items"]
    check_pairs(inputs, items, result_path)
    oks = [r["max_rank"] == 0 for i, r in zip(inputs, items) if tag is None or tag in i.get("tag", [])]
    return f"{sum(oks)}/{len(oks)}"


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    run_dir = sys.argv[1]
    print("設定".ljust(14) + "".join(c[0].rjust(12) for c in COLUMNS))
    for setting in sys.argv[2:]:
        cells = [accuracy(s, os.path.join(run_dir, f"{s}__{setting}.json"), t) for _, s, t in COLUMNS]
        print(setting.ljust(14) + "".join(c.rjust(12) for c in cells))


if __name__ == "__main__":
    main()
