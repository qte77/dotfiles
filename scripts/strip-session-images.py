"""Replace base64 image blocks in Claude Code .jsonl transcripts with a text placeholder.

Usage: python3 -u -I strip-session-images.py [--apply] [--stage-dir DIR] FILE_OR_DIR...

Without --apply it only reports. With --apply each file that holds images is
streamed into a stripped copy under --stage-dir (default: $TMPDIR or /tmp),
validated there (same line count, no image data left), then written back over
the original in place. The stripped copy is always smaller, so the disk being
relieved never needs extra room. Text, reasoning and tool calls are kept; only
the image bytes go, and those are not recoverable.

Files are processed largest first, with one progress line per file that holds
images. Exit status is 1 if any file failed or was skipped mid-run.
"""

import json
import os
import shutil
import sys
import tempfile
import time

MIN_AGE_S = 2 * 3600  # skip transcripts touched more recently than this
HEARTBEAT = 50  # print a progress line at least every N files
CHUNK = 1 << 20


class Skip(Exception):
    """A file left untouched on purpose (e.g. it changed while being processed)."""


def strip(node, counter):
    if isinstance(node, dict):
        if node.get("type") == "image" and isinstance(node.get("source"), dict):
            data = node["source"].get("data") or ""
            counter[0] += 1
            counter[1] += len(data)
            mt = node["source"].get("media_type", "image")
            return {
                "type": "text",
                "text": f"[screenshot removed: {mt}, {len(data)} b64 chars]",
            }
        return {k: strip(v, counter) for k, v in node.items()}
    if isinstance(node, list):
        return [strip(v, counter) for v in node]
    return node


def strip_line(line, counter):
    # Reason: most lines hold no image; a substring test skips the JSON parse,
    # which is what made whole-corpus runs (GBs of transcripts) crawl.
    if '"image"' not in line:
        return line
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        return line  # keep corrupt lines untouched
    before = counter[0]
    new = strip(obj, counter)
    return (
        json.dumps(new, ensure_ascii=False, separators=(",", ":"))
        if counter[0] > before
        else line
    )


def stage_copy(path, out):
    """Stream path line by line; write the stripped lines to out (or nowhere when None).

    Returns (images, b64_chars, line_count).
    """
    counter, n = [0, 0], 0
    with open(path, encoding="utf-8", newline="") as src:
        for line in src:
            n += 1
            body = line.rstrip("\n")
            stripped = strip_line(body, counter)
            if out is not None:
                out.write(stripped + line[len(body) :])
    return counter[0], counter[1], n


def verify(staged, expected_lines):
    n = 0
    with open(staged, encoding="utf-8", newline="") as fh:
        for line in fh:
            n += 1
            if '"type":"image","source"' in line:
                raise RuntimeError("validation failed: image data left in staged copy")
    if n != expected_lines:
        raise RuntimeError(
            f"validation failed: {n} lines staged, {expected_lines} expected"
        )


def overwrite_in_place(path, staged):
    """Copy staged over path without needing free space on path's disk."""
    with open(staged, "rb") as src, open(path, "r+b") as dst:
        shutil.copyfileobj(src, dst, CHUNK)
        dst.truncate()
        dst.flush()
        os.fsync(dst.fileno())


def process(path, apply, stage_dir):
    st = os.stat(path)
    if not apply:
        imgs, chars, _ = stage_copy(path, None)
        return imgs, chars
    if shutil.disk_usage(stage_dir).free < st.st_size:
        raise Skip(f"not enough space in {stage_dir} to stage {st.st_size} bytes")
    fd, staged = tempfile.mkstemp(prefix="strip-", suffix=".jsonl", dir=stage_dir)
    keep_staged = False
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as out:
            imgs, chars, n = stage_copy(path, out)
        if not imgs:
            return 0, 0
        verify(staged, n)
        now = os.stat(path)
        # Reason: a live session appends through an open handle; overwriting a file
        # that grew since we read it would silently drop the new lines.
        if (now.st_mtime_ns, now.st_size) != (st.st_mtime_ns, st.st_size):
            raise Skip("changed while processing; left untouched")
        if os.path.getsize(staged) >= st.st_size:
            raise Skip("stripped copy is not smaller; left untouched")
        try:
            overwrite_in_place(path, staged)
        except OSError as e:
            keep_staged = True
            raise RuntimeError(
                f"overwrite interrupted ({e}); full stripped copy kept at {staged}"
            ) from e
        return imgs, chars
    finally:
        if not keep_staged and os.path.exists(staged):
            os.remove(staged)


def collect(paths):
    files = []
    for a in paths:
        if os.path.isdir(a):
            files += [
                os.path.join(r, n)
                for r, _, ns in os.walk(a)
                for n in ns
                if n.endswith(".jsonl")
            ]
        else:
            files.append(a)
    return files


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    apply = "--apply" in args
    args = [a for a in args if a != "--apply"]
    stage_dir = tempfile.gettempdir()
    if "--stage-dir" in args:
        i = args.index("--stage-dir")
        stage_dir = args[i + 1]
        del args[i : i + 2]

    files = collect(args)
    cutoff = time.time() - MIN_AGE_S
    live = [f for f in files if os.path.getmtime(f) > cutoff]
    todo = sorted(
        (f for f in files if f not in set(live)), key=os.path.getsize, reverse=True
    )

    total, imgs_all, chars_all, touched, failed = len(todo), 0, 0, 0, 0
    t0 = time.time()
    for i, f in enumerate(todo, 1):
        size_mb = os.path.getsize(f) / 1048576
        name = os.path.relpath(f, os.path.dirname(os.path.dirname(f)))
        try:
            imgs, chars = process(f, apply, stage_dir)
        except Skip as e:
            failed += 1
            print(f"[{i}/{total}] SKIPPED {name}: {e}", flush=True)
            continue
        # one bad file must not stop the run
        except (OSError, RuntimeError, ValueError) as e:
            failed += 1
            print(f"[{i}/{total}] FAILED {name}: {e}", flush=True)
            continue
        if imgs:
            touched += 1
            imgs_all += imgs
            chars_all += chars
            print(
                f"[{i}/{total}] {size_mb:6.1f} MB  {name}  {imgs} images, {chars / 1048576:.1f} MB",
                flush=True,
            )
        elif i % HEARTBEAT == 0:
            print(
                f"  ... {i}/{total} files scanned, {time.time() - t0:.0f}s", flush=True
            )

    mode = "removed" if apply else "would remove"
    print(
        f"{mode}: {imgs_all} images, {chars_all / 1048576:.0f} MB base64, in {touched}/{total} files"
    )
    if live:
        print(
            f"skipped {len(live)} files modified in the last {MIN_AGE_S // 60} min (possibly live sessions)"
        )
    if failed:
        print(f"{failed} files failed or were skipped mid-run (see above)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
