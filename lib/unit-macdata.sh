#!/usr/bin/env bash
# Receta durable: unitarias + arquitectura en macdata (T-008).
# Compatible con Bash 3.2. Requiere common.sh ya sourced (BASE_DIR, resolve, ssh helpers).
# Superficies: pm_unit_macdata (fase) y pm_gate_macdata (cierre canónico con fail-fast).
set -euo pipefail

# --- constantes de la receta ---
PM_UNIT_MANIFEST_REL="config/pm-gate-manifest.json"
PM_UNIT_RUNSETTINGS_REL="config/pm-unit.runsettings"
PM_UNIT_REMOTE_NS="pm-unit-workspaces"
PM_UNIT_LOCK_DIR="${TMPDIR:-/tmp}/pm-unit-macdata.lock"
PM_UNIT_LOCK_MAX_WAIT="${PM_UNIT_LOCK_MAX_WAIT:-120}"
# Caps del contenedor: ≤ mitad de 6 CPUs y reserva ≥ PM_WT_MIN_MEM_GB=3 sobre 34 GiB.
PM_UNIT_DOCKER_CPUS="${PM_UNIT_DOCKER_CPUS:-3}"
PM_UNIT_DOCKER_MEMORY="${PM_UNIT_DOCKER_MEMORY:-8g}"
PM_UNIT_DOCKER_PIDS="${PM_UNIT_DOCKER_PIDS:-2048}"

# ---------------------------------------------------------------------------
# Utilidades de evidencia / tiempo
# ---------------------------------------------------------------------------
pm_unit_now_utc() { date -u +%Y%m%dT%H%M%SZ; }
pm_unit_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pm_unit_mono_ms() {
  # reloj monótono en ms (python); fallback date+0
  python3 -c 'import time; print(int(time.monotonic()*1000))' 2>/dev/null || date +%s000
}
pm_unit_sha256_file() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    sha256sum "$f" | awk '{print $1}'
  fi
}
pm_unit_sha256_str() {
  printf '%s' "$1" | shasum -a 256 2>/dev/null | awk '{print $1}'
}

pm_unit_validate_run_id() {
  local id="$1"
  case "$id" in
    ''|*[!A-Za-z0-9._-]* ) return 1 ;;
  esac
  [ "${#id}" -le 80 ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Validación de invocación pública
# ---------------------------------------------------------------------------
pm_unit_reject_public_filters() {
  # FILTER / TESTPROJECT / PM_TEST_FILTER / PM_TEST_PROJECT no se admiten en unit ni gate canónico.
  if [ -n "${FILTER:-}" ] || [ -n "${PM_TEST_FILTER:-}" ]; then
    echo "[pm-unit] invalid_invocation: FILTER no se admite en la via canonica (corpus completo)" >&2
    return 2
  fi
  if [ -n "${TESTPROJECT:-}" ] || [ -n "${PM_TEST_PROJECT:-}" ]; then
    # En gate el orquestador fija internamente PM_TEST_PROJECT; un valor heredado del caller se rechaza
    # salvo que venga marcado como interno (PM_GATE_INTERNAL=1).
    if [ "${PM_GATE_INTERNAL:-0}" != "1" ]; then
      echo "[pm-unit] invalid_invocation: TESTPROJECT no se admite en la via canonica" >&2
      return 2
    fi
  fi
  return 0
}

pm_unit_force_macdata() {
  # Fuerza host/contexto canónicos; rechaza overrides ajenos.
  if [ -n "${PM_TARGET:-}" ] && [ "$PM_TARGET" != "intel" ] && [ "${PM_UNIT_ALLOW_LOCAL:-0}" != "1" ]; then
    # make/pm fijan TARGET=intel; si llega otro valor explícito de usuario, falla.
    case "${PM_UNIT_ENFORCE_HOST:-1}" in
      1)
        if [ "$PM_TARGET" = "local" ] && [ -z "${PM_REMOTE_SSH:-}" ]; then
          echo "[pm-unit] invalid_invocation: la receta unit/gate corre solo en macdata (TARGET=intel REMOTE=macdata)" >&2
          return 2
        fi
        ;;
    esac
  fi
  PM_TARGET=intel
  PM_REMOTE_SSH="${PM_REMOTE_SSH:-macdata}"
  if [ "$PM_REMOTE_SSH" != "macdata" ]; then
    echo "[pm-unit] invalid_invocation: host remoto debe ser macdata (recibido: $PM_REMOTE_SSH)" >&2
    return 2
  fi
  # Contexto docker canónico del data tier en macdata.
  [ -n "${PM_REMOTE_DOCKER_CONTEXT:-}" ] || PM_REMOTE_DOCKER_CONTEXT="colima-nlc3runner"
  return 0
}

pm_unit_resolve_solution() {
  # WT obligatorio; SOLUTION opcional y debe coincidir.
  local wt_input="${WT:-}" solution_input="${PM_SOLUTION_DIR:-}"
  if [ -z "$wt_input" ]; then
    echo "[pm-unit] invalid_invocation: falta WT=<worktree>" >&2
    return 2
  fi
  local abs
  abs="$(pm_resolve_worktree_dir "$wt_input")" || return 2
  if [ -n "$solution_input" ]; then
    local sol
    sol="$(pm_resolve_solution_input "$solution_input")" || return 2
    if [ "$sol" != "$abs" ]; then
      echo "[pm-unit] invalid_invocation: WT y SOLUTION divergen: WT='$abs' SOLUTION='$sol'" >&2
      return 2
    fi
  fi
  PM_SOLUTION_DIR="$abs"
  PM_UNIT_WT_ABS="$abs"
  PM_UNIT_WT_SHORT="$(basename "$abs")"
  printf '%s' "$abs"
}

# ---------------------------------------------------------------------------
# Manifiesto versionado
# ---------------------------------------------------------------------------
pm_unit_manifest_path() {
  printf '%s/%s' "$BASE_DIR" "$PM_UNIT_MANIFEST_REL"
}

pm_unit_load_manifest() {
  local mf; mf="$(pm_unit_manifest_path)"
  [ -f "$mf" ] || { echo "[pm-unit] not_operational: falta manifiesto $mf" >&2; return 3; }
  PM_UNIT_MANIFEST_JSON="$(cat "$mf")"
  # Validación estructural con python (bash 3.2 no tiene JSON nativo).
  python3 - "$mf" "$PM_SOLUTION_DIR" <<'PY'
import json, os, sys, pathlib
mf_path, sol = sys.argv[1], pathlib.Path(sys.argv[2])
try:
    data = json.load(open(mf_path))
except Exception as e:
    print(f"manifest_invalid: JSON: {e}", file=sys.stderr); sys.exit(3)
if data.get("schema_version") != 1:
    print("manifest_invalid: schema_version", file=sys.stderr); sys.exit(3)
projects = data.get("projects") or []
if len(projects) != 14:
    print(f"manifest_invalid: project_count={len(projects)} (esperado 14)", file=sys.stderr); sys.exit(3)
paths = []
for p in projects:
    path = p.get("path") or ""
    if not path or ".." in path.split("/") or path.startswith("/"):
        print(f"manifest_invalid: path ilegal {path!r}", file=sys.stderr); sys.exit(3)
    if path in paths:
        print(f"manifest_invalid: path duplicado {path}", file=sys.stderr); sys.exit(3)
    paths.append(path)
    full = sol / path
    if not full.is_file():
        print(f"manifest_invalid: proyecto ausente {path}", file=sys.stderr); sys.exit(3)
    for k in ("expected_total", "expected_executed", "expected_skipped", "expected_failed"):
        v = p.get(k)
        if not isinstance(v, int) or v < 0:
            print(f"manifest_invalid: {path}.{k}", file=sys.stderr); sys.exit(3)
    if p["expected_total"] <= 0:
        print(f"manifest_invalid: {path}.expected_total<=0", file=sys.stderr); sys.exit(3)

# Descubrimiento dinámico debe coincidir exactamente.
found = []
tests = sol / "tests"
if tests.is_dir():
    for pat in ("*.UnitTests.csproj", "*.ArchitectureTests.csproj"):
        for f in tests.glob(f"*/{pat}"):
            rel = str(f.relative_to(sol)).replace("\\", "/")
            found.append(rel)
found = sorted(found)
expected = sorted(paths)
if found != expected:
    print("manifest_invalid: discovery != manifiesto", file=sys.stderr)
    print("expected:", expected, file=sys.stderr)
    print("found:", found, file=sys.stderr)
    sys.exit(3)

integ = data.get("integration_project") or ""
if integ != "tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj":
    print(f"manifest_invalid: integration_project={integ!r}", file=sys.stderr); sys.exit(3)
if not (sol / integ).is_file():
    print(f"manifest_invalid: integration ausente {integ}", file=sys.stderr); sys.exit(3)
if integ in paths:
    print("manifest_invalid: integration listada como unit", file=sys.stderr); sys.exit(3)

assets = data.get("required_assets") or []
if len(assets) != 4:
    print(f"manifest_invalid: required_assets={len(assets)} (esperado 4)", file=sys.stderr); sys.exit(3)
for a in assets:
    if not a or ".." in a.split("/") or a.startswith("/") or a.endswith("/"):
        print(f"manifest_invalid: asset ilegal {a!r}", file=sys.stderr); sys.exit(3)
    if "*" in a or "?" in a:
        print(f"manifest_invalid: asset glob {a!r}", file=sys.stderr); sys.exit(3)
    if not (sol / a).is_file():
        print(f"required_asset_missing: {a}", file=sys.stderr); sys.exit(3)

sdk = data.get("sdk_image") or ""
if "@sha256:" not in sdk:
    print("sdk_identity_mismatch: sdk_image sin @sha256:", file=sys.stderr); sys.exit(3)
for k in ("expected_sdk_version", "sdk_platform"):
    if not data.get(k):
        print(f"manifest_invalid: falta {k}", file=sys.stderr); sys.exit(3)
print("ok")
PY
}

pm_unit_manifest_field() {
  # Imprime un campo escalar del manifiesto (python).
  local key="$1"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],""))' \
    "$(pm_unit_manifest_path)" "$key"
}

pm_unit_manifest_project_paths() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(p["path"] for p in d["projects"]))' \
    "$(pm_unit_manifest_path)"
}

pm_unit_manifest_assets() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(d["required_assets"]))' \
    "$(pm_unit_manifest_path)"
}

