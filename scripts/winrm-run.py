#!/usr/bin/env python3
"""Ejecuta un script PowerShell en el guest Windows via WinRM.
Credenciales/host por entorno: WINHOST, WINUSER (def Administrator), WINPASS.
PS por argumentos o por stdin (pasar '-' como arg)."""
import os, sys, winrm

host = os.environ.get("WINHOST", "172.16.128.129")
user = os.environ.get("WINUSER", "Administrator")
pw   = os.environ["WINPASS"]
ps = sys.stdin.read() if (len(sys.argv) > 1 and sys.argv[1] == "-") else " ".join(sys.argv[1:])

s = winrm.Session(f"http://{host}:5985/wsman", auth=(user, pw), transport="basic")
r = s.run_ps(ps)
sys.stdout.write(r.std_out.decode("utf-8", "ignore"))
err = r.std_err.decode("utf-8", "ignore")
if err.strip():
    sys.stderr.write("\n[STDERR]\n" + err)
sys.exit(r.status_code)
