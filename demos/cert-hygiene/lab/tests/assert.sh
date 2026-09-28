#!/usr/bin/env bash
# Minimal assertions for the lab's bash unit tests. Source; do not execute.
FAILS=0
assert_eq() { # actual expected message
  [ "$1" = "$2" ] || { printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$2" "$1"; FAILS=$((FAILS + 1)); }
}
assert_contains() { # haystack needle message
  case "$1" in *"$2"*) ;; *) printf 'FAIL: %s\n  [%s] not found in:\n%s\n' "$3" "$2" "$1"; FAILS=$((FAILS + 1)) ;; esac
}
assert_succeeds() { # message command...
  local msg="$1"; shift
  ( "$@" ) >/dev/null 2>&1 || { printf 'FAIL: %s (expected success: %s)\n' "$msg" "$*"; FAILS=$((FAILS + 1)); }
}
assert_fails() { # message command...
  local msg="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then printf 'FAIL: %s (expected failure: %s)\n' "$msg" "$*"; FAILS=$((FAILS + 1)); fi
}
finish() { # suite-name
  if [ "$FAILS" -eq 0 ]; then echo "PASS: $1"; else echo "FAILED: $1 ($FAILS failures)"; exit 1; fi
}
