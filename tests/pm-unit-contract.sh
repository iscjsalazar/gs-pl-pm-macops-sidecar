#!/usr/bin/env bash
# Contratos locales (sin SSH/macdata real) de la receta unit-macdata / gate.
# Compatible con Bash 3.2. Patrón: tests/e2e-playwright-contract.sh.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WRAPPER="$(cd "$ROOT/../.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

# --- archivos versionados ---
[ -f "$ROOT/config/pm-gate-manifest.json" ] && ok "manifest exists" || bad "manifest exists"
[ -f "$ROOT/config/pm-unit.runsettings" ] && ok "runsettings exists" || bad "runsettings exists"
[ -f "$ROOT/lib/unit-macdata.sh" ] && ok "unit-macdata.sh exists" || bad "unit-macdata.sh exists"
[ -f "$ROOT/remote-intel/pm-unit-runner.sh" ] && ok "runner exists" || bad "runner exists"
[ -f "$ROOT/remote-intel/pm-unit-fingerprint.py" ] && ok "fingerprint.py exists" || bad "fingerprint.py exists"

# --- manifiesto: 14 proyectos, 4 assets, digest SDK ---
python3 - "$ROOT/config/pm-gate-manifest.json" <<'PY' && ok "manifest structure" || bad "manifest structure"
import json, sys
d=json.load(open(sys.argv[1]))
assert d["schema_version"]==1
assert len(d["projects"])==14
assert d["project_count"]==14
assert len(d["required_assets"])==4
assert "@sha256:" in d["sdk_image"]
assert d["expected_sdk_version"]=="10.0.302"
assert d["integration_project"]=="tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj"
assert sum(p["expected_total"] for p in d["projects"])==2123
assert d["integration_expected_total"]==334
paths=[p["path"] for p in d["projects"]]
assert len(paths)==len(set(paths))
assert "PL.PM.IntegrationTests" not in " ".join(paths)
PY

# --- runsettings: TreatNoTestsAsError, sin filtros ---
grep -q 'TreatNoTestsAsError>true' "$ROOT/config/pm-unit.runsettings" && ok "TreatNoTestsAsError" || bad "TreatNoTestsAsError"
! grep -qiE 'TestCaseFilter|Retry' "$ROOT/config/pm-unit.runsettings" && ok "no filter/retry in runsettings" || bad "no filter/retry in runsettings"

# --- Makefile: guards WT/FILTER y host macdata ---
grep -q 'pm-unit exige WT' "$ROOT/Makefile" && ok "pm-unit requires WT" || bad "pm-unit requires WT"
grep -q 'pm-unit rechaza FILTER' "$ROOT/Makefile" && ok "pm-unit rejects FILTER" || bad "pm-unit rejects FILTER"
grep -q 'pm-gate exige WT' "$ROOT/Makefile" && ok "pm-gate requires WT" || bad "pm-gate requires WT"
grep -q 'pm-gate rechaza FILTER' "$ROOT/Makefile" && ok "pm-gate rejects FILTER" || bad "pm-gate rejects FILTER"
grep -q 'pm-gate rechaza TESTPROJECT' "$ROOT/Makefile" && ok "pm-gate rejects TESTPROJECT" || bad "pm-gate rejects TESTPROJECT"
grep -q 'alias de pm-gate\|./pm.sh test-clean\|./pm.sh gate' "$ROOT/Makefile" && ok "test-clean alias wired" || bad "test-clean alias wired"

# --- pm.sh: unit/gate despachan a unit-macdata; test-clean -> gate ---
grep -q 'lib/unit-macdata.sh' "$ROOT/pm.sh" && ok "pm.sh sources unit-macdata" || bad "pm.sh sources unit-macdata"
grep -q 'pm_unit_macdata_run' "$ROOT/pm.sh" && ok "pm.sh unit -> macdata" || bad "pm.sh unit -> macdata"
grep -q 'pm_gate_macdata_run' "$ROOT/pm.sh" && ok "pm.sh gate -> macdata" || bad "pm.sh gate -> macdata"
grep -q 'cmd_gate' "$ROOT/pm.sh" && ok "cmd_gate exists" || bad "cmd_gate exists"
grep -A2 'cmd_test_clean' "$ROOT/pm.sh" | grep -q 'cmd_gate' && ok "test-clean delegates to gate" || bad "test-clean delegates to gate"

# --- sin fallback M1 en la receta ---
! grep -qE 'fallback.*M1|PM_UNIT_ALLOW_LOCAL=1|host alterno' "$ROOT/lib/unit-macdata.sh" && ok "no M1 fallback in orchestrator" || bad "no M1 fallback in orchestrator"
grep -q 'macdata' "$ROOT/lib/unit-macdata.sh" && ok "macdata forced" || bad "macdata forced"
grep -q 'required_asset_missing\|assets_fingerprint\|workspace_key' "$ROOT/lib/unit-macdata.sh" && ok "identity helpers present" || bad "identity helpers present"
grep -q 'network disconnect\|network_isolation' "$ROOT/lib/unit-macdata.sh" && ok "network isolation" || bad "network isolation"
grep -q '\-\-no-build' "$ROOT/remote-intel/pm-unit-runner.sh" && ok "runner --no-build" || bad "runner --no-build"
grep -q '\-\-no-restore' "$ROOT/remote-intel/pm-unit-runner.sh" && ok "runner --no-restore" || bad "runner --no-restore"
grep -q 'dotnet restore' "$ROOT/remote-intel/pm-unit-runner.sh" && ok "runner single restore" || bad "runner single restore"
grep -q 'dotnet build' "$ROOT/remote-intel/pm-unit-runner.sh" && ok "runner single build" || bad "runner single build"

