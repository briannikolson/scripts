# ============================================
# 1C SERVER MANAGER - ULTIMATE EDITION v28.0
# ============================================

# Проверка прав администратора
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Restarting with elevation..." -ForegroundColor Yellow
    
    $scriptPath = if($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + $scriptPath + "`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}

# ============================================
# ГЛОБАЛЬНЫЕ НАСТРОЙКИ
# ============================================
$Script:LogFile = "C:\1C_Server_Manager.log"

# Проверка возможности записи в лог
try {
    $testLog = New-Item -ItemType File -Path $Script:LogFile -Force -ErrorAction Stop
    $testLog.Delete()
}
catch {
    Write-Host "WARNING: Cannot write to log file: $Script:LogFile" -ForegroundColor Yellow
    $Script:LogFile = "$env:TEMP\1C_Server_Manager.log"
    Write-Host "Using fallback log: $Script:LogFile" -ForegroundColor Yellow
}

# ============================================
# ФУНКЦИИ ЛОГИРОВАНИЯ
# ============================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    try {
        Add-Content -Path $Script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
        # Игнорируем ошибки логирования
    }
}

# ============================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
# ============================================

function WaitForKeyPress {
    Write-Host ""
    Write-Host "Press any key to continue..." -ForegroundColor Cyan
    try {
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }
    catch {
        Write-Host "(Press Enter to continue)" -ForegroundColor Yellow
        $null = Read-Host
    }
}

function Test-PortInUse {
    param(
        [int]$Port,
        [string]$Hostname = "127.0.0.1"
    )
    
    try {
        $tcpConnection = New-Object System.Net.Sockets.TcpClient
        $tcpConnection.Connect($Hostname, $Port)
        $tcpConnection.Close()
        return $true
    }
    catch {
        return $false
    }
}

function Test-AgentConnection {
    param(
        [int]$Port,
        [string]$Hostname = "localhost"
    )
    
    Write-Host ""
    Write-Host "Checking connection to agent on $Hostname`:$Port..." -ForegroundColor Yellow
    
    if(-not (Test-PortInUse -Port $Port -Hostname $Hostname)) {
        Write-Host "ERROR: Agent on port $Port is not responding!" -ForegroundColor Red
        Write-Host ""
        Write-Host "Possible reasons:" -ForegroundColor Yellow
        Write-Host "1. 1C agent service is not running" -ForegroundColor Gray
        Write-Host "2. Wrong port number" -ForegroundColor Gray
        Write-Host "3. Firewall blocking the connection" -ForegroundColor Gray
        return $false
    } else {
        Write-Host "Agent on port $Port is available!" -ForegroundColor Green
        return $true
    }
}

function Get-1CArchitecture {
    param($ExePath)
    
    if(-not (Test-Path $ExePath)) {
        return "unknown"
    }
    
    try {
        $fs = [System.IO.File]::OpenRead($ExePath)
        try {
            $bytes = New-Object byte[] 512
            $fs.Read($bytes, 0, 512) | Out-Null
            
            $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
            if($peOffset -ge 0 -and $peOffset -lt $bytes.Length - 4) {
                $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
                
                switch ($machine) {
                    0x8664 { return "x64" }
                    0x14c { return "x86" }
                    0xaa64 { return "ARM64" }
                    default { return "unknown" }
                }
            }
            return "unknown"
        }
        finally {
            $fs.Close()
        }
    }
    catch {
        Write-Log "Error reading $ExePath`: $_" "ERROR"
        return "unknown"
    }
}

