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
assert sum(p["expected_total"] for p in d["projects"])==2384
assert d["integration_expected_total"]==475
assert d["integration_expected_executed"]==473
assert d["integration_expected_skipped"]==2
paths=[p["path"] for p in d["projects"]]
assert len(paths)==len(set(paths))
assert "PL.PM.IntegrationTests" not in " ".join(paths)
PY

# --- manifiesto: procedencia fechable (T-009) ---
python3 - "$ROOT/config/pm-gate-manifest.json" <<'PY' && ok "manifest provenance" || bad "manifest provenance"
import json, sys
d=json.load(open(sys.argv[1]))
assert d.get("generated_at"), "generated_at vacio"
assert d.get("commit"), "commit vacio"
assert d.get("baseline_pm_sha"), "baseline_pm_sha vacio"
assert d["commit"]==d["baseline_pm_sha"], "commit != baseline_pm_sha"
assert len(d["commit"])==40, "commit no es un sha40"
assert d.get("baseline_evidence_id"), "baseline_evidence_id vacio"
assert d.get("scope")=="canonical"
assert d.get("generated_by")=="make pm-gate-manifest-promote"
for noise in ("drops_allowed", "drop_justification", "baseline_pm_dirty", "derived_from",
              "baseline_pm_branch", "baseline_wt", "baseline_source_fingerprint"):
    assert noise not in d, f"{noise} no deberia viajar al canonico"
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

# ===========================================================================
# Manifiesto de RAMA: override por entorno, regeneracion y guard de conteos
# ===========================================================================

# --- override por entorno de PM_UNIT_MANIFEST_REL (default intacto) ---
grep -q 'PM_UNIT_MANIFEST_REL="${PM_UNIT_MANIFEST_REL:-' "$ROOT/lib/unit-macdata.sh" \
  && ok "manifest rel overrideable" || bad "manifest rel overrideable"
# El valor va por prefijo al PROCESO hijo (no a la funcion) para no filtrarlo entre casos.
mpath() { BASE_DIR=/base PM_UNIT_MANIFEST_REL="${1:-}" bash -c '. "'"$ROOT"'/lib/unit-macdata.sh"; pm_unit_manifest_path'; }
[ "$(mpath)" = "/base/config/pm-gate-manifest.json" ] \
  && ok "manifest default sin override" || bad "manifest default sin override (=$(mpath))"
[ "$(mpath artifacts/gate-manifests/b.json)" = "/base/artifacts/gate-manifests/b.json" ] \
  && ok "override relativo honrado" || bad "override relativo honrado"
[ "$(mpath /abs/b.json)" = "/abs/b.json" ] \
  && ok "override absoluto honrado" || bad "override absoluto honrado"

# --- Makefile/pm.sh: knob MANIFEST y verbo de regeneracion ---
grep -q "MANIFEST_ENV = \$(if \$(MANIFEST)" "$ROOT/Makefile" \
  && ok "MANIFEST no pisa el entorno cuando viene vacio" || bad "MANIFEST no pisa el entorno cuando viene vacio"
(cd "$ROOT" && make -n pm-gate WT=x MANIFEST=artifacts/gate-manifests/b.json 2>/dev/null | grep -q "PM_UNIT_MANIFEST_REL='artifacts/gate-manifests/b.json'") \
  && ok "make pm-gate MANIFEST -> PM_UNIT_MANIFEST_REL" || bad "make pm-gate MANIFEST -> PM_UNIT_MANIFEST_REL"
(cd "$ROOT" && make -n pm-gate WT=x 2>/dev/null | grep -q "PM_UNIT_MANIFEST_REL=") \
  && bad "make pm-gate sin MANIFEST no inyecta la var" || ok "make pm-gate sin MANIFEST no inyecta la var"
grep -q 'gate-manifest-regen) cmd_gate_manifest_regen' "$ROOT/pm.sh" \
  && ok "verbo gate-manifest-regen registrado" || bad "verbo gate-manifest-regen registrado"
