#!/usr/bin/env python3
"""Release gate for repo.cylo.net/znc:1.8.2-1. Run it on the builder.

Usage: release/release-gate.py repo.cylo.net/znc:1.8.2-1

Exits 0 only when the exact local image passes every check below and the
authenticated registry reports the tag definitively absent:

- tests/test-installed-callback.sh (callback helper and sandboxed entrypoint);
- image: no ZNCPASS in its configuration, no changepassword.sh, the committed
  entrypoint and callback helper, ZNC 1.8.2;
- missing or empty ZNCPASS: the container exits non-zero, sends no installed
  callback and writes no ZNC config;
- fresh install with a dummy password: IRC login over TLS with it, a wrong
  password is refused, webadmin answers, ZNC runs as UID 1000, one installed
  callback with the token header, and the password is in neither the
  container log nor /znc-data;
- restart: same password hash, login still works, no second callback;
- upgrade from znc:latest on the same volume: the existing user's password
  hash and settings are kept and its password still works, one callback,
  nothing traced into the log.

The installed callback goes to a local HTTPS mock that answers as
api.cylo.io/api.cylo.net on a private Docker network; the containers trust a
throwaway CA added to their CA bundle. Nothing is sent to the real API.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

spec = importlib.util.spec_from_file_location('registry_check', Path(__file__).with_name('registry-check.py'))
registry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(registry)
if len(sys.argv) != 2 or sys.argv[1] != registry.EXPECTED:
    raise SystemExit('Usage: release-gate.py ' + registry.EXPECTED)
image = sys.argv[1]
repo_root = Path(__file__).resolve().parent.parent
run_id = 'znc-gate-' + uuid.uuid4().hex[:10]
work = Path(tempfile.mkdtemp(prefix=run_id + '-'))
label = 'appbox.release-gate=' + run_id
network = run_id + '-net'
containers = []
volumes = []
networks = []
# Dummy install values (the form only allows letters and digits).
user = 'gateuser'
password = 'gate' + secrets.token_hex(8)
upgrade_password = 'gate' + secrets.token_hex(8)
callback_token = 'gatetoken' + secrets.token_hex(12)
secret_values = (password, upgrade_password, callback_token)
instance_id = '900000081'
irc_port = '46667'

MOCK = r'''
import http.server, json, ssl
class Handler(http.server.BaseHTTPRequestHandler):
    def handle_one(self, method):
        length = int(self.headers.get('Content-Length') or 0)
        if length:
            self.rfile.read(length)
        print(json.dumps({'method': method, 'host': self.headers.get('Host'), 'path': self.path,
                          'token': self.headers.get('X-Cylo-Callback-Token')}), flush=True)
        ok = method == 'POST' and self.path.startswith('/v1/apps/installed/')
        body = b'{"status":"success"}' if ok else b'{}'
        self.send_response(200 if ok else 404)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        self.handle_one('POST')
    def do_GET(self):
        self.handle_one('GET')
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('0.0.0.0', 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain('/mock/server.crt', '/mock/server.key')
server.socket = context.wrap_socket(server.socket, server_side=True)
print('READY', flush=True)
server.serve_forever()
'''


def redact(text):
    for value in secret_values:
        text = text.replace(value, '[redacted]')
    return text


def command(args, timeout=300, check=True):
    p = subprocess.run(args, capture_output=True, timeout=timeout)
    if check and p.returncode:
        # Never print the arguments: they carry the dummy passwords.
        raise RuntimeError('Builder command failed: ' + redact(p.stderr.decode(errors='replace')[-1500:]))
    return p


def out(args, timeout=300):
    return command(args, timeout).stdout.decode()


def logs(name):
    p = command(['docker', 'logs', name], check=False)
    return p.stdout.decode(errors='replace') + p.stderr.decode(errors='replace')


def show_logs(name):
    print('--- last log lines of ' + name, flush=True)
    print(redact(logs(name))[-4000:], flush=True)


def make_tls():
    mock = work / 'mock'
    mock.mkdir()
    (mock / 'mock.py').write_text(MOCK)
    (work / 'ext.cnf').write_text('subjectAltName=DNS:api.cylo.io,DNS:api.cylo.net\nextendedKeyUsage=serverAuth\n')
    command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
             '-keyout', str(work / 'ca.key'), '-out', str(work / 'ca.crt'), '-subj', '/CN=' + run_id + ' CA',
             '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign'])
    command(['openssl', 'req', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(mock / 'server.key'),
             '-out', str(work / 'server.csr'), '-subj', '/CN=api.cylo.io'])
    command(['openssl', 'x509', '-req', '-in', str(work / 'server.csr'), '-CA', str(work / 'ca.crt'),
             '-CAkey', str(work / 'ca.key'), '-CAcreateserial', '-days', '2',
             '-extfile', str(work / 'ext.cnf'), '-out', str(mock / 'server.crt')])
    bundle = out(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'cat', image,
                  '/etc/ssl/certs/ca-certificates.crt'])
    (work / 'ca-bundle.crt').write_text(bundle + (work / 'ca.crt').read_text())
    # Stands in for the host's wildcard certificate that Appbox binds in.
    command(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
             '-keyout', str(work / 'znc-key.pem'), '-out', str(work / 'znc-cert.pem'), '-subj', '/CN=znc.gate.test'])
    for path in [work, mock] + list(mock.iterdir()) + [work / 'ca-bundle.crt', work / 'znc-key.pem', work / 'znc-cert.pem']:
        os.chmod(path, 0o755 if path.is_dir() else 0o644)


def start_mock():
    command(['docker', 'network', 'create', '--label', label, network])
    networks.append(network)
    name = run_id + '-mock'
    command(['docker', 'run', '-d', '--name', name, '--label', label, '--network', network,
             '--network-alias', 'api.cylo.io', '--network-alias', 'api.cylo.net',
             '-v', str(work / 'mock') + ':/mock:ro', '--entrypoint', 'python3', registry.CURRENT, '/mock/mock.py'])
    containers.append(name)
    for _ in range(60):
        if 'READY' in logs(name):
            return name
        time.sleep(1)
    show_logs(name)
    raise RuntimeError('Mock API did not start')


def callbacks(mock):
    found = []
    for line in logs(mock).splitlines():
        if line.startswith('{'):
            record = json.loads(line)
            if record['method'] == 'POST' and record['path'] == '/v1/apps/installed/' + instance_id:
                found.append(record)
    return found


def wait_callbacks(mock, count, limit=60):
    for _ in range(limit):
        if len(callbacks(mock)) >= count:
            break
        time.sleep(1)
    time.sleep(3)
    found = callbacks(mock)
    assert len(found) == count, 'expected %d installed callbacks, got %d' % (count, len(found))
    return found


def new_volume(suffix):
    name = run_id + '-' + suffix
    command(['docker', 'volume', 'create', '--label', label, name])
    volumes.append(name)
    return name


def launch(suffix, selected_image, volume, znc_password):
    name = run_id + '-' + suffix
    args = ['docker', 'run', '-d', '--platform', 'linux/amd64', '--name', name, '--label', label,
            '--init', '--network', network, '-p', '127.0.0.1::' + irc_port,
            '-v', volume + ':/znc-data',
            '-v', str(work / 'znc-key.pem') + ':/etc/ssl/private/key.pem:ro',
            '-v', str(work / 'znc-cert.pem') + ':/etc/ssl/private/cert.pem:ro',
            '-v', str(work / 'ca-bundle.crt') + ':/etc/ssl/certs/ca-certificates.crt:ro',
            '-e', 'USERNAME=' + user, '-e', 'ZNCPORT=' + irc_port,
            '-e', 'INSTANCE_ID=' + instance_id, '-e', 'CALLBACK_TOKEN=' + callback_token]
    if znc_password is not None:
        args += ['-e', 'ZNCPASS=' + znc_password]
    command(args + [selected_image])
    containers.append(name)
    return name


def host_port(name):
    binding = out(['docker', 'port', name, irc_port + '/tcp']).strip().splitlines()[0]
    return int(binding.rsplit(':', 1)[1])


def tls():
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


def irc(name, znc_password, commands=(), expect=()):
    """Log in over TLS. Returns (True, replies) on 001, (False, '') on 464."""
    raw = socket.create_connection(('127.0.0.1', host_port(name)), timeout=15)
    with tls().wrap_socket(raw) as conn:
        conn.sendall(('PASS %s:%s\r\nNICK %s\r\nUSER %s 0 * :gate\r\n' % (user, znc_password, user, user)).encode())
        data = b''
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if re.search(rb'^\S+ 464 ', data, re.M):
                return False, ''
            if re.search(rb'^\S+ 001 ', data, re.M):
                break
            chunk = conn.recv(65536)
            if not chunk:
                raise ConnectionError('ZNC closed the connection')
            data += chunk
        else:
            raise TimeoutError('no IRC welcome')
        for line in commands:
            conn.sendall(line.encode() + b'\r\n')
        replies = b''
        for marker in expect:
            deadline = time.monotonic() + 20
            while marker.encode() not in replies and time.monotonic() < deadline:
                chunk = conn.recv(65536)
                if not chunk:
                    break
                replies += chunk
            assert marker.encode() in replies, 'no reply containing ' + marker
        conn.sendall(b'QUIT :gate\r\n')
        return True, replies.decode(errors='replace')


def wait_login(name, znc_password, limit=300):
    last = ''
    for _ in range(limit // 3):
        state = out(['docker', 'inspect', '--format', '{{.State.Running}}', name]).strip()
        if state != 'true':
            show_logs(name)
            raise RuntimeError(name + ' stopped')
        try:
            ok, _ = irc(name, znc_password)
            if ok:
                return
            last = 'password refused'
        except (OSError, ConnectionError, TimeoutError) as error:
            last = type(error).__name__
        time.sleep(3)
    show_logs(name)
    raise RuntimeError('IRC login did not succeed: ' + last)


def check_web(name):
    url = 'https://127.0.0.1:%d/' % host_port(name)
    with urllib.request.urlopen(url, timeout=15, context=tls()) as response:
        body = response.read()
        assert response.status == 200 and b'ZNC' in body, 'webadmin did not answer'


def config(name):
    return out(['docker', 'exec', name, 'cat', '/znc-data/configs/znc.conf'])


def pass_block(text):
    """The install user's password settings (ZNC sorts keys when it saves)."""
    match = re.search(r'<User ' + user + r'>(.*?)</User>', text, re.S)
    assert match, 'no block for the install user'
    match = re.search(r'<Pass password>(.*?)</Pass>', match.group(1), re.S)
    assert match, 'no password block for the install user'
    block = dict(re.findall(r'^\s*(\w+) = (\S+)\s*$', match.group(1), re.M))
    # The install template says sha256; ZNC writes SHA256 when it saves.
    assert block.get('Method', '').lower() == 'sha256', 'bad method'
    assert re.fullmatch(r'[0-9a-f]{64}', block.get('Hash', '')), 'bad hash'
    assert len(block.get('Salt', '')) == 20, 'bad salt'
    return block


