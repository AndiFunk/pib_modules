#!/usr/bin/env bash
# Elecrow 7" 1024x600 HDMI LCD on a Jetson AGX Thor, on top of the stock display config.
#
# The Elecrow sends no hotplug signal / EDID, so the NVIDIA driver never enables HDMI for it.
# This tool keeps the original xorg.conf as the default and only adds the Elecrow settings
# when the NVIDIA X driver itself finds nothing on HDMI:
#
#   boot -> original xorg.conf (elecrow-display.service, before the display manager)
#        -> X starts and detects displays
#        -> elecrow-display-check.service reads /var/log/Xorg.0.log:
#             real monitor on HDMI      -> nothing changes (monitor uses its own modes)
#             nothing on HDMI (Elecrow) -> add Elecrow 1024x600 settings, keep any detected
#                                          DisplayPort monitors, restart display manager once
#
# Usage:
#   sudo ./setup-elecrow-display.sh              install and apply now (restarts display manager)
#   sudo ./setup-elecrow-display.sh --no-restart install only (applies on next boot)
#   sudo ./setup-elecrow-display.sh --uninstall  remove everything, restore the original xorg.conf
#   ./setup-elecrow-display.sh --status          show what X detected and the current mode
# After install the tool is also available as `elecrow-display`:
#   sudo elecrow-display --apply                 re-detect now (after swapping displays without reboot)

set -euo pipefail

XORG_CONF=/etc/X11/xorg.conf
XORG_LOG=/var/log/Xorg.0.log
BACKUP="${XORG_CONF}.bak-before-elecrow"
EDID_FILE=/etc/X11/elecrow-1024x600.bin
CONF_FILE=/etc/default/elecrow-display
TOOL=/usr/local/sbin/elecrow-display
UNIT_RESET=/etc/systemd/system/elecrow-display.service
UNIT_CHECK=/etc/systemd/system/elecrow-display-check.service
MARK_BEGIN="    # >>> elecrow-display (managed by setup-elecrow-display.sh)"
MARK_END="    # <<< elecrow-display"
RESTART=1
ACTION=install

# 128-byte EDID 1.3: "ELC Elecrow7", preferred mode 1024x600@60 (CVT, 49.00 MHz,
# h 1024 1072 1168 1312, v 600 603 613 624, -hsync +vsync), 154x86 mm,
# plus established 640x480, 800x600, 1024x768 @60.
EDID_HEX="00ffffffffffff00158307000100000001240103800f09780aee91a3544c99260f50542108000101010101010101010101010101010124130020415818203060\
3a009a560000001c000000fc00456c6563726f77370a20202020000000fd00324b1e500a000a202020202020000000100000000000000000000000000000005e"

log()  { echo "[elecrow] $*"; }
die()  { echo "[elecrow] ERROR: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "run with sudo"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)  ACTION=uninstall ;;
    --status)     ACTION=status ;;
    --reset)      ACTION=reset ;;    # boot, before display manager
    --check)      ACTION=check ;;    # boot, after display manager
    --apply)      ACTION=apply ;;
    --no-restart) RESTART=0 ;;
    -h|--help)    sed -n '2,25p' "$0"; exit 0 ;;
    *)            die "unknown option: $1 (see --help)" ;;
  esac
  shift
done

load_conf() {
  HDMI_DFP=""; FORCE_HDMI=auto
  [[ -f "$CONF_FILE" ]] && . "$CONF_FILE"
  HDMI_DFP="${HDMI_DFP:-$(hdmi_dfp)}"
}

# X output name of the HDMI (TMDS) port, from the Xorg log; DFP-1 on Thor.
hdmi_dfp() {
  local d=""
  [[ -f "$XORG_LOG" ]] && d=$(grep -oE 'DFP-[0-9]+\)?: Internal TMDS' "$XORG_LOG" | head -1 | grep -oE 'DFP-[0-9]+' || true)
  echo "${d:-DFP-1}"
}

# DFPs the NVIDIA X driver reported as connected in the current Xorg log.
x_connected() {
  [[ -f "$XORG_LOG" ]] || return 0
  { grep -oE 'DFP-[0-9]+\)?: connected' "$XORG_LOG" || true; } | grep -oE 'DFP-[0-9]+' | sort -u | tr '\n' ' ' | sed 's/ $//' || true
}

