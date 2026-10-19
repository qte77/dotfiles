"""Replace base64 image blocks in Claude Code .jsonl transcripts with a text placeholder.

Usage: python3 -I strip-session-images.py [--apply] FILE_OR_DIR...

Without --apply it only reports. With --apply each file is rewritten via a temp
file in the same directory, validated (same line count, no image data left),
then atomically renamed over the original. Text, reasoning and tool calls are
kept; only the image bytes go, and those are not recoverable.
"""

import json
import os
import sys
import time

MIN_AGE_S = 2 * 3600  # skip transcripts touched more recently than this


def strip(node, counter):
    if isinstance(node, dict):
        if node.get("type") == "image" and isinstance(node.get("source"), dict):
            data = node["source"].get("data") or ""
            counter[0] += 1
            counter[1] += len(data)
            mt = node["source"].get("media_type", "image")
            return {"type": "text", "text": f"[screenshot removed: {mt}, {len(data)} b64 chars]"}
        return {k: strip(v, counter) for k, v in node.items()}
    if isinstance(node, list):
        return [strip(v, counter) for v in node]
    return node


def process(path, apply):
    counter = [0, 0]
    out_lines = []
    with open(path, encoding="utf-8") as fh:
        raw = fh.read().split("\n")
    trailing = raw and raw[-1] == ""
    lines = raw[:-1] if trailing else raw
    for line in lines:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            out_lines.append(line)  # keep corrupt lines untouched
            continue
        before = counter[0]
        new = strip(obj, counter)
        out_lines.append(json.dumps(new, ensure_ascii=False, separators=(",", ":")) if counter[0] > before else line)
    if not counter[0] or not apply:
        return counter
    tmp = path + ".strip-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out_lines) + ("\n" if trailing else ""))
    with open(tmp, encoding="utf-8") as fh:
        check = fh.read().split("\n")
    check = check[:-1] if trailing else check
    if len(check) != len(lines) or any('"type":"image","source"' in c for c in check):
        os.remove(tmp)
        raise RuntimeError(f"validation failed: {path}")
    os.replace(tmp, path)
    return counter


def main():
    args = sys.argv[1:]
    apply = "--apply" in args
    files = []
    for a in (a for a in args if a != "--apply"):
        if os.path.isdir(a):
            files += sorted(os.path.join(r, n) for r, _, ns in os.walk(a) for n in ns if n.endswith(".jsonl"))
        else:
            files.append(a)
    # Reason: a live session appends to its transcript through an open handle;
    # swapping the file under it would silently drop everything written after.
    cutoff = time.time() - MIN_AGE_S
    live = {f for f in files if os.path.getmtime(f) > cutoff}
    files = [f for f in files if f not in live]
    total_imgs = total_chars = touched = 0
    for f in files:
        imgs, chars = process(f, apply)
        if imgs:
            touched += 1
            total_imgs += imgs
            total_chars += chars
    mode = "removed" if apply else "would remove"
    print(f"{mode}: {total_imgs} images, {total_chars / 1048576:.0f} MB base64, in {touched}/{len(files)} files")
    if live:
        print(f"skipped {len(live)} files modified in the last {MIN_AGE_S // 60} min (possibly live sessions)")


if __name__ == "__main__":
    main()
