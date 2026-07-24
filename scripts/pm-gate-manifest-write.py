#!/usr/bin/env python3
"""Escribe un manifiesto de RAMA del pm-gate a partir de la evidencia real de una corrida.

Uso: pm-gate-manifest-write.py <base-manifest.json> <result.json> <out.json> <canonical-manifest.json>

El manifiesto de rama copia la identidad de la receta del manifiesto base (SDK pinneado, assets
requeridos, proyecto de integracion) y reemplaza los conteos esperados por los conteos REALES que
la evidencia sellada registra, junto con la procedencia (`baseline_pm_sha`, rama, limpieza del
arbol, huella de fuente y run_id que lo produjo).

Reglas fail-closed:
  * Nunca escribe sobre el manifiesto canonico ni dentro de su directorio (exit 4).
  * Un solo proyecto rojo, con rc!=0 o con total<=0 invalida la regeneracion (exit 3): un baseline
    no se sella desde una corrida que no probo nada o que probo mal.
  * Una CAIDA de conteos respecto del manifiesto canonico (proyecto retirado, o menos pruebas que
    el baseline) se rechaza (exit 5) salvo PM_GATE_MANIFEST_ALLOW_DROP=1, y en ese caso queda
    registrada en el manifiesto con su justificacion. Esa es la intencion del guard: la perdida de
    cobertura nunca es silenciosa.

Variables de entorno de procedencia: PM_GATE_MANIFEST_ALLOW_DROP, PM_GATE_MANIFEST_REASON,
PM_GATE_MANIFEST_PM_SHA, PM_GATE_MANIFEST_PM_BRANCH, PM_GATE_MANIFEST_PM_DIRTY,
PM_GATE_MANIFEST_RUN_ID, PM_GATE_MANIFEST_EVIDENCE_DIR, PM_GATE_MANIFEST_SOURCE_FP,
PM_GATE_MANIFEST_GENERATED_AT, PM_GATE_MANIFEST_WT.
"""

import json
import os
import pathlib
import sys


def env(key, default=""):
    return os.environ.get(key, default)


