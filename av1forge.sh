#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# ==========================================================
# av1forge — Archival transcoding to AV1
# Parallel processing on CPU NUMA nodes
# Requires Bash 5.3+
# https://github.com/lev741/av1forge
# ==========================================================

readonly VERSION="1.0.0"

#set -eou pipefail # Kept disabled for stability of parallel forking
shopt -s extglob globstar nullglob nocaseglob

# --- Configuration ---
WORK_DIR="${WORK_DIR:-$PWD}"
SOURCE_DIR="${SOURCE_DIR:-}"
TARGET_DIR="${TARGET_DIR:-}"
declare -r LOCK="stats.lock"
# Prefer ffmpeg from PATH; fall back to script directory
if command -v ffmpeg &>/dev/null; then
    FFMPEG_CMD="ffmpeg"
else
    FFMPEG_CMD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ffmpeg"
fi

# Keep modern codecs as-is
declare -r aCODECS_OK="opus|truehd|ac3|eac3|dca|dts"
declare -r vCODECS_OK="av1|hevc|h265"
TEST=false

usage() {
  cat << EOF
$(basename "$0") v${VERSION} — Archival transcoding to AV1, parallel processing on NUMA nodes

USAGE:
    $(basename "$0") [OPTIONS]

BASIC OPTIONS:
    -h              Show this help and exit.
    -V              Show version and exit.
    -t              Test mode (dry-run).
    -j COUNT        Maximum number of parallel jobs (default NUMA node count: ${MAX_JOBS}).
    -b COUNT        Input buffer size (number of movies to prefetch, default: ${IN_BUFFER_SIZE}).
    -f PATH         Path to ffmpeg binary (default: ffmpeg).

PATHS:
    -z PATH         Source directory (SOURCE_DIR)
                    (current: ${SOURCE_DIR})
    -c PATH         Target directory (TARGET_DIR)
                    (current: ${TARGET_DIR})
    -w PATH         Work directory (WORK_DIR)
                    (current: ${WORK_DIR})

EXAMPLE:
    $(basename "$0") -j 8 -b 3 -z /mnt/nas/source -c /mnt/nas/done -w /mnt/nvme/work

Processing state:  ${WORK_DIR}/state.log
Statistics:        ${WORK_DIR}/stats.csv
Processing errors: ${WORK_DIR}/errors.log

EOF
  exit 0
}

# --- Logging functions ---
log() {
    local prefix=""
    pgrep -x rsync >/dev/null 2>&1 && prefix="\\n"
    echo -e "${prefix}[$(date +'%T')] $*"
}

# Check free space on the work disk
# Returns 0 if there is enough space, 1 if below the limit
# Limits: at least 10% free space OR 100 GB (102400 MB)
DISK_MIN_PCT=10
DISK_MIN_MB=102400  # 100 GB
check_work_disk_space() {
    local dir="$1"
    local avail_kb total_kb pct_free avail_mb
    read -r total_kb avail_kb < <(df -P -k "$dir" 2>/dev/null | awk 'NR==2 {print $2, $4}')
    if [[ -z "$total_kb" || -z "$avail_kb" || "$total_kb" -eq 0 ]]; then
        return 0  # cannot determine → don't check
    fi
    pct_free=$(( avail_kb * 100 / total_kb ))
    avail_mb=$(( avail_kb / 1024 ))
    if (( pct_free < DISK_MIN_PCT )) || (( avail_mb < DISK_MIN_MB )); then
        echo "${avail_mb}:${pct_free}"
        return 1
    fi
    return 0
}

# Estimate RAM in MB for SVT-AV1 encoding based on video height and thread count
# Conservative estimate with 15% safety margin
estimate_job_ram_mb() {
    local height=$1 threads=$2
    local base_ram thread_factor
    if   (( height <= 576  )); then base_ram=2000;  thread_factor=60
    elif (( height <= 720  )); then base_ram=4000;  thread_factor=95
    elif (( height <= 1080 )); then base_ram=6000;  thread_factor=125
    elif (( height <= 1440 )); then base_ram=9000;  thread_factor=200
    else                            base_ram=14000; thread_factor=310
    fi
    local extra=$(( threads > 8 ? threads - 8 : 0 ))
    echo $(( (base_ram + extra * thread_factor) * 115 / 100 ))
}

# Quick detection of video height (in px) for memory requirement estimation
get_file_height() {
    local file=$1
    "$FFPROBE_CMD" -v error -select_streams v:0 \
        -show_entries stream=height -of csv=p=0 "$file" 2>/dev/null | head -1
}

