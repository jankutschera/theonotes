#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 True Brew Birdie Ltd. and Theo Notes contributors

# Network trace for the M10 privacy audit (docs/release/privacy-audit.md).
#
#   net-trace.sh cli <theonotes> <out-dir> [bear-oracle]
#       Headless. Runs a scripted workload of the command-line tool and the MCP server against a
#       throw-away library, once with the network denied by the macOS sandbox (every command must
#       still succeed) and once as a positive control (the one command that is meant to connect,
#       `attachments add-url`, must connect when allowed and fail when denied). The command-line tool
#       never creates a library, so the optional `bear-oracle` binary is used once, offline, to create
#       the empty schema (`--bearcli /usr/bin/false`: Bear is never read).
#   net-trace.sh app <Theo Notes.app> <out-dir> [seconds]
#       Opens windows: run it only while nobody uses the Mac. Starts the app on a throw-away library,
#       samples its sockets every 2 s for `seconds` (default 600), and keeps the unified-log lines of
#       CFNetwork for the app and for WebKit's networking process (sockets alone miss short requests).
#       The GUI part of the workload (import a Markdown folder, export, lock a note, voice note,
#       reminder, share extension) is done by a person or a computer-use session during the window.
#
# Never touches a real library: both modes use a fresh temporary folder (--data-dir). Never kills by
# name: the only process ended is the PID this script started.
set -u

mode="${1:-}"; subject="${2:-}"; out="${3:-}"; seconds="${4:-600}"; seedtool="${4:-}"
if [ -z "$mode" ] || [ -z "$subject" ] || [ -z "$out" ]; then sed -n 2,23p "$0"; exit 64; fi
mkdir -p "$out" || exit 1
out="$(cd "$out" && pwd)"
lib="$(mktemp -d /tmp/theonotes-trace.XXXXXX)"
cleanup() { rm -rf "$lib" "${tooldir:-}"; }
trap cleanup EXIT

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
deny_network='(version 1)(allow default)(deny network*)'

run_cli() { # label, then the command line; stdin passes through
  local label="$1"; shift
  local status
  "$@" >"$out/cli-$label.out" 2>"$out/cli-$label.err"; status=$?
  echo "$(stamp) rc=$status $label" >>"$out/cli-workload.log"
  return $status
}

localtime() { date '+%Y-%m-%d %H:%M:%S'; }

# Primary record: the macOS sandbox reports every denied network attempt of a process it was applied to
# ("Sandbox: <name>(<pid>) deny(1) network-outbound ..."), whatever its duration. Socket sampling
# (lsof, nettop) is secondary: the positive control below showed it misses a request that is over in
# 150 ms. The process name is the first 16 characters of the executable name; the window is local time.
denials() { # process, start, end, file
  /usr/bin/log show --start "$2" --end "$3" --style compact \
    --predicate "eventMessage CONTAINS \"Sandbox: $1(\" AND eventMessage CONTAINS \"deny(1) network\"" >"$4" 2>&1
}
count_denials() { grep -c 'deny(1) network' "$1"; }
# Context only: CFNetwork's own lines for a process (not reliably persisted under heavy load).
unified_log() { # process, start, end, file
  /usr/bin/log show --info --start "$2" --end "$3" --style compact \
    --predicate "process == \"$1\" AND subsystem == \"com.apple.CFNetwork\"" >"$4" 2>&1
}
log_tasks() { grep -c 'Task <.*> resuming' "$1"; }

