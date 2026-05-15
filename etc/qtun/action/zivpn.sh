#!/bin/sh
# /etc/qtun/action/zivpn.sh
# ZiVPN + Q-load + Mihomo launcher (optimized for logs.sh auto-trim)

set -u

BASE="/etc/qtun"
RUN="$BASE/run"

# Core binaries
ZIVPN_BIN="$BASE/core/zivpn"
QLOAD_BIN="$BASE/core/q-load"
CLASH_BIN="$BASE/core/clash"

# Configs
ZIVPN_CFG="$BASE/config/zivpn/config.json"
CLASH_DIR="$BASE/config/clash"
CLASH_CFG="$CLASH_DIR/zivpn.yaml"

# PID files
ZIVPN_PID="$RUN/zivpn.pid"
QLOAD_PID="$RUN/q-load.pid"
CLASH_PID="$RUN/clash.pid"

# Logs
ZIVPN_LOG="$RUN/zivpn.log"
QLOAD_LOG="$RUN/q-load.log"
CLASH_LOG="$RUN/clash.log"

# Worker
WORKER_DIR="$RUN/workers"
WORKER_TOTAL=8

TUNNEL_LIST=""

mkdir -p "$RUN" "$WORKER_DIR"

log() {
    /etc/qtun/action/logs.sh process "$1"
}

rotate_log() {
    [ -n "${1:-}" ] && /etc/qtun/action/logs.sh rotate "$1"
}

is_running() {
    [ -f "$1" ] || return 1
    PID="$(cat "$1" 2>/dev/null)"
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null
}

is_running_multi() {
    [ -f "$1" ] || return 1

    while read -r pid; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    done < "$1"

    return 1
}

kill_pid_file() {
    FILE="$1"

    [ -f "$FILE" ] || return 0

    while read -r pid; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done < "$FILE"

    rm -f "$FILE"
}

