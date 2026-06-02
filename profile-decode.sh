#!/usr/bin/env bash

# sudo ./profile-decode.sh <old-ffmpeg> <new-ffmpeg> <input-dir> [repeats] [core]

set -u

export LC_ALL=C


usage() {
    echo "Использование: sudo $0 <old-ffmpeg> <new-ffmpeg> <input-dir> [repeats] [core]" >&2
    exit 1
}

[[ $# -ge 3 && $# -le 5 ]] || usage

OLD_FF=$1
NEW_FF=$2
INPUT_DIR=$3
REPEATS=${4:-10}
CORE=${5:-}

EVENTS="cycles,instructions,task-clock,context-switches,cpu-migrations"
WARMUPS=1


if [[ $EUID -ne 0 ]]; then
    echo "Ошибка: скрипт нужно запускать от root (sudo $0 ...)." >&2
    exit 1
fi

for bin in "$OLD_FF" "$NEW_FF"; do
    if [[ ! -x "$bin" ]]; then
        echo "Ошибка: ffmpeg '$bin' не существует или не исполняем." >&2
        exit 1
    fi
done

for tool in perf taskset nice gawk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Ошибка: не найден '$tool'." >&2
        exit 1
    fi
done

if ! [[ $REPEATS =~ ^[0-9]+$ ]] || (( REPEATS < 1 )); then
    echo "Ошибка: repeats должно быть целым числом >= 1." >&2
    exit 1
fi

if [[ -d "$INPUT_DIR/x265-compare/old" && -d "$INPUT_DIR/x265-compare/new" ]]; then
    BASE="$INPUT_DIR/x265-compare"
elif [[ -d "$INPUT_DIR/old" && -d "$INPUT_DIR/new" ]]; then
    BASE="$INPUT_DIR"
else
    echo "Ошибка: в '$INPUT_DIR' не найдена структура old/ + new/ от compare-x265.sh." >&2
    exit 1
fi

if ! perf stat -e cycles -- true >/dev/null 2>&1; then
    echo "Ошибка: 'perf stat -e cycles' не работает (нет доступа к PMU / в виртуалке?)." >&2
    exit 1
fi

if [[ -z "$CORE" ]]; then
    CORE=$(ls -d /sys/devices/system/cpu/cpu[0-9]* \
           | sed 's#.*/cpu##' | sort -n | tail -1)
fi

if [[ ! -d "/sys/devices/system/cpu/cpu$CORE" ]]; then
    echo "Ошибка: ядро $CORE не существует." >&2
    exit 1
fi

SIBLING=""
sib_file="/sys/devices/system/cpu/cpu$CORE/topology/thread_siblings_list"
if [[ -r "$sib_file" ]]; then
    for s in $(tr ',' ' ' < "$sib_file"); do
        if [[ "$s" != "$CORE" && "$s" != "0" ]]; then
            SIBLING=$s
            break
        fi
    done
fi


RESTORE=()
add_restore() { RESTORE+=("$1"); }

restore_env() {
    echo
    echo "Восстановление окружения..."
    for (( i=${#RESTORE[@]}-1; i>=0; i-- )); do
        eval "${RESTORE[i]}" 2>/dev/null || true
    done
}
trap restore_env EXIT

set_with_restore() {
    local file=$1 new=$2 old
    [[ -w "$file" ]] || { echo "  пропуск (нет доступа): $file" >&2; return; }
    old=$(cat "$file" 2>/dev/null) || return
    add_restore "echo '$old' > '$file'"
    echo "$new" > "$file" 2>/dev/null || echo "  не удалось записать: $file" >&2
}

echo "Настройка окружения для профилирования..."

if [[ -n "$SIBLING" && -w "/sys/devices/system/cpu/cpu$SIBLING/online" ]]; then
    echo "  отключаю HT-соседа: cpu$SIBLING"
    set_with_restore "/sys/devices/system/cpu/cpu$SIBLING/online" 0
else
    echo "  HT-сосед не отключается (нет SMT или это cpu0)"
fi

if [[ -e /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo "  отключаю turbo (intel_pstate/no_turbo)"
    set_with_restore /sys/devices/system/cpu/intel_pstate/no_turbo 1
elif [[ -e /sys/devices/system/cpu/cpufreq/boost ]]; then
    echo "  отключаю turbo (cpufreq/boost)"
    set_with_restore /sys/devices/system/cpu/cpufreq/boost 0
else
    echo "  управление turbo не найдено"
fi

gov="/sys/devices/system/cpu/cpu$CORE/cpufreq/scaling_governor"
minf="/sys/devices/system/cpu/cpu$CORE/cpufreq/scaling_min_freq"
maxf="/sys/devices/system/cpu/cpu$CORE/cpufreq/scaling_max_freq"
if [[ -e "$gov" ]]; then
    echo "  governor -> performance (cpu$CORE)"
    set_with_restore "$gov" performance
fi
if [[ -e "$minf" && -e "$maxf" ]]; then
    cur_max=$(cat "$maxf")
    echo "  фиксирую частоту cpu$CORE на $cur_max kHz"
    set_with_restore "$minf" "$cur_max"
fi

[[ -e /proc/sys/kernel/nmi_watchdog ]] && \
    { echo "  отключаю nmi_watchdog"; set_with_restore /proc/sys/kernel/nmi_watchdog 0; }

[[ -e /proc/sys/kernel/randomize_va_space ]] && \
    { echo "  отключаю ASLR"; set_with_restore /proc/sys/kernel/randomize_va_space 0; }

[[ -e /proc/sys/kernel/perf_event_paranoid ]] && \
    set_with_restore /proc/sys/kernel/perf_event_paranoid -1

echo "  sync + drop_caches"
sync
[[ -w /proc/sys/vm/drop_caches ]] && echo 3 > /proc/sys/vm/drop_caches

echo "Окружение настроено. Целевое ядро: $CORE"
echo

# === подготовка вывода =======================================================

OUTDIR="$INPUT_DIR/profile-results"
mkdir -p "$OUTDIR"
RAW="$OUTDIR/raw.csv"
SUMMARY="$OUTDIR/summary.csv"
META="$OUTDIR/meta.txt"
STATFILE=$(mktemp)
ERRFILE=$(mktemp)
add_restore "rm -f '$STATFILE' '$ERRFILE'"

echo "set,qp,file,run,cycles,instructions,task_clock_ms,context_switches,cpu_migrations" > "$RAW"

{
    echo "Профилирование декодирования HEVC"
    echo "Дата:        $(date -Is)"
    echo "Хост:        $(hostname)"
    echo "CPU:         $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
    echo "Ядро:        $CORE (HT-сосед $SIBLING отключён)"
    [[ -e "$maxf" ]] && echo "Частота:     $(cat "$maxf") kHz (зафиксирована)"
    echo "old-ffmpeg:  $OLD_FF"
    echo "new-ffmpeg:  $NEW_FF"
    echo "Битстримы:   $BASE"
    echo "Повторов:    $REPEATS (+ $WARMUPS прогрев)"
    echo "perf события: $EVENTS"
} > "$META"

get_metric() {
    gawk -F, -v ev="$2" 'index($3,ev)==1 { print $1; exit }' "$1"
}

FFMPEG_ARGS=(-nostdin -nostats -v error -y -threads 1 -f hevc)
FFMPEG_OUT=(-c:v rawvideo -f rawvideo /dev/null)

ok=0
fail=0

profile_set() {
    local ff=$1 setname=$2
    local setdir="$BASE/$setname"

    [[ -d "$setdir" ]] || { echo "Пропуск: нет папки $setdir" >&2; return; }

    local qpdir qp f name r rc cyc ins tc ctx mig
    for qpdir in "$setdir"/qp*/; do
        [[ -d "$qpdir" ]] || continue
        qp=$(basename "$qpdir"); qp=${qp#qp}

        shopt -s nullglob
        for f in "$qpdir"*.265; do
            name=$(basename "$f")
            echo "[$setname qp$qp] $name"

            for (( r=1; r<=WARMUPS; r++ )); do
                taskset -c "$CORE" "$ff" "${FFMPEG_ARGS[@]}" \
                    -i "$f" "${FFMPEG_OUT[@]}" >/dev/null 2>&1 || true
            done

            for (( r=1; r<=REPEATS; r++ )); do
                perf stat -x, -o "$STATFILE" -e "$EVENTS" -- \
                    taskset -c "$CORE" nice -n -20 \
                    "$ff" "${FFMPEG_ARGS[@]}" -i "$f" "${FFMPEG_OUT[@]}" \
                    2>"$ERRFILE"
                rc=$?

                if [[ $rc -ne 0 ]]; then
                    fail=$((fail + 1))
                    echo "  [ОШИБКА] прогон $r (rc=$rc): $(tail -1 "$ERRFILE")" >&2
                    continue
                fi

                cyc=$(get_metric "$STATFILE" cycles)
                ins=$(get_metric "$STATFILE" instructions)
                tc=$(get_metric "$STATFILE" task-clock)
                ctx=$(get_metric "$STATFILE" context-switches)
                mig=$(get_metric "$STATFILE" cpu-migrations)

                if ! [[ $cyc =~ ^[0-9]+$ ]]; then
                    fail=$((fail + 1))
                    echo "  [ОШИБКА] прогон $r: счётчик cycles не получен ('$cyc')" >&2
                    continue
                fi

                echo "$setname,$qp,$name,$r,$cyc,$ins,$tc,$ctx,$mig" >> "$RAW"
                ok=$((ok + 1))
            done
        done
        shopt -u nullglob
    done
}

echo "=== Профилирование old (бинарь: $OLD_FF) ==="
profile_set "$OLD_FF" old
echo
echo "=== Профилирование new (бинарь: $NEW_FF) ==="
profile_set "$NEW_FF" new

echo
echo "Считаю сводку..."

gawk -F, '
BEGIN {
    # t-критическое (двустороннее 95%) для df = 1..30
    split("12.706 4.303 3.182 2.776 2.571 2.447 2.365 2.306 2.262 2.228 \
           2.201 2.179 2.160 2.145 2.131 2.120 2.110 2.101 2.093 2.086 \
           2.080 2.074 2.069 2.064 2.060 2.056 2.052 2.048 2.045 2.042", T, " ")
    print "set,qp,file,runs,cyc_min,cyc_median,cyc_mean,cyc_std,cyc_ci95,cyc_ci95_pct,ipc_mean"
}
NR > 1 {
    k = $1 "," $2 "," $3
    n[k]++
    cyc[k] = cyc[k] " " $5
    csum[k] += $5
    isum[k] += $6
}
END {
    for (k in n) {
        N = n[k]
        m = split(cyc[k], a, " ")
        for (i = 1; i <= N; i++) a[i] = a[i] + 0
        # сортировка вставками для медианы/минимума
        for (i = 2; i <= N; i++) {
            v = a[i]; j = i - 1
            while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- }
            a[j+1] = v
        }
        mean = csum[k] / N
        ss = 0
        for (i = 1; i <= N; i++) { d = a[i] - mean; ss += d * d }
        std = (N > 1) ? sqrt(ss / (N - 1)) : 0
        med = (N % 2) ? a[(N+1)/2] : (a[N/2] + a[N/2+1]) / 2
        df = N - 1
        tv = (df >= 1 && df <= 30) ? T[df] : 1.96
        ci = (N > 1) ? tv * std / sqrt(N) : 0
        cipct = (mean > 0) ? ci / mean * 100 : 0
        ipc = (csum[k] > 0) ? isum[k] / csum[k] : 0
        printf "%s,%d,%d,%.0f,%.0f,%.1f,%.1f,%.3f,%.4f\n", \
               k, N, a[1], med, mean, std, ci, cipct, ipc
    }
}
' "$RAW" | sort -t, -k1,1 -k2,2n -k3,3 > "$SUMMARY"

echo
echo "Готово. Замеров успешно: $ok, с ошибкой: $fail"
echo "  raw:     $RAW"
echo "  summary: $SUMMARY"
echo "  meta:    $META"
