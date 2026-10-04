#!/bin/sh
# Every case runs against a real daukle, because what this plugin produces is a
# resolved closure and a stub of daukle.fetch would be testing the stub.
#
# The cases that reach Maven Central carry a "needs-central" marker and are
# skipped unless DAUKLE_MAVEN_E2E=1. CI sets it on every runner: resolution is
# the whole of what this plugin does, so a run that skipped them proved only
# that bad input is refused.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work="$root/test/.work"

daukle=${DAUKLE:-}
if [ -z "$daukle" ]; then
  for candidate in \
    "$root/.daukle/build/daukle" \
    "$root/.daukle/build/daukle.exe" \
    "$root/.daukle/build/Release/daukle.exe" \
    "$root/.daukle/build/Debug/daukle.exe"
  do
    [ -x "$candidate" ] && daukle=$candidate && break
  done
fi
if [ -z "$daukle" ] || [ ! -x "$daukle" ]; then
  echo "no daukle binary: set DAUKLE, or check out daukle/daukle into .daukle and build it" >&2
  exit 1
fi

passed=0
failed=0
skipped=0

fail() {
  echo "FAIL $1: $2" >&2
  failed=$((failed + 1))
}

run_case() {
  case_dir=$1
  name=$(basename "$case_dir")

  if [ -f "$case_dir/needs-central" ] && [ "${DAUKLE_MAVEN_E2E:-}" != "1" ]; then
    echo "skip $name: set DAUKLE_MAVEN_E2E=1 to run it here" >&2
    skipped=$((skipped + 1))
    return
  fi

  sandbox="$work/$name"
  rm -rf "$sandbox"
  mkdir -p "$(dirname "$sandbox")"
  cp -R "$case_dir" "$sandbox"
  rm -rf "$sandbox/expected" "$sandbox/expect-error.txt" "$sandbox/needs-central"
  mkdir -p "$sandbox/plugins"
  cp "$root/plugin.lua" "$sandbox/plugins/plugin.lua"
  cp -R "$root/lib" "$sandbox/plugins/lib"

  task=maven:list
  [ -f "$case_dir/task" ] && task=$(cat "$case_dir/task")
  # Unquoted on purpose: a task line may carry flags, and maven:resolve needs
  # --resolve to be allowed to fetch anything unpinned at all.
  # shellcheck disable=SC2086
  set -- $task

  if [ -f "$case_dir/expect-error.txt" ]; then
    if (cd "$sandbox" && "$daukle" "$@" >stdout.txt 2>stderr.txt); then
      fail "$name" "expected a failure, got success"
      return
    fi
    clause=$(cat "$case_dir/expect-error.txt")
    if ! grep -qF "$clause" "$sandbox/stderr.txt" "$sandbox/stdout.txt"; then
      echo "--- stderr ---" >&2
      cat "$sandbox/stderr.txt" >&2
      fail "$name" "message does not carry: $clause"
      return
    fi
    passed=$((passed + 1))
    return
  fi

  if ! (cd "$sandbox" && "$daukle" "$@" >stdout.txt 2>stderr.txt); then
    echo "--- stderr ---" >&2
    cat "$sandbox/stderr.txt" >&2
    fail "$name" "$task failed"
    return
  fi

  # A case asserts on the generated classpath when it ships one, and on the
  # resolved module list otherwise.
  # resolved.txt is derived and lives under build/; classpath.lua is committed
  # and lives in daukle/, which is the whole point of the two directories.
  wanted_name=resolved.txt
  produced="$sandbox/build/daukle/maven/resolved.txt"
  if [ -f "$case_dir/expected/classpath.lua" ]; then
    wanted_name=classpath.lua
    produced="$sandbox/daukle/maven/classpath.lua"
  fi
  if [ ! -f "$produced" ]; then
    fail "$name" "no $wanted_name was written"
    return
  fi

  # The comment lines carry counts that move when Central publishes a new
  # parent POM, so the assertion is the content, which does not.
  grep -vE '^(#|--)' "$produced" | grep -v '^[[:space:]]*$' | sort > "$sandbox/actual.txt"
  grep -vE '^(#|--)' "$case_dir/expected/$wanted_name" | grep -v '^[[:space:]]*$' | sort \
    > "$sandbox/wanted.txt"

  if ! diff -u "$sandbox/wanted.txt" "$sandbox/actual.txt" >"$sandbox/diff.txt" 2>&1; then
    echo "--- $name ---" >&2
    cat "$sandbox/diff.txt" >&2
    fail "$name" "the generated $wanted_name differs"
    return
  fi
  passed=$((passed + 1))
}

rm -rf "$work"
for case_dir in "$root"/test/cases/*/; do
  [ -d "$case_dir" ] || continue
  run_case "${case_dir%/}"
done

echo "$passed passed, $failed failed, $skipped skipped"
[ "$failed" -eq 0 ]
