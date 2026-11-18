#!/usr/bin/env python3
"""
DaVinci Resolve boxes on Daytona GPU sandboxes, with persistent storage.

  python daytona_resolve.py snapshot                 build the GPU snapshot from ./Dockerfile
  python daytona_resolve.py up                       start (or reuse) the GPU box, print the desktop URL
  python daytona_resolve.py down                     save Resolve projects to the volume, delete the box
  python daytona_resolve.py push <files/dirs...>     upload media to the volume   (--to footage|audio|assets|...)
  python daytona_resolve.py fetch <url> [--to footage]  download a URL straight onto the volume (fast)
  python daytona_resolve.py pull <path> [local_dir]  download from the volume     (e.g. exports/final.mov)
  python daytona_resolve.py ls [subdir]              list what's on the volume
  python daytona_resolve.py status                   box + storage status
  python daytona_resolve.py save                     save Resolve projects to the volume now
  python daytona_resolve.py vnc [--restart]          print the desktop URL (restart desktop + Resolve)
  python daytona_resolve.py verify                   in-box GPU / Resolve smoke test

Storage model
  * Volume "resolve-media" (Daytona volume, survives every box) is mounted at ~/media:
      footage/ audio/ assets/ exports/ project-archives/   + .resolve-state/ (project DB backup)
  * Resolve's project database runs on fast local disk; it is restored from the volume at `up`,
    autosaved to it every 5 min while the box runs, and saved again on `down`.
  * push/pull/ls work without the GPU box: they use a small CPU "storage" box on the same volume.

Auth: DAYTONA_API_KEY, or the Daytona CLI login (its config file).
"""
from __future__ import annotations

import argparse
import hashlib
import shlex
import uuid
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
import json
import os
import sys
import time
from pathlib import Path

from daytona import (
    CreateSandboxFromSnapshotParams,
    CreateSnapshotParams,
    Daytona,
    GpuType,
    Image,
    ListSandboxesQuery,
    Resources,
    SessionExecuteRequest,
    VolumeMount,
)

ROOT = Path(__file__).resolve().parent
DEFAULT_SNAPSHOT = "davinci-resolve-studio"
DEFAULT_VOLUME = "resolve-media"
HOME = "/home/daytona"
MEDIA = f"{HOME}/media"
BOX_LABEL = {"app": "davinci-resolve", "role": "editor"}
STORAGE_LABEL = {"app": "davinci-resolve", "role": "storage"}
STORAGE_BOX = "resolve-storage"
# RTX-class: has NVENC/NVDEC (H.264/H.265 hardware); H100/H200 do not.
# Daytona snapshots accept exactly one GPU type. Options: RTX-PRO-6000 L40S RTX-4090 RTX-5090 H100 ...
DEFAULT_GPU = "RTX-PRO-6000"
AUTOSAVE_SECONDS = 300
SCRIPTS = ["start-resolve.sh", "resolve-state.sh", "verify-davinci-resolve.sh"]


# --------------------------------------------------------------------------- helpers
def client() -> Daytona:
    if not os.environ.get("DAYTONA_API_KEY"):
        for p in (
            Path.home() / "Library/Application Support/daytona/config.json",
            Path.home() / ".config/daytona/config.json",
        ):
            if p.exists():
                cfg = json.loads(p.read_text())
                profs = cfg.get("profiles") or [{}]
                prof = next((x for x in profs if x.get("id") == cfg.get("activeProfile")), profs[0])
                api = prof.get("api") or {}
                if api.get("key"):
                    os.environ["DAYTONA_API_KEY"] = api["key"]
                    os.environ.setdefault("DAYTONA_API_URL", api.get("url", "https://app.daytona.io/api"))
                    break
    if not os.environ.get("DAYTONA_API_KEY"):
        sys.exit("No Daytona credentials: set DAYTONA_API_KEY or run `daytona login`.")
    return Daytona()


def volume_mount(d: Daytona, name: str) -> VolumeMount:
    vol = d.volume.get(name, create=True)
    for _ in range(60):
        if str(vol.state).lower().endswith("ready"):
            break
        time.sleep(2)
        vol = d.volume.get(name)
    return VolumeMount(volume_id=vol.id, mount_path=MEDIA)