def main():
    if len(sys.argv) != 5:
        print("uso: pm-gate-manifest-write.py <base> <result.json> <out.json> <canonical>",
              file=sys.stderr)
        return 2

    base_path = pathlib.Path(sys.argv[1])
    result_path = pathlib.Path(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])
    canonical_path = pathlib.Path(sys.argv[4])

    base = json.load(open(base_path))
    result = json.load(open(result_path))
    canonical = json.load(open(canonical_path))

    # --- 1) jamas sobre el manifiesto canonico ---
    canon_abs = canonical_path.resolve()
    out_abs = out_path.resolve() if out_path.exists() else (out_path.parent.resolve() / out_path.name)
    if out_abs == canon_abs or out_abs.parent == canon_abs.parent:
        print(f"manifest_regen_refused: OUT={out_abs} vive en el directorio del manifiesto canonico "
              f"({canon_abs.parent}); el manifiesto de rama se escribe fuera de config/", file=sys.stderr)
        return 4

    # --- 2) conteos reales desde la evidencia ---
    projects = result.get("projects") or []
    if not projects:
        print("manifest_regen_refused: la evidencia no tiene proyectos", file=sys.stderr)
        return 3

    base_by_path = {p["path"]: p for p in base.get("projects") or []}
    canon_by_path = {p["path"]: p for p in canonical.get("projects") or []}

    new_projects = []
    for pr in projects:
        path = pr.get("path") or ""
        total = int(pr.get("total") or 0)
        executed = int(pr.get("executed") or 0)
        skipped = int(pr.get("skipped") or 0)
        failed = int(pr.get("failed") or 0)
        rc = int(pr["exit_code"]) if pr.get("exit_code") is not None else 1
        if failed > 0 or rc != 0 or total <= 0:
            print(f"manifest_regen_refused: {path} no esta verde (total={total} failed={failed} rc={rc}); "
                  "un baseline no se regenera desde una corrida roja", file=sys.stderr)
            return 3
        kind = (base_by_path.get(path) or {}).get("kind")
        if not kind:
            kind = "architecture" if "ArchitectureTests" in path else "unit"
        new_projects.append({
            "path": path,
            "kind": kind,
            "expected_total": total,
            "expected_executed": executed,
            "expected_skipped": skipped,
            "expected_failed": 0,
        })
    new_projects.sort(key=lambda p: p["path"])
    new_by_path = {p["path"]: p for p in new_projects}

    # --- 3) integracion: real si la evidencia la trae verde; heredada si no ---
    integ = result.get("integration") or None
    integ_source = "inherited_from_canonical"
    integ_total = int(canonical.get("integration_expected_total") or 0)
    integ_exec = int(canonical.get("integration_expected_executed") or 0)
    integ_skip = int(canonical.get("integration_expected_skipped") or 0)
    if integ:
        i_total = int(integ.get("total") or 0)
        i_failed = int(integ.get("failed") or 0)
        i_rc = int(integ["exit_code"]) if integ.get("exit_code") is not None else 1
        if i_failed == 0 and i_rc == 0 and i_total > 0:
            integ_total = i_total
            integ_exec = int(integ.get("executed") or 0)
            integ_skip = int(integ.get("skipped") or 0)
            integ_source = "measured"
        else:
            print(f"manifest_regen_refused: la fase de integracion de la evidencia no esta verde "
                  f"(total={i_total} failed={i_failed} rc={i_rc})", file=sys.stderr)
            return 3

    # --- 4) guard de caida de cobertura contra el manifiesto canonico ---
    drops = []
    for path, cp in canon_by_path.items():
        np = new_by_path.get(path)
        if np is None:
            drops.append({"path": path, "from": cp["expected_total"], "to": 0,
                          "kind": "project_removed"})
        elif np["expected_total"] < cp["expected_total"]:
            drops.append({"path": path, "from": cp["expected_total"], "to": np["expected_total"],
                          "kind": "count_drop"})
    canon_integ = int(canonical.get("integration_expected_total") or 0)
    if integ_source == "measured" and integ_total < canon_integ:
        drops.append({"path": canonical.get("integration_project", "integration"),
                      "from": canon_integ, "to": integ_total, "kind": "count_drop"})

    allow_drop = env("PM_GATE_MANIFEST_ALLOW_DROP", "0") == "1"
    reason = env("PM_GATE_MANIFEST_REASON", "").strip()
    if drops and not allow_drop:
        print("manifest_regen_refused: la rama PIERDE cobertura respecto del baseline canonico:",
              file=sys.stderr)
        for d in drops:
            print(f"  - {d['path']}: {d['from']} -> {d['to']} ({d['kind']})", file=sys.stderr)
        print("  Si el retiro es deliberado, repite con ALLOW_DROP=1 REASON='<por que>' "
              "(queda registrado en el manifiesto de rama).", file=sys.stderr)
        return 5
    if drops and allow_drop and not reason:
        print("manifest_regen_refused: ALLOW_DROP=1 exige REASON='<por que>' (queda registrada)",
              file=sys.stderr)
        return 5

    # --- 5) escribe el manifiesto de rama ---
    doc = dict(base)
    doc["project_count"] = len(new_projects)
    doc["projects"] = new_projects
    doc["integration_expected_total"] = integ_total
    doc["integration_expected_executed"] = integ_exec
    doc["integration_expected_skipped"] = integ_skip
    doc["integration_counts_source"] = integ_source
    doc["scope"] = "branch"
    doc["derived_from"] = str(canon_abs)
    doc["baseline_pm_sha"] = env("PM_GATE_MANIFEST_PM_SHA", result.get("git_head", ""))
    doc["baseline_pm_branch"] = env("PM_GATE_MANIFEST_PM_BRANCH")
    doc["baseline_pm_dirty"] = env("PM_GATE_MANIFEST_PM_DIRTY", "0") == "1"
    doc["baseline_source_fingerprint"] = env("PM_GATE_MANIFEST_SOURCE_FP",
                                             result.get("source_fingerprint", ""))
    doc["baseline_evidence_id"] = env("PM_GATE_MANIFEST_RUN_ID", result.get("run_id", ""))
    doc["baseline_evidence_dir"] = env("PM_GATE_MANIFEST_EVIDENCE_DIR",
                                       result.get("evidence_dir", ""))
    doc["baseline_wt"] = env("PM_GATE_MANIFEST_WT", result.get("wt_input", ""))
    doc["generated_at"] = env("PM_GATE_MANIFEST_GENERATED_AT")
    doc["generated_by"] = "make pm-gate-manifest-regen"
    doc["drops_allowed"] = drops
    doc["drop_justification"] = reason

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n")
    tmp.replace(out_path)

    unit_total = sum(p["expected_total"] for p in new_projects)
    print(f"manifest_regen_ok out={out_path} projects={len(new_projects)} unit_total={unit_total} "
          f"integration_total={integ_total} ({integ_source}) drops={len(drops)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
