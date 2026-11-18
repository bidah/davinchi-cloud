# DaVinci Resolve Studio on Daytona GPU sandboxes

A Daytona **GPU snapshot** with DaVinci Resolve Studio (Linux) installed, plus a
small CLI that starts a box and opens Resolve in a browser desktop.

```
┌──────────── Daytona GPU sandbox (RTX PRO 6000 / L40S / RTX 4090 / 5090) ────────────┐
│ Ubuntu 22.04                                                                         │
│ Computer Use desktop: Xvfb :0 (1920x1080) + xfce4 + x11vnc + noVNC :6080             │
│ /opt/resolve  DaVinci Resolve Studio ── vglrun -d egl ──► NVIDIA OpenGL 4.6           │
│                                       └─ CUDA / OpenCL / NVENC from the GPU runtime  │
│ ~/media  ◄── Daytona volume "resolve-media" (persists; the GPU box is ephemeral)     │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## How it works

| Piece | Choice | Why |
|---|---|---|
| Base | `ubuntu:22.04` | apt has all the packages Daytona Computer Use needs |
| Resolve install | official `.run` → `--appimage-extract` → `AppRun -i -a -y` with `SKIP_PACKAGE_CHECK=1`, then `patchelf` to load the system glib | the [davincibox](https://github.com/zelikos/davincibox) recipe, unattended |
| Installer size | separate build stage | the ~3 GB zip doesn't end up in the final image |
| Desktop | `sandbox.computer_use.start()` | Daytona's managed Xvfb + xfce + x11vnc + noVNC |
| GPU rendering | VirtualGL 3.1 EGL back end (`vglrun -d egl`) | Xvfb has no GPU; VirtualGL renders Resolve's OpenGL on the NVIDIA card |
| Driver | injected at runtime (`NVIDIA_DRIVER_CAPABILITIES=all`) | matches whatever driver the GPU host runs |

Two Daytona quirks are handled for you (both confirmed on a live GPU box):

1. **Missing soname links.** The NVIDIA runtime mounts `libEGL_nvidia.so.<ver>`
   and `libGLX_nvidia.so.<ver>` but does not run `ldconfig`. Without the `.so.0`
   links, VirtualGL silently falls back to Mesa llvmpipe.
   `scripts/start-resolve.sh` runs `sudo ldconfig` before launching.
2. **Small default desktop.** Computer Use defaults to 1024x768. The image sets
   `VNC_RESOLUTION=1920x1080`, and `up --resolution` can override it. Resolution
   can only be set when the sandbox is created.

## Prerequisites

- Python 3.10+ and the Daytona SDK: `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`
- Daytona credentials: `DAYTONA_API_KEY`, or a logged-in `daytona` CLI (the script reads its config).
- GPU access on your Daytona org.
- The **Linux** installer from Blackmagic (registration form):
  <https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion>
  → *DaVinci Resolve Studio 21.2* → **Linux**. Put the zip in `optional/`:

  ```bash
  mv ~/Downloads/DaVinci_Resolve_Studio_21.2_Linux.zip optional/
  ```
  `optional/` is git-ignored. A `.run` you already extracted works too.

## 1. Build the snapshot (once per Resolve version)

```bash
.venv/bin/python daytona_resolve.py snapshot            # name: davinci-resolve-studio
.venv/bin/python daytona_resolve.py snapshot --replace  # rebuild after changes
```

This uploads the build context (installer included) and builds on Daytona.
Daytona snapshots take **one** GPU type: the default is `RTX-PRO-6000`, and you
can change it with `--gpu-type L40S` (or `RTX-4090`, `RTX-5090`, `H100`, ...).
RTX-class cards have NVENC; H100/H200 have no hardware H.264/H.265 encoder.

## 2. Daily use

```bash
R=".venv/bin/python daytona_resolve.py"

$R push ~/Shoots/day1 --to footage     # upload media (no GPU box needed)
$R push music.wav logo.png --to assets
$R fetch https://.../A001.mov          # server-side download straight onto the volume (fast)

$R up                                  # GPU box + desktop + Resolve, media + projects already there
$R down                                # close Resolve, save projects, delete the box

