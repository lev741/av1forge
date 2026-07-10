# av1forge

**NUMA-aware parallel AV1 transcoding for archival media collections.**

A Bash script that batch-transcodes video libraries to AV1 (via SVT-AV1) with intelligent codec detection, automatic black & white film optimization, NUMA-pinned parallel encoding, and a triple-buffered I/O pipeline designed for NAS-to-NAS workflows.

---

## ✨ Key Features

- **Parallel NUMA-aware encoding** — automatically detects NUMA topology, pins jobs to nodes, and dynamically allocates threads and RAM per job
- **Smart codec decisions** — skips files already in AV1/HEVC; preserves modern audio codecs (Opus, TrueHD, AC3, DTS); transcodes legacy audio to Opus
- **Black & white detection** — samples saturation across the film and applies optimized CRF/grain settings for B&W content
- **Triple-buffered I/O** — separates network I/O (rsync) from CPU encoding with IN/OUT buffers on a local work disk, keeping NUMA cores busy
- **Resilient & resumable** — tracks state in `state.log`; skips already-processed files on restart; graceful SIGTERM/SIGINT shutdown
- **Disk space awareness** — monitors work disk free space; prioritizes flushing output when low
- **Efficiency guard** — if AV1 output is larger than 105% of the original, falls back to keeping the original video and re-encoding audio only
- **Dry-run mode** — test your pipeline without touching any files (`-t`)

---

## 📋 Requirements

| Dependency | Minimum Version | Purpose |
|---|---|---|
| **Bash** | 5.3+ | `wait -n`, `mapfile`, associative arrays |
| **ffmpeg** | 5.0+ (with `libsvtav1`, `libopus`) | Video/audio encoding |
| **ffprobe** | (bundled with ffmpeg) | Stream analysis |
| **mkvtoolnix** (`mkvmerge`, `mkvpropedit`) | 70+ | Container preprocessing & correction |
| **rsync** | 3.0+ | Buffered file transfer |
| **numactl** | any | NUMA node pinning (only required on multi-NUMA systems) |
| **coreutils** | 8.0+ | `timeout`, `nice`, `ionice`, `stat`, `nproc` |

### Optional
- `lscpu` — for accurate per-node CPU count detection
- `findmnt` — for work directory filesystem validation

---

## 🚀 Installation

```bash
git clone https://github.com/lev741/av1forge.git
cd av1forge
chmod +x av1forge.sh
```

Ensure `ffmpeg` (with SVT-AV1 and Opus support), `mkvtoolnix`, and `rsync` are installed:

```bash
# Debian/Ubuntu
sudo apt install ffmpeg mkvtoolnix rsync numactl

# Arch Linux
sudo pacman -S ffmpeg mkvtoolnix-cli rsync numactl

# Fedora
sudo dnf install ffmpeg mkvtoolnix rsync numactl
```

