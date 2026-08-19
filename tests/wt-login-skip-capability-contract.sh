#!/usr/bin/env bash
# Contratos hermeticos de la perilla login-skip-password del slot (T-101): no abre SSH, Docker, macdata
# ni un slot real. Lee e2e/Dockerfile, lib/worktrees.sh y Makefile como texto, y ejecuta cmd_wt_flag /
# normalizaciones con dependencias simuladas. Cada asercion nombra el defecto que atrapa
# (analisis.md §5.2 A1-A14; ronda 2 endurece A4/A6-A9/A11-A14 y agrega A15;
# ronda 3 ancla A4/A7 al bloque ejecutable y asocia IF NOT EXISTS al INSERT;
# T-105 agrega A16-A19 con seam en wt_shared_query y el wt_shared_scalar real).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
WT="$ROOT/lib/worktrees.sh"
DF="$ROOT/e2e/Dockerfile"
MK="$ROOT/Makefile"
pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS: %s\n' "$*"; }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*" >&2; }

[ -f "$WT" ] && [ -f "$DF" ] && [ -f "$MK" ] || { echo "faltan fuentes del sidecar en $ROOT" >&2; exit 2; }

BUILD_BODY="$(sed -n '/^_wt_build_api_image() {/,/^}/p' "$WT")"
UP_BODY="$(sed -n '/^wt_up_api() {/,/^}/p' "$WT")"
FLAG_BODY="$(sed -n '/^cmd_wt_flag() {/,/^}/p' "$WT")"

# Extrae una funcion de una linea (`name() { ... }`) o de bloque (`name() {` ... `}`).
# El sed por rango /^}/ no captura la forma de una linea de wt_shared_scalar.
extract_shell_fn() {
  awk -v n="$2" '
    $0 ~ "^" n "\\(\\)" {
      print
      rest = $0
      sub(/^[^{]*\{/, "", rest)
      if (index(rest, "}") > 0) exit
      collecting = 1
      next
    }
    collecting {
      print
      if (/^}/) exit
    }
  ' "$1"
}
SCALAR_BODY="$(extract_shell_fn "$WT" "wt_shared_scalar")"

hget() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }

# Extrae el case de normalizacion de la perilla (A11) y el de la etiqueta leida (A9).
CAP_CASE="$(printf '%s\n' "$UP_BODY" | awk '
  /PM_WT_LOGIN_SKIP_CAPABILITY/ { interested=1 }
  interested && /case / { collecting=1 }
  collecting { print }
  collecting && /esac/ { exit }
')"
IMG_CAP_CASE="$(printf '%s\n' "$UP_BODY" | awk '
  /case "\$img_cap"/ { collecting=1 }
  collecting { print }
  collecting && /esac/ { exit }
')"
WT_ENV_BLOCK="$(awk '
  /^WT_ENV[[:space:]]*=/ { collecting=1 }
  collecting { print }
  collecting && $0 !~ /\\[[:space:]]*$/ { exit }
' "$MK")"

# Instrucciones RUN ejecutables del Dockerfile: omite comentarios y une "\".
dockerfile_exec_runs() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      while (line ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, " ", line)
        if ((getline nxt) <= 0) break
        while (nxt ~ /^[[:space:]]*#/ || nxt ~ /^[[:space:]]*$/) {
          if ((getline nxt) <= 0) { nxt = ""; break }
        }
        sub(/^[[:space:]]+/, "", nxt)
        line = line nxt
      }
      if (line ~ /^[[:space:]]*RUN([[:space:]]|$)/) print line
    }
  ' "$1"
}

# Lineas ejecutables de un cuerpo de funcion: omite comentarios y une "\".
fn_exec_lines() {
  printf '%s\n' "$1" | awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      while (line ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, " ", line)
        if ((getline nxt) <= 0) break
        if (nxt ~ /^[[:space:]]*#/ || nxt ~ /^[[:space:]]*$/) continue
        sub(/[[:space:]]+#.*$/, "", nxt)
        sub(/^[[:space:]]+/, "", nxt)
        line = line nxt
      }
      if (line ~ /[^[:space:]]/) print line
    }
  '
}

