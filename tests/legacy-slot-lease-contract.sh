#!/usr/bin/env bash
# Contratos herméticos del lease-guard de legacy-build/legacy-launch/legacy-deploy (T-015; S1 de T-013/D80):
# no abre SSH, Docker, macdata ni un slot real. Fixture propia de slots.tsv (y, para slot-claim/release, de un
# WRAPPER_DIR aislado) bajo un tmpdir. C1-C10 según analisis.md §Plan de pruebas + matriz pid×heartbeat (M1 r1)
# + aserción de orden guard-antes-de-destructivo (S1 r1).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/legacy-lease-contract.XXXXXX")"
REG="$WORKDIR/slots.tsv"
ALIVE_PID=$$                       # pid vivo garantizado: este mismo proceso de test
DEAD_PID=99999999                  # pid casi con certeza inexistente (kill -0 falla)

# Heartbeats independientes del pid (M1 r1): la matriz pid vivo/muerto × hb fresco/rancio exige que el
# heartbeat se fije por caso, no hardcodeado al mismo valor para LIVE y DEAD.
# Fresco = hace ~2 min (bien dentro del TTL default 3600 s). Rancio = hace ~2 h (> TTL).
FRESH_HB="$(TZ=UTC date -u -v-2M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
STALE_HB="$(TZ=UTC date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
CREATED_OLD="$(TZ=UTC date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || TZ=UTC date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"

# row <folder> <slot> <pid> [heartbeat] — heartbeat opcional (default rancio, para no depender del reloj
# en los casos que no aislan el hb).
row(){
  local hb="${4:-$STALE_HB}"
  printf '%s\t%s\tpm-wt%s\t0\t%s\t%s\t%s\n' "$1" "$2" "$2" "$CREATED_OLD" "$3" "$hb"
}

# Invoca require_slot_lease en un subshell hermetico: sourcea legacy.sh con $1 no dispatcheable (cae al 'usage;
# exit 2' final, neutralizado con una funcion 'exit' local a la sesion de source), y SOLO ENTONCES restaura el
# 'exit' real (unset -f) antes de llamar require_slot_lease, para que SU 'exit N' termine el proceso de verdad
# (si se quedara sobrescrito, un 'exit 2' de require_slot_lease solo haria 'return' y la funcion seguiria
# cayendo al resto de la clasificacion -- exactamente el bug que este patron evita).
run_guard(){  # uso: run_guard <verb> <slot> <wt> <override> <reason> <registro-tsv>
  local verb="$1" slot="$2" wt="$3" ov="$4" reason="$5" regcontent="$6" out rc
  printf '%s' "$regcontent" > "$REG"
  out="$( cd "$ROOT" && PM_WT_REGISTRY="$REG" PM_LEGACY_SLOT="$slot" WT="$wt" \
      PM_LEGACY_LEASE_OVERRIDE="$ov" PM_LEGACY_LEASE_OVERRIDE_REASON="$reason" \
      bash -c '
        exit() { return "${1:-0}"; }
        set -- __contract__
        . ./legacy.sh >/dev/null 2>&1
        unset -f exit
        require_slot_lease '"$verb"'
      ' 2>&1 )"; rc=$?
  printf '%s\t%s' "$rc" "$out"
}

# Filas canónicas de la matriz pid × heartbeat (M1 r1).
LIVE_FRESH_ROW="$(row other-pm-wt 0 "$ALIVE_PID" "$FRESH_HB")"   # pid vivo + hb fresco
LIVE_STALE_ROW="$(row other-pm-wt 0 "$ALIVE_PID" "$STALE_HB")"   # pid vivo + hb rancio (pid protege)
DEAD_FRESH_ROW="$(row other-pm-wt 0 "$DEAD_PID" "$FRESH_HB")"    # pid muerto + hb fresco (CASO M1)
DEAD_STALE_ROW="$(row other-pm-wt 0 "$DEAD_PID" "$STALE_HB")"    # pid muerto + hb rancio = huerfano
# Alias de compatibilidad con los nombres C1-C7 previos.
LIVE_ROW="$LIVE_FRESH_ROW"
DEAD_ROW="$DEAD_STALE_ROW"

# --- C1: dueña viva ajena, sin override -> exit 3; stderr menciona folder y lease; no llega a stage ---
res="$(run_guard build 0 mi-legacy-wt 0 "" "$LIVE_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "3" ] && printf '%s' "$out" | grep -q 'other-pm-wt' && printf '%s' "$out" | grep -qi 'arrendad' \
  && ok "C1 dueña viva ajena sin override: exit 3, menciona folder" \
  || bad "C1 dueña viva ajena sin override (rc=$rc): $out"