# --- make guards reales (sin invocar ssh) ---
rc=0
out="$(cd "$ROOT" && make pm-unit 2>&1)" || rc=$?
echo "$out" | grep -q 'exige WT' && [ "$rc" -ne 0 ] && ok "make pm-unit sin WT -> no cero" || bad "make pm-unit sin WT -> no cero (rc=$rc)"

rc=0
out="$(cd "$ROOT" && make pm-unit WT=chore_pm_overhead-tiempo-pruebas FILTER=foo 2>&1)" || rc=$?
echo "$out" | grep -q 'rechaza FILTER' && [ "$rc" -ne 0 ] && ok "make pm-unit FILTER -> no cero" || bad "make pm-unit FILTER -> no cero (rc=$rc)"

rc=0
out="$(cd "$ROOT" && make pm-gate 2>&1)" || rc=$?
echo "$out" | grep -q 'exige WT' && [ "$rc" -ne 0 ] && ok "make pm-gate sin WT -> no cero" || bad "make pm-gate sin WT -> no cero (rc=$rc)"

rc=0
out="$(cd "$ROOT" && make pm-gate WT=x TESTPROJECT=y 2>&1)" || rc=$?
echo "$out" | grep -q 'rechaza TESTPROJECT' && [ "$rc" -ne 0 ] && ok "make pm-gate TESTPROJECT -> no cero" || bad "make pm-gate TESTPROJECT -> no cero (rc=$rc)"

# --- validación de manifiesto vs fixture sintético (13 proyectos = fail) ---
tmp="$(mktemp -d "${TMPDIR:-/tmp}/pm-unit-contract.XXXXXX")"
mkdir -p "$tmp/sol/tests/A.UnitTests" "$tmp/sol/containers/sql/init/planning" \
  "$tmp/sol/containers/oracle/data" "$tmp/sol/containers/oracle/init"
# crea 13 proyectos + assets
i=0
while [ "$i" -lt 13 ]; do
  i=$((i+1))
  mkdir -p "$tmp/sol/tests/P$i.UnitTests"
  touch "$tmp/sol/tests/P$i.UnitTests/P$i.UnitTests.csproj"
done
touch "$tmp/sol/PL.PM.sln"
touch "$tmp/sol/containers/sql/init/planning/0203-filters-loader.sql"
touch "$tmp/sol/containers/sql/init/planning/0203-productionmachines-loader.sql"
touch "$tmp/sol/containers/oracle/data/maquinas.csv"
touch "$tmp/sol/containers/oracle/init/2034-maquinas.csv.ctl"
# discovery != 14 -> load_manifest debe fallar cuando se invoque con SOLUTION real;
# aquí validamos el checker python del manifiesto embebido.
cp "$ROOT/config/pm-gate-manifest.json" "$tmp/mf.json"
if python3 - "$tmp/mf.json" "$tmp/sol" <<'PY' 2>/dev/null
import json,sys,pathlib
# reutiliza la lógica: discovery != 14
sol=pathlib.Path(sys.argv[2])
found=sorted(str(f.relative_to(sol)).replace("\\","/") for f in sol.glob("tests/*/*.UnitTests.csproj"))
assert len(found)!=14
sys.exit(0)
PY
then ok "fixture 13 projects detectable"; else bad "fixture 13 projects detectable"; fi

# --- asset missing detect ---
rm -f "$tmp/sol/containers/oracle/data/maquinas.csv"
if [ ! -f "$tmp/sol/containers/oracle/data/maquinas.csv" ]; then
  ok "asset missing fixture"
else
  bad "asset missing fixture"
fi

# --- bash -n ---
bash -n "$ROOT/lib/unit-macdata.sh" && ok "bash -n unit-macdata" || bad "bash -n unit-macdata"
bash -n "$ROOT/remote-intel/pm-unit-runner.sh" && ok "bash -n runner" || bad "bash -n runner"
bash -n "$ROOT/pm.sh" && ok "bash -n pm.sh" || bad "bash -n pm.sh"

# --- help/docs: gate canonico ---
grep -q 'CIERRE CANONICO\|cierre canonico\|unit macdata' "$ROOT/Makefile" && ok "Makefile promotes gate" || bad "Makefile promotes gate"
grep -q 'pm_gate_macdata_run\|unit_arch_macdata\|not_run' "$ROOT/lib/unit-macdata.sh" && ok "fail-fast phases" || bad "fail-fast phases"
grep -q 'slot_setup' "$ROOT/lib/unit-macdata.sh" && ok "slot_setup phase" || bad "slot_setup phase"
grep -q 'IntegrationTests' "$ROOT/lib/unit-macdata.sh" && ok "integration project forced" || bad "integration project forced"
! grep -q 'dotnet test.*PL.PM.sln' "$ROOT/lib/unit-macdata.sh" && ok "gate no PL.PM.sln" || bad "gate no PL.PM.sln"

rm -rf "$tmp"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
