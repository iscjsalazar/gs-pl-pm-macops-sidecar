#!/usr/bin/env python3
"""Promueve el manifiesto CANONICO del pm-gate (config/pm-gate-manifest.json) desde una medicion
ya sellada -manifiesto de RAMA (scope=branch, producido por pm-gate-manifest-write.py) o result.json
de evidencia cruda- re-estampando procedencia fechable contra el SHA de pl-programa-maestro que
aterrizo en develop.

Uso:
  pm-gate-manifest-promote.py --canonical <config/pm-gate-manifest.json> --from <manifiesto-de-rama-o-result.json>
    --pm-sha <sha40> [--out <ruta-destino>] [--evidence <dir-de-evidencia-sellada>]
    [--trust-dirty --reason '<por que>']
    [--allow-baseline-drop --allow-baseline-drop-reason '<por que>']

--out por defecto es igual a --canonical (mueve el baseline real). Los contract tests usan --out
distinto para no pisar el canonico versionado durante una corrida de fixture.

Condiciones de confianza fail-closed (diseno T-009, analisis.md D-T009-5). Si alguna falla, el
script NO escribe nada y termina con exit != 0:

  C1 la fuente trae conteos COMPLETOS: proyectos no vacios + integracion medida (nunca heredada).
  C2 la fuente esta en VERDE: ningun proyecto ni la integracion reportan fallos; si se pasa
     --evidence, se re-verifica directo contra su result.json (mas fuerte que confiar en el
     manifiesto de rama a ciegas) Y la evidencia DEBE cubrir el mismo conjunto de proyectos
     que la fuente -- un proyecto ausente es rechazo, no omision. Sin --evidence el promote
     es modo degradado (se marca en el resumen: evidence_verified=no).
  C3 --pm-sha obligatorio, 40 hex; el script nunca lo adivina.
  C4 medicion "dirty" (branch.baseline_pm_dirty=true, o el SHA/git_head medido != --pm-sha, que es
     el caso normal de un tren pre-commit -> squash) exige --trust-dirty + --reason explicito
     declarando que el contenido medido es el que aterrizo en --pm-sha.
  C5 integration_counts_source == measured (jamas se promueve una integracion heredada del
     canonico rancio).
  C6 ninguna caida de conteos vs el canonico ACTUAL sin justificacion: si el manifiesto de rama ya
     trae esa caida exacta documentada en drops_allowed/drop_justification, la justificacion viaja
     con la fuente (no hace falta repetirla); si no, exige --allow-baseline-drop +
     --allow-baseline-drop-reason (perilla DISTINTA de ALLOW_DROP de rama, para no confundir
     canales).
  C7 el destino se escribe ATOMICO (tmp + replace).

El documento escrito lleva "evidence_verified" (bool, T-012/D41): true cuando el promote corrio
con --evidence y la re-verificacion independiente (C2) paso; false cuando el promote confio en el
auto-reporte de --from (modo degradado). El campo siempre esta presente -- ausencia de clave no es
un valor valido; los lectores/tests lo leen del archivo escrito, no de stdout.

Este script es el UNICO canal autorizado para mover config/pm-gate-manifest.json.
scripts/pm-gate-manifest-write.py sigue prohibido de tocar config/ (exit 4 en ese script; no se
relaja aqui ni en ningun otro lado).
"""

import argparse
import json
import pathlib
import re
import sys
from datetime import datetime, timezone

SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")

EXIT_INVALID_INVOCATION = 2
EXIT_NOT_GREEN_OR_INCOMPLETE = 3
EXIT_DIRTY_WITHOUT_TRUST = 5
EXIT_DROP_WITHOUT_ALLOW = 6


def refuse(code, msg):
    print(f"manifest_promote_refused: {msg}", file=sys.stderr)
    return code


def load_json(path):
    return json.loads(pathlib.Path(path).read_text())