# ---------------------------------------------------------------------------
# Identidad de fuente + assets
# ---------------------------------------------------------------------------
pm_unit_build_file_list() {
  # Lista NUL-delimited de entradas a copiar/firmar: todo bajo la solución excepto
  # .git/.env/._*/bin/obj/TestResults/artifacts/containers/**, más los 4 assets exactos.
  local root="$1" out="$2"
  local assets_file="$3"
  python3 - "$root" "$out" "$assets_file" <<'PY'
import os, sys, pathlib
root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2])
assets = [ln.strip() for ln in open(sys.argv[3]) if ln.strip()]
exclude_dirs = {".git", "bin", "obj", "TestResults", "artifacts", ".vs", ".idea"}
entries = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    rel_dir = pathlib.Path(dirpath).relative_to(root)
    # poda containers/ entero (se reinyecta por allowlist)
    parts = rel_dir.parts
    if parts and parts[0] == "containers":
        dirnames[:] = []
        continue
    # poda directorios excluidos en cualquier nivel
    dirnames[:] = [d for d in dirnames if d not in exclude_dirs and not d.startswith("._")]
    for name in filenames:
        if name == ".env" or name.startswith("._"):
            continue
        p = pathlib.Path(dirpath) / name
        rel = str(p.relative_to(root)).replace("\\", "/")
        if any(part in exclude_dirs for part in pathlib.Path(rel).parts):
            continue
        if "\n" in rel or "\t" in rel or "\0" in rel:
            print(f"manifest_invalid: path con control chars {rel!r}", file=sys.stderr)
            sys.exit(3)
        # rechaza symlink que escape
        if p.is_symlink():
            target = p.resolve()
            try:
                target.relative_to(root)
            except ValueError:
                print(f"manifest_invalid: symlink escapado {rel}", file=sys.stderr)
                sys.exit(3)
        entries.append(rel)

for a in assets:
    p = root / a
    if not p.is_file():
        print(f"required_asset_missing: {a}", file=sys.stderr)
        sys.exit(3)
    if a not in entries:
        entries.append(a)

entries = sorted(set(entries))
# escribe NUL-delimited
with open(out, "wb") as f:
    for e in entries:
        f.write(e.encode("utf-8") + b"\0")
print(len(entries))
PY
}

pm_unit_fingerprint_from_list() {
  # SHA-256 compuesto: por cada path (orden bytewise) path|tipo|size|sha
  local root="$1" list="$2"
  python3 - "$root" "$list" <<'PY'
import hashlib, os, sys, pathlib
root = pathlib.Path(sys.argv[1])
data = open(sys.argv[2], "rb").read().split(b"\0")
paths = [p.decode("utf-8") for p in data if p]
h = hashlib.sha256()
for rel in paths:
    p = root / rel
    if p.is_symlink():
        kind = "L"; payload = os.readlink(p).encode()
        mode = "x" if os.access(p, os.X_OK) else "-"
        size = 0
        dig = hashlib.sha256(payload).hexdigest()
    elif p.is_file():
        kind = "F"
        mode = "x" if os.access(p, os.X_OK) else "-"
        size = p.stat().st_size
        dig = hashlib.sha256(p.read_bytes()).hexdigest()
    else:
        print(f"missing:{rel}", file=sys.stderr); sys.exit(3)
    line = f"{rel}|{kind}|{mode}|{size}|{dig}\n"
    h.update(line.encode())
print(h.hexdigest())
PY
}

pm_unit_assets_fingerprint() {
  local root="$1"
  python3 - "$root" "$(pm_unit_manifest_path)" <<'PY'
import hashlib, json, sys, pathlib
root = pathlib.Path(sys.argv[1])
assets = json.load(open(sys.argv[2]))["required_assets"]
h = hashlib.sha256()
for rel in sorted(assets):
    p = root / rel
    dig = hashlib.sha256(p.read_bytes()).hexdigest()
    size = p.stat().st_size
    h.update(f"{rel}|{size}|{dig}\n".encode())
print(h.hexdigest())
PY
}

pm_unit_workspace_key() {
  # SHA-256 estable de identidad canónica del repo+ruta del worktree.
  local abs="$1"
  pm_unit_sha256_str "pm-unit-ws|v1|${abs}"
}

pm_unit_dependency_key() {
  local root="$1"
  python3 - "$root" <<'PY'
import hashlib, pathlib, sys
root = pathlib.Path(sys.argv[1])
patterns = ["global.json", "Directory.Packages.props", "NuGet.config", "nuget.config",
            "*.sln", "*.csproj", "*.props", "*.targets", "packages.lock.json"]
files = []
for pat in patterns:
    if "*" in pat:
        files.extend(root.rglob(pat))
    else:
        p = root / pat
        if p.is_file():
            files.append(p)
# normaliza y excluye bin/obj
norm = []
for f in files:
    rel = str(f.relative_to(root)).replace("\\", "/")
    parts = pathlib.Path(rel).parts
    if any(p in ("bin", "obj", ".git") for p in parts):
        continue
    norm.append(rel)
norm = sorted(set(norm))
h = hashlib.sha256()
for rel in norm:
    p = root / rel
    dig = hashlib.sha256(p.read_bytes()).hexdigest()
    h.update(f"{rel}|{dig}\n".encode())
print(h.hexdigest()[:32])
PY
}

# ---------------------------------------------------------------------------
# Locks y recursos
# ---------------------------------------------------------------------------
pm_unit_lock_acquire() {
  local i=0
  PM_UNIT_QUEUE_WAIT_MS=0
  local t0; t0="$(pm_unit_mono_ms)"
  until mkdir "$PM_UNIT_LOCK_DIR" 2>/dev/null; do
    i=$((i+1))
    if [ "$i" -gt "$PM_UNIT_LOCK_MAX_WAIT" ]; then
      echo "[pm-unit] not_operational: lock_unavailable tras ${PM_UNIT_LOCK_MAX_WAIT}s" >&2
      return 3
    fi
    sleep 1
  done
  local t1; t1="$(pm_unit_mono_ms)"
  PM_UNIT_QUEUE_WAIT_MS=$((t1 - t0))
  echo "$$" > "$PM_UNIT_LOCK_DIR/owner"
  # shellcheck disable=SC2064
  trap 'pm_unit_lock_release; pm_unit_on_interrupt' INT TERM
  # S3: EXIT cubre abort inesperado (error no capturado bajo set -e, código no previsto) que INT/TERM
  # no ven. Si al salir result.rc sigue "running" (pm_unit_seal_result nunca corrió), sella un veredicto
  # no-cero best-effort y libera el lock; si ya está sellado, es no-op salvo liberar el lock (idempotente).
  trap 'pm_unit_on_exit' EXIT
  return 0
}

pm_unit_lock_release() {
  [ -d "$PM_UNIT_LOCK_DIR" ] || return 0
  local owner; owner="$(cat "$PM_UNIT_LOCK_DIR/owner" 2>/dev/null || true)"
  if [ "$owner" = "$$" ] || [ -z "$owner" ]; then
    rm -rf "$PM_UNIT_LOCK_DIR" 2>/dev/null || true
  fi
}

pm_unit_on_exit() {
  local ec=$?
  set +e
  if [ -n "${PM_UNIT_EVIDENCE_DIR:-}" ] && [ -f "$PM_UNIT_EVIDENCE_DIR/result.rc" ]; then
    local cur
    cur="$(cat "$PM_UNIT_EVIDENCE_DIR/result.rc" 2>/dev/null || echo running)"
    if [ "$cur" = "running" ]; then
      local fallback_ec="$ec"
      [ "$fallback_ec" != "0" ] || fallback_ec=3
      echo "$fallback_ec" > "$PM_UNIT_EVIDENCE_DIR/result.rc" 2>/dev/null
      if [ ! -f "$PM_UNIT_EVIDENCE_DIR/result.json" ]; then
        python3 - "$PM_UNIT_EVIDENCE_DIR/result.json" "$fallback_ec" "${PM_UNIT_RUN_ID:-unknown}" "${PM_UNIT_MODE:-unit}" <<'PY' 2>/dev/null
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
doc = {
  "schema_version": 1,
  "run_id": sys.argv[3],
  "mode": sys.argv[4],
  "status": "not_operational",
  "reason_code": "unexpected_exit",
  "runner_exit_code": int(sys.argv[2]),
  "canonical_evidence": False,
}
tmp = out.with_suffix(".json.tmp")
tmp.write_text(json.dumps(doc, indent=2) + "\n")
tmp.replace(out)
PY
      fi
      pm_unit_log "on_exit: result.rc seguia running -> sellado fallback rc=$fallback_ec"
      # ec se actualiza al fallback: en bash algunos abort (p.ej. parametro indefinido bajo set -u)
      # reportan $? =0 al propio trap y, sin re-exit explicito, el proceso terminaria en 0 pese al
      # abort (verificado empiricamente en esta ronda) — nunca dejar pasar ese 0 como veredicto.
      ec="$fallback_ec"
    fi
  fi
  pm_unit_lock_release
  # Re-exit explícito: nunca dejar que el status del ÚLTIMO comando del trap (p.ej. pm_unit_lock_release
  # devolviendo 0 por "ya liberado") sustituya silenciosamente el exit code real del proceso.
  exit "$ec"
}

pm_unit_on_interrupt() {
  if [ -n "${PM_UNIT_EVIDENCE_DIR:-}" ] && [ -d "$PM_UNIT_EVIDENCE_DIR" ]; then
    echo interrupted > "$PM_UNIT_EVIDENCE_DIR/result.rc" 2>/dev/null || true
    echo 130 > "$PM_UNIT_EVIDENCE_DIR/result.rc" 2>/dev/null || true
  fi
  # cleanup remoto best-effort
  if [ -n "${PM_UNIT_CONTAINER_NAME:-}" ] && [ -n "${PM_REMOTE_SSH:-}" ]; then
    ssh "$PM_REMOTE_SSH" "export PATH=/usr/local/bin:\$PATH; docker $(remote_docker_ctx) rm -f '$PM_UNIT_CONTAINER_NAME' 2>/dev/null" || true
  fi
  exit 130
}

