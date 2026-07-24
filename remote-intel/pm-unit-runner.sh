#!/usr/bin/env bash
# Runner remoto (dentro del contenedor SDK). Sin python (la imagen sdk no lo trae).
# Fases: restore | build-test | all
set -euo pipefail

PHASE="${1:-all}"
SOURCE="/work/source"
RUN="/work/run"
OUT="$RUN/out"
TRX_ROOT="$RUN/trx"
if [ -f "$SOURCE/pm-unit.slnf" ]; then
  SLNF="$SOURCE/pm-unit.slnf"
else
  SLNF="$RUN/pm-unit.slnf"
fi
RUNSETTINGS="$RUN/pm-unit.runsettings"
PROJECTS_FILE="$RUN/projects.txt"
SUMMARY="$OUT/summary.json"

mkdir -p "$OUT" "$TRX_ROOT"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$OUT/runner.log" >&2; }
ms_now() {
  # date +%s%3N no existe en todos los busybox; usa segundos*1000
  echo $(($(date +%s) * 1000))
}

cd "$SOURCE"

sdk_ver="$(dotnet --version 2>/dev/null || true)"
log "phase=$PHASE dotnet --version=$sdk_ver expected=${EXPECTED_SDK_VERSION:-}"
if [ -n "${EXPECTED_SDK_VERSION:-}" ] && [ "$sdk_ver" != "$EXPECTED_SDK_VERSION" ]; then
  case "$sdk_ver" in
    10.0.3*) log "sdk feature-band ok ($sdk_ver)" ;;
    *)
      log "sdk_incompatible: got=$sdk_ver expected=$EXPECTED_SDK_VERSION"
      printf '{"exit_code":3,"reason":"sdk_incompatible","sdk_version":"%s","restore_rc":1,"build_rc":1,"projects":[]}\n' "$sdk_ver" > "$SUMMARY"
      exit 3
      ;;
  esac
fi

PROJECTS=""
n_proj=0
while IFS= read -r line || [ -n "$line" ]; do
  [ -n "$line" ] || continue
  n_proj=$((n_proj + 1))
  PROJECTS="$PROJECTS$line
"
done < "$PROJECTS_FILE"

if [ "$n_proj" -ne 14 ]; then
  log "manifest_invalid: projects=$n_proj"
  printf '{"exit_code":3,"reason":"manifest_invalid","restore_rc":1,"build_rc":1,"projects":[]}\n' > "$SUMMARY"
  exit 3
fi

# Parsea TRX Counters con sed/grep (sin python/xml libs).
parse_trx() {
  local trx="$1"
  local counters
  counters="$(tr '\n' ' ' < "$trx" | sed -n 's/.*<Counters\([^>]*\)\/>.*/\1/p' | head -1)"
  if [ -z "$counters" ]; then
    counters="$(tr '\n' ' ' < "$trx" | sed -n 's/.*<Counters\([^>]*\)>.*/\1/p' | head -1)"
  fi
  local total=0 executed=0 passed=0 failed=0 error=0 timeout=0 aborted=0 not_executed=0
  total="$(printf '%s' "$counters" | sed -n 's/.*total="\([0-9]*\)".*/\1/p')"
  executed="$(printf '%s' "$counters" | sed -n 's/.*executed="\([0-9]*\)".*/\1/p')"
  passed="$(printf '%s' "$counters" | sed -n 's/.*passed="\([0-9]*\)".*/\1/p')"
  failed="$(printf '%s' "$counters" | sed -n 's/.*failed="\([0-9]*\)".*/\1/p')"
  error="$(printf '%s' "$counters" | sed -n 's/.*error="\([0-9]*\)".*/\1/p')"
  timeout="$(printf '%s' "$counters" | sed -n 's/.*timeout="\([0-9]*\)".*/\1/p')"
  aborted="$(printf '%s' "$counters" | sed -n 's/.*aborted="\([0-9]*\)".*/\1/p')"
  not_executed="$(printf '%s' "$counters" | sed -n 's/.*notExecuted="\([0-9]*\)".*/\1/p')"
  total=${total:-0}; executed=${executed:-0}; passed=${passed:-0}
  failed=${failed:-0}; error=${error:-0}; timeout=${timeout:-0}; aborted=${aborted:-0}
  not_executed=${not_executed:-0}
  local skipped failed_all
  if [ "$not_executed" -gt 0 ]; then skipped=$not_executed; else skipped=$((total - executed)); fi
  [ "$skipped" -ge 0 ] || skipped=0
  failed_all=$((failed + error + timeout + aborted))
  printf '%s %s %s %s %s' "$total" "$executed" "$skipped" "$failed_all" "$passed"
}

