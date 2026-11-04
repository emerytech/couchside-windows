"""Harmless Windows PowerShell worker tests and simulated firewall policy tests."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'install.ps1').read_text(encoding='utf-8-sig')
HELPERS=SOURCE.split('# BEGIN firewall helpers')[1].split('# END firewall helpers')[0]
PORT_HELPERS=SOURCE.split('# BEGIN installer port helpers')[1].split('# END installer port helpers')[0]
WAIT_BLOCK=SOURCE[SOURCE.index('            $child = Start-Process powershell -Verb RunAs'):SOURCE.index('            # END elevated installer wait')]

POLICY_FIXTURE = r'''
class FixtureRules : System.Collections.IEnumerable {
 [System.Collections.ArrayList]$Items=[System.Collections.ArrayList]::new()
 [System.Collections.IEnumerator] GetEnumerator() { return $this.Items.GetEnumerator() }
 [void] Remove([string]$name) {
  for($i=0;$i -lt $this.Items.Count;$i++) { if($this.Items[$i].Name -eq $name) { $this.Items.RemoveAt($i);return } }
 }
}
$rules=[FixtureRules]::new()
foreach($name in @('Couchside Agent','Couchside Agent','Couchside Agent HTTPS','Couchside Agent Discovery','Couchside Agent Other','Unrelated')) { [void]$rules.Items.Add([pscustomobject]@{Name=$name}) }
$script:Policy=[pscustomobject]@{Rules=$rules}
$script:Added=[System.Collections.ArrayList]::new()
function New-Object { param($ComObject) if($ComObject -ne 'HNetCfg.FwPolicy2'){throw 'unexpected fixture COM'};return $script:Policy }
function Get-NetConnectionProfile { if('ACTIVE' -eq 'THROW'){throw 'No connected network profile'}; [pscustomobject]@{NetworkCategory='ACTIVE'} }
function New-NetFirewallRule {
 [CmdletBinding()]param($DisplayName,$Direction,$Action,$Protocol,$LocalPort,$RemoteAddress,$Profile,$Program)
 [void]$script:Added.Add(@{name=$DisplayName;direction=$Direction;action=$Action;protocol=$Protocol;port=$LocalPort;remote=$RemoteAddress;profile=$Profile;program=$Program;errorAction=[string]$PSBoundParameters['ErrorAction']})
}
function Invoke-InstallerWorker {
 param($Code,$Label)
 $Code=$Code.Replace('exit 0','return').Replace('exit 1',"throw 'fixture worker failed'")
 & ([scriptblock]::Create($Code))
}
$NoFirewall=$false;$usePython=$true;$Port=9010
$pyPath="C:\Fake PC\unicode-λ\literal'; not-code.exe"
Set-CouchsideFirewall
@{left=@($rules.Items | ForEach-Object Name); added=@($script:Added)} | ConvertTo-Json -Depth 6 -Compress
'''

@unittest.skipUnless(os.name=='nt','Windows PowerShell integration')
class FirewallTests(unittest.TestCase):
 def run_ps(self, code, timeout=30):
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'fixture.ps1';path.write_text("$ErrorActionPreference='Stop'\n[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n"+code,encoding='utf-8-sig')
   env={k:v for k,v in os.environ.items() if k.upper()!='PSMODULEPATH'}
   result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(path)],capture_output=True,text=True,encoding='utf-8',timeout=timeout,env=env)
   self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
   return result.stdout

 def test_worker_propagates_error_and_bounds_hang(self):
  out=self.run_ps(HELPERS+'''
$failed=$false;$timed=$false
try { Invoke-InstallerWorker -Code "[Console]::Error.WriteLine('fixture failure'); exit 9" -Label fixture } catch { $failed=$_.Exception.Message -like '*exit 9*fixture failure*' }
$watch=[Diagnostics.Stopwatch]::StartNew()
try { Invoke-InstallerWorker -Code 'Start-Sleep -Seconds 60' -Label fixture -TimeoutSeconds 1 } catch { $timed=$_.Exception.Message -like '*timed out*' }
@{failed=$failed; timed=$timed; seconds=$watch.Elapsed.TotalSeconds} | ConvertTo-Json -Compress
''')
  result=json.loads(out.strip().splitlines()[-1]);self.assertTrue(result['failed']);self.assertTrue(result['timed']);self.assertLess(result['seconds'],10)

 def test_elevation_wait_returns_child_exit_without_waiting_for_descendants(self):
  # Exercise the production wait block without UAC in a harmless CI fixture.
  block=WAIT_BLOCK
  block=block.replace('-Verb RunAs ','').replace('exit $childExit','Write-Output "CHILD_EXIT=$childExit"')
  with tempfile.TemporaryDirectory() as tmp:
   pid_file=Path(tmp)/'descendant.pid'
   literal=str(pid_file).replace("'","''")
   child="Start-Process powershell -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 30' -PassThru | ForEach-Object Id | Set-Content -LiteralPath '"+literal+"'; exit 7"
   import base64,time
   encoded=base64.b64encode(child.encode('utf-16-le')).decode()
   start=time.monotonic()
   try:
    out=self.run_ps("$a=@('-NoProfile','-NonInteractive','-EncodedCommand','"+encoded+"')\n"+block,timeout=15)
    self.assertIn('CHILD_EXIT=7',out);self.assertLess(time.monotonic()-start,12)
   finally:
    if pid_file.exists():subprocess.run(['taskkill','/PID',pid_file.read_text(encoding='utf-8-sig').strip(),'/T','/F'],capture_output=True,timeout=10)

 def test_failure_precedes_agent_stop(self):
  stop=SOURCE[SOURCE.index('function Stop-AgentTask {'):SOURCE.index('function Uninstall-Couchside {')]
  out=self.run_ps('''
$Uninstall=$false;$script:Stopped=$false
function Set-CouchsideFirewall { throw 'fixture provider failure' }
function Stop-ScheduledTask { $script:Stopped=$true }
function Get-Process { throw 'fixture must not touch processes' }
'''+stop+'''
$failed=$false
try { Stop-AgentTask } catch { $failed=$_.Exception.Message -like '*before stopping*' }
@{failed=$failed; stopped=$script:Stopped} | ConvertTo-Json -Compress
''')
  self.assertEqual(json.loads(out.strip().splitlines()[-1]),{'failed':True,'stopped':False})

 def test_duplicate_rules_profiles_scopes_and_literal_program(self):
  for active,expected in [('', 'Private'),('THROW','Private'),('Public','Private,Public'),('DomainAuthenticated','Private,Domain')]:
   with self.subTest(active=active):
    out=self.run_ps(HELPERS+POLICY_FIXTURE.replace('ACTIVE',active))
    result=json.loads(out.strip().splitlines()[-1]);self.assertEqual(result['left'],['Couchside Agent Other','Unrelated'])
    rules=result['added'];self.assertEqual(len(rules),3)
    self.assertEqual([r['port'] for r in rules],[9010,9011,9010])
    self.assertEqual([r['protocol'] for r in rules],['TCP','TCP','UDP'])
    self.assertEqual([r['profile'] for r in rules],[expected]*3)
    self.assertEqual([r['errorAction'] for r in rules],['Stop']*3)
    self.assertTrue(all(r['direction']=='Inbound' and r['action']=='Allow' for r in rules))
    self.assertEqual([r['remote'] for r in rules],[None,'LocalSubnet','LocalSubnet'])
    self.assertEqual(rules[2]['program'],"C:\\Fake PC\\unicode-λ\\literal'; not-code.exe")

 def test_null_elevated_exit_is_failure_and_handle_is_cached_first(self):
  # A fast-exiting/elevated process can otherwise expose a null ExitCode.
  stub="""
