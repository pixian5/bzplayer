#!/bin/bash
set -u -o pipefail

usage() {
    cat <<'EOF'
用法：
  scripts/measure_audio_only.sh <媒体文件> [选项]

选项：
  --runs <次数>       每种模式重复次数，默认 1
  --duration <秒>     每次标记后的采样时长，默认 60
  --warmup <秒>       播放就绪后的稳定时间，默认 15
  --output <目录>     输出目录，默认 artifacts/audio-only-benchmark-<时间>
  --app <路径>        .app 路径，默认 /Applications/BZPlayer.app
  -h, --help          显示帮助

脚本会依次测试 normal 和 audio-only，并记录播放器 CPU、top、pmset、ioreg
以及可用时的 powermetrics。两种模式必须使用相同媒体、电源状态、屏幕亮度和
系统负载；结果只提供原始证据，不自动宣称节能。
EOF
}

MEDIA_PATH=""
RUNS=1
DURATION=60
WARMUP=15
OUTPUT_DIR=""
APP_DIR="/Applications/BZPlayer.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)
            RUNS="${2:-}"
            shift 2
            ;;
        --duration)
            DURATION="${2:-}"
            shift 2
            ;;
        --warmup)
            WARMUP="${2:-}"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --app)
            APP_DIR="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "未知选项：$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [[ -z "$MEDIA_PATH" ]]; then
                MEDIA_PATH="$1"
            else
                echo "只能指定一个媒体文件：$1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$MEDIA_PATH" || ! -f "$MEDIA_PATH" ]]; then
    echo "媒体文件不存在，或没有指定媒体文件。" >&2
    usage >&2
    exit 2
fi

if ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "--runs 必须是正整数。" >&2
    exit 2
fi

is_positive_number() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value > 0) }'
}

is_non_negative_number() {
    awk -v value="$1" 'BEGIN { exit !(value ~ /^[0-9]+([.][0-9]+)?$/ && value >= 0) }'
}

if ! is_positive_number "$DURATION"; then
    echo "--duration 必须是正数。" >&2
    exit 2
fi
if ! is_non_negative_number "$WARMUP"; then
    echo "--warmup 必须是非负数。" >&2
    exit 2
fi

MEDIA_PATH="$(cd -- "$(dirname -- "$MEDIA_PATH")" && pwd)/$(basename -- "$MEDIA_PATH")"
APP_BIN="${APP_DIR}/Contents/MacOS/BZPlayer"
if [[ ! -x "$APP_BIN" ]]; then
    echo "找不到可执行的 BZPlayer：$APP_BIN" >&2
    exit 2
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="artifacts/audio-only-benchmark-$(date '+%Y%m%d-%H%M%S')"
fi
mkdir -p "$OUTPUT_DIR"

{
    echo "created_at=$(date -Iseconds)"
    echo "media=$MEDIA_PATH"
    echo "app=$APP_DIR"
    echo "runs=$RUNS"
    echo "duration=$DURATION"
    echo "warmup=$WARMUP"
    echo "hostname=$(hostname)"
    sw_vers
    echo "--- hardware ---"
    sysctl -n hw.model 2>/dev/null || true
    sysctl -n hw.memsize 2>/dev/null || true
    echo "--- power policy ---"
    pmset -g custom 2>&1 || true
    echo "--- media ---"
    /opt/homebrew/bin/ffprobe -v error -show_entries format=duration,size -show_entries stream=codec_name,width,height,r_frame_rate -of default=noprint_wrappers=1 "$MEDIA_PATH" 2>&1 || true
} > "${OUTPUT_DIR}/environment.txt"

if sudo -n true 2>/dev/null; then
    POWERMETRICS_AVAILABLE=1
else
    POWERMETRICS_AVAILABLE=0
    echo "powermetrics=unavailable_without_passwordless_sudo" >> "${OUTPUT_DIR}/environment.txt"
fi

