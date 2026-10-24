#!/usr/bin/env bash
#
# macbookpro101-postinstall.sh
# Post-instalación para Debian 13 (trixie) + GNOME en MacBookPro10,1
# (MacBook Pro 15" Retina, mediados de 2012: Intel HD 4000 + NVIDIA GT 650M,
#  wifi Broadcom BCM4331, teclado/trackpad USB, SSD SATA).
#
# Uso (como root):
#   ./macbookpro101-postinstall.sh                   # instala y configura todo
#   ./macbookpro101-postinstall.sh --verify          # batería de pruebas (tras reiniciar)
#   ./macbookpro101-postinstall.sh --test-suspend    # prueba de suspensión + consumo
#   ./macbookpro101-postinstall.sh --list-backups    # lista las ejecuciones registradas
#   ./macbookpro101-postinstall.sh --rollback        # deshace la última ejecución
#   ./macbookpro101-postinstall.sh --rollback=ID|all # deshace hasta ID (incluida) o todas
#   ./macbookpro101-postinstall.sh --selftest        # prueba la lógica interna (sin tocar el sistema)
#   ./macbookpro101-postinstall.sh --help
#
# Opciones de instalación:
#   --dry-run  --force  --no-zram  --no-snapshot  --power=tlp|ppd  --wifi=wl|b43
#   --regdom=XX  --fnmode=0|1|2|3  --iso-layout=-1|0|1  --swap-opt-cmd=0|1|2
# Opciones de rollback:
#   --keep-packages (no desinstala paquetes)  --yes (sin confirmación)  --dry-run
#
set -uo pipefail
shopt -s lastpipe   # "… | put_file" debe ejecutarse en el shell actual (registro de cambios)

SCRIPT_VERSION="2.0.0"
TARGET_MODEL="MacBookPro10,1"
LOG_FILE="/var/log/macbookpro101-postinstall.log"
STATE_DIR="/var/lib/macbookpro101-postinstall"
RUNS_DIR="${STATE_DIR}/runs"
LOCK_FILE="/run/macbookpro101-postinstall.lock"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_DIR=""
BACKUP_DIR=""
MANIFEST=""

REGDOM="${REGDOM:-ES}"
POWER_MGR="${POWER_MGR:-tlp}"     # tlp | ppd (power-profiles-daemon, el de GNOME)
WIFI_DRV="${WIFI_DRV:-wl}"        # wl (broadcom-sta-dkms) | b43 (libre + firmware descargado)
APT_COMPONENTS="contrib non-free non-free-firmware"
WITH_ZRAM=1
WITH_SNAPSHOT=1
DRY_RUN=0
FORCE=0
ASSUME_YES=0
KEEP_PACKAGES=0
MODE="install"
ROLLBACK_TARGET="last"
FNMODE=""
ISO_LAYOUT=""
SWAP_OPT_CMD=""
NEED_INITRAMFS=0

REAL_USER="${SUDO_USER:-}"
if [[ -z "$REAL_USER" || "$REAL_USER" == root ]]; then
  REAL_USER="$(getent passwd 1000 2>/dev/null | cut -d: -f1)"
fi

if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_B=""; C_0=""
fi

N_PASS=0; N_WARN=0; N_FAIL=0
declare -A TRACKED=()