def sh(sb, cmd: str, timeout: int = 300, check: bool = True) -> str:
    r = sb.process.exec(cmd, timeout=timeout)
    if check and r.exit_code != 0:
        raise RuntimeError(f"`{cmd}` failed ({r.exit_code}):\n{r.result}")
    return r.result


def bg(sb, session: str, cmd: str):
    try:
        sb.process.create_session(session)
    except Exception:
        pass
    sb.process.execute_session_command(session, SessionExecuteRequest(command=cmd, run_async=True))


def find_box(d: Daytona, labels: dict) -> list:
    out = []
    for s in d.list(ListSandboxesQuery(labels=labels)):
        if (s.name or "").startswith("DESTROYED_"):
            continue
        if str(s.state).lower().split(".")[-1] in ("destroyed", "destroying", "error", "build_failed"):
            continue
        out.append(s)
    return out


def running(sb) -> bool:
    return str(sb.state).lower().endswith("started")


def editor_box(d: Daytona, ident: str | None):
    if ident:
        return d.get(ident)
    boxes = find_box(d, BOX_LABEL)
    if not boxes:
        sys.exit("No Resolve box running. Start one with: daytona_resolve.py up")
    return boxes[0]


def sync_scripts(sb):
    """Push the current in-box scripts so fixes apply without rebuilding the snapshot."""
    for name in SCRIPTS:
        sb.fs.upload_file(str(ROOT / "scripts" / name), f"/tmp/{name}")
    files = " ".join(f"/tmp/{n}" for n in SCRIPTS)
    sh(sb, f"sudo mkdir -p /opt/scripts && sudo install -m 0755 {files} /opt/scripts/")


# --------------------------------------------------------------------------- snapshot
def cmd_snapshot(a):
    inst = [p for p in (ROOT / "optional").iterdir() if p.suffix.lower() in (".zip", ".run") and "linux" in p.name.lower()]
    if not inst:
        sys.exit("No Linux installer in ./optional/ — download DaVinci_Resolve_Studio_<ver>_Linux.zip from "
                 "https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion")
    print(f"[snapshot] installer: {inst[0].name} ({inst[0].stat().st_size / 1e9:.1f} GB)")
    d = client()
    if a.replace:
        try:
            d.snapshot.delete(d.snapshot.get(a.name))
            print(f"[snapshot] deleted old {a.name}")
            time.sleep(10)
        except Exception:
            pass
    os.chdir(ROOT)
    by_value = {g.value: g for g in GpuType}
    if a.gpu_type not in by_value:
        sys.exit(f"unknown GPU type {a.gpu_type}; choose from {sorted(by_value)}")
    res = Resources(gpu=1, gpu_type=[by_value[a.gpu_type]],
                    cpu=a.cpu, memory=a.memory, disk=a.disk)
    print(f"[snapshot] building {a.name}; uploading context + building takes a while...")
    snap = d.snapshot.create(
        CreateSnapshotParams(name=a.name, image=Image.from_dockerfile(ROOT / "Dockerfile"),
                             resources=res, region_id=a.region),
        on_logs=lambda line: print(line, end="" if line.endswith("\n") else "\n", flush=True),
        timeout=0,
    )
    print(f"[snapshot] {snap.name}: {snap.state}")


# --------------------------------------------------------------------------- editor box
def start_session(sb, launch_resolve: bool, fresh: bool):
    sync_scripts(sb)
    if fresh:
        print("[up] restoring Resolve projects from the volume ...")
        print("     " + sh(sb, "/opt/scripts/resolve-state.sh restore").strip().replace("\n", "\n     "))
    bg(sb, "autosave", f"/opt/scripts/resolve-state.sh loop {AUTOSAVE_SECONDS} >> /tmp/resolve-state.log 2>&1")
    print("[up] starting desktop ...")
    sb.computer_use.start()
    for _ in range(30):
        if getattr(sb.computer_use.get_status(), "status", "") == "active":
            break
        time.sleep(2)
    if launch_resolve:
        sh(sb, "pgrep -f /opt/resolve/bin/resolve >/dev/null && pkill -f /opt/resolve/bin/resolve; true")
        bg(sb, "resolve", "/opt/scripts/start-resolve.sh > /tmp/resolve.log 2>&1")
        print("[up] Resolve launching (log: /tmp/resolve.log)")