pm_unit_check_resources() {
  # Fail-closed: mide CPUs/mem/disco del docker remoto.
  local info
  if ! info="$(on_intel "docker $(remote_docker_ctx) info --format '{{.NCPU}} {{.MemTotal}}'" 2>/dev/null)"; then
    echo "[pm-unit] not_operational: resource_unmeasurable (docker info)" >&2
    return 3
  fi
  local ncpu mem
  ncpu="$(printf '%s' "$info" | awk '{print $1}')"
  mem="$(printf '%s' "$info" | awk '{print $2}')"
  if [ -z "$ncpu" ] || [ -z "$mem" ] || [ "$ncpu" = "0" ]; then
    echo "[pm-unit] not_operational: resource_unmeasurable (parse vacio: $info)" >&2
    return 3
  fi
  PM_UNIT_HOST_NCPU="$ncpu"
  PM_UNIT_HOST_MEM="$mem"
  # Reserva mínima de RAM para slots (PM_WT_MIN_MEM_GB=3 → 3 GiB).
  local min_bytes=$(( ${PM_WT_MIN_MEM_GB:-3} * 1024 * 1024 * 1024 ))
  # Memoria del contenedor unitario ≈ 8g; debe caber sin invadir la reserva.
  local unit_bytes=$(( 8 * 1024 * 1024 * 1024 ))
  if [ "$((mem - unit_bytes))" -lt "$min_bytes" ]; then
    echo "[pm-unit] not_operational: resource_insufficient (mem host=$mem unit=$unit_bytes reserve=$min_bytes)" >&2
    return 3
  fi
  # CPU cap ≤ mitad
  local half=$(( ncpu / 2 ))
  [ "$half" -ge 1 ] || half=1
  if [ "${PM_UNIT_DOCKER_CPUS%%.*}" -gt "$half" ]; then
    PM_UNIT_DOCKER_CPUS="$half"
  fi
  return 0
}

pm_unit_check_sdk_image() {
  local image; image="$(pm_unit_manifest_field sdk_image)"
  local platform; platform="$(pm_unit_manifest_field sdk_platform)"
  local expected_ver; expected_ver="$(pm_unit_manifest_field expected_sdk_version)"
  local inspect
  if ! inspect="$(on_intel "docker $(remote_docker_ctx) image inspect '$image' --format '{{.Id}}|{{json .RepoDigests}}|{{.Architecture}}'" 2>/dev/null)"; then
    echo "[pm-unit] not_operational: sdk_image_missing ($image)" >&2
    return 3
  fi
  local id arch digests
  id="$(printf '%s' "$inspect" | awk -F'|' '{print $1}')"
  digests="$(printf '%s' "$inspect" | awk -F'|' '{print $2}')"
  arch="$(printf '%s' "$inspect" | awk -F'|' '{print $3}')"
  case "$image" in
    *@sha256:*)
      local want="${image##*@}"
      case "$id" in
        *"${want#sha256:}"*|sha256:"${want#sha256:}") : ;;
        *)
          # Id suele ser el digest de contenido; acepta si RepoDigests lo contiene.
          case "$digests" in
            *"$want"*) : ;;
            *) echo "[pm-unit] not_operational: sdk_identity_mismatch id=$id digests=$digests want=$want" >&2; return 3 ;;
          esac
          ;;
      esac
      ;;
    *) echo "[pm-unit] not_operational: sdk_identity_mismatch (sin digest)" >&2; return 3 ;;
  esac
  if [ "$arch" != "amd64" ] && [ "$platform" = "linux/amd64" ]; then
    # Algunas versiones reportan Architecture=amd64; si vacío, sigue.
    if [ -n "$arch" ] && [ "$arch" != "amd64" ]; then
      echo "[pm-unit] not_operational: sdk_identity_mismatch arch=$arch" >&2
      return 3
    fi
  fi
  PM_UNIT_SDK_IMAGE="$image"
  PM_UNIT_SDK_ID="$id"
  PM_UNIT_SDK_EXPECTED_VER="$expected_ver"
  return 0
}

# ---------------------------------------------------------------------------
# Evidencia
# ---------------------------------------------------------------------------
pm_unit_open_evidence() {
  local mode="$1" run_id="$2"
  local base="$BASE_DIR/artifacts/test-logs"
  if [ "$mode" = "gate" ]; then
    PM_UNIT_EVIDENCE_DIR="$base/gate/$run_id"
  else
    PM_UNIT_EVIDENCE_DIR="$base/unit/$run_id"
  fi
  mkdir -p "$PM_UNIT_EVIDENCE_DIR/trx/unit" "$PM_UNIT_EVIDENCE_DIR/trx/integration" \
           "$PM_UNIT_EVIDENCE_DIR/source-manifests"
  echo running > "$PM_UNIT_EVIDENCE_DIR/result.rc"
  if [ "$mode" = "gate" ]; then
    PM_UNIT_LOG="$PM_UNIT_EVIDENCE_DIR/gate.log"
  else
    PM_UNIT_LOG="$PM_UNIT_EVIDENCE_DIR/unit.log"
  fi
  : > "$PM_UNIT_LOG"
  PM_UNIT_PHASES_JSONL="$PM_UNIT_EVIDENCE_DIR/phases.jsonl"
  PM_UNIT_PROJECTS_JSONL="$PM_UNIT_EVIDENCE_DIR/projects.jsonl"
  : > "$PM_UNIT_PHASES_JSONL"
  : > "$PM_UNIT_PROJECTS_JSONL"
  PM_UNIT_MODE="$mode"
  PM_UNIT_RUN_ID="$run_id"
  PM_UNIT_STARTED_MS="$(pm_unit_mono_ms)"
  PM_UNIT_STARTED_ISO="$(pm_unit_now_iso)"
}

pm_unit_log() {
  local msg="$*"
  printf '%s %s\n' "$(pm_unit_now_iso)" "$msg" | tee -a "$PM_UNIT_LOG" >&2
}

pm_unit_phase_begin() {
  local name="$1"
  eval "PM_UNIT_PHASE_${name}_START=\$(pm_unit_mono_ms)"
  eval "PM_UNIT_PHASE_${name}_STATUS=running"
  pm_unit_log "phase_begin name=$name"
}

pm_unit_phase_end() {
  local name="$1" status="$2" rc="$3"
  local start end dur
  eval "start=\${PM_UNIT_PHASE_${name}_START:-0}"
  end="$(pm_unit_mono_ms)"
  dur=$((end - start))
  printf '{"phase":"%s","status":"%s","raw_exit_code":%s,"normalized_exit_code":%s,"duration_ms":%s,"ts":"%s"}\n' \
    "$name" "$status" "$rc" "$rc" "$dur" "$(pm_unit_now_iso)" >> "$PM_UNIT_PHASES_JSONL"
  pm_unit_log "phase_end name=$name status=$status rc=$rc duration_ms=$dur"
}

pm_unit_phase_not_run() {
  local name="$1" reason="$2"
  printf '{"phase":"%s","status":"not_run","raw_exit_code":null,"normalized_exit_code":null,"duration_ms":0,"not_run_reason":"%s","ts":"%s"}\n' \
    "$name" "$reason" "$(pm_unit_now_iso)" >> "$PM_UNIT_PHASES_JSONL"
  pm_unit_log "phase_not_run name=$name reason=$reason"
}

pm_unit_seal_result() {
  local status="$1" reason="$2" exit_code="$3"
  local wall=0
  if [ -n "${PM_UNIT_STARTED_MS:-}" ]; then
    wall=$(( $(pm_unit_mono_ms) - PM_UNIT_STARTED_MS ))
  fi
  echo "$exit_code" > "$PM_UNIT_EVIDENCE_DIR/result.rc"
  python3 - "$PM_UNIT_EVIDENCE_DIR/result.json" <<PY
import json, pathlib, sys, os
out = pathlib.Path(sys.argv[1])
phases = []
pj = pathlib.Path(os.environ.get("PM_UNIT_PHASES_JSONL",""))
if pj.is_file():
    for line in pj.read_text().splitlines():
        line=line.strip()
        if line:
            try: phases.append(json.loads(line))
            except Exception: pass
projects = []
prj = pathlib.Path(os.environ.get("PM_UNIT_PROJECTS_JSONL",""))
if prj.is_file():
    for line in prj.read_text().splitlines():
        line=line.strip()
        if line:
            try: projects.append(json.loads(line))
            except Exception: pass
doc = {
  "schema_version": 1,
  "run_id": os.environ.get("PM_UNIT_RUN_ID",""),
  "mode": os.environ.get("PM_UNIT_MODE","unit"),
  "status": """$status""",
  "reason_code": """$reason""",
  "runner_exit_code": int("""$exit_code"""),
  "canonical_evidence": True,
  "started_at": os.environ.get("PM_UNIT_STARTED_ISO",""),
  "finished_at": "$(pm_unit_now_iso)",
  "wall_total_ms": int("""$wall"""),
  "active_total_ms": int("""$wall""") - int(os.environ.get("PM_UNIT_QUEUE_WAIT_MS","0")),
  "queue_wait_ms": int(os.environ.get("PM_UNIT_QUEUE_WAIT_MS","0")),
  "wt_input": os.environ.get("WT",""),
  "solution_path": os.environ.get("PM_SOLUTION_DIR",""),
  "git_head": os.environ.get("PM_UNIT_GIT_HEAD",""),
  "source_fingerprint": os.environ.get("PM_UNIT_SOURCE_FP",""),
  "assets_fingerprint": os.environ.get("PM_UNIT_ASSETS_FP",""),
  "workspace_key": os.environ.get("PM_UNIT_WORKSPACE_KEY",""),
  "dependency_key": os.environ.get("PM_UNIT_DEPENDENCY_KEY",""),
  "sdk_image": os.environ.get("PM_UNIT_SDK_IMAGE",""),
  "sdk_image_id": os.environ.get("PM_UNIT_SDK_ID",""),
  "sdk_version": os.environ.get("PM_UNIT_SDK_VERSION",""),
  "state_class": os.environ.get("PM_UNIT_STATE_CLASS","unknown"),
  "comparable": os.environ.get("PM_UNIT_COMPARABLE","true") == "true",
  "host_ncpu": os.environ.get("PM_UNIT_HOST_NCPU",""),
  "host_mem": os.environ.get("PM_UNIT_HOST_MEM",""),
  "docker_cpus": os.environ.get("PM_UNIT_DOCKER_CPUS",""),
  "docker_memory": os.environ.get("PM_UNIT_DOCKER_MEMORY",""),
  "manifest_project_count": 14,
  "phases": {p.get("phase"): p for p in phases},
  "projects": projects,
  "integration": json.loads(os.environ.get("PM_UNIT_INTEGRATION_JSON","null") or "null"),
  "evidence_dir": str(out.parent),
}
tmp = out.with_suffix(".json.tmp")
tmp.write_text(json.dumps(doc, indent=2) + "\n")
tmp.replace(out)
PY
  if [ "${PM_UNIT_MODE}" = "gate" ]; then
    echo "PM_GATE_RESULT=$PM_UNIT_EVIDENCE_DIR/result.json"
    echo "PM_GATE_LOG=$PM_UNIT_LOG"
    echo "PM_GATE_EXIT=$exit_code"
  else
    echo "PM_UNIT_RESULT=$PM_UNIT_EVIDENCE_DIR/result.json"
    echo "PM_UNIT_LOG=$PM_UNIT_LOG"
    echo "PM_UNIT_EXIT=$exit_code"
  fi
  pm_unit_lock_release
}