forced_active() { [[ -f "$XORG_CONF" ]] && grep -qF "$MARK_BEGIN" "$XORG_CONF"; }

remove_block() {
  [[ -f "$XORG_CONF" ]] || return 0
  sed -i "/^${MARK_BEGIN//\//\\/}\$/,/^${MARK_END//\//\\/}\$/d" "$XORG_CONF"
}

add_block() {   # $1 = comma separated ConnectedMonitor list, HDMI first
  local list="$1"
  remove_block
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v dfp="$HDMI_DFP" -v list="$list" -v edid="$EDID_FILE" '
    { print }
    /^Section "Device"/ && !done {
      print b
      print "    Option      \"ConnectedMonitor\" \"" list "\""
      print "    Option      \"CustomEDID\" \"" dfp ":" edid "\""
      print "    Option      \"ModeValidation\" \"AllowNonEdidModes\""
      print e
      done=1
    }' "$XORG_CONF" > "$XORG_CONF.tmp"
  mv "$XORG_CONF.tmp" "$XORG_CONF"
}

# Wait until X (started with the stock config) has logged the detection result for all outputs.
wait_for_x_probe() {
  local start=$1 i n
  for i in $(seq 1 60); do
    if [[ -f "$XORG_LOG" && $(stat -c %Y "$XORG_LOG") -ge $start ]]; then
      n=$(grep -cE 'NVIDIA\(GPU-0\): .*DFP-[0-9]+\)?: (connected|disconnected)' "$XORG_LOG" || true)
      [[ $n -ge 4 ]] && { sleep 1; return 0; }
    fi
    sleep 1
  done
  return 1
}

# Decide after X has started with the stock config.
check_and_force() {
  load_conf
  if [[ "$FORCE_HDMI" == never ]]; then log "FORCE_HDMI=never -> keeping original config"; return 0; fi
  if forced_active; then log "Elecrow settings already active"; return 0; fi
  local conn dp list d
  conn=" $(x_connected) "
  if [[ "$FORCE_HDMI" == auto && "$conn" == *" $HDMI_DFP "* ]]; then
    log "X detected a monitor on HDMI ($HDMI_DFP) -> keeping original config"
    return 0
  fi
  list="$HDMI_DFP"
  for d in $conn; do [[ "$d" != "$HDMI_DFP" ]] && list+=", $d"; done
  add_block "$list"
  log "Nothing detected on HDMI -> adding Elecrow 1024x600 settings (ConnectedMonitor \"$list\")"
  log "Restarting display manager to apply"
  systemctl --no-block restart display-manager
}

show_status() {
  load_conf
  echo "X detected (connected): $(x_connected || true)    HDMI = $HDMI_DFP"
  if forced_active; then
    echo "mode: ORIGINAL config + Elecrow 1024x600 on HDMI"
    grep -F '"ConnectedMonitor"' "$XORG_CONF" | sed 's/^ */  /'
  else
    echo "mode: ORIGINAL config (all displays auto-detected)"
  fi
  echo "settings: FORCE_HDMI=$FORCE_HDMI"
  for u in elecrow-display elecrow-display-check; do
    echo "$u.service: $(systemctl is-enabled $u.service 2>/dev/null || echo not installed)"
  done
  if command -v xrandr >/dev/null; then
    DISPLAY=:0 xrandr 2>/dev/null | grep -A1 -E '^(HDMI|DP)-[0-9]+ connected' || echo "xrandr: nothing connected / cannot query DISPLAY=:0"
  fi
}

restart_and_check() {
  local t; t=$(date +%s)
  log "Restarting display manager with the original config (graphical session will be logged out)..."
  systemctl restart display-manager
  wait_for_x_probe "$t" || die "X did not report display detection within 60 s; check $XORG_LOG"
  check_and_force
}