cleanup_workers() {
    rm -f "$WORKER_DIR"/*.log "$WORKER_DIR"/*.pid "$WORKER_DIR"/*.json 2>/dev/null
}

append_zivpn_log() {
    echo "$1" >> "$ZIVPN_LOG"
    rotate_log "$ZIVPN_LOG"
}

auto_rotate_pid_log() {
    PID_FILE="$1"
    LOG_FILE="$2"

    (
        while true; do
            [ -f "$PID_FILE" ] || break

            PID="$(cat "$PID_FILE" 2>/dev/null)"

            [ -n "$PID" ] || break

            if ! kill -0 "$PID" 2>/dev/null; then
                break
            fi

            rotate_log "$LOG_FILE"

            sleep 10
        done
    ) &
}

stop_existing() {
    rotate_log "$ZIVPN_LOG"
    rotate_log "$QLOAD_LOG"
    rotate_log "$CLASH_LOG"

    if [ -f "$ZIVPN_PID" ]; then
        kill_pid_file "$ZIVPN_PID"
        log "Stopped old ZiVPN"
    fi

    if [ -f "$QLOAD_PID" ]; then
        kill_pid_file "$QLOAD_PID"
        log "Stopped old Q-load"
    fi

    if [ -f "$CLASH_PID" ]; then
        kill_pid_file "$CLASH_PID"
        log "Stopped old Clash"
    fi

    for pidfile in "$WORKER_DIR"/*.pid; do
        [ -f "$pidfile" ] && kill_pid_file "$pidfile"
    done

    killall -9 zivpn q-load clash mihomo 2>/dev/null

    cleanup_workers

    sleep 2
}

start_zivpn() {
    log "Starting ZiVPN..."

    if [ ! -x "$ZIVPN_BIN" ]; then
        log "ZiVPN binary not found: $ZIVPN_BIN"
        return 1
    fi

    if [ ! -f "$ZIVPN_CFG" ]; then
        log "ZiVPN config not found: $ZIVPN_CFG"
        return 1
    fi

    : > "$ZIVPN_PID"
    : > "$ZIVPN_LOG"

    TUNNEL_LIST=""
    WORKER_SUCCESS=0
    TIMEOUT_FAIL=0

    for i in $(busybox seq 0 $((WORKER_TOTAL - 1))); do
        PORT=$((1080 + i))

        WORKER_LOG="$WORKER_DIR/zivpn-$PORT.log"
        WORKER_PID="$WORKER_DIR/zivpn-$PORT.pid"

        CONFIG_JSON="$(sed "s/127.0.0.1:1080/127.0.0.1:$PORT/g" "$ZIVPN_CFG")"

        rm -f "$WORKER_LOG"
        touch "$WORKER_LOG"

        "$ZIVPN_BIN" -s 'hu``hqb`c' --config "$CONFIG_JSON" \
            2>&1 | sed "s/^/[PORT:$PORT] /" | tee -a "$WORKER_LOG" >> "$ZIVPN_LOG" &

        PID=$!

        echo "$PID" >> "$ZIVPN_PID"
        echo "$PID" > "$WORKER_PID"

        READY=0
        LAST_ERR=""

        for t in $(busybox seq 1 15); do
            sleep 1
            sync

            rotate_log "$WORKER_LOG"
            rotate_log "$ZIVPN_LOG"

            if grep -Ei "FATAL|timeout|unreachable|INTERNAL_ERROR|error" "$WORKER_LOG" >/dev/null; then
                LAST_ERR="$(grep -Ei "FATAL|timeout|unreachable|INTERNAL_ERROR|error" \
                    "$WORKER_LOG" | tail -n 1)"
                break
            fi

            if ! kill -0 "$PID" 2>/dev/null; then
                LAST_ERR="$(tail -n 20 "$WORKER_LOG" | tail -n 1)"
                [ -z "$LAST_ERR" ] && LAST_ERR="Process died without log"
                break
            fi

            if netstat -tunlp 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
                READY=1
                break
            fi
        done

        if [ "$READY" -eq 1 ]; then
            log "ZiVPN started on :$PORT (PID $PID)"

            if [ -z "$TUNNEL_LIST" ]; then
                TUNNEL_LIST="127.0.0.1:$PORT"
            else
                TUNNEL_LIST="$TUNNEL_LIST 127.0.0.1:$PORT"
            fi

            WORKER_SUCCESS=$((WORKER_SUCCESS + 1))

            LAST_LOG="$(tail -n 20 "$WORKER_LOG" 2>/dev/null | tail -n 1)"
            [ -z "$LAST_LOG" ] && LAST_LOG="STARTED"

            append_zivpn_log "[PORT:$PORT][PID:$PID] SUCCESS: $LAST_LOG"

            TIMEOUT_FAIL=0
            continue
        fi

        [ -z "$LAST_ERR" ] && LAST_ERR="$(tail -n 20 "$WORKER_LOG" 2>/dev/null | tail -n 1)"
        [ -z "$LAST_ERR" ] && LAST_ERR="Port bind failed without log"

        if echo "$LAST_ERR" | grep -qi "timeout: no recent network activity"; then
            TIMEOUT_FAIL=$((TIMEOUT_FAIL + 1))

            log "ZiVPN failed on :$PORT"
            log "Reason: Upstream timeout"

            append_zivpn_log "[PORT:$PORT][PID:$PID] CONNECTION_TIMEOUT: $LAST_ERR"

        elif echo "$LAST_ERR" | grep -Eqi "FATAL|timeout|unreachable|INTERNAL_ERROR|error"; then
            log "ZiVPN failed on :$PORT"
            log "Reason: $LAST_ERR"

            append_zivpn_log "[PORT:$PORT][PID:$PID] FAILED: $LAST_ERR"

        else
            log "ZiVPN backend failed on :$PORT"
            log "Last Log: $LAST_ERR"

            append_zivpn_log "[PORT:$PORT][PID:$PID] BACKEND_FAILED: $LAST_ERR"
        fi

        kill "$PID" 2>/dev/null
        rm -f "$WORKER_PID"

        if [ "$TIMEOUT_FAIL" -ge 3 ]; then
            log "Multiple upstream timeout detected (3x), aborting remaining workers"
            append_zivpn_log "[ABORT] Multiple upstream timeout detected"
            break
        fi
    done

    append_zivpn_log "[SUMMARY] $WORKER_SUCCESS/$WORKER_TOTAL workers active"

    if [ "$WORKER_SUCCESS" -gt 0 ]; then
        log "ZiVPN Tunnel active: $WORKER_SUCCESS/$WORKER_TOTAL backends running"
        return 0
    fi

    log "All ZiVPN Tunnel failed"
    return 1
}

start_qload() {
    log "Starting Q-load..."

    if [ ! -x "$QLOAD_BIN" ]; then
        log "Q-load binary not found: $QLOAD_BIN"
        return 1
    fi

    if [ -z "$TUNNEL_LIST" ]; then
        log "Q-load aborted: No active ZiVPN tunnel"
        return 1
    fi

    : > "$QLOAD_LOG"

    set -- $TUNNEL_LIST

    "$QLOAD_BIN" -lport 7777 -tunnel "$@" > "$QLOAD_LOG" 2>&1 &

    echo "$!" > "$QLOAD_PID"

    auto_rotate_pid_log "$QLOAD_PID" "$QLOAD_LOG"

    sleep 3

    if netstat -tunlp 2>/dev/null | grep -q "127.0.0.1:7777"; then
        log "Q-load started on 127.0.0.1:7777 (PID $(cat "$QLOAD_PID"))"
        return 0
    fi

    log "Q-load failed"
    [ -f "$QLOAD_LOG" ] && log "Last Log: $(tail -n 50 "$QLOAD_LOG")"

    return 1
}

start_clash() {
    log "Starting Clash..."

    if [ ! -x "$CLASH_BIN" ]; then
        log "Clash binary not found: $CLASH_BIN"
        return 1
    fi

    if [ ! -f "$CLASH_CFG" ]; then
        log "Clash config not found: $CLASH_CFG"
        return 1
    fi

    : > "$CLASH_LOG"

    "$CLASH_BIN" -d "$CLASH_DIR" -f "$CLASH_CFG" > "$CLASH_LOG" 2>&1 &

    echo "$!" > "$CLASH_PID"

    auto_rotate_pid_log "$CLASH_PID" "$CLASH_LOG"

    sleep 3

    if is_running "$CLASH_PID"; then
        log "Clash started (PID $(cat "$CLASH_PID"))"
        return 0
    fi

    log "Clash failed"
    [ -f "$CLASH_LOG" ] && log "Last Log: $(tail -n 20 "$CLASH_LOG")"

    return 1
}

check_ports() {
    log "Checking active listeners..."
    netstat -lntp 2>/dev/null | grep -E '127.0.0.1:(108[0-7]|7777|7890|7891|9090)'
}

status_stack() {
    rotate_log "$ZIVPN_LOG"
    rotate_log "$QLOAD_LOG"
    rotate_log "$CLASH_LOG"

    is_running_multi "$ZIVPN_PID" && log "ZiVPN: RUNNING" || log "ZiVPN: STOPPED"
    is_running "$QLOAD_PID" && log "Q-load: RUNNING" || log "Q-load: STOPPED"
    is_running "$CLASH_PID" && log "Mihomo: RUNNING" || log "Mihomo: STOPPED"

    check_ports
}

main() {
    log "Initializing ZiVPN stack..."

    stop_existing
    start_zivpn || exit 1

    sleep 2

    start_qload || exit 1

    sleep 2

    start_clash || exit 1

    check_ports

    log "ZiVPN stack started successfully"
    log "Use routing.sh to redirect traffic"
}

stop_zivpn_only() {
    log "Stopping ZiVPN workers only..."

    if [ -f "$ZIVPN_PID" ]; then
        kill_pid_file "$ZIVPN_PID"
    fi

    for pidfile in "$WORKER_DIR"/*.pid; do
        [ -f "$pidfile" ] && kill_pid_file "$pidfile"
    done

    killall -9 zivpn 2>/dev/null
    cleanup_workers

    log "ZiVPN workers stopped"
}

restart_zivpn_only() {
    log "Restarting ZiVPN workers only..."

    stop_zivpn_only
    sleep 2

    start_zivpn || {
        log "ZiVPN reconnect failed"
        return 1
    }

    log "ZiVPN workers reconnected"
    return 0
}

case "${1:-}" in
    start)
        main
        ;;
    stop)
        stop_existing
        log "ZiVPN stack stopped"
        ;;
    restart)
        stop_existing
        sleep 2
        main
        ;;
    reconnect-zivpn)
        restart_zivpn_only
        ;;
    status)
        status_stack
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|reconnect-zivpn|status}"
        exit 1
        ;;
esac