def vnc_url(sb) -> str:
    link = sb.get_preview_link(6080)
    url = link.url.rstrip("/") + "/vnc.html?autoconnect=true&resize=scale"
    if getattr(link, "token", None) and not sb.public:
        url += f"\n  (private box: open it from the Daytona dashboard, or send header x-daytona-preview-token: {link.token})"
    return url


def cmd_up(a):
    d = client()
    existing = [] if a.new else find_box(d, {**BOX_LABEL, "volume": a.volume})
    try:
        for b in existing:
            b.refresh_data()
        existing = [b for b in existing if not (b.name or "").startswith("DESTROYED_")
                    and str(b.state).lower().split(".")[-1] not in ("destroyed", "destroying")]
    except Exception:
        existing = []
    if existing:
        sb = existing[0]
        print(f"[up] reusing box {sb.name} ({sb.state})")
        if not running(sb):
            sb.start(timeout=600)
        start_session(sb, not a.no_resolve, fresh=False)
        print("\nDesktop:\n  " + vnc_url(sb))
        return

    stor = find_box(d, {**STORAGE_LABEL, "volume": a.volume})
    for s in stor:  # avoid two boxes writing the volume at once
        if running(s):
            print(f"[up] stopping storage box {s.name} first")
            s.stop()

    print(f"[up] creating GPU box from {a.snapshot}; volume '{a.volume}' -> {MEDIA}")
    sb = d.create(
        CreateSandboxFromSnapshotParams(
            snapshot=a.snapshot,
            name=a.name,
            ephemeral=True,  # GPU boxes are deleted on stop; everything worth keeping is on the volume
            auto_stop_interval=a.auto_stop,
            volumes=[volume_mount(d, a.volume)],
            public=a.public,
            env_vars={"RESOLVE_MEDIA": MEDIA, "VNC_RESOLUTION": a.resolution},
            labels={**BOX_LABEL, "volume": a.volume},
        ),
        timeout=1200,
    )
    print(f"[up] box {sb.name} ({sb.id}) started")
    print("[up] GPU: " + sh(sb, "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader", check=False).strip())
    start_session(sb, not a.no_resolve, fresh=True)
    print("[up] storage:\n     " + sh(sb, "/opt/scripts/resolve-state.sh status", check=False).strip().replace("\n", "\n     "))
    print("\nDesktop:\n  " + vnc_url(sb))
    print(f"""
Your media is at {MEDIA} (footage/ audio/ assets/ exports/ project-archives/).
Projects autosave to the volume every {AUTOSAVE_SECONDS // 60} min and on `down`.
Idle {a.auto_stop} min -> box is deleted (volume kept). Studio: Help > Deactivate License before `down`.""")


def cmd_down(a):
    d = client()
    sb = editor_box(d, a.sandbox)
    if running(sb):
        print("[down] closing Resolve and saving projects to the volume ...")
        sh(sb, "pkill -TERM -f /opt/resolve/bin/resolve; for i in $(seq 20); do pgrep -f /opt/resolve/bin/resolve >/dev/null || break; sleep 1; done; true",
           check=False)
        print("       " + sh(sb, "/opt/scripts/resolve-state.sh save", timeout=900).strip())
    sid = sb.id
    sb.delete()
    for _ in range(60):  # deletion is async; wait so a following `up` doesn't see the old box
        if not any(x.id == sid for x in find_box(d, BOX_LABEL)):
            break
        time.sleep(2)
    print(f"[down] deleted box {sid}; volume data kept")


def cmd_save(a):
    sb = editor_box(client(), a.sandbox)
    print(sh(sb, "/opt/scripts/resolve-state.sh save", timeout=900).strip())


def cmd_vnc(a):
    sb = editor_box(client(), a.sandbox)
    if a.restart:
        start_session(sb, True, fresh=False)
    print(vnc_url(sb))


def cmd_verify(a):
    sb = editor_box(client(), a.sandbox)
    sync_scripts(sb)
    r = sb.process.exec("/opt/scripts/verify-davinci-resolve.sh", timeout=400)
    print(r.result)
    sys.exit(r.exit_code)


