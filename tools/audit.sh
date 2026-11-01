#!/bin/bash
# Code audit builds, kept separate from build.sh. Everything goes to build/audit/.
#
#   tools/audit.sh static            clang static analyzer + extra-warnings pass over src/ and tools/
#   tools/audit.sh sanitize          build an ASan+UBSan atmostest; full segment dump of the two
#                                    reference files; leaks check (normal build) on the same files
#   tools/audit.sh fuzz [N]          corrupted/truncated copies of the reference files (N variants
#                                    per kind, default 4) run through the sanitizer build
#   tools/audit.sh library [dir]     sanitizer `check` over every video file in dir
#                                    (default /Volumes/Movies); read-only and silent
#
# Results: a summary on stdout; full logs under build/audit/<step>/.
# A file counts as CRASH if it died on a signal, hit an ASan/UBSan report or timed out;
# a clean FAIL from atmostest (unreadable file) is not a crash.
set -uo pipefail
cd "$(dirname "$0")/.."
BREW="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
FFI=(-isystem "$BREW/include")   # -isystem: no warnings from FFmpeg headers
FFL=(-L"$BREW/lib" -lavformat -lavcodec -lavutil -lswresample -lswscale -Wl,-rpath,"$BREW/lib")
CF=(-fobjc-arc -Wall -Wno-four-char-constants -Wno-deprecated-declarations)
SRC=(src/Segmenter.m src/HLSServer.m src/Subtitles.m)
ALL=(src/main.m "${SRC[@]}" tools/atmostest.m tools/capture.m tools/subtest.m tools/makeicon.m)
OUT=build/audit
ASAN_BIN=$OUT/atmostest-asan
REFS=("7.1.4_Atmos_Channel_Check_for_Academy_1sec_Black_2238fps_H265-15Mbps_DD+JOC-768Kbps.mp4"
      "Dolby Atmos TrueHD, E-AC-3 7.1.4.mkv")
TIMEOUT=900   # seconds per file

# Sanitizer settings: stop at the first report so it can't be missed, and use a distinct exit code.
export ASAN_OPTIONS="abort_on_error=0:halt_on_error=1:exitcode=99:detect_stack_use_after_return=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1:exitcode=99"

