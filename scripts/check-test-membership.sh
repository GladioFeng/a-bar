#!/bin/bash
#
# A test file that is on disk but missing from the test target's Sources phase
# compiles nowhere and runs nothing - and the suite still reports success. This
# catches that, because nothing else does.
#
# The test target has no TEST_HOST: it recompiles a whitelist of production
# sources directly into the bundle, so membership is manual and easy to forget.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="a-bar.xcodeproj/project.pbxproj"
TESTS_DIR="a-barTests"
PHASE="S1000002"

# The filenames listed in the test target's Sources build phase.
members="$(
  awk "/${PHASE} \/\* Sources \*\/ = \{/,/};/" "$PROJECT" \
    | sed -n 's/.*\/\* \(.*\) in Sources \*\/.*/\1/p' \
    | sort -u
)"

missing=0
for path in "$TESTS_DIR"/*.swift; do
  name="$(basename "$path")"
  if ! printf '%s\n' "$members" | grep -qx "$name"; then
    echo "error: $path is not a member of the a-barTests target."
    echo "       Add it to the ${PHASE} Sources phase in $PROJECT, or it will never run."
    missing=1
  fi
done

# A build-file entry pointing at a test file that no longer exists fails the
# build, but with a message that does not mention the test target.
while IFS= read -r name; do
  case "$name" in
    *Tests.swift | *Fixtures.swift)
      if [ ! -f "$TESTS_DIR/$name" ]; then
        echo "error: ${PHASE} references $name, which is not in $TESTS_DIR/."
        missing=1
      fi
      ;;
  esac
done <<< "$members"

if [ "$missing" -ne 0 ]; then
  exit 1
fi

count="$(printf '%s\n' "$TESTS_DIR"/*.swift | wc -l | tr -d ' ')"
echo "All $count file(s) in $TESTS_DIR/ are members of the a-barTests target."