$R pull exports/final.mov ~/Desktop    # download a render
$R ls footage                          # what's on the volume
$R status                              # boxes, volume, last project save
$R save | vnc [--restart] | verify     # save now / desktop URL / smoke test
```

`up` reuses the running box if there is one; otherwise it creates a new one
(`--new` forces a new box). Options: `--resolution 2560x1440`, `--auto-stop 120`,
`--volume <name>` (separate volume per client or project), `--no-resolve`, `--public`.

## 3. Persistent storage

GPU boxes are **ephemeral**: they are deleted on `down`, on idle auto-stop, or if
they crash. Everything worth keeping lives on the Daytona **volume**
`resolve-media`. It is created on first use and mounted at `~/media` in every box:

```
~/media/
  footage/  audio/  assets/        your media: import it in Resolve from here
  exports/                         render here
  project-archives/                .dra / .drp exports
  .resolve-state/                  automatic project-database backups (state-<UTC>.tar.gz, last 5)
```

- **Media** sits directly on the volume, so it's there as soon as any box starts.
  Media pool links to `~/media/...` keep working because the path is the same
  in every box.
- **Projects**: Resolve's database is SQLite, which can't run on a FUSE/S3
  volume. It runs on the box's local disk instead:
  - `up` restores the newest backup before Resolve starts.
  - Autosave writes a new backup every 5 minutes, only when something changed.
  - `down` closes Resolve and saves one last time.
  - At worst, a crash or idle auto-stop loses the last ≤5 minutes of edits.
- **Uploads**: `push` sends big files as 16 MB chunks over 8 parallel streams
  (about 5x faster than a single stream) and checks the MD5 afterwards. Files
  already on the volume with the same size are skipped, so re-running a push
  resumes it. With no GPU box running, `push`/`pull`/`ls` use a small CPU box
  (`resolve-storage-<volume>`), so you don't pay for a GPU while uploading.
- **Volume behaviour** (`mountpoint-s3`): sequential writes, overwrite and delete
  work, but **rename does not**. Reading is slower than local disk. For heavy
  4K/RAW timelines, generate optimized media or proxies, and keep Resolve's cache
  on the local disk (the default).

These were all tested on live Daytona GPU boxes:
- push, then a fresh `up` shows the media with matching MD5
- project data survives `down` and `up`
- an edit survives a box killed without `down`, via autosave
- pull of a file name with spaces

## Studio licence: read this

- On first launch Resolve Studio asks for your **activation key**. Enter it in
  the GUI. It is never baked into the image.
- Activation is tied to the machine, and a key allows **2 activations**. Each
  `up` creates a new machine.
- **Before every `down`, run Help ▸ Deactivate License in Resolve**, or you'll
  use up your activations and have to reset them with Blackmagic support.
- `--auto-stop` defaults to 60 idle minutes; after that the box is deleted
  (projects are autosaved). Raise it for long sessions.

## Layout

```
Dockerfile                          base → installer stage → final image
daytona_resolve.py                  snapshot | up | down | push | fetch | pull | ls | status | save | vnc | verify
requirements.txt                    daytona SDK
optional/                           put the Resolve Linux zip/run here (git-ignored)
scripts/install-davinci-resolve.sh  unattended install (build time)
scripts/start-resolve.sh            ldconfig fix + vglrun -d egl launcher
scripts/resolve-state.sh            project DB restore / save / autosave to the volume
scripts/verify-davinci-resolve.sh   in-box smoke test
scripts/davinci-resolve.desktop     desktop / menu launcher
scripts/install-resolve-mcp.sh      optional davinci-resolve MCP (build arg INSTALL_MCP=1)
scripts/start-mcp.sh                run the MCP server in the box
mcp/README.md                       agent control notes
```

## Troubleshooting

- **`No installer in ./optional/`**: download the *Linux* zip (not the Mac one).
- **Resolve shows "GPU not supported" or renders slowly**: run `verify`. The GL
  line must say `NVIDIA`. If it says llvmpipe, run `sudo ldconfig` and relaunch.
- **noVNC 503 / blank**: `daytona_resolve.py vnc <id> --restart`.
- **Logs**: `/tmp/resolve.log`, `/opt/resolve/logs/`.
