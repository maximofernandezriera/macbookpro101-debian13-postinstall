# Post-instalación Debian 13 (trixie) para MacBook Pro 10,1

Script de post-instalación para **Debian 13 + GNOME** en un **MacBookPro10,1**
(MacBook Pro 15" Retina, mediados de 2012). Incluye verificación, prueba de
suspensión y **rollback** de todo lo que cambia.

## Qué hace

| Área | Acciones |
|------|----------|
| Repos APT | Añade `contrib non-free non-free-firmware` a las entradas de Debian (deb822 y formato clásico) y comenta el `cdrom:` |
| Wi-Fi BCM4331 | `--wifi=wl` (por defecto): `broadcom-sta-dkms` + cabeceras del kernel. `--wifi=b43`: driver libre + `firmware-b43-installer`. Dominio regulatorio (`--regdom`, por defecto `ES`) |
| Teclado/trackpad | USB (`hid_apple`, `bcm5974`). Opciones de `hid_apple`: `--fnmode`, `--iso-layout`, `--swap-opt-cmd`. Defaults de GNOME vía dconf (tap-to-click, scroll natural, % batería) |
| Gráficos | Intel HD 4000 + NVIDIA GT 650M con Mesa/nouveau, VA-API (`i965-va-driver`), `switcheroo-control` |
| Energía | TLP (o `--power=ppd`), thermald, **mbpfan** (ventiladores vía `applesmc`), zram, fstrim, sysctl |
| Firmware | `intel-microcode`, `firmware-misc-nonfree`, `firmware-intel-*` |

## Uso

```bash
sudo ./macbookpro101-postinstall.sh --dry-run     # ver qué haría
sudo ./macbookpro101-postinstall.sh               # instalar
sudo reboot
sudo ./macbookpro101-postinstall.sh --verify      # batería de comprobaciones
sudo ./macbookpro101-postinstall.sh --test-suspend
./macbookpro101-postinstall.sh --selftest         # autotest de la lógica (sin root)
./macbookpro101-postinstall.sh --help
```

El Mac no tiene Ethernet: durante la instalación conéctate por **tethering USB**
o con un adaptador Thunderbolt-Ethernet (el driver wifi aún no está instalado).

## Rollback

Cada ejecución guarda en `/var/lib/macbookpro101-postinstall/runs/<ID>/` un
manifiesto con:

- copia de cada fichero modificado y lista de ficheros/directorios creados,
- estado previo (enabled/masked/active) de cada servicio systemd que toca,
- paquetes instalados **y desinstalados** por apt en esa ejecución
  (p. ej. `tlp` desinstala `power-profiles-daemon`),
- foto del sistema previa (`dpkg --get-selections`, `apt-mark showmanual`, unidades).

```bash
sudo ./macbookpro101-postinstall.sh --list-backups
sudo ./macbookpro101-postinstall.sh --rollback --dry-run   # qué se desharía
sudo ./macbookpro101-postinstall.sh --rollback             # deshace la última ejecución
sudo ./macbookpro101-postinstall.sh --rollback=ID          # vuelve al estado previo a ID
sudo ./macbookpro101-postinstall.sh --rollback=all         # deshace todas
sudo ./macbookpro101-postinstall.sh --rollback --keep-packages   # solo config/servicios
```

El rollback restaura ficheros, desinstala (`purge`) los paquetes que trajo el
script, reinstala los que apt quitó, restaura servicios y regenera initramfs,
dconf y sysctl. Si desinstalar arrastrara paquetes que instalaste después,
pregunta antes (con `--yes` los conserva). Reinicia al terminar.
Como es norma en Debian, los usuarios/grupos de sistema que crean algunos
paquetes (p. ej. `polkitd`, `bluetooth`) no se borran al desinstalarlos.

Si tienes **Timeshift** (o snapper) configurado, el script crea además una
instantánea completa antes de empezar (`--no-snapshot` para omitirla).

## Notas del hardware

- El firmware EFI oculta la Intel HD 4000 si el SO no se identifica como macOS;
  el kernel 6.12 solo aplica `apple_set_os` a MacBookPro11,3/11,5 y posteriores,
  así que normalmente funcionará la NVIDIA con **nouveau**.
- El driver privativo de NVIDIA para Kepler (serie 470) no existe en Debian 13.
- La cámara FaceTime HD de este modelo es UVC: funciona sin drivers extra.
- No hay límite de carga de batería por software.

## Probado

`shellcheck`, `--selftest` y un ciclo completo instalación → verificación →
rollback en un contenedor Debian 13 con systemd (sin hardware Mac: los pasos de
módulos/hardware fallan allí como es de esperar). Tras el rollback, paquetes,
`/etc` (salvo esos usuarios de sistema) y estados de servicios vuelven a ser
idénticos a los previos.