with_timeout() { perl -e '$t = shift; $SIG{ALRM} = sub { kill "KILL", $pid; exit 124 };
                          $pid = fork // die; if (!$pid) { exec @ARGV or exit 127 }
                          alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$TIMEOUT" "$@"; }

# Classify one run: prints OK / FAIL / CRASH(<why>) given exit code and its stderr log.
classify() {
    local rc=$1 log=$2
    if grep -q "ERROR: AddressSanitizer" "$log"; then echo "CRASH(asan)"
    elif grep -q "runtime error:" "$log"; then echo "CRASH(ubsan)"
    elif [ "$rc" -eq 124 ]; then echo "CRASH(timeout)"
    elif [ "$rc" -ge 128 ]; then echo "CRASH(signal $((rc - 128)))"
    elif [ "$rc" -eq 99 ]; then echo "CRASH(sanitizer)"
    elif [ "$rc" -eq 0 ]; then echo "OK"
    else echo "FAIL"; fi
}

build_asan() {
    mkdir -p $OUT
    if [ -x $ASAN_BIN ] && [ -z "$(find src tools/atmostest.m -newer $ASAN_BIN 2>/dev/null)" ]; then return; fi
    echo "building $ASAN_BIN"
    clang "${CF[@]}" -O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined \
        tools/atmostest.m "${SRC[@]}" "${FFI[@]}" "${FFL[@]}" \
        -framework AVFoundation -framework CoreMedia -framework AudioToolbox -framework CoreAudio \
        -framework CoreVideo -framework QuartzCore -framework Cocoa -o $ASAN_BIN || exit 1
}

# run_check <label> <logdir> <file>: sanitizer `check` on one file, prints one TSV line.
run_check() {
    local label=$1 dir=$2 f=$3 log t0 rc res line
    log="$dir/$(echo "$label" | tr '/ ' '__').log"
    t0=$(date +%s)
    line=$(with_timeout $ASAN_BIN check "$f" - 2>"$log"); rc=$?
    res=$(classify $rc "$log")
    printf '%s\t%s\t%ss\t%s\n' "$res" "$label" "$(( $(date +%s) - t0 ))" "$line"
    [ "$res" = OK ] || [ "$res" = FAIL ] && rm -f "$log"   # keep logs only for crashes
    return 0
}

step_static() {
    local d=$OUT/static; rm -rf $d; mkdir -p $d
    echo "== static analyzer"
    for f in "${ALL[@]}"; do
        clang --analyze "${CF[@]}" "${FFI[@]}" -Xanalyzer -analyzer-output=text \
            -Xanalyzer -analyzer-checker=core,unix,osx,nullability,deadcode,security \
            -Xanalyzer -analyzer-disable-checker=security.insecureAPI.DeprecatedOrUnsafeBufferHandling \
            "$f" -o /dev/null 2>>$d/analyzer.txt
    done
    grep -E "^[^ ].*: warning:" $d/analyzer.txt | sort -u > $d/analyzer-warnings.txt
    echo "$(wc -l < $d/analyzer-warnings.txt | tr -d ' ') analyzer findings  ($d/analyzer.txt has the paths)"
    sed 's/^/  /' $d/analyzer-warnings.txt

    echo "== extra warnings (-Wextra -Wshadow -Wconversion -Wformat=2 ...)"
    for f in "${ALL[@]}"; do
        clang -fsyntax-only "${CF[@]}" "${FFI[@]}" -Wextra -Wshadow -Wconversion -Wformat=2 \
            -Wnull-dereference -Wimplicit-fallthrough -Wunreachable-code -Wcast-qual \
            -Wno-unused-parameter "$f" 2>>$d/warnings.txt
    done
    grep -E "^[^ ].*: warning:" $d/warnings.txt | sort -u > $d/warnings-unique.txt
    echo "$(wc -l < $d/warnings-unique.txt | tr -d ' ') unique warnings  ($d/warnings-unique.txt); by flag:"
    grep -oE '\[-W[^],]+' $d/warnings-unique.txt | sort | uniq -c | sort -rn | sed 's/\[//; s/^/  /'
    echo "by file:"
    cut -d: -f1 $d/warnings-unique.txt | sort | uniq -c | sort -rn | sed 's/^/  /'
}

step_sanitize() {
    build_asan
    local d=$OUT/sanitize; rm -rf $d; mkdir -p $d
    for f in "${REFS[@]}"; do
        [ -f "$f" ] || { echo "missing reference file: $f"; continue; }
        echo "== ASan/UBSan dump of every segment: $f"
        local log="$d/$(echo "$f" | tr ' /' '__').dump.log" t0=$(date +%s)
        with_timeout $ASAN_BIN dump "$f" "$d/segs" 0 1000000 >/dev/null 2>"$log"; local rc=$?
        echo "  $(classify $rc "$log")  ($(( $(date +%s) - t0 ))s, $(ls "$d/segs" 2>/dev/null | wc -l | tr -d ' ') files written; log $log)"
        rm -rf "$d/segs"
        echo "== ASan/UBSan check: $f"
        echo "  $(run_check "$f" $d "$f")"
    done
    echo "== leaks (normal build): check mode on each reference file"
    [ -x build/atmostest ] || ./build.sh >/dev/null
    for f in "${REFS[@]}"; do
        [ -f "$f" ] || continue
        local log="$d/$(echo "$f" | tr ' /' '__').leaks.txt"
        MallocStackLogging=1 leaks --atExit -- build/atmostest check "$f" - >"$log" 2>&1
        echo "  $(grep -m1 -E 'leaks? for [0-9]+ total leaked bytes' "$log" || echo 'see log')  ($log)"
    done
}

# Corrupt copies: truncations, a damaged header region, scattered damage, missing head.
step_fuzz() {
    build_asan
    local n=${1:-4} d=$OUT/fuzz; rm -rf $d; mkdir -p $d/files $d/logs
    local cap=$((96 * 1024 * 1024))   # work on at most the first 96 MB of each reference file
    for ref in "${REFS[@]}"; do
        [ -f "$ref" ] || { echo "missing reference file: $ref"; continue; }
        local ext="${ref##*.}" tag base size
        tag=$(echo "$ref" | tr -cd 'A-Za-z0-9' | cut -c1-12)
        base=$d/files/$tag.base.$ext
        head -c $cap "$ref" > "$base"; size=$(stat -f %z "$base")
        for i in $(seq 1 "$n"); do
            RANDOM=$((i * 7919))
            head -c $(( size * (RANDOM % 95 + 3) / 100 )) "$base" > "$d/files/$tag.trunc$i.$ext"
            for kind in header scatter; do
                local f="$d/files/$tag.$kind$i.$ext" region hits k
                cp "$base" "$f"
                if [ $kind = header ]; then region=65536; hits=$((8 * i)); else region=$size; hits=$((200 * i)); fi
                for k in $(seq 1 $hits); do
                    local off=$(( (RANDOM * 32768 + RANDOM) % region ))
                    head -c 16 /dev/urandom | dd of="$f" bs=1 seek=$off conv=notrunc 2>/dev/null
                done
            done
            tail -c +$(( (RANDOM * 32768 + RANDOM) % 4096 + 2 )) "$base" > "$d/files/$tag.nohead$i.$ext"
        done
    done
    echo "== fuzz: $(ls $d/files | wc -l | tr -d ' ') files through the sanitizer build"
    for f in $d/files/*; do run_check "$(basename "$f")" $d/logs "$f"; done | tee $d/results.tsv |
        awk -F'\t' '{print "  " $1 "\t" $2 "\t" $3}'
    echo "summary: $(cut -f1 $d/results.tsv | sed 's/(.*//' | sort | uniq -c | tr '\n' ' ')"
    echo "crash logs: $d/logs/ (corrupted inputs kept in $d/files/)"
}

step_library() {
    build_asan
    local root=${1:-/Volumes/Movies} d=$OUT/library; rm -rf $d; mkdir -p $d/logs
    [ -d "$root" ] || { echo "not mounted: $root"; exit 1; }
    find "$root" -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.avi' \
        -o -iname '*.m2ts' -o -iname '*.ts' -o -iname '*.mov' -o -iname '*.webm' \) | sort > $d/files.txt
    echo "== library: $(wc -l < $d/files.txt | tr -d ' ') files under $root (sanitizer check, read-only)"
    while IFS= read -r f; do run_check "${f#$root/}" $d/logs "$f"; done < $d/files.txt > $d/results.tsv
    echo "summary: $(cut -f1 $d/results.tsv | sed 's/(.*//' | sort | uniq -c | tr '\n' ' ')"
    grep -v -E '^(OK|FAIL)	' $d/results.tsv | cut -f1-3 | sed 's/^/  /'
    grep -E '^FAIL	' $d/results.tsv | cut -f1-2 | sed 's/^/  /'
    echo "full results: $d/results.tsv; crash logs: $d/logs/"
}

case "${1:-}" in
    static)   step_static ;;
    sanitize) step_sanitize ;;
    fuzz)     step_fuzz "${2:-4}" ;;
    library)  step_library "${2:-}" ;;
    *) sed -n '2,15p' "$0"; exit 2 ;;
esac
