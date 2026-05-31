#!/bin/sh
# ==================================================
# SMART TETHERING WATCHDOG FINAL
# OpenWrt + Ethernet Adapter tethering + wwan0
#
# Fungsi:
# - Memulihkan interface tethering Type Ethernet Adapter
# - Memulihkan device wwan0 yang down
# - Memulihkan bearer ModemManager yang bengong
# - Fallback ke ModemManager reset, AT+CFUN, USB reauthorize
#
# Install:
#   chmod +x /root/reboot.sh
#   sh /root/reboot.sh --install-cron
#
# Cron:
#   * * * * sh /root/reboot.sh
# ==================================================

LOCKFILE="/tmp/modem-watchdog.lock"
LOCKDIR="/tmp/modem-watchdog.lockdir"
STATEFILE="/tmp/modem-watchdog.fail"
COOLDOWNFILE="/tmp/modem-watchdog.cooldown"
LOGFILE="/tmp/reboot.log"

# ==================================================
# SESUAIKAN JIKA PERLU
# ==================================================

NETIF="tethering"
PHYSDEV="wwan0"
TTYDEV="/dev/ttyUSB0"
SCRIPT="/root/reboot.sh"

PING_TARGETS="1.1.1.1 8.8.8.8 104.17.3.81"

# Cron tiap 1 menit.
# Nilai 2 berarti deep recovery dimulai setelah gagal 2 kali berturut-turut.
FAILS_REQUIRED=2

# Cooldown deep recovery jika semua tahap gagal.
COOLDOWN_SECONDS=180

# Maksimal ukuran /tmp/reboot.log sebelum dikosongkan.
MAX_LOG_SIZE=200000

# ==================================================
# FINAL FALLBACK: REBOOT OPENWRT
# ==================================================
# 1 = aktifkan reboot router jika semua recovery gagal.
# 0 = matikan fallback reboot router.
ENABLE_ROUTER_REBOOT=1

# Jangan reboot router jika uptime masih terlalu pendek.
# Ini mencegah boot-loop saat modem/operator sedang bermasalah.
MIN_UPTIME_BEFORE_REBOOT_SECONDS=600

# Delay pendek sebelum perintah reboot dijalankan.
ROUTER_REBOOT_DELAY_SECONDS=5

# ==================================================
# LOCK
# ==================================================

acquire_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$LOCKFILE"

        if ! flock -n 9; then
            logger -t modem-watchdog "Already running, skipping"
            exit 0
        fi

        return 0
    fi

    if ! mkdir "$LOCKDIR" 2>/dev/null; then
        logger -t modem-watchdog "Already running, skipping"
        exit 0
    fi

    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
}

acquire_lock

# ==================================================
# LOGGING
# ==================================================

log() {
    MSG="$*"

    logger -t modem-watchdog "$MSG"

    if [ -f "$LOGFILE" ]; then
        SIZE="$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)"

        case "$SIZE" in
            ''|*[!0-9]*)
                SIZE=0
                ;;
        esac

        if [ "$SIZE" -gt "$MAX_LOG_SIZE" ]; then
            : > "$LOGFILE"
        fi
    fi

    echo "$(date '+%F %T') $MSG" >> "$LOGFILE"
}

# ==================================================
# UCI / CRON
# ==================================================

fix_uci_runtime() {
    DISABLED="$(uci -q get "network.$NETIF.disabled" 2>/dev/null)"
    AUTO="$(uci -q get "network.$NETIF.auto" 2>/dev/null)"

    if [ "$DISABLED" = "1" ]; then
        log "Runtime UCI fix: remove disabled from $NETIF"
        uci -q delete "network.$NETIF.disabled" 2>/dev/null || true
    fi

    if [ "$AUTO" != "1" ]; then
        log "Runtime UCI fix: set $NETIF auto=1"
        uci -q set "network.$NETIF.auto=1" 2>/dev/null || true
    fi
}

fix_uci_persistent() {
    CHANGED=0

    DISABLED="$(uci -q get "network.$NETIF.disabled" 2>/dev/null)"
    AUTO="$(uci -q get "network.$NETIF.auto" 2>/dev/null)"
    FORCE="$(uci -q get "network.$NETIF.force_connection" 2>/dev/null)"
    SIGNAL="$(uci -q get "network.$NETIF.signalrate" 2>/dev/null)"
    IP_TYPE="$(uci -q get "network.$NETIF.iptype" 2>/dev/null)"

    if [ "$DISABLED" = "1" ]; then
        uci -q delete "network.$NETIF.disabled" 2>/dev/null || true
        CHANGED=1
    fi

    if [ "$AUTO" != "1" ]; then
        uci -q set "network.$NETIF.auto=1" 2>/dev/null || true
        CHANGED=1
    fi

    if [ "$FORCE" != "1" ]; then
        uci -q set "network.$NETIF.force_connection=1" 2>/dev/null || true
        CHANGED=1
    fi

    if [ "$SIGNAL" != "15" ]; then
        uci -q set "network.$NETIF.signalrate=15" 2>/dev/null || true
        CHANGED=1
    fi

    if [ "$IP_TYPE" != "ipv4" ]; then
        uci -q set "network.$NETIF.iptype=ipv4" 2>/dev/null || true
        CHANGED=1
    fi

    if [ "$CHANGED" -eq 1 ]; then
        uci commit network
        log "Persistent UCI config updated for $NETIF"
    else
        log "Persistent UCI config already OK for $NETIF"
    fi
}

install_cron() {
    CRON_ENTRY="* * * * sh $SCRIPT"

    crontab -l 2>/dev/null \
        | grep -Fv "$SCRIPT" \
        > /tmp/modem-cron.tmp

    echo "$CRON_ENTRY" >> /tmp/modem-cron.tmp

    crontab /tmp/modem-cron.tmp
    rm -f /tmp/modem-cron.tmp

    fix_uci_persistent

    log "Cron installed: every 1 minute"
}

reset_state() {
    rm -f "$STATEFILE" "$COOLDOWNFILE"
    log "State reset"
}

# ==================================================
# DEVICE DETECTION
# ==================================================

get_l3dev() {
    L3DEV=""

    if command -v ifstatus >/dev/null 2>&1; then
        if command -v jsonfilter >/dev/null 2>&1; then
            L3DEV="$(
                ifstatus "$NETIF" 2>/dev/null \
                    | jsonfilter -e '@.l3_device' 2>/dev/null
            )"
        else
            L3DEV="$(
                ifstatus "$NETIF" 2>/dev/null \
                    | sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' \
                    | head -n 1
            )"
        fi
    fi

    if [ -n "$L3DEV" ]; then
        echo "$L3DEV"
        return 0
    fi

    if ip link show dev "$PHYSDEV" >/dev/null 2>&1; then
        echo "$PHYSDEV"
        return 0
    fi

    return 1
}

force_link_up() {
    DEV="$1"
    QUIET="$2"

    if [ -z "$DEV" ]; then
        return 1
    fi

    if ip link show dev "$DEV" >/dev/null 2>&1; then
        if [ "$QUIET" != "quiet" ]; then
            log "Force link up: $DEV"
        fi

        ip link set dev "$DEV" up 2>/dev/null || true
        return 0
    fi

    return 1
}

force_tethering_up() {
    log "Force bringing up logical interface: $NETIF"

    fix_uci_runtime

    ubus call "network.interface.$NETIF" up >/dev/null 2>&1 || true
    sleep 1

    ifup "$NETIF" 2>/dev/null || true
    sleep 2

    DEV="$(get_l3dev)"

    if [ -n "$DEV" ]; then
        force_link_up "$DEV"
    fi

    if [ "$PHYSDEV" != "$DEV" ]; then
        force_link_up "$PHYSDEV"
    fi

    return 0
}


