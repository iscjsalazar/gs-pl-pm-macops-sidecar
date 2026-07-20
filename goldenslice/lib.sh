#!/usr/bin/env bash
# Librería compartida de los orquestadores goldenslice (up.sh y relaunch.sh). Aloja los helpers reutilizables por
# ambos flujos para no duplicar cuerpos de función. Se sourcea DESPUES de lib/common.sh + lib/worktrees.sh; las
# funciones aqui invocan gs_log/gs_die y variables del script consumidor en tiempo de EJECUCION (no de definición),
# de modo que cada script aporta su propio prefijo de log ([goldenslice-up] / [goldenslice-relaunch]) y su contexto.

# gs_run_job: POST a un tool-job del pm-api y poll a Completed (async 202 + jobId; GET /api/v1/jobs/{id}).
# Depende de dos variables que el script consumidor resuelve ANTES de invocarlo: API_PORT (puerto publicado del
# contenedor API en macdata) y PM_REMOTE_SSH (alias SSH de la Intel). Retorna 0 solo si el job llega a Completed.
gs_run_job(){  # <path> <json-body-o-vacio> <label>
  local path="$1" body="$2" label="$3" resp jid st i
  if [ -n "$body" ]; then
    resp="$(ssh "$PM_REMOTE_SSH" "curl -fsS -X POST http://127.0.0.1:$API_PORT$path -H 'Content-Type: application/json' -d '$body'" 2>/dev/null)"
  else
    resp="$(ssh "$PM_REMOTE_SSH" "curl -fsS -X POST http://127.0.0.1:$API_PORT$path" 2>/dev/null)"
  fi
  jid="$(printf '%s' "$resp" | sed -nE 's/.*"jobId"[": ]*"?([0-9a-fA-F-]{16,})"?.*/\1/p')"
  [ -n "$jid" ] || { gs_log "AVISO: $label no devolvio jobId (resp: ${resp:-<vacio>})"; return 1; }
  for i in $(seq 1 90); do
    st="$(ssh "$PM_REMOTE_SSH" "curl -fsS http://127.0.0.1:$API_PORT/api/v1/jobs/$jid" 2>/dev/null | sed -nE 's/.*"currentStatus"[": ]*"([A-Za-z]+)".*/\1/p')"
    case "$st" in
      Completed) gs_log "$label -> Completed"; return 0 ;;
      Failed|TimedOut) gs_log "AVISO: $label -> $st (revisa el job $jid)"; return 1 ;;
    esac
    sleep 2
  done
  gs_log "AVISO: $label no llego a Completed (job $jid)"; return 1
}
