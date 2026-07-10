# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2025-07-10

### Added
- NUMA-aware parallel encoding with automatic topology detection
- SVT-AV1 video encoding with resolution-adaptive CRF/preset
- Automatic black & white film detection via saturation sampling
- Smart audio handling: passthrough for modern codecs (Opus, TrueHD, AC3, EAC3, DTS), Opus encoding for legacy codecs
- Subtitle preservation (copy) with format conversion for incompatible types (mov_text → SRT)
- Triple-buffered I/O pipeline (source → IN buffer → encode → OUT buffer → target)
- Dynamic thread and RAM allocation per job
- Efficiency guard: reverts to original video if AV1 output > 105% of source
- Disk space monitoring with automatic OUT queue prioritization when low
- mkvmerge preprocessing for clean container timestamps
- Cover art and attachment preservation via mkvmerge
- Graceful shutdown on SIGINT/SIGTERM with process tree cleanup
- Resumable processing via state.log
- Detailed per-file statistics in stats.csv
- Error log with FFmpeg output excerpts
- Test/dry-run mode (`-t`)
- Configurable ffmpeg binary path (`-f`)
