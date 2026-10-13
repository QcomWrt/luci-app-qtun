#!/bin/sh
# /etc/qtun/action/q-ssh.sh
# Q-SSH-WORKER + Q-load + Mihomo launcher (Optimized for single-process multi-port)

set -u

trap '' HUP PIPE

BASE="/etc/qtun"
RUN="$BASE/run"

# Core binaries
QSSH_BIN="$BASE/core/Q-SSH-WORKER"
QLOAD_BIN="$BASE/core/q-load"
CLASH_BIN="$BASE/core/clash"

# Configs
QSSH_DIR="$BASE/config/q-ssh"
QSSH_CFG="$BASE/config/q-ssh/config.json"
CLASH_DIR="$BASE/config/clash"
CLASH_CFG="$CLASH_DIR/q-ssh.yaml"

# PID files
QSSH_PID="$RUN/q-ssh.pid"
QLOAD_PID="$RUN/q-load.pid"
CLASH_PID="$RUN/clash.pid"

# Logs
QSSH_LOG="$RUN/q-ssh.log"
QLOAD_LOG="$RUN/q-load.log"
CLASH_LOG="$RUN/clash.log"

mkdir -p "$RUN"

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

kill_pid_file() {
    FILE="$1"
    [ -f "$FILE" ] || return 0
    PID="$(cat "$FILE" 2>/dev/null)"
    [ -n "$PID" ] && kill "$PID" 2>/dev/null
    rm -f "$FILE"
}

auto_rotate_pid_log() {
    PID_FILE="$1"
    LOG_FILE="$2"
    (
        while true; do
            [ -f "$PID_FILE" ] || break
            PID="$(cat "$PID_FILE" 2>/dev/null)"
            [ -n "$PID" ] || break
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            rotate_log "$LOG_FILE"
            sleep 10
        done
    ) &
}

prepare_config() {
    log "Preparing Q-SSH JSON configuration..."

    # Baca pilihan qssh_inject_mode dari UCI /etc/config/qtun
    INJECT_MODE="$(uci -q get qtun.main.qssh_inject_mode)"
    [ -z "$INJECT_MODE" ] && INJECT_MODE="ssl_payload"

    SRC_JSON="$QSSH_DIR/${INJECT_MODE}.json"

    if [ -f "$SRC_JSON" ]; then
        cp -f "$SRC_JSON" "$QSSH_CFG"
        log "Active config loaded: ${INJECT_MODE}.json -> config.json"
    else
        log "Warning: Target config $SRC_JSON not found! Using existing config.json"
    fi
}

stop_existing() {
    rotate_log "$QSSH_LOG"
    rotate_log "$QLOAD_LOG"
    rotate_log "$CLASH_LOG"

    [ -f "$QSSH_PID" ] && kill_pid_file "$QSSH_PID"
    [ -f "$QLOAD_PID" ] && kill_pid_file "$QLOAD_PID"
    [ -f "$CLASH_PID" ] && kill_pid_file "$CLASH_PID"

    killall -9 Q-SSH-WORKER q-load clash mihomo 2>/dev/null
    sleep 2
}

start_qssh() {
    log "Starting Q-SSH-WORKER..."

    if [ ! -x "$QSSH_BIN" ]; then
        log "Q-SSH-WORKER binary not found: $QSSH_BIN"
        return 1
    fi

    if [ ! -f "$QSSH_CFG" ]; then
        log "Q-SSH config not found: $QSSH_CFG"
        return 1
    fi

    : > "$QSSH_LOG"

    # Jalankan Q-SSH-WORKER dengan pembungkus daemon mandiri
    nohup "$QSSH_BIN" --dial "$QSSH_CFG" >> "$QSSH_LOG" 2>&1 &
    echo "$!" > "$QSSH_PID"

    auto_rotate_pid_log "$QSSH_PID" "$QSSH_LOG"
    
    # Tunggu 5 detik penuh agar port listen matang sempurna
    sleep 5

    # Verifikasi keaktifan via netstat langsung ke range port 1080-1089
    if is_running "$QSSH_PID" || netstat -an 2>/dev/null | grep -q "127.0.0.1:108[0-9].*LISTEN"; then
        log "Q-SSH-WORKER process and listeners verified"
        return 0
    fi

    log "Q-SSH-WORKER failed to bind listeners"
    return 1
}