# --- C2: dueña viva ajena + FORCE=1 sin LEASE_OVERRIDE -> exit 3 (FORCE NO bypassea el lease) ---
regfile_bak="$(cat "$REG")"; printf '%s' "$LIVE_ROW" > "$REG"
out="$( cd "$ROOT" && PM_WT_REGISTRY="$REG" PM_LEGACY_SLOT=0 WT=mi-legacy-wt PM_LEGACY_FORCE=1 bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    require_slot_lease build
  ' 2>&1 )"; rc=$?
[ "$rc" = "3" ] && ok "C2 FORCE=1 sin LEASE_OVERRIDE no bypassea el lease (rc=3)" \
  || bad "C2 FORCE=1 sin LEASE_OVERRIDE no bypassea el lease (rc=$rc): $out"

# --- C3: dueña viva + WT= folder de la fila -> allow (exit 0 del guard) ---
res="$(run_guard build 0 other-pm-wt 0 "" "$LIVE_ROW")"; rc="${res%%$'\t'*}"
[ "$rc" = "0" ] && ok "C3 folder propio permite (dueña viva, WT=folder de la fila)" \
  || bad "C3 folder propio permite (rc=$rc)"

# --- C4: sin fila en el registro para ese SLOT -> allow ---
res="$(run_guard build 3 mi-legacy-wt 0 "" "$LIVE_ROW")"; rc="${res%%$'\t'*}"   # LIVE_ROW es del slot 0, no del 3
[ "$rc" = "0" ] && ok "C4 sin fila para el SLOT pedido: permite" \
  || bad "C4 sin fila para el SLOT pedido: permite (rc=$rc)"

# --- C5: pid muerto + heartbeat RANCIO -> allow (arrendamiento huerfano; no exit 3) ---
res="$(run_guard build 0 mi-legacy-wt 0 "" "$DEAD_STALE_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "0" ] && ok "C5 pid muerto + heartbeat rancio: permite (huerfano)" \
  || bad "C5 pid muerto + heartbeat rancio (rc=$rc): $out"

# --- M1 matriz pid × heartbeat (dueña viva = pid vivo O heartbeat fresco; wt_lease_reclaimable) ---
# pid vivo + hb fresco + folder ajeno -> exit 3
res="$(run_guard build 0 mi-legacy-wt 0 "" "$LIVE_FRESH_ROW")"; rc="${res%%$'\t'*}"
[ "$rc" = "3" ] && ok "M1a pid vivo + hb fresco + folder ajeno: exit 3" \
  || bad "M1a pid vivo + hb fresco (rc=$rc)"
# pid vivo + hb rancio + folder ajeno -> exit 3 (pid protege aunque hb rancio)
res="$(run_guard build 0 mi-legacy-wt 0 "" "$LIVE_STALE_ROW")"; rc="${res%%$'\t'*}"
[ "$rc" = "3" ] && ok "M1b pid vivo + hb rancio + folder ajeno: exit 3 (pid protege)" \
  || bad "M1b pid vivo + hb rancio (rc=$rc)"
# pid muerto + hb fresco + folder ajeno -> exit 3 (CASO M1: el latido operativo es el heartbeat)
res="$(run_guard build 0 mi-legacy-wt 0 "" "$DEAD_FRESH_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "3" ] && printf '%s' "$out" | grep -q 'other-pm-wt' \
  && ok "M1c pid muerto + hb fresco + folder ajeno: exit 3 (heartbeat protege; caso M1)" \
  || bad "M1c pid muerto + hb fresco (rc=$rc): $out"
# pid muerto + hb rancio + folder ajeno -> allow (ya cubierto por C5; se reafirma en la matriz)
res="$(run_guard build 0 mi-legacy-wt 0 "" "$DEAD_STALE_ROW")"; rc="${res%%$'\t'*}"
[ "$rc" = "0" ] && ok "M1d pid muerto + hb rancio + folder ajeno: permite (huerfano)" \
  || bad "M1d pid muerto + hb rancio (rc=$rc)"
# pid muerto + hb fresco + folder PROPIO -> allow (identidad del lease)
res="$(run_guard build 0 other-pm-wt 0 "" "$DEAD_FRESH_ROW")"; rc="${res%%$'\t'*}"
[ "$rc" = "0" ] && ok "M1e pid muerto + hb fresco + folder propio: permite" \
  || bad "M1e pid muerto + hb fresco + folder propio (rc=$rc)"
