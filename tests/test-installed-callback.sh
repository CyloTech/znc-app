#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3; no Docker):
#   - appbox-installed-callback retries network errors, 408, 429 and 5xx,
#     stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token, passes an optional JSON body, and never logs the
#     callback token carried in INSTANCE_ID;
#   - scripts/entrypoint.sh starts ZNC straight away even when the API rejects
#     the callback, sends a pending callback once in the background, clears
#     the pending flag, and sends nothing on a plain restart. The run uses the
#     update path (existing znc.conf and dh.pem in a scratch /znc-data), so no
#     password hashing or dhparam generation runs.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
znc_password='gatepassword0123456789'
header_token='headertoken0123456789'

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken|gatepassword' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 3
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# An invalid APPBOX_CALLBACK_RETRY_DELAY falls back to the 5s default.
start_mock 503,200
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY='1;x' "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'retrying in 5s' "${work}/output" && [[ "$(request_count)" == 2 ]]; then
    pass "helper ignores an invalid retry delay"
else
    fail "helper invalid retry delay exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock

# --- start path ------------------------------------------------------------------

# sandbox_start_script (defined per repo below) writes a copy of the start
# script to $1 with its paths pointed into ${work}, any hard-coded API URL
# pointed at the mock, and its final exec replaced by `exec "$@"`.
# entrypoint_case runs that copy with a fake app as "$@" that records when it
# started, waits for the background callback to finish and checks that:
#   - the app started within 5s whatever the API answered (a blocking
#     callback never lets it start; 5s leaves room for a busy builder);
#   - the API saw exactly <want_requests> POSTs;
#   - the pending flag (${work}/callback_pending) is gone and no token
#     reached the output.
# Usage: entrypoint_case <label> <codes> <want_requests> <setup function> [VAR=value...]
entrypoint_case() {
    local label=$1 codes=$2 want_requests=$3 setup=$4
    shift 4
    start_mock "${codes}"
    local sandbox="${work}/start-script"
    sandbox_start_script "${sandbox}"
    chmod +x "${sandbox}"
    if ! grep -q '^ *exec "\$@"$' "${sandbox}"; then
        fail "${label}: could not sandbox the start script"
        stop_mock
        return
    fi
    "${setup}"

    local started_at app_at entrypoint_pid waited=0
    started_at=$(date +%s)
    env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 ZNCPASS="${znc_password}" "$@" \
        "${sandbox}" bash -c "date +%s >'${work}/app_started'; sleep 1" \
        >"${work}/output" 2>&1 &
    entrypoint_pid=$!

    # A callback that blocks startup never reaches the app; give up after 10s.
    while [[ ! -f "${work}/app_started" && "${waited}" -lt 10 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if [[ ! -f "${work}/app_started" ]]; then
        pkill -P "${entrypoint_pid}" 2>/dev/null
        kill "${entrypoint_pid}" 2>/dev/null
    fi
    wait "${entrypoint_pid}" 2>/dev/null

    # The background sender outlives the fake app; wait for it to finish.
    waited=0
    while [[ -f "${work}/callback_pending" && "${waited}" -lt 20 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    sleep 0.5

    app_at=$(cat "${work}/app_started" 2>/dev/null || echo 0)
    local requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${app_at}" -gt 0 && $((app_at - started_at)) -le 5 && ! -f "${work}/callback_pending" \
        && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "${label} codes=${codes}: app started after $((app_at - started_at))s, requests=${requests}"
    else
        fail "${label} codes=${codes}: app_started=${app_at} start=${started_at} pending=$([[ -f "${work}/callback_pending" ]] && echo yes || echo no) requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

sandbox_start_script() {
    local sed_cmd=sed
    command -v gsed >/dev/null && sed_cmd=gsed   # the script uses GNU sed -i
    sed -e "s|/znc-data|${work}/znc-data|g" \
        -e "s|/root/|${work}/root/|g" \
        -e "s|/etc/app_configured|${work}/app_configured|g" \
        -e "s|mv /znc.conf |mv ${work}/znc.conf |" \
        -e "s|/etc/appbox_callback_pending|${work}/callback_pending|g" \
        -e "s|/usr/local/bin/appbox-installed-callback|${helper}|g" \
        -e "s|https://api\.cylo\.[a-z]*|http://127.0.0.1:${port}|g" \
        -e "s|^\( *\)sed -i|\1${sed_cmd} -i|" \
        -e 's|^ *chown -R znc:znc .*|true|' \
        -e 's|^/bin/su -s /bin/bash -c "znc .*|exec "$@"|' \
        "${repo_root}/scripts/entrypoint.sh" >"$1"
}

# Update/migration: the persistent config and dh.pem already exist.
update() {
    mkdir -p "${work}/znc-data/configs"
    printf '<Listener l>\n\tPort = 6667\n\tSSL = false\n</Listener>\n' >"${work}/znc-data/configs/znc.conf"
    touch "${work}/znc-data/dh.pem"
}
restart_pending() { update; touch "${work}/app_configured" "${work}/callback_pending"; }
restart() { update; touch "${work}/app_configured"; }

entrypoint_case "entrypoint.sh first boot" 200 1 update
entrypoint_case "entrypoint.sh first boot" 401 1 update
entrypoint_case "entrypoint.sh SKIP_APPBOX_CALLBACK=1" 200 0 update SKIP_APPBOX_CALLBACK=1
entrypoint_case "entrypoint.sh restart-pending" 503,200 2 restart_pending
entrypoint_case "entrypoint.sh restart" 200 0 restart

# Without ZNCPASS the first start stops before setting anything up: ZNC does
# not start, nothing is sent and neither marker is written.
refused_case() {
    local label=$1
    shift
    start_mock 200
    local sandbox="${work}/start-script"
    sandbox_start_script "${sandbox}"
    chmod +x "${sandbox}"
    update
    run_limited 10 env -u ZNCPASS INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" "$@" \
        "${sandbox}" bash -c "date +%s >'${work}/app_started'" >"${work}/output" 2>&1
    local rc=$?
    sleep 1
    if [[ "${rc}" != 0 && "${rc}" != 124 && ! -f "${work}/app_started" && ! -f "${work}/callback_pending" \
        && ! -f "${work}/app_configured" && "$(request_count)" == 0 ]] \
        && grep -q 'refusing to set up ZNC' "${work}/output"; then
        pass "${label}: exit ${rc}, ZNC not started, no callback"
    else
        fail "${label}: exit=${rc} app_started=$([[ -f "${work}/app_started" ]] && echo yes || echo no) requests=$(request_count)"
    fi
    stop_mock
}
# Fresh install: the template gets the install user, the port and a hash
# ZNC accepts for its sha256 method, sha256(password + salt) with a 20
# character salt, and the password is not printed.
fresh_case() {
    start_mock 200
    local sandbox="${work}/start-script"
    sandbox_start_script "${sandbox}"
    chmod +x "${sandbox}"
    mkdir -p "${work}/znc-data/configs"
    cp "${repo_root}/sources/znc.conf" "${work}/znc.conf"
    touch "${work}/znc-data/dh.pem"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" APPBOX_CALLBACK_RETRY_DELAY=1 \
        USERNAME=gateuser ZNCPORT=6697 ZNCPASS="${znc_password}" \
        "${sandbox}" true >"${work}/output" 2>&1
    local rc=$? conf="${work}/znc-data/configs/znc.conf" salt hash want
    salt=$(awk '$1 == "Salt" {print $3}' "${conf}" 2>/dev/null)
    hash=$(awk '$1 == "Hash" {print $3}' "${conf}" 2>/dev/null)
    want=$(printf '%s%s' "${znc_password}" "${salt}" \
        | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')
    if [[ "${rc}" == 0 && "${#salt}" == 20 && "${hash}" == "${want}" && "$(token_logged)" == 0 ]] \
        && grep -q '^<User gateuser>' "${conf}" && grep -q 'Port = 6697' "${conf}"; then
        pass "entrypoint.sh fresh install writes a sha256(password + salt) hash"
    else
        fail "entrypoint.sh fresh install: exit=${rc} salt_length=${#salt} hash_ok=$([[ "${hash}" == "${want}" ]] && echo yes || echo no)"
    fi
    stop_mock
}
for _ in 1 2 3; do fresh_case; done

refused_case "entrypoint.sh without ZNCPASS"
refused_case "entrypoint.sh with empty ZNCPASS" ZNCPASS=

if grep -qE '^[[:space:]]*set -[a-z]*x' "${repo_root}/scripts/entrypoint.sh"; then
    fail "entrypoint.sh traces its commands (set -x)"
else
    pass "entrypoint.sh does not trace its commands"
fi

if grep -q 'apps/installed' "${repo_root}/scripts/entrypoint.sh"; then
    fail "entrypoint.sh still calls the installed callback itself"
else
    pass "entrypoint.sh only marks the callback pending and hands it to the helper"
fi

# First boot sets the pending flag before the configured marker, so a crash
# between the two cannot lose the callback.
# Usage: flag_before_marker <label> <marker path> < script
flag_before_marker() {
    local label=$1 marker=$2 text flag_line marker_line
    text=$(cat)
    flag_line=$(grep -n 'touch [^ ]*appbox_callback_pending' <<<"${text}" | head -1 | cut -d: -f1)
    marker_line=$(grep -n "touch ${marker}\$" <<<"${text}" | head -1 | cut -d: -f1)
    if [[ -n "${flag_line}" && -n "${marker_line}" && "${flag_line}" -lt "${marker_line}" ]]; then
        pass "${label} sets the pending flag before ${marker}"
    else
        fail "${label}: pending flag line ${flag_line:-none}, ${marker} line ${marker_line:-none}"
    fi
}
flag_before_marker "entrypoint.sh" /etc/app_configured <"${repo_root}/scripts/entrypoint.sh"

exit "${failures}"