> [!NOTE]
> If your distro's ffmpeg lacks `libsvtav1`, you may need to build ffmpeg from source or use a static build. Point to it with `-f /path/to/ffmpeg`.
> `libsvtav1` version 3.1.2 has a bug causing a deadlock during encoding. Try using a development version where it has been fixed ([latest static FFmpeg build](https://github.com/BtbN/FFmpeg-Builds/releases/latest))

---

## 📖 Usage

```bash
./av1forge.sh -z /path/to/source -c /path/to/target -w /path/to/workdir [OPTIONS]
```

### Required Paths

| Flag | Description |
|---|---|
| `-z PATH` | Source directory containing video files |
| `-c PATH` | Target directory for transcoded output |
| `-w PATH` | Work directory on a **local** fast disk (SSD/NVMe recommended) |

### Options

| Flag | Description | Default |
|---|---|---|
| `-j COUNT` | Max parallel encoding jobs | Number of NUMA nodes |
| `-b COUNT` | Input buffer size (prefetch count) | `jobs × 10` |
| `-f PATH` | Path to custom ffmpeg binary | `ffmpeg` from PATH |
| `-t` | Test / dry-run mode | off |
| `-V` | Print version and exit | — |
| `-h` | Show help | — |

### Examples

**Basic — single machine, local files:**
```bash
./av1forge.sh -z ~/Movies -c ~/Movies-AV1 -w /tmp/av1work
```

**NAS-to-NAS with fast local work disk:**
```bash
./av1forge.sh \
  -z /mnt/nas/movies \
  -c /mnt/nas/movies-av1 \
  -w /mnt/nvme/av1work \
  -j 4 -b 20
```

**Custom ffmpeg build, 8 parallel jobs:**
```bash
./av1forge.sh \
  -z /data/source \
  -c /data/output \
  -w /fast-ssd/work \
  -j 8 \
  -f /opt/ffmpeg-svtav1/ffmpeg
```

---

## ⚙️ How It Works

```
┌─────────────┐     rsync      ┌──────────────┐    encode    ┌──────────────┐     rsync      ┌─────────────┐
│   SOURCE     │ ──────────────▶│   IN Buffer  │ ───────────▶│  OUT Buffer  │ ──────────────▶│   TARGET    │
│   (NAS)      │   1 file/time  │  (local SSD) │  N parallel │  (local SSD) │   1 file/time  │   (NAS)     │
└─────────────┘                 └──────────────┘             └──────────────┘                 └─────────────┘
                                       ▲                            │
                                       │         NUMA node 0       │
                                       │         NUMA node 1       │
                                       │         ...               │
                                       └────────────────────────────┘
                                              RAM-aware scheduler
```

### Pipeline Stages

1. **Scan** — recursively finds video files (`mkv`, `mp4`, `avi`, `mov`, etc.) in the source directory
2. **Prefetch (IN buffer)** — rsyncs files one-at-a-time to the local work disk
3. **Preprocess** — `mkvmerge` re-muxes the container for clean timestamps; strips problematic stereo-3D metadata
4. **Analyze** — `ffprobe` inspects all streams; saturation sampling detects B&W films
5. **Encode** — `ffmpeg` with SVT-AV1 (video) and Opus (audio); NUMA-pinned with `numactl`
6. **Post-process** — `mkvmerge` re-muxes output, reattaches cover art, fonts, and attachments
7. **Efficiency check** — if output > 105% of original, falls back to copy-video + re-encode audio
8. **Deliver (OUT buffer)** — rsyncs finished files to the target directory

### Encoding Decisions

| Resolution | CRF | Preset | Notes |
|---|---|---|---|
| ≤ 576p (SD) | 22 | 3 | Higher quality for low-res content |
| ≤ 720p | 24 | 4 | |
| 1080p | 26 | 4 | Default |
| > 1080p (4K) | 28 | 5 | Balanced for large frames |
| B&W film | 18 | 4 | Grayscale + film grain synthesis |

**Audio rules:**
- Opus, TrueHD, AC3, EAC3, DTS → **copy** (no re-encode)
- Everything else → **Opus 128 kbps** (64 kbps for mono)
- Surround layouts normalized for libopus compatibility

---

## 📊 Output Files

All output files are created in the work directory (`-w`):

| File | Description |
|---|---|
| `state.log` | List of successfully processed files (one per line). Used for resume. |
| `stats.csv` | Semicolon-delimited statistics: filename, CRF, preset, codecs, sizes, savings %, duration |
| `errors.log` | Failed files with error stage and FFmpeg log excerpts |

---

## 🔧 Troubleshooting

**"This script requires Bash 5.3 or newer"**
Your system Bash is too old. Install a newer version or use `env bash` from a custom build.

**"Work directory is not on a local block device"**
The work directory must be on a local disk (not NFS/CIFS/SSHFS). Lock files and temp encoding need local I/O.

**"mkvmerge is not installed"**
Install the `mkvtoolnix` package for your distribution.

**Encoding is slow / uses only one NUMA node**
Check that `numactl` is installed. The script auto-detects NUMA topology and pins jobs accordingly.

**Output file is larger than original**
This is handled automatically — the script detects this (> 105% threshold) and falls back to keeping original video while re-encoding audio only.

---

## 📄 License

[MIT](LICENSE)