# Quita comentarios T-SQL (--) y (/* */) respetando literales; vacia su interior.
sql_strip_comments() {
  awk '
    { buf = buf $0 "\n" }
    END {
      n = length(buf)
      out = ""
      in_str = 0
      in_line = 0
      in_block = 0
      for (i = 1; i <= n; i++) {
        c = substr(buf, i, 1)
        nxt = (i < n) ? substr(buf, i + 1, 1) : ""
        if (in_line) {
          if (c == "\n") { in_line = 0; out = out c }
          continue
        }
        if (in_block) {
          if (c == "*" && nxt == "/") { in_block = 0; i++ }
          else if (c == "\n") out = out c
          continue
        }
        if (in_str) {
          if (c == "'\''") {
            if (nxt == "'\''") { i++ }
            else { in_str = 0; out = out c }
          }
          continue
        }
        if (c == "'\''") { in_str = 1; out = out c; continue }
        if (c == "-" && nxt == "-") { in_line = 1; i++; continue }
        if (c == "/" && nxt == "*") { in_block = 1; i++; continue }
        out = out c
      }
      printf "%s", out
    }
  '
}

# Clasifica cada INSERT INTO FeatureManagement.FeatureFlags: guarded si
# queda dentro de IF NOT EXISTS ... BEGIN ... END; si no, unguarded.
sql_insert_scopes() {
  awk '
    { buf = buf $0 "\n" }
    END {
      s = toupper(buf)
      gsub(/IF[ \t\r\n]+NOT[ \t\r\n]+EXISTS/, " IF_NOT_EXISTS ", s)
      gsub(/INSERT[ \t\r\n]+INTO[ \t\r\n]+FEATUREMANAGEMENT\.FEATUREFLAGS/, " INSERT_FF ", s)
      n = split(s, w, /[^A-Z0-9_.]+/)
      exists_pending = 0
      exists_depth = 0
      begin_depth = 0
      for (i = 1; i <= n; i++) {
        tok = w[i]
        if (tok == "IF_NOT_EXISTS") {
          exists_pending = 1
        } else if (tok == "BEGIN") {
          begin_depth++
          if (exists_pending) {
            exists_depth++
            exists_at[exists_depth] = begin_depth
            exists_pending = 0
          }
        } else if (tok == "END") {
          if (exists_depth > 0 && exists_at[exists_depth] == begin_depth) exists_depth--
          if (begin_depth > 0) begin_depth--
        } else if (tok == "INSERT_FF") {
          if (exists_depth > 0 || exists_pending) print "guarded"
          else print "unguarded"
          exists_pending = 0
        }
      }
    }
  '
}

# Ejecuta el case de PM_WT_LOGIN_SKIP_CAPABILITY aislado. Imprime RC= CAP=.
run_cap_norm() {
  (
    PM_WT_LOGIN_SKIP_CAPABILITY="$1"
    cap=""
    wt_die() { :; }
    _go() { eval "$CAP_CASE"; }
    _go
    printf 'RC=%s CAP=%s\n' "$?" "${cap-}"
  )
}

# Ejecuta el case de img_cap aislado. Imprime el valor normalizado.
run_img_cap_norm() {
  (
    img_cap="$1"
    eval "$IMG_CAP_CASE"
    printf '%s' "$img_cap"
  )
}

