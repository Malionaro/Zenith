# Starts everything for working on Zenith in one go: headless Factorio with the bridge mod from this
# checkout (through run-server.ps1, so mod edits apply on each start), waits until the bridge is
# up, then starts the Godot client connected to it. When the client closes, the server is saved
# and stopped. With -Mock the fake game (tools/mock_server.py) stands in for Factorio.
#
#   powershell -ExecutionPolicy Bypass -File server\dev.ps1
#   powershell -ExecutionPolicy Bypass -File server\dev.ps1 -Save C:\path\my-base.zip
#   powershell -ExecutionPolicy Bypass -File server\dev.ps1 -Mock
#   powershell -ExecutionPolicy Bypass -File server\dev.ps1 -NoClient     # server only, waits for Enter
#
# Godot is found from -Godot, then $env:GODOT, then godot / godot4 on the PATH. Factorio as in
# run-server.ps1 (every Steam library, C:\Program Files\Factorio), or -Factorio.
param(
  [string]$Save = "",
  [string]$Factorio = "",
  [string]$Godot = "",
  [int]$UdpPort = 34200,
  [int]$GamePort = 34197,
  [int]$RconPort = 34198,
  [long]$Seed = 0,
  # The fake game instead of Factorio (needs Python); its own options go in -MockArgs.
  [switch]$Mock,
  [string[]]$MockArgs = @(),
  # Start only the server and keep it running until Enter is pressed.
  [switch]$NoClient,
  # Leave the server running after the client closes.
  [switch]$KeepServer,
  # More options for the client, after Godot's `--` (e.g. "--models=C:\my-models").
  [string[]]$ClientArgs = @(),
  [int]$TimeoutSeconds = 180
)
$ErrorActionPreference = "Stop"

$here = $PSScriptRoot
$repo = Split-Path $here -Parent
$data = Join-Path $here "data"
$log = Join-Path $data "factorio-current.log"

function Find-Python {
  foreach ($p in @((Join-Path $repo ".venv\Scripts\python.exe"), "python", "py", "python3")) {
    if ((Test-Path $p) -or (Get-Command $p -ErrorAction SilentlyContinue)) { return $p }
  }
  Write-Error "Python not found (needed for the mock server and to stop the server over RCON)."
}

function Find-Godot {
  if ($Godot -ne "") {
    if (-not (Test-Path $Godot)) { Write-Error "Godot not found at $Godot." }
    return $Godot
  }
  if ($env:GODOT -and (Test-Path $env:GODOT)) { return $env:GODOT }
  foreach ($name in @("godot", "godot4", "Godot", "Godot_v4")) {
    $c = Get-Command $name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
  }
  Write-Error "Godot not found. Pass -Godot 'C:\path\to\Godot_v4.x.exe' or set `$env:GODOT."
}

# Is something listening for UDP on 127.0.0.1:<port> (Factorio's --enable-lua-udp, or the mock)?
function Test-UdpBound([int]$port) {
  try {
    return [bool](Get-NetUDPEndpoint -LocalPort $port -ErrorAction SilentlyContinue)
  } catch {
    return $false
  }
}

# Look the tools up before anything starts, so a missing one stops the script with nothing left running.
$py = Find-Python
$godotExe = if ($NoClient) { $null } else { Find-Godot }

if (Test-UdpBound $UdpPort) {
  Write-Error "Port $UdpPort is already in use (another server or mock?). Stop it, or pass -UdpPort."
}

$server = $null
if ($Mock) {
  Write-Host "Starting the mock server on 127.0.0.1:$UdpPort"
  $margs = @((Join-Path $repo "tools\mock_server.py"), "--port", "$UdpPort") + $MockArgs
  $server = Start-Process -FilePath $py -ArgumentList ($margs | ForEach-Object { '"' + $_ + '"' }) -PassThru -WindowStyle Minimized
} else {
  # A log from the last run would say "Hosting game at" already: start from a fresh one.
  if (Test-Path $log) { Remove-Item $log -Force }
  $sargs = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $here "run-server.ps1"),
    "-UdpPort", "$UdpPort", "-GamePort", "$GamePort", "-RconPort", "$RconPort", "-Seed", "$Seed")
  if ($Save -ne "") { $sargs += @("-Save", $Save) }
  if ($Factorio -ne "") { $sargs += @("-Factorio", $Factorio) }
  Write-Host "Starting headless Factorio with the bridge mod (log: $log)"
  $server = Start-Process -FilePath "powershell" -ArgumentList ($sargs | ForEach-Object { '"' + $_ + '"' }) -PassThru -WindowStyle Minimized
}

# Wait until the bridge's port is open (and, for Factorio, the game is hosted), or give up.
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
  $hosted = $Mock -or ((Test-Path $log) -and (Select-String -Path $log -Pattern "Hosting game at" -Quiet))
  if ($hosted -and (Test-UdpBound $UdpPort)) { $ready = $true; break }
  if ($Mock -and $server.HasExited) { break }
  # run-server.ps1 returns once factorio.exe is started; with no factorio left after that, it failed.
  if (-not $Mock -and $server.HasExited -and -not (Get-Process -Name factorio -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name factorio -ErrorAction SilentlyContinue)) { break }
  }
  Start-Sleep -Milliseconds 500
}

function Stop-Server {
  if ($Mock) {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    return
  }
  # /quit saves the map, as Factorio does when a server quits.
  Write-Host "Saving and stopping the server"
  & $py (Join-Path $repo "tools\rcon.py") /quit 2>$null | Out-Null
}

if (-not $ready) {
  Write-Host "The server didn't come up within $TimeoutSeconds s."
  if (Test-Path $log) { Get-Content $log -Tail 30 }
  Stop-Server
  exit 1
}
Write-Host "Bridge up on 127.0.0.1:$UdpPort"

try {
  if ($NoClient) {
    Read-Host "Server running. Press Enter to stop it"
  } else {
    $cargs = @("--path", (Join-Path $repo "client"), "--", "--factorio-port=$UdpPort") + $ClientArgs
    Write-Host "Starting the client: $godotExe $($cargs -join ' ')"
    $client = Start-Process -FilePath $godotExe -ArgumentList ($cargs | ForEach-Object { '"' + $_ + '"' }) -PassThru
    $client.WaitForExit()
  }
} finally {
  if (-not $KeepServer) { Stop-Server }
}