$script:HandleRead=$false;$failed=$false
function Start-Process {
 $p=[pscustomobject]@{ExitCode=$null}
 $p | Add-Member ScriptProperty Handle { $script:HandleRead=$true;return 42 }
 $p | Add-Member ScriptMethod WaitForExit { if(!$script:HandleRead){throw 'Handle not cached before wait'} }
 return $p
}
"""
  block=WAIT_BLOCK.replace('exit $childExit','throw "Unexpected successful exit $childExit"')
  out=self.run_ps(stub+'try {\n'+block+"\n} catch { $failed=$_.Exception.Message -like '*did not provide an exit code*' }\n@{failed=$failed; handleRead=$script:HandleRead} | ConvertTo-Json -Compress")
  self.assertEqual(json.loads(out.strip().splitlines()[-1]),{'failed':True,'handleRead':True})

 def test_port_resolution_range_explicit_override_and_settings_retention(self):
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'config.json'
   original={'port':9010,'launchers':[{'id':'synthetic','args':['x','y']}],'appearance':{'accent':'blue','label':'Café 🎮'}}
   path.write_text(json.dumps(original,ensure_ascii=False),encoding='utf-8')
   literal=str(path).replace("'","''")
   out=self.run_ps(PORT_HELPERS+"\n$path='"+literal+"'\n"+"""