function Stop-ServiceWithTimeout {
    param(
        [string]$ServiceName,
        [int]$Timeout = 30
    )
    
    try {
        $service = Get-Service $ServiceName -ErrorAction SilentlyContinue
        if(-not $service) {
            return $true
        }
        
        if($service.Status -eq "Stopped") {
            return $true
        }
        
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        
        $timeoutDate = (Get-Date).AddSeconds($Timeout)
        while((Get-Date) -lt $timeoutDate -and $service.Status -ne "Stopped") {
            Start-Sleep -Milliseconds 500
            $service.Refresh()
        }
        
        if($service.Status -ne "Stopped") {
            Write-Host "Service $ServiceName is stuck in $($service.Status) state" -ForegroundColor Red
            $serviceProcess = Get-CimInstance Win32_Service | Where-Object { $_.Name -eq $ServiceName }
            if($serviceProcess -and $serviceProcess.ProcessId -gt 0) {
                Write-Host "Attempting to kill process $($serviceProcess.ProcessId)..." -ForegroundColor Yellow
                Stop-Process -Id $serviceProcess.ProcessId -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
            return $false
        }
        return $true
    }
    catch {
        Write-Host "Error stopping service: $_" -ForegroundColor Red
        return $false
    }
}

function Test-WriteAccess {
    param($Path)
    
    try {
        if(-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
        }
        $testFile = Join-Path $Path "test_$(Get-Random).tmp"
        New-Item -ItemType File -Path $testFile -ErrorAction Stop | Out-Null
        Remove-Item $testFile -Force
        return $true
    }
    catch {
        return $false
    }
}

# ============================================
# ДИСКИ
# ============================================

function Get-AvailableDisks {
    Get-CimInstance Win32_LogicalDisk |
    Where-Object { $_.DriveType -eq 3 } |
    Select-Object DeviceID, FreeSpace, Size
}

function Select-Disk {
    $disks = Get-AvailableDisks
    
    Write-Host ""
    Write-Host "Available disks (or 0 to cancel)"
    Write-Host "================================"
    
    $i = 1
    foreach($disk in $disks){
        $free = [math]::Round($disk.FreeSpace/1GB, 1)
        $total = [math]::Round($disk.Size/1GB, 1)
        Write-Host "$i) $($disk.DeviceID)  Free: $free GB / Total: $total GB"
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select disk number"
    
    if($choice -eq "0") {
        return $null
    }
    
    $disk = $disks[$choice-1]
    
    if(!$disk){
        Write-Host "Invalid selection"
        return $null
    }
    
    return $disk.DeviceID.TrimEnd(":")
}

# ============================================
# ПЛАТФОРМЫ 1С
# ============================================

function Get-1CPlatforms {
    $paths = @(
        "C:\Program Files\1cv8",
        "C:\Program Files (x86)\1cv8",
        "D:\Program Files\1cv8",
        "D:\Program Files (x86)\1cv8"
    )
    
    # Поиск в реестре с правильным определением пути
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\1cv8.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\1cv8.exe"
    )
    
    foreach($regPath in $regPaths) {
        if(Test-Path $regPath) {
            try {
                $exePath = (Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue)."(Default)"
                if($exePath -and (Test-Path $exePath)) {
                    $binDir = Split-Path $exePath -Parent
                    $versionDir = Split-Path $binDir -Parent
                    $rootDir = Split-Path $versionDir -Parent
                    
                    if($rootDir -and (Test-Path $rootDir)) {
                        $paths += $rootDir
                        Write-Host "  Found via registry: $rootDir" -ForegroundColor DarkGray
                    }
                }
            }
            catch {
                # Игнорируем ошибки реестра
            }
        }
    }
    
    $platforms = @()
    $uniquePaths = $paths | Select-Object -Unique
    
    Write-Host "Searching for 1C platforms..." -ForegroundColor Cyan
    Write-Log "Searching for 1C platforms"
    
    foreach($path in $uniquePaths){
        if(Test-Path $path){
            Write-Host "  Checking: $path" -ForegroundColor DarkGray
            Get-ChildItem $path -Directory -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
            ForEach-Object{
                $ragent = Join-Path $_.FullName "bin\ragent.exe"
                $ras = Join-Path $_.FullName "bin\ras.exe"
                
                if(Test-Path $ragent){
                    $hasRas = Test-Path $ras
                    $platforms += [PSCustomObject]@{
                        Version = $_.Name
                        Path = $_.FullName
                        Ragent = $ragent
                        HasRAS = $hasRas
                    }
                    Write-Host "    Found: $($_.Name) (RAS: $hasRas)" -ForegroundColor Green
                    Write-Log "Found platform: $($_.Name) at $($_.FullName)"
                }
            }
        }
    }
    
    return $platforms
}

function Show-Platforms {
    $platforms = Get-1CPlatforms
    
    Write-Host ""
    Write-Host "Installed 1C platforms"
    Write-Host "======================"
    
    if(!$platforms){
        Write-Host "No platforms found" -ForegroundColor Red
        Write-Log "No platforms found" "WARN"
        return
    }
    
    $i = 1
    foreach($p in $platforms){
        $rasIcon = if($p.HasRAS) { "[RAS available]" } else { "[No RAS]" }
        Write-Host "$i) $($p.Version) - $($p.Path) $rasIcon" -ForegroundColor Green
        $i++
    }
}

# ============================================
# УПРАВЛЕНИЕ СЛУЖБАМИ 1С (ПУНКТЫ 1-7)
# ============================================

function Get-1CServices {
    Get-CimInstance Win32_Service |
    Where-Object {$_.PathName -match "ragent.exe"}
}

function Show-Services {
    $services = Get-1CServices
    
    Write-Host ""
    Write-Host "1C services"
    Write-Host "==========="
    
    if(!$services){
        Write-Host "No services found" -ForegroundColor Yellow
        Write-Log "No 1C services found" "WARN"
        return
    }
    
    $services | Select Name, DisplayName, State, Description | Format-Table -AutoSize
}

function Get-1CServerMap {
    $services = Get-1CServices
    $servers = @()
    
    foreach($svc in $services){
        $path = $svc.PathName
        $port = $null
        $regport = $null
        $range = $null
        $version = $null
        $srvinfo = $null
        
        if($path -match "-port\s+(\d+)"){ $port = $matches[1] }
        if($path -match "-regport\s+(\d+)"){ $regport = $matches[1] }
        if($path -match "-range\s+([\d:]+)"){ $range = $matches[1] }
        if($path -match "1cv8\\([\d\.]+)\\bin"){ $version = $matches[1] }
        if($path -match '-d\s+"([^"]+)"'){ $srvinfo = $matches[1] }
        
        $servers += [PSCustomObject]@{
            Service = $svc.Name
            Version = $version
            Port = $port
            RegPort = $regport
            Range = $range
            SrvInfo = $srvinfo
            State = $svc.State
            Path = $path
            Description = $svc.Description
        }
    }
    
    return $servers
}

function Show-ServerMap {
    $servers = Get-1CServerMap
    
    Write-Host ""
    Write-Host "1C SERVER TOPOLOGY"
    Write-Host "=================="
    
    if(!$servers){
        Write-Host "No servers found" -ForegroundColor Yellow
        Write-Log "No servers found" "WARN"
        return
    }
    
    foreach($srv in $servers){
        Write-Host ""
        Write-Host "Service     : $($srv.Service)"
        Write-Host "Server Port : $($srv.Port)"
        Write-Host "Version     : $($srv.Version)"
        Write-Host "RegPort     : $($srv.RegPort)"
        Write-Host "Range       : $($srv.Range)"
        Write-Host "SrvInfo     : $($srv.SrvInfo)"
        Write-Host "State       : $($srv.State)"
        Write-Host "Description : $($srv.Description)"
        Write-Host "-------------------"
    }
}

function Remove-1CServer {
    param($ServiceName)
    
    Write-Host "Stopping service: $ServiceName" -ForegroundColor Yellow
    Write-Log "Stopping service: $ServiceName"
    
    if(-not (Stop-ServiceWithTimeout -ServiceName $ServiceName -Timeout 30)) {
        Write-Host "WARNING: Service may not have stopped cleanly" -ForegroundColor Yellow
    }
    
    sc.exe delete "$ServiceName" | Out-Null
    Start-Sleep -Seconds 3
    
    $checkService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if($checkService) {
        Write-Host "Service still exists, forcing removal..." -ForegroundColor Yellow
        sc.exe delete $ServiceName | Out-Null
        Start-Sleep -Seconds 5
    }
    
    Write-Host "Service deleted: $ServiceName" -ForegroundColor Green
    Write-Log "Service deleted: $ServiceName"
}

function Delete-1CService {
    $servers = Get-1CServerMap
    
    if(!$servers){
        Write-Host "No servers found" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "Select server to delete (or 0 to cancel)"
    Write-Host "========================================"
    
    $i = 1
    foreach($srv in $servers){
        Write-Host "$i) Port $($srv.Port) Version $($srv.Version) - $($srv.State)"
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select number"
    
    if($choice -eq "0") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $srv = $servers[$choice-1]
    
    if(!$srv){
        Write-Host "Invalid selection"
        return
    }
    
    $confirm = Read-Host "Delete server on port $($srv.Port)? (y/n)"
    if($confirm -eq 'y'){
        Remove-1CServer $srv.Service
        Write-Log "Server on port $($srv.Port) deleted by user"
    } else {
        Write-Host "Deletion cancelled" -ForegroundColor Yellow
    }
}

function Create-1CService {
    $platforms = Get-1CPlatforms
    
    if(!$platforms){
        Write-Host "No 1C platforms found!" -ForegroundColor Red
        Write-Log "No 1C platforms found for service creation" "ERROR"
        return
    }
    
    Write-Host ""
    Write-Host "Select 1C platform (or 0 to cancel)"
    Write-Host "==================================="
    
    $i = 1
    foreach($p in $platforms){
        Write-Host "$i) $($p.Version) - $($p.Path)"
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select platform"
    
    if($choice -eq "0") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $platform = $platforms[$choice-1]
    
    if(!$platform){
        Write-Host "Invalid selection"
        return
    }
    
    do {
        $port = Read-Host "Enter port (1540-1640 typical range) (or 0 to cancel)"
        
        if($port -eq "0") {
            Write-Host "Operation cancelled" -ForegroundColor Yellow
            return
        }
        
        if($port -notmatch '^\d+$' -or [int]$port -lt 1 -or [int]$port -gt 65535){
            Write-Host "Invalid port number" -ForegroundColor Red
            $valid = $false
        } else {
            if(Test-PortInUse -Port ([int]$port)) {
                Write-Host "Port $port is already in use!" -ForegroundColor Red
                $valid = $false
            } else {
                $valid = $true
            }
        }
    } while (-not $valid)
    
    $existing = Get-1CServerMap | Where-Object {$_.Port -eq $port}
    
    if($existing){
        Write-Host ""
        Write-Host "Server with port $port already exists." -ForegroundColor Yellow
        $confirm = Read-Host "Recreate? (y/n)"
        if($confirm -ne 'y'){ 
            Write-Host "Operation cancelled" -ForegroundColor Yellow
            return 
        }
        Remove-1CServer $existing.Service
        Start-Sleep -Seconds 5
    }
    
    $disk = Select-Disk
    
    if(!$disk){
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $srvinfo = "$disk`:\1CServer\$($platform.Version)_$port"
    
    $diskInfo = Get-AvailableDisks | Where-Object {$_.DeviceID -eq "$disk`:"}
    $freeGB = [math]::Round($diskInfo.FreeSpace/1GB, 1)
    
    if($freeGB -lt 10){
        Write-Host "Warning: Only $freeGB GB free on disk $disk" -ForegroundColor Yellow
        $confirm = Read-Host "Continue anyway? (y/n)"
        if($confirm -ne 'y'){ 
            Write-Host "Operation cancelled" -ForegroundColor Yellow
            return 
        }
    }
    
    if(-not (Test-WriteAccess -Path "$disk`:\")) {
        Write-Host "No write access to disk $disk`:" -ForegroundColor Red
        return
    }
    
    try {
        New-Item -ItemType Directory -Force -Path $srvinfo | Out-Null
        Write-Host "Created directory: $srvinfo"
        Write-Log "Created directory: $srvinfo"
        
        $regport = [int]$port + 1
        $rangeStart = [int]$port + 20
        $rangeEnd = [int]$port + 51
        
        $arch = Get-1CArchitecture $platform.Ragent
        $serviceName = "1C:Enterprise 8.3 Server Agent ($arch) $port"
        $displayName = "1C:Enterprise 8.3 ($($platform.Version)) Server Agent ($arch) ($port)"
        $serviceDescription = "1C:Enterprise 8.3 Server Agent ($arch) Parameters: port: $port, regport: $regport, range: $rangeStart`:$rangeEnd, data: $srvinfo"
        
        $binary = "`"$($platform.Ragent)`" -srvc -agent -port $port -regport $regport -range $rangeStart`:$rangeEnd -d `"$srvinfo`" -debug"
        
        New-Service `
            -Name $serviceName `
            -BinaryPathName $binary `
            -DisplayName $displayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        sc.exe description $serviceName "`"$serviceDescription`""
        Write-Host "Service description set: $serviceDescription" -ForegroundColor DarkGray
        
        Start-Sleep -Seconds 3
        Start-Service $serviceName -ErrorAction Stop
        
        Write-Host ""
        Write-Host "Server created successfully" -ForegroundColor Green
        Write-Host "Service name: $serviceName" -ForegroundColor Green
        Write-Host "Display name: $displayName" -ForegroundColor Gray
        Write-Host "Description: $serviceDescription" -ForegroundColor DarkGray
        Write-Host "Data directory: $srvinfo" -ForegroundColor Gray
        Write-Host "Port: $port" -ForegroundColor Gray
        Write-Host "RegPort: $regport" -ForegroundColor Gray
        Write-Host "Range: $rangeStart`:$rangeEnd" -ForegroundColor Gray
        
        Write-Log "Server created: $serviceName on port $port"
    }
    catch {
        Write-Host "Error creating service: $_" -ForegroundColor Red
        Write-Log "Error creating service: $_" "ERROR"
    }
}

function Restart-1CService {
    $servers = Get-1CServerMap
    
    if(!$servers){
        Write-Host "No servers found"
        return
    }
    
    Write-Host ""
    Write-Host "Select server to restart (or 0 to cancel)"
    Write-Host "========================================="
    
    $i = 1
    foreach($srv in $servers){
        Write-Host "$i) Port $($srv.Port) - State: $($srv.State)"
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select number"
    
    if($choice -eq "0") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $srv = $servers[$choice-1]
    
    if(!$srv){
        Write-Host "Invalid selection"
        return
    }
    
    Restart-Service $srv.Service -Force
    Write-Host "Service restarted" -ForegroundColor Green
    Write-Log "Service restarted: $($srv.Service)"
}

function Change-1CServerPort {
    $servers = Get-1CServerMap
    
    if(-not $servers) {
        Write-Host "No servers found" -ForegroundColor Red
        return
    }
    
    Write-Host ""
    Write-Host "Select server to change port (or 0 to cancel)"
    Write-Host "============================================="
    
    $i = 1
    foreach($srv in $servers){
        Write-Host "$i) Port $($srv.Port) - Version $($srv.Version) - State: $($srv.State)" -ForegroundColor $(if($srv.State -eq "Running"){"Green"}else{"Yellow"})
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select number"
    
    if($choice -eq "0") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $srv = $servers[$choice-1]
    if(-not $srv) {
        Write-Host "Invalid selection" -ForegroundColor Red
        return
    }
    
    Write-Host "Current server configuration:" -ForegroundColor Cyan
    Write-Host "  Service: $($srv.Service)" -ForegroundColor Gray
    Write-Host "  Port: $($srv.Port)" -ForegroundColor Gray
    Write-Host "  RegPort: $($srv.RegPort)" -ForegroundColor Gray
    Write-Host "  Data dir: $($srv.SrvInfo)" -ForegroundColor Gray
    
    $newPort = Read-Host "Enter new port (current: $($srv.Port))"
    if(-not ($newPort -match '^\d+$' -and [int]$newPort -gt 0 -and [int]$newPort -le 65535)) {
        Write-Host "Invalid port number" -ForegroundColor Red
        return
    }
    
    if(Test-PortInUse -Port ([int]$newPort)) {
        Write-Host "Port $newPort is already in use!" -ForegroundColor Red
        return
    }
    
    $confirm = Read-Host "Change port from $($srv.Port) to $newPort? (y/n)"
    if($confirm -ne 'y') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    try {
        Write-Host "Stopping service..." -ForegroundColor Yellow
        Stop-ServiceWithTimeout -ServiceName $srv.Service -Timeout 30
        
        $platforms = Get-1CPlatforms
        $platform = $null
        foreach($p in $platforms) {
            if($srv.Path -match "\\$($p.Version)\\") {
                $platform = $p
                break
            }
        }
        
        if(-not $platform) {
            Write-Host "Platform not found!" -ForegroundColor Red
            return
        }
        
        $newRegPort = [int]$newPort + 1
        $newRangeStart = [int]$newPort + 20
        $newRangeEnd = [int]$newPort + 51
        
        $arch = Get-1CArchitecture $platform.Ragent
        $newServiceName = "1C:Enterprise 8.3 Server Agent ($arch) $newPort"
        $newDisplayName = "1C:Enterprise 8.3 ($($platform.Version)) Server Agent ($arch) ($newPort)"
        $serviceDescription = "1C:Enterprise 8.3 Server Agent ($arch) Parameters: port: $newPort, regport: $newRegPort, range: $newRangeStart`:$newRangeEnd, data: $($srv.SrvInfo)"
        
        $binary = "`"$($platform.Ragent)`" -srvc -agent -port $newPort -regport $newRegPort -range $newRangeStart`:$newRangeEnd -d `"$($srv.SrvInfo)`" -debug"
        
        Write-Host "Removing old service..." -ForegroundColor Yellow
        sc.exe delete $srv.Service
        Start-Sleep -Seconds 5
        
        $checkService = Get-Service -Name $srv.Service -ErrorAction SilentlyContinue
        if($checkService) {
            Write-Host "Service still exists, forcing removal..." -ForegroundColor Yellow
            sc.exe delete $srv.Service
            Start-Sleep -Seconds 5
        }
        
        Write-Host "Creating new service..." -ForegroundColor Yellow
        New-Service `
            -Name $newServiceName `
            -BinaryPathName $binary `
            -DisplayName $newDisplayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        sc.exe description $newServiceName "`"$serviceDescription`""
        Write-Host "Service description set: $serviceDescription" -ForegroundColor DarkGray
        
        Start-Sleep -Seconds 3
        Start-Service $newServiceName -ErrorAction Stop
        
        Write-Host ""
        Write-Host "Port changed successfully!" -ForegroundColor Green
        Write-Host "New service name: $newServiceName" -ForegroundColor Green
        Write-Host "New port: $newPort" -ForegroundColor Gray
        Write-Host "New regport: $newRegPort" -ForegroundColor Gray
        
        Write-Log "Port changed from $($srv.Port) to $newPort for service $newServiceName"
    }
    catch {
        Write-Host "Error changing port: $_" -ForegroundColor Red
        Write-Log "Error changing port: $_" "ERROR"
    }
}

# ============================================
# РАС СЛУЖБЫ (ПУНКТЫ 8-10)
# ============================================

function Get-RASServices {
    $services = Get-CimInstance Win32_Service | Where-Object {$_.PathName -match "ras\.exe"}
    
    $result = @()
    foreach($svc in $services) {
        $rasPort = "unknown"
        if($svc.PathName -match "--ras-port[= ](\d+)") {
            $rasPort = $matches[1]
        }
        elseif($svc.PathName -match "--port[= ](\d+)") {
            $rasPort = $matches[1]
        }
        elseif($svc.PathName -match ":(\d+)(?=\s|$)") {
            $rasPort = $matches[1]
        }
        elseif($svc.Name -match "(\d+)$") {
            $rasPort = $matches[1]
        }
        
        $agentPort = "unknown"
        if($svc.DisplayName -match "agent:(\d+)") {
            $agentPort = $matches[1]
        }
        elseif($svc.PathName -match "(\w+):(\d+)") {
            $agentPort = $matches[2]
        }
        
        $svc | Add-Member -MemberType NoteProperty -Name "RASPort" -Value $rasPort -Force
        $svc | Add-Member -MemberType NoteProperty -Name "AgentPort" -Value $agentPort -Force
        $result += $svc
    }
    
    return $result
}

function Show-RASServices {
    $services = Get-RASServices
    
    Write-Host ""
    Write-Host "RAS Services"
    Write-Host "============"
    
    if(!$services){
        Write-Host "No RAS services found" -ForegroundColor Yellow
        return
    }
    
    foreach($svc in $services) {
        Write-Host ""
        Write-Host "Service Name  : $($svc.Name)" -ForegroundColor Green
        Write-Host "Display Name  : $($svc.DisplayName)" -ForegroundColor Gray
        Write-Host "Description   : $($svc.Description)" -ForegroundColor DarkGray
        Write-Host "RAS Port      : $($svc.RASPort)" -ForegroundColor Gray
        Write-Host "Agent Port    : $($svc.AgentPort)" -ForegroundColor Gray
        Write-Host "State         : $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Red"})
        Write-Host "Path          : $($svc.PathName)" -ForegroundColor DarkGray
        Write-Host "-------------------"
    }
}

function Remove-RASService {
    param($ServiceName)
    
    Write-Host "Stopping RAS service: $ServiceName" -ForegroundColor Yellow
    Write-Log "Stopping RAS service: $ServiceName"
    
    if(-not (Stop-ServiceWithTimeout -ServiceName $ServiceName -Timeout 30)) {
        Write-Host "WARNING: Service may not have stopped cleanly" -ForegroundColor Yellow
    }
    
    sc.exe delete "$ServiceName" | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "RAS service deleted: $ServiceName" -ForegroundColor Green
    Write-Log "RAS service deleted: $ServiceName"
}

function Get-RASPlatformByAgent {
    param(
        [string]$AgentPort,
        [array]$Platforms,
        [array]$Servers
    )
    
    $matchingServer = $Servers | Where-Object { $_.Port -eq $AgentPort } | Select-Object -First 1
    
    if($matchingServer) {
        $rasPlatform = $Platforms | Where-Object { 
            $_.HasRAS -and $_.Version -eq $matchingServer.Version 
        } | Select-Object -First 1
        
        if($rasPlatform) {
            Write-Host "Found RAS version: $($rasPlatform.Version) (matches agent version $($matchingServer.Version))" -ForegroundColor Green
            return $rasPlatform
        } else {
            Write-Host "WARNING: No RAS found for version $($matchingServer.Version)" -ForegroundColor Red
            Write-Host "Available RAS versions:" -ForegroundColor Yellow
            $Platforms | Where-Object { $_.HasRAS } | ForEach-Object {
                Write-Host "  - $($_.Version)" -ForegroundColor Gray
            }
            return $null
        }
    } else {
        Write-Host "No server found on port $AgentPort" -ForegroundColor Yellow
        return $null
    }
}

function Create-RASService {
    $platforms = Get-1CPlatforms
    
    if(-not $platforms) {
        Write-Host "No 1C platforms found!" -ForegroundColor Red
        Write-Log "No 1C platforms found" "ERROR"
        return
    }
    
    $existingRASServices = Get-RASServices
    if($existingRASServices) {
        Write-Host ""
        Write-Host "Existing RAS services found:" -ForegroundColor Yellow
        foreach($svc in $existingRASServices) {
            Write-Host "  - $($svc.Name) (RAS Port: $($svc.RASPort), State: $($svc.State))" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    $servers = Get-1CServerMap
    $rasPlatform = $null
    $ctrlPort = $null
    $agentName = "localhost"
    
    if($servers) {
        Write-Host ""
        Write-Host "Available 1C servers (agents):" -ForegroundColor Cyan
        $i = 1
        foreach($srv in $servers) {
            Write-Host "$i) Port $($srv.Port) - Version $($srv.Version) - State: $($srv.State)" -ForegroundColor $(if($srv.State -eq "Running"){"Green"}else{"Yellow"})
            $i++
        }
        Write-Host ""
        $useExisting = Read-Host "Connect to existing server? (y/n) (n - manual entry)"
        
        if($useExisting -eq 'y') {
            $srvChoice = Read-Host "Select server number (or 0 to cancel)"
            if($srvChoice -eq "0") {
                Write-Host "Operation cancelled" -ForegroundColor Yellow
                return
            }
            $selectedServer = $servers[$srvChoice-1]
            if($selectedServer) {
                $ctrlPort = $selectedServer.Port
                $agentName = "localhost"
                Write-Host "Will connect to agent on port: $ctrlPort" -ForegroundColor Green
                
                if(-not (Test-AgentConnection -Port ([int]$ctrlPort) -Hostname $agentName)) {
                    return
                }
                
                $rasPlatform = $platforms | Where-Object { 
                    $_.HasRAS -and $_.Version -eq $selectedServer.Version 
                } | Select-Object -First 1
                
                if(-not $rasPlatform) {
                    Write-Host ""
                    Write-Host "ERROR: No RAS found for version $($selectedServer.Version)!" -ForegroundColor Red
                    Write-Host "Available RAS versions:" -ForegroundColor Yellow
                    $platforms | Where-Object { $_.HasRAS } | ForEach-Object {
                        Write-Host "  - $($_.Version)" -ForegroundColor Gray
                    }
                    
                    $useFallback = Read-Host "Use first available RAS version instead? (y/n)"
                    if($useFallback -eq 'y') {
                        $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
                        Write-Host "Using fallback RAS version: $($rasPlatform.Version)" -ForegroundColor Yellow
                    } else {
                        Write-Host "Operation cancelled" -ForegroundColor Yellow
                        return
                    }
                } else {
                    Write-Host "Using RAS version: $($rasPlatform.Version) (matches agent)" -ForegroundColor Green
                }
            } else {
                Write-Host "Invalid selection, using manual entry" -ForegroundColor Yellow
                $ctrlPort = Read-Host "Enter agent port (default: 1540)"
                if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
                $agentName = Read-Host "Enter agent host (default: localhost)"
                if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
                
                if(-not (Test-AgentConnection -Port ([int]$ctrlPort) -Hostname $agentName)) {
                    return
                }
                
                $rasPlatform = Get-RASPlatformByAgent -AgentPort $ctrlPort -Platforms $platforms -Servers $servers
                
                if(-not $rasPlatform) {
                    $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
                    Write-Host "Using first available RAS: $($rasPlatform.Version)" -ForegroundColor Yellow
                }
            }
        } else {
            $ctrlPort = Read-Host "Enter agent port (default: 1540)"
            if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
            $agentName = Read-Host "Enter agent host (default: localhost)"
            if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
            
            if(-not (Test-AgentConnection -Port ([int]$ctrlPort) -Hostname $agentName)) {
                return
            }
            
            $rasPlatform = Get-RASPlatformByAgent -AgentPort $ctrlPort -Platforms $platforms -Servers $servers
            
            if(-not $rasPlatform) {
                $useFallback = Read-Host "Use first available RAS version? (y/n)"
                if($useFallback -eq 'y') {
                    $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
                    Write-Host "Using fallback RAS version: $($rasPlatform.Version)" -ForegroundColor Yellow
                } else {
                    Write-Host "Operation cancelled" -ForegroundColor Yellow
                    return
                }
            }
        }
    } else {
        $ctrlPort = Read-Host "Enter agent port (default: 1540)"
        if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
        $agentName = Read-Host "Enter agent host (default: localhost)"
        if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
        
        if(-not (Test-AgentConnection -Port ([int]$ctrlPort) -Hostname $agentName)) {
            return
        }
        
        $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
        
        if(-not $rasPlatform) {
            Write-Host "No platform with RAS found!" -ForegroundColor Red
            Write-Log "No platform with RAS found" "ERROR"
            return
        }
        Write-Host "Using first available RAS: $($rasPlatform.Version)" -ForegroundColor Yellow
    }
    
    if(-not $rasPlatform) {
        Write-Host "No platform with RAS found!" -ForegroundColor Red
        Write-Log "No platform with RAS found" "ERROR"
        return
    }
    
    $defaultRasPort = [int]$ctrlPort + 5
    $rasPort = Read-Host "Enter RAS port (default: $defaultRasPort)"
    if([string]::IsNullOrWhiteSpace($rasPort)){ $rasPort = $defaultRasPort.ToString() }
    
    if(Test-PortInUse -Port ([int]$rasPort)) {
        Write-Host "Port $rasPort is already in use!" -ForegroundColor Red
        $existingRAS = Get-RASServices | Where-Object { $_.RASPort -eq $rasPort }
        if($existingRAS) {
            Write-Host "Existing RAS service on this port: $($existingRAS.Name)" -ForegroundColor Yellow
            $confirm = Read-Host "Delete existing and recreate? (y/n)"
            if($confirm -eq 'y') {
                $existingRAS | ForEach-Object { Remove-RASService $_.Name }
                Start-Sleep -Seconds 5
            } else {
                Write-Host "Operation cancelled" -ForegroundColor Yellow
                return
            }
        } else {
            Write-Host "Port is occupied by another application" -ForegroundColor Red
            return
        }
    }
    
    $rasPath = $rasPlatform.Ragent -replace "ragent.exe", "ras.exe"
    $arch = Get-1CArchitecture $rasPath
    
    $binary = "`"$rasPath`" cluster --service --ras-port=$rasPort $agentName`:$ctrlPort"
    
    $serviceShortName = "1C_RAS_$($rasPlatform.Version)_agent$ctrlPort"
    $serviceDisplayName = "1C:Enterprise 8.3 ($($rasPlatform.Version)) RAS Agent ($arch) (agent:$ctrlPort, ras:$rasPort)"
    $serviceDescription = "1C:Enterprise 8.3 RAS Agent ($arch) Parameters: ras-port: $rasPort, monitored server: $agentName`:$ctrlPort"
    
    Write-Host ""
    Write-Host "=== СОЗДАНИЕ RAS СЛУЖБЫ ===" -ForegroundColor Cyan
    Write-Host "Platform version: $($rasPlatform.Version)" -ForegroundColor Green
    Write-Host "Architecture: $arch" -ForegroundColor Gray
    Write-Host "Service name (short): $serviceShortName" -ForegroundColor Green
    Write-Host "Display name: $serviceDisplayName" -ForegroundColor Green
    Write-Host "Description: $serviceDescription" -ForegroundColor Gray
    Write-Host "Agent: $agentName`:$ctrlPort" -ForegroundColor Green
    Write-Host "Agent status: Available ✓" -ForegroundColor Green
    Write-Host "RAS port: $rasPort" -ForegroundColor Gray
    Write-Host "RAS path: $rasPath" -ForegroundColor Gray
    Write-Host "Command: $binary" -ForegroundColor DarkGray
    
    Write-Host ""
    Write-Host "Enter credentials for RAS service:" -ForegroundColor Yellow
    $useLocalSystem = Read-Host "Use LocalSystem account? (y/n) (default: y)"
    if($useLocalSystem -eq 'n') {
        $rasUserName = Read-Host "Enter username (format: DOMAIN\username or .\username)"
        $rasUserPwd = Read-Host "Enter password" -AsSecureString
        $rasUserPwdPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($rasUserPwd))
    } else {
        $rasUserName = "LocalSystem"
        $rasUserPwdPlain = ""
    }
    
    $confirm = Read-Host "Create RAS service? (y/n)"
    if($confirm -ne 'y') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    try {
        $oldService = Get-Service -Name $serviceShortName -ErrorAction SilentlyContinue
        if($oldService) {
            Write-Host "Removing existing service..." -ForegroundColor Yellow
            Stop-Service $serviceShortName -Force -ErrorAction SilentlyContinue
            sc.exe delete $serviceShortName
            Start-Sleep -Seconds 5
        }
        
        Write-Host "Creating RAS service..." -ForegroundColor Cyan
        
        $newServiceParams = @{
            Name = $serviceShortName
            BinaryPathName = $binary
            DisplayName = $serviceDisplayName
            StartupType = "Automatic"
            ErrorAction = "Stop"
        }
        
        if($rasUserName -ne "LocalSystem") {
            $newServiceParams.Credential = [PSCredential]::new($rasUserName, (ConvertTo-SecureString $rasUserPwdPlain -AsPlainText -Force))
        }
        
        New-Service @newServiceParams
        
        sc.exe description $serviceShortName "`"$serviceDescription`""
        Write-Host "Service description set: $serviceDescription" -ForegroundColor DarkGray
        
        Write-Log "RAS service created: $serviceShortName on port $rasPort"
        
        Write-Host "Starting RAS service..." -ForegroundColor Yellow
        Start-Service -Name $serviceShortName -ErrorAction Stop
        
        Start-Sleep -Seconds 5
        
        $service = Get-Service -Name $serviceShortName -ErrorAction SilentlyContinue
        if($service -and $service.Status -eq "Running") {
            Write-Host ""
            Write-Host "RAS service started successfully!" -ForegroundColor Green
            Write-Host "Service name: $serviceShortName" -ForegroundColor Green
            Write-Host "Display name: $serviceDisplayName" -ForegroundColor Gray
            Write-Host "Description: $serviceDescription" -ForegroundColor DarkGray
            Write-Host "Connected to agent: $agentName`:$ctrlPort" -ForegroundColor Gray
            
            $portCheck = netstat -ano | Select-String $rasPort | Select-String "LISTENING"
            if($portCheck) {
                Write-Host "Port $rasPort is listening: OK" -ForegroundColor Green
            } else {
                Write-Host "Port $rasPort is NOT listening" -ForegroundColor Red
            }
        } else {
            Write-Host "Service created but not running. Status: $($service.Status)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Error creating service: $_" -ForegroundColor Red
        Write-Log "Error creating RAS service: $_" "ERROR"
        
        Write-Host ""
        Write-Host "Try creating service manually:" -ForegroundColor Cyan
        if($rasUserName -ne "LocalSystem") {
            Write-Host "  sc create `"$serviceShortName`" binPath= `"$binary`" start= auto obj= `"$rasUserName`" password= `"****`" displayname= `"$serviceDisplayName`"" -ForegroundColor Gray
            Write-Host "  sc description $serviceShortName `"$serviceDescription`"" -ForegroundColor Gray
        } else {
            Write-Host "  sc create `"$serviceShortName`" binPath= `"$binary`" start= auto displayname= `"$serviceDisplayName`"" -ForegroundColor Gray
            Write-Host "  sc description $serviceShortName `"$serviceDescription`"" -ForegroundColor Gray
        }
        Write-Host "  Start-Service $serviceShortName" -ForegroundColor Gray
    }
}

function Delete-RASService {
    $rasServices = Get-RASServices
    
    if(-not $rasServices) {
        Write-Host "No RAS services found" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "=== УДАЛЕНИЕ RAS СЛУЖБЫ ===" -ForegroundColor Cyan
    Write-Host "Select RAS service to delete (or 0 to cancel):" -ForegroundColor Yellow
    
    $i = 1
    foreach($svc in $rasServices) {
        Write-Host "$i) $($svc.Name) - RAS Port: $($svc.RASPort) - Status: $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Yellow"})
        $i++
    }
    Write-Host "0) Return to main menu"
    
    $choice = Read-Host "Select number"
    
    if($choice -eq "0") {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $selectedService = $rasServices[$choice-1]
    
    if(-not $selectedService) {
        Write-Host "Invalid selection"
        return
    }
    
    $confirm = Read-Host "Delete service '$($selectedService.Name)'? (y/n)"
    if($confirm -ne 'y') {
        Write-Host "Deletion cancelled" -ForegroundColor Yellow
        return
    }
    
    Remove-RASService $selectedService.Name
}

# ============================================
# ПОЛУЧЕНИЕ ИНФОРМАЦИОННЫХ БАЗ ИЗ ФАЙЛА (ПУНКТ 12)
# ============================================

function Find-1CV8ClstFiles {
    $allFiles = @()
    
    Write-Host "Searching for 1CV8Clst.lst files from running services..." -ForegroundColor Yellow
    
    $services = Get-1CServices
    
    if(-not $services -or $services.Count -eq 0) {
        Write-Host "No 1C services running!" -ForegroundColor Red
        Write-Host "Cannot find cluster files without active services" -ForegroundColor Yellow
        return $allFiles
    }
    
    Write-Host "Found $($services.Count) 1C service(s)" -ForegroundColor Green
    Write-Host ""
    
    $foundAny = $false
    
    foreach($svc in $services) {
        Write-Host "  Service: $($svc.DisplayName)" -ForegroundColor Cyan
        Write-Host "    State: $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Red"})
        
        if($svc.PathName -match '-d\s+"([^"]+)"') {
            $dataDir = $matches[1]
            Write-Host "    Data directory: $dataDir" -ForegroundColor Yellow
            
            if(-not (Test-Path $dataDir)) {
                Write-Host "    Warning: Directory does not exist!" -ForegroundColor Red
                Write-Host ""
                continue
            }
            
            Write-Host "    Searching in reg_* folders..." -ForegroundColor DarkGray
            
            try {
                $regDirs = Get-ChildItem -Path $dataDir -Directory -Filter "reg_*" -Recurse -ErrorAction SilentlyContinue
                
                if(-not $regDirs) {
                    Write-Host "    No reg_* folders found" -ForegroundColor Yellow
                    Write-Host ""
                    continue
                }
                
                Write-Host "    Found $($regDirs.Count) reg_* folder(s)" -ForegroundColor DarkGray
                
                foreach($regDir in $regDirs) {
                    $clusterFile = Join-Path $regDir.FullName "1CV8Clst.lst"
                    
                    if(Test-Path $clusterFile) {
                        Write-Host "      Found: $clusterFile" -ForegroundColor Green
                        $allFiles += [System.IO.FileInfo]::new($clusterFile)
                        $foundAny = $true
                    }
                }
            }
            catch {
                Write-Host "    Error searching: $_" -ForegroundColor Red
            }
        } else {
            Write-Host "    No data directory (-d) found in service parameters" -ForegroundColor Yellow
        }
        
        Write-Host ""
    }
    
    if(-not $foundAny) {
        Write-Host "No 1CV8Clst.lst files found in any service data directory" -ForegroundColor Yellow
    }
    
    $allFiles = $allFiles | Select-Object -Unique
    
    Write-Host ""
    Write-Host "Total files found: $($allFiles.Count)" -ForegroundColor Cyan
    
    return $allFiles
}

function Get-InfobasesFromClusterFile {
    $clusterFiles = Find-1CV8ClstFiles
    
    if(-not $clusterFiles -or $clusterFiles.Count -eq 0) {
        Write-Host "No 1CV8Clst.lst files found!" -ForegroundColor Red
        return $null
    }
    
    Write-Host ""
    Write-Host "Found $($clusterFiles.Count) cluster file(s)" -ForegroundColor Green
    Write-Host ""
    
    $allInfobases = @()
    $totalFiles = $clusterFiles.Count
    $fileIndex = 0
    
    foreach($file in $clusterFiles) {
        $fileIndex++
        Write-Host "[$fileIndex/$totalFiles] Reading: $($file.FullName)" -ForegroundColor DarkGray
        
        try {
            $content = $null
            $contentBytes = $null
            $encodings = @(
                [System.Text.Encoding]::UTF8,
                [System.Text.Encoding]::GetEncoding(1251),
                [System.Text.Encoding]::Default,
                [System.Text.Encoding]::ASCII
            )
            
            $contentBytes = [System.IO.File]::ReadAllBytes($file.FullName)
            
            foreach($enc in $encodings) {
                try {
                    $content = $enc.GetString($contentBytes)
                    if($content -and ($content -match 'DB=' -or $content -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')) {
                        Write-Host "    Using encoding: $($enc.EncodingName)" -ForegroundColor DarkGray
                        break
                    }
                }
                catch {
                    continue
                }
            }
            
            if(-not $content) {
                Write-Host "    Failed to read file content" -ForegroundColor Red
                continue
            }
            
            $pattern = '\{([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}),\s*"([^"]*)",\s*"([^"]*)",\s*"([^"]*)",\s*"([^"]*)",\s*"([^"]*)",'
            $matches = [regex]::Matches($content, $pattern)
            
            $dbMatches = @()
            $foundGuids = @()
            
            foreach($match in $matches) {
                $guid = $match.Groups[1].Value
                $name = $match.Groups[2].Value
                $description = $match.Groups[3].Value
                $dbms = $match.Groups[4].Value
                $dbServer = $match.Groups[5].Value
                $dbName = $match.Groups[6].Value
                
                if([string]::IsNullOrWhiteSpace($dbms) -or $dbms -eq "0") {
                    continue
                }
                
                if($name -match '^\d+$') {
                    continue
                }
                
                if($name -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
                    continue
                }
                
                $invalidNames = @(
                    "Локальный кластер", "Local cluster",
                    "Центральный сервер", "Central server",
                    "Главный менеджер кластера", "Cluster manager",
                    "Главный сервер", "Master server"
                )
                
                $isInvalid = $false
                foreach($invalidName in $invalidNames) {
                    if($name -eq $invalidName) {
                        $isInvalid = $true
                        break
                    }
                    if($dbName -eq $invalidName) {
                        $isInvalid = $true
                        break
                    }
                }
                
                if($isInvalid) {
                    continue
                }
                
                if($dbms -eq "Unknown" -or [string]::IsNullOrWhiteSpace($dbms)) {
                    continue
                }
                
                if($foundGuids -notcontains $guid) {
                    $foundGuids += $guid
                    
                    $infobase = [PSCustomObject]@{
                        ID = $guid
                        Name = $name
                        DBMS = $dbms
                        DBServer = $dbServer
                        DBName = $dbName
                        SourceFile = $file.FullName
                    }
                    
                    $allInfobases += $infobase
                    $dbMatches += $infobase
                }
            }
            
            Write-Host "    Found $($dbMatches.Count) DB= reference(s)" -ForegroundColor DarkGray
            
            $foundCount = 0
            foreach($infobase in $dbMatches) {
                $foundCount++
                Write-Host "      Found: $($infobase.Name) (DB: $($infobase.DBName), DBMS: $($infobase.DBMS), Server: $($infobase.DBServer))" -ForegroundColor Green
            }
            
            if($foundCount -gt 0) {
                Write-Host "    Found $foundCount infobase(s)" -ForegroundColor Green
            } else {
                Write-Host "    No infobases found in this file" -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "  Error reading file: $_" -ForegroundColor Red
            Write-Log "Error reading cluster file $($file.FullName): $_" "ERROR"
        }
    }
    
    $uniqueInfobases = @()
    $seenIds = @()
    foreach($ib in $allInfobases) {
        if($seenIds -notcontains $ib.ID) {
            $uniqueInfobases += $ib
            $seenIds += $ib.ID
        }
    }
    
    return $uniqueInfobases
}

function Show-InfobasesFromFile {
    Write-Host ""
    Write-Host "Searching for infobases in cluster files..." -ForegroundColor Cyan
    
    $infobases = Get-InfobasesFromClusterFile
    
    if(-not $infobases -or $infobases.Count -eq 0) {
        Write-Host ""
        Write-Host "No infobases found in cluster files" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "Total unique infobases found: $($infobases.Count)" -ForegroundColor Cyan
    Write-Host ""
}

# ============================================
# ПОЛУЧЕНИЕ ИНФОРМАЦИОННЫХ БАЗ ЧЕРЕЗ RAS (ПУНКТ 11)
# ============================================

function Get-RACPath {
    $platforms = Get-1CPlatforms
    $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
    
    if(-not $rasPlatform) {
        Write-Host "Platform with RAS not found!" -ForegroundColor Red
        return $null
    }
    
    $racPath = $rasPlatform.Ragent -replace "ragent.exe", "rac.exe"
    
    if(-not (Test-Path $racPath)) {
        Write-Host "RAC executable not found: $racPath" -ForegroundColor Red
        return $null
    }
    
    return $racPath
}

function Get-InfobasesFromRAS {
    param(
        [string]$RASPort = "1545",
        [string]$Server = "localhost"
    )
    
    $racPath = Get-RACPath
    if(-not $racPath) {
        return $null
    }
    
    try {
        Write-Host "Connecting to RAS port $RASPort..." -ForegroundColor Gray
        
        if(-not (Test-PortInUse -Port ([int]$RASPort) -Hostname $Server)) {
            Write-Host "Port $RASPort is not responding, skipping..." -ForegroundColor Red
            return $null
        }
        
        $clusterCommands = @(
            "cluster list --port=$RASPort $Server",
            "cluster list $Server`:$RASPort"
        )
        
        $clustersOutput = $null
        foreach($cmd in $clusterCommands) {
            $cmdParts = $cmd.Split(' ')
            $testOutput = & $racPath $cmdParts 2>&1
            if($LASTEXITCODE -eq 0 -and $testOutput -match "cluster") {
                $clustersOutput = $testOutput
                break
            }
        }
        
        if(-not $clustersOutput) {
            Write-Host "No clusters found on port $RASPort" -ForegroundColor Yellow
            return $null
        }
        
        if($clustersOutput -is [array]) {
            $outputString = $clustersOutput -join "`n"
        } else {
            $outputString = $clustersOutput.ToString()
        }
        
        $guidPattern = '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'
        $clusterMatches = [regex]::Matches($outputString, $guidPattern)
        
        if($clusterMatches.Count -eq 0) {
            Write-Host "No cluster IDs found on port $RASPort" -ForegroundColor Yellow
            return $null
        }
        
        $allInfobases = @()
        
        foreach($match in $clusterMatches) {
            $clusterId = $match.Value
            
            $infobaseCommands = @(
                "infobase summary list --port=$RASPort $Server --cluster=$clusterId",
                "infobase summary list $Server`:$RASPort --cluster=$clusterId"
            )
            
            $infobasesOutput = $null
            foreach($cmd in $infobaseCommands) {
                $cmdParts = $cmd.Split(' ')
                $testOutput = & $racPath $cmdParts 2>&1
                if($LASTEXITCODE -eq 0) {
                    $infobasesOutput = $testOutput
                    break
                }
            }
            
            if(-not $infobasesOutput) {
                continue
            }
            
            if($infobasesOutput -is [array]) {
                $infobasesString = $infobasesOutput -join "`n"
            } else {
                $infobasesString = $infobasesOutput.ToString()
            }
            
            if($infobasesString -match "infobase" -and $infobasesString -notmatch "No infobases found") {
                $infobaseLines = $infobasesString -split "`n"
                $currentInfobase = @{}
                $infobaseId = $null
                
                foreach($line in $infobaseLines) {
                    if($line -match "^\s*infobase\s*:\s*([a-f0-9\-]+)") {
                        if($currentInfobase.Count -gt 0 -and $infobaseId) {
                            $currentInfobase["infobase"] = $infobaseId
                            $currentInfobase["cluster"] = $clusterId
                            $allInfobases += $currentInfobase
                        }
                        $infobaseId = $matches[1]
                        $currentInfobase = @{}
                    }
                    elseif($line -match "^\s*(name|descr)\s*:\s*(.+)$") {
                        $key = $matches[1].Trim()
                        $value = $matches[2].Trim()
                        $currentInfobase[$key] = $value
                    }
                }
                
                if($currentInfobase.Count -gt 0 -and $infobaseId) {
                    $currentInfobase["infobase"] = $infobaseId
                    $currentInfobase["cluster"] = $clusterId
                    $allInfobases += $currentInfobase
                }
            }
        }
        
        $enhancedInfobases = @()
        foreach($infobase in $allInfobases) {
            $infobaseId = $infobase["infobase"]
            $clusterId = $infobase["cluster"]
            
            $detailCommands = @(
                "infobase info --port=$RASPort $Server --cluster=$clusterId --infobase=$infobaseId",
                "infobase info $Server`:$RASPort --cluster=$clusterId --infobase=$infobaseId"
            )
            
            $detailOutput = $null
            foreach($cmd in $detailCommands) {
                $cmdParts = $cmd.Split(' ')
                $testOutput = & $racPath $cmdParts 2>&1
                if($LASTEXITCODE -eq 0) {
                    $detailOutput = $testOutput
                    break
                }
            }
            
            if($detailOutput) {
                if($detailOutput -is [array]) {
                    $detailString = $detailOutput -join "`n"
                } else {
                    $detailString = $detailOutput.ToString()
                }
                
                $detailLines = $detailString -split "`n"
                foreach($line in $detailLines) {
                    if($line -match "^\s*(dbms|db-server|db-name|security-level|sessions-deny|scheduled-jobs-deny|license-distribution)\s*:\s*(.+)$") {
                        $key = $matches[1].Trim()
                        $value = $matches[2].Trim()
                        $infobase[$key] = $value
                    }
                }
            }
            
            $enhancedInfobases += $infobase
        }
        
        if($enhancedInfobases.Count -gt 0) {
            return $enhancedInfobases
        }
        
        return $null
    }
    catch {
        Write-Host ("Error on port {0}: {1}" -f $RASPort, $_) -ForegroundColor Red
        return $null
    }
}

function Show-InfobasesViaRAS {
    $rasServices = Get-RASServices
    
    if(-not $rasServices) {
        Write-Host "No RAS services found!" -ForegroundColor Red
        Write-Host "Please create RAS service first (option 9)" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "=== ВЫБОР RAS СЛУЖБЫ ===" -ForegroundColor Cyan
    Write-Host ""
    
    $i = 1
    foreach($svc in $rasServices) {
        Write-Host "$i) $($svc.Name) - RAS Port: $($svc.RASPort) - Status: $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Yellow"})
        $i++
    }
    Write-Host "$i) ALL RAS services (search all)" -ForegroundColor Cyan
    Write-Host "0) Return"
    
    $choice = Read-Host "Select number"
    if($choice -eq "0") {
        return
    }
    
    Clear-Host
    Write-Host ""
    Write-Host "=== ИНФОРМАЦИОННЫЕ БАЗЫ (ЧЕРЕЗ RAS) ===" -ForegroundColor Cyan
    
    if($choice -eq $rasServices.Count + 1) {
        Write-Host "Searching all RAS services..." -ForegroundColor Gray
        
        $allPorts = @()
        foreach($svc in $rasServices) {
            if($svc.RASPort -and $svc.RASPort -ne "unknown") {
                $allPorts += $svc.RASPort
            }
        }
        $allPorts = $allPorts | Select-Object -Unique
        
        $allInfobases = @()
        foreach($port in $allPorts) {
            Write-Host ""
            Write-Host "Checking RAS port: $port" -ForegroundColor Yellow
            $result = Get-InfobasesFromRAS -RASPort $port
            if($result) {
                $allInfobases += $result
            }
        }
        
        if($allInfobases.Count -gt 0) {
            Write-Host ""
            Write-Host "Infobases found:" -ForegroundColor Green
            Write-Host ""
            
            $idx = 1
            foreach($item in $allInfobases) {
                if($item -is [hashtable]) {
                    $name = if($item["name"]) { $item["name"] } else { $item["infobase"] }
                    $descr = if($item["descr"]) { $item["descr"] } else { "" }
                    $dbms = if($item["dbms"]) { $item["dbms"] } else { "Unknown" }
                    $dbServer = if($item["db-server"]) { $item["db-server"] } else { "N/A" }
                    $dbName = if($item["db-name"]) { $item["db-name"] } else { "N/A" }
                    $securityLevel = if($item["security-level"]) { $item["security-level"] } else { "N/A" }
                    $sessionsDeny = if($item["sessions-deny"]) { $item["sessions-deny"] } else { "N/A" }
                    $infobaseId = $item["infobase"]
                    
                    Write-Host "$idx) " -NoNewline -ForegroundColor Yellow
                    Write-Host "$name" -ForegroundColor Green
                    Write-Host "   ID: $infobaseId" -ForegroundColor Gray
                    if($descr) {
                        Write-Host "   Description: $descr" -ForegroundColor Gray
                    }
                    Write-Host "   DBMS: $dbms" -ForegroundColor Cyan
                    Write-Host "   DB Server: $dbServer" -ForegroundColor Cyan
                    Write-Host "   DB Name: $dbName" -ForegroundColor Cyan
                    Write-Host "   Security Level: $securityLevel" -ForegroundColor Yellow                    Write-Host "   Sessions Deny: $sessionsDeny" -ForegroundColor $(if($sessionsDeny -eq "on"){"Red"}else{"Green"})
                    Write-Host ""
                    $idx++
                }
            }
        } else {
            Write-Host "No infobases found" -ForegroundColor Yellow
        }
    } else {
        $selectedService = $rasServices[$choice-1]
        if(-not $selectedService) {
            Write-Host "Invalid selection" -ForegroundColor Red
            return
        }
        
        if($selectedService.State -ne "Running") {
            Write-Host "RAS service is not running!" -ForegroundColor Red
            $start = Read-Host "Start it? (y/n)"
            if($start -eq 'y') {
                Start-Service $selectedService.Name
                Start-Sleep -Seconds 3
            } else {
                return
            }
        }
        
        Write-Host "RAS: localhost:$($selectedService.RASPort)" -ForegroundColor Gray
        $result = Get-InfobasesFromRAS -RASPort $selectedService.RASPort
        
        if($result) {
            Write-Host ""
            Write-Host "Infobases found:" -ForegroundColor Green
            Write-Host ""
            
            $idx = 1
            foreach($item in $result) {
                if($item -is [hashtable]) {
                    $name = if($item["name"]) { $item["name"] } else { $item["infobase"] }
                    $descr = if($item["descr"]) { $item["descr"] } else { "" }
                    $dbms = if($item["dbms"]) { $item["dbms"] } else { "Unknown" }
                    $dbServer = if($item["db-server"]) { $item["db-server"] } else { "N/A" }
                    $dbName = if($item["db-name"]) { $item["db-name"] } else { "N/A" }
                    $securityLevel = if($item["security-level"]) { $item["security-level"] } else { "N/A" }
                    $sessionsDeny = if($item["sessions-deny"]) { $item["sessions-deny"] } else { "N/A" }
                    $infobaseId = $item["infobase"]
                    
                    Write-Host "$idx) " -NoNewline -ForegroundColor Yellow
                    Write-Host "$name" -ForegroundColor Green
                    Write-Host "   ID: $infobaseId" -ForegroundColor Gray
                    if($descr) {
                        Write-Host "   Description: $descr" -ForegroundColor Gray
                    }
                    Write-Host "   DBMS: $dbms" -ForegroundColor Cyan
                    Write-Host "   DB Server: $dbServer" -ForegroundColor Cyan
                    Write-Host "   DB Name: $dbName" -ForegroundColor Cyan
                    Write-Host "   Security Level: $securityLevel" -ForegroundColor Yellow
                    Write-Host "   Sessions Deny: $sessionsDeny" -ForegroundColor $(if($sessionsDeny -eq "on"){"Red"}else{"Green"})
                    Write-Host ""
                    $idx++
                }
            }
        } else {
            Write-Host "No infobases found" -ForegroundColor Yellow
        }
    }
}

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================

function Show-MainMenu {
    Clear-Host
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "     1C SERVER MANAGER ULTIMATE            " -ForegroundColor White
    Write-Host "            v28.0                         " -ForegroundColor DarkGray
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "=== 1C SERVER SERVICES ===" -ForegroundColor Yellow
    Write-Host " 1 - Show installed platforms"
    Write-Host " 2 - Show 1C services"
    Write-Host " 3 - Show 1C server topology"
    Write-Host " 4 - Restart 1C service"
    Write-Host " 5 - Delete 1C service"
    Write-Host " 6 - Create / Recreate 1C server"
    Write-Host " 7 - Change server port"
    Write-Host ""
    Write-Host "=== RAS SERVICES ===" -ForegroundColor Yellow
    Write-Host " 8 - Show RAS services"
    Write-Host " 9 - Create RAS service"
    Write-Host "10 - Delete RAS service"
    Write-Host ""
    Write-Host "=== INFO BASES ===" -ForegroundColor Yellow
    Write-Host "11 - Show infobases via RAS"
    Write-Host "12 - Show infobases from cluster file"
    Write-Host ""
    Write-Host "0 - Exit"
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "At any prompt, enter 0 to cancel" -ForegroundColor Yellow
    Write-Host "Log file: $Script:LogFile" -ForegroundColor DarkGray
    Write-Host "==========================================" -ForegroundColor Cyan
}

# ============================================
# ОСНОВНОЙ ЦИКЛ
# ============================================

do {
    Show-MainMenu
    
    $choice = Read-Host "Select option"
    
    switch($choice){
        "1" { 
            Clear-Host
            Show-Platforms
        }
        "2" { 
            Clear-Host
            Show-Services 
        }
        "3" { 
            Clear-Host
            Show-ServerMap 
        }
        "4" { 
            Clear-Host
            Restart-1CService 
        }
        "5" { 
            Clear-Host
            Delete-1CService 
        }
        "6" { 
            Clear-Host
            Create-1CService 
        }
        "7" {
            Clear-Host
            Change-1CServerPort
        }
        "8" { 
            Clear-Host
            Show-RASServices 
        }
        "9" { 
            Clear-Host
            Create-RASService 
        }
        "10" { 
            Clear-Host
            Delete-RASService 
        }
        "11" {
            Clear-Host
            Show-InfobasesViaRAS
        }
        "12" {
            Clear-Host
            Show-InfobasesFromFile
        }
        "0" { 
            Clear-Host
            Write-Host "Exiting..." -ForegroundColor Green
            Write-Log "Script exited by user"
            break 
        }
        default { 
            Clear-Host
            Write-Host "Invalid option. Please try again." -ForegroundColor Red
        }
    }
    
    if($choice -ne "0"){
        WaitForKeyPress
    }
    
} while ($choice -ne "0")
