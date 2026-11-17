#!/usr/bin/env python3
"""Embed reviewed artwork in the one-file installer; --check verifies sync."""
import base64
import hashlib
from pathlib import Path
import sys

root = Path(__file__).resolve().parents[1]
installer = root / 'install.sh'
start = '# BEGIN GENERATED OFFLINE ARTWORK\n'
end = '# END GENERATED OFFLINE ARTWORK'
text = installer.read_text()
parts = []
for source, target in [('artwork/index.html', 'artwork.html'), ('artwork/NOTICE.md', 'ARTWORK-NOTICE.md')]:
    data = (root / source).read_bytes()
    encoded = base64.b64encode(data).decode('ascii')
    digest = hashlib.sha256(data).hexdigest()
    parts.append(f'''python3 - "$DATA/{target}" <<'ARTWORK_PY'
import base64, hashlib, os, sys, tempfile
data = base64.b64decode('{encoded}', validate=True)
if hashlib.sha256(data).hexdigest() != '{digest}':
    raise SystemExit('Embedded artwork checksum mismatch')
fd, stage = tempfile.mkstemp(dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
    os.replace(stage, sys.argv[1])
finally:
    if os.path.exists(stage): os.unlink(stage)
ARTWORK_PY
''')
result = text.split(start)[0] + start + ''.join(parts) + end + text.split(end, 1)[1]
if '--check' in sys.argv:
    if result != text:
        raise SystemExit('Embedded artwork is stale. Run python3 tools/bundle_artwork.py')
else:
    installer.write_text(result)