# ---------------------------------------------------------------------------
# Sync + remote workspace
# ---------------------------------------------------------------------------
pm_unit_prepare_remote_workspace() {
  local ws_key="$1"
  PM_UNIT_REMOTE_HOME="$(on_intel 'printf %s "$HOME"')"
  PM_UNIT_REMOTE_ROOT="$PM_UNIT_REMOTE_HOME/$PM_UNIT_REMOTE_NS/$ws_key"
  PM_UNIT_REMOTE_SOURCE="$PM_UNIT_REMOTE_ROOT/source"
  PM_UNIT_REMOTE_CACHE="$PM_UNIT_REMOTE_ROOT/cache"
  PM_UNIT_REMOTE_STATE="$PM_UNIT_REMOTE_ROOT/state"
  PM_UNIT_REMOTE_RUNS="$PM_UNIT_REMOTE_ROOT/runs"
  on_intel "mkdir -p '$PM_UNIT_REMOTE_SOURCE' '$PM_UNIT_REMOTE_CACHE/nuget' '$PM_UNIT_REMOTE_CACHE/nuget-http' \
    '$PM_UNIT_REMOTE_CACHE/dotnet-home' '$PM_UNIT_REMOTE_CACHE/home' '$PM_UNIT_REMOTE_STATE' \
    '$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID' && \
    printf 'pm-unit-workspace-v1|%s\\n' '$ws_key' > '$PM_UNIT_REMOTE_ROOT/OWNER'"
}

pm_unit_sync_source() {
  local list_file="$1"
  local root="$PM_SOLUTION_DIR"
  # Limpia containers/ administrado en remoto y resync base (sin containers/).
  on_intel "rm -rf '$PM_UNIT_REMOTE_SOURCE/containers' && mkdir -p '$PM_UNIT_REMOTE_SOURCE'"
  rsync -a --delete --checksum \
    --exclude '.git/' \
    --exclude '.env' \
    --exclude '._*' \
    --exclude 'bin/' \
    --exclude 'obj/' \
    --exclude 'TestResults/' \
    --exclude 'artifacts/' \
    --exclude '.vs/' \
    --exclude 'containers/' \
    --out-format='%i %n' \
    "$root/" "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_SOURCE/" \
    > "$PM_UNIT_EVIDENCE_DIR/sync-delta.txt" 2>&1 || {
      pm_unit_log "sync falló (rsync base)"
      return 3
    }
  # Copia exacta de los 4 assets. Lista en archivo (ssh NO debe consumir el stdin del bucle).
  local assets_list="$PM_UNIT_EVIDENCE_DIR/source-manifests/assets-list.txt"
  pm_unit_manifest_assets > "$assets_list"
  local a n_copied=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ -f "$root/$a" ] || { pm_unit_log "required_asset_missing local: $a"; return 3; }
    # </dev/null: evita que ssh drene el resto de assets_list.
    ssh -n "$PM_REMOTE_SSH" "mkdir -p '$(dirname "$PM_UNIT_REMOTE_SOURCE/$a")'" </dev/null || return 3
    if ! rsync -a --checksum "$root/$a" "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_SOURCE/$a"; then
      pm_unit_log "sync asset falló: $a"
      return 3
    fi
    n_copied=$((n_copied + 1))
  done < "$assets_list"
  if [ "$n_copied" -ne 4 ]; then
    pm_unit_log "required_asset_missing: copiados=$n_copied (esperado 4)"
    return 3
  fi
  # Lista remota de archivos bajo containers/ (exactamente 4 paths allowlisted).
  local remote_list
  remote_list="$(ssh -n "$PM_REMOTE_SSH" "export PATH=/usr/local/bin:\$PATH; find '$PM_UNIT_REMOTE_SOURCE/containers' -type f 2>/dev/null | sed 's|^$PM_UNIT_REMOTE_SOURCE/||' | LC_ALL=C sort")"
  local remote_n
  remote_n="$(printf '%s\n' "$remote_list" | grep -c . || true)"
  if [ "${remote_n:-0}" -ne 4 ]; then
    pm_unit_log "unexpected_container_asset: count=$remote_n (esperado 4)"
    pm_unit_log "remote containers files: $remote_list"
    return 3
  fi
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case "$remote_list" in
      *"$a"*) : ;;
      *) pm_unit_log "required_asset_missing remote: $a"; return 3 ;;
    esac
  done < "$assets_list"
  return 0
}

pm_unit_remote_fingerprint() {
  # Calcula fingerprint en remoto con la misma política (python remoto).
  local assets_tmp list_tmp
  assets_tmp="$(mktemp)"
  list_tmp="$(mktemp)"
  pm_unit_manifest_assets > "$assets_tmp"
  # Sube helper mínimo y assets list
  scp -q "$assets_tmp" "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/assets.txt"
  scp -q "$BASE_DIR/remote-intel/pm-unit-fingerprint.py" \
    "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/fingerprint.py" 2>/dev/null || {
    # embebido si aún no se scp-ea el py dedicado: genera inline
    on_intel "cat > '$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/fingerprint.py' <<'PY'
import hashlib, os, pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
assets = [ln.strip() for ln in open(sys.argv[2]) if ln.strip()]
exclude_dirs = {'.git', 'bin', 'obj', 'TestResults', 'artifacts', '.vs', '.idea'}
entries = []
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    rel_dir = pathlib.Path(dirpath).relative_to(root)
    parts = rel_dir.parts
    if parts and parts[0] == 'containers':
        dirnames[:] = []
        continue
    dirnames[:] = [d for d in dirnames if d not in exclude_dirs and not d.startswith('._')]
    for name in filenames:
        if name == '.env' or name.startswith('._'): continue
        p = pathlib.Path(dirpath)/name
        rel = str(p.relative_to(root)).replace('\\\\','/')
        if any(part in exclude_dirs for part in pathlib.Path(rel).parts): continue
        entries.append(rel)
for a in assets:
    if a not in entries: entries.append(a)
entries = sorted(set(entries))
h = hashlib.sha256()
for rel in entries:
    p = root/rel
    if not p.is_file():
        print('missing:'+rel, file=sys.stderr); sys.exit(3)
    dig = hashlib.sha256(p.read_bytes()).hexdigest()
    size = p.stat().st_size
    mode = 'x' if os.access(p, os.X_OK) else '-'
    h.update(f'{rel}|F|{mode}|{size}|{dig}\\n'.encode())
print(h.hexdigest())
ah = hashlib.sha256()
for rel in sorted(assets):
    p = root/rel
    dig = hashlib.sha256(p.read_bytes()).hexdigest()
    ah.update(f'{rel}|{p.stat().st_size}|{dig}\\n'.encode())
print(ah.hexdigest())
# count containers files
n = 0
c = root/'containers'
if c.is_dir():
    for _dp,_dn,fn in os.walk(c):
        n += len(fn)
print(n)
PY"
  }
  local out
  out="$(on_intel "python3 '$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/fingerprint.py' '$PM_UNIT_REMOTE_SOURCE' '$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/assets.txt'")" || return 3
  PM_UNIT_REMOTE_SOURCE_FP="$(printf '%s\n' "$out" | sed -n '1p')"
  PM_UNIT_REMOTE_ASSETS_FP="$(printf '%s\n' "$out" | sed -n '2p')"
  PM_UNIT_REMOTE_CONTAINERS_N="$(printf '%s\n' "$out" | sed -n '3p')"
  rm -f "$assets_tmp" "$list_tmp"
  return 0
}

# ---------------------------------------------------------------------------
# Build-seal (M2): identidad + limpieza/mitigación acotadas
# ---------------------------------------------------------------------------
pm_unit_recipe_fingerprint() {
  # Huella de la receta que ejecuta el build: runner + runsettings + manifiesto versionados.
  local f1="$BASE_DIR/remote-intel/pm-unit-runner.sh"
  local f2="$BASE_DIR/$PM_UNIT_RUNSETTINGS_REL"
  local f3; f3="$(pm_unit_manifest_path)"
  if command -v shasum >/dev/null 2>&1; then
    cat "$f1" "$f2" "$f3" | shasum -a 256 | awk '{print $1}'
  else
    cat "$f1" "$f2" "$f3" | sha256sum | awk '{print $1}'
  fi
}

pm_unit_write_build_seal() {
  # Sella atómicamente (tmp+mv) la identidad del build que ACABA de completar con éxito.
  # Se invoca solo cuando restore_rc=0 y build_rc=0 (independiente del veredicto de los tests:
  # un test rojo no vuelve stale al binario que sí compiló).
  local dep_key="$1"
  local recipe_fp="${PM_UNIT_RECIPE_FP:-$(pm_unit_recipe_fingerprint)}"
  local seal_content
  seal_content="$(python3 -c '
import json, sys
print(json.dumps({
    "schema_version": 1,
    "state": "complete",
    "source_fingerprint": sys.argv[1],
    "assets_fingerprint": sys.argv[2],
    "recipe_fingerprint": sys.argv[3],
    "dependency_key": sys.argv[4],
    "sdk_image": sys.argv[5],
    "sdk_image_id": sys.argv[6],
    "run_id": sys.argv[7],
    "sealed_at": sys.argv[8],
}))
' "$PM_UNIT_SOURCE_FP" "$PM_UNIT_ASSETS_FP" "$recipe_fp" "$dep_key" "$PM_UNIT_SDK_IMAGE" "$PM_UNIT_SDK_ID" "$PM_UNIT_RUN_ID" "$(pm_unit_now_iso)")"
  local seal_tmp="$PM_UNIT_REMOTE_STATE/build-seal.json.tmp.$$"
  local seal_final="$PM_UNIT_REMOTE_STATE/build-seal.json"
  printf '%s' "$seal_content" | on_intel "cat > '$seal_tmp' && mv -f '$seal_tmp' '$seal_final'"
}

pm_unit_clean_stale_build_outputs() {
  # Limpieza ACOTADA: solo bin/obj bajo el source/ del workspace validado (OWNER re-verificado).
  local owner_check
  owner_check="$(on_intel "cat '$PM_UNIT_REMOTE_ROOT/OWNER' 2>/dev/null" || true)"
  case "$owner_check" in
    pm-unit-workspace-v1\|*) : ;;
    *)
      pm_unit_log "build_seal: OWNER inesperado ('$owner_check'), no se limpia bin/obj"
      return 1
      ;;
  esac
  on_intel "find '$PM_UNIT_REMOTE_SOURCE' -type d \\( -name bin -o -name obj \\) -prune -exec rm -rf {} + 2>/dev/null; true"
}

