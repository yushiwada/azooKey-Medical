"""anco evaluate の出力（JSON）を集計する。
使い方: python3 summarize_eval.py <入力セット.json> <結果1.json> [<結果2.json> ...]
問題と結果は順に対応させ、読み・前の文章・正解が一致しないとき（別の問題セットの結果など）は止める。
"""
import json
import sys
from collections import defaultdict


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def paired(inputs, items, result_path):
    """問題と結果を組にする。件数や中身が合わなければ止める"""
    if len(inputs) != len(items):
        sys.exit(f"{result_path}: 結果の件数 {len(items)} が問題の数 {len(inputs)} と違う")
    for k, (src, item) in enumerate(zip(inputs, items)):
        want = (src["query"], src.get("left_context") or "", src["answer"][0])
        got = (item.get("query"), item.get("left_context") or "", (item.get("answers") or [None])[0])
        if want != got:
            sys.exit(f"{result_path}: {k + 1}問目の結果が問題と対応しない（問題 {want} / 結果 {got}）")
    return zip(inputs, items)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    inputs = load(sys.argv[1])
    for result_path in sys.argv[2:]:
        result = load(result_path)
        items = result["items"]
        by_tag = defaultdict(lambda: [0, 0])
        top1 = 0
        misses = []
        for src, item in paired(inputs, items, result_path):
            ok = item["max_rank"] == 0
            top1 += ok
            for tag in src.get("tag", []):
                by_tag[tag][0] += ok
                by_tag[tag][1] += 1
            if not ok:
                first = item["outputs"][0]["text"] if item["outputs"] else "(候補なし)"
                misses.append(f'{src.get("left_context", "")}［{item["query"]}］→ {first}（正解 {item["answers"][0]}）')
        n = len(items)
        sec = result.get("execution_time", 0)
        print(f"== {result_path}")
        if n == 0:
            print("問題が0問")
            continue
        print(f"1位正解 {top1}/{n} ({top1 / n:.0%})  平均 {sec / n * 1000:.0f} ms/問")
        print("  " + "  ".join(f"{t}: {a}/{b}" for t, (a, b) in sorted(by_tag.items())))
        for m in misses:
            print("  ✗ " + m)


if __name__ == "__main__":
    main()
