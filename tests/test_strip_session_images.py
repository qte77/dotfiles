"""Behaviour of scripts/strip-session-images.py (run: uv run --no-project --with pytest pytest tests)."""

import importlib.util
import json
import os
import pathlib
import time

import pytest

SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "scripts"
    / "strip-session-images.py"
)
spec = importlib.util.spec_from_file_location("strip_session_images", SCRIPT)
ssi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ssi)

OLD = time.time() - 3 * 3600  # older than the live-session cutoff


def image_line(b64="A" * 4000):
    msg = {
        "type": "user",
        "message": {
            "content": [
                {"type": "text", "text": "look"},
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": b64,
                    },
                },
            ]
        },
    }
    return json.dumps(msg, separators=(",", ":"))


TEXT_LINE = json.dumps(
    {"type": "assistant", "message": {"content": [{"type": "text", "text": "hi"}]}},
    separators=(",", ":"),
)


def write(path, lines, age=OLD):
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.utime(path, (age, age))
    return path


@pytest.fixture
def dirs(tmp_path):
    projects, stage = tmp_path / "projects", tmp_path / "stage"
    projects.mkdir()
    stage.mkdir()
    return projects, stage


def run(capsys, *args):
    rc = ssi.main(list(args))
    return rc, capsys.readouterr().out


def test_apply_strips_images_keeps_text_and_line_count(dirs, capsys):
    projects, stage = dirs
    f = write(projects / "a.jsonl", [TEXT_LINE, image_line(), "not json {", TEXT_LINE])
    before = f.stat().st_size

    rc, out = run(capsys, "--apply", "--stage-dir", str(stage), str(projects))

    lines = f.read_text(encoding="utf-8").split("\n")[:-1]
    assert rc == 0
    assert len(lines) == 4
    assert lines[0] == TEXT_LINE and lines[2] == "not json {"
    assert '"type":"image"' not in lines[1] and "screenshot removed" in lines[1]
    assert '"text":"look"' in lines[1]
    assert f.stat().st_size < before
    assert "1 images" in out


def test_file_without_images_is_untouched(dirs, capsys):
    projects, stage = dirs
    f = write(projects / "plain.jsonl", [TEXT_LINE, TEXT_LINE])
    data, mtime = f.read_bytes(), f.stat().st_mtime_ns

    run(capsys, "--apply", "--stage-dir", str(stage), str(projects))

    assert f.read_bytes() == data and f.stat().st_mtime_ns == mtime


def test_dry_run_changes_nothing_but_reports(dirs, capsys):
    projects, stage = dirs
    f = write(projects / "a.jsonl", [image_line()])
    data = f.read_bytes()

    rc, out = run(capsys, "--stage-dir", str(stage), str(projects))

    assert rc == 0 and f.read_bytes() == data
    assert "would remove: 1 images" in out


def test_recent_file_is_skipped_as_possibly_live(dirs, capsys):
    projects, stage = dirs
    f = write(projects / "live.jsonl", [image_line()], age=time.time())
    data = f.read_bytes()

    _, out = run(capsys, "--apply", "--stage-dir", str(stage), str(projects))

    assert f.read_bytes() == data and "skipped 1 files" in out


def test_never_writes_next_to_the_original(dirs, capsys):
    projects, stage = dirs
    write(projects / "a.jsonl", [image_line()])

    run(capsys, "--apply", "--stage-dir", str(stage), str(projects))

    assert sorted(p.name for p in projects.iterdir()) == ["a.jsonl"]
    assert list(stage.iterdir()) == []  # staged copy cleaned up after success


def test_file_changed_mid_run_is_skipped(dirs, capsys, monkeypatch):
    projects, stage = dirs
    f = write(projects / "a.jsonl", [image_line()])
    real_stage = ssi.stage_copy

    def stage_then_append(*a, **kw):
        result = real_stage(*a, **kw)
        with open(f, "a", encoding="utf-8") as fh:  # a live session appends meanwhile
            fh.write(TEXT_LINE + "\n")
        return result

    monkeypatch.setattr(ssi, "stage_copy", stage_then_append)
    rc, out = run(capsys, "--apply", "--stage-dir", str(stage), str(projects))

    text = f.read_text(encoding="utf-8")
    assert '"type":"image"' in text and text.endswith(TEXT_LINE + "\n")  # nothing lost
    assert "changed while processing" in out
    assert rc == 1


def test_one_failure_does_not_stop_the_run(dirs, capsys):
    projects, stage = dirs
    bad = write(projects / "bad.jsonl", [image_line()])
    good = write(projects / "good.jsonl", [image_line()])
    bad.chmod(0)
    try:
        rc, out = run(capsys, "--apply", "--stage-dir", str(stage), str(projects))
    finally:
        bad.chmod(0o644)

    assert rc == 1
    assert "FAILED" in out and "bad.jsonl" in out
    assert '"type":"image"' not in good.read_text(encoding="utf-8")


def test_progress_line_per_file_largest_first(dirs, capsys):
    projects, stage = dirs
    write(projects / "small.jsonl", [image_line("A" * 1000)])
    write(projects / "big.jsonl", [image_line("A" * 9000)])

    _, out = run(capsys, "--stage-dir", str(stage), str(projects))

    progress = [ln for ln in out.splitlines() if ln.startswith("[")]
    assert len(progress) == 2
    assert "big.jsonl" in progress[0] and "small.jsonl" in progress[1]
    assert progress[0].startswith("[1/2]")