start_qload() {
    log "Starting Q-load aggregator..."

    if [ ! -x "$QLOAD_BIN" ]; then
        log "Q-load binary not found: $QLOAD_BIN"
        return 1
    fi

    if [ ! -f "$QSSH_CFG" ]; then
        log "Q-SSH config not found for extraction: $QSSH_CFG"
        return 1
    fi

    # =========================================================
    # EKSTRAKSI PARAMETER WORKER DARI CONFIG.JSON
    # =========================================================
    local start_port
    local workers
    
    start_port=$(jsonfilter -i "$QSSH_CFG" -e '@.concurrency.start_port' 2>/dev/null)
    workers=$(jsonfilter -i "$QSSH_CFG" -e '@.concurrency.workers' 2>/dev/null)

    # Fallback aman jika parsing JSON gagal atau parameter kosong
    [ -z "$start_port" ] && start_port=$(jsonfilter -i "$QSSH_CFG" -e '@.listen.port' 2>/dev/null)
    [ -z "$start_port" ] && start_port=1080
    [ -z "$workers" ] && workers=5

    # GENERATE RANGE PORT SECARA STRUKTURAL & DEFENSIF
    TUNNEL_ARGS=""
    local current_port=$start_port
    local i=1

    while [ $i -le "$workers" ]; do
        TUNNEL_ARGS="$TUNNEL_ARGS 127.0.0.1:$current_port"
        current_port=$((current_port + 1))
        i=$((i + 1))
    done

    # Bersihkan spasi di awal string
    TUNNEL_ARGS=$(echo "$TUNNEL_ARGS" | sed 's/^ //')

    log "Q-load dynamic structural tunnels allocated: $TUNNEL_ARGS"

    : > "$QLOAD_LOG"

    # Jalankan q-load terpisah sempurna dari pipa penampung LuCI
    nohup "$QLOAD_BIN" -lport 7777 -tunnel $TUNNEL_ARGS >> "$QLOAD_LOG" 2>&1 &
    echo "$!" > "$QLOAD_PID"

    sleep 3

    if [ -f "$QLOAD_PID" ] || netstat -an 2>/dev/null | grep -q "127.0.0.1:7777.*LISTEN"; then
        log "Q-load successfully aggregated to 127.0.0.1:7777"
        return 0
    fi

    log "Q-load aggregator failed to start"
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

    # Jalankan Clash dengan pembungkus daemon mandiri
    nohup "$CLASH_BIN" -d "$CLASH_DIR" -f "$CLASH_CFG" >> "$CLASH_LOG" 2>&1 &
    echo "$!" > "$CLASH_PID"

    auto_rotate_pid_log "$CLASH_PID" "$CLASH_LOG"
    sleep 3

    if is_running "$CLASH_PID"; then
        log "Clash core started successfully"
        return 0
    fi

    log "Clash core failed to start"
    return 1
}

check_ports() {
    log "Checking active listeners..."
    netstat -an 2>/dev/null | grep -E ':(108[0-4]|7777|789[0-9]|9090)' | grep LISTEN
}

status_stack() {
    rotate_log "$QSSH_LOG"
    rotate_log "$QLOAD_LOG"
    rotate_log "$CLASH_LOG"

    is_running "$QSSH_PID" && log "Q-SSH-WORKER: RUNNING" || log "Q-SSH-WORKER: STOPPED"
    is_running "$QLOAD_PID" && log "Q-load: RUNNING" || log "Q-load: STOPPED"
    is_running "$CLASH_PID" && log "Mihomo/Clash: RUNNING" || log "Mihomo/Clash: STOPPED"

    check_ports
}

main() {
    log "Initializing Q-SSH stack..."

    stop_existing

    prepare_config
    
    # Rantai Ketergantungan Ketat (Fail-Fast Mechanism)
    start_qssh || { log "Fatal: Q-SSH-WORKER failed to initialize. Aborting stack."; exit 1; }
    start_qload || { log "Fatal: Q-load aggregator failed to initialize. Aborting stack."; exit 1; }
    start_clash || { log "Fatal: Clash core failed to initialize. Aborting stack."; exit 1; }

    check_ports
    log "Q-SSH core stack up and running perfectly!"
}

case "${1:-}" in
    start)
        main
        ;;
    stop)
        stop_existing
        log "Q-SSH stack stopped clean"
        ;;
    restart)
        stop_existing
        sleep 1
        main
        ;;
    status)
        status_stack
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac