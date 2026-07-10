#!/usr/bin/env bash
# Orquestador de aprovisionamiento por worktree (verbos wt-*). Capa fina sobre lib/common.sh + lib/worktrees.sh.
# Modelo "slot" (0..N-1) por worktree: SQL compartido (nvoslabs) + referencia LN propia (pm_erpln106) + bus
# PM-owned como singletons; BD de producto (pm_planning_wt<N>) y API (build desde el worktree) por worktree.
# Requiere PM_TARGET=intel (REMOTE=macdata): el SQL compartido, el bus y la API viven en el docker de macdata.
#
#   WT=<folder> ./wt.sh up      # aprovisiona el entorno del worktree (asigna slot, siembra, levanta la API)
#   WT=<folder> PM_WT_ORACLE=1 ./wt.sh up   # + Oracle ControlPiso propio del slot (lazy; lo enciende e2e-up)
#   WT=<folder> ./wt.sh down    # baja API, Oracle y BD del worktree; libera el slot (singletons intactos)
#   WT=<folder> ./wt.sh info    # imprime la derivacion completa del slot (API, BD, bus, Oracle, site, tunel)
#   ./wt.sh ls                  # lista el registro de slots (folder -> slot)
#   ./wt.sh status              # estado de los contenedores PM por worktree y del bus
#   ./wt.sh gc                  # cruza registro / API / Oracle / sites y marca huerfanos (FORCE=1 los retira)
#   ./wt.sh seed-ln             # asegura la referencia LN compartida (pm_erpln106) una sola vez
# WT se autodetecta con 'git rev-parse --show-toplevel' si el comando se corre dentro del worktree.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib/worktrees.sh"

VERB="${1:-}"; shift || true
load_env

case "$VERB" in
  up)       cmd_wt_up ;;
  down)     cmd_wt_down ;;
  ls)       cmd_wt_ls ;;
  info)     cmd_wt_info ;;
  status)   cmd_wt_status ;;
  gc)       cmd_wt_gc ;;
  seed-ln)  cmd_wt_seed_ln ;;
  *) echo "uso: $0 {up|down|ls|info|status|gc|seed-ln}   (WT=<folder>; requiere PM_TARGET=intel REMOTE=macdata)"; exit 2 ;;
esac