$before=(Get-FileHash $path).Hash
$saved=Resolve-InstallerPort 8787 $false $path
$explicit=Resolve-InstallerPort 9123 $true $path
$max=Resolve-InstallerPort 65534 $true $path
$rejected=@()
foreach($invalid in @(0,65535)) { try { [void](Resolve-InstallerPort $invalid $true $path) } catch { $rejected+=$invalid } }
Save-ExplicitInstallerPort -RequestedPort 9010 -Path $path
$unchanged=(Get-FileHash $path).Hash -eq $before
Save-ExplicitInstallerPort -RequestedPort 9123 -Path $path
$after=Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
@{saved=$saved;explicit=$explicit;max=$max;rejected=$rejected;samePortUnchanged=$unchanged;after=$after} | ConvertTo-Json -Depth 20 -Compress
""")
   result=json.loads(out.strip().splitlines()[-1]);self.assertEqual(result['saved'],9010);self.assertEqual(result['explicit'],9123)
   self.assertEqual(result['max'],65534);self.assertEqual(result['rejected'],[0,65535]);self.assertTrue(result['samePortUnchanged'])
   self.assertEqual(result['after'],dict(original,port=9123))
   path.write_text('{"port":65535}')
   out=self.run_ps(PORT_HELPERS+"\ntry { Resolve-InstallerPort 8787 $false '"+literal+"'; throw 'unexpected success' } catch { if($_.Exception.Message -notlike '*1 through 65534*'){throw};Write-Output 'REJECTED' }")
   self.assertIn('REJECTED',out)

 def test_no_progress_removal_errors_clearly_and_stops_before_rule_creation(self):
  fixture=POLICY_FIXTURE.replace('$this.Items.RemoveAt($i);return','return')
  fixture=fixture.replace('throw \'fixture worker failed\'','throw')
  fixture=fixture.replace('Set-CouchsideFirewall\n@{left=',"try { Set-CouchsideFirewall;throw 'unexpected success' } catch { if($_.Exception.Message -notlike '*still present*Group Policy*'){throw} }\n@{left=")
  result=json.loads(self.run_ps(HELPERS+fixture).strip().splitlines()[-1])
  self.assertEqual(result['added'],[]);self.assertIn('Couchside Agent',result['left'])

 def test_creation_error_is_not_swallowed_by_offline_fallback(self):
  fixture=POLICY_FIXTURE.replace('ACTIVE','THROW').replace('throw \'fixture worker failed\'','throw')
  fixture=fixture.replace('[void]$script:Added.Add',"throw 'fixture creation denied';[void]$script:Added.Add")
  fixture=fixture.replace('Set-CouchsideFirewall\n@{left=',"try { Set-CouchsideFirewall;throw 'unexpected success' } catch { if($_.Exception.Message -notlike '*fixture creation denied*'){throw} }\n@{left=")
  self.assertEqual(json.loads(self.run_ps(HELPERS+fixture).strip().splitlines()[-1])['added'],[])

 def test_uninstall_removes_rules_even_with_no_firewall_switch(self):
  fixture=POLICY_FIXTURE.replace('$NoFirewall=$false','$NoFirewall=$true').replace('Set-CouchsideFirewall\n','Set-CouchsideFirewall -RemoveOnly\n')
  result=json.loads(self.run_ps(HELPERS+fixture).strip().splitlines()[-1])
  self.assertEqual(result['left'],['Couchside Agent Other','Unrelated']);self.assertEqual(result['added'],[])

 def test_uninstall_continues_file_cleanup_after_firewall_failure(self):
  body=SOURCE[SOURCE.index('function Uninstall-Couchside {'):SOURCE.index('if ($Uninstall) { Uninstall-Couchside; exit 0 }')]
  with tempfile.TemporaryDirectory() as tmp:
   root=Path(tmp);install=root/'agent';install.mkdir();(install/'synthetic.exe').write_text('fixture')
   data=root/'data';data.mkdir();(data/'token').write_text('synthetic token')
   path=lambda p:str(p).replace("'","''")
   prefix="$InstallDir='"+path(install)+"';$DataDir='"+path(data)+"';$StartupLnk='"+path(root/'absent.lnk')+"'\n"
   out=self.run_ps(prefix+"""
$script:stopped=$false;$script:unregistered=$false;$NoFirewall=$true
function Stop-AgentTask { $script:stopped=$true }
function Unregister-ScheduledTask { $script:unregistered=$true }
function Set-CouchsideFirewall { param([switch]$RemoveOnly) if(!$RemoveOnly){throw 'missing removal mode'};throw 'fixture managed rule' }
function Get-CimInstance { return @() }
function Get-ItemProperty { return $null }
"""+body+"""
Uninstall-Couchside
@{stopped=$script:stopped;unregistered=$script:unregistered;filesRemoved=(!(Test-Path $InstallDir));tokenRetained=((Get-Content (Join-Path $DataDir 'token') -Raw) -eq 'synthetic token')} | ConvertTo-Json -Compress
""")
   self.assertIn('fixture managed rule',out)
   self.assertEqual(json.loads(out.strip().splitlines()[-1]),{'stopped':True,'unregistered':True,'filesRemoved':True,'tokenRetained':True})

if __name__=='__main__':unittest.main()