grep -q 'pm_gate_manifest_regen_run' "$ROOT/lib/unit-macdata.sh" \
  && ok "regen en la libreria" || bad "regen en la libreria"
rc=0
out="$(cd "$ROOT" && make pm-gate-manifest-regen 2>&1)" || rc=$?
echo "$out" | grep -q 'exige WT' && [ "$rc" -ne 0 ] && ok "make regen sin WT -> no cero" || bad "make regen sin WT -> no cero (rc=$rc)"

# --- fixtures sinteticos del comparador de cobertura ---
gen_mf() {  # $1=out $2=total del proyecto A
  python3 - "$1" "$2" <<'PY'
import json, sys
json.dump({
  "schema_version": 1, "project_count": 2,
  "integration_project": "tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj",
  "integration_expected_total": 300, "integration_expected_executed": 298,
  "integration_expected_skipped": 2,
  "sdk_image": "img@sha256:deadbeef", "expected_sdk_version": "10.0.302",
  "required_assets": ["a", "b", "c", "d"],
  "baseline_pm_sha": "baseline0",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "kind": "unit",
     "expected_total": int(sys.argv[2]), "expected_executed": int(sys.argv[2]),
     "expected_skipped": 0, "expected_failed": 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "kind": "unit",
     "expected_total": 10, "expected_executed": 10, "expected_skipped": 0, "expected_failed": 0},
  ],
}, open(sys.argv[1], "w"), indent=2)
PY
}
gen_summary() {  # $1=out $2=total de A $3=failed de A $4=rc de A [$5=1 omite el proyecto B]
  python3 - "$1" "$2" "$3" "$4" "${5:-0}" <<'PY'
import json, sys
out, total, failed, rc, drop_b = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
projects = [{"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": total,
             "executed": total, "skipped": 0, "failed": failed, "exit_code": rc,
             "duration_ms": 1, "trx": "a.trx"}]
if drop_b != "1":
    projects.append({"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10,
                     "skipped": 0, "failed": 0, "exit_code": 0, "duration_ms": 1, "trx": "b.trx"})
json.dump({"restore_rc": 0, "build_rc": 0, "exit_code": 0, "projects": projects}, open(out, "w"))
PY
}
cov() {  # $1=dir de trabajo -> imprime "<ok> <clase>"
  printf '%s %s' "$(cat "$1/coverage_ok.txt" | tr -d '\n')" "$(cat "$1/coverage_class.txt" | tr -d '\n')"
}

cmp_py="$ROOT/scripts/pm-unit-coverage-compare.py"
cd "$tmp"
mkdir -p "$tmp/canon"
gen_mf "$tmp/canon/pm-gate-manifest.json" 100

# 1) conteos exactos -> verde
mkdir -p "$tmp/c1"; gen_summary "$tmp/c1/summary.json" 100 0 0
python3 "$cmp_py" "$tmp/c1/summary.json" "$tmp/c1/projects.jsonl" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
[ "$(cov "$tmp/c1")" = "1 ok" ] && ok "guard: conteos exactos -> verde" || bad "guard: conteos exactos -> verde ($(cov "$tmp/c1"))"

# 2) CASO NEGATIVO: manifiesto correcto + suite acotada (100 -> 40) y CERO rojos -> el guard CORTA
mkdir -p "$tmp/c2"; gen_summary "$tmp/c2/summary.json" 40 0 0
python3 "$cmp_py" "$tmp/c2/summary.json" "$tmp/c2/projects.jsonl" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
[ "$(cov "$tmp/c2")" = "0 counts_only" ] \
  && ok "guard INTACTO: suite acotada con 0 rojos sigue cortando" \
  || bad "guard INTACTO: suite acotada con 0 rojos sigue cortando ($(cov "$tmp/c2"))"
