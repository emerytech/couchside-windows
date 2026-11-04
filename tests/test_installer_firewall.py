"""Harmless Windows PowerShell worker tests and simulated firewall policy tests."""
import json, os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'install.ps1').read_text(encoding='utf-8-sig')
HELPERS=SOURCE.split('# BEGIN firewall helpers')[1].split('# END firewall helpers')[0]

@unittest.skipUnless(os.name=='nt','Windows PowerShell integration')
class FirewallTests(unittest.TestCase):
 def run_ps(self, code, timeout=30):
  with tempfile.TemporaryDirectory() as tmp:
   path=Path(tmp)/'fixture.ps1';path.write_text("$ErrorActionPreference='Stop'\n"+code,encoding='utf-8-sig')
   env={k:v for k,v in os.environ.items() if k.upper()!='PSMODULEPATH'}
   result=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',str(path)],capture_output=True,text=True,timeout=timeout,env=env)
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
  for active,expected in [('', 'Private'),('Public','Private,Public'),('DomainAuthenticated','Private,Domain')]:
   with self.subTest(active=active):
    out=self.run_ps(HELPERS+'''
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
function Get-NetConnectionProfile { [pscustomobject]@{NetworkCategory='ACTIVE'} }
function New-NetFirewallRule {
 [CmdletBinding()]param($DisplayName,$Direction,$Action,$Protocol,$LocalPort,$RemoteAddress,$Profile,$Program)
 [void]$script:Added.Add(@{name=$DisplayName;direction=$Direction;action=$Action;protocol=$Protocol;port=$LocalPort;remote=$RemoteAddress;profile=$Profile;program=$Program})
}
function Invoke-InstallerWorker {
 param($Code,$Label)
 $Code=$Code.Replace('exit 0','return').Replace('exit 1',"throw 'fixture worker failed'")
 & ([scriptblock]::Create($Code))
}
$NoFirewall=$false;$usePython=$true;$Port=9010
$pyPath="C:\\Fake PC\\unicode-λ\\literal'; not-code.exe"
Set-CouchsideFirewall
@{left=@($rules.Items | ForEach-Object Name); added=@($script:Added)} | ConvertTo-Json -Depth 6 -Compress
'''.replace("NetworkCategory='ACTIVE'",f"NetworkCategory='{active}'"))
    result=json.loads(out.strip().splitlines()[-1]);self.assertEqual(result['left'],['Couchside Agent Other','Unrelated'])
    rules=result['added'];self.assertEqual(len(rules),3)
    self.assertEqual([r['port'] for r in rules],[9010,9011,9010])
    self.assertEqual([r['protocol'] for r in rules],['TCP','TCP','UDP'])
    self.assertEqual([r['profile'] for r in rules],[expected]*3)
    self.assertTrue(all(r['direction']=='Inbound' and r['action']=='Allow' for r in rules))
    self.assertEqual([r['remote'] for r in rules],[None,'LocalSubnet','LocalSubnet'])
    self.assertEqual(rules[2]['program'],"C:\\Fake PC\\unicode-λ\\literal'; not-code.exe")

if __name__=='__main__':unittest.main()
