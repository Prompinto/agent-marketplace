#!/usr/bin/env bash
# lifecycle.sh -- start / health-check / stop a detected dev command, PID-tracked.
#
# Never finds-then-kills by port (lsof -ti:<port> | xargs kill) -- that can
# kill an unrelated process that happens to occupy the same port. Every PID
# this script kills is one it itself started and recorded in a session-scoped
# PID file; the caller is responsible for passing the same PID file back to
# `stop`.
set -u

usage() {
  cat >&2 <<'EOF'
Usage:
  lifecycle.sh health <host> <port> [timeout_secs]
  lifecycle.sh start <cwd> <command> <pid_file> <log_file>
  lifecycle.sh wait-healthy <host> <port> <timeout_secs> <log_file>
  lifecycle.sh stop <pid_file>
EOF
}

MODE="${1:-}"
[ -n "$MODE" ] || { usage; exit 1; }
shift || true

case "$MODE" in
  health)
    HOST="${1:-127.0.0.1}"; PORT="${2:-}"; TIMEOUT="${3:-3}"
    [ -n "$PORT" ] || { jq -n '{"error":"port required"}'; exit 1; }
    if curl -sf --max-time "$TIMEOUT" -o /dev/null "http://$HOST:$PORT/"; then
      jq -n --arg host "$HOST" --argjson port "$PORT" '{healthy:true, host:$host, port:$port}'
      exit 0
    else
      # A non-2xx/3xx response (e.g. 401/403 behind an auth gate, or 404) still
      # proves *something* is listening -- distinguish "nothing there" from
      # "something answered but not with success" via a raw TCP connect check.
      if curl -s --max-time "$TIMEOUT" -o /dev/null -w '%{http_code}' "http://$HOST:$PORT/" 2>/dev/null | grep -qE '^[1-9][0-9]{2}$'; then
        jq -n --arg host "$HOST" --argjson port "$PORT" '{healthy:true, host:$host, port:$port, note:"non-2xx/3xx response but something is listening"}'
        exit 0
      fi
      jq -n --arg host "$HOST" --argjson port "$PORT" '{healthy:false, host:$host, port:$port}'
      exit 1
    fi
    ;;

  start)
    CWD="${1:-}"; COMMAND="${2:-}"; PID_FILE="${3:-}"; LOG_FILE="${4:-}"
    if [ -z "$CWD" ] || [ -z "$COMMAND" ] || [ -z "$PID_FILE" ] || [ -z "$LOG_FILE" ]; then
      jq -n '{"error":"start requires: cwd command pid_file log_file"}'
      exit 1
    fi
    [ -d "$CWD" ] || { jq -n --arg cwd "$CWD" '{"error":"cwd is not a directory", "cwd":$cwd}'; exit 1; }
    : > "$LOG_FILE"
    rm -f "$PID_FILE"
    (
      cd "$CWD" || exit 127
      # `set -m` turns on job control in this subshell, which makes the
      # backgrounded job its own process group leader (PGID == its own PID)
      # instead of inheriting the parent shell's PGID. That's what lets
      # `stop`'s `kill -TERM -<pgid>` actually reach the whole tree (many
      # dev-server CLIs spawn a further child process, e.g. a bundler worker).
      set -m
      nohup sh -c "$COMMAND" >"$LOG_FILE" 2>&1 &
      echo $! > "$PID_FILE"
    ) &
    disown
    # Wait briefly for the PID file to actually appear before reporting.
    DEADLINE=$((SECONDS + 5))
    while [ ! -s "$PID_FILE" ] && [ "$SECONDS" -lt "$DEADLINE" ]; do
      sleep 0.2
    done
    if [ ! -s "$PID_FILE" ]; then
      jq -n '{"error":"pid file never appeared after start"}'
      exit 1
    fi
    PID="$(cat "$PID_FILE")"
    sleep 0.3
    if kill -0 "$PID" 2>/dev/null; then
      # Bind this PID's identity by also recording its process start time, so
      # `stop` can later refuse to signal a *different* process that happens
      # to have reused the same PID (or a tampered/corrupted PID file).
      START_TIME="$(ps -o lstart= -p "$PID" 2>/dev/null | sed -E 's/^ +//; s/ +$//')"
      if [ -z "$START_TIME" ]; then
        # Narrow race: kill -0 saw it alive, but it may have exited before ps
        # ran. Retry once -- this is a timing race, not a permanent condition.
        sleep 0.2
        START_TIME="$(ps -o lstart= -p "$PID" 2>/dev/null | sed -E 's/^ +//; s/ +$//')"
      fi
      if [ -n "$START_TIME" ]; then
        printf '%s\nT %s\n' "$PID" "$START_TIME" > "$PID_FILE"
        jq -n --argjson pid "$PID" --arg pid_file "$PID_FILE" --arg log_file "$LOG_FILE" \
          '{started:true, pid:$pid, pid_file:$pid_file, log_file:$log_file}'
        exit 0
      fi
      # No fingerprint could be obtained at all (lstart unavailable even after
      # retry). By now 0.3s-0.5s have elapsed since the last confirmed-alive
      # check, so the process may have already exited and had its PID number
      # reused by something unrelated. Only ever signal this PID's own process
      # group (set up via `set -m` above) -- never fall back to a bare-PID
      # kill, since a bare PID here could hit a totally different process.
      # If the group signal fails, there's nothing (of ours) left to signal.
      rm -f "$PID_FILE"
      # Immediate pre-signal re-check, with no sleep or `ps` call between it
      # and the signal below -- shrinks the TOCTOU window (time between
      # "last confirmed alive" and "signal sent") to a single kill -0
      # syscall, the theoretical floor for any PID/PGID-signaling design.
      # This can't be eliminated to literally zero (every such design --
      # this script's own `stop` mode included, and every real-world process
      # supervisor) has some nonzero check-to-signal gap; this is the minimum
      # achievable, and the residual is accepted as inherent, not chased
      # further. If it's already gone, there's nothing of ours left to
      # signal -- report the same failure as the sibling "exited immediately"
      # branch below instead of signaling a possibly-reused PID.
      if ! kill -0 "$PID" 2>/dev/null; then
        jq -n --argjson pid "$PID" --arg log_file "$LOG_FILE" \
          '{started:false, pid:$pid, log_file:$log_file, detail:"process exited immediately after start"}'
        exit 1
      fi
      kill -TERM -- "-$PID" 2>/dev/null
      for _ in 1 2 3 4 5; do
        kill -0 -- "-$PID" 2>/dev/null || break
        sleep 1
      done
      if kill -0 -- "-$PID" 2>/dev/null; then
        kill -KILL -- "-$PID" 2>/dev/null
      fi
      jq -n --argjson pid "$PID" --arg log_file "$LOG_FILE" \
        '{started:false, pid:$pid, log_file:$log_file, detail:"could not establish a reliable process identity fingerprint (ps -o lstart= unavailable after retry); the process was terminated rather than left running unmanageable"}'
      exit 1
    fi
    jq -n --argjson pid "$PID" --arg log_file "$LOG_FILE" \
      '{started:false, pid:$pid, log_file:$log_file, detail:"process exited immediately after start"}'
    exit 1
    ;;

  wait-healthy)
    HOST_PORT_HOST="${1:-127.0.0.1}"; HOST_PORT_PORT="${2:-}"; TIMEOUT="${3:-60}"; LOG_FILE="${4:-}"
    [ -n "$HOST_PORT_PORT" ] || { jq -n '{"error":"port required"}'; exit 1; }
    DEADLINE=$((SECONDS + TIMEOUT))
    while [ "$SECONDS" -lt "$DEADLINE" ]; do
      if curl -s --max-time 2 -o /dev/null -w '%{http_code}' "http://$HOST_PORT_HOST:$HOST_PORT_PORT/" 2>/dev/null | grep -qE '^[1-9][0-9]{2}$'; then
        jq -n --arg host "$HOST_PORT_HOST" --argjson port "$HOST_PORT_PORT" '{healthy:true, host:$host, port:$port}'
        exit 0
      fi
      sleep 1
    done
    TAIL="null"
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
      TAIL="$(tail -n 30 "$LOG_FILE" 2>/dev/null | jq -Rs .)"
    fi
    jq -n --arg host "$HOST_PORT_HOST" --argjson port "$HOST_PORT_PORT" --argjson timeout "$TIMEOUT" --argjson log_tail "$TAIL" \
      '{healthy:false, host:$host, port:$port, timeout_secs:$timeout, log_tail:$log_tail}'
    exit 1
    ;;

  stop)
    PID_FILE="${1:-}"
    [ -n "$PID_FILE" ] || { jq -n '{"error":"stop requires pid_file"}'; exit 1; }
    if [ ! -f "$PID_FILE" ]; then
      jq -n --arg pid_file "$PID_FILE" '{stopped:"not_applicable", detail:"no pid file", pid_file:$pid_file}'
      exit 0
    fi
    PID="$(sed -n '1p' "$PID_FILE" 2>/dev/null)"
    FINGERPRINT_LINE="$(sed -n '2p' "$PID_FILE" 2>/dev/null)"
    if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
      rm -f "$PID_FILE"
      jq -n --argjson pid "${PID:-null}" '{stopped:"not_applicable", detail:"process already gone", pid:$pid}'
      exit 0
    fi
    # Refuse to signal a PID whose current identity doesn't match what
    # `start` recorded -- protects against PID reuse (the original process
    # exited and the OS handed the number to something unrelated) or a
    # corrupted/tampered PID file. Never trust a bare PID number alone.
    #
    # A successful `start` always writes a "T <lstart>" second line (start
    # self-terminates and reports failure instead if it couldn't obtain one --
    # see `start` above) -- any other second line means a malformed, tampered,
    # or legacy-format PID file, so this default branch is unreachable via any
    # actual `start` success path but stays fail-closed defensively.
    case "$FINGERPRINT_LINE" in
      "T "*)
        RECORDED="${FINGERPRINT_LINE#T }"
        CURRENT="$(ps -o lstart= -p "$PID" 2>/dev/null | sed -E 's/^ +//; s/ +$//')"
        ;;
      *)
        RECORDED=""
        CURRENT="__no_fingerprint_available__"
        ;;
    esac
    if [ -z "$RECORDED" ] || [ "$CURRENT" != "$RECORDED" ]; then
      rm -f "$PID_FILE"
      jq -n --argjson pid "$PID" '{stopped:"not_applicable", detail:"pid recycled, file corrupted, or no fingerprint available", pid:$pid}'
      exit 0
    fi
    # Kill only this recorded PID's own process group -- never re-derive by
    # port. TERM first, brief grace period, then KILL if still alive.
    kill -TERM -- "-$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null
    for _ in 1 2 3 4 5; do
      kill -0 -- "-$PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 -- "-$PID" 2>/dev/null; then
      kill -KILL -- "-$PID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null
      sleep 1
    fi
    rm -f "$PID_FILE"
    if kill -0 -- "-$PID" 2>/dev/null; then
      jq -n --argjson pid "$PID" '{stopped:false, pid:$pid, detail:"process still alive after TERM and KILL"}'
      exit 1
    fi
    jq -n --argjson pid "$PID" '{stopped:true, pid:$pid}'
    exit 0
    ;;

  *)
    usage
    exit 1
    ;;
esac
