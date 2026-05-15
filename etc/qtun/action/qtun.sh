#!/bin/sh
# /etc/qtun/action/qtun.sh

MODE="$(uci -q get qtun.main.mode 2>/dev/null)"
ENABLED="$(uci -q get qtun.main.enabled 2>/dev/null)"
ACTION="${1:-start}"

RUN="/etc/qtun/run"
WATCHDOG_SH="/etc/qtun/action/watchdog.sh"
WATCHDOG_PID="$RUN/watchdog.pid"

mkdir -p "$RUN"

log() {
    /etc/qtun/action/logs.sh process "$1"
}

start_watchdog() {
    [ -x "$WATCHDOG_SH" ] || {
        log "Watchdog not found or not executable"
        return 1
    }

    if [ -f "$WATCHDOG_PID" ]; then
        PID="$(cat "$WATCHDOG_PID" 2>/dev/null)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            log "QTUN watchdog already running"
            return 0
        fi
    fi

    log "Starting QTUN watchdog"
    "$WATCHDOG_SH" >/dev/null 2>&1 &
    echo "$!" > "$WATCHDOG_PID"
}

stop_watchdog() {
    if [ -f "$WATCHDOG_PID" ]; then
        PID="$(cat "$WATCHDOG_PID" 2>/dev/null)"
        [ -n "$PID" ] && kill "$PID" 2>/dev/null
        rm -f "$WATCHDOG_PID"
        log "QTUN watchdog stopped"
    fi
}

# =========================================================
# START MODE (MANUAL START - SELALU BOLEH)
# Tidak cek enabled
# =========================================================
start_mode() {
    case "$MODE" in
        zivpn)
            /etc/qtun/action/zivpn.sh start || exit 1
            ;;
        ssh)
            /etc/qtun/action/ssh.sh start || exit 1
            ;;
        ssh_ws)
            /etc/qtun/action/ssh_ws.sh start || exit 1
            ;;
        ssh_ssl)
            /etc/qtun/action/ssh_ssl.sh start || exit 1
            ;;
        "")
            log "No mode configured (qtun.main.mode)"
            exit 1
            ;;
        *)
            log "Unknown mode: $MODE"
            exit 1
            ;;
    esac

    /etc/qtun/action/routing.sh start
    start_watchdog
}

# =========================================================
# BOOT MODE (AUTOSTART ONLY)
# Cek enabled
# =========================================================
boot_mode() {
    if [ "$ENABLED" != "1" ]; then
        log "QTUN autostart disabled (qtun.main.enabled=0)"
        exit 0
    fi

    log "QTUN autostart enabled"
    start_mode
}

# =========================================================
# STOP ALL
# =========================================================
stop_mode() {
    stop_watchdog

    /etc/qtun/action/routing.sh stop

    for MODE_SCRIPT in zivpn ssh ssh_ws ssh_ssl; do
        [ -x "/etc/qtun/action/$MODE_SCRIPT.sh" ] && \
        /etc/qtun/action/"$MODE_SCRIPT.sh" stop
    done
}

# =========================================================
# STATUS
# =========================================================
status_mode() {
    log "Enabled (autostart): ${ENABLED:-0}"
    log "Mode: ${MODE:-none}"

    # Watchdog status
    if [ -f "$WATCHDOG_PID" ]; then
        PID="$(cat "$WATCHDOG_PID" 2>/dev/null)"

        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            log "Watchdog: RUNNING (PID $PID)"
        else
            log "Watchdog: DEAD"
        fi
    else
        log "Watchdog: STOPPED"
    fi

    case "$MODE" in
        zivpn)
            [ -x /etc/qtun/action/zivpn.sh ] && \
            /etc/qtun/action/zivpn.sh status
            ;;
        ssh)
            [ -x /etc/qtun/action/ssh.sh ] && \
            /etc/qtun/action/ssh.sh status
            ;;
        ssh_ws)
            [ -x /etc/qtun/action/ssh_ws.sh ] && \
            /etc/qtun/action/ssh_ws.sh status
            ;;
        ssh_ssl)
            [ -x /etc/qtun/action/ssh_ssl.sh ] && \
            /etc/qtun/action/ssh_ssl.sh status
            ;;
    esac

    /etc/qtun/action/routing.sh status
}

# =========================================================
# ACTION ROUTER
# =========================================================
case "$ACTION" in
    start)
        # Manual start selalu jalan
        stop_mode
        start_mode
        ;;
    boot)
        # Dipakai init/autostart saat boot
        stop_mode
        boot_mode
        ;;
    stop)
        stop_mode
        ;;
    restart)
        stop_mode
        sleep 2
        start_mode
        ;;
    status)
        status_mode
        ;;
    *)
        echo "Usage: $0 {start|boot|stop|restart|status}"
        exit 1
        ;;
esac