# Ejecuta cmd_wt_flag N veces con wt_shared_scalar simulado (sin SQL real).
# $1=create $2=state $3=start_rows $4=times $5=reread|__stored__
# El estado vive en archivos: out="$(wt_shared_scalar ...)" corre en un subshell y
# perderia incrementos en variables. Interpreta el lote interpolado: IF 1=1 + INSERT
# crea; ELSE @outcome decide la ausencia. IF NOT EXISTS solo protege el INSERT si
# lo envuelve en el SQL ejecutable (comentarios fuera); un INSERT suelto duplica.
harness_flag_repeat() {
  (
    create="$1"
    state="$2"
    start_rows="$3"
    times="$4"
    reread="${5:-__stored__}"
    died=0
    last_rc=0
    hdir="$(mktemp -d "${TMPDIR:-/tmp}/wt-login-skip-h.XXXXXX")"
    trap 'rm -rf "$hdir"' EXIT
    printf '%s' "0" > "$hdir/inserts"
    printf '%s' "$start_rows" > "$hdir/rows"
    if [ "$start_rows" -gt 0 ]; then
      printf '%s' "1" > "$hdir/enabled"
    else
      printf '%s' "" > "$hdir/enabled"
    fi
    eval "$FLAG_BODY"
    wt_require_intel() { return 0; }
    _wt_bind_slot() { PM_PLANNING_DB="pm_planning_wt0"; return 0; }
    wt_shared_sql_password() { printf '%s' "pw"; return 0; }
    wt_shared_sql_check() { return 0; }
    wt_log() { :; }
    wt_die() { died=1; printf 'DIE:%s\n' "$*" >> "$hdir/die.log"; return 1; }
    requested_v=0
    case "$state" in on|ON|1|true|TRUE) requested_v=1 ;; esac
    wt_shared_scalar() {
      local sql="$2" else_out rows inserts create_on has_insert has_unguarded sql_exec scope
      rows="$(cat "$hdir/rows")"
      inserts="$(cat "$hdir/inserts")"
      if printf '%s' "$sql" | grep -q 'CAST(IsEnabled AS int)'; then
        if [ "$reread" != "__stored__" ]; then
          printf '%s' "$reread"
        else
          cat "$hdir/enabled"
        fi
        return 0
      fi
      create_on=0
      has_insert=0
      has_unguarded=0
      sql_exec="$(printf '%s' "$sql" | sql_strip_comments)"
      printf '%s' "$sql_exec" | grep -qE 'IF[[:space:]]+"?1"?[[:space:]]*=[[:space:]]*"?1"?' && create_on=1
      while IFS= read -r scope; do
        [ -n "$scope" ] || continue
        has_insert=1
        [ "$scope" = "unguarded" ] && has_unguarded=1
      done < <(printf '%s' "$sql_exec" | sql_insert_scopes)
      else_out="$(printf '%s' "$sql_exec" | sed -n "s/.*ELSE SET @outcome = N'\\([^']*\\)'.*/\\1/p" | head -1)"
      if [ "$rows" -eq 0 ]; then
        if [ "$create_on" -eq 1 ] && [ "$has_insert" -eq 1 ]; then
          printf '%s' "$((inserts + 1))" > "$hdir/inserts"
          printf '%s' "1" > "$hdir/rows"
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s' "created"
        else
          printf '%s' "${else_out:-absent}"
        fi
      else
        if [ "$has_unguarded" -eq 1 ] && [ "$create_on" -eq 1 ]; then
          printf '%s' "$((inserts + 1))" > "$hdir/inserts"
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s' "created"
        else
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s' "updated"
        fi
      fi
      return 0
    }
    PM_WT_FLAG_KEY="login-skip-password"
    PM_WT_FLAG_STATE="$state"
    PM_WT_FLAG_CREATE="$create"
    PM_WT_FLAG_PLANT="TRI"
    PM_PLANNING_DB="pm_planning_wt0"
    n=0
    while [ "$n" -lt "$times" ]; do
      cmd_wt_flag
      last_rc=$?
      n=$((n + 1))
    done
    printf 'RC=%s INSERTS=%s ROWS=%s DIED=%s CALLS=%s\n' \
      "$last_rc" "$(cat "$hdir/inserts")" "$(cat "$hdir/rows")" "$died" "$n"
  )
}