# ----------------------------------------------------------------- utilidades
log()  { { printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"; } 2>/dev/null || true; }
info() { printf '%s\n' "$*"; log "INFO $*"; }
step() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; log "STEP $*"; }
note() { printf '         %s\n' "$*"; log "NOTE $*"; }
pass() { printf '  [%sOK%s]   %s\n'   "$C_OK"   "$C_0" "$*"; log "PASS $*"; N_PASS=$((N_PASS+1)); }
warnc(){ printf '  [%sAVISO%s] %s\n'  "$C_WARN" "$C_0" "$*"; log "WARN $*"; N_WARN=$((N_WARN+1)); }
failc(){ printf '  [%sFALLO%s] %s\n'  "$C_ERR"  "$C_0" "$*"; log "FAIL $*"; N_FAIL=$((N_FAIL+1)); }
have() { command -v "$1" >/dev/null 2>&1; }
die()  { failc "$*"; exit 1; }

# Ejecuta un comando registrando la salida en el log (respeta --dry-run)
run() {
  log "RUN $*"
  if ((DRY_RUN)); then printf '  [dry-run] %s\n' "$*"; return 0; fi
  "$@" >>"$LOG_FILE" 2>&1
}
# Igual, pero mostrando la salida en pantalla (apt, builds…)
run_v() {
  log "RUN $*"
  if ((DRY_RUN)); then printf '  [dry-run] %s\n' "$*"; return 0; fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

confirm() { # confirm "pregunta"  -> 0 si el usuario acepta
  ((ASSUME_YES)) && return 0
  [[ -t 0 ]] || { warnc "Sin terminal interactiva: usa --yes para confirmar"; return 1; }
  local r; read -r -p "$1 [s/N] " r
  [[ "$r" =~ ^[sSyY]$ ]]
}

as_user() {
  [[ -n "$REAL_USER" ]] || return 1
  local uid; uid=$(id -u "$REAL_USER" 2>/dev/null) || return 1
  runuser -u "$REAL_USER" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

acquire_lock() {
  exec 9>"$LOCK_FILE" || die "No se pudo crear $LOCK_FILE"
  flock -n 9 || die "Ya hay otra ejecución de este script en marcha"
}

mod_exists() { modinfo "$1" >/dev/null 2>&1; }
mod_loaded() { [[ -d "/sys/module/${1//-/_}" ]]; }

bat_dir() {
  local d
  for d in /sys/class/power_supply/BAT*; do
    [[ -d "$d" ]] && { echo "$d"; return 0; }
  done
  return 1
}

# ================================================== registro de cambios (rollback)
# Cada ejecución de instalación crea  $RUNS_DIR/<ID>/  con:
#   manifest   líneas separadas por TAB, en orden cronológico:
#                MOD <ruta>                  existía: copia en files/<ruta>
#                NEW <ruta>                  no existía: se borra al deshacer
#                NEWDIR <dir>                directorio creado: rmdir si queda vacío
#                UNIT <unidad> <enabled> <active>   estado previo de systemd
#                PKGNEW <paquete>            instalado en esta ejecución
#                PKGGONE <paquete>           desinstalado por apt en esta ejecución
#                SNAPSHOT <herramienta> <descripción>
#   files/     copia de seguridad de los ficheros modificados
#   status     in-progress | done | interrupted | rolled-back
#   *.txt      foto del sistema previa (paquetes, servicios) para consulta

manifest() {
  ((DRY_RUN)) && return 0
  [[ -n "$MANIFEST" ]] || return 0
  local IFS=$'\t'
  printf '%s\n' "$*" >>"$MANIFEST"
}

track_new_parents() {
  local d=$1 list=()
  while [[ ! -e "$d" && "$d" != / && "$d" != . ]]; do list=("$d" "${list[@]}"); d=$(dirname "$d"); done
  for d in "${list[@]}"; do
    [[ -n "${TRACKED[$d]:-}" ]] && continue
    TRACKED[$d]=1
    manifest NEWDIR "$d"
  done
}

# Guarda el estado previo de una ruta (una sola vez por ejecución) antes de tocarla
track_path() {
  local p=$1
  [[ -n "${TRACKED[$p]:-}" ]] && return 0
  ((DRY_RUN)) && return 0
  TRACKED[$p]=1
  if [[ -n "$MANIFEST" ]] && grep -qxF -e "MOD"$'\t'"$p" -e "NEW"$'\t'"$p" "$MANIFEST" 2>/dev/null; then
    return 0
  fi
  if [[ -e "$p" || -L "$p" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a --parents -- "$p" "$BACKUP_DIR"/ || { failc "No se pudo hacer copia de $p"; return 1; }
    manifest MOD "$p"
  else
    track_new_parents "$(dirname "$p")"
    manifest NEW "$p"
  fi
}
backup_file() { track_path "$1"; }

# Registra el estado previo de una unidad systemd (una sola vez por ejecución)
track_unit() {
  local u=$1 en act
  [[ -n "${TRACKED[unit:$u]:-}" ]] && return 0
  ((DRY_RUN)) && return 0
  TRACKED[unit:$u]=1
  # Estado al INICIO de la ejecución (los postinst de apt pueden haberlo cambiado ya,
  # p. ej. tlp enmascara systemd-rfkill); "not-found" = unidad que trajo esta ejecución.
  en=$(awk -v u="$u" '$1 == u {print $2; exit}' "$RUN_DIR/unit-files.txt" 2>/dev/null)
  if [[ -z "$en" && "$u" == *@?*.* ]]; then en=$(systemctl is-enabled "$u" 2>/dev/null); fi
  [[ -n "$en" ]] || en=not-found
  act=inactive
  awk -v u="$u" '$1 == u {f = 1} END {exit !f}' "$RUN_DIR/units-active.txt" 2>/dev/null && act=active
  manifest UNIT "$u" "$en" "$act"
}

# svc ACCIÓN [--now] UNIDAD...  : systemctl registrando el estado previo
svc() {
  local a
  for a in "$@"; do
    case "$a" in -*|enable|disable|mask|unmask|start|stop|restart) ;; *) track_unit "$a" ;; esac
  done
  run systemctl "$@"
}

pkg_snapshot() {
  dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null \
    | awk '$1 ~ /^ii/ {print $2}' | sort -u
}

start_run() {
  RUN_DIR="${RUNS_DIR}/${RUN_ID}"
  BACKUP_DIR="${RUN_DIR}/files"
  MANIFEST="${RUN_DIR}/manifest"
  ((DRY_RUN)) && { RUN_DIR=""; MANIFEST=""; return 0; }
  mkdir -p "$BACKUP_DIR"; chmod 700 "$STATE_DIR" "$RUNS_DIR" "$RUN_DIR"
  : >"$MANIFEST"
  echo in-progress >"$RUN_DIR/status"
  {
    echo "version=$SCRIPT_VERSION"; echo "date=$(date -Is)"; echo "kernel=$(uname -r)"
    echo "args=$ORIG_ARGS"
  } >"$RUN_DIR/info"
  dpkg --get-selections >"$RUN_DIR/dpkg-selections.txt" 2>/dev/null
  apt-mark showmanual >"$RUN_DIR/apt-manual.txt" 2>/dev/null
  systemctl list-unit-files --no-pager --no-legend >"$RUN_DIR/unit-files.txt" 2>/dev/null
  systemctl list-units --all --plain --no-pager --no-legend --state=active 2>/dev/null \
    | awk '{print $1}' >"$RUN_DIR/units-active.txt"
  find /etc -xdev >"$RUN_DIR/etc-paths.txt" 2>/dev/null
  trap on_interrupt INT TERM
}
finish_run() { [[ -n "$RUN_DIR" ]] && echo "$1" >"$RUN_DIR/status"; }
on_interrupt() {
  finish_run interrupted
  printf '\n'; warnc "Interrumpido. Puedes deshacer lo aplicado con:  sudo $0 --rollback"
  exit 130
}

# ----------------------------------------------------------- ficheros
# put_file DESTINO [modo]  (contenido por stdin). Con copia de seguridad.
put_file() {
  local dest=$1 mode=${2:-644} content
  content=$(cat)
  if ((DRY_RUN)); then info "  [dry-run] escribiría $dest"; return 0; fi
  track_path "$dest" || return 1
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" >"$dest"
  chmod "$mode" "$dest"
  log "WROTE $dest"
}

# ensure_line FICHERO LINEA : añade la línea si no existe (idempotente)
ensure_line() {
  local f=$1 l=$2
  grep -qxF -- "$l" "$f" 2>/dev/null && return 0
  if ((DRY_RUN)); then info "  [dry-run] añadiría '$l' a $f"; return 0; fi
  track_path "$f" || return 1
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$l" >>"$f"
  log "APPENDED '$l' -> $f"
}

# Añade los componentes $APT_COMPONENTS a las entradas de Debian de un fichero APT.
# Devuelve 0 si hubo cambios.
fix_components_file() {
  local f=$1 tmp changed=1
  [[ -f "$f" ]] || return 1
  tmp=$(mktemp)
  case "$f" in
    *.sources)
      awk -v want="$APT_COMPONENTS" '
        function addc(l,   n, w, i) {
          n = split(want, w, " ")
          for (i = 1; i <= n; i++) if (index(l " ", " " w[i] " ") == 0) l = l " " w[i]
          return l
        }
        function flush(   i, l) {
          for (i = 1; i <= n; i++) {
            l = buf[i]
            if (isdeb && l ~ /^Components:/) { sub(/[[:space:]]+$/, "", l); l = addc(l) }
            print l
          }
          n = 0; isdeb = 0
        }
        /^[[:space:]]*$/ { flush(); print; next }
        { buf[++n] = $0; if ($0 ~ /^URIs:.*debian\.org/) isdeb = 1 }
        END { flush() }' "$f" >"$tmp"
      ;;
    *)
      awk -v want="$APT_COMPONENTS" '
        /^deb(-src)?[[:space:]]/ && /debian\.org/ {
          l = $0; sub(/[[:space:]]+$/, "", l)
          n = split(want, w, " ")
          for (i = 1; i <= n; i++) if (index(l " ", " " w[i] " ") == 0) l = l " " w[i]
          print l; next
        }
        { print }' "$f" >"$tmp"
      ;;
  esac
  if ! cmp -s "$f" "$tmp"; then
    changed=0
    if ((!DRY_RUN)); then track_path "$f" && cat "$tmp" >"$f"; fi
  fi
  rm -f "$tmp"
  return "$changed"
}

# Instala solo los paquetes que existen en los repos (informa de los que faltan)
# y registra qué paquetes se instalaron o desinstalaron realmente.
apt_install() {
  local p avail=() miss=() before after rc
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else miss+=("$p"); fi
  done
  ((${#miss[@]})) && warnc "Paquetes no disponibles en los repos (se omiten): ${miss[*]}"
  ((${#avail[@]})) || return 0
  ((DRY_RUN)) || before=$(pkg_snapshot)
  DEBIAN_FRONTEND=noninteractive run_v apt-get install -y \
      -o Dpkg::Options::=--force-confold "${avail[@]}"
  rc=$?
  if ((!DRY_RUN)); then
    after=$(pkg_snapshot)
    while read -r p; do [[ -n "$p" ]] && manifest PKGNEW "$p"; done < <(comm -13 <(echo "$before") <(echo "$after"))
    while read -r p; do [[ -n "$p" ]] && manifest PKGGONE "$p"; done < <(comm -23 <(echo "$before") <(echo "$after"))
  fi
  if ((rc == 0)); then pass "Instalados: ${avail[*]}"
  else failc "apt-get install falló para: ${avail[*]} (ver $LOG_FILE)"; return 1; fi
}

default_route_dev() { ip -o route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# ------------------------------------------------------------------ preflight
preflight() {
  step "Comprobaciones previas"
  [[ $EUID -eq 0 ]] || die "Ejecuta como root (sudo -i  o  su -)"
  mkdir -p "$STATE_DIR"; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
  acquire_lock

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${VERSION_CODENAME:-}" == "trixie" ]]; then pass "Debian 13 (trixie)"
  elif ((FORCE)); then warnc "Sistema: ${PRETTY_NAME:-?} (continúo por --force)"
  else die "Se esperaba Debian 13 (trixie), detectado: ${PRETTY_NAME:-?}. Usa --force para ignorar."; fi

  local prod; prod=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "?")
  if [[ "$prod" == "$TARGET_MODEL" ]]; then pass "Hardware: $prod"
  elif ((FORCE)); then warnc "Hardware: $prod (no es $TARGET_MODEL; continúo por --force)"
  else die "Este script es para $TARGET_MODEL, detectado: $prod. Usa --force para ignorar."; fi

  local free_mb; free_mb=$(df -Pm / | awk 'NR==2{print $4}')
  if ((free_mb > 2000)); then pass "Espacio libre en /: ${free_mb} MB"
  else warnc "Poco espacio libre en / (${free_mb} MB)"; fi

  local dev; dev=$(default_route_dev)
  if [[ -n "$dev" ]]; then
    pass "Ruta por defecto por: $dev"
    [[ "$dev" == wl* ]] && warnc "Estás conectado por wifi; no se recargará el módulo wifi"
  else
    failc "Sin ruta por defecto: conecta el móvil por USB (tethering) o un adaptador Thunderbolt-Ethernet y reintenta"
    ((DRY_RUN)) || exit 1
  fi
  if have curl && curl -fsS --max-time 15 -o /dev/null -I https://deb.debian.org/debian/dists/trixie/Release; then
    pass "Acceso a deb.debian.org"
  else
    warnc "No se pudo alcanzar deb.debian.org (¿tethering sin datos?)"
  fi
  if have lspci; then
    note "Wifi: $(lspci -nn | grep -iE 'network|14e4:43' | head -2 | tr '\n' ';')"
    note "GPU:  $(lspci -nn | grep -iE 'vga|3d controller' | tr '\n' ';')"
  fi

  start_run
  ((DRY_RUN)) || info "  Log: $LOG_FILE   Registro para rollback: $RUN_DIR"
}

# ----------------------------------------------------- instantánea del sistema
stage_snapshot() {
  ((WITH_SNAPSHOT)) || return 0
  step "Instantánea del sistema (punto de restauración)"
  local desc="antes de macbookpro101-postinstall $RUN_ID"
  if have snapper && snapper -c root list >/dev/null 2>&1; then
    if run snapper -c root create -d "$desc"; then
      pass "Instantánea snapper creada"; manifest SNAPSHOT snapper "$desc"
    else warnc "snapper no pudo crear la instantánea"; fi
  elif have timeshift && [[ -s /etc/timeshift/timeshift.json ]]; then
    if run_v timeshift --create --comments "$desc" --tags O; then
      pass "Instantánea Timeshift creada"; manifest SNAPSHOT timeshift "$desc"
    else warnc "Timeshift no pudo crear la instantánea"; fi
  else
    note "Sin Timeshift/snapper configurado: el rollback usará el registro propio del script."
    note "(Opcional: apt install timeshift, configúralo y relanza para tener además una instantánea completa.)"
  fi
}

# ------------------------------------------------------------------ repos APT
stage_sources() {
  step "Repositorios APT (contrib, non-free, non-free-firmware; sin cdrom)"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qE '^deb[[:space:]]+(\[[^]]*\][[:space:]]+)?cdrom:' "$f"; then
      if ((DRY_RUN)); then info "  [dry-run] comentaría la línea cdrom en $f"
      else
        track_path "$f"
        sed -i -E 's/^(deb[[:space:]]+(\[[^]]*\][[:space:]]+)?cdrom:)/# \1/' "$f"
        pass "Línea cdrom comentada en $f"
      fi
    fi
    if fix_components_file "$f"; then pass "Componentes ($APT_COMPONENTS) añadidos en $f"; fi
  done
  if run_v apt-get update; then pass "apt-get update correcto"
  else die "apt-get update falló: revisa la conexión"; fi
}

# ------------------------------------------------------------------ paquetes
stage_packages() {
  step "Paquetes: firmware, diagnóstico, gráficos, energía"
  apt_install \
    firmware-misc-nonfree firmware-intel-graphics firmware-intel-misc intel-microcode \
    iw rfkill wireless-regdb wpasupplicant network-manager \
    usbmuxd libimobiledevice-utils \
    pciutils usbutils dmidecode lshw ethtool \
    libgl1-mesa-dri mesa-vulkan-drivers mesa-va-drivers i965-va-driver vainfo \
    intel-gpu-tools switcheroo-control \
    bluez alsa-utils alsa-ucm-conf \
    thermald lm-sensors upower powertop acpi smartmontools \
    gnome-tweaks
}

# ---------------------------------------------------------------------- wifi
stage_wifi() {
  step "Wi-Fi Broadcom BCM4331 (driver: $WIFI_DRV)"
  local dev; dev=$(default_route_dev)
  case "$WIFI_DRV" in
    wl)
      # broadcom-sta-dkms instala su propio blacklist (b43, bcma, ssb, brcmsmac…)
      apt_install linux-headers-amd64 "linux-headers-$(uname -r)" broadcom-sta-dkms || {
        failc "No se pudo instalar broadcom-sta-dkms (¿faltan cabeceras del kernel?)"; return 1; }
      if ((!DRY_RUN)) && have dkms && ! dkms status broadcom-sta -k "$(uname -r)" 2>/dev/null | grep -q installed; then
        failc "El módulo wl no está compilado para $(uname -r) (ver: dkms status)"
      fi
      ;;
    b43)
      # firmware-b43-installer descarga y extrae el firmware de Broadcom durante la instalación
      apt_install b43-fwcutter firmware-b43-installer || return 1
      if [[ -d /lib/firmware/b43 ]]; then pass "Firmware b43 presente en /lib/firmware/b43"
      elif ((!DRY_RUN)); then failc "No se encuentra /lib/firmware/b43 (¿falló la descarga?)"; fi
      ;;
    *) failc "Driver wifi desconocido: $WIFI_DRV (usa wl o b43)"; return 1 ;;
  esac

  put_file /etc/modprobe.d/macbookpro-wifi.conf <<EOF
# Dominio regulatorio (evita quedarse en el mundo "00" con canales limitados)
options cfg80211 ieee80211_regdom=${REGDOM}
EOF
  NEED_INITRAMFS=1
  have iw && run iw reg set "$REGDOM"
  have rfkill && run rfkill unblock wifi
  have nmcli  && run nmcli radio wifi on

  if [[ "$dev" == wl* ]]; then
    note "Conectado por wifi: omito la recarga del módulo (se aplicará al reiniciar)"
  elif ((DRY_RUN)); then
    info "  [dry-run] recargaría el driver $WIFI_DRV"
  else
    info "  Cargando el driver $WIFI_DRV…"
    local m
    if [[ "$WIFI_DRV" == wl ]]; then
      for m in b43 b43legacy brcmsmac bcma ssb; do modprobe -r "$m" 2>/dev/null; done
    else
      modprobe -r wl 2>/dev/null
    fi
    if modprobe "$WIFI_DRV" >>"$LOG_FILE" 2>&1; then
      local i
      for ((i = 0; i < 20; i++)); do iw dev 2>/dev/null | grep -q Interface && break; sleep 1; done
      if iw dev 2>/dev/null | grep -q Interface; then
        pass "Interfaz wifi creada: $(iw dev | awk '/Interface/{print $2; exit}')"
      else
        failc "$WIFI_DRV cargó pero no apareció interfaz. Últimos mensajes:"
        dmesg | grep -iE "$WIFI_DRV|bcma|wl_" | tail -8 | sed 's/^/         /'
      fi
    else
      failc "modprobe $WIFI_DRV falló (ver $LOG_FILE)"
    fi
  fi
  note "Si wl da problemas, prueba el libre:  sudo $0 --wifi=b43  (antes: --rollback)."
}

# ------------------------------------------------------- teclado / trackpad
stage_input() {
  step "Teclado y trackpad (hid_apple, bcm5974) + retroiluminación"
  local m present=()
  for m in applesmc coretemp; do
    if mod_exists "$m"; then present+=("$m"); else warnc "Módulo $m no existe en este kernel"; fi
  done
  if ((${#present[@]})); then
    { echo "# Sensores, ventiladores y luz del teclado del MacBookPro10,1"; printf '%s\n' "${present[@]}"; } \
      | put_file /etc/modules-load.d/macbookpro-smc.conf
    for m in "${present[@]}"; do run modprobe "$m"; done
  fi

  if [[ -n "$FNMODE$ISO_LAYOUT$SWAP_OPT_CMD" ]]; then
    local opts=""
    [[ -n "$FNMODE" ]]       && opts+=" fnmode=${FNMODE}"
    [[ -n "$ISO_LAYOUT" ]]   && opts+=" iso_layout=${ISO_LAYOUT}"
    [[ -n "$SWAP_OPT_CMD" ]] && opts+=" swap_opt_cmd=${SWAP_OPT_CMD}"
    put_file /etc/modprobe.d/macbookpro-hid-apple.conf <<EOF
# Opciones del teclado Apple (generadas por macbookpro101-postinstall)
options hid_apple${opts}
EOF
    NEED_INITRAMFS=1
    pass "Opciones de hid_apple:${opts} (efectivas tras reiniciar)"
  fi

  # Valores por defecto de GNOME (system-db de dconf: no pisan lo que el usuario ya haya cambiado)
  put_file /etc/dconf/db/local.d/00-macbookpro <<'EOF'
[org/gnome/desktop/peripherals/touchpad]
tap-to-click=true
click-method='fingers'
natural-scroll=true
two-finger-scrolling-enabled=true
disable-while-typing=true

[org/gnome/desktop/interface]
show-battery-percentage=true

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-battery-type='suspend'
sleep-inactive-battery-timeout=900
EOF
  local prof=/etc/dconf/profile/user
  if [[ -f "$prof" ]]; then
    ensure_line "$prof" "system-db:local"
  else
    printf 'user-db:user\nsystem-db:local\n' | put_file "$prof"
  fi
  if have dconf; then
    track_path /etc/dconf/db/local
    run dconf update && pass "Ajustes por defecto de GNOME aplicados (tap-to-click, scroll natural…)"
  else
    warnc "dconf no está instalado: los valores de GNOME se aplicarán cuando lo esté (dconf update)"
  fi
}

# ------------------------------------------------------------------ gráficos
stage_graphics() {
  step "Gráficos (Intel HD 4000 + NVIDIA GT 650M)"
  local gpus; gpus=$(lspci -nn 2>/dev/null | grep -iE 'vga|3d controller')
  if grep -qi '8086:' <<<"$gpus"; then pass "GPU Intel visible (i915)"
  else
    note "Solo se ve la NVIDIA: el firmware EFI oculta la Intel si el SO no se identifica como macOS"
    note "(el kernel 6.12 solo aplica 'apple_set_os' a MacBookPro11,3/11,5 y posteriores, no a 10,1)."
  fi
  grep -qi '10de:' <<<"$gpus" && pass "GPU NVIDIA visible (driver libre nouveau)"
  note "El driver privativo para Kepler (serie 470) no existe en Debian 13: se usa nouveau + Mesa."
  have systemctl && svc enable switcheroo-control.service
  note "Si hay cuelgues gráficos con nouveau, prueba en GRUB: nouveau.runpm=0"
}

# ------------------------------------------------------------------- energía
stage_power() {
  step "Gestión de energía, ventiladores y batería (${POWER_MGR})"
  svc enable --now thermald.service

  case "$POWER_MGR" in
    tlp)
      apt_install tlp tlp-rdw || return 1
      put_file /etc/tlp.d/10-macbookpro101.conf <<'EOF'
# Configuración TLP para MacBookPro10,1 (Core i7 Ivy Bridge, sin HWP)
TLP_ENABLE=1
TLP_DEFAULT_MODE=AC
TLP_PERSISTENT_DEFAULT=0

CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
# Sin HWP en Ivy Bridge: TLP aplica esta política vía EPB
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
# Turbo en batería: ponlo a 0 si quieres menos calor/ruido y más autonomía
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=1

PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto

SATA_LINKPWR_ON_AC="med_power_with_dipm max_performance"
SATA_LINKPWR_ON_BAT="med_power_with_dipm min_power"

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

USB_AUTOSUSPEND=1
USB_EXCLUDE_PHONE=1
USB_EXCLUDE_BTUSB=1

SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=10
SOUND_POWER_SAVE_CONTROLLER=Y

NMI_WATCHDOG=0
EOF
      # TLP y power-profiles-daemon no deben convivir
      if systemctl list-unit-files power-profiles-daemon.service 2>/dev/null | grep -q '^power-profiles-daemon.service'; then
        svc disable --now power-profiles-daemon.service
        svc mask power-profiles-daemon.service
        note "power-profiles-daemon enmascarado: el selector de perfiles de GNOME desaparece (normal con TLP)."
      fi
      svc enable tlp.service
      svc restart tlp.service
      svc mask systemd-rfkill.service systemd-rfkill.socket
      ;;
    ppd)
      apt_install power-profiles-daemon || return 1
      svc unmask power-profiles-daemon.service
      svc enable --now power-profiles-daemon.service
      ;;
    *) failc "POWER_MGR desconocido: $POWER_MGR (usa tlp o ppd)"; return 1 ;;
  esac

  # Ventiladores: sin control, el MacBookPro10,1 se calienta y ruge en Linux
  if apt_install mbpfan; then
    svc enable mbpfan.service
    svc restart mbpfan.service
  fi

  put_file /etc/sysctl.d/99-macbookpro.conf <<'EOF'
vm.swappiness=100
vm.page-cluster=0
EOF
  run sysctl --system
  svc enable --now fstrim.timer

  if ((WITH_ZRAM)); then
    apt_install systemd-zram-generator && {
      put_file /etc/systemd/zram-generator.conf <<'EOF'
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
swap-priority = 100
EOF
      run systemctl daemon-reload
      svc start systemd-zram-setup@zram0.service
    }
  fi

  local b; b=$(bat_dir) || { warnc "No se ve batería en /sys/class/power_supply"; return 0; }
  if [[ -e "$b/charge_control_end_threshold" ]]; then
    note "Tu kernel expone umbral de carga: puedes limitarlo en /etc/tlp.d (STOP_CHARGE_THRESH_BAT0)."
  else
    note "Este Mac NO permite límite de carga por software en Linux (no hay charge_control_end_threshold)."
  fi
}

stage_initramfs() {
  ((NEED_INITRAMFS)) || return 0
  step "initramfs"
  if have update-initramfs; then
    run_v update-initramfs -u -k all && pass "initramfs regenerado (opciones de módulos)"
  else
    warnc "update-initramfs no disponible"
  fi
}

# ----------------------------------------------------------------- instalación
do_install() {
  preflight
  stage_snapshot
  stage_sources
  stage_packages
  stage_wifi
  stage_input
  stage_graphics
  stage_power
  stage_initramfs
  finish_run "done"

  step "Resumen de la instalación"
  info "  OK: $N_PASS   Avisos: $N_WARN   Fallos: $N_FAIL"
  cat <<EOF

Siguientes pasos:
  1) Reinicia:                    sudo reboot
  2) Tras reiniciar, comprueba:   sudo $0 --verify
  3) Prueba de suspensión:        sudo $0 --test-suspend   (con el cargador desconectado)
  Para deshacer todo:             sudo $0 --rollback       (ID: ${RUN_ID})
Log completo: $LOG_FILE
EOF
  ((N_FAIL == 0))
}

# ==================================================================== ROLLBACK
run_status() { cat "$RUNS_DIR/$1/status" 2>/dev/null || echo "?"; }

list_runs() { # IDs ordenados del más antiguo al más reciente
  local d
  for d in "$RUNS_DIR"/*/; do [[ -f "$d/manifest" ]] && basename "$d"; done | sort
}

do_list_backups() {
  [[ $EUID -eq 0 ]] || die "Ejecuta como root"
  step "Ejecuciones registradas en $RUNS_DIR"
  local id n=0
  while read -r id; do
    [[ -n "$id" ]] || continue
    n=$((n+1))
    printf '  %-17s %-12s ficheros:%-3s paquetes nuevos:%-3s servicios:%s\n' "$id" "$(run_status "$id")" \
      "$(grep -cE '^(MOD|NEW)'$'\t' "$RUNS_DIR/$id/manifest")" \
      "$(grep -c '^PKGNEW'$'\t' "$RUNS_DIR/$id/manifest")" \
      "$(grep -c '^UNIT'$'\t' "$RUNS_DIR/$id/manifest")"
  done < <(list_runs)
  ((n)) || info "  (ninguna)"
}

# Restaura ficheros/directorios de una ejecución (en orden inverso).
# Deja en ROLLBACK_PATHS las rutas tocadas para decidir acciones posteriores.
rollback_files() {
  local dir=$1 type p
  local backup="$dir/files"
  while IFS=$'\t' read -r type p _; do
    case "$type" in
      MOD)
        ROLLBACK_PATHS+=("$p")
        if [[ ! -e "$backup$p" && ! -L "$backup$p" ]]; then failc "Falta la copia de $p"; continue; fi
        if ((DRY_RUN)); then info "  [dry-run] restauraría $p"; continue; fi
        rm -rf -- "$p"; mkdir -p "$(dirname "$p")"
        if cp -a -- "$backup$p" "$p"; then pass "Restaurado $p"; else failc "No se pudo restaurar $p"; fi
        ;;
      NEW)
        ROLLBACK_PATHS+=("$p")
        [[ -e "$p" || -L "$p" ]] || continue
        if ((DRY_RUN)); then info "  [dry-run] borraría $p"; continue; fi
        rm -rf -- "$p" && pass "Eliminado $p"
        ;;
      NEWDIR)
        [[ -d "$p" ]] || continue
        if ((DRY_RUN)); then info "  [dry-run] eliminaría el directorio $p si queda vacío"; continue; fi
        rmdir -- "$p" 2>/dev/null && log "RMDIR $p"
        ;;
    esac
  done < <(tac "$dir/manifest")
}

# Los scripts de purge de algunos paquetes (p. ej. locales) borran ficheros de /etc
# que ya existían antes de la ejecución: se guardan antes del purge y se reponen.
etc_existing() { # rutas de /etc que existían al empezar la ejecución y siguen existiendo
  local p
  while IFS= read -r p; do [[ -e "$p" || -L "$p" ]] && printf '%s\n' "$p"; done <"$1/etc-paths.txt"
}
restore_purged_etc() {
  local dir=$1 tarf=$2 pre=$3 p miss=()
  while IFS= read -r p; do [[ -e "$p" || -L "$p" ]] || miss+=("${p#/}"); done <"$pre"
  if ((${#miss[@]})); then
    if tar -C / --no-recursion -xpf "$tarf" -- "${miss[@]}" 2>>"$LOG_FILE"; then
      pass "Repuestos ${#miss[@]} elementos de /etc previos que el purge había borrado"
    else warnc "No se pudo reponer todo lo que el purge borró de /etc (ver $LOG_FILE)"; fi
  fi
  # Directorios vacíos que dejaron los paquetes desinstalados
  find /etc -xdev -mindepth 1 -depth -type d -empty 2>/dev/null | grep -vxFf "$dir/etc-paths.txt" \
    | while IFS= read -r p; do rmdir -- "$p" 2>/dev/null; done
  rm -f -- "$tarf" "$pre"
}

rollback_packages() {
  local dir=$1 p new=() gone=() extra
  while IFS=$'\t' read -r t p _; do
    case "$t" in
      PKGNEW)  dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' && new+=("$p") ;;
      PKGGONE) dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null | grep -q '^ii' || gone+=("$p") ;;
    esac
  done <"$dir/manifest"

  if ((${#new[@]})); then
    if ((KEEP_PACKAGES)); then
      note "--keep-packages: se conservan ${#new[@]} paquetes instalados por el script"
    else
      # Comprueba que apt no arrastre paquetes que el usuario instaló después
      extra=$(apt-get -s purge "${new[@]}" 2>/dev/null | awk '/^Purg /{print $2}' | sort -u \
              | comm -23 - <(printf '%s\n' "${new[@]%%:*}" "${new[@]}" | sort -u))
      if [[ -n "$extra" ]]; then
        warnc "Desinstalar los paquetes del script arrastraría también: $(echo "$extra" | tr '\n' ' ')"
        if ((ASSUME_YES)) || ! confirm "¿Desinstalarlos igualmente?"; then
          warnc "Se omite la desinstalación de paquetes (relanza con --rollback sin --yes para decidir)"
          new=()
        fi
      fi
      if ((${#new[@]})); then
        info "  Desinstalando ${#new[@]} paquetes: ${new[*]}"
        local etc_tar="$dir/etc-before-purge.tar" etc_pre="$dir/etc-before-purge.txt"
        if ! ((DRY_RUN)) && [[ -s "$dir/etc-paths.txt" ]]; then
          etc_existing "$dir" >"$etc_pre"
          tar -C / --xattrs -cpf "$etc_tar" etc 2>>"$LOG_FILE" || true
        fi
        if DEBIAN_FRONTEND=noninteractive run_v apt-get purge -y "${new[@]}"; then pass "Paquetes desinstalados"
        else failc "apt-get purge falló (ver $LOG_FILE)"; fi
        [[ -s "$etc_tar" && -s "$etc_pre" ]] && restore_purged_etc "$dir" "$etc_tar" "$etc_pre"
      fi
    fi
  fi
  if ((${#gone[@]})); then
    info "  Reinstalando paquetes que se desinstalaron: ${gone[*]}"
    if DEBIAN_FRONTEND=noninteractive run_v apt-get install -y "${gone[@]}"; then pass "Paquetes reinstalados"
    else failc "No se pudieron reinstalar: ${gone[*]}"; fi
  fi
}

rollback_units() {
  local dir=$1 t u en act
  while IFS=$'\t' read -r t u en act; do
    [[ "$t" == UNIT ]] || continue
    if ((DRY_RUN)); then info "  [dry-run] $u -> $en/$act"; continue; fi
    case "$en" in
      masked|masked-runtime) systemctl mask "$u" >>"$LOG_FILE" 2>&1 ;;
      enabled|enabled-runtime) systemctl unmask "$u" >>"$LOG_FILE" 2>&1; systemctl enable "$u" >>"$LOG_FILE" 2>&1 ;;
      disabled) systemctl unmask "$u" >>"$LOG_FILE" 2>&1; systemctl disable "$u" >>"$LOG_FILE" 2>&1 ;;
      *) systemctl unmask "$u" >>"$LOG_FILE" 2>&1 ;;
    esac
    if [[ "$act" == active ]]; then systemctl start "$u" >>"$LOG_FILE" 2>&1
    else systemctl stop "$u" >>"$LOG_FILE" 2>&1; fi
    pass "Servicio $u restaurado ($en, $act)"
  done < <(tac "$dir/manifest")
}

rollback_run() {
  local id=$1 dir="$RUNS_DIR/$1"
  step "Deshaciendo la ejecución $id"
  ROLLBACK_PATHS=()
  # Las unidades que se iban a parar (zram…) se paran antes de quitar su configuración
  rollback_files "$dir"
  rollback_packages "$dir"
  if printf '%s\n' "${ROLLBACK_PATHS[@]}" | grep -q '^/etc/apt/'; then
    run_v apt-get update >/dev/null && pass "apt-get update con los repositorios originales"
  fi
  run systemctl daemon-reload
  rollback_units "$dir"

  local paths; paths=$(printf '%s\n' "${ROLLBACK_PATHS[@]}")
  if grep -qE '^/etc/(initramfs-tools|modprobe\.d|modules-load\.d)/' <<<"$paths" && have update-initramfs; then
    run_v update-initramfs -u -k all && pass "initramfs regenerado"
  fi
  if grep -q '^/etc/dconf/' <<<"$paths" && have dconf; then run dconf update && pass "dconf actualizado"; fi
  grep -q '^/etc/sysctl\.d/' <<<"$paths" && run sysctl --system

  local snap; snap=$(awk -F'\t' '$1=="SNAPSHOT"{print $2" ("$3")"}' "$dir/manifest")
  [[ -n "$snap" ]] && note "Existe además una instantánea completa previa: $snap"
  ((DRY_RUN)) || echo rolled-back >"$dir/status"
}

do_rollback() {
  [[ $EUID -eq 0 ]] || die "Ejecuta como root"
  touch "$LOG_FILE"; acquire_lock
  local all=() pending=() id targets=()
  mapfile -t all < <(list_runs)
  for id in "${all[@]}"; do [[ "$(run_status "$id")" == rolled-back ]] || pending+=("$id"); done
  ((${#pending[@]})) || die "No hay ejecuciones pendientes de deshacer en $RUNS_DIR (ver --list-backups)"

  case "$ROLLBACK_TARGET" in
    last) targets=("${pending[-1]}") ;;
    all)  targets=("${pending[@]}") ;;
    *)
      [[ -f "$RUNS_DIR/$ROLLBACK_TARGET/manifest" ]] || die "No existe la ejecución $ROLLBACK_TARGET (ver --list-backups)"
      [[ "$(run_status "$ROLLBACK_TARGET")" == rolled-back ]] && die "La ejecución $ROLLBACK_TARGET ya se deshizo"
      # Para volver al estado previo a ID hay que deshacer también las posteriores
      for id in "${pending[@]}"; do [[ "$id" < "$ROLLBACK_TARGET" ]] || targets+=("$id"); done
      ;;
  esac

  step "Rollback"
  info "  Se deshará (de la más reciente a la más antigua): $(printf '%s ' "${targets[@]}" | tr ' ' '\n' | sort -r | tr '\n' ' ')"
  ((KEEP_PACKAGES)) && info "  Los paquetes instalados se conservarán (--keep-packages)"
  [[ "$(default_route_dev)" == wl* ]] && ((!KEEP_PACKAGES)) && \
    warnc "Estás conectado por wifi: al quitar el driver puedes perder la conexión"
  ((DRY_RUN)) || confirm "¿Continuar?" || die "Cancelado"

  for ((i = ${#targets[@]} - 1; i >= 0; i--)); do rollback_run "${targets[i]}"; done

  step "Resultado del rollback"
  info "  OK: $N_PASS   Avisos: $N_WARN   Fallos: $N_FAIL"
  info "  Reinicia para que el kernel, los módulos y los sysctl vuelvan al estado original."
  ((N_FAIL == 0))
}

# ===================================================================== VERIFY
chk() { # chk NIVEL(FAIL|WARN) "descripción" función...
  local lvl=$1 desc=$2; shift 2
  if "$@" >/dev/null 2>&1; then pass "$desc"
  elif [[ "$lvl" == FAIL ]]; then failc "$desc"
  else warnc "$desc"; fi
}

any_glob() { local f; for f in "$@"; do [[ -e "$f" ]] && return 0; done; return 1; }

t_wifi_drv()       { mod_loaded wl || mod_loaded b43; }
t_wl_dkms()        { dkms status broadcom-sta -k "$(uname -r)" 2>/dev/null | grep -q installed; }
t_b43_fw()         { [[ -d /lib/firmware/b43 ]]; }
t_wifi_iface()     { iw dev 2>/dev/null | grep -q Interface; }
t_wifi_unblocked() { ! rfkill list wifi 2>/dev/null | grep -qi 'blocked: yes'; }
t_wifi_scan()      { timeout 20 nmcli -t -f SSID dev wifi list --rescan yes 2>/dev/null | grep -q .; }
t_regdom()         { iw reg get 2>/dev/null | grep -q "country ${REGDOM}"; }
t_nm_wifi_on()     { nmcli radio wifi 2>/dev/null | grep -q enabled; }
t_bt_unblocked()   { ! rfkill list bluetooth 2>/dev/null | grep -qi 'blocked: yes'; }
t_bt_ctrl()        { timeout 5 bluetoothctl list 2>/dev/null | grep -q Controller; }
t_hid_apple()      { mod_loaded hid_apple; }
t_bcm5974()        { mod_loaded bcm5974; }
t_kbd_dev()        { grep -qi 'Apple.*Internal Keyboard' /proc/bus/input/devices; }
t_tp_dev()         { grep -qiE 'bcm5974|Apple.*Trackpad' /proc/bus/input/devices; }
t_kbd_backlight()  { any_glob /sys/class/leds/*kbd_backlight*; }
t_backlight()      { any_glob /sys/class/backlight/*; }
t_gpu_drv()        { mod_loaded nouveau || mod_loaded i915; }
t_vaapi()          { vainfo 2>&1 | grep -q 'VAProfile'; }
t_battery()        { bat_dir >/dev/null; }
t_upower_bat()     { upower -e 2>/dev/null | grep -q battery; }
t_tlp_active()     { systemctl is-active --quiet tlp; }
t_tlp_conf()       { ! tlp-stat -c 2>&1 | grep -qiE 'error|invalid|unknown'; }
t_ppd_active()     { systemctl is-active --quiet power-profiles-daemon; }
t_thermald()       { systemctl is-active --quiet thermald; }
t_pstate()         { [[ "$(cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null)" == active ]]; }
t_applesmc()       { mod_loaded applesmc; }
t_fans()           { any_glob /sys/devices/platform/applesmc.*/fan1_input; }
t_mbpfan()         { systemctl is-active --quiet mbpfan; }
t_sensors()        { sensors 2>/dev/null | grep -q '°C'; }
t_zram()           { swapon --show 2>/dev/null | grep -q zram; }
t_fstrim()         { systemctl is-enabled --quiet fstrim.timer; }
t_audio_card()     { aplay -l 2>/dev/null | grep -q '^card'; }
t_pw_audio()       { as_user wpctl status 2>/dev/null | grep -q 'Sinks:'; }
t_cam_dev()        { any_glob /dev/video*; }
t_mem_sleep()      { [[ -r /sys/power/mem_sleep ]]; }
t_dconf()          { grep -q 'system-db:local' /etc/dconf/profile/user 2>/dev/null; }

do_verify() {
  preflight_light
  step "Wi-Fi y Bluetooth"
  chk FAIL "Driver wifi (wl o b43) cargado" t_wifi_drv
  if mod_loaded wl || dpkg -s broadcom-sta-dkms >/dev/null 2>&1; then
    have dkms && chk FAIL "broadcom-sta (wl) compilado por DKMS para $(uname -r)" t_wl_dkms
  else
    chk WARN "Firmware b43 instalado" t_b43_fw
  fi
  chk FAIL "Existe interfaz wifi" t_wifi_iface
  chk FAIL "Wifi no bloqueado por rfkill" t_wifi_unblocked
  chk WARN "NetworkManager con wifi activado" t_nm_wifi_on
  have nmcli && chk WARN "El escaneo wifi ve redes" t_wifi_scan
  chk WARN "Dominio regulatorio = $REGDOM" t_regdom
  have iw && note "$(iw reg get 2>/dev/null | head -2 | tr '\n' ' ')"
  have rfkill && chk WARN "Bluetooth no bloqueado" t_bt_unblocked
  have bluetoothctl && chk WARN "Controlador Bluetooth presente" t_bt_ctrl

  step "Teclado, trackpad, pantalla"
  chk WARN "Módulo hid_apple cargado" t_hid_apple
  chk WARN "Módulo bcm5974 (trackpad) cargado" t_bcm5974
  chk FAIL "Teclado interno Apple detectado" t_kbd_dev
  chk FAIL "Trackpad detectado" t_tp_dev
  chk WARN "Retroiluminación del teclado (smc::kbd_backlight)" t_kbd_backlight
  chk FAIL "Control de brillo de pantalla (/sys/class/backlight)" t_backlight
  any_glob /sys/class/backlight/* && note "Backlight: $(cd /sys/class/backlight && echo *)"
  chk WARN "Defaults de GNOME (dconf system-db) activos" t_dconf

  step "Gráficos"
  chk FAIL "Driver gráfico (nouveau o i915) cargado" t_gpu_drv
  have lspci && lspci -k 2>/dev/null | grep -A3 -iE 'vga|3d controller' | grep -iE 'vga|3d|in use' | sed 's/^/         /'
  [[ -r /sys/kernel/debug/vgaswitcheroo/switch ]] && note "vga_switcheroo: $(tr '\n' ' ' </sys/kernel/debug/vgaswitcheroo/switch)"
  have vainfo && chk WARN "VA-API (decodificación por hardware)" t_vaapi
  note "Sesión gráfica: $(as_user printenv XDG_SESSION_TYPE 2>/dev/null || echo n/d)"

  step "Energía, ventiladores y batería"
  chk FAIL "Batería detectada" t_battery
  have upower && chk WARN "UPower ve la batería" t_upower_bat
  local b; if b=$(bat_dir); then
    local full design pct cyc st cap
    full=$(cat "$b/energy_full" 2>/dev/null || cat "$b/charge_full" 2>/dev/null || echo 0)
    design=$(cat "$b/energy_full_design" 2>/dev/null || cat "$b/charge_full_design" 2>/dev/null || echo 0)
    cyc=$(cat "$b/cycle_count" 2>/dev/null || echo "?")
    st=$(cat "$b/status" 2>/dev/null || echo "?")
    cap=$(cat "$b/capacity" 2>/dev/null || echo "?")
    if [[ "$design" =~ ^[0-9]+$ && "$full" =~ ^[0-9]+$ ]] && ((design > 0)); then
      pct=$((full * 100 / design))
      if ((pct >= 80)); then pass "Salud de batería: ${pct}% (ciclos: $cyc)"
      else warnc "Salud de batería baja: ${pct}% (ciclos: $cyc)"; fi
    fi
    note "Estado: $st, carga: ${cap}%"
  fi
  if [[ "$POWER_MGR" == tlp ]]; then
    chk FAIL "Servicio TLP activo" t_tlp_active
    have tlp-stat && chk WARN "Configuración TLP sin errores" t_tlp_conf
  else
    chk FAIL "power-profiles-daemon activo" t_ppd_active
    have powerprofilesctl && note "Perfil actual: $(powerprofilesctl get 2>/dev/null)"
  fi
  chk WARN "thermald activo" t_thermald
  chk WARN "intel_pstate en modo active" t_pstate
  chk WARN "applesmc cargado (sensores/ventiladores Apple)" t_applesmc
  chk WARN "Ventiladores visibles vía applesmc" t_fans
  chk WARN "mbpfan (control de ventiladores) activo" t_mbpfan
  if have sensors; then
    chk WARN "lm-sensors lee temperaturas" t_sensors
    local temp; temp=$(sensors 2>/dev/null | awk '/Package id 0/{gsub(/[+°C]/,"",$4); print int($4); exit}')
    if [[ -n "$temp" ]]; then
      if ((temp < 75)); then pass "Temperatura CPU: ${temp}°C"; else warnc "Temperatura CPU alta: ${temp}°C (¿carga en segundo plano?)"; fi
    fi
    sensors 2>/dev/null | grep -iE '^(Exhaust|Master|Left|Right).*RPM|fan' | head -3 | sed 's/^/         /'
  fi
  chk WARN "Swap en zram activa" t_zram
  chk WARN "fstrim.timer habilitado" t_fstrim
  t_mem_sleep && note "Suspensión disponible: $(cat /sys/power/mem_sleep)"
  note "Fuentes de despertar activas: $(awk '$3 ~ /enabled/ {printf "%s ", $1}' /proc/acpi/wakeup 2>/dev/null)"
  if have smartctl; then
    local disk; disk=$(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^(zram|loop)/ {print "/dev/"$1; exit}')
    if [[ -n "$disk" ]]; then
      if smartctl -H "$disk" 2>/dev/null | grep -qE 'PASSED|OK'; then pass "SMART de $disk: correcto"
      else warnc "SMART de $disk: no se pudo confirmar el estado"; fi
    fi
  fi

  step "Audio y cámara"
  have aplay && chk FAIL "Tarjeta de audio ALSA detectada" t_audio_card
  chk WARN "PipeWire expone salidas de audio (usuario $REAL_USER)" t_pw_audio
  chk WARN "Cámara FaceTime HD (UVC) en /dev/video*" t_cam_dev

  step "Errores del kernel en este arranque (revisión manual)"
  journalctl -k -b -p err --no-pager 2>/dev/null | tail -15 | sed 's/^/         /'

  step "Resultado"
  info "  OK: $N_PASS   Avisos: $N_WARN   Fallos: $N_FAIL"
  info "  Log: $LOG_FILE"
  ((N_FAIL == 0))
}

preflight_light() {
  [[ $EUID -eq 0 ]] || die "Ejecuta como root para que dmesg/journal/tlp-stat funcionen"
  mkdir -p "$STATE_DIR"; touch "$LOG_FILE"
  # Detecta el gestor de energía realmente instalado
  if have tlp; then POWER_MGR=tlp
  elif dpkg-query -W -f='${db:Status-Abbrev}' power-profiles-daemon 2>/dev/null | grep -q '^ii'; then POWER_MGR=ppd; fi
  step "Entorno"
  info "  Kernel: $(uname -r)   Equipo: $(cat /sys/class/dmi/id/product_name 2>/dev/null)   Gestor de energía: $POWER_MGR"
}

# ============================================================== TEST SUSPENSIÓN
bat_energy() { local b; b=$(bat_dir) || return 1; cat "$b/energy_now" 2>/dev/null || cat "$b/charge_now" 2>/dev/null; }

do_test_suspend() {
  preflight_light
  have rtcwake || die "Falta rtcwake (paquete util-linux)"
  local mode=freeze
  grep -qw deep /sys/power/mem_sleep 2>/dev/null && mode=mem
  step "Prueba de suspensión ($mode) de 120 s"
  local b st e0 e1 rc
  b=$(bat_dir) || b=""
  st=$([[ -n "$b" ]] && cat "$b/status" || echo "?")
  note "Estado de la batería: $st"
  [[ "$st" == "Discharging" ]] || warnc "Cargador conectado: no se medirá el consumo en suspensión"
  info "  El equipo se suspenderá 120 s y despertará solo. Guarda tu trabajo. Empieza en 5 s…"
  sleep 5
  e0=$(bat_energy)
  rtcwake -m "$mode" -s 120 >>"$LOG_FILE" 2>&1; rc=$?
  sleep 8
  e1=$(bat_energy)
  if ((rc == 0)); then pass "Suspensión y reanudación correctas (rtcwake rc=0)"
  else failc "rtcwake devolvió $rc"; fi

  local i
  for ((i = 0; i < 30; i++)); do t_wifi_iface && break; sleep 1; done
  chk FAIL "Interfaz wifi presente tras reanudar" t_wifi_iface
  chk FAIL "Teclado presente tras reanudar" t_kbd_dev
  chk FAIL "Trackpad presente tras reanudar" t_tp_dev
  chk WARN "Backlight de pantalla presente tras reanudar" t_backlight
  local re='(wl|b43|bcma|nouveau|i915|bcm5974|xhci).*(error|fail|timeout)'
  if journalctl -k --since "-4min" --no-pager 2>/dev/null | grep -iqE "$re"; then
    warnc "Errores en el kernel durante la suspensión/reanudación:"
    journalctl -k --since "-4min" --no-pager | grep -iE "$re" | tail -5 | sed 's/^/         /'
  else
    pass "Sin errores de wifi/gráficos/USB en el ciclo de suspensión"
  fi

  if [[ "$st" == "Discharging" && -n "$e0" && -n "$e1" ]]; then
    local w; w=$(awk -v a="$e0" -v b="$e1" 'BEGIN{printf "%.2f", (a-b)*3600/120/1000000}')
    note "Consumo medio en suspensión: ${w} W (energy_now ${e0} → ${e1})"
    if awk -v w="$w" 'BEGIN{exit !(w < 1.0)}'; then pass "Consumo en suspensión aceptable (< 1 W)"
    else warnc "Consumo en suspensión alto (${w} W): revisa wakeups (/proc/acpi/wakeup) y dispositivos USB"; fi
  fi
  step "Resultado"
  info "  OK: $N_PASS   Avisos: $N_WARN   Fallos: $N_FAIL"
  ((N_FAIL == 0))
}

# ================================================================== SELFTEST
do_selftest() {
  step "Autotest de la lógica interna (no modifica el sistema)"
  local t; t=$(mktemp -d)
  LOG_FILE="$t/test.log"; DRY_RUN=0
  RUN_DIR="$t/run"; BACKUP_DIR="$RUN_DIR/files"; MANIFEST="$RUN_DIR/manifest"
  mkdir -p "$BACKUP_DIR"; : >"$MANIFEST"
  local ok=0 bad=0
  _not_changed() { ! fix_components_file "$1"; }
  ck() { if "$@"; then ok=$((ok+1)); printf '  [OK]   %s\n' "${CK_DESC}"; else bad=$((bad+1)); printf '  [FALLO] %s\n' "${CK_DESC}"; fi; }

  # 1) deb822
  cat >"$t/debian.sources" <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
EOF
  cp "$t/debian.sources" "$t/debian.sources.orig"
  fix_components_file "$t/debian.sources"
  CK_DESC="deb822: los 2 stanzas de Debian quedan con main contrib non-free non-free-firmware"
  ck test "$(grep -cE '^Components: main( contrib| non-free| non-free-firmware){3}$' "$t/debian.sources")" -eq 2
  CK_DESC="deb822: no duplica componentes ya presentes"
  ck test "$(grep -c 'non-free-firmware.*non-free-firmware' "$t/debian.sources")" -eq 0
  CK_DESC="deb822: no toca repos de terceros"
  ck grep -qx 'Components: stable' "$t/debian.sources"
  CK_DESC="deb822: segundo paso es idempotente (devuelve 'sin cambios')"
  ck _not_changed "$t/debian.sources"

  # 2) formato de una línea
  cat >"$t/sources.list" <<'EOF'
deb http://deb.debian.org/debian/ trixie main contrib
deb-src http://deb.debian.org/debian/ trixie main
deb http://security.debian.org/debian-security trixie-security main non-free-firmware
# deb http://deb.debian.org/debian/ trixie main
deb https://example.com/repo stable main
EOF
  fix_components_file "$t/sources.list"
  _all_comps() { awk '/^deb.*debian\.org/ { n++; if (" " $0 " " ~ / contrib / && " " $0 " " ~ / non-free / && " " $0 " " ~ / non-free-firmware /) k++ }
                      END { exit !(n == 3 && k == 3) }' "$1"; }
  CK_DESC="one-line: deb y deb-src de Debian con los 3 componentes"
  ck _all_comps "$t/sources.list"
  CK_DESC="one-line: no duplica donde ya estaba"
  ck test "$(grep -cE '(contrib.*contrib|non-free-firmware.*non-free-firmware)' "$t/sources.list")" -eq 0
  CK_DESC="one-line: no toca comentarios ni repos de terceros"
  ck bash -c "grep -qx '# deb http://deb.debian.org/debian/ trixie main' '$t/sources.list' && grep -qx 'deb https://example.com/repo stable main' '$t/sources.list'"

  # 3) ensure_line / put_file
  ensure_line "$t/x.conf" "foo"; ensure_line "$t/x.conf" "foo"; ensure_line "$t/x.conf" "bar"
  CK_DESC="ensure_line es idempotente"
  ck test "$(wc -l <"$t/x.conf")" -eq 2
  printf 'old\n' >"$t/y.conf"; chmod 640 "$t/y.conf"
  printf 'new content\n' | put_file "$t/y.conf" 600
  printf 'newer content\n' | put_file "$t/y.conf" 600
  CK_DESC="put_file escribe, aplica permisos y guarda la versión ORIGINAL"
  ck bash -c "grep -qx 'newer content' '$t/y.conf' && [ \"\$(stat -c %a '$t/y.conf')\" = 600 ] && grep -qx old '$BACKUP_DIR$t/y.conf'"
  printf 'x\n' | put_file "$t/nuevo/sub/dir/z.conf"
  _mf() { grep -cxF "$1"$'\t'"$2" "$MANIFEST"; }
  _manifest_ok() { [[ $(_mf MOD "$t/y.conf") == 1 && $(_mf NEW "$t/x.conf") == 1 && $(_mf NEWDIR "$t/nuevo") == 1 \
                      && $(_mf NEWDIR "$t/nuevo/sub/dir") == 1 && $(_mf MOD "$t/debian.sources") == 1 ]]; }
  CK_DESC="manifiesto: registra MOD, NEW y NEWDIR sin duplicados"
  ck _manifest_ok

  # 4) dry-run no escribe
  DRY_RUN=1
  printf 'zzz\n' | put_file "$t/dry.conf" >/dev/null
  CK_DESC="--dry-run no escribe ficheros ni manifiesto"
  ck bash -c "[ ! -e '$t/dry.conf' ] && ! grep -q dry.conf '$MANIFEST'"
  DRY_RUN=0

  # 5) rollback de ficheros
  ROLLBACK_PATHS=()
  rollback_files "$RUN_DIR" >/dev/null
  CK_DESC="rollback: restaura contenido y permisos originales"
  ck bash -c "grep -qx old '$t/y.conf' && [ \"\$(stat -c %a '$t/y.conf')\" = 640 ]"
  CK_DESC="rollback: restaura fichero APT original"
  ck cmp -s "$t/debian.sources" "$t/debian.sources.orig"
  CK_DESC="rollback: borra ficheros creados y directorios nuevos vacíos"
  ck bash -c "[ ! -e '$t/x.conf' ] && [ ! -e '$t/nuevo' ]"
  CK_DESC="rollback: informa de las rutas tocadas"
  ck test "${#ROLLBACK_PATHS[@]}" -ge 4

  LOG_FILE=/dev/null; MANIFEST=""
  rm -rf "$t"
  info "  Autotest: $ok correctos, $bad fallidos"
  ((bad == 0))
}

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; }

# =================================================================== ARGUMENTOS
ORIG_ARGS="$*"
for a in "$@"; do
  case "$a" in
    --verify)          MODE=verify ;;
    --test-suspend)    MODE=suspend ;;
    --selftest)        MODE=selftest ;;
    --list-backups)    MODE=list ;;
    --rollback)        MODE=rollback ;;
    --rollback=*)      MODE=rollback; ROLLBACK_TARGET="${a#*=}" ;;
    --keep-packages)   KEEP_PACKAGES=1 ;;
    --yes|-y)          ASSUME_YES=1 ;;
    --dry-run)         DRY_RUN=1 ;;
    --force)           FORCE=1 ;;
    --no-zram)         WITH_ZRAM=0 ;;
    --no-snapshot)     WITH_SNAPSHOT=0 ;;
    --power=*)         POWER_MGR="${a#*=}" ;;
    --wifi=*)          WIFI_DRV="${a#*=}" ;;
    --regdom=*)        REGDOM="${a#*=}" ;;
    --fnmode=*)        FNMODE="${a#*=}" ;;
    --iso-layout=*)    ISO_LAYOUT="${a#*=}" ;;
    --swap-opt-cmd=*)  SWAP_OPT_CMD="${a#*=}" ;;
    --version)         echo "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "Opción desconocida: $a" >&2; usage; exit 2 ;;
  esac
done

bad_arg() { echo "Valor no válido: $1" >&2; exit 2; }
[[ "$POWER_MGR" =~ ^(tlp|ppd)$ ]]            || bad_arg "--power=$POWER_MGR (tlp|ppd)"
[[ "$WIFI_DRV" =~ ^(wl|b43)$ ]]              || bad_arg "--wifi=$WIFI_DRV (wl|b43)"
[[ "$REGDOM" =~ ^[A-Z]{2}$ ]]                || bad_arg "--regdom=$REGDOM (dos letras mayúsculas, p. ej. ES)"
[[ -z "$FNMODE" || "$FNMODE" =~ ^[0-3]$ ]]   || bad_arg "--fnmode=$FNMODE (0|1|2|3)"
[[ -z "$ISO_LAYOUT" || "$ISO_LAYOUT" =~ ^(-1|0|1)$ ]] || bad_arg "--iso-layout=$ISO_LAYOUT (-1|0|1)"
[[ -z "$SWAP_OPT_CMD" || "$SWAP_OPT_CMD" =~ ^[0-2]$ ]] || bad_arg "--swap-opt-cmd=$SWAP_OPT_CMD (0|1|2)"
[[ "$ROLLBACK_TARGET" =~ ^(last|all|[0-9]{8}-[0-9]{6})$ ]] || bad_arg "--rollback=$ROLLBACK_TARGET (ID|all)"

case "$MODE" in
  install)  do_install ;;
  verify)   do_verify ;;
  suspend)  do_test_suspend ;;
  selftest) do_selftest ;;
  list)     do_list_backups ;;
  rollback) do_rollback ;;
esac
