"""Generate PE project/version metadata from the literal source version."""
import ast,re,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
node=ast.parse((root/'couchsided-win.py').read_text(encoding='utf-8'))
version=next(ast.literal_eval(n.value) for n in node.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='VERSION' for t in n.targets))
m=re.fullmatch(r'(\d+)\.(\d+)\.(\d+)(?:-[A-Za-z0-9.-]+)?',version)
if not m:raise SystemExit('Invalid source version')
numbers=tuple(map(int,m.groups()))+(0,)
if any(x>65535 for x in numbers):raise SystemExit('PE version component out of range')
text='.'.join(map(str,numbers))
from PyInstaller.utils.win32.versioninfo import VSVersionInfo,FixedFileInfo,StringFileInfo,StringTable,StringStruct,VarFileInfo,VarStruct
info=VSVersionInfo(ffi=FixedFileInfo(filevers=numbers,prodvers=numbers,mask=0x3f,flags=0,OS=0x40004,fileType=1,subtype=0,date=(0,0)),kids=[StringFileInfo([StringTable('040904B0',[StringStruct(k,v) for k,v in {'CompanyName':'ETS3D LLC','ProductName':'Couchside','ProductVersion':text,'FileVersion':text,'FileDescription':'Couchside Windows agent','InternalName':'couchside-agent','OriginalFilename':'couchside-agent.exe','LegalCopyright':'Copyright 2026 Taylor Emery (ETS3D LLC)'}.items()])]),VarFileInfo([VarStruct('Translation',[1033,1200])])])
Path(sys.argv[1]).write_text(str(info),encoding='utf-8')