# Function to clean up leftovers
cleanup() {
    rm -rf "$WORK_DIR"/job[0-9]* 2>/dev/null || true
    rm -f "$WORK_DIR/$LOCK" 2>/dev/null || true
    # Remove empty directories (if any)
    find "$WORK_DIR/in" "$WORK_DIR/out" "$WORK_DIR/err" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

# Helper function to get all descendants before we start killing
get_descendants() {
    local parent=$1
    local children child
    mapfile -t children < <(pgrep -P "$parent" 2>/dev/null)
    for child in "${children[@]}"; do
        [[ -z "$child" ]] && continue
        get_descendants "$child"
        echo "$child"
    done
}

# --- Cleanup and exit function ---
cleanup_and_exit() {
    trap '' SIGINT SIGTERM
    echo -e "\\n"
    log "🛑  Termination signal received. Collecting PIDs of running processes..."
    local all_pids=($(get_descendants $$))
    
    if (( ${#all_pids[@]} > 0 )); then
        log "🔪  Sending SIGTERM to ${#all_pids[@]} processes..."
        kill -TERM "${all_pids[@]}" 2>/dev/null || true
        log "🦥  Waiting 10s for graceful process termination..."
        sleep 10
        log "☠️  Killing any surviving processes (SIGKILL)..."
        kill -KILL "${all_pids[@]}" 2>/dev/null || true
    fi
    printf -v runtime "%02d:%02d:%02d" $((SECONDS/3600)) $(((SECONDS%3600)/60)) $((SECONDS%60))
    log "👋 Script terminated. ⏱️  Total runtime: $runtime"
    cleanup
    exit 1
}

trap cleanup_and_exit SIGINT SIGTERM

# --- Function for processing a single file ---
process_file() {
    local rel_name="$1"
    local job_slot="$2"
    local job_threads="${3:-$total_threads}"
    local start_time=$SECONDS
    local src_filename="${rel_name##*/}"
    local in_file="$IN_DIR/$rel_name"
    local tmp_dir="$WORK_DIR/job${job_slot}"
    mkdir -p "$tmp_dir"
    
    local work_file="$in_file"
    local pre_work_file="$tmp_dir/pre.mkv"
    local tmp_output="$tmp_dir/encoding.mkv"
    local corrected_file="$tmp_dir/corrected.mkv"
    local out_file="$OUT_DIR/${rel_name%.*}.mkv"
    
    local ffmpeg_log="$tmp_dir/ffmpeg.log"

    # Helper function for error handling
    handle_error() {
        local stage="$1"
        local err_detail=""
        if [[ -s "$ffmpeg_log" ]]; then
            err_detail=$(tail -30 "$ffmpeg_log")
            log "❌ [Job $job_slot] Error at $stage: $rel_name"
            log "--- FFmpeg output ---"
            echo "$err_detail" | while IFS= read -r line; do log "  $line"; done
            log "--- End of FFmpeg output ---"
        else
            log "❌ [Job $job_slot] Error at $stage: $rel_name (no FFmpeg output)"
        fi
        (
            flock -x 200
            echo "${stage}; $rel_name" >> "$ERROR_FILE"
            if [[ -n "$err_detail" ]]; then
                echo "  FFmpeg log:" >> "$ERROR_FILE"
                echo "$err_detail" >> "$ERROR_FILE"
            fi
        ) 200>"$WORK_DIR/$LOCK"
        
        mkdir -p "$(dirname "$ERR_DIR/$rel_name")"
        cp -f "$in_file" "$ERR_DIR/$rel_name" 2>/dev/null || true
        rm -f "$in_file"
        rm -rf "$tmp_dir"
    }

    local stream_data raw_data p_vid p_aud p_sub idx codec type p4 p5 a_idx a_codec a_channels
    local vf_audio_params="" vf_video_params=""
    local encode_audio=N encode_video=N
    local ffmpeg_prolog="-loglevel error -nostdin -fflags +genpts -analyzeduration 500M -probesize 500M " # -threads 4 
    local orig_size=$(stat -c%s "$work_file" 2>/dev/null || echo 0)
    local input_params="-err_detect ignore_err -fflags +genpts+igndts"
    local output_params="-avoid_negative_ts make_zero -max_muxing_queue_size 8192 -max_interleave_delta 0"
    local mkv_attach_args=()

    # FFmpeg: lower CPU and IO priorities, run on NUMA node
    local cmd_prefix=(nice -n 16 ionice -c 2 -n 7)
    if [[ $numa_count -gt 1 && $job_threads -lt $total_threads ]]; then
        local numa_node=$(( (job_slot+1) % numa_count )) # Keep NUMA 0 free as long as possible
        cmd_prefix+=(numactl --cpunodebind=$numa_node --preferred=$numa_node)
    fi

    # --- Initial mkvmerge preprocessing ---
    log "[Job $job_slot] 🛠️ Initial preprocessing (mkvmerge): $rel_name"
    if [[ "$TEST" == "true" ]]; then
        log "${cmd_prefix[*]} mkvmerge --quiet --clusters-in-meta-seek -o $pre_work_file $work_file"
        cp -f "$work_file" "$pre_work_file" 2>/dev/null || true
        work_file="$pre_work_file"
    else
        if ( timeout -k 1m 30m "${cmd_prefix[@]}" mkvmerge --quiet --clusters-in-meta-seek -o "$pre_work_file" "$work_file" < /dev/null; exit $? ) 2>/dev/null || (( $? == 1 )); then
            work_file="$pre_work_file"
            # Work around FFmpeg bug (File exists / EEXIST) when H264 SEI and MKV container both have Stereo 3D metadata
            "${cmd_prefix[@]}" mkvpropedit "$work_file" --edit track:v1 --delete stereo-mode >/dev/null 2>&1 || true
        else
            log "[Job $job_slot] ⚠️ mkvmerge pre-processing failed. Trying fallback remux via ffmpeg..."
            if timeout -k 1m 30m "${cmd_prefix[@]}" "$FFMPEG_CMD" -v fatal -nostdin -i "$work_file" -map 0 -c copy -map_metadata 0 -y "$pre_work_file" 2>/dev/null; then
                work_file="$pre_work_file"
            else
                log "[Job $job_slot] ⚠️ Fallback remux also failed. Using original file without pre-processing."
                # Continue without returning an error
            fi
        fi
    fi
    local baseline_size=$(stat -c%s "$work_file" 2>/dev/null || echo 0)

    # FFprobe analysis
    log "[Job $job_slot] 🔍 Analysis: $rel_name"
    raw_data=$("${cmd_prefix[@]}" "$FFPROBE_CMD" -v error -analyzeduration 2000M -probesize 2000M \
                -show_entries stream=codec_type,index,codec_name,width,height,channels \
                -of csv=p=0:s=\| "$work_file" 2>/dev/null)
    if [[ "$TEST" == "true" ]]; then
        log "[Job $job_slot] ℹ️ RAW data <$src_filename>: $raw_data"
    fi

    while IFS="|" read -r idx codec type p4 p5; do
        if [[ "$type" == "video" ]]; then
            if [[ "$codec" =~ ^(mjpeg|png|bmp|webp|jpeg)$ ]]; then
                log "[Job $job_slot] 🖼️ Detected attachment (cover art): stream $idx ($codec) - will be attached via mkvmerge"
                continue
            fi
            p_vid+="${idx}|${codec}|${p4}|${p5}"$'\n'
        elif [[ "$type" == "audio" ]]; then
            p_aud+="${idx}|${codec}|${p4}"$'\n'
        elif [[ "$type" == "subtitle" ]]; then
            p_sub+="${idx}|${codec}"$'\n'
        elif [[ "$type" == "attachment" ]]; then
            log "[Job $job_slot] 📎 Detected attachment: stream $idx - will be attached via mkvmerge"
        fi
    done <<< "$raw_data"

    stream_data=$(echo "$p_vid" | sort -t'|' -k3,3nr | head -n1)
    if [[ -z "$stream_data" ]]; then
        handle_error "analysis"
        return 1
    fi

    # --- Audio analysis and parameters ---
    local audio_params="" map_audio="" a_cnt=0 orig_acodecs=""
    while IFS='|' read -r a_idx a_codec a_channels; do
        [[ -z "$a_codec" ]] && continue
        orig_acodecs="${orig_acodecs:-$a_codec}"
        map_audio+=" -map 0:$a_idx"
        local a_opts=""
        if [[ "$a_codec" =~ ^($aCODECS_OK)$ ]]; then
            a_opts="-c:a:$a_cnt copy"
            if [[ "${a_channels:-2}" -eq 1 ]]; then
                log "[Job $job_slot] 🔊 Audio $a_cnt: Mono preserved (copy)"
            fi
        else
            encode_audio=Y
            a_opts="-c:a:$a_cnt libopus -b:a:$a_cnt 128k -vbr:a:$a_cnt on"
            if [[ "${a_channels:-2}" -eq 1 ]]; then
                a_opts="-c:a:$a_cnt libopus -b:a:$a_cnt 64k -vbr:a:$a_cnt on -ac:a:$a_cnt 1"
                log "[Job $job_slot] 🔊 Audio $a_cnt: Mono ($a_codec -> Opus 64k)"
            fi
            if [[ "${a_channels:-2}" -gt 2 ]]; then
                a_opts+=" -mapping_family:a:$a_cnt 1"
                # FFmpeg libopus rejects non-standard layout names (e.g., 5.0(side))
                # — normalize to standard name for the given channel count
                vf_audio_params+=" -filter:a:$a_cnt aresample=async=1,aformat=channel_layouts=7.1|6.1|7.0|5.1|5.0|quad|surround|stereo|mono"
            fi
        fi
        audio_params+="$a_opts "
        ((++a_cnt))
    done <<<"$p_aud"

    # --- Subtitle analysis and parameters ---
    local subtitle_params="" map_sub="" s_cnt=0
    while IFS='|' read -r s_idx s_codec; do
        [[ -z "$s_codec" || "$s_codec" =~ ^(unknown|none|bin_data|epg|scte_35)$ ]] && continue
        map_sub+=" -map 0:$s_idx"
        if [[ "$s_codec" =~ ^(mov_text|tx3g|text|eia_608|cc_dec|arib_caption)$ ]]; then
             subtitle_params+=" -c:s:$s_cnt subrip"
             log "[Job $job_slot] 💬 Subtitle $s_cnt: Converting $s_codec -> SRT"
        elif [[ "$s_codec" == "hdmv_pgs_subtitle" ]]; then
             subtitle_params+=" -c:s:$s_cnt copy"
             log "[Job $job_slot] 💬 Subtitle $s_cnt: Bitmap PGS ($s_codec) preserved"
        else
             subtitle_params+=" -c:s:$s_cnt copy"
             log "[Job $job_slot] 💬 Subtitle $s_cnt: Format $s_codec preserved"
        fi
        ((s_cnt++))
    done <<< "$p_sub"

    # --- Video analysis and parameters ---
    local stream_idx vcodec width height
    IFS='|' read -r stream_idx vcodec width height <<< "$stream_data"

    if [[ ! "$vcodec" =~ ^($vCODECS_OK)$ ]]; then
        encode_video=Y
    fi

    local svt_params="" video_params="-c:v:0 copy"
    local use_crf=26 use_preset=4 

    local duration=$("$FFPROBE_CMD" -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$work_file" 2>/dev/null)
    duration=${duration%.*}
    duration=${duration:-0}

    local ffmpeg_timeout="10h"
    if (( duration > 0 )); then
        ffmpeg_timeout="$(( duration * 10 ))s"
    fi

    if [[ "$encode_video" == "N" && "$encode_audio" == "N" ]]; then
        log "[Job $job_slot] ℹ️ Skipping encoding (modern codecs), repackaging only: $rel_name."
        cp -f "$work_file" "$tmp_output"
    else
        mkv_attach_args=(--no-video --no-audio --no-subtitles --no-chapters --no-track-tags --no-global-tags --no-buttons "$work_file")
        if [[ "$encode_video" != "N" ]]; then
            if [[ "$vcodec" == "mpeg4" ]]; then
                log "[Job $job_slot] 🩹 MPEG-4 detected: Adding wallclock recovery and B-frame unpacking."
                input_params+=" -use_wallclock_as_timestamps 0 -bsf:v:0 mpeg4_unpack_bframes"
            fi

            if (( height <= 576 )); then use_crf=22; use_preset=3;
            elif (( height <= 720 )); then use_crf=24; use_preset=4;
            elif (( height > 1080 )); then use_crf=28; use_preset=5; 
            fi    

            local is_bw=true sat_avg=0 valid_samples=0

            for pos in {10..90..10}; do
                local seek_time=$(( duration * pos / 100 ))
                sat_avg=$("$FFMPEG_CMD" -hide_banner -loglevel fatal -nostdin -analyzeduration 2000M -probesize 2000M -ss "$seek_time" -t 2 -i "$work_file" \
                    -map "0:$stream_idx" -an -sn -dn -vf "crop=ih:ih,scale=480:480,signalstats,metadata=mode=print:file=-" -f null - 2>&1 \
                    | grep "lavfi.signalstats.SATAVG=" | sed -n 's/.*lavfi.signalstats.SATAVG=\([0-9.]*\).*/\1/p' \
                    | awk '{sum+=$1; count++} END {if (count > 0) print sum/count; else print "FAIL"}')
                
                if [[ "$sat_avg" == "FAIL" ]]; then continue; fi
                valid_samples=$((valid_samples + 1))

                if (( $(awk -v s="$sat_avg" 'BEGIN {print (s > 1.3)}') )); then
                    is_bw=false; break
                fi
            done

            if [[ "$valid_samples" -eq 0 ]]; then
                is_bw=false
                sat_avg="N/A"
                log "[Job $job_slot] ⚠️ Unable to analyze color, switching to color mode (fallback)."
            fi

            if [[ "$is_bw" == "true" ]]; then
                log "[Job $job_slot] ⚫⚪ Black & white film (SAT: $sat_avg)"
                use_crf=18; use_preset=4
                svt_params="-svtav1-params tune=0:enable-overlays=1:film-grain=10:film-grain-denoise=0:lp=$job_threads"
                vf_video_params=" -filter:v:0 format=gray"
            else
                log "[Job $job_slot] 🎨 Color film (SAT: $sat_avg)"
                svt_params="-svtav1-params tune=0:enable-overlays=1:keyint=10s:film-grain=7:film-grain-denoise=0:lp=$job_threads"
            fi
            video_params="-c:v:0 libsvtav1 -preset:v:0 $use_preset -crf:v:0 $use_crf -pix_fmt:v:0 yuv420p10le $svt_params"
        fi

        log "[Job $job_slot] ⚙️  Encoding$([[ "$encode_video" == "Y" ]] && echo " 📽️")$([[ "$encode_audio" == "Y" ]] && echo " 🔉"): ${src_filename}"
        if [[ "$TEST" == "true" ]]; then
        log "timeout -k 1m \"$ffmpeg_timeout\" ${cmd_prefix[*]} $FFMPEG_CMD $ffmpeg_prolog $input_params -i $work_file \
            $vf_audio_params $vf_video_params -map 0:$stream_idx $map_audio $map_sub \
            $video_params $audio_params $subtitle_params $output_params -y $tmp_output"
        touch "$tmp_output"
        else
        timeout -k 1m "$ffmpeg_timeout" "${cmd_prefix[@]}" "$FFMPEG_CMD" $ffmpeg_prolog $input_params -i "$work_file" \
            $vf_audio_params $vf_video_params -map "0:$stream_idx" $map_audio $map_sub \
            $video_params $audio_params $subtitle_params $output_params -y "$tmp_output" 2>"$ffmpeg_log"
        local ff_exit=$?
        if (( ff_exit == 124 || ff_exit == 137 )); then
            log "[Job $job_slot] ⏱️ FFmpeg exceeded time limit ($ffmpeg_timeout), was terminated."
            handle_error "ffmpeg_timeout"
            return 1
        elif (( ff_exit != 0 )); then
            handle_error "ffmpeg"
            return 1
        fi
        fi
    fi

    # Correction to ensure audio is OK
    if [[ "$TEST" == "true" ]]; then
        log "${cmd_prefix[*]} mkvmerge --quiet --clusters-in-meta-seek -o $corrected_file $tmp_output ${mkv_attach_args[*]:-}"
        cp -f "$tmp_output" "$corrected_file" 2>/dev/null || true
    else
        local mm_exit=0
        timeout -k 1m 30m "${cmd_prefix[@]}" mkvmerge --quiet --clusters-in-meta-seek -o "$corrected_file" "$tmp_output" "${mkv_attach_args[@]}" >/dev/null 2>&1 || mm_exit=$?
        if (( mm_exit > 1 )); then
            handle_error "mkvmerge"
            return 1
        fi
    fi

    local new_size=$(stat -c%s "$corrected_file" 2>/dev/null || echo 0)
    local size_limit=$(( baseline_size * 105 / 100 ))

    if [[ "$encode_video" == "Y" && "$new_size" -gt "$size_limit" && "$baseline_size" -gt 0 ]]; then
        log "[Job $job_slot] ⚠️ Encoding inefficient (size > 105%). Reverting to original video."
        rm -f "$corrected_file"
        encode_video=N

        if [[ "$encode_audio" == "Y" ]]; then
            log "[Job $job_slot] ⚙️  Keeping video and re-encoding audio only..."
            timeout -k 1m "$ffmpeg_timeout" "${cmd_prefix[@]}" "$FFMPEG_CMD" $ffmpeg_prolog $input_params -i "$work_file" $vf_audio_params -map "0:$stream_idx" $map_audio $map_sub -c:v:0 copy $audio_params $subtitle_params $output_params -y "$tmp_output" 2>"$ffmpeg_log"
            local ff_exit=$?
            if (( ff_exit == 124 || ff_exit == 137 )); then
                log "[Job $job_slot] ⏱️ FFmpeg exceeded time limit ($ffmpeg_timeout), was terminated."
                handle_error "ffmpeg_fallback_timeout"
                return 1
            elif (( ff_exit != 0 )); then
                handle_error "ffmpeg_fallback"
                return 1
            fi
            
            if [[ "$TEST" == "true" ]]; then
                log "${cmd_prefix[*]} mkvmerge --quiet --clusters-in-meta-seek -o $corrected_file $tmp_output ${mkv_attach_args[*]:-}"
                cp -f "$tmp_output" "$corrected_file" 2>/dev/null || true
            else
                local mm_fallback_exit=0
                timeout -k 1m 30m "${cmd_prefix[@]}" mkvmerge --quiet --clusters-in-meta-seek -o "$corrected_file" "$tmp_output" "${mkv_attach_args[@]}" >/dev/null 2>&1 || mm_fallback_exit=$?
                if (( mm_fallback_exit > 1 )); then
                    handle_error "mkvmerge_fallback"
                    return 1
                fi
            fi
        else
            log "[Job $job_slot] ℹ️ Using original file (repackaged only)."
            cp -f "$work_file" "$corrected_file"
        fi
        
        if [[ ! -f "$corrected_file" ]]; then
             handle_error "fallback"
             return 1
        fi
        new_size=$(stat -c%s "$corrected_file" 2>/dev/null || echo 0)
    fi

    local savings=$(( 100 - (100 * new_size / (orig_size + 1)) ))
    log "[Job $job_slot] ⏭️  Processed, sending to output buffer: $rel_name"
    
    mkdir -p "$(dirname "$out_file")"
    mv -f "$corrected_file" "$out_file"

    (
        flock -x 200
        echo "$rel_name" >> "$STATE_FILE"
        echo "\"$rel_name\";$use_crf;$use_preset;$vcodec;$orig_acodecs;$encode_video;$encode_audio;${width}x${height};$((orig_size/1048576));$((new_size/1048576));$savings;$(((SECONDS-start_time)/60));OK;" >> "$STATS_FILE"
    ) 200>"$WORK_DIR/$LOCK"
    
    # Delete from IN buffer only after successful processing
    rm -f "$in_file"
    rm -rf "$tmp_dir"
    log "[Job $job_slot] ✅ Done $rel_name (Savings $savings %, processing time $(((SECONDS-start_time)/60)) minutes)"

}

# --------------------
# --- Main start ---
# --------------------

if ! command -v mkvmerge &> /dev/null; then
    log "❌ Error: mkvmerge is not installed. Install mkvtoolnix."
    exit 1
fi

if (( BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3) )); then
    echo "❌ Error: This script requires Bash 5.3 or newer (found ${BASH_VERSION})." >&2
    exit 1
fi

# numactl check is moved after NUMA node detection (lines below)

# Detect the number of logical processors on the largest NUMA node
lp_count=$(lscpu --extended 2>/dev/null | awk 'NR>1 && $2 ~ /^[0-9]+$/ {nodes[$2]++} END {max=0; for (n in nodes) if (nodes[n]>max) max=nodes[n]; print max}')
if [ -z "$lp_count" ] || [ "$lp_count" -eq 0 ]; then
    lp_count=$(nproc)
fi

nodes=(/sys/devices/system/node/node[0-9]*)
numa_count=${#nodes[@]}
[[ $numa_count -eq 0 ]] && numa_count=1
log "ℹ️  Detected NUMA nodes: $numa_count"
log "ℹ️  Detected logical processors/node: $lp_count"

if ! command -v numactl &> /dev/null && [[ $numa_count -gt 1 ]]; then
    log "❌ Error: Command 'numactl' not found. Install it."
    exit 1
fi

total_threads=$(nproc)
avail_ram_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
log "ℹ️  Total threads: $total_threads"
log "ℹ️  Available RAM for encoding: ${avail_ram_mb} MB"

MAX_JOBS=$numa_count
IN_BUFFER_SIZE=$((MAX_JOBS * 10))

while getopts ":hVtj:z:c:w:b:f:" opt; do
  case $opt in
    h) usage ;;
    V) echo "$(basename "$0") v${VERSION}"; exit 0 ;;
    t) TEST=true ;;
    j) MAX_JOBS="$OPTARG" ;;
    z) SOURCE_DIR="$OPTARG" ;;
    c) TARGET_DIR="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    b) IN_BUFFER_SIZE="$OPTARG" ;;
    f) FFMPEG_CMD="$OPTARG" ;;
    \?) printf "❌ Unknown option: -%s\\n" "$OPTARG" >&2; usage ;;
    :)  case $OPTARG in
        j|b) printf "⚠️  Error: Option -%s requires a number.\\n" "$OPTARG" >&2 ;;
        z|c|w|f) printf "⚠️  Error: Option -%s requires a path. Using default.\\n" "$OPTARG" >&2 ;;
        *) printf "❌ Error: Option -%s requires a value, but none was provided.\\n" "$OPTARG" >&2; usage ;;
      esac
  esac
