#!/usr/bin/env bash
# Contratos hermeticos de la perilla login-skip-password del slot (T-101): no abre SSH, Docker, macdata
# ni un slot real. Lee e2e/Dockerfile, lib/worktrees.sh y Makefile como texto. Cada asercion nombra el
# defecto que atrapa (analisis.md §5.2 A1-A14).
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

# --- A4 ---
# Defecto: la propiedad se renombra en la solucion o MSBuild la ignora: la imagen queda etiquetada
# true con un artefacto sin gate. Es el sintoma indistinguible, materializado.
if grep -q 'LoginSkipPasswordTestCapabilityMarker' "$DF" \
  && grep -q 'LOGIN_SKIP_PASSWORD_TEST_CAPABILITY' "$DF" \
  && grep -qE 'grep[[:space:]]+-qa[[:space:]]+.LoginSkipPasswordTestCapabilityMarker' "$DF"; then
  ok "A4 Dockerfile verifica el marcador del artefacto contra el ARG"
else
  bad "A4 Dockerfile verifica el marcador del artefacto contra el ARG"
fi

# --- A5 ---
# Defecto: sin etiqueta no hay nada que comparar: el gate de reuso queda ciego a la perilla.
if printf '%s\n' "$BUILD_BODY" | grep -q -- '--label org.pm.login-skip-password-capability'; then
  ok "A5 _wt_build_api_image estampa --label org.pm.login-skip-password-capability"
else
  bad "A5 _wt_build_api_image estampa --label org.pm.login-skip-password-capability"
fi

# --- A6 ---
# Defecto: estampar solo en true rompe la invalidacion true -> false: la imagen capacidad-true se
# reusa cuando se pide false (D16 / F-10).
if printf '%s\n' "$BUILD_BODY" | grep -q -- '--label org.pm.login-skip-password-capability' \
  && ! printf '%s\n' "$BUILD_BODY" | grep -qE '\[ "\$cap" = "?true"? \].*login-skip-password-capability' \
  && printf '%s\n' "$BUILD_BODY" | awk '
      /\[ "\$cap" = "?true"? \]/ { gated=1 }
      /^[[:space:]]*fi[[:space:]]*$/ { gated=0 }
      /org.pm.login-skip-password-capability/ { if (gated) exit 1 }
      END { exit 0 }
    '; then
  ok "A6 la etiqueta se estampa SIEMPRE, tambien cuando la capacidad es false"
else
  bad "A6 la etiqueta se estampa SIEMPRE, tambien cuando la capacidad es false"
fi

# --- A7 ---
# Defecto: la etiqueta dice true y el build publica sin la capacidad: etiqueta mentirosa.
if printf '%s\n' "$BUILD_BODY" | grep -q -- '--build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY'; then
  ok "A7 _wt_build_api_image pasa --build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY"
else
  bad "A7 _wt_build_api_image pasa --build-arg LOGIN_SKIP_PASSWORD_TEST_CAPABILITY"
fi

# --- A8 ---
# Defecto: EL RIESGO DOMINANTE. La perilla cambia, el SHA no, el build se salta y el slot conserva
# la imagen anterior. Reverso F-10: un slot liberado con la capacidad encendida se la hereda a otra
# sesion, que ademas recibe la fila IsEnabled=1 de e2e-up.
SKIP_IF="$(printf '%s\n' "$UP_BODY" | grep -B1 'do_build=0' | grep 'if \[')"
if [ -n "$SKIP_IF" ] \
  && printf '%s\n' "$SKIP_IF" | grep -q 'img_sha' \
  && printf '%s\n' "$SKIP_IF" | grep -q 'src_sha' \
  && printf '%s\n' "$SKIP_IF" | grep -q 'img_cap'; then
  ok "A8 do_build=0 exige org.pm.src-sha Y la etiqueta de capacidad en el mismo if"
else
  bad "A8 do_build=0 exige org.pm.src-sha Y la etiqueta de capacidad en el mismo if"
fi

# --- A9 ---
# Defecto: toda imagen previa a este cambio se declararia «desconocida» y forzaria un rebuild de
# varios minutos en cada slot vivo; o peor, se compararia como igual a true.
if printf '%s\n' "$UP_BODY" | grep -qE "''\|'<no value>'|'<no value>'\|''" \
  && printf '%s\n' "$UP_BODY" | grep -q 'img_cap=false'; then
  ok "A9 la lectura de la etiqueta normaliza vacio y <no value> a false"
else
  bad "A9 la lectura de la etiqueta normaliza vacio y <no value> a false"
fi