# --------------------------------------------------------------------------- storage (no GPU needed)
def storage_box(d: Daytona, volume: str):
    """The running editor box if there is one, else a small CPU box on the same volume."""
    for s in find_box(d, {**BOX_LABEL, "volume": volume}):
        if running(s):
            return s
    boxes = find_box(d, {**STORAGE_LABEL, "volume": volume})
    if boxes:
        sb = boxes[0]
        if not running(sb):
            print(f"[storage] starting {sb.name} ...")
            sb.start(timeout=600)
        return sb
    print("[storage] creating a small CPU box for file transfers ...")
    sb = d.create(
        CreateSandboxFromSnapshotParams(
            name=f"{STORAGE_BOX}-{volume}", labels={**STORAGE_LABEL, "volume": volume}, auto_stop_interval=15,
            volumes=[volume_mount(d, volume)],
        ),
        timeout=600,
    )
    sh(sb, f"mkdir -p {MEDIA}/footage {MEDIA}/audio {MEDIA}/assets {MEDIA}/exports {MEDIA}/project-archives {MEDIA}/.resolve-state")
    return sb


CHUNK = 16 * 1024 * 1024   # parallel chunk size for big files
WORKERS = 8                # parallel upload streams (8 measured ~5x faster than 1)
WINDOW = 24                # max chunks staged on the box's local disk (~384 MB)


def _retry(fn, tries=4):
    for i in range(tries):
        try:
            return fn()
        except Exception as e:  # network hiccups
            if i == tries - 1:
                raise
            print(f"   retry after error: {str(e)[:120]}")
            time.sleep(2 * (i + 1))


def _md5(path: Path) -> str:
    h = hashlib.md5()
    with open(path, "rb") as fh:
        for blk in iter(lambda: fh.read(8 * 1024 * 1024), b""):
            h.update(blk)
    return h.hexdigest()


def push_big(sb, f: Path, dst: str, verify: bool):
    """Upload one large file as parallel chunks; a box-side writer streams them in order onto the volume
    (mountpoint-s3 only supports sequential writes, so no seek/append)."""
    size = f.stat().st_size
    n = (size + CHUNK - 1) // CHUNK
    tid = uuid.uuid4().hex[:8]
    stage = f"/tmp/push-{tid}"
    sh(sb, f"mkdir -p {stage} {shlex.quote(dst.rsplit('/', 1)[0])}")
    writer = (f"for i in $(seq 0 {n - 1}); do while [ ! -f {stage}/$i.ok ]; do sleep 0.2; done; "
              f"cat {stage}/$i || exit 1; rm -f {stage}/$i {stage}/$i.ok; done > {shlex.quote(dst)} "
              f"&& echo ok > {stage}/complete || echo fail > {stage}/complete")
    bg(sb, f"push-{tid}", "bash -c " + shlex.quote(writer))

    def part(i: int):
        with open(f, "rb") as fh:
            fh.seek(i * CHUNK)
            data = fh.read(CHUNK)
        _retry(lambda: sb.fs.upload_file(data, f"{stage}/{i}", timeout=900))
        _retry(lambda: sb.fs.upload_file(b"", f"{stage}/{i}.ok", timeout=120))
        return len(data)

    t0, sent = time.time(), 0
    with ThreadPoolExecutor(WORKERS) as ex:
        pending = {}
        nxt = 0
        while nxt < n or pending:
            while nxt < n and len(pending) < WINDOW:
                pending[ex.submit(part, nxt)] = nxt
                nxt += 1
            done, _ = wait(pending, return_when=FIRST_COMPLETED)
            for fut in done:
                sent += fut.result()
                pending.pop(fut)
            rate = sent / max(time.time() - t0, 0.1) / 1e6
            print(f"\r[push] {f.name}  {sent / 1e6:,.0f}/{size / 1e6:,.0f} MB  {rate:.2f} MB/s", end="", flush=True)
    print()
    for _ in range(600):
        st = sh(sb, f"cat {stage}/complete 2>/dev/null", check=False).strip()
        if st:
            break
        time.sleep(1)
    if st != "ok":
        raise RuntimeError(f"box-side writer failed for {dst}")
    remote = int(sh(sb, f"stat -c %s {shlex.quote(dst)}").strip())
    if remote != size:
        raise RuntimeError(f"size mismatch for {dst}: local {size}, remote {remote}")
    if verify:
        lm = _md5(f)
        rm = sh(sb, f"md5sum {shlex.quote(dst)}", timeout=1800).split()[0]
        if lm != rm:
            raise RuntimeError(f"md5 mismatch for {dst}")
        print(f"[push]   verified md5 {lm}")
    sh(sb, f"rm -rf {stage}", check=False)