cli_mode() {
  local original="$subject" failed=0 bin
  # A copy under a name nothing else on this Mac has, so the log lines are ours alone.
  local tool="tn-t2trace"
  tooldir="$(mktemp -d /tmp/theonotes-trace-bin.XXXXXX)"
  cp "$original" "$tooldir/$tool"; bin="$tooldir/$tool"
  : >"$out/cli-workload.log"
  {
    echo "binary:   $original (run as a copy named $tool)"
    echo "sha256:   $(shasum -a 256 "$original" | cut -d' ' -f1)"
    echo "mtime:    $(stat -f %Sm -t %Y-%m-%dT%H:%M:%S "$original")"
    echo "version:  $("$bin" --version 2>&1 | head -1)"
    echo "macOS:    $(sw_vers -productVersion) $(uname -m)"
    echo "started:  $(stamp)"
    echo "load:     $(uptime | sed 's/.*load averages*: //')"
    echo "library:  throw-away (removed on exit)"
  } >"$out/cli-environment.txt"

  if [ -n "$seedtool" ]; then
    "$seedtool" --import-check --data-dir "$lib" --bearcli /usr/bin/false >"$out/cli-seed.log" 2>&1
  fi
  [ -f "$lib/Baerchen.sqlite" ] || { echo "no library to run on (see the usage text)"; return 1; }
  export THEONOTES_DATA_DIR="$lib"
  local sx=(sandbox-exec -p "$deny_network")

  local t_start t_denied_end t_control_start t_control_end t_end
  t_start="$(localtime)"
  # 1. Full workload with the network denied: every step has to succeed.
  step() { # label, stdin text, command...
    local label="$1" text="$2"; shift 2
    if ! printf '%s' "$text" | run_cli "$label" "${sx[@]}" "$bin" "$@"; then failed=$((failed + 1)); fi
  }
  step create-a $'# Alpha note\n\nFirst note #trace/one\n- [ ] a task\n' create --format json
  step create-b $'# Beta note\n\nSecond note with [[Alpha note]] and a link https://example.com/page\n' create --format json
  step create-c $'# Gamma\n\nThird note #trace/two\n' create --format json
  step list "" list --format json --fields all
  step search "" search "Alpha" --format json
  step search-tag "" search "#trace" --format json
  step tags "" tags list --format json
  step cat "" cat --title "Alpha note"
  step show "" show --title "Alpha note" --format json --fields all
  step outline "" outline --title "Alpha note"
  step append $'\nappended line\n' append --title "Beta note"
  step attach-add $'not really a png, just bytes\n' attachments add --title "Gamma" --filename trace.png
  step attach-list "" attachments list --title "Gamma" --format json
  step attach-save "" attachments save --title "Gamma" --filename trace.png
  step pin "" pin add --title "Alpha note" global
  step list-ids "" list --format json --fields id,title
  local gamma
  gamma="$(python3 -I -c 'import json,sys; print(next(n["id"] for n in json.load(open(sys.argv[1])) if n["title"]=="Gamma"))' "$out/cli-list-ids.out")"
  step archive "" archive "$gamma"
  step restore "" restore "$gamma"
  step trash "" trash "$gamma"

  # 2. MCP server session (stdin closes after the last request, the server then exits).
  mcp_requests() {
    printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"net-trace","version":"1"}}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"Alpha"}}}'
  }
  if ! mcp_requests | run_cli mcp-session "${sx[@]}" "$bin" mcp-server; then failed=$((failed + 1)); fi
  grep -q '"id":3' "$out/cli-mcp-session.out" || { echo "MCP search call got no answer" >>"$out/cli-workload.log"; failed=$((failed + 1)); }

  # 3. Positive control for the method. The MCP tool `add_attachment_from_url` is the one core path that
  #    opens a connection (a plain GET of https://example.com/, IANA's reserved demo host). Allowed: the
  #    server stays alive for 10 s after the fetch; `nettop -P` keeps cumulative bytes per process, so it
  #    must show traffic after the socket is closed (lsof only sees a socket while it is open and can
  #    miss it). Denied: the same call must fail.
  t_denied_end="$(localtime)"
  printf '%s' $'# Control\n' | "${sx[@]}" "$bin" create >/dev/null 2>&1
  t_control_start="$(localtime)"
  cat >"$out/control-requests.jsonl" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"net-trace","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"add_attachment_from_url","arguments":{"title":"Control","url":"https://example.com/","filename":"control.html"}}}
JSON
  ( cat "$out/control-requests.jsonl"; sleep 10 ) | "$bin" mcp-server >"$out/control-allowed.out" 2>"$out/control-allowed.err" &
  local pid=$! n
  : >"$out/control-allowed.sockets"; : >"$out/control-allowed.nettop"
  for n in 1 2 3 4 5 6 7 8; do
    { echo "# $(stamp)"; lsof -nP -i -a -p "$pid" 2>/dev/null; } >>"$out/control-allowed.sockets"
    { echo "# $(stamp)"; nettop -P -x -m tcp -m udp -J bytes_in,bytes_out -L 1 -p "$pid" 2>&1; } >>"$out/control-allowed.nettop"
    sleep 1
  done
  wait "$pid"
  t_control_end="$(localtime)"
  echo "$(stamp) control-allowed done (sampled pid $pid)" >>"$out/cli-workload.log"
  ( cat "$out/control-requests.jsonl"; sleep 2 ) | "${sx[@]}" "$bin" mcp-server >"$out/control-denied.out" 2>"$out/control-denied.err"
  echo "$(stamp) control-denied done (the fetch must have failed)" >>"$out/cli-workload.log"
  t_end="$(localtime)"

  # Sandbox denial reports, three windows: the workload, the allowed control, the denied control.
  sleep 3
  denials "$tool" "$t_start" "$t_denied_end" "$out/sandbox-denials-workload.txt"
  denials "$tool" "$t_control_start" "$t_control_end" "$out/sandbox-denials-control-allowed.txt"
  denials "$tool" "$t_control_end" "$t_end" "$out/sandbox-denials-control-denied.txt"
  unified_log "$tool" "$t_control_start" "$t_control_end" "$out/unified-log-control-allowed.txt"

  {
    echo "workload steps failed under denied network: $failed (expected 0)"
    echo "sandbox-reported network attempts: workload $(count_denials "$out/sandbox-denials-workload.txt") (expected 0), control allowed $(count_denials "$out/sandbox-denials-control-allowed.txt") (expected 0, it was not sandboxed), control denied $(count_denials "$out/sandbox-denials-control-denied.txt") (expected 1 or more)"
    echo "CFNetwork lines for the allowed control (context, not persisted reliably): $(log_tasks "$out/unified-log-control-allowed.txt") task(s)"
    echo "control allowed: tool answer: $(grep -o '"id":2.\{0,160\}' "$out/control-allowed.out" | head -1)"
    echo "control allowed: lsof socket lines: $(grep -vc '^#' "$out/control-allowed.sockets"), nettop data rows: $(grep -v '^#' "$out/control-allowed.nettop" | grep -vc bytes_in)"
    echo "control denied:  tool answer: $(grep -o '"id":2.\{0,200\}' "$out/control-denied.out" | head -1)"
  } | tee "$out/cli-summary.txt"
  [ "$failed" -eq 0 ]
}