# Ejecuta cmd_wt_flag con el wt_shared_scalar REAL (extraido) y un wt_shared_query
# simulado que modela el transporte: R1 (USE emite el informativo), R2 (BD efectiva =
# USE, si no -d, si no master), R3 (tabla solo existe en pm_planning_wt0).
# $1=create $2=state $3=start_rows $4=times $5=reread|__stored__ $6=planning_db
harness_flag_transport() {
  (
    create="$1"
    state="$2"
    start_rows="$3"
    times="$4"
    reread="${5:-__stored__}"
    slot_db="${6:-pm_planning_wt0}"
    died=0
    last_rc=0
    hdir="$(mktemp -d "${TMPDIR:-/tmp}/wt-login-skip-t.XXXXXX")"
    trap 'rm -rf "$hdir"' EXIT
    printf '%s' "0" > "$hdir/inserts"
    printf '%s' "$start_rows" > "$hdir/rows"
    if [ "$start_rows" -gt 0 ]; then
      printf '%s' "1" > "$hdir/enabled"
    else
      printf '%s' "" > "$hdir/enabled"
    fi
    : > "$hdir/log"
    : > "$hdir/die.log"
    if [ -z "$SCALAR_BODY" ]; then
      printf 'RC=99 INSERTS=0 ROWS=0 DIED=1 CALLS=0\nLOG=\nDIE=extractor-vacio\n'
      exit 0
    fi
    eval "$FLAG_BODY"
    eval "$SCALAR_BODY"
    wt_require_intel() { return 0; }
    _wt_bind_slot() { PM_PLANNING_DB="$slot_db"; return 0; }
    wt_shared_sql_password() { printf '%s' "pw"; return 0; }
    wt_shared_sql_check() { return 0; }
    wt_log() { printf '%s\n' "$*" >> "$hdir/log"; }
    wt_die() { died=1; printf '%s\n' "$*" >> "$hdir/die.log"; return 1; }
    requested_v=0
    case "$state" in on|ON|1|true|TRUE) requested_v=1 ;; esac
    wt_shared_query() {
      local sql="$2" flags="${3:-}" effective_db="master" use_db d_db
      use_db="$(printf '%s' "$sql" | sed -n 's/.*USE[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -1)"
      if [ -n "$use_db" ]; then
        printf '%s\n' "Changed database context to '${use_db}'."
        effective_db="$use_db"
      else
        d_db="$(printf '%s\n' "$flags" | awk '{
          for (i = 1; i <= NF; i++) {
            if ($i == "-d" && (i + 1) <= NF) { print $(i + 1); exit }
            if ($i ~ /^-d./) { print substr($i, 3); exit }
          }
        }')"
        if [ -n "$d_db" ]; then
          effective_db="$d_db"
        fi
      fi
      if [ "$effective_db" != "pm_planning_wt0" ]; then
        printf '%s\n' "no-table"
        return 0
      fi
      if printf '%s' "$sql" | grep -q 'CAST(IsEnabled AS int)'; then
        if [ "$reread" != "__stored__" ]; then
          printf '%s\n' "$reread"
        else
          cat "$hdir/enabled"
          printf '\n'
        fi
        return 0
      fi
      local else_out rows inserts create_on has_insert has_unguarded sql_exec scope
      rows="$(cat "$hdir/rows")"
      inserts="$(cat "$hdir/inserts")"
      create_on=0
      has_insert=0
      has_unguarded=0
      sql_exec="$(printf '%s' "$sql" | sql_strip_comments)"
      printf '%s' "$sql_exec" | grep -qE 'IF[[:space:]]+"?1"?[[:space:]]*=[[:space:]]*"?1"?' && create_on=1
      while IFS= read -r scope; do
        [ -n "$scope" ] || continue
        has_insert=1
        [ "$scope" = "unguarded" ] && has_unguarded=1
      done < <(printf '%s' "$sql_exec" | sql_insert_scopes)
      else_out="$(printf '%s' "$sql_exec" | sed -n "s/.*ELSE SET @outcome = N'\\([^']*\\)'.*/\\1/p" | head -1)"
      if [ "$rows" -eq 0 ]; then
        if [ "$create_on" -eq 1 ] && [ "$has_insert" -eq 1 ]; then
          printf '%s' "$((inserts + 1))" > "$hdir/inserts"
          printf '%s' "1" > "$hdir/rows"
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s\n' "created"
        else
          printf '%s\n' "${else_out:-absent}"
        fi
      else
        if [ "$has_unguarded" -eq 1 ] && [ "$create_on" -eq 1 ]; then
          printf '%s' "$((inserts + 1))" > "$hdir/inserts"
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s\n' "created"
        else
          printf '%s' "$requested_v" > "$hdir/enabled"
          printf '%s\n' "updated"
        fi
      fi
      return 0
    }
    PM_WT_FLAG_KEY="login-skip-password"
    PM_WT_FLAG_STATE="$state"
    PM_WT_FLAG_CREATE="$create"
    PM_WT_FLAG_PLANT="TRI"
    PM_PLANNING_DB="$slot_db"
    n=0
    while [ "$n" -lt "$times" ]; do
      cmd_wt_flag
      last_rc=$?
      n=$((n + 1))
    done
    printf 'RC=%s INSERTS=%s ROWS=%s DIED=%s CALLS=%s\n' \
      "$last_rc" "$(cat "$hdir/inserts")" "$(cat "$hdir/rows")" "$died" "$n"
    printf 'LOG=%s\n' "$(sed -n '$p' "$hdir/log" 2>/dev/null)"
    printf 'DIE=%s\n' "$(sed -n '$p' "$hdir/die.log" 2>/dev/null)"
  )
}