renew_tethering() {
    log "Stage 0: renew/up $NETIF Type=Ethernet Adapter Device=$PHYSDEV"

    fix_uci_runtime

    ubus call "network.interface.$NETIF" renew >/dev/null 2>&1 || true
    sleep 2

    ubus call "network.interface.$NETIF" up >/dev/null 2>&1 || true
    ifup "$NETIF" 2>/dev/null || true

    force_link_up "$PHYSDEV" "quiet" >/dev/null 2>&1 || true

    wait_online 15
}

reboot_tethering() {
    log "Stage 1: reboot $NETIF Type=Ethernet Adapter Device=$PHYSDEV"

    fix_uci_runtime

    # Turunkan logical interface OpenWrt.
    ubus call "network.interface.$NETIF" down >/dev/null 2>&1 || true
    ifdown "$NETIF" 2>/dev/null || true
    sleep 2

    # Turunkan dan naikkan ulang device wwan0.
    if ip link show dev "$PHYSDEV" >/dev/null 2>&1; then
        log "Stage 1: link down $PHYSDEV"
        ip link set dev "$PHYSDEV" down 2>/dev/null || true
        sleep 2

        # Bersihkan IP lama agar DHCP/lease tidak nyangkut.
        ip addr flush dev "$PHYSDEV" 2>/dev/null || true
        sleep 1

        log "Stage 1: link up $PHYSDEV"
        ip link set dev "$PHYSDEV" up 2>/dev/null || true
        sleep 2
    else
        log "Stage 1: device $PHYSDEV not found"
    fi

    # Naikkan logical interface lagi.
    ubus call "network.interface.$NETIF" up >/dev/null 2>&1 || true
    sleep 1

    ifup "$NETIF" 2>/dev/null || true

    wait_online 35
}

# ==================================================
# CONNECTIVITY CHECK
# ==================================================

has_ip() {
    DEV="$(get_l3dev)"

    if [ -n "$DEV" ] && ip link show dev "$DEV" >/dev/null 2>&1; then
        ip -4 addr show dev "$DEV" 2>/dev/null \
            | grep -q "inet " \
            && return 0
    fi

    if ip link show dev "$PHYSDEV" >/dev/null 2>&1; then
        ip -4 addr show dev "$PHYSDEV" 2>/dev/null \
            | grep -q "inet " \
            && return 0
    fi

    return 1
}

ping_ok() {
    DEV="$(get_l3dev)"

    if [ -z "$DEV" ]; then
        return 1
    fi

    if ! ip link show dev "$DEV" >/dev/null 2>&1; then
        return 1
    fi

    for HOST in $PING_TARGETS; do
        ping -I "$DEV" -c 1 -W 1 "$HOST" >/dev/null 2>&1 \
            && return 0
    done

    return 1
}

check_connectivity() {
    has_ip || return 1
    ping_ok || return 1

    return 0
}

wait_online() {
    LIMIT="$1"
    I=0

    while [ "$I" -lt "$LIMIT" ]; do
        DEV="$(get_l3dev)"

        if [ -n "$DEV" ]; then
            force_link_up "$DEV" "quiet" >/dev/null 2>&1 || true
        fi

        if [ "$PHYSDEV" != "$DEV" ]; then
            force_link_up "$PHYSDEV" "quiet" >/dev/null 2>&1 || true
        fi

        if check_connectivity; then
            return 0
        fi

        sleep 1
        I=$((I + 1))
    done

    return 1
}

# ==================================================
# MODEMMANAGER
# ==================================================

get_mm_modem() {
    command -v mmcli >/dev/null 2>&1 || return 1

    mmcli -L 2>/dev/null \
        | sed -n 's|.*/Modem/\([0-9][0-9]*\).*|\1|p' \
        | head -n 1
}

mm_wait_modem() {
    LIMIT="$1"
    I=0

    while [ "$I" -lt "$LIMIT" ]; do
        MM="$(get_mm_modem)"

        if [ -n "$MM" ]; then
            echo "$MM"
            return 0
        fi

        sleep 1
        I=$((I + 1))
    done

    return 1
}