case "$ACTION" in
  status) show_status ;;

  reset)  need_root; remove_block ;;

  check)
    need_root
    wait_for_x_probe "$(date -d "$(systemctl show -p ActiveEnterTimestamp --value display-manager)" +%s 2>/dev/null || echo 0)" \
      || die "X did not report display detection; leaving original config"
    check_and_force ;;

  apply)
    need_root; remove_block; restart_and_check ;;

  uninstall)
    need_root
    systemctl disable elecrow-display.service elecrow-display-check.service >/dev/null 2>&1 || true
    rm -f "$UNIT_RESET" "$UNIT_CHECK" "$TOOL" "$CONF_FILE"
    systemctl daemon-reload
    if [[ -f "$BACKUP" ]]; then
      cp "$BACKUP" "$XORG_CONF"; rm -f "$BACKUP"; log "Restored original $XORG_CONF"
    else
      remove_block; log "Removed Elecrow settings from $XORG_CONF"
    fi
    rm -f "$EDID_FILE"
    log "Uninstalled"
    [[ $RESTART -eq 1 ]] && systemctl restart display-manager
    ;;

  install)
    need_root
    [[ -f "$XORG_CONF" ]] || die "$XORG_CONF not found (is this a JetPack desktop image?)"
    grep -q '^Section "Device"' "$XORG_CONF" || die "no Device section in $XORG_CONF"
    [[ "$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null)" == *tegra264* ]] \
      || log "WARNING: this does not look like a Jetson Thor (tegra264); continuing anyway."
    remove_block
    if grep -qE '^\s*Option\s+"(ConnectedMonitor|CustomEDID)"' "$XORG_CONF"; then
      die "$XORG_CONF has ConnectedMonitor/CustomEDID options not managed by this script; remove them first"
    fi

    # 1. EDID
    printf '%s' "$EDID_HEX" | sed 's/../\\x&/g' | xargs -0 printf '%b' > "$EDID_FILE.tmp"
    [[ $(stat -c %s "$EDID_FILE.tmp") -eq 128 ]] || die "EDID generation failed"
    sum=$(od -An -tu1 -v "$EDID_FILE.tmp" | tr -s ' ' '\n' | awk 'NF{s+=$1} END{print s%256}')
    [[ "$sum" -eq 0 ]] || die "EDID checksum invalid"
    install -m 644 "$EDID_FILE.tmp" "$EDID_FILE"; rm -f "$EDID_FILE.tmp"
    log "Installed EDID: $EDID_FILE"

    # 2. Backup of the original config (first time only)
    [[ -f "$BACKUP" ]] || { cp "$XORG_CONF" "$BACKUP"; log "Backed up original config -> $BACKUP"; }

    # 3. Tool, settings, boot services
    install -m 755 "$(readlink -f "$0")" "$TOOL"
    if [[ ! -f "$CONF_FILE" ]] || ! grep -q '^FORCE_HDMI=' "$CONF_FILE"; then
      cat > "$CONF_FILE" <<EOF
# Settings for elecrow-display (read at every boot).
# HDMI_DFP:   X output name of the HDMI port (empty = auto-detect from the Xorg log; DFP-1 on Thor)
# FORCE_HDMI: auto   = add Elecrow settings only when X finds nothing on HDMI (default)
#             always = always use the Elecrow settings on HDMI
#             never  = never add them (original config only)
HDMI_DFP=
FORCE_HDMI=auto
EOF
    fi
    cat > "$UNIT_RESET" <<EOF
[Unit]
Description=Elecrow display: start display manager with the original X config
Before=display-manager.service gdm.service

[Service]
Type=oneshot
ExecStart=$TOOL --reset

[Install]
WantedBy=graphical.target
EOF
    cat > "$UNIT_CHECK" <<EOF
[Unit]
Description=Elecrow display: add Elecrow settings if X found nothing on HDMI
After=display-manager.service
Requires=elecrow-display.service

[Service]
Type=oneshot
TimeoutStartSec=120
ExecStart=$TOOL --check

[Install]
WantedBy=graphical.target
EOF
    systemctl daemon-reload
    systemctl enable elecrow-display.service elecrow-display-check.service >/dev/null
    log "Installed $TOOL and enabled boot services"

    # 4. Apply now
    if [[ $RESTART -eq 1 ]]; then restart_and_check; sleep 8; show_status
    else log "Skipped restart; applies at next boot (or run 'sudo elecrow-display --apply')."; fi
    ;;
esac