done
shift $((OPTIND - 1))

# Derive ffprobe path from the same directory as ffmpeg
if [[ "$FFMPEG_CMD" == */* ]]; then
    FFPROBE_CMD="$(dirname "$FFMPEG_CMD")/ffprobe"
    if [[ ! -x "$FFPROBE_CMD" ]]; then
        FFPROBE_CMD="ffprobe"
    fi
else
    FFPROBE_CMD="ffprobe"
fi

SOURCE_DIR="${SOURCE_DIR%/}"
TARGET_DIR="${TARGET_DIR%/}"
WORK_DIR="${WORK_DIR%/}"

IN_DIR="$WORK_DIR/in"
OUT_DIR="$WORK_DIR/out"
ERR_DIR="$WORK_DIR/err"

STATE_FILE="$WORK_DIR/state.log"
STATS_FILE="$WORK_DIR/stats.csv"
ERROR_FILE="$WORK_DIR/errors.log"

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    log "⚠️  Warning: Job count (-j) must be a positive number. Using default: $numa_count"
    MAX_JOBS=$numa_count
fi
if ! [[ "$IN_BUFFER_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    IN_BUFFER_SIZE=$((MAX_JOBS * 5))
    log "⚠️  Warning: Buffer size (-b) must be a positive number. Using default: $IN_BUFFER_SIZE"
fi

log "ℹ️  Parallel jobs to be launched: $MAX_JOBS"

if [[ -z "$SOURCE_DIR" ]]; then
    log "❌ Error: Source directory not specified (-z)."
    exit 1
fi
if [[ -z "$TARGET_DIR" ]]; then
    log "❌ Error: Target directory not specified (-c)."
    exit 1
fi

# Check that work directory is not inside the source directory (prevent recursive processing of temp files)
src_real=$(realpath -m "$SOURCE_DIR" 2>/dev/null || echo "$SOURCE_DIR")
work_real=$(realpath -m "$WORK_DIR" 2>/dev/null || echo "$WORK_DIR")
if [[ "$work_real" == "$src_real" || "$work_real" == "$src_real/"* ]]; then
    log "❌ Error: Work directory ($WORK_DIR) must not be inside or equal to the source directory ($SOURCE_DIR)."
    exit 1
fi

# Ensure work directory exists before checks
mkdir -p "$WORK_DIR"

# Check that work directory is on a local block device (not a network/remote mount)
# More reliable than FS type blacklist: local disks always have source /dev/*, network mounts never do.
work_mount_src=""
work_fstype=""
if command -v findmnt &> /dev/null; then
    read -r work_mount_src work_fstype < <(findmnt -n -o SOURCE,FSTYPE --target "$WORK_DIR" 2>/dev/null | head -1)
else
    # Fallback to df if findmnt is not available
    read -r work_mount_src work_fstype < <(df -P -T "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $1, $2}')
fi
if [[ -n "$work_mount_src" ]]; then
    if [[ "$work_mount_src" != /dev/* ]]; then
        log "❌ Error: Work directory ($WORK_DIR) is not on a local block device."
        log "   Mount source: $work_mount_src (FS: ${work_fstype:-unknown})"
        log "   Lock file must be on a local disk. Network mount will cause critical slowdown and risk of data corruption."
        exit 1
    fi
    log "ℹ️  Work directory: device=$work_mount_src, FS=$work_fstype"
else
    log "⚠️  Cannot determine mount source for $WORK_DIR. Continuing with warning."
fi

# Initial free space check on the work disk
if disk_info=$(check_work_disk_space "$WORK_DIR"); then
    work_avail_kb=$(df -P -k "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    log "ℹ️  Free space on work disk: $(( work_avail_kb / 1024 )) MB ($(( work_avail_kb / 1048576 )) GB)"
else
    IFS=: read -r avail_mb pct_free <<< "$disk_info"
    log "❌ Error: Insufficient space on work disk ($WORK_DIR)."
    log "   Free: ${avail_mb} MB (${pct_free}%). Minimum: ${DISK_MIN_MB} MB or ${DISK_MIN_PCT}%."
    exit 1
fi

mkdir -p "$TARGET_DIR" "$IN_DIR" "$OUT_DIR" "$ERR_DIR"
[[ ! -f "$STATS_FILE" ]] && echo "file;crf;preset;codec;audio_codec;encode_video;encode_audio;resolution;orig_MB;new_MB;savings_%;duration_min;status;" > "$STATS_FILE"
touch "$STATE_FILE"
touch "$ERROR_FILE"

log "📂 Source directory: $SOURCE_DIR"
log "☯️  Work directory: $WORK_DIR"
log "♾️  Target directory: $TARGET_DIR"
log "ℹ️  Path to ffmpeg: $FFMPEG_CMD"
log "ℹ️  Path to ffprobe: $FFPROBE_CMD"
log "🛄 Input buffer size: $IN_BUFFER_SIZE"
log "🚀 Starting scan"

declare -A skip_files
if [[ -f "$STATE_FILE" ]]; then
    while read -r rel_name; do
        [[ -n "$rel_name" ]] && skip_files["$rel_name"]=1
    done < "$STATE_FILE"
fi
if [[ -f "$ERROR_FILE" ]]; then
    while IFS=';' read -r stage rel_name; do
        # Skip indented lines (FFmpeg log output) and empty lines
        [[ "$stage" =~ ^[[:space:]] ]] && continue
        rel_name="${rel_name## }"
        [[ -n "$rel_name" ]] && skip_files["$rel_name"]=1
    done < "$ERROR_FILE"
fi

files=("$SOURCE_DIR"/**/*.@(mkv|mp4|avi|mov|webm|mpg|mpeg|wmv|flv|vob|ts|m2ts|m4v|divx))
total_files=${#files[@]}
log "📂 Total found: $total_files files"

declare -a pending_files=()
declare -a in_buffer_files=()
declare -A known_out_files
declare -a out_buffer_files=()

for f in "${files[@]}"; do
    rel_name="${f#$SOURCE_DIR/}"
    if [[ -v skip_files["$rel_name"] ]]; then
        continue
    fi
    
    in_file="$IN_DIR/$rel_name"
    if [[ -f "$in_file" ]]; then
        src_size=$(stat -c%s "$f" 2>/dev/null || echo -1)
        in_size=$(stat -c%s "$in_file" 2>/dev/null || echo -1)
        if [[ $src_size -eq $in_size && $src_size -gt 0 ]]; then
            in_buffer_files+=("$rel_name")
            log "ℹ️ Complete in IN buffer: $rel_name"
        else
            pending_files+=("$rel_name")
            log "ℹ️ Incomplete in IN buffer (will be re-copied): $rel_name"
        fi
    else
        pending_files+=("$rel_name")
    fi
done

for f in "$OUT_DIR"/**/*.mkv; do
    [[ -f "$f" ]] || continue
    rel_name="${f#$OUT_DIR/}"
    out_buffer_files+=("$rel_name")
    known_out_files["$rel_name"]=1
    log "ℹ️ Ready in OUT buffer (awaiting delivery): $rel_name"
done

total_to_do=$((${#pending_files[@]} + ${#in_buffer_files[@]}))
processed_count=0
log "🚀 Starting orchestration ($MAX_JOBS slots, IN buffer: $IN_BUFFER_SIZE, to process: $total_to_do, RAM limit: ${avail_ram_mb} MB)"

declare -a pids
declare -a node_files
declare -a job_ram
for ((i=0; i<MAX_JOBS; i++)); do
    pids[$i]=""
    node_files[$i]=""
    job_ram[$i]=0
done

io_pid=""
io_task=""
copying_in_rel=""
copying_out_rel=""
cmd_copy=(nice -n 18 ionice -c 2 -n 6)

while true; do
    # 1. Check CPU tasks
    for node in "${!pids[@]}"; do
        if [[ -n "${pids[$node]}" ]]; then
            if ! kill -0 "${pids[$node]}" 2>/dev/null; then
                wait "${pids[$node]}" 2>/dev/null || true
                pids[$node]=""
                job_ram[$node]=0
                
                # Get the name of the finished file and add to out_buffer without scanning disk
                finished_file="${node_files[$node]}"
                if [[ -n "$finished_file" ]]; then
                    out_rel="${finished_file%.*}.mkv"
                    if [[ -f "$OUT_DIR/$out_rel" ]]; then
                        out_buffer_files+=("$out_rel")
                        known_out_files["$out_rel"]=1
                    fi
                    node_files[$node]=""
                fi
                
                ((processed_count++))
                log "📊 Progress: Processed $processed_count / $total_to_do (Remaining: $((total_to_do - processed_count)))"
            fi
        fi
    done

    # 2. Check IO task
    if [[ -n "$io_pid" ]]; then
        if ! kill -0 "$io_pid" 2>/dev/null; then
            wait "$io_pid" 2>/dev/null
            io_status=$?
            if [[ "$io_task" == "IN" ]]; then
                if [[ $io_status -eq 0 ]]; then
                    in_buffer_files+=("$copying_in_rel")
                    log "📥 File successfully copied to IN buffer: $copying_in_rel"
                else
                    log "⚠️ Download error: $copying_in_rel"
                    pending_files+=("$copying_in_rel")
                fi
                copying_in_rel=""
            elif [[ "$io_task" == "OUT" ]]; then
                if [[ $io_status -eq 0 ]]; then
                    rm -f "$OUT_DIR/$copying_out_rel"
                    unset known_out_files["$copying_out_rel"]
                    log "📤 File successfully copied to target: $copying_out_rel"
                else
                    log "⚠️ Upload error: $copying_out_rel"
                    out_buffer_files+=("$copying_out_rel")
                fi
                copying_out_rel=""
            fi
            io_pid=""
            io_task=""
        fi
    fi

    # 3. Check for new files in OUT_DIR (no longer needed, handled efficiently in step 1)

    # 4. Launch CPU tasks (with dynamic thread allocation and RAM check)
    #    Iterates through the entire buffer looking for a file that fits in RAM.
    #    Large files are skipped — they will be processed when nothing smaller remains.
    for ((node=0; node<MAX_JOBS; node++)); do
        [[ -n "${pids[$node]:-}" ]] && continue
        (( ${#in_buffer_files[@]} == 0 )) && break

        # How many jobs are currently running and how much RAM are they using?
        running_count=0; used_ram=0
        for n in "${!pids[@]}"; do
            [[ -n "${pids[$n]}" ]] && { ((running_count++)); (( used_ram += ${job_ram[$n]:-0} )); }
        done

        # Threads: if alone, gets maximum on NUMA node; otherwise NUMA split
        if (( running_count == 0 )); then
            threads_for_job=$lp_count
        else
            threads_for_job=$(( total_threads / MAX_JOBS ))
            (( threads_for_job > lp_count )) && threads_for_job=$lp_count
            (( threads_for_job < 1 )) && threads_for_job=1
        fi

        scheduled=false
        buf_len=${#in_buffer_files[@]}

        for ((fi=0; fi<buf_len; fi++)); do
            rel_to_process="${in_buffer_files[$fi]}"

            # Get resolution for RAM estimation
            file_h=$(get_file_height "$IN_DIR/$rel_to_process")
            file_h=${file_h%%[^0-9]*}
            file_h=${file_h:-1080}

            est_ram=$(estimate_job_ram_mb "$file_h" "$threads_for_job")

            if (( used_ram + est_ram <= avail_ram_mb )); then
                # Fits — remove from buffer and launch
                in_buffer_files=("${in_buffer_files[@]:0:$fi}" "${in_buffer_files[@]:$((fi+1))}")
                job_ram[$node]=$est_ram
                log "[Job $node] 🚀 Deploying (${threads_for_job} threads, ~${est_ram} MB RAM): ${rel_to_process##*/}"
                node_files[$node]="$rel_to_process"
                process_file "$rel_to_process" "$node" "$threads_for_job" &
                pids[$node]=$!
                scheduled=true
                break
            fi
        done

        if [[ "$scheduled" == "false" ]]; then
            # No file fits alongside running jobs
            if (( running_count > 0 )); then
                # Other jobs are running — wait for them to finish and free RAM
                log "[Job $node] ⏳ None of the ${buf_len} files fit in RAM (free ~$((avail_ram_mb - used_ram)) MB). Deferring large files..."
                break
            fi

            # Nothing running and nothing fits → try with fewer threads (less RAM)
            rel_to_process="${in_buffer_files[0]}"
            file_h=$(get_file_height "$IN_DIR/$rel_to_process")
            file_h=${file_h%%[^0-9]*}
            file_h=${file_h:-1080}

            # Reduce threads until estimate fits (minimum 4 threads)
            threads_for_job=$(( total_threads / MAX_JOBS ))
            (( threads_for_job > lp_count )) && threads_for_job=$lp_count
            (( threads_for_job < 4 )) && threads_for_job=4
            est_ram=$(estimate_job_ram_mb "$file_h" "$threads_for_job")

            if (( est_ram > avail_ram_mb )); then
                # Even with minimum threads it doesn't fit → estimate is conservative, launch with warning
                threads_for_job=8
                est_ram=$(estimate_job_ram_mb "$file_h" "$threads_for_job")
                log "[Job $node] ⚠️  RAM estimate (~${est_ram} MB) exceeds available memory (${avail_ram_mb} MB). Launching with ${threads_for_job} threads (estimates are conservative)."
            fi

            in_buffer_files=("${in_buffer_files[@]:1}")
            job_ram[$node]=$est_ram
            log "[Job $node] 🚀 Deploying (${threads_for_job} threads, ~${est_ram} MB RAM): ${rel_to_process##*/}"
            node_files[$node]="$rel_to_process"
            process_file "$rel_to_process" "$node" "$threads_for_job" &
            pids[$node]=$!
        fi
    done

    # 5. Launch IO task
    if [[ -z "$io_pid" ]]; then
        active_in_buffer=$((${#in_buffer_files[@]}))
        for node in "${!pids[@]}"; do
            [[ -n "${pids[$node]}" ]] && ((active_in_buffer++))
        done
        [[ -n "$copying_in_rel" ]] && ((active_in_buffer++))

        # Decide what to copy: when low on space, prioritize emptying the OUT queue
        disk_low=false
        if ! disk_info=$(check_work_disk_space "$WORK_DIR"); then
            disk_low=true
        fi

        if [[ "$disk_low" == "true" ]] && (( ${#out_buffer_files[@]} > 0 )); then
            # Low space → prioritize sending finished files off the work disk
            IFS=: read -r avail_mb pct_free <<< "$disk_info"
            copying_out_rel="${out_buffer_files[0]}"
            out_buffer_files=("${out_buffer_files[@]:1}")
            
            out_file="$OUT_DIR/$copying_out_rel"
            target_file="$TARGET_DIR/$copying_out_rel"
            mkdir -p "$(dirname "$target_file")"
            
            log "💾 Low space (${avail_mb} MB / ${pct_free}%) → priority delivery to target: $copying_out_rel"
            "${cmd_copy[@]}" rsync -a --no-p --no-o --no-g --inplace --info=progress2 -- "$out_file" "$target_file" &
            io_pid=$!
            io_task="OUT"
        elif [[ "$disk_low" == "false" ]] && (( active_in_buffer < IN_BUFFER_SIZE )) && (( ${#pending_files[@]} > 0 )); then
            copying_in_rel="${pending_files[0]}"
            pending_files=("${pending_files[@]:1}")
            
            src_file="$SOURCE_DIR/$copying_in_rel"
            in_file="$IN_DIR/$copying_in_rel"
            mkdir -p "$(dirname "$in_file")"
            
            log "⏳ Downloading to buffer (${active_in_buffer}/${IN_BUFFER_SIZE}): $copying_in_rel"
            "${cmd_copy[@]}" rsync -a --no-p --no-o --no-g --inplace --info=progress2 -- "$src_file" "$in_file" &
            io_pid=$!
            io_task="IN"
        elif (( ${#out_buffer_files[@]} > 0 )); then
            copying_out_rel="${out_buffer_files[0]}"
            out_buffer_files=("${out_buffer_files[@]:1}")
            
            out_file="$OUT_DIR/$copying_out_rel"
            target_file="$TARGET_DIR/$copying_out_rel"
            mkdir -p "$(dirname "$target_file")"
            
            log "⏭️ Sending to target: $copying_out_rel"
            "${cmd_copy[@]}" rsync -a --no-p --no-o --no-g --inplace --info=progress2 -- "$out_file" "$target_file" &
            io_pid=$!
            io_task="OUT"
        elif [[ "$disk_low" == "true" ]]; then
            IFS=: read -r avail_mb pct_free <<< "$disk_info"
            log "⏸️  Copying paused — low space (${avail_mb} MB / ${pct_free}%) and no OUT files to send. Waiting for space to free up..."
        fi
    fi

    # 6. Termination condition
    any_processing=false
    for node in "${!pids[@]}"; do
        [[ -n "${pids[$node]}" ]] && any_processing=true
    done

    if [[ ${#pending_files[@]} -eq 0 ]] && \
       [[ -z "$io_pid" ]] && \
       [[ ${#in_buffer_files[@]} -eq 0 ]] && \
       [[ "$any_processing" == "false" ]] && \
       [[ ${#out_buffer_files[@]} -eq 0 ]]; then
        break
    fi

    wait -n 2>/dev/null || true
done

wait
cleanup

printf -v runtime "%02d:%02d:%02d" $((SECONDS/3600)) $(((SECONDS%3600)/60)) $((SECONDS%60))
log "🎉  All done. ⏱️  Total runtime: $runtime"
