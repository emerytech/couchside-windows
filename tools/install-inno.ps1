param([string]$InstallerPath)
$ErrorActionPreference = 'Stop'
$expected = '4D11E8050B6185E0D49BD9E8CC661A7A59F44959A621D31D11033124C4E8A7B0'
$downloaded = -not $InstallerPath
if ($downloaded) {
    $InstallerPath = Join-Path $env:TEMP ('couchside-inno-' + [guid]::NewGuid().ToString('N') + '.exe')
    Invoke-WebRequest 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_1/innosetup-6.7.1.exe' -OutFile $InstallerPath -UseBasicParsing
}
try {
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash -ne $expected) { throw 'Inno Setup SHA256 mismatch' }
    $installDir = Join-Path $env:LOCALAPPDATA 'Couchside-Build-Tools\Inno-6.7.1'
    $args = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /CURRENTUSER /DIR="' + $installDir + '"'
    $proc = Start-Process -FilePath $InstallerPath -ArgumentList $args -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "Inno installation failed: $($proc.ExitCode)" }
    $compiler = Join-Path $installDir 'ISCC.exe'
    # ISCC 6.7.1 has a 0.0.0.0 PE version resource; pin the compiler bytes instead.
    $compilerHash = 'EB6F4410C8DB367A5F74127E8025AD2CCACC0AFABBE783959D237DF3050F97FB'
    if ((Get-FileHash -Algorithm SHA256 $compiler).Hash -ne $compilerHash) { throw 'Unexpected Inno compiler hash' }
    Write-Output $compiler
} finally {
    if ($downloaded) { Remove-Item -LiteralPath $InstallerPath -Force -ErrorAction SilentlyContinue }
}