do_restore() {
  log "RESTORE begin slnf=$SLNF"
  t0="$(ms_now)"
  set +e
  dotnet restore "$SLNF" --nologo >"$OUT/restore.log" 2>&1
  restore_rc=$?
  set -e
  t1="$(ms_now)"
  restore_ms=$((t1 - t0))
  cat "$OUT/restore.log" >&2 || true
  echo "RESTORE rc=$restore_rc ms=$restore_ms" >> "$OUT/commands.log"
  log "RESTORE end rc=$restore_rc ms=$restore_ms"
  printf '%s' "$restore_rc" > "$OUT/restore.rc"
  printf '%s' "$restore_ms" > "$OUT/restore.ms"
  printf '%s' "$sdk_ver" > "$OUT/sdk.version"
  return "$restore_rc"
}

do_build_test() {
  restore_rc="$(cat "$OUT/restore.rc" 2>/dev/null || echo 1)"
  restore_ms="$(cat "$OUT/restore.ms" 2>/dev/null || echo 0)"
  sdk_ver="$(cat "$OUT/sdk.version" 2>/dev/null || echo "$sdk_ver")"
  if [ "$restore_rc" != "0" ]; then
    log "build-test aborted: restore_rc=$restore_rc"
    printf '{"exit_code":1,"reason":"restore_failed","sdk_version":"%s","restore_rc":%s,"build_rc":1,"projects":[]}\n' \
      "$sdk_ver" "$restore_rc" > "$SUMMARY"
    return 1
  fi

  log "BUILD begin"
  t0="$(ms_now)"
  set +e
  dotnet build "$SLNF" -c Debug --no-restore --nologo >"$OUT/build.log" 2>&1
  build_rc=$?
  set -e
  t1="$(ms_now)"
  build_ms=$((t1 - t0))
  cat "$OUT/build.log" >&2 || true
  echo "BUILD rc=$build_rc ms=$build_ms" >> "$OUT/commands.log"
  log "BUILD end rc=$build_rc ms=$build_ms"
  if [ "$build_rc" -ne 0 ]; then
    printf '{"exit_code":1,"reason":"build_failed","sdk_version":"%s","restore_rc":0,"build_rc":%s,"restore_ms":%s,"build_ms":%s,"projects":[]}\n' \
      "$sdk_ver" "$build_rc" "$restore_ms" "$build_ms" > "$SUMMARY"
    return 1
  fi

  : > "$OUT/projects.jsonl"
  idx=0
  any_fail=0
  while IFS= read -r proj || [ -n "$proj" ]; do
    [ -n "$proj" ] || continue
    idx=$((idx + 1))
    name="$(basename "$proj" .csproj)"
    trx_dir="$TRX_ROOT/$(printf '%02d' "$idx")"
    mkdir -p "$trx_dir"
    trx_name="$(printf '%02d' "$idx")-${name}.trx"
    log "TEST begin idx=$idx project=$proj"
    t0="$(ms_now)"
    set +e
    dotnet test "$SOURCE/$proj" \
      -c Debug \
      --no-build \
      --no-restore \
      --nologo \
      --settings "$RUNSETTINGS" \
      --logger "trx;LogFileName=$trx_name" \
      --results-directory "$trx_dir" \
      >"$OUT/test-$(printf '%02d' "$idx").log" 2>&1
    trc=$?
    set -e
    t1="$(ms_now)"
    dms=$((t1 - t0))
    cat "$OUT/test-$(printf '%02d' "$idx").log" >&2 || true
    echo "TEST idx=$idx project=$proj rc=$trc ms=$dms" >> "$OUT/commands.log"

    trx_path="$(find "$trx_dir" -name '*.trx' -type f 2>/dev/null | head -1 || true)"
    total=0; executed=0; skipped=0; failed=0; passed=0
    if [ -n "$trx_path" ] && [ -f "$trx_path" ]; then
      read -r total executed skipped failed passed <<EOF
$(parse_trx "$trx_path")
EOF
      cp -f "$trx_path" "$OUT/$trx_name" 2>/dev/null || true
    else
      trc=1
      any_fail=1
      log "TEST missing TRX for $proj"
    fi
    if [ "$trc" -ne 0 ] || [ "${failed:-0}" -gt 0 ] || [ "${total:-0}" -eq 0 ]; then
      any_fail=1
    fi
    log "TEST end idx=$idx rc=$trc total=$total executed=$executed skipped=$skipped failed=$failed ms=$dms"
    printf '{"index":%s,"path":"%s","exit_code":%s,"total":%s,"executed":%s,"skipped":%s,"failed":%s,"passed":%s,"duration_ms":%s,"trx":"%s","invocation_count":1}\n' \
      "$idx" "$proj" "$trc" "${total:-0}" "${executed:-0}" "${skipped:-0}" "${failed:-0}" "${passed:-0}" "$dms" "$trx_name" \
      >> "$OUT/projects.jsonl"
  done <<EOF
$PROJECTS
EOF

  exit_code=0
  [ "$any_fail" -eq 0 ] || exit_code=1

  # Ensambla summary.json sin python: concatena projects.jsonl
  {
    printf '{\n'
    printf '  "exit_code": %s,\n' "$exit_code"
    if [ "$exit_code" -eq 0 ]; then
      printf '  "reason": "ok",\n'
    else
      printf '  "reason": "test_failed",\n'
    fi
    printf '  "sdk_version": "%s",\n' "$sdk_ver"
    printf '  "restore_rc": 0,\n'
    printf '  "build_rc": 0,\n'
    printf '  "restore_ms": %s,\n' "$restore_ms"
    printf '  "build_ms": %s,\n' "$build_ms"
    printf '  "project_count": %s,\n' "$idx"
    printf '  "projects": [\n'
    first=1
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if [ "$first" -eq 1 ]; then first=0; else printf ',\n'; fi
      printf '    %s' "$line"
    done < "$OUT/projects.jsonl"
    printf '\n  ],\n'
    # aggregates
    agg_total=0; agg_exec=0; agg_skip=0; agg_fail=0
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      t="$(printf '%s' "$line" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')"
      e="$(printf '%s' "$line" | sed -n 's/.*"executed":\([0-9]*\).*/\1/p')"
      s="$(printf '%s' "$line" | sed -n 's/.*"skipped":\([0-9]*\).*/\1/p')"
      f="$(printf '%s' "$line" | sed -n 's/.*"failed":\([0-9]*\).*/\1/p')"
      agg_total=$((agg_total + ${t:-0}))
      agg_exec=$((agg_exec + ${e:-0}))
      agg_skip=$((agg_skip + ${s:-0}))
      agg_fail=$((agg_fail + ${f:-0}))
    done < "$OUT/projects.jsonl"
    printf '  "aggregates": {"total":%s,"executed":%s,"skipped":%s,"failed":%s}\n' \
      "$agg_total" "$agg_exec" "$agg_skip" "$agg_fail"
    printf '}\n'
  } > "$SUMMARY"

  echo complete > "$OUT/build-complete.marker"
  log "DONE exit=$exit_code projects=$idx aggregates total=$agg_total"
  return "$exit_code"
}

case "$PHASE" in
  restore) do_restore ;;
  build-test) do_build_test ;;
  all)
    do_restore || exit $?
    do_build_test || exit $?
    ;;
  *) log "unknown phase $PHASE"; exit 2 ;;
esac
