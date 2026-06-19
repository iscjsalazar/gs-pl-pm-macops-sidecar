# Instalar VMware Fusion en la `macdata` (pasos actualizados, 2026)

> **Por qué manual**: el cask `vmware-fusion` de Homebrew quedó **deshabilitado el 2025-06-23** porque Broadcom
> ahora exige **login** para descargar Fusion. Sigue siendo **gratis** (Fusion Pro 13.x, uso personal y
> comercial desde fin 2024), pero la descarga es por el **portal de Broadcom**.
> **Tu parte manual** se reduce a: **(2) descargar el `.dmg`** y **(4) aprobar el kext una vez**. El resto
> (montaje/instalación y todo el spike) lo hace el agente **por SSH**.

## Ya hecho por el agente (por SSH, sin GUI)
- Folder exclusivo en la macdata: `~/pm-host-windows/` (`artifacts/{iso,vms,downloads,cache,stage}`, `packer/`, `scripts/`).
- `packer` 1.15.4 + `jq` instalados.
- **ISO Windows Server 2022 descargado y verificado**: `~/pm-host-windows/artifacts/iso/SERVER_EVAL_x64FRE_en-us.iso`
  (5,044,094,976 bytes, eval 180 días, sin product key).

## Paso 1 — Cuenta Broadcom (gratis) — *tú*
- Entra a <https://support.broadcom.com> → **Login**; si no tienes, **Register** (cuenta gratuita).
  (Broadcom absorbió VMware; el viejo "Customer Connect" vive ahora aquí.)

## Paso 2 — Descargar VMware Fusion (gratis) — *tú*
- En el portal, selector de división arriba → **VMware Cloud Foundation**, o ve directo a **My Downloads**.
- Busca **"VMware Fusion"** → **VMware Fusion 13 Pro** → última (p.ej. **13.6.x**) → acepta los *Terms & Conditions*
  → descarga el `.dmg` **Universal** (sirve en Intel). Nombre tipo `VMware-Fusion-13.6.x-XXXXXXXX_universal.dmg`.
- Si el portal pide un "entitlement", haz clic en el producto gratuito de Fusion para habilitarlo.

## Paso 3 — Dejar el `.dmg` en el folder exclusivo — *tú deja el archivo, yo instalo*
- Si lo bajaste **en la macdata**: muévelo a `~/pm-host-windows/artifacts/downloads/`.
- Si lo bajaste **en otra Mac**: cópialo por scp →
  `scp VMware-Fusion-*_universal.dmg macdata:~/pm-host-windows/artifacts/downloads/`
- **Avísame** cuando esté ahí: el agente monta el dmg e instala `VMware Fusion.app` por SSH
  (`hdiutil attach` + copia a `/Applications`; si tu usuario no es admin, te paso el comando con `sudo`).

## Paso 4 — Aprobar la extensión de sistema (kext) — *tú* (ÚNICO paso GUI)
- Abre **VMware Fusion.app** una vez en la **sesión gráfica** de la macdata (físicamente o por **Compartir
  Pantalla / Screen Sharing**).
- macOS dirá *"Se bloqueó una extensión del sistema"* → **Ajustes del Sistema → Privacidad y Seguridad** →
  **Permitir** para *Broadcom Inc. / VMware*.
- Si pide **reiniciar**, reinicia. (En **Intel + Sequoia** es *Permitir + reinicio*; **no** Recovery — eso es
  solo Apple Silicon.)
- Acepta el **EULA** y elige **uso personal/gratuito** (o pega la license key gratuita si la pide).

## Paso 5 — El agente verifica y sigue (por SSH)
- Verifica `"/Applications/VMware Fusion.app/Contents/Library/vmrun"`.
- Construye la VM **Windows Server 2022 Core headless** con **Packer (builder `vmware-iso`)** desde el ISO ya
  descargado, y continúa el spike F3→F5 (arranque headless, compilar con MSBuild, publicar a IIS, smoke test).
  Todo por SSH; no vuelves a tocar GUI.

## Reparto rápido
| Paso | Quién |
|---|---|
| 1 cuenta Broadcom · 2 descargar dmg · 4 aprobar kext (GUI) | **tú** |
| 3 montar/instalar el .app · 5 vmrun + Packer + spike completo | **agente (SSH)** |