tlog() { printf '%s\n' "$1" | sed -n 's/^LOG=//p' | head -1; }
tdie() { printf '%s\n' "$1" | sed -n 's/^DIE=//p' | head -1; }

# --- A1 ---
# Defecto: alguien cambia el default a true (o lo omite, dejandolo vacio): TODO slot de TODA sesion
# nace con el gate del bypass compilado. Viola el AC del hito.
if grep -qE '^ARG[[:space:]]+LOGIN_SKIP_PASSWORD_TEST_CAPABILITY=false[[:space:]]*$' "$DF"; then
  ok "A1 Dockerfile declara ARG LOGIN_SKIP_PASSWORD_TEST_CAPABILITY=false"
else
  bad "A1 Dockerfile declara ARG LOGIN_SKIP_PASSWORD_TEST_CAPABILITY=false"
fi

# --- A2 ---
# Defecto: el ARG se declara pero no se cablea: la perilla se acepta, el wt-up reporta exito y el
# binario nunca lleva el gate. T-103 no puede observar nada y la culpa recae en la fila.
if grep -q -- '-p:LoginSkipPasswordTestCapability=' "$DF"; then
  ok "A2 dotnet publish consume el ARG via -p:LoginSkipPasswordTestCapability="
else
  bad "A2 dotnet publish consume el ARG via -p:LoginSkipPasswordTestCapability="
fi

# --- A3 ---
# Defecto: Directory.Build.props:13 compara contra 'true'; =1 no enciende nada y no falla.
# Encendido fantasma.
if grep -q -- '-p:LoginSkipPasswordTestCapability=$LOGIN_SKIP_PASSWORD_TEST_CAPABILITY' "$DF" \
  && ! grep -E -- '-p:LoginSkipPasswordTestCapability=(1|0)([[:space:]]|$)' "$DF" >/dev/null; then
  ok "A3 el valor pasado al -p: es el ARG, no un literal 1/0"
else
  bad "A3 el valor pasado al -p: es el ARG, no un literal 1/0"
fi

# --- A4 (M1) ---
# Defecto: la propiedad se renombra en la solucion o MSBuild la ignora: la imagen queda etiquetada
# true con un artefacto sin gate. La igualdad y el exit 1 deben vivir en el MISMO RUN
# ejecutable posterior al publish que inspecciona el dll publicado. Un comentario u
# otro RUN con el literal no acredita la comparacion.
a4_ok=0
a4_seen_publish=0
while IFS= read -r run; do
  printf '%s\n' "$run" | grep -q 'dotnet publish' && a4_seen_publish=1
  [ "$a4_seen_publish" -eq 1 ] || continue
  if printf '%s\n' "$run" | grep -q '/app/PL.PM.Catalogs.Infrastructure.dll' \
    && printf '%s\n' "$run" | grep -qE 'grep[[:space:]]+-qa[[:space:]]+.LoginSkipPasswordTestCapabilityMarker' \
    && printf '%s\n' "$run" | grep -qE '\[ "\$found" = "\$LOGIN_SKIP_PASSWORD_TEST_CAPABILITY" \]' \
    && printf '%s\n' "$run" | grep -qE 'exit[[:space:]]+1'; then
    a4_ok=1
    break
  fi
done < <(dockerfile_exec_runs "$DF")
if [ "$a4_ok" -eq 1 ]; then
  ok "A4 Dockerfile compara el marcador del artefacto contra el ARG y corta si no coincide"
else
  bad "A4 Dockerfile compara el marcador del artefacto contra el ARG y corta si no coincide"
fi

# --- A5 ---
# Defecto: sin etiqueta no hay nada que comparar: el gate de reuso queda ciego a la perilla.
if printf '%s\n' "$BUILD_BODY" | grep -q -- '--label org.pm.login-skip-password-capability'; then
  ok "A5 _wt_build_api_image estampa --label org.pm.login-skip-password-capability"
else
  bad "A5 _wt_build_api_image estampa --label org.pm.login-skip-password-capability"
fi

# --- A6 (M2) ---
# Defecto: estampar solo en true rompe la invalidacion true -> false (D16 / F-10).
# END decide el rc: un exit 1 intra-regla ya no lo pisa un END { exit 0 }.
if printf '%s\n' "$BUILD_BODY" | grep -q -- '--label org.pm.login-skip-password-capability' \
  && ! printf '%s\n' "$BUILD_BODY" | grep -qE '\[ "\$cap" = "?true"? \].*login-skip-password-capability' \
  && printf '%s\n' "$BUILD_BODY" | awk '
      /\[ "\$cap" = "?true"? \]/ { gated=1 }
      /^[[:space:]]*fi[[:space:]]*$/ { gated=0 }
      /org.pm.login-skip-password-capability/ { if (gated) bad=1 }
      END { exit(bad ? 1 : 0) }
    '; then
  ok "A6 la etiqueta se estampa SIEMPRE, tambien cuando la capacidad es false"