# --- A10 ---
# Defecto: la capacidad se cuela por omision. Es el AC del hito, textual.
if printf '%s\n' "$UP_BODY" | grep -q '\${PM_WT_LOGIN_SKIP_CAPABILITY:-0}' \
  && grep -qE '^LOGINSKIP[[:space:]]*\?=[[:space:]]*0[[:space:]]*$' "$MK"; then
  ok "A10 default apagado: \${PM_WT_LOGIN_SKIP_CAPABILITY:-0} y LOGINSKIP ?= 0"
else
  bad "A10 default apagado: \${PM_WT_LOGIN_SKIP_CAPABILITY:-0} y LOGINSKIP ?= 0"
fi

# --- A11 ---
# Defecto: LOGINSKIP=yes se trata como apagado sin decir nada: el tester ve «login rechazado»
# sin una sola pista.
CAP_CASE="$(printf '%s\n' "$UP_BODY" | awk '
  /PM_WT_LOGIN_SKIP_CAPABILITY/ { interested=1 }
  interested && /case / { collecting=1 }
  collecting { print }
  collecting && /esac/ { exit }
')"
if [ -n "$CAP_CASE" ] \
  && printf '%s\n' "$CAP_CASE" | grep -qE '^\s*\*\)' \
  && printf '%s\n' "$CAP_CASE" | grep -q 'wt_die'; then
  ok "A11 un valor no reconocido de la perilla aborta con wt_die (no se coerce)"
else
  bad "A11 un valor no reconocido de la perilla aborta con wt_die (no se coerce)"
fi

# --- A12 ---
# Defecto: la perilla existe en lib/ pero es inalcanzable desde el punto de entrada sancionado (make).
if grep -q 'PM_WT_LOGIN_SKIP_CAPABILITY=$(LOGINSKIP)' "$MK" \
  && grep -q 'PM_WT_FLAG_CREATE=$(CREATE)' "$MK"; then
  ok "A12 WT_ENV propaga PM_WT_LOGIN_SKIP_CAPABILITY y PM_WT_FLAG_CREATE"
else
  bad "A12 WT_ENV propaga PM_WT_LOGIN_SKIP_CAPABILITY y PM_WT_FLAG_CREATE"
fi

# --- A13 ---
# Defecto: (a) el verbo crea filas en silencio y rompe el criterio «sin CREATE, la fila ausente
# sigue fallando»; (b) repetir el comando choca contra la PK ([Key],[Plant]).
nexists_line="$(printf '%s\n' "$FLAG_BODY" | grep -n 'IF NOT EXISTS' | head -1 | cut -d: -f1)"
insert_line="$(printf '%s\n' "$FLAG_BODY" | grep -n 'INSERT INTO FeatureManagement.FeatureFlags' | head -1 | cut -d: -f1)"
create_line="$(printf '%s\n' "$FLAG_BODY" | grep -nE 'IF[[:space:]]+\$create[[:space:]]*=[[:space:]]*1' | head -1 | cut -d: -f1)"
if [ -n "${nexists_line:-}" ] && [ -n "${insert_line:-}" ] && [ -n "${create_line:-}" ] \
  && [ "$nexists_line" -lt "$insert_line" ] && [ "$create_line" -lt "$insert_line" ]; then
  ok "A13 INSERT esta bajo CREATE y bajo IF NOT EXISTS"
else
  bad "A13 INSERT esta bajo CREATE y bajo IF NOT EXISTS (nexists=${nexists_line:-?} create=${create_line:-?} insert=${insert_line:-?})"
fi

# --- A14 ---
# Defecto: (a) un PLANT con apostrofo rompe el lote; wt_shared_scalar devuelve vacio y se reporta
# «el flag no existe» — diagnostico falso. (b) sin relectura, el verbo termina en 0 aunque la
# escritura no haya aterrizado, y el criterio de cierre 1 se acredita con un exito falso.
if printf '%s\n' "$FLAG_BODY" | grep -q 'plant_esc=' \
  && printf '%s\n' "$FLAG_BODY" | grep -q "N'\$plant_esc'" \
  && ! printf '%s\n' "$FLAG_BODY" | grep -qE "N'\$plant'" \
  && printf '%s\n' "$FLAG_BODY" | grep -q 'CAST(IsEnabled AS int)' \
  && printf '%s\n' "$FLAG_BODY" | grep -q 'wt_die'; then
  ok "A14 cmd_wt_flag escapa PLANT (plant_esc) y relee el estado con wt_die si no coincide"
else
  bad "A14 cmd_wt_flag escapa PLANT (plant_esc) y relee el estado con wt_die si no coincide"
fi

echo "----"
echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
