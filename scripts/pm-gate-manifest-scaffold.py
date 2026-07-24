#!/usr/bin/env python3
"""Arma el manifiesto ANDAMIO con el que corre la fase de regeneracion.

Uso: pm-gate-manifest-scaffold.py <base-manifest.json> <solution-dir> <out.json>

La validacion del manifiesto exige que la lista de proyectos coincida exactamente con el
descubrimiento del arbol (`tests/*/ *.UnitTests.csproj` y `*.ArchitectureTests.csproj`). Una rama
que agrega o retira un proyecto de pruebas no puede correr ni siquiera para MEDIRSE contra el
manifiesto canonico. El andamio resuelve ese arranque: toma la lista de proyectos del arbol real y
conserva del manifiesto base la identidad de la receta (SDK pinneado, assets, proyecto de
integracion) y los conteos conocidos; los proyectos nuevos entran con un conteo marcador de 1.

El andamio NO es un baseline: solo habilita la corrida de observacion (PM_UNIT_REGEN=1) de la que
sale el manifiesto de rama con conteos reales.
"""

import json
import pathlib
import sys


def main():
    if len(sys.argv) != 4:
        print("uso: pm-gate-manifest-scaffold.py <base-manifest.json> <solution-dir> <out.json>",
              file=sys.stderr)
        return 2

    base = json.load(open(sys.argv[1]))
    sol = pathlib.Path(sys.argv[2])
    out_path = pathlib.Path(sys.argv[3])

    found = []
    tests = sol / "tests"
    if tests.is_dir():
        for pat in ("*.UnitTests.csproj", "*.ArchitectureTests.csproj"):
            for f in tests.glob(f"*/{pat}"):
                found.append(str(f.relative_to(sol)).replace("\\", "/"))
    found = sorted(set(found))
    if not found:
        print(f"scaffold_invalid: no hay proyectos de prueba bajo {tests}", file=sys.stderr)
        return 3

    base_by_path = {p["path"]: p for p in base.get("projects") or []}
    projects = []
    placeholders = []
    for path in found:
        known = base_by_path.get(path)
        if known:
            projects.append(dict(known))
            continue
        placeholders.append(path)
        projects.append({
            "path": path,
            "kind": "architecture" if "ArchitectureTests" in path else "unit",
            "expected_total": 1,
            "expected_executed": 1,
            "expected_skipped": 0,
            "expected_failed": 0,
        })

    doc = dict(base)
    doc["projects"] = projects
    doc["project_count"] = len(projects)
    doc["scope"] = "scaffold"
    doc["scaffold_placeholder_projects"] = placeholders
    doc["scaffold_removed_projects"] = sorted(set(base_by_path) - set(found))

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n")
    tmp.replace(out_path)
    print(f"scaffold_ok out={out_path} projects={len(projects)} nuevos={len(placeholders)} "
          f"retirados={len(doc['scaffold_removed_projects'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