else
  bad "A6 la etiqueta se estampa SIEMPRE, tambien cuando la capacidad es false"
fi

# --- A7 (M4) ---
# Defecto: la etiqueta dice true y el build publica sin la capacidad: etiqueta mentirosa.
# La igualdad $cap debe ir en la misma linea/comando ejecutable que docker ... build.
# Un comentario o rama no ejecutada con el literal no acredita el argumento real.
a7_builds=0
a7_ok=1
while IFS= read -r cmd; do
  printf '%s\n' "$cmd" | grep -qE 'docker[[:space:]].*build' || continue
  a7_builds=$((a7_builds + 1))
  if ! printf '%s\n' "$cmd" | grep -q -- "--build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY='\$cap'"; then
    a7_ok=0
  fi
done < <(fn_exec_lines "$BUILD_BODY")
if [ "$a7_builds" -gt 0 ] && [ "$a7_ok" -eq 1 ]; then
  ok "A7 _wt_build_api_image pasa --build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY='\$cap'"
else
  bad "A7 _wt_build_api_image pasa --build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY='\$cap'"
fi

# --- A8 (M3) ---
# Defecto: EL RIESGO DOMINANTE. La perilla cambia, el SHA no, el build se salta.
# Exige img_cap = cap en el mismo if que org.pm.src-sha; [ -n "$img_cap" ] no basta.
SKIP_IF="$(printf '%s\n' "$UP_BODY" | grep -B1 'do_build=0' | grep 'if \[')"
if [ -n "$SKIP_IF" ] \
  && printf '%s\n' "$SKIP_IF" | grep -q 'img_sha' \
  && printf '%s\n' "$SKIP_IF" | grep -q 'src_sha' \
  && printf '%s\n' "$SKIP_IF" | grep -qE '\[ "\$img_cap" = "\$cap" \]'; then
  ok "A8 do_build=0 exige img_sha=src_sha Y img_cap=cap en el mismo if"
else
  bad "A8 do_build=0 exige img_sha=src_sha Y img_cap=cap en el mismo if"
fi

# --- A9 (S2) ---
# Defecto: un *) img_cap=false oculta una etiqueta corrupta y degrada el gate de reuso.
# Solo '' y <no value> convergen a false; cualquier otro valor se conserva.
img_empty="$(run_img_cap_norm '')"
img_noval="$(run_img_cap_norm '<no value>')"
img_true="$(run_img_cap_norm 'true')"
img_unknown="$(run_img_cap_norm 'garbage')"
if [ -n "$IMG_CAP_CASE" ] \
  && [ "$img_empty" = "false" ] \
  && [ "$img_noval" = "false" ] \
  && [ "$img_true" = "true" ] \
  && [ "$img_unknown" = "garbage" ]; then
  ok "A9 vacio y <no value> -> false; un valor desconocido NO se coerce a false"
else
  bad "A9 vacio y <no value> -> false; un valor desconocido NO se coerce a false (empty=${img_empty:-?} noval=${img_noval:-?} true=${img_true:-?} unk=${img_unknown:-?})"
fi

# --- A10 ---
# Defecto: la capacidad se cuela por omision. Es el AC del hito, textual.
if printf '%s\n' "$UP_BODY" | grep -q '\${PM_WT_LOGIN_SKIP_CAPABILITY:-0}' \
  && grep -qE '^LOGINSKIP[[:space:]]*\?=[[:space:]]*0[[:space:]]*$' "$MK"; then
  ok "A10 default apagado: \${PM_WT_LOGIN_SKIP_CAPABILITY:-0} y LOGINSKIP ?= 0"
else
  bad "A10 default apagado: \${PM_WT_LOGIN_SKIP_CAPABILITY:-0} y LOGINSKIP ?= 0"
fi

