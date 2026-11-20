"""Behaviour of scripts/disk-cleanup.sh (run: uv run --no-project --with pytest pytest tests).

Every run is sandboxed: HOME, WORKSPACES and CLAUDE_CONFIG_DIR point into tmp_path.
"""

import os
import pathlib
import subprocess
import time

SCRIPT = (
    pathlib.Path(__file__).resolve().parent.parent / "scripts" / "disk-cleanup.sh"
)
OLD = time.time() - 48 * 3600  # older than the 24h active-session cutoff


def run(tmp_path, *args):
    env = {
        "PATH": os.environ["PATH"],
        "HOME": str(tmp_path / "home"),
        "WORKSPACES": str(tmp_path / "ws"),
        "CLAUDE_CONFIG_DIR": str(tmp_path / "claude"),
        "TMPDIR": str(tmp_path / "tmp"),
    }
    for d in ("home", "ws", "claude", "tmp"):
        (tmp_path / d).mkdir(exist_ok=True)
    return subprocess.run(
        ["bash", str(SCRIPT), *args], env=env, capture_output=True, text=True
    )


def session(tmp_path, project, sid, age):
    """A main transcript plus its session dir, both last written at `age`."""
    proj = tmp_path / "claude" / "projects" / project
    proj.mkdir(parents=True, exist_ok=True)
    t = proj / f"{sid}.jsonl"
    t.write_text('{"type":"user","message":"hello"}\n' * 500)
    d = proj / sid
    d.mkdir()
    for p in (t, d):
        os.utime(p, (age, age))
    return t


def archives(tmp_path):
    return sorted((tmp_path / "ws" / ".claude-archive" / "transcripts").rglob("*.zst"))


def test_tier_1_is_accepted_explicitly(tmp_path):
    r = run(tmp_path, "--dry-run", "1")
    assert r.returncode == 0, r.stderr
    assert "Tier 1" in r.stdout


def test_archive_leaves_transcripts_alone_without_the_flag(tmp_path):
    t = session(tmp_path, "-p", "s1", OLD)
    r = run(tmp_path, "archive")
    assert r.returncode == 0, r.stderr
    assert t.exists()
    assert archives(tmp_path) == []


def test_archive_transcripts_compresses_idle_ones_losslessly(tmp_path):
    t = session(tmp_path, "-p", "s1", OLD)
    original = t.read_bytes()
    r = run(tmp_path, "archive", "--transcripts")
    assert r.returncode == 0, r.stderr
    assert not t.exists()
    [a] = archives(tmp_path)
    assert a.parent.name == "-p" and a.name.startswith("s1.")
    assert oct(a.stat().st_mode & 0o777) == "0o600"
    restored = subprocess.run(["zstd", "-dc", str(a)], capture_output=True).stdout
    assert restored == original


def test_archive_transcripts_keeps_recent_sessions(tmp_path):
    t = session(tmp_path, "-p", "s1", time.time())
    r = run(tmp_path, "archive", "--transcripts")
    assert r.returncode == 0, r.stderr
    assert t.exists()
    assert archives(tmp_path) == []


def test_archive_transcripts_dry_run_changes_nothing(tmp_path):
    t = session(tmp_path, "-p", "s1", OLD)
    r = run(tmp_path, "archive", "--transcripts", "--dry-run")
    assert r.returncode == 0, r.stderr
    assert t.exists()
    assert "would compress" in r.stdout


def test_archive_transcripts_keeps_a_session_whose_process_is_alive(tmp_path):
    # Idle for 48h but still open in a running Claude process (here: this test's own pid).
    t = session(tmp_path, "-p", "s1", OLD)
    reg = tmp_path / "claude" / "sessions"
    reg.mkdir()
    (reg / f"{os.getpid()}.json").write_text(
        f'{{"pid":{os.getpid()},"sessionId":"s1","cwd":"/x"}}'
    )
    r = run(tmp_path, "archive", "--transcripts")
    assert r.returncode == 0, r.stderr
    assert t.exists()
    assert archives(tmp_path) == []


def test_archive_transcripts_also_runs_when_subagents_are_archived(tmp_path):
    t = session(tmp_path, "-p", "s1", OLD)
    sub = t.with_suffix("") / "subagents"
    sub.mkdir()
    (sub / "agent-a.jsonl").write_text('{"x":1}\n')
    for p in (sub / "agent-a.jsonl", sub, t.with_suffix("")):
        os.utime(p, (OLD, OLD))
    r = run(tmp_path, "archive", "--transcripts")
    assert r.returncode == 0, r.stderr
    assert not t.exists()
    assert len(archives(tmp_path)) == 1


def test_tier_1_keeps_an_old_claude_version_that_is_running(tmp_path):
    versions = tmp_path / "home" / ".local" / "share" / "claude" / "versions"
    versions.mkdir(parents=True)
    old, cur = versions / "1.0.0", versions / "2.0.0"
    for v in (old, cur):
        v.write_bytes(pathlib.Path("/bin/sleep").read_bytes())
        v.chmod(0o755)
    stale = versions / "0.9.0"
    stale.write_bytes(b"x")
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "claude").symlink_to(cur)
    # Its command line reads `claude 30`, as a live session reads `claude --resume`.
    proc = subprocess.Popen(["claude", "30"], executable=str(old))
    try:
        os.environ["PATH"] = f"{bindir}:{os.environ['PATH']}"
        r = run(tmp_path, "--dry-run", "1")
    finally:
        proc.kill()
        os.environ["PATH"] = os.environ["PATH"].split(":", 1)[1]
    assert r.returncode == 0, r.stderr
    assert f"keep    {old}" in r.stdout
    assert f"would remove {stale}" in r.stdout
