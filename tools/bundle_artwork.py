#!/usr/bin/env python3
"""Generate a self-contained installer from reviewed native sources."""
import base64
import hashlib
from pathlib import Path
import sys
root=Path(__file__).resolve().parents[1]
parts=[]
for source,target in [('native/viewer.c','viewer.c'),('native/shader.h','shader.h'),('native/runner.py','runner.py'),('artwork/NOTICE.md','ARTWORK-NOTICE.md')]:
    data=(root/source).read_bytes()
    parts.append(f'''python3 - "$stage/{target}" <<'PAYLOAD_PY'
import base64, hashlib, sys
data=base64.b64decode('{base64.b64encode(data).decode()}',validate=True)
if hashlib.sha256(data).hexdigest()!='{hashlib.sha256(data).hexdigest()}':
    raise SystemExit('Embedded source checksum mismatch')
with open(sys.argv[1],'wb') as f: f.write(data)
PAYLOAD_PY
''')
result=(root/'tools/install_template.sh').read_text().replace('# GENERATED PAYLOAD\n',''.join(parts))
target=root/'install.sh'
if '--check' in sys.argv:
    if target.read_text()!=result: raise SystemExit('Stale installer: run tools/bundle_artwork.py')
else: target.write_text(result)