# --- A11 (M5) ---
# Defecto: LOGINSKIP=yes se trata como apagado sin decir nada.
# El case aislado con valor no reconocido debe devolver rc 2 (no 1 ni 0).
cap_yes="$(run_cap_norm yes)"
cap_yes_rc="$(hget "$cap_yes" RC)"
cap_off="$(run_cap_norm 0)"
cap_on="$(run_cap_norm 1)"
if [ -n "$CAP_CASE" ] \
  && [ "$cap_yes_rc" = "2" ] \
  && [ "$(hget "$cap_off" CAP)" = "false" ] \
  && [ "$(hget "$cap_on" CAP)" = "true" ]; then
  ok "A11 valor no reconocido de la perilla aborta con rc 2 (0->false, 1->true)"
else
  bad "A11 valor no reconocido de la perilla aborta con rc 2 (yes=$cap_yes off=$cap_off on=$cap_on)"
fi

# --- A12 (S1) ---
# Defecto: las cadenas existen en un comentario o receta no ejecutada, pero WT_ENV deja de
# propagarlas. La asercion se ancla al bloque WT_ENV (continuaciones con barra).
if [ -n "$WT_ENV_BLOCK" ] \
  && printf '%s\n' "$WT_ENV_BLOCK" | grep -q 'PM_WT_LOGIN_SKIP_CAPABILITY=$(LOGINSKIP)' \
  && printf '%s\n' "$WT_ENV_BLOCK" | grep -q 'PM_WT_FLAG_CREATE=$(CREATE)'; then
  ok "A12 bloque WT_ENV propaga PM_WT_LOGIN_SKIP_CAPABILITY y PM_WT_FLAG_CREATE"
else
  bad "A12 bloque WT_ENV propaga PM_WT_LOGIN_SKIP_CAPABILITY y PM_WT_FLAG_CREATE"
fi

# --- A13 (M6) ---
# Defecto: (a) sin CREATE, fila ausente deja de fallar; (b) CREATE=1 repetido inserta de nuevo.
# Arnes: CREATE=0 + ausente + relectura que coincidiria -> rc=1 e INSERTS=0.
#         CREATE=1 dos veces sobre tabla vacia -> rc=0 e INSERTS=1.
# La proteccion de existencia se asocia a la rama del INSERT, no al token global.
a13_absent="$(harness_flag_repeat 0 on 0 1 1)"
a13_create="$(harness_flag_repeat 1 on 0 2 __stored__)"
a13_abs_rc="$(hget "$a13_absent" RC)"
a13_abs_ins="$(hget "$a13_absent" INSERTS)"
a13_abs_died="$(hget "$a13_absent" DIED)"
a13_cr_rc="$(hget "$a13_create" RC)"
a13_cr_ins="$(hget "$a13_create" INSERTS)"
if [ "$a13_abs_rc" != "0" ] && [ "$a13_abs_ins" = "0" ] && [ "$a13_abs_died" = "1" ] \
  && [ "$a13_cr_rc" = "0" ] && [ "$a13_cr_ins" = "1" ]; then
  ok "A13 CREATE=0 ausente -> rc!=0 sin INSERT; CREATE=1 x2 -> una sola insercion"
else
  bad "A13 CREATE=0 ausente -> rc!=0 sin INSERT; CREATE=1 x2 -> una sola insercion (absent=$a13_absent create=$a13_create)"
fi

# --- A14 (M7) ---
# Defecto: (a) PLANT crudo rompe el lote; (b) sin relectura el verbo reporta exito falso.
# plant_esc + N'$plant_esc' siguen en el texto; el arnes dispara wt_die si observed != v.
a14="$(harness_flag_repeat 0 on 1 1 0)"
a14_rc="$(hget "$a14" RC)"
a14_died="$(hget "$a14" DIED)"
if printf '%s\n' "$FLAG_BODY" | grep -q 'plant_esc=' \
  && printf '%s\n' "$FLAG_BODY" | grep -q "N'\$plant_esc'" \
  && ! printf '%s\n' "$FLAG_BODY" | grep -qE "N'\$plant'" \
  && [ "$a14_rc" != "0" ] && [ "$a14_died" = "1" ]; then
  ok "A14 cmd_wt_flag escapa PLANT y la relectura discrepante dispara wt_die (rc!=0)"
else
  bad "A14 cmd_wt_flag escapa PLANT y la relectura discrepante dispara wt_die (rc!=0) (h=$a14)"
fi