# pid muerto + hb fresco + override con razon -> allow + log
res="$(run_guard build 0 mi-legacy-wt 1 "coordinado M1" "$DEAD_FRESH_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "0" ] && printf '%s' "$out" | grep -q '\[LEASE-OVERRIDE\]' \
  && ok "M1f pid muerto + hb fresco + LEASE_OVERRIDE con razon: permite" \
  || bad "M1f pid muerto + hb fresco + override (rc=$rc): $out"

# --- C6: LEASE_OVERRIDE=1 sin razon -> exit 2 (mal uso), sin llegar al resto de la clasificacion ---
res="$(run_guard build 0 mi-legacy-wt 1 "" "$LIVE_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "2" ] && ! printf '%s' "$out" | grep -q 'LEASE-OVERRIDE' \
  && ok "C6 LEASE_OVERRIDE=1 sin razon: exit 2 (no cae al override real)" \
  || bad "C6 LEASE_OVERRIDE=1 sin razon (rc=$rc): $out"

# --- C7: LEASE_OVERRIDE=1 + razon no vacia + dueña viva ajena -> allow + log [LEASE-OVERRIDE] con la razon ---
res="$(run_guard build 0 mi-legacy-wt 1 "coordinado con humano" "$LIVE_ROW")"; rc="${res%%$'\t'*}"; out="${res#*$'\t'}"
[ "$rc" = "0" ] && printf '%s' "$out" | grep -q '\[LEASE-OVERRIDE\]' && printf '%s' "$out" | grep -q 'coordinado con humano' \
  && ok "C7 LEASE_OVERRIDE=1 con razon: permite y loguea [LEASE-OVERRIDE]" \
  || bad "C7 LEASE_OVERRIDE=1 con razon (rc=$rc): $out"

# --- Singleton (SLOT vacio): el guard nuevo NO aplica (require_slot_lease retorna 0 de inmediato) ---
res="$(run_guard build "" "" 0 "" "")"; rc="${res%%$'\t'*}"
[ "$rc" = "0" ] && ok "singleton (SLOT vacio): require_slot_lease no interviene" \
  || bad "singleton (SLOT vacio): require_slot_lease no interviene (rc=$rc)"

# --- C8: require_slot sin SLOT sigue exit 2; SINGLETON=1 no pasa por el lease per-slot (no regresion) ---
out="$( cd "$ROOT" && bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    require_slot build
  ' 2>&1 )"; rc=$?
[ "$rc" = "2" ] && ok "C8a require_slot sin SLOT/SINGLETON sigue exit 2 (sin regresion)" \
  || bad "C8a require_slot sin SLOT/SINGLETON (rc=$rc): $out"
out="$( cd "$ROOT" && PM_LEGACY_SINGLETON=1 bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    require_slot build
    echo "AFTER_REQUIRE_SLOT_RC=$?"
  ' 2>&1 )"; rc=$?
echo "$out" | grep -q 'AFTER_REQUIRE_SLOT_RC=0' && echo "$out" | grep -qi 'VIA LEGADA' \
  && ok "C8b SINGLETON=1 sigue permitiendo (avisa VIA LEGADA); SLOT vacio => require_slot_lease fuera de alcance" \
  || bad "C8b SINGLETON=1 (rc=$rc): $out"

# --- C9: README documenta legacy-slot-claim y que FORCE no es el lease override ---
grep -q 'legacy-slot-claim' "$ROOT/README.md" && ok "README menciona legacy-slot-claim" || bad "README menciona legacy-slot-claim"
grep -qi 'FORCE.*no.*override\|FORCE.*NO es\|lease.*override.*FORCE\|distinto de.*FORCE' "$ROOT/README.md" \
  && ok "README documenta que FORCE no es el lease override" \
  || bad "README documenta que FORCE no es el lease override"

# --- C10: e2e_legacy_launch pasa WT= (o equivalente) al make de legacy-launch (cableado, no regresion e2e-up) ---
E2E_BODY="$(sed -n '/^e2e_legacy_launch(){/,/^}/p' "$ROOT/scripts/e2e.sh")"
[ -n "$E2E_BODY" ] && ok "cuerpo de e2e_legacy_launch extraido" || bad "cuerpo de e2e_legacy_launch extraido"
printf '%s\n' "$E2E_BODY" | grep -qE 'make -C "\$BASE_DIR" legacy-launch' && ok "e2e_legacy_launch invoca legacy-launch" || bad "e2e_legacy_launch invoca legacy-launch"
printf '%s\n' "$E2E_BODY" | grep -qE 'WT="\$WT"' \
  && ok "C10 e2e_legacy_launch pasa WT=\$WT explicito al make de legacy-launch (afirma identidad del lease)" \
  || bad "C10 e2e_legacy_launch pasa WT= explicito"

