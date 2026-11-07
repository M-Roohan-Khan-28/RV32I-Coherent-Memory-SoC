param([string]$OutputDir = 'build/coherent-run')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$destination = if ([System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repo $OutputDir }
if (Test-Path -LiteralPath $destination) { throw "Fresh output directory required: $destination" }
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$result = [ordered]@{
  status = 'NOT RUN'; source_revision = (& git -C $repo rev-parse HEAD).Trim()
  command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_coherent.ps1 -OutputDir <fresh-directory>'
  simulator = ''; compile_exit = $null; simulation_exit = $null; program_simulation_exit = $null; concurrent_simulation_exit = $null
  simulator_version = ''; source_dirty = [bool](@(git -C $repo status --porcelain).Count)
  bridge_simulation_exit = $null; reset_commit_simulation_exit = $null
  shared_store_simulation_exit = $null; shared_read_write_simulation_exit = $null
  bridge_checks = 0; reset_commit_checks = 0; shared_store_checks = 0; shared_read_write_checks = 0
  cases = 0; checks = 0; accepted = 0; completed = 0; aborted = 0; contention_waits = 0
  program_checks = 0; program_accepted = 0; program_completed = 0; program_waits = 0
  concurrent_checks = 0; concurrent_simultaneous = 0; concurrent_busy_waits = 0
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
  $versionExit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-version' (Join-Path $destination 'version.log')
  if ($versionExit -ne 0) { throw "vsim version exit $versionExit" }
  $result.simulator_version = (Get-Content (Join-Path $destination 'version.log') -Raw).Trim()
  $vlibCode = Invoke-Logged (Join-Path $simDir 'vlib.exe') 'work' (Join-Path $destination 'vlib.log')
  if ($vlibCode -ne 0) { throw "vlib exit $vlibCode" }
  $rtl = Join-Path $repo 'rtl\coherent\coherent_word_memory.sv'
  $tb = Join-Path $repo 'tb\tb_coherent_word_memory.sv'
  $sources = @(
    (Join-Path $repo 'rtl\core\alu.sv'), (Join-Path $repo 'rtl\core\reg_file.sv'),
    (Join-Path $repo 'rtl\core\control_unit.sv'), (Join-Path $repo 'rtl\core\rv32i_core.sv'),
    $rtl, (Join-Path $repo 'rtl\coherent\core_request_bridge.sv'),
    $tb, (Join-Path $repo 'tb\tb_two_core_programs.sv'),
    (Join-Path $repo 'tb\tb_two_core_concurrent.sv'),
    (Join-Path $repo 'tb\tb_core_request_bridge.sv'),
    (Join-Path $repo 'tb\tb_coherent_reset_commit.sv'),
    (Join-Path $repo 'tb\tb_two_core_shared.sv'))
  $sourceArgs = ($sources | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $result.compile_exit = Invoke-Logged (Join-Path $simDir 'vlog.exe') "-sv $sourceArgs" (Join-Path $destination 'compile.log')
  $compile = Get-Content (Join-Path $destination 'compile.log') -Raw
  $result.simulator = (($compile -split "`r?`n")[0]).Trim()
  if ($result.compile_exit -ne 0 -or $compile -notmatch 'Errors: 0, Warnings: 0') { throw "Compilation failed: exit $($result.compile_exit)" }
  $result.simulation_exit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_coherent_word_memory -do "run -all; quit -f"' (Join-Path $destination 'simulation.log')
  $sim = Get-Content (Join-Path $destination 'simulation.log') -Raw
  if ($result.simulation_exit -ne 0 -or $sim -match '(?i)\*\* Fatal|\*\* Error' -or $sim -notmatch 'Errors: 0, Warnings: 0' -or $sim -notmatch '\$finish') { throw "Simulation failed: exit $($result.simulation_exit)" }
  if ($sim -notmatch 'PASS COHERENT cases=(\d+) checks=(\d+) accepted=(\d+) completed=(\d+) aborted=(\d+) contention_waits=(\d+)') { throw 'Required result marker missing' }
  $result.cases = [int]$Matches[1]; $result.checks = [int]$Matches[2]
  $result.accepted = [int]$Matches[3]; $result.completed = [int]$Matches[4]; $result.aborted = [int]$Matches[5]
  $result.contention_waits = [int]$Matches[6]
  if ($result.cases -ne 71 -or $result.checks -ne 1477 -or
      $result.aborted -ne 1 -or $result.contention_waits -lt 10) { throw 'Required test count missing' }
  $programExit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_two_core_programs -do "run -all; quit -f"' (Join-Path $destination 'program.log')
  $result.program_simulation_exit = $programExit
  $program = Get-Content (Join-Path $destination 'program.log') -Raw
  if ($programExit -ne 0 -or $program -match '(?i)\*\* Fatal|\*\* Error' -or
      $program -notmatch 'Errors: 0, Warnings: 0' -or $program -notmatch '\$finish') { throw "Two-core program simulation failed: exit $programExit" }
  if ($program -notmatch 'PASS TWO_CORE_PROGRAMS checks=(\d+) accepted=(\d+) completed=(\d+) waits=(\d+)') { throw 'Two-core program result marker missing' }
  $result.program_checks = [int]$Matches[1]; $result.program_accepted = [int]$Matches[2]
  $result.program_completed = [int]$Matches[3]; $result.program_waits = [int]$Matches[4]
  if ($result.program_checks -ne 135 -or $result.program_accepted -ne 6 -or
      $result.program_completed -ne 6 -or $result.program_waits -lt 6) {
      throw 'Two-core program check count missing'
  }
  $concurrentExit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_two_core_concurrent -do "run -all; quit -f"' (Join-Path $destination 'concurrent.log')
  $result.concurrent_simulation_exit = $concurrentExit
  $concurrent = Get-Content (Join-Path $destination 'concurrent.log') -Raw
  if ($concurrentExit -ne 0 -or $concurrent -match '(?i)\*\* Fatal|\*\* Error' -or
      $concurrent -notmatch 'Errors: 0, Warnings: 0' -or $concurrent -notmatch '\$finish') { throw "Concurrent two-core simulation failed: exit $concurrentExit" }
  if ($concurrent -notmatch 'PASS TWO_CORE_CONCURRENT checks=(\d+) accepted=2/2 completed=2/2 simultaneous=(\d+) busy_waits=(\d+)') {
    throw 'Concurrent two-core result marker missing'
  }
  $result.concurrent_checks = [int]$Matches[1]
  $result.concurrent_simultaneous = [int]$Matches[2]
  $result.concurrent_busy_waits = [int]$Matches[3]
  if ($result.concurrent_checks -ne 106 -or $result.concurrent_simultaneous -lt 1 -or
      $result.concurrent_busy_waits -lt 2) { throw 'Concurrent two-core scenarios missing' }
  $result.bridge_simulation_exit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_core_request_bridge -do "run -all; quit -f"' (Join-Path $destination 'bridge.log')
  $bridge = Get-Content (Join-Path $destination 'bridge.log') -Raw
  if ($result.bridge_simulation_exit -ne 0 -or $bridge -match '(?i)\*\* Fatal|\*\* Error' -or
      $bridge -notmatch 'Errors: 0, Warnings: 0' -or $bridge -notmatch '\$finish' -or
      $bridge -notmatch 'BRIDGE_CONTRACT_PASS checks=(\d+) accepted=4 completed=3 aborted=1 stalls=(\d+)') {
    throw 'Bridge contract simulation failed or marker missing'
  }
  $result.bridge_checks = [int]$Matches[1]
  if ($result.bridge_checks -ne 159 -or [int]$Matches[2] -ne 14) { throw 'Bridge contract count missing' }
  $result.reset_commit_simulation_exit = Invoke-Logged (Join-Path $simDir 'vsim.exe') '-c -onfinish exit tb_coherent_reset_commit -do "run -all; quit -f"' (Join-Path $destination 'reset-commit.log')
  $resetCommit = Get-Content (Join-Path $destination 'reset-commit.log') -Raw
  if ($result.reset_commit_simulation_exit -ne 0 -or $resetCommit -match '(?i)\*\* Fatal|\*\* Error' -or
      $resetCommit -notmatch 'Errors: 0, Warnings: 0' -or $resetCommit -notmatch '\$finish' -or
      $resetCommit -notmatch 'RESET_COMMIT_PASS checks=(\d+) accepted=8 completed=5 aborted=3 commits=3 resets=5') {
    throw 'Reset/commit simulation failed or marker missing'
  }
  $result.reset_commit_checks = [int]$Matches[1]
  if ($result.reset_commit_checks -ne 163) { throw 'Reset/commit checks missing' }
  foreach ($mode in @('store_store','read_write')) {
    $extra = if ($mode -eq 'read_write') { '+READ_WRITE ' } else { '' }
    $logName = "shared-$mode.log"
    $runCode = Invoke-Logged (Join-Path $simDir 'vsim.exe') "-c -onfinish exit tb_two_core_shared $extra-do `"run -all; quit -f`"" (Join-Path $destination $logName)
    $shared = Get-Content (Join-Path $destination $logName) -Raw
    if ($runCode -ne 0 -or $shared -match '(?i)\*\* Fatal|\*\* Error' -or
        $shared -notmatch 'Errors: 0, Warnings: 0' -or $shared -notmatch '\$finish' -or
        $shared -notmatch "PASS TWO_CORE_SHARED mode=$mode checks=(\d+) accepted=2/2 completed=2/2 simultaneous=(\d+) busy_waits=(\d+) invalidation_waits=(\d+)") {
      throw "Shared-core $mode simulation failed or marker missing"
    }
    $sharedChecks = [int]$Matches[1]
    if ($sharedChecks -ne 106 -or [int]$Matches[2] -lt 1 -or
        [int]$Matches[3] -lt 2 -or [int]$Matches[4] -lt 1) {
      throw "Shared-core $mode scenario count missing"
    }
    if ($mode -eq 'store_store') {
      $result.shared_store_simulation_exit = $runCode
      $result.shared_store_checks = $sharedChecks
    } else {
      $result.shared_read_write_simulation_exit = $runCode
      $result.shared_read_write_checks = $sharedChecks
    }
  }
  $result.status = 'PASS'
  $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $destination 'results.json')
  Write-Host "PASS COHERENT cases=$($result.cases) checks=$($result.checks) completed=$($result.completed) program_checks=$($result.program_checks) source=$($result.source_revision)"
  exit 0
} catch {
  $result.status = 'FAIL'; $result.reason = $_.Exception.Message
  $result | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $destination 'results.json')
  Write-Error "FAIL COHERENT: $($result.reason)"
  exit 1
}