def check_runtime(name):
    status = out(['docker', 'exec', name, 'sh', '-c', 'cat /proc/$(pidof znc)/status'])
    assert re.search(r'^Uid:\s+1000\s+1000\s+1000\s+1000$', status, re.M), 'znc is not UID 1000'


def check_not_logged(name, values):
    text = logs(name)
    for value in values:
        assert value not in text, 'Secret found in the container log of ' + name
    assert 'admin123' not in text
    assert not re.search(r'^\++ ', text, re.M), 'commands traced into the log of ' + name


def check_not_stored(name, values):
    for value in values:
        p = command(['docker', 'exec', name, 'grep', '-rlF', value, '/znc-data'], check=False)
        assert p.returncode == 1, 'Password found in files of ' + name


def refused(suffix, mock, env_password):
    before = len(callbacks(mock))
    volume = new_volume(suffix)
    name = launch(suffix, image, volume, env_password)
    status = command(['docker', 'wait', name], timeout=120).stdout.decode().strip()
    assert status not in ('', '0'), 'container exited with status ' + status
    assert 'refusing to set up ZNC' in logs(name)
    changed = out(['docker', 'diff', name])
    assert not re.search(r'^[AC] /etc/app(_configured|box_callback_pending)', changed, re.M), 'markers written'
    listing = out(['docker', 'run', '--rm', '--network', 'none', '-v', volume + ':/znc-data',
                   '--entrypoint', 'find', image, '/znc-data', '-type', 'f'])
    assert listing.strip() == '', 'files created in /znc-data'
    time.sleep(3)
    assert len(callbacks(mock)) == before, 'installed callback sent'
    print('PASS refused (%s): exit %s, no config, no callback' % (suffix, status), flush=True)


