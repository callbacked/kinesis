#!/bin/bash
# Replays arm movement through the air cursor, one display frame at a time, and
# measures how the pointer moves. A developer tool: it lives in the tests and never
# ships in the app.
#
#   scripts/pointer-lab.sh scenarios
#   scripts/pointer-lab.sh motion.jsonl --refresh 60,100,vrr --pacing 0,0.016 --window 30-90
#
# A motion log comes from: open -n --env KINESIS_MOTION_LOG=/path/motion.jsonl dist/Kinesis.app
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -lt 1 ]; then
    sed -n 2,9p "$0" | sed 's/^# \{0,1\}//'
    exit 1
fi
input=$1
shift
if [ "$input" != scenarios ]; then input=$(cd "$(dirname "$input")" && pwd)/$(basename "$input"); fi
export KINESIS_LAB_INPUT=$input
while [ $# -gt 0 ]; do
    case $1 in
        --refresh) export KINESIS_LAB_REFRESH=$2; shift 2;;
        --pacing) export KINESIS_LAB_PACING=$2; shift 2;;
        --display) export KINESIS_LAB_DISPLAY=$2; shift 2;;
        --window) export KINESIS_LAB_WINDOW=$2; shift 2;;
        --out) export KINESIS_LAB_OUT=$2; shift 2;;
        *) printf 'unknown option %s\n' "$1" >&2; exit 1;;
    esac
done
swift test --filter pointerLab 2>&1 | grep -vE '^(\[|Building|Build complete|Compiling|Write|Planning|Test Suite|Test Case|Executed|◇|↳)' | grep -vE '^􀟈|^✔ Test run|^􁁛' || true
