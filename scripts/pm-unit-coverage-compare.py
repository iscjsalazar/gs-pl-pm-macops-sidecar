#!/usr/bin/env python3
"""Compara los conteos reales de la corrida unit contra el manifiesto ACTIVO de la fase.

Uso: pm-unit-coverage-compare.py <summary.json> <projects.jsonl> <manifest.json>

Escribe:
  <projects.jsonl>                        una linea por proyecto con conteos reales y baseline_match
  <dir de summary>/coverage_ok.txt        1|0 veredicto de la fase
  <dir de summary>/coverage_class.txt     ok | counts_only | red | structural
  <dir de summary>/coverage_reasons.txt   motivo por proyecto desviado

Intencion del guard (no se relaja): un proyecto que pierde pruebas en silencio, una suite cortada
o un rojo invalidan la fase. La clase `counts_only` distingue el caso en el que NINGUN proyecto
tiene rojos ni rc!=0 y la unica diferencia son los conteos respecto del baseline pinneado: esa es
la desviacion legitima de una rama con pruebas nuevas, y el orquestador la reporta con
reason_code=coverage_manifest_mismatch en vez del engañoso unit_failed_failfast.

PM_UNIT_REGEN=1 (verbo de regeneracion del manifiesto) convierte `counts_only` en insumo: la fase
pasa para que el escritor lea los conteos reales de la rama. Un rojo, un rc!=0 o una desviacion
estructural siguen cortando incluso en regeneracion.
"""

import json
import os
import pathlib
import sys


def main():
    if len(sys.argv) != 4:
        print("uso: pm-unit-coverage-compare.py <summary.json> <projects.jsonl> <manifest.json>",
              file=sys.stderr)
        return 2

    summary_path = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2])
    manifest_path = pathlib.Path(sys.argv[3])

    summary = json.load(open(summary_path))
    mf = json.load(open(manifest_path))
    exp = {p["path"]: p for p in mf["projects"]}
    expected_n = int(mf.get("project_count") or len(mf["projects"]))
    regen = os.environ.get("PM_UNIT_REGEN", "0") == "1"

    lines = []
    reasons = []
    counts_deviated = False
    red = False
    structural = False

    for i, pr in enumerate(summary.get("projects") or [], 1):
        path = pr.get("path")
        e = exp.get(path)
        if e is None:
            structural = True
            e = {}
            reasons.append(f"{path}: proyecto ausente del manifiesto activo")
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
        if failed > 0 or rc != 0 or total <= 0:
            red = True
        elif not match:
            counts_deviated = True
        if not match:
            reasons.append(
                f"{path}: total={total}/{e.get('expected_total')} exec={executed} "
                f"skip={skipped} fail={failed} rc={rc}"
            )
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

    restore_rc = summary.get("restore_rc")
    build_rc = summary.get("build_rc")
    if restore_rc != 0 or build_rc != 0:
        red = True
    if len(lines) != expected_n:
        structural = True
        reasons.append(f"proyectos ejecutados={len(lines)} (manifiesto activo espera {expected_n})")

    if structural:
        klass = "structural"
    elif red:
        klass = "red"
    elif counts_deviated:
        klass = "counts_only"
    else:
        klass = "ok"

    ok = klass == "ok" or (regen and klass == "counts_only")

    (summary_path.parent / "coverage_ok.txt").write_text("1\n" if ok else "0\n")
    (summary_path.parent / "coverage_class.txt").write_text(klass + "\n")
    (summary_path.parent / "coverage_reasons.txt").write_text("\n".join(reasons) + "\n")
    print("projects", len(lines), klass, "regen" if regen else "")
    return 0


if __name__ == "__main__":
    sys.exit(main())