pm_unit_touch_transferred() {
  # Mitigación §5: bumpea mtime (a "ahora") de los archivos que rsync SÍ transfirió (sync-delta.txt,
  # formato itemizado '%i %n') más los 4 assets exactos. Evita que dotnet build --no-restore trate un
  # archivo con contenido nuevo pero mtime preservado por rsync como "no cambió" (build incremental stale).
  local delta_file="$1"
  [ -f "$delta_file" ] || return 0
  local list_tmp; list_tmp="$(mktemp)"
  awk '{
    code=$1
    if (code ~ /^\*deleting/) next
    $1=""
    sub(/^ /, "")
    if (length($0)) print
  }' "$delta_file" > "$list_tmp"
  pm_unit_manifest_assets >> "$list_tmp"
  if [ -s "$list_tmp" ]; then
    on_intel "cd '$PM_UNIT_REMOTE_SOURCE' && while IFS= read -r p; do [ -n \"\$p\" ] && [ -e \"\$p\" ] && touch -- \"\$p\"; done; true" < "$list_tmp"
  fi
  rm -f "$list_tmp"
}

# ---------------------------------------------------------------------------
# Ejecución remota (restore/build/test)
# ---------------------------------------------------------------------------
pm_unit_run_remote_pipeline() {
  local dep_key="$1"
  PM_UNIT_CONTAINER_NAME="pm-unit-$PM_UNIT_RUN_ID"
  # Copia runner + runsettings + genera slnf
  scp -q "$BASE_DIR/remote-intel/pm-unit-runner.sh" \
    "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/pm-unit-runner.sh"
  scp -q "$BASE_DIR/$PM_UNIT_RUNSETTINGS_REL" \
    "$PM_REMOTE_SSH:$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/pm-unit.runsettings"
  pm_unit_manifest_project_paths | on_intel "cat > '$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/projects.txt'"
  # Genera .slnf: path de solución relativo al .slnf o absoluto; projects DEBEN coincidir
  # textualmente con las entradas del .sln (backslashes Windows-style en esta solución).
  # Coloca el .slnf DENTRO de source/ para que path='PL.PM.sln' resuelva bien.
  on_intel "python3 - <<'PY'
import json, pathlib, re
projects = [ln.strip() for ln in open('$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/projects.txt') if ln.strip()]
# Normaliza a la forma del .sln: tests\\Name\\Name.csproj
sln_style = [p.replace('/', '\\\\') for p in projects]
doc = {
  'solution': {
    'path': 'PL.PM.sln',
    'projects': sln_style
  }
}
# .slnf junto a la solución dentro del mount source
out = pathlib.Path('$PM_UNIT_REMOTE_SOURCE/pm-unit.slnf')
out.write_text(json.dumps(doc, indent=2) + '\n')
# Copia de control en runs/
pathlib.Path('$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID/pm-unit.slnf').write_text(json.dumps(doc, indent=2) + '\n')
print('slnf', len(projects), out)
PY"

  local cpus="$PM_UNIT_DOCKER_CPUS"
  local mem="$PM_UNIT_DOCKER_MEMORY"
  local pids="$PM_UNIT_DOCKER_PIDS"
  local image="$PM_UNIT_SDK_IMAGE"
  local ctx; ctx="$(remote_docker_ctx)"
  local run_dir="$PM_UNIT_REMOTE_RUNS/$PM_UNIT_RUN_ID"
  local src="$PM_UNIT_REMOTE_SOURCE"
  local cache_nuget="$PM_UNIT_REMOTE_CACHE/nuget/$dep_key"
  local cache_http="$PM_UNIT_REMOTE_CACHE/nuget-http/$dep_key"
  local cache_cli="$PM_UNIT_REMOTE_CACHE/dotnet-home/$dep_key"
  local cache_home="$PM_UNIT_REMOTE_CACHE/home/$dep_key"

  on_intel "mkdir -p '$cache_nuget' '$cache_http' '$cache_cli' '$cache_home' '$run_dir/trx' '$run_dir/out'"

  # Contenedor efímero con red (para restore); el runner desconecta tras restore.
  # --pull=never: no descarga silenciosa.
  local uid_gid
  uid_gid="$(on_intel 'printf %s:%s "$(id -u)" "$(id -g)"')"

  pm_unit_log "docker_run name=$PM_UNIT_CONTAINER_NAME cpus=$cpus memory=$mem pids=$pids image=$image"

  # Ejecuta runner dentro del contenedor. El runner escribe summary.json + TRX en /work/run.
  set +e
  on_intel "export PATH=/usr/local/bin:\$PATH
    docker $ctx rm -f '$PM_UNIT_CONTAINER_NAME' >/dev/null 2>&1 || true
    docker $ctx run -d --name '$PM_UNIT_CONTAINER_NAME' \
      --platform linux/amd64 \
      --pull=never \
      --cpus='$cpus' \
      --memory='$mem' \
      --memory-swap='$mem' \
      --pids-limit='$pids' \
      --user '$uid_gid' \
      -e DOTNET_NOLOGO=1 \
      -e DOTNET_CLI_TELEMETRY_OPTOUT=1 \
      -e NUGET_PACKAGES=/work/cache/nuget \
      -e NUGET_HTTP_CACHE_PATH=/work/cache/nuget-http \
      -e DOTNET_CLI_HOME=/work/cache/dotnet-home \
      -e HOME=/work/cache/home \
      -e EXPECTED_SDK_VERSION='$PM_UNIT_SDK_EXPECTED_VER' \
      -v '$src:/work/source' \
      -v '$run_dir:/work/run' \
      -v '$cache_nuget:/work/cache/nuget' \
      -v '$cache_http:/work/cache/nuget-http' \
      -v '$cache_cli:/work/cache/dotnet-home' \
      -v '$cache_home:/work/cache/home' \
      -w /work/source \
      '$image' \
      sleep 7200
  "
  local create_rc
  create_rc=$?
  # M3 (mismo hallazgo de fondo que en pm_unit_macdata_run/pm_gate_run_integration_physical): esta
  # función corre SIEMPRE bajo el `set +e` que ya puso el caller antes de invocarla; NO se reactiva -e
  # aquí ni en los otros dos puntos de esta función (más abajo) porque un `set -e` seguido de un
  # `return` no-cero se filtraría (errexit es global, no por-función) y abortaría al caller ANTES de
  # que capture `$?` — se verificó empíricamente que esto rompía por completo el fail-fast del gate
  # ante un unit-rojo real. Cada rama de esta función ya comprueba su propio rc explícitamente.
  if [ "$create_rc" -ne 0 ]; then
    pm_unit_log "docker run falló rc=$create_rc"
    return 3
  fi

  # 1) RESTORE (con red)
  set +e
  on_intel "docker $ctx exec '$PM_UNIT_CONTAINER_NAME' bash /work/run/pm-unit-runner.sh restore" \
    >"$PM_UNIT_EVIDENCE_DIR/remote-restore.log" 2>&1
  local restore_exec_rc
  restore_exec_rc=$?
  cat "$PM_UNIT_EVIDENCE_DIR/remote-restore.log" >> "$PM_UNIT_LOG" 2>/dev/null || true
  if [ "$restore_exec_rc" -ne 0 ]; then
    pm_unit_log "restore falló rc=$restore_exec_rc"
    rsync -az "$PM_REMOTE_SSH:$run_dir/out/" "$PM_UNIT_EVIDENCE_DIR/remote-out/" 2>/dev/null || true
    on_intel "docker $ctx rm -f '$PM_UNIT_CONTAINER_NAME' >/dev/null 2>&1 || true"
    PM_UNIT_CONTAINER_NAME=""
    return 1
  fi

  # 2) Aísla red: desconecta todas las redes del contenedor y verifica
  local nets
  nets="$(on_intel "docker $ctx inspect '$PM_UNIT_CONTAINER_NAME' --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}'" 2>/dev/null || true)"
  local net
  for net in $nets; do
    [ -n "$net" ] || continue
    pm_unit_log "network_disconnect net=$net"
    on_intel "docker $ctx network disconnect -f '$net' '$PM_UNIT_CONTAINER_NAME'" 2>/dev/null || true
  done
  local nets_after
  nets_after="$(on_intel "docker $ctx inspect '$PM_UNIT_CONTAINER_NAME' --format '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}'" 2>/dev/null || true)"
  nets_after="$(printf '%s' "$nets_after" | tr -d '[:space:]')"
  if [ -n "$nets_after" ]; then
    pm_unit_log "network_isolation_failed remaining=$nets_after"
    on_intel "docker $ctx rm -f '$PM_UNIT_CONTAINER_NAME' >/dev/null 2>&1 || true"
    PM_UNIT_CONTAINER_NAME=""
    return 3
  fi
  pm_unit_log "network_isolated ok"

  # 3) BUILD + 14 tests (sin red)
  set +e
  on_intel "docker $ctx exec '$PM_UNIT_CONTAINER_NAME' bash /work/run/pm-unit-runner.sh build-test" \
    >"$PM_UNIT_EVIDENCE_DIR/remote-build-test.log" 2>&1
  local build_test_rc
  build_test_rc=$?
  cat "$PM_UNIT_EVIDENCE_DIR/remote-build-test.log" >> "$PM_UNIT_LOG" 2>/dev/null || true

  local summary_rc
  summary_rc="$(on_intel "python3 -c \"import json; print(json.load(open('$run_dir/out/summary.json')).get('exit_code',1))\" 2>/dev/null" || echo 1)"
  local runner_rc="$summary_rc"
  if [ "$build_test_rc" -ne 0 ] && [ "$runner_rc" = "0" ]; then
    runner_rc="$build_test_rc"
  fi

  # Copia TRX y summary a evidencia local
  mkdir -p "$PM_UNIT_EVIDENCE_DIR/trx/unit"
  rsync -az "$PM_REMOTE_SSH:$run_dir/out/" "$PM_UNIT_EVIDENCE_DIR/remote-out/" 2>/dev/null || true
  rsync -az "$PM_REMOTE_SSH:$run_dir/trx/" "$PM_UNIT_EVIDENCE_DIR/trx/unit/" 2>/dev/null || true

  # SDK version efectiva
  PM_UNIT_SDK_VERSION="$(on_intel "docker $ctx exec '$PM_UNIT_CONTAINER_NAME' dotnet --version 2>/dev/null" || true)"
  export PM_UNIT_SDK_VERSION

  # Cleanup contenedor
  on_intel "docker $ctx rm -f '$PM_UNIT_CONTAINER_NAME' >/dev/null 2>&1 || true"
  PM_UNIT_CONTAINER_NAME=""

  # Parsea projects.jsonl desde summary
  if [ -f "$PM_UNIT_EVIDENCE_DIR/remote-out/summary.json" ]; then
    python3 - "$PM_UNIT_EVIDENCE_DIR/remote-out/summary.json" "$PM_UNIT_PROJECTS_JSONL" "$(pm_unit_manifest_path)" <<'PY'