def cmd_push(a):
    d = client()
    sb = storage_box(d, a.volume)
    dest_root = f"{MEDIA}/{a.to.strip('/')}"
    jobs = []
    for p in map(Path, a.paths):
        p = p.expanduser().resolve()
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not f.name.startswith("."):
                    jobs.append((f, f"{dest_root}/{p.name}/{f.relative_to(p).as_posix()}"))
        elif p.is_file():
            jobs.append((p, f"{dest_root}/{p.name}"))
        else:
            sys.exit(f"not found: {p}")
    if not a.overwrite:
        existing = set(sh(sb, f"find {shlex.quote(dest_root)} -type f -printf '%p %s\\n' 2>/dev/null", check=False).splitlines())
        skipped = [j for j in jobs if f"{j[1]} {j[0].stat().st_size}" in existing]
        if skipped:
            print(f"[push] skipping {len(skipped)} file(s) already on the volume (same size); --overwrite to resend")
        jobs = [j for j in jobs if j not in skipped]
    if not jobs:
        print("[push] nothing to do")
        return
    dirs = sorted({j[1].rsplit("/", 1)[0] for j in jobs})
    sh(sb, "mkdir -p " + " ".join(shlex.quote(x) for x in dirs))
    small = [j for j in jobs if j[0].stat().st_size <= 2 * CHUNK]
    big = [j for j in jobs if j[0].stat().st_size > 2 * CHUNK]
    if small:
        def up(j):
            _retry(lambda: sb.fs.upload_file(str(j[0]), j[1], timeout=1800))
            print(f"[push] {j[0].name}  {j[0].stat().st_size / 1e6:,.1f} MB")
        with ThreadPoolExecutor(WORKERS) as ex:
            list(ex.map(up, small))
    for f, dst in big:
        push_big(sb, f, dst, verify=not a.no_verify)
    print(f"[push] {len(jobs)} file(s) -> {dest_root}")


def cmd_fetch(a):
    """Download a URL straight onto the volume from inside Daytona (datacenter bandwidth)."""
    d = client()
    sb = storage_box(d, a.volume)
    name = a.name or a.url.split("?")[0].rstrip("/").rsplit("/", 1)[-1] or "download.bin"
    dst = f"{MEDIA}/{a.to.strip('/')}/{name}"
    sh(sb, f"mkdir -p {shlex.quote(dst.rsplit('/', 1)[0])}")
    print(f"[fetch] {a.url} -> {dst}")
    t = time.time()
    sh(sb, f"curl -fL --retry 5 -o {shlex.quote(dst)} {shlex.quote(a.url)}", timeout=6 * 3600)
    size = int(sh(sb, f"stat -c %s {shlex.quote(dst)}").strip())
    print(f"[fetch] {size / 1e6:,.1f} MB in {time.time() - t:,.0f}s")


def cmd_pull(a):
    d = client()
    sb = storage_box(d, a.volume)
    src = a.path if a.path.startswith("/") else f"{MEDIA}/{a.path.strip('/')}"
    out = Path(a.local_dir).expanduser()
    q = shlex.quote(src)
    files = [x for x in sh(sb, f"if [ -d {q} ]; then find {q} -type f; else ls -d {q}; fi").splitlines() if x.strip()]
    base = src.rstrip("/").rsplit("/", 1)[0]
    for f in files:
        local = out / Path(f).relative_to(base)
        local.parent.mkdir(parents=True, exist_ok=True)
        sb.fs.download_file(f, str(local))
        print(f"[pull] {f} -> {local}")


