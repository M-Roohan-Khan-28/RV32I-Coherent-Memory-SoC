param([string]$OutputDir = 'build/coherent-run')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destination = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repo $OutputDir }
if (Test-Path -LiteralPath $destination) { throw "Fresh output directory required: $destination" }
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$result = [ordered]@{
  status = 'NOT RUN'; source_revision = (& git -C $repo rev-parse HEAD).Trim()
  command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_coherent.ps1 -OutputDir <fresh-directory>'
  simulator = ''; compile_exit = $null; simulation_exit = $null
  cases = 0; checks = 0; accepted = 0; completed = 0; aborted = 0
  output_dir = $destination; reason = ''
}
function Invoke-Logged([string]$Executable, [string]$Arguments, [string]$Log) {
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo.FileName = $Executable
  $p.StartInfo.Arguments = $Arguments
  $p.StartInfo.WorkingDirectory = $destination
  $p.StartInfo.UseShellExecute = $false
  $p.StartInfo.RedirectStandardOutput = $true
  $p.StartInfo.RedirectStandardError = $true
  if (-not $p.Start()) { throw "Could not launch $Executable" }
  $stdout = $p.StandardOutput.ReadToEndAsync()
  $stderr = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit(120000)) {
    $p.Kill()
    $p.WaitForExit()
    throw "Timeout after 120 seconds: $Executable $Arguments"
  }
  [System.IO.File]::WriteAllText($Log, $stdout.Result + $stderr.Result)
  return $p.ExitCode
}
try {
  $simDir = if ($env:MODELSIM_BIN) { $env:MODELSIM_BIN } else { 'C:\intelFPGA\20.1\modelsim_ase\win32aloem' }
  foreach ($tool in @('vlib.exe','vlog.exe','vsim.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $simDir $tool))) { throw "Missing simulator tool: $(Join-Path $simDir $tool)" }
  }
  $vlibCode = Invoke-Logged (Join-Path $simDir 'vlib.exe') 'work' (Join-Path $destination 'vlib.log')
  if ($vlibCode -ne 0) { throw "vlib exit $vlibCode" }
  $rtl = Join-Path $repo 'rtl\coherent\coherent_word_memory.sv'
  $tb = Join-Path $repo 'tb\tb_coherent_word_memory.sv'
  $result.compile_exit = Invoke-Logged (Join-Path $simDir 'vlog.exe') "-sv `"$rtl`" `"$tb`"" (Join-Path $destination 'compile.log')
  $compile = Get-Content (Join-Path $destination 'compile.log') -Raw
  $result.simulator = (($compile -split "`r?`n")[0]).Trim()
  if ($result.compile_exit -ne 0 -or $compile -notmatch 'Errors: 0, Warnings: 0') { throw "Compilation failed: exit $($result.compile_exit)" }
  $result.simulation_exit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_coherent_word_memory -do "run -all; quit -f"' (Join-Path $destination 'simulation.log')
  $sim = Get-Content (Join-Path $destination 'simulation.log') -Raw
  if ($result.simulation_exit -ne 0 -or $sim -match '(?i)\*\* Fatal|\*\* Error' -or $sim -notmatch 'Errors: 0, Warnings: 0') { throw "Simulation failed: exit $($result.simulation_exit)" }
  if ($sim -notmatch 'PASS COHERENT cases=(\d+) checks=(\d+) accepted=(\d+) completed=(\d+) aborted=(\d+)') { throw 'Required result marker missing' }
  $result.cases = [int]$Matches[1]; $result.checks = [int]$Matches[2]
  $result.accepted = [int]$Matches[3]; $result.completed = [int]$Matches[4]; $result.aborted = [int]$Matches[5]
  if ($result.cases -lt 63 -or $result.checks -lt 100 -or $result.aborted -ne 1) { throw 'Required test count missing' }
  $result.status = 'PASS'
  $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $destination 'results.json')
  Write-Host "PASS COHERENT cases=$($result.cases) checks=$($result.checks) completed=$($result.completed) source=$($result.source_revision)"
  exit 0
} catch {
  $result.status = 'FAIL'; $result.reason = $_.Exception.Message
  $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $destination 'results.json')
  Write-Error "FAIL COHERENT: $($result.reason)"
  exit 1
}