# --- require_slot_lease queda cableado en build/launch/deploy, DESPUES de require_slot y ANTES de
#     guest_turn_acquire/stage_build/deploy (S1 r1: posición relativa, no solo presencia) ---
DISPATCH="$(sed -n '/^case "\${1:-}" in/,/^esac/p' "$ROOT/legacy.sh")"
[ -n "$DISPATCH" ] && ok "bloque de dispatch extraido" || bad "bloque de dispatch extraido"
for verb in launch build deploy; do
  line="$(printf '%s\n' "$DISPATCH" | grep -E "^  ${verb}\\)")"
  echo "$line" | grep -q 'require_slot_lease' && ok "dispatch de '$verb' invoca require_slot_lease" || bad "dispatch de '$verb' invoca require_slot_lease: $line"
  rs_pos="$(printf '%s' "$line" | grep -bo 'require_slot ' | head -1 | cut -d: -f1)"
  rsl_pos="$(printf '%s' "$line" | grep -bo 'require_slot_lease' | head -1 | cut -d: -f1)"
  if [ -n "$rs_pos" ] && [ -n "$rsl_pos" ] && [ "$rs_pos" -lt "$rsl_pos" ]; then
    ok "'$verb': require_slot corre ANTES de require_slot_lease"
  else
    bad "'$verb': require_slot corre ANTES de require_slot_lease (rs=${rs_pos:-?} rsl=${rsl_pos:-?})"
  fi
  # S1: require_slot_lease ANTES de todo efecto destructivo presente en la línea del dispatch.
  # build: guest_turn_acquire + stage_build en la misma línea.
  # deploy: guest_turn_acquire + deploy (el verbo de efecto) en la misma línea.
  # launch: la línea solo invoca launch() (el cuerpo de launch() hace guest_turn/stage/deploy DESPUÉS);
  #         se exige que require_slot_lease aparezca antes de la invocación final de launch.
  case "$verb" in
    build)
      for tok in guest_turn_acquire stage_build; do
        tok_pos="$(printf '%s' "$line" | grep -bo "$tok" | head -1 | cut -d: -f1)"
        if [ -n "$rsl_pos" ] && [ -n "$tok_pos" ] && [ "$rsl_pos" -lt "$tok_pos" ]; then
          ok "'$verb': require_slot_lease corre ANTES de $tok"
        else
          bad "'$verb': require_slot_lease corre ANTES de $tok (rsl=${rsl_pos:-?} $tok=${tok_pos:-?})"
        fi
      done
      ;;
    deploy)
      gta_pos="$(printf '%s' "$line" | grep -bo 'guest_turn_acquire' | head -1 | cut -d: -f1)"
      if [ -n "$rsl_pos" ] && [ -n "$gta_pos" ] && [ "$rsl_pos" -lt "$gta_pos" ]; then
        ok "'$verb': require_slot_lease corre ANTES de guest_turn_acquire"
      else
        bad "'$verb': require_slot_lease corre ANTES de guest_turn_acquire (rsl=${rsl_pos:-?} gta=${gta_pos:-?})"
      fi
      # El efecto 'deploy' tras guest_turn: primera ocurrencia de 'deploy' DESPUÉS de guest_turn_acquire.
      # (require_slot deploy / require_slot_lease deploy también contienen la palabra).
      dep_after="$(printf '%s' "$line" | grep -bo 'guest_turn_acquire; deploy' | head -1 | cut -d: -f1)"
      if [ -n "$rsl_pos" ] && [ -n "$dep_after" ] && [ "$rsl_pos" -lt "$dep_after" ]; then
        ok "'$verb': require_slot_lease corre ANTES del deploy de efecto"
      else
        bad "'$verb': require_slot_lease corre ANTES del deploy de efecto (rsl=${rsl_pos:-?} dep=${dep_after:-?})"
      fi
      ;;
    launch)
      # Orden en la línea: require_slot_lease launch; launch
      if printf '%s' "$line" | grep -qE 'require_slot_lease[[:space:]]+launch;[[:space:]]*launch'; then
        ok "'$verb': require_slot_lease corre ANTES de invocar launch()"
      else
        bad "'$verb': require_slot_lease corre ANTES de invocar launch(): $line"
      fi
      # Cuerpo de launch(): guest_turn_acquire y stage_build deben existir (el guard en dispatch es antes de la fn).
      LAUNCH_BODY="$(sed -n '/^launch(){/,/^}/p' "$ROOT/legacy.sh")"
      printf '%s\n' "$LAUNCH_BODY" | grep -q 'guest_turn_acquire' \
        && ok "'$verb': launch() invoca guest_turn_acquire (despues del guard del dispatch)" \
        || bad "'$verb': launch() invoca guest_turn_acquire"
      printf '%s\n' "$LAUNCH_BODY" | grep -q 'stage_build' \
        && ok "'$verb': launch() invoca stage_build (despues del guard del dispatch)" \
        || bad "'$verb': launch() invoca stage_build"
      ;;
  esac
