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

# Coverage of everything that is not a SwiftUI view body.
#
# SwiftUI inflates executable-line counts by roughly 4x - WidgetSettingsViews.swift is 1,256
# source lines and 4,769 executable ones - and views are about 72% of the app by that measure.
# The overall number is therefore dominated by code that is not unit-testable, and reports
# ~25% even when every testable line is covered. This second figure is the one that moves when
# the suite improves. Both are published; neither replaces the other.
logic_coverage="$({ xcrun xccov view --report --files-for-target a-bar.app --json "$result_bundle" 2>/dev/null || true; } \
  | python3 -c '
import json, sys

raw = sys.stdin.read()
if not raw.strip():
    sys.exit(1)
report = json.loads(raw)
files = report[0]["files"] if isinstance(report, list) else report["files"]

executable = covered = 0
for entry in files:
    path = entry["path"].split("/a-bar/a-bar/", 1)[-1]
    if path.startswith(("Views/", "Widgets/")) or path == "BarView.swift":
        continue
    executable += entry["executableLines"]
    covered += entry["coveredLines"]

if executable == 0:
    sys.exit(1)
print("%.1f" % (100.0 * covered / executable))
')"

if [[ ! "$version" =~ ^v[0-9]+([.][0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]] \
  || [[ ! "$coverage" =~ ^[0-9]+([.][0-9]+)?$ ]] \
  || [[ ! "$logic_coverage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
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

color_for() {
  awk -v coverage_value="$1" 'BEGIN {
    print (coverage_value >= 90 ? "#4c1" : coverage_value >= 80 ? "#97ca00" : coverage_value >= 70 ? "#a4a61d" : coverage_value >= 60 ? "#dfb317" : coverage_value >= 50 ? "#fe7d37" : "#e05d44")
  }'
}

badge "version" "$version" "#007ec6" "version.svg"
badge "coverage" "$coverage%" "$(color_for "$coverage")" "coverage.svg"
badge "logic coverage" "$logic_coverage%" "$(color_for "$logic_coverage")" "logic.svg"