def relativize_under_artifacts(raw):
    """Guarda una ruta de evidencia PORTABLE: desde 'artifacts/' en vez de un absoluto atado a un
    checkout (central o worktree) especifico -- el propio directorio 'artifacts/' esta gitignored
    y NO se comparte automaticamente entre worktrees del sidecar (cada checkout resuelve su BASE_DIR
    de forma independiente)."""
    if not raw:
        return raw
    parts = pathlib.PurePosixPath(str(raw).replace("\\", "/")).parts
    if "artifacts" in parts:
        idx = parts.index("artifacts")
        return "/".join(parts[idx:])
    return raw


def check_project_green(pr):
    total = int(pr.get("total") or 0)
    failed = int(pr.get("failed") or 0)
    rc = int(pr["exit_code"]) if pr.get("exit_code") is not None else 1
    return failed == 0 and rc == 0 and total > 0


def reconstruct_from_result(result):
    """C1/C2/C5 desde un result.json crudo (sin manifiesto de rama intermedio): misma logica que
    pm-gate-manifest-write.py, SIN comparar caidas contra el canonico viejo como bloqueo -- el
    proposito de esta funcion es justo reemplazar el baseline, no medir una rama."""
    projects = result.get("projects") or []
    if not projects:
        return None, None, "la evidencia no tiene proyectos"
    new_projects = []
    for pr in projects:
        path = pr.get("path") or ""
        if not check_project_green(pr):
            return None, None, (
                f"{path} no esta en verde (total={pr.get('total')} failed={pr.get('failed')} "
                f"exit_code={pr.get('exit_code')})"
            )
        kind = "architecture" if "ArchitectureTests" in path else "unit"
        new_projects.append({
            "path": path,
            "kind": kind,
            "expected_total": int(pr.get("total") or 0),
            "expected_executed": int(pr.get("executed") or 0),
            "expected_skipped": int(pr.get("skipped") or 0),
            "expected_failed": 0,
        })
    new_projects.sort(key=lambda p: p["path"])

    integ = result.get("integration") or None
    if not integ:
        return None, None, "la evidencia no trae integration (result.json.integration ausente)"
    if not check_project_green(integ):
        return None, None, (
            f"integration no esta en verde (total={integ.get('total')} failed={integ.get('failed')} "
            f"exit_code={integ.get('exit_code')})"
        )
    integ_doc = {
        "integration_expected_total": int(integ.get("total") or 0),
        "integration_expected_executed": int(integ.get("executed") or 0),
        "integration_expected_skipped": int(integ.get("skipped") or 0),
    }
    return new_projects, integ_doc, None


def from_branch_manifest(doc):
    """C1/C5 desde un manifiesto de rama ya escrito por pm-gate-manifest-write.py. C2 (verde) se
    apoya en la garantia fail-closed de ese escritor (nunca sella un proyecto rojo); si se pasa
    --evidence, el caller re-verifica en verde de forma independiente."""
    projects = doc.get("projects") or []
    if not projects:
        return None, None, "el manifiesto de rama no trae proyectos"
    declared_n = doc.get("project_count")
    if declared_n is not None and int(declared_n) != len(projects):
        return None, None, (
            f"project_count={declared_n} no coincide con len(projects)={len(projects)}"
        )
    for p in projects:
        if int(p.get("expected_failed") or 0) != 0:
            return None, None, f"{p.get('path')} declara expected_failed!=0 en el manifiesto de rama"
    if doc.get("integration_counts_source") != "measured":
        return None, None, (
            f"integration_counts_source={doc.get('integration_counts_source')!r} != 'measured' "
            "(no se promueve una integracion heredada del canonico rancio)"
        )
    new_projects = [dict(p) for p in projects]
    new_projects.sort(key=lambda p: p["path"])
    integ_doc = {
        "integration_expected_total": int(doc.get("integration_expected_total") or 0),
        "integration_expected_executed": int(doc.get("integration_expected_executed") or 0),
        "integration_expected_skipped": int(doc.get("integration_expected_skipped") or 0),
    }
    return new_projects, integ_doc, None