done

# --- Makefile: LEASE_OVERRIDE/LEASE_OVERRIDE_REASON propagados por LEGACY_ENV; targets slot-claim/release ---
grep -qE '^LEASE_OVERRIDE\b' "$ROOT/Makefile" && ok "Makefile declara LEASE_OVERRIDE" || bad "Makefile declara LEASE_OVERRIDE"
grep -qE '^LEASE_OVERRIDE_REASON\b' "$ROOT/Makefile" && ok "Makefile declara LEASE_OVERRIDE_REASON" || bad "Makefile declara LEASE_OVERRIDE_REASON"
LEGACY_ENV_BODY="$(grep -A6 '^LEGACY_ENV =' "$ROOT/Makefile")"
printf '%s\n' "$LEGACY_ENV_BODY" | grep -q 'PM_LEGACY_LEASE_OVERRIDE=\$(LEASE_OVERRIDE)' \
  && ok "LEGACY_ENV propaga PM_LEGACY_LEASE_OVERRIDE" || bad "LEGACY_ENV propaga PM_LEGACY_LEASE_OVERRIDE"
printf '%s\n' "$LEGACY_ENV_BODY" | grep -q 'PM_LEGACY_LEASE_OVERRIDE_REASON=' \
  && ok "LEGACY_ENV propaga PM_LEGACY_LEASE_OVERRIDE_REASON" || bad "LEGACY_ENV propaga PM_LEGACY_LEASE_OVERRIDE_REASON"
grep -qE '^legacy-slot-claim:' "$ROOT/Makefile" && ok "Makefile define legacy-slot-claim" || bad "Makefile define legacy-slot-claim"
grep -qE '^legacy-slot-release:' "$ROOT/Makefile" && ok "Makefile define legacy-slot-release" || bad "Makefile define legacy-slot-release"
# .PHONY es una directiva multi-linea (continuada con '\'); se extrae el bloque completo antes de buscar.
PHONY_BODY="$(awk '/^\.PHONY:/{p=1} p{print; if ($0 !~ /\\$/) exit}' "$ROOT/Makefile")"
printf '%s\n' "$PHONY_BODY" | grep -q 'legacy-slot-claim' && ok "legacy-slot-claim en .PHONY" || bad "legacy-slot-claim en .PHONY"
printf '%s\n' "$PHONY_BODY" | grep -q 'legacy-slot-release' && ok "legacy-slot-release en .PHONY" || bad "legacy-slot-release en .PHONY"

# --- slot-claim / slot-release: WRAPPER_DIR y registro aislados en el WORKDIR (fixture propia; sin tocar
#     worktrees/ real ni .worktrees/slots.tsv real) ---
FX="$WORKDIR/fixture-wrapper"
mkdir -p "$FX/gs-pl-pm-macops-sidecar" "$FX/worktrees/legacy-solo-wt"
: > "$FX/worktrees/legacy-solo-wt/ProgramaMaestroPT.sln"
FXREG="$WORKDIR/fixture-slots.tsv"

out="$( cd "$ROOT" && PM_WRAPPER_DIR="$FX" PM_WT_REGISTRY="$FXREG" bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    slot_claim
  ' 2>&1 )"; rc=$?
[ "$rc" = "2" ] && ok "slot-claim sin WT: exit 2" || bad "slot-claim sin WT (rc=$rc): $out"

out="$( cd "$ROOT" && PM_WRAPPER_DIR="$FX" PM_WT_REGISTRY="$FXREG" WT=folder-sin-marcador bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    slot_claim
  ' 2>&1 )"; rc=$?
