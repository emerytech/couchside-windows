"""Inventory the actual build environment and artifacts. Never reads user config."""
import hashlib,importlib.metadata as metadata,json,platform,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=root/'dist';notices=out/'licenses';notices.mkdir(parents=True,exist_ok=True)
packages=[]
for dist in metadata.distributions():
 name=dist.metadata.get('Name','unknown')
 if name=='pip':continue
 copies=[]
 for f in dist.files or []:
  if any(p.lower().startswith(('license','copying','notice','authors')) for p in f.parts):
   src=Path(dist.locate_file(f))
   if src.is_file():
    dest=notices/name/('-'.join(f.parts[-3:]));dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(src.read_bytes());copies.append(str(dest.relative_to(out)))
 packages.append({'name':name,'version':dist.version,'license':dist.metadata.get('License-Expression') or dist.metadata.get('License'),'notices':copies})
for rel in ['LICENSE.txt','tcl/tcl8.6/license.terms','tcl/tk8.6/license.terms']:
 src=Path(sys.base_prefix)/rel
 if src.is_file():(notices/('Python-'+rel.replace('/','-'))).write_bytes(src.read_bytes())
(notices/'Couchside-LICENSE.txt').write_bytes((root/'LICENSE').read_bytes())
for source in (root/'third-party').glob('*LICENSE*'):
 (notices/source.name).write_bytes(source.read_bytes())
def digest(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for b in iter(lambda:f.read(65536),b''):h.update(b)
 return h.hexdigest()
artifacts=[]
for p in [root/'ViGEmClient.dll',out/'couchside-agent.exe',out/'CouchsideSetup.exe']:
 if p.is_file():artifacts.append({'name':p.name,'size':p.stat().st_size,'sha256':digest(p)})
# Paths deliberately omitted: build environments can contain private user names.
(out/'build-inventory.json').write_text(json.dumps({'python':platform.python_version(),'platform':sys.platform,'dependencies':sorted(packages,key=lambda x:x['name'].lower()),'artifacts':artifacts},indent=2),encoding='utf-8')
