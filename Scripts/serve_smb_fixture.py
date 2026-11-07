#!/usr/bin/env python3
"""Serve generated fixtures over loopback SMB2 (optional test-only impacket dependency)."""
import argparse
import json
import logging
import os
from pathlib import Path
import secrets
import shutil
import tempfile
from impacket import smbserver
from impacket import smb3structs as smb2
from impacket.nt_errors import STATUS_SUCCESS
from impacket.ntlm import compute_lmhash, compute_nthash


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True, help='New temporary credentials file for the integration test; removed at exit')
    parser.add_argument('--port', type=int, default=14455)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        parser.error('Choose an unprivileged port between 1024 and 65535')
    source = Path(__file__).resolve().parent.parent / 'VisionProPlayer/Resources/Sample2D.mp4'
    with tempfile.TemporaryDirectory(prefix='vpp-smb-fixture-') as temporary:
        root = Path(temporary)
        (root / '子目录').mkdir()
        for target in [root / '测试 #1.mp4', root / '子目录/nested.mp4']:
            shutil.copyfile(source, target)
        (root / 'readme.txt').write_text('Synthetic fixture')
        username, password = 'fixtureviewer', secrets.token_hex(12)
        server = smbserver.SimpleSMBServer(listenAddress='127.0.0.1', listenPort=args.port)
        server.setSMB2Support(True)
        server.addShare('Movies', str(root), 'Synthetic read-only movies', readOnly='yes')
        server.addCredential(username, 0, compute_lmhash(password), compute_nthash(password))
        # The stock test server emits a READ body with an EOF error status.
        # libsmb2 expects the SMB2 error body when status is not SUCCESS.
        def read_with_error_body(conn_id, smb_server, packet):
            commands, packets, status = smbserver.SMB2Commands.smb2Read(conn_id, smb_server, packet)
            if status != STATUS_SUCCESS:
                error = smb2.SMB2Error()
                error['ByteCount'] = 1
                error['ErrorData'] = b'\x00'
                return [error], None, status
            return commands, packets, status
        server.getServer().hookSmb2Command(smb2.SMB2_READ, read_with_error_body)
        # Do not print authentication tokens or hashes, even for test accounts.
        logging.disable(logging.CRITICAL)
        fd = os.open(args.config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump({'url': f'smb://127.0.0.1:{args.port}/Movies/',
                       'username': username, 'password': password}, output)
        print('Loopback SMB fixture ready; no NAS or system sharing settings changed.', flush=True)
        try:
            server.start()
        except KeyboardInterrupt:
            pass
        finally:
            args.config.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