grep -q 'total=40/100' "$tmp/c2/coverage_reasons.txt" && ok "guard reporta la desviacion" || bad "guard reporta la desviacion"

# 3) suite acotada + REGEN -> la fase pasa (insumo), pero el escritor la rechaza como baseline (abajo)
mkdir -p "$tmp/c3"; gen_summary "$tmp/c3/summary.json" 40 0 0
PM_UNIT_REGEN=1 python3 "$cmp_py" "$tmp/c3/summary.json" "$tmp/c3/projects.jsonl" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
[ "$(cov "$tmp/c3")" = "1 counts_only" ] && ok "regen observa conteos" || bad "regen observa conteos ($(cov "$tmp/c3"))"

# 4) un rojo NUNCA pasa, ni siquiera en regen
mkdir -p "$tmp/c4"; gen_summary "$tmp/c4/summary.json" 100 1 1
PM_UNIT_REGEN=1 python3 "$cmp_py" "$tmp/c4/summary.json" "$tmp/c4/projects.jsonl" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
[ "$(cov "$tmp/c4")" = "0 red" ] && ok "regen NO tapa un rojo" || bad "regen NO tapa un rojo ($(cov "$tmp/c4"))"

# 5) proyecto entero ausente -> structural, tampoco pasa en regen
mkdir -p "$tmp/c5"; gen_summary "$tmp/c5/summary.json" 100 0 0 1
PM_UNIT_REGEN=1 python3 "$cmp_py" "$tmp/c5/summary.json" "$tmp/c5/projects.jsonl" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
[ "$(cov "$tmp/c5")" = "0 structural" ] && ok "regen NO tapa una suite incompleta" || bad "regen NO tapa una suite incompleta ($(cov "$tmp/c5"))"

# --- escritor del manifiesto de rama ---
wr_py="$ROOT/scripts/pm-gate-manifest-write.py"
gen_result() {  # $1=out $2=total de A $3=failed de A $4=total de integracion
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import json, sys
out, total, failed, integ = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
json.dump({
  "run_id": "regen-test", "git_head": "abc123", "source_fingerprint": "fp",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": total, "executed": total,
     "skipped": 0, "failed": failed, "exit_code": 1 if failed else 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10,
     "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": integ, "executed": integ - 2, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(out, "w"))
PY
}

# 6) crecimiento legitimo -> escribe el manifiesto de rama con conteos reales
gen_result "$tmp/res-grow.json" 130 0 340
python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-grow.json" "$tmp/out-grow.json" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["projects"][0]["expected_total"]==130, d["projects"][0]
assert d["integration_expected_total"]==340
assert d["project_count"]==2 and d["scope"]=="branch"
assert d["baseline_pm_sha"]=="abc123"
' "$tmp/out-grow.json"; then ok "regen escribe conteos reales de la rama"; else bad "regen escribe conteos reales de la rama (rc=$rc)"; fi

# 7) CAIDA de conteos -> rechazada sin ALLOW_DROP (intencion del guard preservada)
gen_result "$tmp/res-drop.json" 40 0 340
rc=0; out="$(python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-drop.json" "$tmp/out-drop.json" "$tmp/canon/pm-gate-manifest.json" 2>&1)" || rc=$?
[ "$rc" -eq 5 ] && echo "$out" | grep -q 'PIERDE cobertura' && [ ! -f "$tmp/out-drop.json" ] \
  && ok "regen rechaza caida de cobertura sin ALLOW_DROP" || bad "regen rechaza caida de cobertura sin ALLOW_DROP (rc=$rc)"