def verify_evidence(evidence_dir, source_doc, is_branch, new_projects, integ_doc):
    """C2 fuerte + cadena de custodia: re-lee result.json del directorio de evidencia sellado y
    exige verde ahi tambien, mas paridad de contenido/conteos contra la fuente (--from).

    Fail-closed en cobertura: la evidencia DEBE cubrir el mismo conjunto de proyectos que la
    fuente (manifiesto de rama o result.json reconstruido). Un proyecto ausente en --evidence
    es RECHAZO, no omision silenciosa -- un canonico promovido sobre evidencia incompleta
    legitimaria conteos no medidos (peor que un baseline rancio).
    """
    result_path = pathlib.Path(evidence_dir) / "result.json"
    if not result_path.is_file():
        return None, f"no existe result.json en --evidence={evidence_dir}"
    evidence = load_json(result_path)

    runner_exit_code = evidence.get("runner_exit_code")
    runner_rc = int(runner_exit_code) if runner_exit_code is not None else 1
    if evidence.get("status") != "passed" or runner_rc != 0:
        return None, (
            f"la evidencia {evidence_dir} no esta en verde "
            f"(status={evidence.get('status')!r} runner_exit_code={evidence.get('runner_exit_code')})"
        )
    for pr in evidence.get("projects") or []:
        if not check_project_green(pr):
            return None, f"la evidencia trae {pr.get('path')} no verde"
    ev_integ = evidence.get("integration") or {}
    if not check_project_green(ev_integ):
        return None, "la evidencia trae integration no verde"

    # Cobertura de proyectos (M1): set(evidencia) debe cubrir set(fuente). Ausencia = rechazo.
    ev_by_path = {p.get("path"): p for p in evidence.get("projects") or []}
    source_paths = {p["path"] for p in new_projects}
    evidence_paths = set(ev_by_path.keys())
    missing = sorted(source_paths - evidence_paths)
    if missing:
        return None, (
            "la evidencia no cubre los mismos proyectos que la fuente (--from): "
            f"faltan {len(missing)} proyecto(s): {missing}"
        )

    if is_branch:
        src_fp = source_doc.get("baseline_source_fingerprint")
        ev_fp = evidence.get("source_fingerprint")
        if src_fp and ev_fp and src_fp != ev_fp:
            return None, (
                "la evidencia no corresponde al manifiesto de rama: "
                f"baseline_source_fingerprint={src_fp!r} != evidence.source_fingerprint={ev_fp!r}"
            )
        for p in new_projects:
            ev_p = ev_by_path[p["path"]]  # presente: cobertura ya verificada arriba
            if int(ev_p.get("total") or 0) != p["expected_total"]:
                return None, (
                    f"la evidencia no coincide con el manifiesto de rama en {p['path']}: "
                    f"evidencia total={ev_p.get('total')} manifiesto expected_total={p['expected_total']}"
                )
        ev_integ_total = int(ev_integ.get("total") or 0)
        if ev_integ_total and ev_integ_total != integ_doc["integration_expected_total"]:
            return None, (
                "la evidencia no coincide con el manifiesto de rama en integration: "
                f"evidencia total={ev_integ_total} manifiesto={integ_doc['integration_expected_total']}"
            )

    return evidence, None


def compute_drops(old_canonical, new_projects, integ_doc):
    drops = []
    old_by_path = {p["path"]: p for p in old_canonical.get("projects") or []}
    new_by_path = {p["path"]: p for p in new_projects}
    for path, op in old_by_path.items():
        np = new_by_path.get(path)
        old_total = int(op.get("expected_total") or 0)
        if np is None:
            drops.append({"path": path, "from": old_total, "to": 0, "kind": "project_removed"})
        elif int(np["expected_total"]) < old_total:
            drops.append({"path": path, "from": old_total, "to": int(np["expected_total"]), "kind": "count_drop"})
    old_integ_total = int(old_canonical.get("integration_expected_total") or 0)
    if integ_doc["integration_expected_total"] < old_integ_total:
        drops.append({
            "path": old_canonical.get("integration_project", "integration"),
            "from": old_integ_total,
            "to": integ_doc["integration_expected_total"],
            "kind": "count_drop",
        })
    return drops


