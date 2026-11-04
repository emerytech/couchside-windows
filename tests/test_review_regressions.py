"""Review regressions. Windows installer tests use disposable paths and stubs only."""
import base64,hashlib,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
ROOT=Path(__file__).resolve().parents[1]

class ReviewTests(unittest.TestCase):
 def test_inventory_excludes_old_installer_until_explicit_final(self):
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);(root/'tools').mkdir();(root/'dist').mkdir()
   (root/'LICENSE').write_text('synthetic license')
   tool=root/'tools/inventory.py';tool.write_bytes((ROOT/'tools/collect_build_inventory.py').read_bytes())
   (root/'dist/couchside-agent.exe').write_bytes(b'new-agent')
   setup=root/'dist/CouchsideSetup.exe';setup.write_bytes(b'old-installer')
   subprocess.run([sys.executable,str(tool)],check=True)
   report=root/'dist/build-inventory.json'
   self.assertEqual([v['name'] for v in json.loads(report.read_text())['artifacts']],['couchside-agent.exe'])
   setup.write_bytes(b'new-installer')
   subprocess.run([sys.executable,str(tool),'--final-installer'],check=True)
   entry=next(v for v in json.loads(report.read_text())['artifacts'] if v['name']==setup.name)
   self.assertEqual(entry['sha256'],hashlib.sha256(b'new-installer').hexdigest())

 def test_elevation_forwards_ref_only_when_explicit(self):
  source=(ROOT/'install.ps1').read_text()
  self.assertIn("if ($PSBoundParameters.ContainsKey('Ref')) { $fwd += \"-Ref $Ref\" }",source)

 @unittest.skipUnless(os.name=='nt','Windows PowerShell integration')
 def test_signed_download_preflight_preserves_old_agent_on_failure(self):
  source=(ROOT/'install.ps1').read_text()
  helper=source[source.index('function Assert-ReleaseSignature {'):source.index('# --- 1. resolve the agent source:')]
  # Execute only the source-resolution phase. Never execute elevation, task,
  # firewall, config, driver or account setup. Stub dependencies and downloads.
  phase=source[source.index('# --- 1. resolve the agent source:'):source.index('# The agent runs NON-elevated')]
  phase=phase.replace("    & $consolePy -m pip install --only-binary=:all: 'cryptography==46.0.7'",'    $global:LASTEXITCODE = 0 # fixture dependency is already installed')
  key=Ed25519PrivateKey.generate();pem=key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo).decode()
  payloads={'couchsided-win.py':b'print("synthetic only")\n','qr.py':b'# fixture\n'}
  sums=''.join(hashlib.sha256(v).hexdigest()+'  '+k+'\n' for k,v in payloads.items()).encode()
  for mode in ['valid','wrong-key','missing-signature','tampered-payload','bad-syntax','dependency-failure']:
   with self.subTest(mode=mode),tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp);fixtures=root/'fixtures';fixtures.mkdir()
    for name,data in payloads.items():(fixtures/name).write_bytes(data)
    signed=sums
    if mode=='bad-syntax':
     (fixtures/'couchsided-win.py').write_bytes(b'def ! invalid\n')
     signed=''.join(hashlib.sha256((fixtures/k).read_bytes()).hexdigest()+'  '+k+'\n' for k in payloads).encode()
    (fixtures/'SHA256SUMS').write_bytes(signed)
    signer=Ed25519PrivateKey.generate() if mode=='wrong-key' else key
    if mode!='missing-signature':(fixtures/'SHA256SUMS.sig').write_bytes(signer.sign(signed))
    if mode=='tampered-payload':(fixtures/'qr.py').write_bytes(b'# modified\n')
    install=root/'installed';install.mkdir();(install/'couchsided-win.py').write_bytes(b'old-agent')
    harness=root/'harness.ps1'
    prefix='''param($Work, $Python, $PublicKey, $Mode)
$ErrorActionPreference='Stop'
$here=$null; $UseRelease=$true; $ReleaseBase='https://fixture.invalid/release'
$InstallDir=Join-Path $Work 'installed'; $DataDir=Join-Path $Work 'data'
$env:TEMP=$Work
$ReleasePubKeys=@([Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($PublicKey)))
$script:Stopped=0
function Stop-AgentTask { $script:Stopped++ }
function Resolve-Python { return $Python }
function Install-WingetPackage { throw 'Fixture must not install packages' }
function Invoke-WebRequest {
 param($UseBasicParsing,$Uri,$OutFile)
 # Switch is positional in original calls; collect the actual URI via args.
 if (-not $Uri) { throw 'Fixture URL missing' }
 $name=($Uri -split '/')[-1]
 Copy-Item -LiteralPath (Join-Path (Join-Path $Work 'fixtures') $name) -Destination $OutFile -ErrorAction Stop
}
'''.replace('param($UseBasicParsing,$Uri,$OutFile)','param([switch]$UseBasicParsing,[string]$Uri,[string]$OutFile)')
    runphase=phase
    if mode=='dependency-failure':runphase=runphase.replace('$global:LASTEXITCODE = 0 # fixture dependency is already installed','$global:LASTEXITCODE = 1')
    harness.write_text(prefix+helper+'\n$failed=$false; $why=$null\ntry {\n'+runphase+'''\n} catch { $failed=$true; $why=$_.Exception.Message }
@{why=$why; failed=$failed; stopped=$script:Stopped; retained=([IO.File]::ReadAllText((Join-Path $InstallDir 'couchsided-win.py')) -eq 'old-agent')} | ConvertTo-Json -Compress | Write-Output
''',encoding='utf-8-sig')
    r=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(harness),str(root),sys.executable,base64.b64encode(pem.encode()).decode(),mode],capture_output=True,text=True,timeout=60)
    self.assertEqual(r.returncode,0,r.stderr)
    result=json.loads(next(line for line in reversed(r.stdout.splitlines()) if line.startswith('{')))
    why=result.pop('why',None)
    if mode=='valid':self.assertEqual(result,{'failed':False,'stopped':1,'retained':False},str(why)+'\n'+r.stderr+'\n'+r.stdout)
    else:self.assertEqual(result,{'failed':True,'stopped':0,'retained':True})

if __name__=='__main__':unittest.main()