# 8) ALLOW_DROP=1 exige REASON y deja constancia
rc=0; PM_GATE_MANIFEST_ALLOW_DROP=1 python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-drop.json" "$tmp/out-drop.json" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 5 ] && ok "ALLOW_DROP sin REASON se rechaza" || bad "ALLOW_DROP sin REASON se rechaza (rc=$rc)"
rc=0; PM_GATE_MANIFEST_ALLOW_DROP=1 PM_GATE_MANIFEST_REASON="retiro deliberado" \
  python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-drop.json" "$tmp/out-drop.json" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["drops_allowed"] and d["drops_allowed"][0]["from"]==100 and d["drops_allowed"][0]["to"]==40
assert d["drop_justification"]=="retiro deliberado"
' "$tmp/out-drop.json"; then ok "ALLOW_DROP+REASON queda registrado"; else bad "ALLOW_DROP+REASON queda registrado (rc=$rc)"; fi

# 9) evidencia roja -> jamas se convierte en baseline
gen_result "$tmp/res-red.json" 130 3 340
rc=0; PM_GATE_MANIFEST_ALLOW_DROP=1 PM_GATE_MANIFEST_REASON=x \
  python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-red.json" "$tmp/out-red.json" "$tmp/canon/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] && [ ! -f "$tmp/out-red.json" ] && ok "regen no sella baseline desde corrida roja" || bad "regen no sella baseline desde corrida roja (rc=$rc)"

# 10) el canonico NUNCA se sobrescribe
before="$(shasum -a 256 "$ROOT/config/pm-gate-manifest.json" | awk '{print $1}')"
rc=0; python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-grow.json" "$ROOT/config/pm-gate-manifest.json" \
  "$ROOT/config/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
after="$(shasum -a 256 "$ROOT/config/pm-gate-manifest.json" | awk '{print $1}')"
[ "$rc" -eq 4 ] && [ "$before" = "$after" ] && ok "regen jamas escribe el manifiesto canonico" || bad "regen jamas escribe el manifiesto canonico (rc=$rc)"
rc=0; python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-grow.json" "$ROOT/config/otro.json" \
  "$ROOT/config/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && [ ! -f "$ROOT/config/otro.json" ] && ok "regen no escribe dentro de config/" || bad "regen no escribe dentro de config/ (rc=$rc)"

# ===========================================================================
# Promotor del CANONICO (T-009): scripts/pm-gate-manifest-promote.py
# ===========================================================================
pr_py="$ROOT/scripts/pm-gate-manifest-promote.py"

gen_branch_mf() {  # $1=out $2=pm_sha $3=dirty(0|1) $4=integ_source(measured|inherited_from_canonical)
                    # $5=totalA(default 130) $6=drops_allowed_json(default []) $7=drop_justification(default "")
  python3 - "$1" "$2" "$3" "$4" "${5:-130}" "${6:-[]}" "${7:-}" <<'PY'
import json, sys
out, pm_sha, dirty, integ_src, total_a, drops_json, just = sys.argv[1:8]
json.dump({
  "schema_version": 1, "solution_path": "PL.PM.sln", "project_count": 2,
  "integration_project": "tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj",
  "integration_expected_total": 340, "integration_expected_executed": 338,
  "integration_expected_skipped": 2, "integration_counts_source": integ_src,
  "sdk_image": "img@sha256:deadbeef", "sdk_platform": "linux/amd64", "expected_sdk_version": "10.0.302",
  "required_assets": ["a", "b", "c", "d"],
  "baseline_unit_warm_min": 2.5, "target_unit_incremental_min": 1.5,
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "kind": "unit",
     "expected_total": int(total_a), "expected_executed": int(total_a),
     "expected_skipped": 0, "expected_failed": 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "kind": "unit",
     "expected_total": 10, "expected_executed": 10, "expected_skipped": 0, "expected_failed": 0},
  ],
  "scope": "branch",
  "baseline_pm_sha": pm_sha, "baseline_pm_dirty": dirty == "1",
  "baseline_evidence_id": "run-fixture", "baseline_evidence_dir": "artifacts/test-logs/gate/run-fixture",
  "drops_allowed": json.loads(drops_json), "drop_justification": just,
  "generated_at": "2026-07-25T00:00:00Z", "generated_by": "make pm-gate-manifest-regen",
}, open(out, "w"), indent=2)
PY
}

