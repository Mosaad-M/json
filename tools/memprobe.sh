#!/bin/sh
# Memory used by parsing, relative to input size (report-only).
# Reported: peak RSS of parse run minus a baseline run that builds the same
# input but does not parse, divided by the input size.
set -e
cd "$(dirname "$0")/.."
mkdir -p .cache
mojo build -O3 -I . tools/memprobe.mojo -o .cache/memprobe
rss() {
  if /usr/bin/time -l true >/dev/null 2>&1; then
    /usr/bin/time -l "$@" 2>.cache/memprobe.time >.cache/memprobe.out
    awk '/maximum resident set size/ {print $1}' .cache/memprobe.time
  else
    /usr/bin/time -v "$@" 2>.cache/memprobe.time >.cache/memprobe.out
    awk '/Maximum resident set size/ {print $6 * 1024}' .cache/memprobe.time
  fi
}
for shape in zeros empty_arrays empty_objects mixed; do
  base=$(rss .cache/memprobe "$shape" baseline)
  peak=$(rss .cache/memprobe "$shape")
  bytes=$(awk '{print $2}' .cache/memprobe.out)
  awk -v s="$shape" -v b="$bytes" -v p="$peak" -v z="$base" 'BEGIN {
    printf "%-14s input %5.1f MB  parse adds %6.1f MB  (%.1fx input)\n", s, b/1e6, (p-z)/1e6, (p-z)/b }'
done
