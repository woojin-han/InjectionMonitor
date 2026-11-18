"""쇼핑몰 목록 JSON 주소가 수집에 쓸 만한지 확인하는 스크립트.

사용법 (본인 PC에서):
    pip install requests
    python scripts/check_source.py "개발자도구에서 복사한 요청 주소"
    python scripts/check_source.py 저장한파일.json      # 응답을 파일로 저장했다면

하는 일:
  1. 주소로 요청을 보내 상태 코드와 응답 형식(JSON인지)을 확인한다
  2. JSON 안에서 '상품 목록'으로 보이는 배열을 찾는다
  3. 첫 번째 상품의 필드 중 가격, 이름, 번호, 이미지로 보이는 것을 골라 보여준다
  4. 결과를 scripts/samples/ 에 저장한다 (개인정보·쿠키는 저장하지 않음)
"""
import json
import pathlib
import re
import sys

HINTS = {
    "번호": re.compile(r"(goods|product|item)?_?(no|id|number)$", re.I),
    "이름": re.compile(r"(goods|product|item)?_?name$|title", re.I),
    "브랜드": re.compile(r"brand", re.I),
    "가격": re.compile(r"price|amount|cost", re.I),
    "할인율": re.compile(r"(sale|discount).*(rate|percent)|rate$", re.I),
    "이미지": re.compile(r"image|img|thumbnail|thumb", re.I),
    "품절": re.compile(r"sold.?out|stock", re.I),
}


def load(arg: str):
    path = pathlib.Path(arg)
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8")), "파일"
    import requests  # 주소일 때만 필요

    headers = {"User-Agent": "Mozilla/5.0 (TagCheck student project)", "Accept": "application/json"}
    res = requests.get(arg, headers=headers, timeout=15)
    print(f"상태 코드: {res.status_code}")
    if res.status_code != 200:
        print("→ 200이 아니면 막혔거나 주소가 잘못된 것입니다. 브라우저에서는 되는데 여기서 안 되면 알려주세요.")
        sys.exit(1)
    try:
        return res.json(), "주소"
    except ValueError:
        print("→ JSON이 아닙니다(아마 HTML). 개발자도구에서 Fetch/XHR 요청을 다시 찾아보세요.")
        print(res.text[:300])
        sys.exit(1)


def find_lists(node, path="$", out=None):
    """객체가 5개 이상 들어 있는 배열을 모두 찾는다."""
    out = [] if out is None else out
    if isinstance(node, list):
        if len(node) >= 5 and all(isinstance(x, dict) for x in node[:5]):
            out.append((path, node))
        for i, x in enumerate(node[:3]):
            find_lists(x, f"{path}[{i}]", out)
    elif isinstance(node, dict):
        for k, v in node.items():
            find_lists(v, f"{path}.{k}", out)
    return out


def flatten(d, prefix=""):
    for k, v in d.items():
        key = f"{prefix}{k}"
        if isinstance(v, dict):
            yield from flatten(v, key + ".")
        else:
            yield key, v


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(0)
    data, kind = load(sys.argv[1])
    lists = find_lists(data)
    if not lists:
        print("상품 목록으로 보이는 배열을 못 찾았습니다. 응답 앞부분:")
        print(json.dumps(data, ensure_ascii=False)[:800])
        sys.exit(1)
    lists.sort(key=lambda x: -len(x[1]))
    path, items = lists[0]
    print(f"\n상품 목록 위치: {path}  (상품 {len(items)}개)")
    first = dict(flatten(items[0]))
    print("\n첫 번째 상품에서 찾은 필드:")
    for label, rx in HINTS.items():
        hits = [(k, v) for k, v in first.items() if rx.search(k.split(".")[-1])]
        for k, v in hits[:4]:
            print(f"  [{label}] {k} = {str(v)[:80]}")
    print("\n전체 필드 이름:", ", ".join(list(first)[:60]))

    out = pathlib.Path(__file__).parent / "samples"
    out.mkdir(exist_ok=True)
    name = re.sub(r"[^a-z0-9]+", "_", sys.argv[1].lower())[:60] if kind == "주소" else pathlib.Path(sys.argv[1]).stem
    sample = {"source": sys.argv[1].split("?")[0] if kind == "주소" else sys.argv[1],
              "list_path": path, "count": len(items), "first_items": items[:3]}
    (out / f"{name}.json").write_text(json.dumps(sample, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n저장: scripts/samples/{name}.json  ← 이 파일을 커밋하거나 내용을 보내주세요")


if __name__ == "__main__":
    main()