def cmd_ls(a):
    d = client()
    sb = storage_box(d, a.volume)
    path = f"{MEDIA}/{a.subdir.strip('/')}" if a.subdir else MEDIA
    print(sh(sb, f"cd '{path}' && du -sh * 2>/dev/null; echo; find . -type f -not -path './.resolve-state/*' | head -200").strip())


def cmd_status(a):
    d = client()
    for s in find_box(d, BOX_LABEL) + find_box(d, STORAGE_LABEL):
        print(f"{s.labels.get('role'):8} {s.name:28} {str(s.state).split('.')[-1]:10} gpu={s.gpu} {s.gpu_type or ''}")
    vol = d.volume.get(a.volume, create=False)
    print(f"volume   {vol.name:28} {str(vol.state).split('.')[-1]}")
    sb = next((s for s in find_box(d, BOX_LABEL) if running(s)), None)
    if sb:
        sync_scripts(sb)
        print(sh(sb, "/opt/scripts/resolve-state.sh status", check=False).strip())


# --------------------------------------------------------------------------- cli
def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="build the GPU snapshot")
    s.add_argument("--name", default=DEFAULT_SNAPSHOT)
    s.add_argument("--gpu-type", default=DEFAULT_GPU, help="one of RTX-PRO-6000, L40S, RTX-4090, RTX-5090, H100, ...")
    s.add_argument("--cpu", type=int)
    s.add_argument("--memory", type=int, help="GB")
    s.add_argument("--disk", type=int, help="GB")
    s.add_argument("--region")
    s.add_argument("--replace", action="store_true")
    s.set_defaults(fn=cmd_snapshot)

    u = sub.add_parser("up", help="start (or reuse) the GPU box")
    u.add_argument("--snapshot", default=DEFAULT_SNAPSHOT)
    u.add_argument("--name")
    u.add_argument("--volume", default=DEFAULT_VOLUME)
    u.add_argument("--auto-stop", type=int, default=60, help="idle minutes before the box is stopped+deleted (0 = never)")
    u.add_argument("--resolution", default="1920x1080")
    u.add_argument("--public", action="store_true")
    u.add_argument("--no-resolve", action="store_true")
    u.add_argument("--new", action="store_true", help="always create a new box")
    u.set_defaults(fn=cmd_up)

    for name, fn, h in (("down", cmd_down, "save + delete the box"), ("save", cmd_save, "save projects now"),
                        ("verify", cmd_verify, "smoke test"), ("vnc", cmd_vnc, "desktop URL")):
        x = sub.add_parser(name, help=h)
        x.add_argument("sandbox", nargs="?")
        if name == "vnc":
            x.add_argument("--restart", action="store_true")
        x.set_defaults(fn=fn)

    x = sub.add_parser("push", help="upload files/folders to the volume")
    x.add_argument("paths", nargs="+")
    x.add_argument("--to", default="footage", help="folder on the volume (footage, audio, assets, ...)")
    x.add_argument("--overwrite", action="store_true", help="re-upload files already present with the same size")
    x.add_argument("--no-verify", action="store_true", help="skip md5 check of big files")
    x.add_argument("--volume", default=DEFAULT_VOLUME)
    x.set_defaults(fn=cmd_push)

    x = sub.add_parser("fetch", help="download a URL straight onto the volume (fast, server-side)")
    x.add_argument("url")
    x.add_argument("--to", default="footage")
    x.add_argument("--name", help="file name on the volume")
    x.add_argument("--volume", default=DEFAULT_VOLUME)
    x.set_defaults(fn=cmd_fetch)

    x = sub.add_parser("pull", help="download from the volume")
    x.add_argument("path")
    x.add_argument("local_dir", nargs="?", default=".")
    x.add_argument("--volume", default=DEFAULT_VOLUME)
    x.set_defaults(fn=cmd_pull)

    x = sub.add_parser("ls", help="list volume contents")
    x.add_argument("subdir", nargs="?")
    x.add_argument("--volume", default=DEFAULT_VOLUME)
    x.set_defaults(fn=cmd_ls)

    x = sub.add_parser("status")
    x.add_argument("--volume", default=DEFAULT_VOLUME)
    x.set_defaults(fn=cmd_status)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