cleanup_processes() {
    local pid="${1:-}"
    local monitor_pid="${2:-}"
    local top_pid="${3:-}"
    local power_pid="${4:-}"
    local caffeinate_pid="${5:-}"

    if [[ -n "$monitor_pid" ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
    fi
    if [[ -n "$top_pid" ]]; then
        kill "$top_pid" 2>/dev/null || true
        wait "$top_pid" 2>/dev/null || true
    fi
    if [[ -n "$power_pid" ]]; then
        kill "$power_pid" 2>/dev/null || true
        wait "$power_pid" 2>/dev/null || true
    fi
    if [[ -n "$caffeinate_pid" ]]; then
        kill "$caffeinate_pid" 2>/dev/null || true
        wait "$caffeinate_pid" 2>/dev/null || true
    fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        sleep 1
        kill -9 "$pid" 2>/dev/null || true
    fi
}

run_case() {
    local mode="$1"
    local run_number="$2"
    local case_dir="${OUTPUT_DIR}/${mode}-run-${run_number}"
    local signal_file="${case_dir}/benchmark-start.signal"
    local pid=""
    local monitor_pid=""
    local top_pid=""
    local power_pid=""
    local caffeinate_pid=""
    local signal_message=""

    mkdir -p "$case_dir"
    rm -f "$signal_file"
    echo "[$mode run $run_number] starting"

    pkill -x BZPlayer 2>/dev/null || true
    sleep 1
    pkill -9 -x BZPlayer 2>/dev/null || true

    pmset -g batt > "${case_dir}/battery-before.txt" 2>&1 || true
    date -Iseconds > "${case_dir}/started.txt"

    if [[ "$POWERMETRICS_AVAILABLE" -eq 1 ]]; then
        sudo -n powermetrics \
            --sample-rate 5000 \
            --samplers cpu_power,gpu_power,battery \
            --show-process-energy \
            --show-usage-summary \
            > "${case_dir}/powermetrics.txt" 2>&1 &
        power_pid=$!
    else
        echo "powermetrics unavailable: passwordless sudo is not configured" > "${case_dir}/powermetrics.txt"
    fi

    open -na "$APP_DIR" --args \
        --benchmark-media "$MEDIA_PATH" \
        --benchmark-mode "$mode" \
        --benchmark-duration "$DURATION" \
        --benchmark-warmup "$WARMUP" \
        --benchmark-speed 1 \
        --benchmark-start-file "$signal_file" \
        > "${case_dir}/app-launch.txt" 2>&1

    for _ in $(seq 1 30); do
        pid="$(pgrep -n -x BZPlayer 2>/dev/null || true)"
        if [[ -n "$pid" ]]; then
            break
        fi
        sleep 1
    done
    if [[ -z "$pid" ]]; then
        echo "[$mode run $run_number] BZPlayer did not start" >&2
        cleanup_processes "" "" "" "$power_pid" ""
        return 1
    fi

    (
        while kill -0 "$pid" 2>/dev/null; do
            printf '\n[%s]\n' "$(date -Iseconds)"
            ps -p "$pid" -o pid=,ppid=,%cpu=,%mem=,rss=,etime=,state=,command= 2>&1 || true
            echo "--- pmset ---"
            pmset -g batt 2>&1 || true
            echo "--- ioreg battery fields ---"
            ioreg -r -n AppleSmartBattery -l -w 0 2>/dev/null | awk -F'= ' \
                '/^      "(CurrentCapacity|MaxCapacity|ExternalConnected|InstantAmperage|Amperage|Voltage|Temperature|SystemPowerIn|BatteryPower)"/ {
                    gsub(/^[[:space:]]+/, "", $1); print $1 "=" $2
                }' || true
            sleep 5
        done
    ) > "${case_dir}/process-and-battery.log" 2>&1 &
    monitor_pid=$!

    top -l 0 -s 5 -pid "$pid" -stats pid,command,cpu,rprvt,time,threads \
        > "${case_dir}/top.txt" 2>&1 &
    top_pid=$!

    caffeinate -dimsu -w "$pid" > "${case_dir}/caffeinate.txt" 2>&1 &
    caffeinate_pid=$!

    for _ in $(seq 1 90); do
        if [[ -f "$signal_file" ]]; then
            signal_message="$(tr '\n' ' ' < "$signal_file")"
            break
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    if [[ -z "$signal_message" ]]; then
        echo "[$mode run $run_number] benchmark did not reach the measurement window" >&2
        cleanup_processes "$pid" "$monitor_pid" "$top_pid" "$power_pid" "$caffeinate_pid"
        return 1
    fi

    echo "$signal_message" > "${case_dir}/measurement-window.txt"
    echo "[$mode run $run_number] $signal_message"

    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
    done

    pmset -g batt > "${case_dir}/battery-after.txt" 2>&1 || true
    date -Iseconds > "${case_dir}/finished.txt"
    cleanup_processes "$pid" "$monitor_pid" "$top_pid" "$power_pid" "$caffeinate_pid"
    echo "[$mode run $run_number] finished: $case_dir"
}

for mode in normal audio-only; do
    for run_number in $(seq 1 "$RUNS"); do
        if ! run_case "$mode" "$run_number"; then
            echo "测试失败：${mode} run ${run_number}" >&2
            exit 1
        fi
    done
done

cat > "${OUTPUT_DIR}/README.txt" <<EOF
BZPlayer 音频模式 A/B 原始测量

媒体：${MEDIA_PATH}
模式：normal / audio-only
重复：${RUNS}
稳定时间：${WARMUP} 秒
标记后的采样时间：${DURATION} 秒

每个 run 目录包含播放器进程采样、top、pmset、ioreg 和可用时的 powermetrics。
请只比较相同电源、亮度、外接显示器、网络和后台负载下的对应 run；短媒体或过短
采样只能验证流程，不能作为功耗结论。
EOF

echo "原始测量完成：${OUTPUT_DIR}"
