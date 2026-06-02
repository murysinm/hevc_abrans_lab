#!/usr/bin/env bash

# ./compare-x265.sh <old-bin> <new-bin> <input-dir> "<params>" "<qp-list>"

set -u


if [[ $# -ne 5 ]]; then
    echo "Использование: $0 <old-bin> <new-bin> <input-dir> \"<params>\" \"<qp-list>\"" >&2
    exit 1
fi

OLD_BIN=$1
NEW_BIN=$2
INPUT_DIR=$3
PARAMS=$4
QP_LIST=$5


for bin in "$OLD_BIN" "$NEW_BIN"; do
    if [[ ! -x "$bin" ]]; then
        echo "Ошибка: '$bin' не существует или не является исполняемым." >&2
        exit 1
    fi
done

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "Ошибка: папка '$INPUT_DIR' не найдена." >&2
    exit 1
fi

read -r -a QP_ARR <<< "${QP_LIST//,/ }"

if [[ ${#QP_ARR[@]} -eq 0 ]]; then
    echo "Ошибка: пустой список QP." >&2
    exit 1
fi

for qp in "${QP_ARR[@]}"; do
    if ! [[ $qp =~ ^[0-9]+$ ]] || (( qp < 0 || qp > 51 )); then
        echo "Ошибка: некорректное значение QP '$qp' (ожидается число 0..51)." >&2
        exit 1
    fi
done


shopt -s nullglob
INPUT_FILES=("$INPUT_DIR"/*.y4m)
shopt -u nullglob

if [[ ${#INPUT_FILES[@]} -eq 0 ]]; then
    echo "Ошибка: в '$INPUT_DIR' нет .y4m файлов." >&2
    exit 1
fi

read -r -a PARAM_ARR <<< "$PARAMS"

ok=0
fail=0

run_encoder() {
    local bin=$1 outdir=$2 infile=$3 qp=$4
    local name out_265 out_log
    name=$(basename "$infile" .y4m)
    out_265="$outdir/$name.265"
    out_log="$outdir/$name.log"

    if "$bin" --input "$infile" "${PARAM_ARR[@]}" --qp "$qp" \
            --output "$out_265" > "$out_log" 2>&1; then
        ok=$((ok + 1))
    else
        fail=$((fail + 1))
        echo "  [ОШИБКА] $bin -> $name (подробности в $out_log)" >&2
    fi
}

echo "Файлов на вход: ${#INPUT_FILES[@]}"
echo "Значения QP: ${QP_ARR[*]}"
echo "Параметры: $PARAMS"
echo

for qp in "${QP_ARR[@]}"; do
    out_old="$INPUT_DIR/x265-compare/old/qp$qp"
    out_new="$INPUT_DIR/x265-compare/new/qp$qp"
    mkdir -p "$out_old" "$out_new"

    echo "########## QP $qp ##########"
    for infile in "${INPUT_FILES[@]}"; do
        echo "=== $(basename "$infile") (QP $qp) ==="
        echo "  старый кодер..."
        run_encoder "$OLD_BIN" "$out_old" "$infile" "$qp"
        echo "  новый кодер..."
        run_encoder "$NEW_BIN" "$out_new" "$infile" "$qp"
    done
    echo
done

# --- сводка ------------------------------------------------------------------

echo "Готово. Успешно: $ok, с ошибкой: $fail"
echo "Результаты: $INPUT_DIR/x265-compare/{old,new}/qp<N>/"

[[ $fail -eq 0 ]]