import json, sys, pathlib
summary = json.load(open(sys.argv[1]))
out = pathlib.Path(sys.argv[2])
mf = json.load(open(sys.argv[3]))
exp = {p["path"]: p for p in mf["projects"]}
lines = []
ok = True
reasons = []
for i, pr in enumerate(summary.get("projects") or [], 1):
    path = pr.get("path")
    e = exp.get(path, {})
    total = int(pr.get("total") if pr.get("total") is not None else 0)
    executed = int(pr.get("executed") if pr.get("executed") is not None else 0)
    skipped = int(pr.get("skipped") if pr.get("skipped") is not None else 0)
    failed = int(pr.get("failed") if pr.get("failed") is not None else 0)
    # OJO: no usar `x or 1` — exit_code 0 es falsy en Python.
    rc = int(pr["exit_code"]) if "exit_code" in pr and pr["exit_code"] is not None else 1
    match = (
        total == e.get("expected_total")
        and executed == e.get("expected_executed")
        and skipped == e.get("expected_skipped")
        and failed == e.get("expected_failed", 0)
        and rc == 0
        and total > 0
    )
    if not match:
        ok = False
        reasons.append(f"{path}: total={total}/{e.get('expected_total')} exec={executed} skip={skipped} fail={failed} rc={rc}")
    lines.append(json.dumps({
        "index": i,
        "path": path,
        "invocation_count": 1,
        "exit_code": rc,
        "total": total,
        "executed": executed,
        "skipped": skipped,
        "failed": failed,
        "duration_ms": pr.get("duration_ms"),
        "trx": pr.get("trx"),
        "baseline_match": match,
    }))
out.write_text("\n".join(lines) + ("\n" if lines else ""))
# también resume counts
agg = summary.get("aggregates") or {}
pathlib.Path(sys.argv[1]).with_name("coverage_ok.txt").write_text(
    "1\n" if ok and summary.get("restore_rc")==0 and summary.get("build_rc")==0 and len(lines)==14 else "0\n"
)
pathlib.Path(sys.argv[1]).with_name("coverage_reasons.txt").write_text("\n".join(reasons)+"\n")
print("projects", len(lines), "ok" if ok else "mismatch")
PY
  else
    pm_unit_log "evidence_invalid: falta summary.json remoto"
    return 3
  fi

  # Interpreta veredicto unitario
  local cov_ok restore_rc build_rc
  cov_ok="$(cat "$PM_UNIT_EVIDENCE_DIR/remote-out/coverage_ok.txt" 2>/dev/null || echo 0)"
  restore_rc="$(python3 -c 'import json; print(json.load(open("'"$PM_UNIT_EVIDENCE_DIR"'/remote-out/summary.json")).get("restore_rc",1))' 2>/dev/null || echo 1)"
  build_rc="$(python3 -c 'import json; print(json.load(open("'"$PM_UNIT_EVIDENCE_DIR"'/remote-out/summary.json")).get("build_rc",1))' 2>/dev/null || echo 1)"

  # M2: sella el build SOLO si restore+build compilaron limpio (independiente del veredicto de tests:
  # un test rojo no vuelve stale al binario que sí compiló, así que el seal debe seguir siendo válido).
  if [ "$restore_rc" = "0" ] && [ "$build_rc" = "0" ]; then
    pm_unit_write_build_seal "$dep_key" || pm_unit_log "build_seal: fallo al escribir el seal (no bloqueante)"
  fi

  if [ "$restore_rc" != "0" ] || [ "$build_rc" != "0" ]; then
    pm_unit_log "unit failed: restore_rc=$restore_rc build_rc=$build_rc"
    return 1
  fi
  if [ "$cov_ok" != "1" ]; then
    pm_unit_log "unit failed: coverage/baseline mismatch o test rojo"
    if [ -f "$PM_UNIT_EVIDENCE_DIR/remote-out/coverage_reasons.txt" ]; then
      pm_unit_log "$(cat "$PM_UNIT_EVIDENCE_DIR/remote-out/coverage_reasons.txt")"
    fi
    return 1
  fi
  if [ "$runner_rc" != "0" ]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Fase unitaria completa
# ---------------------------------------------------------------------------
pm_unit_macdata_run() {
  # Entrada: WT ya en entorno; PM_UNIT_EVIDENCE_DIR puede venir del gate.
  local mode="${1:-unit}"
  local run_id="${2:-}"
  local t_wall0; t_wall0="$(pm_unit_mono_ms)"

  pm_unit_reject_public_filters || return $?
  pm_unit_force_macdata || return $?

  if [ -z "$run_id" ]; then
    run_id="unit-$(pm_unit_now_utc)-$$"
  fi
  if ! pm_unit_validate_run_id "$run_id"; then
    echo "[pm-unit] invalid_invocation: UNIT_RUN_ID inseguro: $run_id" >&2
    return 2
  fi

  # Si el gate ya abrió evidencia, reutiliza; si no, abre propia.
  if [ -z "${PM_UNIT_EVIDENCE_DIR:-}" ] || [ ! -d "${PM_UNIT_EVIDENCE_DIR:-}" ]; then
    pm_unit_open_evidence "$mode" "$run_id"
  else
    PM_UNIT_RUN_ID="$run_id"
    PM_UNIT_MODE="$mode"
    [ -n "${PM_UNIT_LOG:-}" ] || PM_UNIT_LOG="$PM_UNIT_EVIDENCE_DIR/unit.log"
    [ -n "${PM_UNIT_PHASES_JSONL:-}" ] || PM_UNIT_PHASES_JSONL="$PM_UNIT_EVIDENCE_DIR/phases.jsonl"
    [ -n "${PM_UNIT_PROJECTS_JSONL:-}" ] || PM_UNIT_PROJECTS_JSONL="$PM_UNIT_EVIDENCE_DIR/projects.jsonl"
    [ -n "${PM_UNIT_STARTED_MS:-}" ] || PM_UNIT_STARTED_MS="$(pm_unit_mono_ms)"
    [ -n "${PM_UNIT_STARTED_ISO:-}" ] || PM_UNIT_STARTED_ISO="$(pm_unit_now_iso)"
  fi
  export PM_UNIT_RUN_ID PM_UNIT_MODE PM_UNIT_LOG PM_UNIT_PHASES_JSONL PM_UNIT_PROJECTS_JSONL
  export PM_UNIT_STARTED_MS PM_UNIT_STARTED_ISO PM_UNIT_EVIDENCE_DIR
  export PM_UNIT_DOCKER_CPUS PM_UNIT_DOCKER_MEMORY

  pm_unit_phase_begin validate
  if ! pm_unit_resolve_solution >/dev/null; then
    pm_unit_phase_end validate invalid_invocation 2
    pm_unit_seal_result invalid_invocation "invalid_wt" 2
    return 2
  fi
  export PM_SOLUTION_DIR WT
  PM_UNIT_GIT_HEAD="$(cd "$PM_SOLUTION_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)"
  export PM_UNIT_GIT_HEAD

  if ! pm_unit_load_manifest; then
    local mrc
    mrc=$?
    # Nota: con `if ! cmd` el rc ya se perdió aquí en algunos shells; re-ejecutar no.
    # load_manifest imprime el motivo; normalizamos a 3.
    mrc=3
    pm_unit_phase_end validate not_operational "$mrc"
    pm_unit_seal_result not_operational "manifest_or_asset" "$mrc"
    return "$mrc"
  fi
  pm_unit_phase_end validate passed 0

  # Lock
  if ! pm_unit_lock_acquire; then
    pm_unit_seal_result not_operational "lock_unavailable" 3
    return 3
  fi
  export PM_UNIT_QUEUE_WAIT_MS

  pm_unit_phase_begin resources
  if ! pm_unit_check_resources; then
    pm_unit_phase_end resources not_operational 3
    pm_unit_seal_result not_operational "resource_unmeasurable_or_insufficient" 3
    return 3
  fi
  export PM_UNIT_HOST_NCPU PM_UNIT_HOST_MEM
  pm_unit_phase_end resources passed 0

  # SSH reachability
  if ! on_intel "true" 2>/dev/null; then
    pm_unit_seal_result not_operational "ssh_unavailable" 3
    return 3
  fi

  pm_unit_phase_begin sdk
  if ! pm_unit_check_sdk_image; then
    pm_unit_phase_end sdk not_operational 3
    pm_unit_seal_result not_operational "sdk_image" 3
    return 3
  fi
  export PM_UNIT_SDK_IMAGE PM_UNIT_SDK_ID PM_UNIT_SDK_EXPECTED_VER
  pm_unit_phase_end sdk passed 0

  pm_unit_phase_begin fingerprint
  local assets_file list_file
  assets_file="$(mktemp)"
  list_file="$(mktemp)"
  pm_unit_manifest_assets > "$assets_file"
  if ! pm_unit_build_file_list "$PM_SOLUTION_DIR" "$list_file" "$assets_file"; then
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end fingerprint not_operational 3
    pm_unit_seal_result not_operational "required_asset_missing" 3
    return 3
  fi
  PM_UNIT_SOURCE_FP="$(pm_unit_fingerprint_from_list "$PM_SOLUTION_DIR" "$list_file")"
  PM_UNIT_ASSETS_FP="$(pm_unit_assets_fingerprint "$PM_SOLUTION_DIR")"
  PM_UNIT_WORKSPACE_KEY="$(pm_unit_workspace_key "$PM_SOLUTION_DIR")"
  PM_UNIT_DEPENDENCY_KEY="$(pm_unit_dependency_key "$PM_SOLUTION_DIR")"
  export PM_UNIT_SOURCE_FP PM_UNIT_ASSETS_FP PM_UNIT_WORKSPACE_KEY PM_UNIT_DEPENDENCY_KEY
  printf '%s\n' "$PM_UNIT_SOURCE_FP" > "$PM_UNIT_EVIDENCE_DIR/source-manifests/source_before.txt"
  printf '%s\n' "$PM_UNIT_ASSETS_FP" > "$PM_UNIT_EVIDENCE_DIR/source-manifests/assets_before.txt"
  pm_unit_phase_end fingerprint passed 0

  pm_unit_phase_begin sync
  pm_unit_prepare_remote_workspace "$PM_UNIT_WORKSPACE_KEY"
  if ! pm_unit_sync_source "$list_file"; then
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "sync_failed" 3
    return 3
  fi
  # Re-fingerprint local post-sync (árbol no debe haber cambiado)
  local source_after
  source_after="$(pm_unit_fingerprint_from_list "$PM_SOLUTION_DIR" "$list_file")"
  if [ "$source_after" != "$PM_UNIT_SOURCE_FP" ]; then
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "source_changed_during_sync" 3
    return 3
  fi
  if ! pm_unit_remote_fingerprint; then
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "remote_source_mismatch" 3
    return 3
  fi
  if [ "$PM_UNIT_REMOTE_SOURCE_FP" != "$PM_UNIT_SOURCE_FP" ]; then
    pm_unit_log "remote_source_mismatch local=$PM_UNIT_SOURCE_FP remote=$PM_UNIT_REMOTE_SOURCE_FP"
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "remote_source_mismatch" 3
    return 3
  fi
  if [ "$PM_UNIT_REMOTE_ASSETS_FP" != "$PM_UNIT_ASSETS_FP" ]; then
    pm_unit_log "asset_identity_mismatch local=$PM_UNIT_ASSETS_FP remote=$PM_UNIT_REMOTE_ASSETS_FP"
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "asset_identity_mismatch" 3
    return 3
  fi
  if [ "${PM_UNIT_REMOTE_CONTAINERS_N:-0}" != "4" ]; then
    pm_unit_log "unexpected_container_asset n=$PM_UNIT_REMOTE_CONTAINERS_N"
    rm -f "$assets_file" "$list_file"
    pm_unit_phase_end sync not_operational 3
    pm_unit_seal_result not_operational "unexpected_container_asset" 3
    return 3
  fi
  pm_unit_phase_end sync passed 0
  rm -f "$assets_file" "$list_file"

  # M2/S2: identidad real del build-seal (source/assets/recipe/SDK/dependency_key), no solo su presencia.
  # Sin match exacto de TODO -> o es cambio estructural (dependency_key distinto)/seal ausente-corrupto
  # (frio: limpia bin/obj) o es cambio ordinario de contenido (tibio incremental: bumpea mtime de lo
  # transferido para que dotnet build --no-restore no confie en un mtime preservado por rsync).
  pm_unit_phase_begin build_seal
  PM_UNIT_RECIPE_FP="$(pm_unit_recipe_fingerprint)"
  export PM_UNIT_RECIPE_FP
  local seal_remote="$PM_UNIT_REMOTE_STATE/build-seal.json"
  local seal_json
  seal_json="$(on_intel "cat '$seal_remote' 2>/dev/null" || true)"
  # OJO bash/python: `printf seal_json | python3 - <<'PY'` es un bug real hallado en esta ronda —
  # `python3 -` lee su PROPIO script desde stdin, así que el heredoc AGOTA stdin antes de que el
  # cuerpo del script llegue a `sys.stdin.read()`: ese read() siempre devuelve "" y el seal se trata
  # como ausente en TODA corrida (state_class quedaba fijo en "cold" incluso con seal idéntico
  # verificado). seal_json se pasa por argv, no por stdin.
  PM_UNIT_STATE_CLASS="$(python3 - "$seal_json" "$PM_UNIT_DEPENDENCY_KEY" "$PM_UNIT_SOURCE_FP" "$PM_UNIT_ASSETS_FP" "$PM_UNIT_RECIPE_FP" "$PM_UNIT_SDK_ID" <<'PY'