mm_recover() {
    command -v mmcli >/dev/null 2>&1 || return 1

    MM="$(get_mm_modem)"

    if [ -z "$MM" ]; then
        log "Stage MM: no modem found"
        return 1
    fi

    log "Stage MM: disconnect/disable/enable modem $MM"

    mmcli -m "$MM" --simple-disconnect >/dev/null 2>&1 || true
    sleep 2

    mmcli -m "$MM" --disable >/dev/null 2>&1 || true
    sleep 3

    mmcli -m "$MM" --enable >/dev/null 2>&1 || true
    sleep 6

    force_tethering_up

    wait_online 40
}

mm_daemon_restart() {
    log "Stage MM daemon: restarting ModemManager"

    if [ -x /etc/init.d/modemmanager ]; then
        /etc/init.d/modemmanager restart >/dev/null 2>&1 || true
    elif [ -x /etc/init.d/ModemManager ]; then
        /etc/init.d/ModemManager restart >/dev/null 2>&1 || true
    else
        log "Stage MM daemon failed: init script not found"
        return 1
    fi

    MM="$(mm_wait_modem 30)"

    if [ -n "$MM" ]; then
        log "Stage MM daemon: modem detected as $MM"
        mmcli -m "$MM" --enable >/dev/null 2>&1 || true
    else
        log "Stage MM daemon: modem not detected after restart"
    fi

    force_tethering_up

    wait_online 50
}

mm_reset_recover() {
    command -v mmcli >/dev/null 2>&1 || return 1

    MM="$(get_mm_modem)"

    if [ -z "$MM" ]; then
        log "Stage MM reset: no modem found"
        return 1
    fi

    log "Stage MM reset: mmcli --reset modem $MM"

    mmcli -m "$MM" --reset >/dev/null 2>&1 || true

    sleep 12

    MM="$(mm_wait_modem 35)"

    if [ -n "$MM" ]; then
        mmcli -m "$MM" --enable >/dev/null 2>&1 || true
    fi

    force_tethering_up

    wait_online 55
}

# ==================================================
# AT COMMAND
# ==================================================

at_cmd() {
    CMD="$1"
    TMO="${2:-5}"

    [ -e "$TTYDEV" ] || return 1
    command -v atinout >/dev/null 2>&1 || return 1

    if command -v timeout >/dev/null 2>&1; then
        OUTPUT="$(
            printf "%s\r\n" "$CMD" \
                | timeout "$TMO" atinout - "$TTYDEV" - 2>/dev/null \
                || true
        )"
    else
        OUTPUT="$(
            printf "%s\r\n" "$CMD" \
                | atinout - "$TTYDEV" - 2>/dev/null \
                || true
        )"
    fi

    echo "$OUTPUT" | grep -q "OK"
}

wait_tty() {
    LIMIT="$1"
    I=0

    while [ "$I" -lt "$LIMIT" ]; do
        if [ -e "$TTYDEV" ] && at_cmd "AT" 2; then
            return 0
        fi

        sleep 1
        I=$((I + 1))
    done

    return 1
}

soft_cfun_recover() {
    log "Stage AT soft: CFUN=4 then CFUN=1"

    ifdown "$NETIF" 2>/dev/null || true
    sleep 1

    at_cmd "AT+CFUN=4" 5 || true
    sleep 2

    at_cmd "AT+CFUN=1" 5 || true
    sleep 4

    force_tethering_up

    wait_online 45
}

hard_cfun_recover() {
    log "Stage AT hard: CFUN=1,1"

    at_cmd "AT+CFUN=1,1" 8 || true

    wait_tty 35 || true

    force_tethering_up

    wait_online 60
}

# ==================================================
# USB FALLBACK
# ==================================================