# --- A15 (S3) ---
# Defecto: CREATE=yes se coerce a 0 o 1 en silencio. El diseño exige rc 2.
a15="$(harness_flag_repeat yes on 0 1 __stored__)"
a15_rc="$(hget "$a15" RC)"
if [ "$a15_rc" = "2" ]; then
  ok "A15 CREATE=yes aborta con rc 2 (no se coerce a 0 ni a 1)"
else
  bad "A15 CREATE=yes aborta con rc 2 (no se coerce a 0 ni a 1) (h=$a15)"
fi

# --- A16 ---
# Defecto: alguien restituye el USE en el lote de outcome o quita el -d: el verbo vuelve a
# salir 1 y no imprime el discriminador CREADO (06-wt-flag-on-create.txt).
a16_ok=1
[ -n "$SCALAR_BODY" ] || a16_ok=0
a16="$(harness_flag_transport 1 on 0 1 __stored__)"
a16_rc="$(hget "$a16" RC)"
a16_died="$(hget "$a16" DIED)"
a16_log="$(tlog "$a16")"
if [ "$a16_ok" -eq 1 ] && [ "$a16_rc" = "0" ] && [ "$a16_died" = "0" ] \
  && [ "$a16_log" = "flag 'login-skip-password'/TRI CREADO con IsEnabled=1 en pm_planning_wt0" ]; then
  ok "A16 CREATE=1 ausente -> rc=0 y log CREADO IsEnabled=1 (transporte real)"
else
  bad "A16 CREATE=1 ausente -> rc=0 y log CREADO IsEnabled=1 (transporte real) (h=$a16 scalar=${#SCALAR_BODY})"
fi

# --- A17 ---
# Defecto: el arreglo se aplica solo al lote de outcome y la relectura sigue con USE:
# observed llega contaminado y el wt_die de discrepancia mata la corrida (11-wt-flag-off.txt).
a17="$(harness_flag_transport 0 off 1 1 __stored__)"
a17_rc="$(hget "$a17" RC)"
a17_log="$(tlog "$a17")"
if [ -n "$SCALAR_BODY" ] && [ "$a17_rc" = "0" ] \
  && [ "$a17_log" = "flag 'login-skip-password'/TRI -> IsEnabled=0 en pm_planning_wt0" ]; then
  ok "A17 CREATE=0 STATE=off presente -> rc=0 y log -> IsEnabled=0 (relectura limpia)"
else
  bad "A17 CREATE=0 STATE=off presente -> rc=0 y log -> IsEnabled=0 (relectura limpia) (h=$a17)"
fi

# --- A18 ---
# Defecto: el arreglo "destraba" el verbo haciendo que la fila ausente pase por buena, o
# la deja saliendo 1 con resultado inesperado. El absent sin CREATE sigue en rojo.
a18="$(harness_flag_transport 0 on 0 1 __stored__)"
a18_rc="$(hget "$a18" RC)"
a18_died="$(hget "$a18" DIED)"
a18_ins="$(hget "$a18" INSERTS)"
a18_die="$(tdie "$a18")"
if [ -n "$SCALAR_BODY" ] && [ "$a18_rc" != "0" ] && [ "$a18_died" = "1" ] && [ "$a18_ins" = "0" ] \
  && printf '%s' "$a18_die" | grep -q 'CREATE=1' \
  && ! printf '%s' "$a18_die" | grep -q 'resultado inesperado'; then
  ok "A18 CREATE=0 ausente -> rc!=0, 0 INSERT, mensaje nombra CREATE=1"
else
  bad "A18 CREATE=0 ausente -> rc!=0, 0 INSERT, mensaje nombra CREATE=1 (h=$a18)"
fi

# --- A19 ---
# Defecto: alguien quita el USE pero olvida pasar el -d: el lote corre contra master,
# donde la tabla no existe. Sin R2/R3 el mutante sobrevive con rc=0.
a19="$(harness_flag_transport 1 on 0 1 __stored__ pm_planning_wt99)"
a19_rc="$(hget "$a19" RC)"
a19_die="$(tdie "$a19")"
if [ -n "$SCALAR_BODY" ] && [ "$a19_rc" != "0" ] \
  && printf '%s' "$a19_die" | grep -q 'wt-up'; then
  ok "A19 BD efectiva distinta del slot -> rc!=0 y mensaje nombra wt-up"
else
  bad "A19 BD efectiva distinta del slot -> rc!=0 y mensaje nombra wt-up (h=$a19)"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