import json, sys
seal_json = sys.argv[1]
dep_key, src_fp, assets_fp, recipe_fp, sdk_id = sys.argv[2:7]
try:
    d = json.loads(seal_json) if seal_json.strip() else {}
except Exception:
    d = {}
if d.get("state") != "complete":
    print("cold")
elif d.get("dependency_key") != dep_key:
    print("cold")
elif (d.get("source_fingerprint") == src_fp and d.get("assets_fingerprint") == assets_fp
      and d.get("recipe_fingerprint") == recipe_fp and d.get("sdk_image_id") == sdk_id):
    print("warm_unchanged")
else:
    print("warm_incremental")
PY
)"
  export PM_UNIT_STATE_CLASS
  case "$PM_UNIT_STATE_CLASS" in
    cold)
      pm_unit_log "build_seal: cold (seal ausente/incompleto/dependency_key distinto) -> limpia bin/obj"
      pm_unit_clean_stale_build_outputs || true
      ;;
    warm_incremental)
      pm_unit_log "build_seal: warm_incremental -> bumpea mtime de transferidos (mitigacion mtime rsync)"
      pm_unit_touch_transferred "$PM_UNIT_EVIDENCE_DIR/sync-delta.txt"
      ;;
    warm_unchanged)
      pm_unit_log "build_seal: warm_unchanged (identidad exacta con el ultimo build sellado)"
      ;;
  esac
  pm_unit_phase_end build_seal passed 0
  PM_UNIT_COMPARABLE=true
  export PM_UNIT_COMPARABLE

  pm_unit_phase_begin unit_arch_macdata
  # OJO bash: `local x=$?` pisa $? con 0. Capturar en dos pasos.
  local unit_rc=0
  set +e
  pm_unit_run_remote_pipeline "$PM_UNIT_DEPENDENCY_KEY"
  unit_rc=$?
  set +e
  # Sellar SIEMPRE en modo unit (también ante rojo N-08 u otros), sin depender de set -e.
  # M3 (bug real hallado en esta ronda): un `set -e` aquí, justo antes del `return`, RE-ENCIENDE
  # errexit globalmente; como pm_gate_macdata_run llama a esta función bajo su propio `set +e ...
  # unit_rc=$? ... set -e`, ese re-encendido se "filtra" hacia el caller y aborta el proceso ANTES de
  # que `unit_rc=$?` del caller llegue a ejecutarse (verificado empíricamente) — el gate nunca llega a
  # marcar slot_setup/integration como not_run ni a sellar con reason_code=unit_failed_failfast; el
  # resultado queda solo con el fallback genérico de S3. -e permanece OFF al retornar; cada caller
  # (cmd_unit sin wrapper, pm_gate_macdata_run con su propio `set +e/set -e`) ya gobierna su -e.
  if [ "$unit_rc" -eq 0 ]; then
    pm_unit_phase_end unit_arch_macdata passed 0
    if [ "$mode" = "unit" ]; then
      pm_unit_seal_result passed "ok" 0
    fi
    return 0
  fi
  if [ "$unit_rc" -eq 3 ]; then
    pm_unit_phase_end unit_arch_macdata not_operational 3
    if [ "$mode" = "unit" ]; then
      pm_unit_seal_result not_operational "unit_pipeline" 3
    fi
    return 3
  fi
  pm_unit_phase_end unit_arch_macdata failed 1
  if [ "$mode" = "unit" ]; then
    pm_unit_seal_result failed "unit_tests" 1
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Gate canónico: unit → (fail-fast) → wt-up → integration only
# ---------------------------------------------------------------------------
pm_gate_macdata_run() {
  local run_id="${GATE_RUN_ID:-gate-$(pm_unit_now_utc)-$$}"
  if ! pm_unit_validate_run_id "$run_id"; then
    echo "[pm-gate] invalid_invocation: GATE_RUN_ID inseguro: $run_id" >&2
    return 2
  fi

  # Rechaza filtros públicos antes de abrir evidencia.
  # TESTPROJECT del caller se rechaza; el gate fija el interno después.
  if [ -n "${FILTER:-}" ] || [ -n "${PM_TEST_FILTER:-}" ]; then
    echo "[pm-gate] invalid_invocation: FILTER no se admite" >&2
    return 2
  fi
  if [ -n "${TESTPROJECT:-}" ]; then
    echo "[pm-gate] invalid_invocation: TESTPROJECT no se admite en el cierre canonico" >&2
    return 2
  fi
  # Limpia PM_TEST_PROJECT heredado del entorno para no confundir validación unitaria.
  unset PM_TEST_PROJECT PM_TEST_FILTER FILTER TESTPROJECT

  pm_unit_force_macdata || return $?
  pm_unit_open_evidence gate "$run_id"
  export PM_UNIT_EVIDENCE_DIR PM_UNIT_LOG PM_UNIT_PHASES_JSONL PM_UNIT_PROJECTS_JSONL
  export PM_UNIT_RUN_ID PM_UNIT_MODE PM_UNIT_STARTED_MS PM_UNIT_STARTED_ISO

  pm_unit_log "gate start run_id=$run_id WT=${WT:-}"

  # 1) Unitarias primero (fail-fast antes de wt-up).
  # mode=gate: la fase unit NO sella el bundle final (lo hace el gate); reutiliza evidencia ya abierta.
  local unit_rc
  set +e
  UNIT_RUN_ID="$run_id" pm_unit_macdata_run gate "$run_id"
  unit_rc=$?
  set -e

  if [ "$unit_rc" -ne 0 ]; then
    pm_unit_phase_not_run slot_setup "unit_failed"
    pm_unit_phase_not_run integration_prepare "unit_failed"
    pm_unit_phase_not_run integration_test "unit_failed"
    local st=failed
    [ "$unit_rc" -eq 2 ] && st=invalid_invocation
    [ "$unit_rc" -eq 3 ] && st=not_operational
    [ "$unit_rc" -ge 128 ] && st=interrupted
    pm_unit_seal_result "$st" "unit_failed_failfast" "$unit_rc"
    return "$unit_rc"
  fi

  # 2) wt-up ORACLE=1
  pm_unit_phase_begin slot_setup
  # Asegura worktrees.sh
  if ! type cmd_wt_up >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "$BASE_DIR/lib/worktrees.sh"
  fi
  set +e
  # Fuerza intel/macdata/full/oracle
  PM_TARGET=intel PM_REMOTE_SSH=macdata PM_PROFILE=full PM_WT_ORACLE=1 ORACLE=1 \
    cmd_wt_up 2>&1 | tee -a "$PM_UNIT_LOG"
  local up_rc=${PIPESTATUS[0]:-$?}
  set -e
  if [ "$up_rc" -ne 0 ]; then
    pm_unit_phase_end slot_setup failed "$up_rc"
    pm_unit_phase_not_run integration_prepare "slot_setup_failed"
    pm_unit_phase_not_run integration_test "slot_setup_failed"
    pm_unit_seal_result failed "slot_setup" 1
    return 1
  fi
  pm_unit_phase_end slot_setup passed 0

  # 3) Integración limpia: solo PL.PM.IntegrationTests.
  # S1: integration_prepare/integration_test abren y cierran sus propias fases DENTRO del helper
  # (con timestamps reales), así que aquí solo se invoca directo (sin pipe/subshell: un pipe perdería
  # las variables que el helper exporta para M1, p.ej. PM_UNIT_INTEGRATION_JSON). cmd_test ya vuelca
  # su output a PM_UNIT_LOG vía PM_TEST_LOG_SINK; no hace falta un segundo tee aquí.
  local int_rc=0
  set +e
  pm_gate_run_integration_physical
  int_rc=$?
  set -e
  if [ "$int_rc" -eq 0 ]; then
    pm_unit_seal_result passed "ok" 0
    return 0
  else
    pm_unit_seal_result failed "integration_test" 1
    return 1
  fi
}