usb_cycle() {
    log "Stage USB: reauthorization fallback"

    TTYBASE="$(basename "$TTYDEV")"
    SYSPATH="$(readlink -f "/sys/class/tty/$TTYBASE/device" 2>/dev/null)"

    if [ -z "$SYSPATH" ]; then
        log "Stage USB failed: sysfs path not found"
        return 1
    fi

    USBDEV="$(dirname "$SYSPATH")"

    while [ "$USBDEV" != "/" ] && [ ! -f "$USBDEV/authorized" ]; do
        USBDEV="$(dirname "$USBDEV")"
    done

    if [ ! -f "$USBDEV/authorized" ]; then
        log "Stage USB failed: authorized file not found"
        return 1
    fi

    echo 0 > "$USBDEV/authorized" 2>/dev/null || return 1
    sleep 5

    echo 1 > "$USBDEV/authorized" 2>/dev/null || return 1
    sleep 10

    wait_tty 35 || true

    if [ -x /etc/init.d/modemmanager ]; then
        /etc/init.d/modemmanager restart >/dev/null 2>&1 || true
        sleep 8
    elif [ -x /etc/init.d/ModemManager ]; then
        /etc/init.d/ModemManager restart >/dev/null 2>&1 || true
        sleep 8
    fi

    force_tethering_up

    wait_online 60
}

network_service_restart() {
    log "Stage network: restarting network service"

    /etc/init.d/network restart >/dev/null 2>&1 || true

    sleep 10

    force_tethering_up

    wait_online 50
}


# ==================================================
# ROUTER REBOOT FALLBACK
# ==================================================

get_uptime_seconds() {
    awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0
}

router_reboot_fallback() {
    if [ "$ENABLE_ROUTER_REBOOT" != "1" ]; then
        log "Final fallback skipped: router reboot disabled"
        return 1
    fi

    UPTIME="$(get_uptime_seconds)"

    case "$UPTIME" in
        ''|*[!0-9]*)
            UPTIME=0
            ;;
    esac

    if [ "$UPTIME" -lt "$MIN_UPTIME_BEFORE_REBOOT_SECONDS" ]; then
        log "Final fallback skipped: uptime ${UPTIME}s is below minimum ${MIN_UPTIME_BEFORE_REBOOT_SECONDS}s"
        return 1
    fi

    log "FINAL FALLBACK: all recovery failed, rebooting OpenWrt in ${ROUTER_REBOOT_DELAY_SECONDS}s"

    sync
    sleep "$ROUTER_REBOOT_DELAY_SECONDS"
    /sbin/reboot

    return 0
}

# ==================================================
# STATE
# ==================================================

get_fail_count() {
    FAIL="$(cat "$STATEFILE" 2>/dev/null)"

    case "$FAIL" in
        ''|*[!0-9]*)
            FAIL=0
            ;;
    esac

    echo "$FAIL"
}

get_last_cooldown() {
    LAST="$(cat "$COOLDOWNFILE" 2>/dev/null)"

    case "$LAST" in
        ''|*[!0-9]*)
            LAST=0
            ;;
    esac

    echo "$LAST"
}

run_time_sync() {
    if [ -x /root/time2.sh ]; then
        log "Running /root/time2.sh"
        sh /root/time2.sh
    fi
}

show_status() {
    echo "=== TETHERING WATCHDOG STATUS ==="
    echo "NETIF       : $NETIF"
    echo "TYPE        : Ethernet Adapter"
    echo "DEVICE      : $PHYSDEV"
    echo "TTYDEV      : $TTYDEV"
    echo "L3DEV       : $(get_l3dev 2>/dev/null)"
    echo "FAIL COUNT  : $(get_fail_count)"
    echo "COOLDOWN    : $(get_last_cooldown)"
    echo "UPTIME      : $(get_uptime_seconds)s"
    echo "REBOOT FB   : $ENABLE_ROUTER_REBOOT"
    echo

    echo "=== IFSTATUS $NETIF ==="
    if command -v ifstatus >/dev/null 2>&1; then
        ifstatus "$NETIF" 2>/dev/null || echo "ifstatus failed"
    else
        echo "ifstatus not found"
    fi
    echo

    echo "=== IP ADDR $PHYSDEV ==="
    ip addr show dev "$PHYSDEV" 2>/dev/null || echo "$PHYSDEV not found"
    echo

    echo "=== MODEMMANAGER ==="
    if command -v mmcli >/dev/null 2>&1; then
        mmcli -L 2>/dev/null || echo "mmcli -L failed"
    else
        echo "mmcli not installed"
    fi
    echo

    echo "=== CONNECTIVITY ==="
    if check_connectivity; then
        echo "ONLINE"
    else
        echo "OFFLINE"
    fi
}