app_mode() {
  local app="$subject" exe pid=""
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")" || exit 1
  [ -z "$(pgrep -x "$exe" 2>/dev/null)" ] || echo "note: another '$exe' is running; samples are keyed to the PID started here only"
  {
    echo "app:      $app"
    echo "version:  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist"))"
    echo "sync key: $(/usr/libexec/PlistBuddy -c 'Print :THEONOTES_SyncSetupAvailable' "$app/Contents/Info.plist" 2>/dev/null || echo absent)"
    echo "macOS:    $(sw_vers -productVersion) $(uname -m)"
    echo "started:  $(stamp)   duration: ${seconds}s"
    echo "load:     $(uptime | sed 's/.*load averages*: //')"
  } >"$out/app-environment.txt"
  # The app process runs inside a profile that denies its own outbound network and DNS lookups, and the
  # sandbox reports every attempt. Web views use WebKit's separate networking process, which this does
  # not cover (see the WebKit lines below and the CSP/navigation tests).
  local profile='(version 1)(allow default)(deny network-outbound (remote ip))(deny network-outbound (literal "/private/var/run/mDNSResponder"))'
  sandbox-exec -p "$profile" "$app/Contents/MacOS/$exe" --data-dir "$lib" >"$out/app-stdout.log" 2>&1 &
  pid=$!
  echo "app pid $pid; do the GUI workload now (see docs/release/privacy-audit.md, section 4)"
  local end=$((SECONDS + seconds)) t_start t_end
  t_start="$(localtime)"
  : >"$out/app-sockets.log"; : >"$out/app-nettop.log"; : >"$out/app-webkit-networking.log"
  while [ $SECONDS -lt $end ] && kill -0 "$pid" 2>/dev/null; do
    { echo "# $(stamp)"; lsof -nP -i -a -p "$pid" 2>/dev/null; } >>"$out/app-sockets.log"
    { echo "# $(stamp)"; nettop -P -x -m tcp -m udp -J bytes_in,bytes_out -L 1 -p "$pid" 2>&1; } >>"$out/app-nettop.log"
    # WKWebView requests go through WebKit's own networking process, not the app's PID: log its rows
    # for correlation by time (other apps share the name, so this is context, not proof).
    { echo "# $(stamp)"; nettop -P -x -m tcp -m udp -J bytes_in,bytes_out -L 1 2>/dev/null | grep -i 'WebKit.Networking'; } >>"$out/app-webkit-networking.log"
    sleep 2
  done
  kill -0 "$pid" 2>/dev/null && kill "$pid"
  wait "$pid" 2>/dev/null
  t_end="$(localtime)"
  # Sockets are sampled every 2 s and miss a request that is over in 150 ms (the CLI control showed
  # it), so the sandbox denial reports are the primary record of the app process.
  sleep 3
  denials "$exe" "$t_start" "$t_end" "$out/sandbox-denials-app.txt"
  unified_log "$exe" "$t_start" "$t_end" "$out/unified-log-app.txt"
  unified_log "com.apple.WebKit.Networking" "$t_start" "$t_end" "$out/unified-log-webkit-networking.txt"
  {
    echo "samples:               $(grep -c '^# ' "$out/app-sockets.log")"
    echo "sandbox-reported attempts of the app process: $(count_denials "$out/sandbox-denials-app.txt") (expected 0)"
    echo "inet socket lines:     $(grep -vc '^#' "$out/app-sockets.log") (expected 0)"
    echo "nettop data rows:      $(grep -v '^#' "$out/app-nettop.log" | grep -vc 'bytes_in') (expected 0)"
    echo "CFNetwork tasks of the app (context): $(log_tasks "$out/unified-log-app.txt") (expected 0)"
    echo "WebKit networking tasks in the window: $(log_tasks "$out/unified-log-webkit-networking.txt") (context: other apps share this process)"
  } | tee "$out/app-summary.txt"
}

case "$mode" in
  cli) cli_mode ;;
  app) app_mode ;;
  *) sed -n 2,23p "$0"; exit 64 ;;
esac