pm_gate_parse_integration_trx() {
  # Parser de los Counters del TRX (mismo patrón sed/grep ya probado en
  # remote-intel/pm-unit-runner.sh:parse_trx — NO usa python xml.etree: en esta Mac el python3 de
  # Homebrew tiene pyexpat roto (dlopen falla por mismatch de libexpat), verificado en esta ronda; el
  # parser de texto sobre el propio XML evita esa fragilidad de ambiente sin depender de un módulo).
  # Salida: "total executed skipped failed" (failed = failed+error+timeout+aborted). Un TRX
  # ausente/malformado/sin Counters imprime "0 0 0 1" (fuerza mismatch/rojo, nunca verde vacuo).
  local trx="$1"
  [ -f "$trx" ] || { printf '0 0 0 1'; return 0; }
  local counters
  counters="$(tr '\n' ' ' < "$trx" | sed -n 's/.*<Counters\([^>]*\)\/>.*/\1/p' | head -1)"
  if [ -z "$counters" ]; then
    counters="$(tr '\n' ' ' < "$trx" | sed -n 's/.*<Counters\([^>]*\)>.*/\1/p' | head -1)"
  fi
  if [ -z "$counters" ]; then
    printf '0 0 0 1'
    return 0
  fi
  local total executed failed error timeout aborted not_executed
  total="$(printf '%s' "$counters" | sed -n 's/.*total="\([0-9]*\)".*/\1/p')"
  executed="$(printf '%s' "$counters" | sed -n 's/.*executed="\([0-9]*\)".*/\1/p')"
  failed="$(printf '%s' "$counters" | sed -n 's/.*failed="\([0-9]*\)".*/\1/p')"
  error="$(printf '%s' "$counters" | sed -n 's/.*error="\([0-9]*\)".*/\1/p')"
  timeout="$(printf '%s' "$counters" | sed -n 's/.*timeout="\([0-9]*\)".*/\1/p')"
  aborted="$(printf '%s' "$counters" | sed -n 's/.*aborted="\([0-9]*\)".*/\1/p')"
  not_executed="$(printf '%s' "$counters" | sed -n 's/.*notExecuted="\([0-9]*\)".*/\1/p')"
  total=${total:-0}; executed=${executed:-0}; failed=${failed:-0}
  error=${error:-0}; timeout=${timeout:-0}; aborted=${aborted:-0}; not_executed=${not_executed:-0}
  local skipped
  if [ "$not_executed" -gt 0 ]; then skipped=$not_executed; else skipped=$((total - executed)); fi
  [ "$skipped" -ge 0 ] || skipped=0
  printf '%s %s %s %s' "$total" "$executed" "$skipped" "$((failed + error + timeout + aborted))"
}

pm_gate_run_integration_physical() {
  # Helper privado: cuerpo físico de test-clean sin re-ejecutar unitarias ni PL.PM.sln.
  # Fuerza PM_TEST_PROJECT a IntegrationTests. Fases propias (S1): integration_prepare cubre
  # resolución/slot/migración; integration_test cubre solo la invocación real de dotnet test.
  pm_unit_phase_begin integration_prepare
  if ! type wt_resolve_folder >/dev/null 2>&1; then
    # shellcheck disable=SC1090
    . "$BASE_DIR/lib/worktrees.sh"
  fi
  local gate_folder gate_abs gate_short gate_slot
  gate_folder="$(wt_resolve_folder)" || { pm_unit_phase_end integration_prepare failed 2; return 2; }
  gate_abs="$(pm_resolve_worktree_dir "$gate_folder")" || { pm_unit_phase_end integration_prepare failed 2; return 2; }
  gate_short="$(basename "$gate_abs")"
  gate_slot="$(wt_slot_lookup "$gate_folder")"
  if [ -z "$gate_slot" ]; then gate_slot="$(wt_slot_lookup "$gate_abs")"; [ -n "$gate_slot" ] && gate_folder="$gate_abs"; fi
  if [ -z "$gate_slot" ]; then gate_slot="$(wt_slot_lookup "$gate_short")"; [ -n "$gate_slot" ] && gate_folder="$gate_short"; fi
  if [ -z "$gate_slot" ]; then
    pm_unit_log "integration: sin slot para $gate_abs"
    pm_unit_phase_end integration_prepare failed 2
    return 2
  fi
  WT="$gate_folder"
  wt_require_intel || { pm_unit_phase_end integration_prepare failed 1; return 1; }

  # Warm reuse si sano
  if [ "${PM_WT_WARM:-1}" = "1" ]; then
    wt_derive "$gate_slot"
    if on_intel "curl -fsS -o /dev/null http://127.0.0.1:$PM_API_PORT/health/live" 2>/dev/null && wt_oracle_running; then
      WT_ORACLE_ACTIVE=1
      pm_unit_log "WARM slot $gate_slot sano -> reusa aprovisionamiento"
    else
      pm_unit_log "WARM pero slot no sano -> wt-up"
      cmd_wt_up || { pm_unit_phase_end integration_prepare failed 1; return 1; }
    fi
  else
    cmd_wt_up || { pm_unit_phase_end integration_prepare failed 1; return 1; }
  fi

  if [ "${WT_ORACLE_ACTIVE:-0}" != "1" ]; then
    pm_unit_log "Oracle del slot no activo"
    pm_unit_phase_end integration_prepare failed 2
    return 2
  fi

  local m1host="$PM_TEST_SQL_HOST"
  case "$m1host" in macdata) : ;; esac
  case "$m1host" in ""|127.0.0.1|localhost|macdata) m1host="macbook-pro-de-diana.local" ;; esac
  local bport pw; bport="$(wt_bridge_port)"
  wt_bridge_up || { pm_unit_phase_end integration_prepare failed 1; return 1; }
  pw="$(wt_shared_sql_password)" || { pm_unit_phase_end integration_prepare failed 1; return 1; }
  PM_TEST_SQL_HOST="$m1host"; PM_SQL_HOST_PORT="$bport"; PM_SQL_SA_PASSWORD="$pw"
  PM_SERVICEBUS_HOST="$m1host"; PM_SB_HOST_PORT="$PM_WT_BUS_HOST_PORT"; PM_API_HOST="$m1host"
  pm_ef_migrate "$(pm_planning_connstr)" || { pm_unit_phase_end integration_prepare failed 1; return 1; }
  pm_unit_phase_end integration_prepare passed 0

  # Fija corpus de integración (única vez). Sink de log del gate.
  export PM_GATE_INTERNAL=1
  export PM_TEST_PROJECT="tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj"
  unset PM_TEST_FILTER
  # cmd_test con log redirigido al sink del gate si se exporta PM_TEST_LOG_SINK
  export PM_TEST_LOG_SINK="$PM_UNIT_LOG"

  # M1: TRX propio + --settings (TreatNoTestsAsError) para exigir conteos REALES, nunca hardcodeados.
  local trx_dir="$PM_UNIT_EVIDENCE_DIR/trx/integration"
  rm -rf "$trx_dir"; mkdir -p "$trx_dir"

  pm_unit_phase_begin integration_test
  set +e
  PM_SKIP_API=1 cmd_test \
    --settings "$BASE_DIR/$PM_UNIT_RUNSETTINGS_REL" \
    --logger "trx;LogFileName=integration.trx" \
    --results-directory "$trx_dir"
  local rc=$?
  # M3 (mismo hallazgo que en pm_unit_macdata_run): NO reactivar -e aquí. pm_gate_macdata_run llama a
  # este helper bajo `set +e ... int_rc=$? ... set -e`; si esta función reactivara errexit antes de
  # sus `return` finales, el re-encendido se filtraría al caller (global, no por-función) y abortaría
  # el proceso antes de que `int_rc=$?` se ejecutara. -e permanece OFF hasta que el caller lo reactiva.

  local exp_total exp_exec exp_skip
  exp_total="$(pm_unit_manifest_field integration_expected_total)"
  exp_exec="$(pm_unit_manifest_field integration_expected_executed)"
  exp_skip="$(pm_unit_manifest_field integration_expected_skipped)"

  local trx_n trx_path total=0 executed=0 skipped=0 failed=1 match=0
  trx_n="$(find "$trx_dir" -name '*.trx' -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${trx_n:-0}" = "1" ]; then
    trx_path="$(find "$trx_dir" -name '*.trx' -type f 2>/dev/null | head -1)"
    local counts
    counts="$(pm_gate_parse_integration_trx "$trx_path")"
    total="$(printf '%s' "$counts" | awk '{print $1}')"
    executed="$(printf '%s' "$counts" | awk '{print $2}')"
    skipped="$(printf '%s' "$counts" | awk '{print $3}')"
    failed="$(printf '%s' "$counts" | awk '{print $4}')"
  else
    trx_path=""
    pm_unit_log "integration evidence_invalid: TRX encontrados=$trx_n (esperado 1) en $trx_dir"
  fi

  # Cualquier diferencia de conteos invalida el verde, incluso si dotnet retornó 0 (AC de T-008).
  if [ "$rc" -eq 0 ] && [ "$total" -gt 0 ] && [ "$total" = "$exp_total" ] \
     && [ "$executed" = "$exp_exec" ] && [ "$skipped" = "$exp_skip" ] && [ "$failed" -eq 0 ]; then
    match=1
  else
    pm_unit_log "integration mismatch/rojo: total=$total/$exp_total executed=$executed/$exp_exec skipped=$skipped/$exp_skip failed=$failed rc=$rc"
  fi

  PM_UNIT_INTEGRATION_JSON="$(python3 - "${trx_path:-}" "$rc" "$total" "$executed" "$skipped" "$failed" "$exp_total" "$exp_exec" "$exp_skip" "$match" <<'PY'
import json, os, sys
trx, rc, total, executed, skipped, failed, exp_total, exp_exec, exp_skip, match = sys.argv[1:11]
print(json.dumps({
  "path": "tests/PL.PM.IntegrationTests/PL.PM.IntegrationTests.csproj",
  "invocation_count": 1,
  "exit_code": int(rc),
  "trx": os.path.basename(trx) if trx else None,
  "total": int(total),
  "executed": int(executed),
  "skipped": int(skipped),
  "failed": int(failed),
  "expected_total": int(exp_total),
  "expected_executed": int(exp_exec),
  "expected_skipped": int(exp_skip),
  "baseline_match": bool(int(match)),
}))
PY
)"
  export PM_UNIT_INTEGRATION_JSON

  if [ "$match" -eq 1 ]; then
    pm_unit_phase_end integration_test passed 0
    return 0
  fi
  pm_unit_phase_end integration_test failed 1
  [ "$rc" -ne 0 ] && return "$rc"
  return 1
}