[ "$rc" = "2" ] && printf '%s' "$out" | grep -qi 'ProgramaMaestroPT.sln' \
  && ok "slot-claim con WT sin ProgramaMaestroPT.sln: exit 2" \
  || bad "slot-claim con WT sin marcador (rc=$rc): $out"

out="$( cd "$ROOT" && PM_WRAPPER_DIR="$FX" PM_WT_REGISTRY="$FXREG" WT=legacy-solo-wt bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    slot_claim
  ' 2>&1 )"; rc=$?
claimed_slot="$(awk -F'\t' -v f=legacy-solo-wt '$1==f{print $2; exit}' "$FXREG" 2>/dev/null)"
[ "$rc" = "0" ] && [ -n "$claimed_slot" ] \
  && ok "slot-claim con marcador valido: rc=0, fila persistida en el registro (slot=$claimed_slot)" \
  || bad "slot-claim con marcador valido (rc=$rc, fila='$claimed_slot')"

# El slot reclamado (folder propio) DEBE pasar el guard de lease sin override — incluso con pid del claim
# ya muerto y heartbeat fresco (M1: dueña viva por hb; la identidad del folder propio lo autoriza).
res="$(run_guard build "$claimed_slot" legacy-solo-wt 0 "" "$(cat "$FXREG" 2>/dev/null)")"
rc="${res%%$'\t'*}"
[ -n "$claimed_slot" ] && [ "$rc" = "0" ] && ok "slot reclamado por slot-claim pasa el guard como folder propio" \
  || bad "slot reclamado por slot-claim pasa el guard (rc=${rc:-?})"

# slot-release del mismo folder libera la fila (pid propio: la corrida del claim y del release son el MISMO
# owner_pid solo si el proceso es el mismo; aqui cada 'bash -c' es un proceso nuevo, asi que el pid de la fila
# NO coincide con $$ del release -- pero como ese pid (el del claim, ya terminado) esta MUERTO, slot_release
# lo permite (slot_release solo gatea por pid vivo, no por heartbeat — fuera del charter M1 del guard de build).
out="$( cd "$ROOT" && PM_WRAPPER_DIR="$FX" PM_WT_REGISTRY="$FXREG" WT=legacy-solo-wt bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    slot_release
  ' 2>&1 )"; rc=$?
still_there="$(awk -F'\t' -v f=legacy-solo-wt '$1==f{print $2; exit}' "$FXREG" 2>/dev/null)"
[ "$rc" = "0" ] && [ -z "$still_there" ] && ok "slot-release libera la fila del registro" \
  || bad "slot-release libera la fila (rc=$rc, aun presente='${still_there:-<vacio>}')"

# --- Regresion del camino canonico e2e-up: simula 'wt-up WT=<pm-wt>' asignando la fila con wt_slot_assign (el
#     MISMO helper que usa cmd_wt_up), y confirma que 'legacy-launch SLOT=<N> WT=<pm-wt>' (el WT que
#     e2e_legacy_launch ahora pasa, C10) pasa el guard sin override -- e2e-up no queda roto bajo el guard nuevo. ---
E2EREG="$WORKDIR/e2e-up-slots.tsv"
out="$( cd "$ROOT" && PM_WT_REGISTRY="$E2EREG" bash -c '
    exit() { return "${1:-0}"; }
    set -- __contract__
    . ./legacy.sh >/dev/null 2>&1
    unset -f exit
    wt_registry_lock wt_slot_assign wtpm-worktree ""
  ' 2>&1 )"
e2e_slot="$out"
res="$(run_guard launch "$e2e_slot" wtpm-worktree 0 "" "$(cat "$E2EREG" 2>/dev/null)")"
rc="${res%%$'\t'*}"
[ -n "$e2e_slot" ] && [ "$rc" = "0" ] \
  && ok "camino canonico e2e-up: wt-up asigna el slot ($e2e_slot) y legacy-launch WT=<mismo folder> pasa el guard" \
  || bad "camino canonico e2e-up (slot='${e2e_slot:-<vacio>}', rc=${rc:-?})"

echo "----"
echo "PASS=$pass FAIL=$fail"
# EXIT=0 si todo paso; 1 si hubo fallos (el script termina con ese codigo).
if [ "$fail" -eq 0 ]; then
  echo "EXIT=0"
  exit 0
fi
echo "EXIT=1"
exit 1