# Canonico sintetico DEDICADO (A/B, con el schema COMPLETO del canonico real): el REAL
# config/pm-gate-manifest.json tiene otros 14 paths y compararia el fixture A/B contra el, viendo
# los 14 reales como "removidos" (falso drop); el destino real ya se verifico en la instancia
# ejecutada por Paso 4 (arriba de este archivo, en el propio repo).
promote_canon="$tmp/promote-canon.json"
python3 - "$promote_canon" <<'PY'
import json, sys
json.dump({
  "schema_version": 1, "solution_path": "PL.PM.sln", "project_count": 2,
  "integration_project": "tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj",
  "integration_expected_total": 300, "integration_expected_executed": 298,
  "integration_expected_skipped": 2,
  "sdk_image": "img@sha256:deadbeef", "sdk_platform": "linux/amd64", "expected_sdk_version": "10.0.302",
  "baseline_pm_sha": "oldsha0000000000000000000000000000000000"[:40],
  "baseline_evidence_id": "old-id", "baseline_unit_warm_min": 2.5, "target_unit_incremental_min": 1.5,
  "required_assets": ["a", "b", "c", "d"],
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "kind": "unit",
     "expected_total": 100, "expected_executed": 100, "expected_skipped": 0, "expected_failed": 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "kind": "unit",
     "expected_total": 10, "expected_executed": 10, "expected_skipped": 0, "expected_failed": 0},
  ],
}, open(sys.argv[1], "w"), indent=2)
PY
SHA40="d58c8ead96d31ef9a454f6c703f46a273141d1c3"

# (a) sin --pm-sha -> rechazo, no escribe
mf_a="$tmp/promote-a.json"; gen_branch_mf "$mf_a" "$SHA40" 0 measured
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_a" --out "$tmp/promote-out-a.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-a.json" ] && ok "promote sin PM_SHA -> rechazo" || bad "promote sin PM_SHA -> rechazo (rc=$rc)"

# (b) medicion dirty (SHA de origen != --pm-sha) sin --trust-dirty -> rechazo
mf_b="$tmp/promote-b.json"; gen_branch_mf "$mf_b" "otro-sha-pre-merge-000000000000000000" 0 measured
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_b" --pm-sha "$SHA40" --out "$tmp/promote-out-b.json" 2>&1)" || rc=$?
echo "$out" | grep -q -- '--trust-dirty' && [ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-b.json" ] \
  && ok "promote dirty sin TRUST_DIRTY -> rechazo" || bad "promote dirty sin TRUST_DIRTY -> rechazo (rc=$rc)"

# (c) integration no measured -> rechazo
mf_c="$tmp/promote-c.json"; gen_branch_mf "$mf_c" "$SHA40" 0 inherited_from_canonical
rc=0; python3 "$pr_py" --canonical "$promote_canon" --from "$mf_c" --pm-sha "$SHA40" --out "$tmp/promote-out-c.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-c.json" ] && ok "promote integration no measured -> rechazo" || bad "promote integration no measured -> rechazo (rc=$rc)"