def drops_pre_justified(drops, source_doc, is_branch):
    if not is_branch or not drops:
        return False
    justification = (source_doc.get("drop_justification") or "").strip()
    if not justification:
        return False
    declared = {(d["path"], d["from"], d["to"]) for d in source_doc.get("drops_allowed") or []}
    return all((d["path"], d["from"], d["to"]) in declared for d in drops)


def parse_args(argv):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--canonical", required=True, help="config/pm-gate-manifest.json actual (receta + baseline viejo)")
    p.add_argument("--from", dest="from_path", required=True, help="manifiesto de rama (scope=branch) o result.json de evidencia")
    p.add_argument("--pm-sha", required=True, help="SHA de 40 hex de pl-programa-maestro que aterrizo en develop")
    p.add_argument("--out", default=None, help="destino (default: el mismo --canonical)")
    p.add_argument("--evidence", default=None, help="directorio de evidencia sellada (result.json) para re-verificar en verde")
    p.add_argument("--trust-dirty", action="store_true")
    p.add_argument("--reason", default="")
    p.add_argument("--allow-baseline-drop", action="store_true")
    p.add_argument("--allow-baseline-drop-reason", default="")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])

    if not SHA_RE.match(args.pm_sha or ""):
        return refuse(EXIT_INVALID_INVOCATION, f"--pm-sha invalido (se esperan 40 hex): {args.pm_sha!r}")

    canonical_path = pathlib.Path(args.canonical)
    from_path = pathlib.Path(args.from_path)
    if not canonical_path.is_file():
        return refuse(EXIT_INVALID_INVOCATION, f"--canonical no existe: {canonical_path}")
    if not from_path.is_file():
        return refuse(EXIT_INVALID_INVOCATION, f"--from no existe: {from_path}")

    old_canonical = load_json(canonical_path)
    source_doc = load_json(from_path)

    is_branch = source_doc.get("scope") == "branch"
    if is_branch:
        expected_integ_project = old_canonical.get("integration_project")
        source_integ_project = source_doc.get("integration_project")
        if expected_integ_project and source_integ_project and expected_integ_project != source_integ_project:
            return refuse(
                EXIT_INVALID_INVOCATION,
                f"integration_project no coincide: canonico={expected_integ_project!r} "
                f"manifiesto de rama={source_integ_project!r}",
            )
        new_projects, integ_doc, err = from_branch_manifest(source_doc)
    elif "run_id" in source_doc and "projects" in source_doc:
        new_projects, integ_doc, err = reconstruct_from_result(source_doc)
    else:
        return refuse(
            EXIT_INVALID_INVOCATION,
            "--from no es reconocible: ni manifiesto de rama (scope=branch) ni result.json (run_id+projects)",
        )
    if err:
        return refuse(EXIT_NOT_GREEN_OR_INCOMPLETE, err)

    evidence_id = ""
    evidence_dir_rel = ""
    dirty_condition = False
    if is_branch:
        dirty_condition = bool(source_doc.get("baseline_pm_dirty")) or (
            bool(source_doc.get("baseline_pm_sha")) and source_doc.get("baseline_pm_sha") != args.pm_sha
        )
        evidence_id = source_doc.get("baseline_evidence_id", "")
        evidence_dir_rel = relativize_under_artifacts(source_doc.get("baseline_evidence_dir", ""))
    else:
        dirty_condition = bool(source_doc.get("git_head")) and source_doc.get("git_head") != args.pm_sha
        evidence_id = source_doc.get("run_id", "")
        evidence_dir_rel = relativize_under_artifacts(source_doc.get("evidence_dir", ""))

    if args.evidence:
        evidence, err = verify_evidence(args.evidence, source_doc, is_branch, new_projects, integ_doc)
        if err:
            return refuse(EXIT_NOT_GREEN_OR_INCOMPLETE, err)
        evidence_id = evidence.get("run_id") or evidence_id
        evidence_dir_rel = relativize_under_artifacts(
            evidence.get("evidence_dir") or str(pathlib.Path(args.evidence))
        )
        ev_git_head = evidence.get("git_head")
        if ev_git_head:
            dirty_condition = dirty_condition or (ev_git_head != args.pm_sha)

    if dirty_condition:
        if not args.trust_dirty or not args.reason.strip():
            return refuse(
                EXIT_DIRTY_WITHOUT_TRUST,
                "la medicion de origen es dirty o su SHA/git_head difiere de --pm-sha (tren "
                "pre-commit -> squash es el caso normal): repite con --trust-dirty --reason "
                "'<por que el contenido medido es el que aterrizo en --pm-sha>', o re-corre en "
                "limpio sobre un checkout en --pm-sha.",
            )

    if not integ_doc.get("integration_expected_total"):
        return refuse(EXIT_NOT_GREEN_OR_INCOMPLETE, "integration_expected_total resulto en 0 o ausente")

    drops = compute_drops(old_canonical, new_projects, integ_doc)
    if drops:
        pre_justified = drops_pre_justified(drops, source_doc, is_branch)
        if not pre_justified:
            if not args.allow_baseline_drop or not args.allow_baseline_drop_reason.strip():
                lines = "\n".join(f"  - {d['path']}: {d['from']} -> {d['to']} ({d['kind']})" for d in drops)
                return refuse(
                    EXIT_DROP_WITHOUT_ALLOW,
                    "el promote BAJA conteos respecto del canonico actual, sin justificacion ya "
                    "documentada en el manifiesto de rama:\n" + lines +
                    "\n  Si el retiro es deliberado, repite con --allow-baseline-drop "
                    "--allow-baseline-drop-reason '<por que>' (canal DISTINTO de ALLOW_DROP de "
                    "rama), o prefiere re-medir en limpio.",
                )

    out_path = pathlib.Path(args.out) if args.out else canonical_path
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    evidence_verified = bool(args.evidence)
    doc = {
        "schema_version": old_canonical["schema_version"],
        "solution_path": old_canonical["solution_path"],
        "project_count": len(new_projects),
        "integration_project": old_canonical["integration_project"],
        "integration_expected_total": integ_doc["integration_expected_total"],
        "integration_expected_executed": integ_doc["integration_expected_executed"],
        "integration_expected_skipped": integ_doc["integration_expected_skipped"],
        "sdk_image": old_canonical["sdk_image"],
        "sdk_platform": old_canonical["sdk_platform"],
        "expected_sdk_version": old_canonical["expected_sdk_version"],
        "baseline_pm_sha": args.pm_sha,
        "baseline_evidence_id": evidence_id,
        "baseline_evidence_dir": evidence_dir_rel,
        "baseline_unit_warm_min": old_canonical.get("baseline_unit_warm_min"),
        "target_unit_incremental_min": old_canonical.get("target_unit_incremental_min"),
        "required_assets": old_canonical["required_assets"],
        "projects": new_projects,
        "scope": "canonical",
        "generated_at": now_iso,
        "generated_by": "make pm-gate-manifest-promote",
        "commit": args.pm_sha,
        "evidence_verified": evidence_verified,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(json.dumps(doc, indent=2) + "\n")
    tmp.replace(out_path)

    unit_total = sum(p["expected_total"] for p in new_projects)
    # S2: el modo sin --evidence es degradado (confia en el auto-reporte de la fuente); se marca
    # de forma auditable en el resumen maquina-legible y con aviso en stderr.
    if not evidence_verified:
        print(
            "manifest_promote_warn: promote SIN --evidence (modo degradado: sin re-verificacion "
            "independiente; la confianza depende del auto-reporte de --from). Preferir "
            "EVIDENCE=<dir> con el result.json sellado de la medicion.",
            file=sys.stderr,
        )
    print(
        f"manifest_promote_ok out={out_path} commit={args.pm_sha} generated_at={now_iso} "
        f"unit_total={unit_total} integration_total={integ_doc['integration_expected_total']} "
        f"projects={len(new_projects)} drops={len(drops)} "
        f"evidence_verified={'yes' if evidence_verified else 'no'}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