try:
    # --- unit tests and the image itself ----------------------------------------
    test = subprocess.run(['bash', str(repo_root / 'tests' / 'test-installed-callback.sh')],
                          capture_output=True, text=True, timeout=600)
    print(test.stdout[-3000:], flush=True)
    assert test.returncode == 0, 'tests/test-installed-callback.sh failed'
    details = json.loads(out(['docker', 'image', 'inspect', image]))[0]
    assert details['Architecture'] == 'amd64' and details['Os'] == 'linux'
    env = details['Config']['Env']
    assert not any(item.startswith('ZNCPASS=') for item in env), env
    assert 'USERNAME=admin' in env and 'ZNCPORT=6667' in env
    assert details['Config']['Cmd'] == ['/entrypoint.sh']
    files = out(['docker', 'run', '--rm', '--network', 'none', '--entrypoint', 'sh', image, '-c',
                 'sha256sum /entrypoint.sh /usr/local/bin/appbox-installed-callback; '
                 'test ! -e /appbox/scripts/changepassword.sh && echo no-changepassword; '
                 'bash -n /entrypoint.sh && echo syntax-ok; znc --version | head -1; '
                 'getcap /usr/local/bin/znc'])
    for path in ('scripts/entrypoint.sh', 'appbox-installed-callback'):
        assert hashlib.sha256((repo_root / path).read_bytes()).hexdigest() in files, path + ' differs'
    assert 'no-changepassword' in files and 'syntax-ok' in files and 'ZNC 1.8.2' in files, files
    assert 'cap_net_bind_service' in files, files
    print('PASS image: no ZNCPASS default, no changepassword.sh, committed scripts, ZNC 1.8.2', flush=True)

    make_tls()
    mock = start_mock()

    # --- no password: fail closed -------------------------------------------------
    refused('unset', mock, None)
    refused('empty', mock, '')

    # --- fresh install --------------------------------------------------------------
    fresh = launch('fresh', image, new_volume('fresh'), password)
    wait_login(fresh, password)
    ok, _ = irc(fresh, upgrade_password)
    assert not ok, 'wrong password accepted'
    check_web(fresh)
    check_runtime(fresh)
    fresh_block = pass_block(config(fresh))
    found = wait_callbacks(mock, 1)
    assert found[-1]['host'] == 'api.cylo.net' and found[-1]['token'] == callback_token, 'callback without token'
    check_not_logged(fresh, secret_values)
    check_not_stored(fresh, secret_values)
    print('PASS fresh: TLS login, wrong password refused, webadmin, UID 1000, one callback with token, '
          'nothing secret logged or stored', flush=True)

    # --- restart -------------------------------------------------------------------
    command(['docker', 'restart', '--time', '30', fresh])
    wait_login(fresh, password)
    assert pass_block(config(fresh)) == fresh_block
    check_web(fresh)
    wait_callbacks(mock, 1, limit=5)
    check_not_logged(fresh, secret_values)
    print('PASS restart: same password hash, login works, no second callback', flush=True)
    command(['docker', 'stop', '--time', '30', fresh])

    # --- upgrade from znc:latest ----------------------------------------------------
    upgrade_volume = new_volume('upgrade')
    baseline = launch('baseline', registry.CURRENT, upgrade_volume, upgrade_password)
    wait_login(baseline, upgrade_password)
    irc(baseline, upgrade_password,
        commands=('PRIVMSG *controlpanel :Set RealName %s Gate preserved' % user, 'PRIVMSG *status :saveconfig'),
        expect=('Wrote config',))
    wait_callbacks(mock, 2)
    baseline_conf = config(baseline)
    baseline_block = pass_block(baseline_conf)
    assert 'RealName = Gate preserved' in baseline_conf
    baseline_leaked = upgrade_password in logs(baseline)
    command(['docker', 'stop', '--time', '30', baseline])
    upgraded = launch('upgraded', image, upgrade_volume, upgrade_password)
    wait_login(upgraded, upgrade_password)
    upgraded_conf = config(upgraded)
    assert pass_block(upgraded_conf) == baseline_block, 'password hash changed on upgrade'
    assert 'RealName = Gate preserved' in upgraded_conf, 'user settings lost on upgrade'
    check_web(upgraded)
    check_runtime(upgraded)
    found = wait_callbacks(mock, 3)
    assert found[-1]['host'] == 'api.cylo.net' and found[-1]['token'] == callback_token
    check_not_logged(upgraded, secret_values)
    check_not_stored(upgraded, secret_values)
    print('PASS upgrade from znc:latest: password hash and user settings kept, login works, one callback, '
          'nothing secret logged (znc:latest logged the password: %s)' % baseline_leaked, flush=True)
except Exception as error:
    print('FAIL release gate: ' + type(error).__name__ + ': ' + redact(str(error)), flush=True)
    raise
finally:
    for name in reversed(containers):
        try:
            found = out(['docker', 'inspect', '--format', '{{index .Config.Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Container cleanup identity mismatch')
            command(['docker', 'rm', '-f', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in volumes:
        try:
            found = out(['docker', 'volume', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Volume cleanup identity mismatch')
            command(['docker', 'volume', 'rm', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    for name in networks:
        try:
            found = out(['docker', 'network', 'inspect', '--format', '{{index .Labels "appbox.release-gate"}}', name]).strip()
            if found != run_id:
                raise RuntimeError('Network cleanup identity mismatch')
            command(['docker', 'network', 'rm', name])
        except Exception as error:
            print('Cleanup requires attention:', name, type(error).__name__, flush=True)
    if work.parent == Path(tempfile.gettempdir()) and work.name.startswith(run_id + '-'):
        shutil.rmtree(work)

registry.require_absent(image)
print('PASS required release gates', flush=True)