# ==================================================
# ARGUMENTS
# ==================================================

case "$1" in
    --install-cron)
        install_cron
        exit 0
        ;;

    --fix-uci)
        fix_uci_persistent
        exit 0
        ;;

    --reset-state)
        reset_state
        exit 0
        ;;

    --status)
        show_status
        exit 0
        ;;

    --reboot-tethering)
        reboot_tethering
        exit $?
        ;;
esac

# ==================================================
# MAIN
# ==================================================

log "=== Watchdog check started ==="

# Tahap 0:
# Jika koneksi masih sehat, jangan lakukan ifup/ubus up.
# Ini mengurangi beban netifd, ModemManager, dan modem.
if check_connectivity; then
    rm -f "$STATEFILE" "$COOLDOWNFILE"
    log "Connection healthy"
    exit 0
fi

log "No connection detected on $NETIF/$PHYSDEV"

# Tahap 1:
# Karena interface di LuCI adalah Type=Ethernet Adapter Device=wwan0,
# recovery utama adalah renew/up lalu reboot tethering.
if renew_tethering; then
    rm -f "$STATEFILE" "$COOLDOWNFILE"
    log "RECOVERED via renew_tethering"
    run_time_sync
    log "=== Watchdog cycle done ==="
    exit 0
fi

if reboot_tethering; then
    rm -f "$STATEFILE" "$COOLDOWNFILE"
    log "RECOVERED via reboot_tethering"
    run_time_sync
    log "=== Watchdog cycle done ==="
    exit 0
fi

# Tahap 2:
# Jika recovery ringan belum berhasil, baru hitung gagal berturut-turut.
FAIL="$(get_fail_count)"
FAIL=$((FAIL + 1))
echo "$FAIL" > "$STATEFILE"

log "Connectivity failed $FAIL/$FAILS_REQUIRED after reboot_tethering"

if [ "$FAIL" -lt "$FAILS_REQUIRED" ]; then
    log "Waiting next cycle before deep recovery"
    exit 0
fi

# Tahap 3:
# Cek cooldown agar modem tidak dihajar reset terus-menerus.
NOW="$(date +%s)"
LAST_COOLDOWN="$(get_last_cooldown)"

if [ "$LAST_COOLDOWN" -gt 0 ]; then
    AGE=$((NOW - LAST_COOLDOWN))

    if [ "$AGE" -lt "$COOLDOWN_SECONDS" ]; then
        log "Cooldown active, skip deep recovery. Age=${AGE}s"
        exit 0
    fi
fi

# Tahap 4:
# Deep recovery bertingkat.
RECOVERED=0

if mm_recover; then
    log "RECOVERED via ModemManager disconnect/disable/enable"
    RECOVERED=1
elif mm_daemon_restart; then
    log "RECOVERED via ModemManager daemon restart"
    RECOVERED=1
elif mm_reset_recover; then
    log "RECOVERED via mmcli modem reset"
    RECOVERED=1
elif soft_cfun_recover; then
    log "RECOVERED via AT CFUN soft reset"
    RECOVERED=1
elif hard_cfun_recover; then
    log "RECOVERED via AT CFUN hard restart"
    RECOVERED=1
elif usb_cycle; then
    log "RECOVERED via USB fallback"
    RECOVERED=1
elif network_service_restart; then
    log "RECOVERED via network service restart"
    RECOVERED=1
else
    log "Still down after all recovery stages"
    echo "$NOW" > "$COOLDOWNFILE"
    router_reboot_fallback || true
fi

if [ "$RECOVERED" -eq 1 ]; then
    rm -f "$STATEFILE" "$COOLDOWNFILE"
    run_time_sync
fi

log "=== Watchdog cycle done ==="
exit 0
