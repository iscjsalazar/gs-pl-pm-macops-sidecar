#!/usr/bin/env bash
# Contratos herméticos de deprecaciones: no abre SSH, Docker, macdata ni un slot.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# pm-test y pm.sh test son tombstones antes de cargar common.sh o tocar el data tier.
out=""
if out="$(cd "$ROOT" && make pm-test 2>&1)"; then rc=0; else rc=$?; fi
echo "$out" | grep -q 'DEPRECATED' && echo "$out" | grep -q 'make pm-unit WT=<worktree>' \
  && echo "$out" | grep -q 'dotnet test <project>' && [ "$rc" -eq 2 ] \
  && ok "make pm-test tombstone names both replacements and exits 2" \
  || bad "make pm-test tombstone contract (rc=$rc)"

out=""
if out="$(cd "$ROOT" && PM_TARGET=intel PM_REMOTE_SSH=macdata ./pm.sh test 2>&1)"; then rc=0; else rc=$?; fi
echo "$out" | grep -q 'DEPRECATED' && echo "$out" | grep -q 'make pm-unit WT=<worktree>' \
  && echo "$out" | grep -q 'dotnet test <project>' && [ "$rc" -eq 2 ] \
  && ok "pm.sh test tombstone exits before environment work" \
  || bad "pm.sh test tombstone contract (rc=$rc)"

# Existing tombstones remain fail-closed and name the slot replacement.
for verb in e2e-backend e2e-backend-down; do
  out=""
  if out="$(cd "$ROOT" && ./pm.sh "$verb" 2>&1)"; then rc=0; else rc=$?; fi
  echo "$out" | grep -q 'DEPRECATED' && echo "$out" | grep -q 'make ' \
    && [ "$rc" -eq 2 ] && ok "$verb tombstone exits 2" || bad "$verb tombstone contract (rc=$rc)"
done

# Canonical targets remain dispatchable; -n proves the recipe without invoking macdata.
for pair in 'pm-unit:./pm.sh unit' 'pm-gate:./pm.sh gate' 'pm-test-clean:./pm.sh test-clean'; do
  target="${pair%%:*}"; dispatch="${pair#*:}"
  out="$(cd "$ROOT" && make -n "$target" WT=fixture 2>&1)" || true
  echo "$out" | grep -q "$dispatch" \
    && ok "$target still dispatches $dispatch" || bad "$target dispatch contract"
done

# WARM=1 is warning-only for gate aliases: it must be visible and must not become a tombstone.
for target in pm-gate pm-test-clean; do
  out="$(cd "$ROOT" && make -n "$target" WT=fixture WARM=1 2>&1)" || true
  echo "$out" | grep -q 'AVISO DEPRECADO: WARM=1' \
    && echo "$out" | grep -q './pm.sh' \
    && ok "$target WARM warning is visible without changing dispatch" \
    || bad "$target WARM warning contract"
done

# The public singleton verb is gone from the dispatch, while the internal helper remains available to the gate.
if ! grep -qE '^  test\)[[:space:]]+cmd_test' "$ROOT/pm.sh" \
  && grep -q 'PM_TEST_LOG_SINK' "$ROOT/pm.sh"; then
  ok "singleton test dispatch removed while gate log sink remains"
else
  bad "singleton test dispatch/log sink contract"
fi

# The physical integration consumer still invokes cmd_test; source pm.sh and lib/unit-macdata.sh in an
# isolated shell to prove that the provider survives the public tombstone without running a gate.
cmd_test_decl=""
if cmd_test_decl="$(cd "$ROOT" && bash -c '
  exit() { return 0; }
  set -- __deprecations_contract__
  . ./pm.sh >/dev/null 2>&1
  . ./lib/unit-macdata.sh >/dev/null 2>&1
  declare -f cmd_test
' 2>/dev/null)" \
  && [ -n "$cmd_test_decl" ] \
  && grep -qE 'PM_SKIP_API=1[[:space:]]+cmd_test' "$ROOT/lib/unit-macdata.sh"; then
  ok "gate consumer retains cmd_test provider after public tombstone"
else
  bad "gate consumer/provider cmd_test contract"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
