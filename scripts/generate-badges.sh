#!/bin/bash

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <test-results.xcresult> <output-directory>" >&2
  exit 1
fi

result_bundle="$1"
output_directory="$2"

version="$(git describe --tags --abbrev=0 --match 'v[0-9]*')"
coverage="$({ xcrun xccov view --report --only-targets "$result_bundle" 2>/dev/null || true; } \
  | awk '$2 == "a-bar.app" { sub(/%/, "", $4); printf "%.1f", $4; found = 1 } END { if (!found) exit 1 }')"

if [[ ! "$version" =~ ^v[0-9]+([.][0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]] \
  || [[ ! "$coverage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "Could not read a safe version or coverage value." >&2
  exit 1
fi

mkdir -p "$output_directory"

badge() {
  local label="$1"
  local value="$2"
  local color="$3"
  local file="$4"
  local label_width value_width width label_center value_center

  label_width=$(( ${#label} * 7 + 14 ))
  value_width=$(( ${#value} * 7 + 14 ))
  width=$(( label_width + value_width ))
  label_center=$(( label_width / 2 ))
  value_center=$(( label_width + value_width / 2 ))

  printf '%s\n' \
    "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"20\" role=\"img\" aria-label=\"$label: $value\">" \
    "  <title>$label: $value</title>" \
    "  <clipPath id=\"r\"><rect width=\"$width\" height=\"20\" rx=\"3\"/></clipPath>" \
    "  <g clip-path=\"url(#r)\">" \
    "    <rect width=\"$label_width\" height=\"20\" fill=\"#555\"/>" \
    "    <rect x=\"$label_width\" width=\"$value_width\" height=\"20\" fill=\"$color\"/>" \
    "  </g>" \
    "  <g fill=\"#fff\" text-anchor=\"middle\" font-family=\"Verdana,Geneva,DejaVu Sans,sans-serif\" font-size=\"11\">" \
    "    <text x=\"$label_center\" y=\"15\">$label</text>" \
    "    <text x=\"$value_center\" y=\"15\">$value</text>" \
    "  </g>" \
    "</svg>" > "$output_directory/$file"
}

coverage_color="$(awk -v coverage_value="$coverage" 'BEGIN {
  print (coverage_value >= 90 ? "#4c1" : coverage_value >= 80 ? "#97ca00" : coverage_value >= 70 ? "#a4a61d" : coverage_value >= 60 ? "#dfb317" : coverage_value >= 50 ? "#fe7d37" : "#e05d44")
}')"

badge "version" "$version" "#007ec6" "version.svg"
badge "coverage" "$coverage%" "$coverage_color" "coverage.svg"