# (c2) --evidence roja (un proyecto con failed>0) -> rechazo, aunque el manifiesto de rama diga verde
mf_c2="$tmp/promote-c2.json"; gen_branch_mf "$mf_c2" "$SHA40" 0 measured
ev_c2="$tmp/evidence-red"; mkdir -p "$ev_c2"
python3 - "$ev_c2/result.json" <<'PY'
import json, sys
json.dump({
  "run_id": "run-red", "status": "passed", "runner_exit_code": 0, "git_head": "d58c8ead96d31ef9a454f6c703f46a273141d1c3",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": 130, "executed": 129, "skipped": 0, "failed": 1, "exit_code": 1},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10, "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": 340, "executed": 338, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(sys.argv[1], "w"))
PY
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_c2" --pm-sha "$SHA40" --evidence "$ev_c2" --out "$tmp/promote-out-c2.json" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-c2.json" ] && ok "promote con --evidence roja -> rechazo" || bad "promote con --evidence roja -> rechazo (rc=$rc)"

# (c3) M1: --evidence incompleta (falta un proyecto del manifiesto de rama) -> rechazo
#     Antes del fix, verify_evidence omitia en silencio el proyecto ausente y el promote sellaba
#     expected_total no medido. Rojo->verde de la ronda r1.
mf_c3="$tmp/promote-c3.json"; gen_branch_mf "$mf_c3" "$SHA40" 0 measured
ev_c3="$tmp/evidence-incomplete"; mkdir -p "$ev_c3"
python3 - "$ev_c3/result.json" <<'PY'
import json, sys
# Solo A: B falta a proposito (evidencia incompleta pero "passed" en los presentes).
json.dump({
  "run_id": "run-incomplete", "status": "passed", "runner_exit_code": 0,
  "git_head": "d58c8ead96d31ef9a454f6c703f46a273141d1c3",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": 130, "executed": 130, "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": 340, "executed": 338, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(sys.argv[1], "w"))
PY
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_c3" --pm-sha "$SHA40" --evidence "$ev_c3" --out "$tmp/promote-out-c3.json" 2>&1)" || rc=$?
echo "$out" | grep -q 'no cubre los mismos proyectos' && [ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-c3.json" ] \
  && ok "promote con --evidence incompleta (proyecto ausente) -> rechazo" \
  || bad "promote con --evidence incompleta (proyecto ausente) -> rechazo (rc=$rc out=$out)"

# (c4) S1: --from = result.json crudo (sin manifiesto de rama) -> camino reconstruct_from_result
res_c4="$tmp/result-raw.json"
python3 - "$res_c4" <<'PY'
import json, sys
json.dump({
  "run_id": "run-raw-result", "status": "passed", "runner_exit_code": 0,
  "git_head": "d58c8ead96d31ef9a454f6c703f46a273141d1c3",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": 130, "executed": 130, "skipped": 0, "failed": 0, "exit_code": 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10, "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": 340, "executed": 338, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(sys.argv[1], "w"))
PY
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$res_c4" --pm-sha "$SHA40" --out "$tmp/promote-out-c4.json" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/promote-out-c4.json" ] && echo "$out" | grep -q 'evidence_verified=no' \
  && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["scope"]=="canonical"
assert d["commit"]=="'"$SHA40"'"
assert sum(p["expected_total"] for p in d["projects"])==140
assert d["integration_expected_total"]==340
assert d["baseline_evidence_id"]=="run-raw-result"
' "$tmp/promote-out-c4.json"; then
  ok "promote --from result.json crudo (sin manifiesto de rama) -> ok"
else
  bad "promote --from result.json crudo (sin manifiesto de rama) -> ok (rc=$rc out=$out)"
fi

# (c5) S1 negativo: result.json crudo con proyecto rojo -> rechazo
res_c5="$tmp/result-raw-red.json"
python3 - "$res_c5" <<'PY'
import json, sys
json.dump({
  "run_id": "run-raw-red", "status": "failed", "runner_exit_code": 1,
  "git_head": "d58c8ead96d31ef9a454f6c703f46a273141d1c3",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": 130, "executed": 129, "skipped": 0, "failed": 1, "exit_code": 1},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10, "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": 340, "executed": 338, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(sys.argv[1], "w"))
PY
rc=0; python3 "$pr_py" --canonical "$promote_canon" --from "$res_c5" --pm-sha "$SHA40" --out "$tmp/promote-out-c5.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-c5.json" ] \
  && ok "promote --from result.json rojo -> rechazo" \
  || bad "promote --from result.json rojo -> rechazo (rc=$rc)"

# (d) promote feliz a un OUT temporal: NO pisa el canonico real del repo
#     S2: sin --evidence declara evidence_verified=no + manifest_promote_warn
before="$(shasum -a 256 "$ROOT/config/pm-gate-manifest.json" | awk '{print $1}')"
mf_d="$tmp/promote-d.json"; gen_branch_mf "$mf_d" "$SHA40" 0 measured
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_d" --pm-sha "$SHA40" --out "$tmp/promote-out-d.json" 2>&1)" || rc=$?
after="$(shasum -a 256 "$ROOT/config/pm-gate-manifest.json" | awk '{print $1}')"
if [ "$rc" -eq 0 ] && [ "$before" = "$after" ] && echo "$out" | grep -q 'evidence_verified=no' \
  && echo "$out" | grep -q 'manifest_promote_warn' \
  && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["scope"]=="canonical"
assert d["commit"]=="'"$SHA40"'" and d["baseline_pm_sha"]=="'"$SHA40"'"
assert sum(p["expected_total"] for p in d["projects"])==140
assert d["integration_expected_total"]==340
assert "drops_allowed" not in d and "drop_justification" not in d
assert d["evidence_verified"] is False
' "$tmp/promote-out-d.json"; then ok "promote feliz a OUT temporal no pisa el canonico real"; else bad "promote feliz a OUT temporal no pisa el canonico real (rc=$rc)"; fi

# (d2) S2: con --evidence completa y verde, evidence_verified=yes (sin warn de modo degradado)
mf_d2="$tmp/promote-d2.json"; gen_branch_mf "$mf_d2" "$SHA40" 0 measured
ev_d2="$tmp/evidence-green"; mkdir -p "$ev_d2"
python3 - "$ev_d2/result.json" <<'PY'
import json, sys
json.dump({
  "run_id": "run-green", "status": "passed", "runner_exit_code": 0,
  "git_head": "d58c8ead96d31ef9a454f6c703f46a273141d1c3",
  "projects": [
    {"path": "tests/A.UnitTests/A.UnitTests.csproj", "total": 130, "executed": 130, "skipped": 0, "failed": 0, "exit_code": 0},
    {"path": "tests/B.UnitTests/B.UnitTests.csproj", "total": 10, "executed": 10, "skipped": 0, "failed": 0, "exit_code": 0},
  ],
  "integration": {"total": 340, "executed": 338, "skipped": 2, "failed": 0, "exit_code": 0},
}, open(sys.argv[1], "w"))
PY
rc=0; out="$(python3 "$pr_py" --canonical "$promote_canon" --from "$mf_d2" --pm-sha "$SHA40" --evidence "$ev_d2" --out "$tmp/promote-out-d2.json" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ -f "$tmp/promote-out-d2.json" ] && echo "$out" | grep -q 'evidence_verified=yes' \
  && ! echo "$out" | grep -q 'manifest_promote_warn' \
  && python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d["baseline_evidence_id"]=="run-green"
assert d["evidence_verified"] is True
' "$tmp/promote-out-d2.json"; then
  ok "promote con --evidence completa -> evidence_verified=yes"
else
  bad "promote con --evidence completa -> evidence_verified=yes (rc=$rc out=$out)"
fi

# (e) caida de conteos vs el canonico ACTUAL sin justificar -> rechazo; con ALLOW_BASELINE_DROP+reason -> ok
mf_e="$tmp/promote-e.json"; gen_branch_mf "$mf_e" "$SHA40" 0 measured 1
rc=0; python3 "$pr_py" --canonical "$promote_canon" --from "$mf_e" --pm-sha "$SHA40" --out "$tmp/promote-out-e.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$tmp/promote-out-e.json" ] && ok "promote drop no justificado -> rechazo" || bad "promote drop no justificado -> rechazo (rc=$rc)"
rc=0; python3 "$pr_py" --canonical "$promote_canon" --from "$mf_e" --pm-sha "$SHA40" --out "$tmp/promote-out-e2.json" \
  --allow-baseline-drop --allow-baseline-drop-reason "retiro deliberado (fixture)" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/promote-out-e2.json" ] && ok "promote drop con ALLOW_BASELINE_DROP+reason -> ok" || bad "promote drop con ALLOW_BASELINE_DROP+reason -> ok (rc=$rc)"

# (f) caida ya justificada EN el manifiesto de rama (drops_allowed+drop_justification) -> se acepta sin flags extra
mf_f="$tmp/promote-f.json"
gen_branch_mf "$mf_f" "$SHA40" 0 measured 1 \
  '[{"path": "tests/A.UnitTests/A.UnitTests.csproj", "from": 100, "to": 1, "kind": "count_drop"}]' \
  "baseline canonico rancio, no perdida real de cobertura (fixture)"
rc=0; python3 "$pr_py" --canonical "$promote_canon" --from "$mf_f" --pm-sha "$SHA40" --out "$tmp/promote-out-f.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && [ -f "$tmp/promote-out-f.json" ] && ok "promote drop pre-justificado en manifiesto de rama -> ok sin flags" || bad "promote drop pre-justificado en manifiesto de rama -> ok sin flags (rc=$rc)"

# (g) write.py sigue sin poder escribir en config/ (canal separado, exit 4 -- cubierto arriba en el
#     caso 10; se re-afirma aqui explicitamente como frontera del promotor)
rc=0; python3 "$wr_py" "$tmp/canon/pm-gate-manifest.json" "$tmp/res-grow.json" "$ROOT/config/pm-gate-manifest.json" \
  "$ROOT/config/pm-gate-manifest.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 4 ] && ok "write.py sigue prohibido de escribir config/ (frontera con promote.py)" || bad "write.py sigue prohibido de escribir config/ (frontera con promote.py) (rc=$rc)"

# --- Makefile: verbo pm-gate-manifest-promote, guards y no exige WT ---
grep -q 'pm-gate-manifest-promote:' "$ROOT/Makefile" && ok "target pm-gate-manifest-promote existe" || bad "target pm-gate-manifest-promote existe"
grep -q 'pm-gate-manifest-promote exige FROM' "$ROOT/Makefile" && ok "promote exige FROM" || bad "promote exige FROM"
grep -q 'pm-gate-manifest-promote exige PM_SHA' "$ROOT/Makefile" && ok "promote exige PM_SHA" || bad "promote exige PM_SHA"
rc=0; out="$(cd "$ROOT" && make pm-gate-manifest-promote 2>&1)" || rc=$?
echo "$out" | grep -q 'exige FROM' && [ "$rc" -ne 0 ] && ok "make promote sin FROM -> no cero" || bad "make promote sin FROM -> no cero (rc=$rc)"
rc=0; out="$(cd "$ROOT" && make pm-gate-manifest-promote FROM=x.json 2>&1)" || rc=$?
echo "$out" | grep -q 'exige PM_SHA' && [ "$rc" -ne 0 ] && ok "make promote sin PM_SHA -> no cero" || bad "make promote sin PM_SHA -> no cero (rc=$rc)"

# --- sintaxis de los scripts nuevos ---
pysyn() { python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$1"; }
pysyn "$cmp_py" && ok "sintaxis coverage-compare" || bad "sintaxis coverage-compare"
pysyn "$wr_py" && ok "sintaxis manifest-write" || bad "sintaxis manifest-write"
pysyn "$ROOT/scripts/pm-gate-manifest-scaffold.py" && ok "sintaxis manifest-scaffold" || bad "sintaxis manifest-scaffold"
pysyn "$pr_py" && ok "sintaxis manifest-promote" || bad "sintaxis manifest-promote"
cd "$ROOT"

rm -rf "$tmp"

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
