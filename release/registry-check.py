#!/usr/bin/env python3
"""Fail closed unless the authenticated registry confirms this new tag is absent."""
import subprocess
import sys

EXPECTED = 'repo.cylo.net/znc:1.8.2-2'
# znc:1.8.2-1, the image behind the current default catalogue version.
CURRENT = 'repo.cylo.net/znc@sha256:a37dfe9c40939a7a54bcd593c3fb657ac306b30adf9e026b2aad6d2e5da4fbf2'
# znc:latest, the image behind the older 1.8.2 catalogue version.
LEGACY = 'repo.cylo.net/znc@sha256:da126b15c5964dde5e63b6f318020bf5ec060bb2c7b7d36d3169e824de674e66'


def require_absent(image):
    if image != EXPECTED:
        raise RuntimeError('Unexpected image reference')
    for baseline in (CURRENT, LEGACY):
        known = subprocess.run(['docker', 'manifest', 'inspect', baseline], capture_output=True, text=True, timeout=90)
        if known.returncode:
            raise RuntimeError('Authenticated registry baseline read failed; state is indeterminate')
    result = subprocess.run(['docker', 'manifest', 'inspect', image], capture_output=True, text=True, timeout=90)
    if result.returncode == 0:
        raise RuntimeError('Release tag exists; refusing replacement')
    if result.stderr.strip() != 'no such manifest: ' + image:
        raise RuntimeError('Registry response is indeterminate; refusing publication')
    print('PASS registry: baseline readable and exact release tag definitively absent', flush=True)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: registry-check.py IMAGE')
    require_absent(sys.argv[1])
