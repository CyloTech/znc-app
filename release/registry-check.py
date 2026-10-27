#!/usr/bin/env python3
"""Fail closed unless the authenticated registry confirms this new tag is absent."""
import subprocess
import sys

EXPECTED = 'repo.cylo.net/znc:1.8.2-1'
# znc:latest, the image behind the current 1.8.2 catalogue version.
CURRENT = 'repo.cylo.net/znc@sha256:da126b15c5964dde5e63b6f318020bf5ec060bb2c7b7d36d3169e824de674e66'


def require_absent(image):
    if image != EXPECTED:
        raise RuntimeError('Unexpected image reference')
    known = subprocess.run(['docker', 'manifest', 'inspect', CURRENT], capture_output=True, text=True, timeout=90)
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
