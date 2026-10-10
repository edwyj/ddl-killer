"""Identify a channel's Web build from inputs without self-hashing output JS."""
from pathlib import Path
import hashlib,sys
app=Path(__file__).resolve().parents[1]
paths=[app/'pubspec.yaml',app/'pubspec.lock']
paths+=list((app/'lib').rglob('*.dart'))
paths+=list((app/'web').rglob('*'))
channel=sys.argv[2] if len(sys.argv)>2 else 'beta'
if channel not in {'stable','beta'}: raise ValueError('Invalid release channel')
if channel=='beta':
    paths+=[app.parent/'ops/beta-download.html',app.parent/'ops/beta-download.js']
h=hashlib.sha256((channel+'-web:'+sys.argv[1]).encode())
for p in sorted(p for p in paths if p.is_file() and p.suffix!='.apk'):
    h.update(p.relative_to(app.parent).as_posix().encode());h.update(b'\0');h.update(p.read_bytes())
print(h.hexdigest())
