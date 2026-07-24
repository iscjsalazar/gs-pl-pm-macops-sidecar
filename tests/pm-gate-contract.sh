#!/usr/bin/env bash
# Contratos del gate canónico (fail-fast, alias test-clean, log único, exits).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# test-clean es alias de gate
grep -A5 '^cmd_test_clean' "$ROOT/pm.sh" | grep -q 'cmd_gate' && ok "test-clean->gate" || bad "test-clean->gate"
grep -q 'gate)' "$ROOT/pm.sh" && ok "gate verb registered" || bad "gate verb registered"

# Fail-fast: unit rojo no llama wt-up
grep -A30 'unit_rc' "$ROOT/lib/unit-macdata.sh" | grep -q 'not_run' && ok "fail-fast not_run" || bad "fail-fast not_run"
grep -A40 'unit_rc' "$ROOT/lib/unit-macdata.sh" | grep -q 'unit_failed' && ok "fail-fast reason" || bad "fail-fast reason"

# Orden unit -> setup -> integration
grep -q 'pm_unit_macdata_run' "$ROOT/lib/unit-macdata.sh" && ok "gate calls unit first" || bad "gate calls unit first"
grep -q 'cmd_wt_up\|slot_setup' "$ROOT/lib/unit-macdata.sh" && ok "gate has slot_setup" || bad "gate has slot_setup"
grep -q 'pm_gate_run_integration_physical' "$ROOT/lib/unit-macdata.sh" && ok "gate has integration helper" || bad "gate has integration helper"

# PM_TEST_PROJECT forzado a IntegrationTests
grep -q 'PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj' "$ROOT/lib/unit-macdata.sh" && ok "integration path fixed" || bad "integration path fixed"

# Evidencia gate
grep -qE 'gate/\$run_id|mode.*=.*gate|/gate/' "$ROOT/lib/unit-macdata.sh" && ok "gate evidence dir" || bad "gate evidence dir"
grep -q 'PM_GATE_RESULT' "$ROOT/lib/unit-macdata.sh" && ok "PM_GATE_RESULT marker" || bad "PM_GATE_RESULT marker"
grep -q 'PM_UNIT_RESULT' "$ROOT/lib/unit-macdata.sh" && ok "PM_UNIT_RESULT marker" || bad "PM_UNIT_RESULT marker"
grep -q 'result.json' "$ROOT/lib/unit-macdata.sh" && ok "result.json seal" || bad "result.json seal"
grep -q 'result.rc' "$ROOT/lib/unit-macdata.sh" && ok "result.rc seal" || bad "result.rc seal"

# Exit codes documentados en código
grep -q 'invalid_invocation' "$ROOT/lib/unit-macdata.sh" && ok "invalid_invocation status" || bad "invalid_invocation status"
grep -q 'not_operational' "$ROOT/lib/unit-macdata.sh" && ok "not_operational status" || bad "not_operational status"
grep -q 'required_asset_missing' "$ROOT/lib/unit-macdata.sh" && ok "required_asset_missing" || bad "required_asset_missing"

# cmd_test acepta sink del gate (log único)
grep -q 'PM_TEST_LOG_SINK' "$ROOT/pm.sh" && ok "cmd_test log sink" || bad "cmd_test log sink"

# Make alias
grep -A8 '^pm-test-clean:' "$ROOT/Makefile" | grep -q 'pm.sh test-clean' && ok "make test-clean->pm.sh" || bad "make test-clean->pm.sh"
grep -A8 '^pm-gate:' "$ROOT/Makefile" | grep -q 'pm.sh gate' && ok "make gate->pm.sh" || bad "make gate->pm.sh"

# No recursión make wt-up + pm-test-clean (viejo pm-gate)
! grep -E 'pm-gate:.*;.*wt-up.*pm-test-clean' "$ROOT/Makefile" && ok "old recursive pm-gate removed" || bad "old recursive pm-gate removed"

# --- reason_code fino: desviacion de conteos != pruebas rojas ---
grep -q 'coverage_manifest_mismatch' "$ROOT/lib/unit-macdata.sh" && ok "reason coverage_manifest_mismatch" || bad "reason coverage_manifest_mismatch"
grep -q 'PM_UNIT_FAIL_REASON' "$ROOT/lib/unit-macdata.sh" && ok "fail reason plumbing" || bad "fail reason plumbing"
grep -A12 'local gate_reason="unit_failed_failfast"' "$ROOT/lib/unit-macdata.sh" | grep -q 'PM_UNIT_FAIL_REASON' \
  && ok "gate seal usa el reason fino" || bad "gate seal usa el reason fino"
grep -q 'pm_unit_desviacion_hint' "$ROOT/lib/unit-macdata.sh" && ok "hint de regeneracion/override" || bad "hint de regeneracion/override"
grep -q 'pm-gate-manifest-regen WT=' "$ROOT/lib/unit-macdata.sh" && ok "hint cita el verbo real" || bad "hint cita el verbo real"
grep -q 'MANIFEST=artifacts/gate-manifests' "$ROOT/lib/unit-macdata.sh" && ok "hint cita el knob MANIFEST" || bad "hint cita el knob MANIFEST"

# --- evidencia: identidad del manifiesto activo y modo regeneracion ---
grep -q '"manifest_path"' "$ROOT/lib/unit-macdata.sh" && ok "result.json trae manifest_path" || bad "result.json trae manifest_path"
grep -q '"regen_mode"' "$ROOT/lib/unit-macdata.sh" && ok "result.json marca regen_mode" || bad "result.json marca regen_mode"
grep -q 'manifest_regen_observed' "$ROOT/lib/unit-macdata.sh" && ok "verde de observacion no se confunde con sello" || bad "verde de observacion no se confunde con sello"

# --- la fase de integracion tambien separa veredicto de identidad ---
grep -q 'local phase_ok=0' "$ROOT/lib/unit-macdata.sh" && ok "integration phase_ok separado de baseline_match" || bad "integration phase_ok separado de baseline_match"

# --- regeneracion: nunca sobre el manifiesto canonico ---
grep -q 'manifest_regen_refused' "$ROOT/scripts/pm-gate-manifest-write.py" && ok "writer fail-closed" || bad "writer fail-closed"
grep -q 'pm-gate-manifest-regen exige WT' "$ROOT/Makefile" && ok "regen exige WT" || bad "regen exige WT"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
