# ============================================
# 1C SERVER MANAGER - ULTIMATE EDITION v2.0
# ============================================

# Проверка прав администратора
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges!" -ForegroundColor Red
    Write-Host "Restarting with elevation..." -ForegroundColor Yellow
    
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"" + $MyInvocation.MyCommand.Path + "`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit
}

# ============================================
# ГЛОБАЛЬНЫЕ НАСТРОЙКИ
# ============================================
$Script:LogFile = "C:\1C_Server_Manager.log"
$Script:BackupPath = "C:\1C_Backups"

# Создаем папки для логов и бэкапов
if(-not (Test-Path $Script:BackupPath)) {
    New-Item -ItemType Directory -Force -Path $Script:BackupPath | Out-Null
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

function Test-PortAvailable {
    param([int]$Port)
    
    try {
        $tcpConnection = New-Object System.Net.Sockets.TcpClient
        $tcpConnection.Connect('127.0.0.1', $Port)
        $tcpConnection.Close()
        return $false # Порт занят
    }
    catch {
        return $true # Порт свободен
    }
}

function Get-1CArchitecture {
    param($ExePath)
    
    if(-not (Test-Path $ExePath)) {
        return "unknown"
    }
    
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ExePath)
        $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
        $machine = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
        
        switch ($machine) {
            0x8664 { return "x64" }
            0x14c { return "x86" }
            0xaa64 { return "ARM64" }
            default { return "unknown" }
        }
    }
    catch {
        return "unknown"
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
    
    $platforms = @()
    
    Write-Host "Searching for 1C platforms..." -ForegroundColor Cyan
    Write-Log "Searching for 1C platforms"
    
    foreach($path in $paths){
        if(Test-Path $path){
            Write-Host "  Checking: $path" -ForegroundColor DarkGray
            Get-ChildItem $path -Directory -ErrorAction SilentlyContinue | ForEach-Object{
                $ragent = Join-Path $_.FullName "bin\ragent.exe"
                $ras = Join-Path $_.FullName "bin\ras.exe"
                
                if(Test-Path $ragent){
                    $platforms += [PSCustomObject]@{
                        Version = $_.Name
                        Path = $_.FullName
                        Ragent = $ragent
                        HasRAS = Test-Path $ras
                    }
                    Write-Host "    Found: $($_.Name) (RAS: $(Test-Path $ras))" -ForegroundColor Green
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
# УПРАВЛЕНИЕ СЛУЖБАМИ 1С
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
    
    $services | Select Name, DisplayName, State | Format-Table -AutoSize
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
        Write-Host "-------------------"
    }
}

function Remove-1CServer {
    param($ServiceName)
    
    Write-Host "Stopping service: $ServiceName" -ForegroundColor Yellow
    Write-Log "Stopping service: $ServiceName"
    
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    
    try{
        (Get-Service $ServiceName).WaitForStatus("Stopped","00:00:20")
    } catch {}
    
    sc.exe delete "$ServiceName" | Out-Null
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
            if(-not (Test-PortAvailable -Port ([int]$port))) {
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
        Start-Sleep -Seconds 2
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
        
        $binary = "`"$($platform.Ragent)`" -srvc -agent -port $port -regport $regport -range $rangeStart`:$rangeEnd -d `"$srvinfo`" -debug"
        
        New-Service `
            -Name $serviceName `
            -BinaryPathName $binary `
            -DisplayName $displayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        Start-Sleep -Seconds 3
        Start-Service $serviceName -ErrorAction Stop
        
        Write-Host ""
        Write-Host "Server created successfully" -ForegroundColor Green
        Write-Host "Service name: $serviceName" -ForegroundColor Green
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
    
    if(-not (Test-PortAvailable -Port ([int]$newPort))) {
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
        Stop-Service $srv.Service -Force
        Start-Sleep -Seconds 2
        
        $platform = (Get-1CPlatforms) | Where-Object { $srv.Path -match $_.Version } | Select-Object -First 1
        
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
        
        $binary = "`"$($platform.Ragent)`" -srvc -agent -port $newPort -regport $newRegPort -range $newRangeStart`:$newRangeEnd -d `"$($srv.SrvInfo)`" -debug"
        
        Write-Host "Removing old service..." -ForegroundColor Yellow
        sc.exe delete $srv.Service
        
        Write-Host "Creating new service..." -ForegroundColor Yellow
        New-Service `
            -Name $newServiceName `
            -BinaryPathName $binary `
            -DisplayName $newDisplayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        Start-Sleep -Seconds 2
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
# РАС СЛУЖБЫ (ИСПРАВЛЕННАЯ ВЕРСИЯ)
# ============================================

function Get-RASServices {
    $services = Get-CimInstance Win32_Service | Where-Object {$_.PathName -match "ras\.exe"}
    
    foreach($svc in $services) {
        $rasPort = "unknown"
        if($svc.PathName -match "--port[= ](\d+)") {
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
        
        Add-Member -InputObject $svc -MemberType NoteProperty -Name "RASPort" -Value $rasPort -Force
        Add-Member -InputObject $svc -MemberType NoteProperty -Name "AgentPort" -Value $agentPort -Force
    }
    
    return $services
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
    
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    
    try{
        (Get-Service $ServiceName).WaitForStatus("Stopped","00:00:20")
    } catch {}
    
    sc.exe delete "$ServiceName" | Out-Null
    Write-Host "RAS service deleted: $ServiceName" -ForegroundColor Green
    Write-Log "RAS service deleted: $ServiceName"
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
        
        $selectedServer = $null
        
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
                
                # ============= ВАЖНОЕ ИСПРАВЛЕНИЕ =============
                # Ищем платформу, соответствующую версии выбранного сервера
                $rasPlatform = $platforms | Where-Object { 
                    $_.HasRAS -and $_.Version -eq $selectedServer.Version 
                } | Select-Object -First 1
                
                if(-not $rasPlatform) {
                    Write-Host ""
                    Write-Host "WARNING: No RAS found for version $($selectedServer.Version)!" -ForegroundColor Red
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
                # =============================================
                
            } else {
                Write-Host "Invalid selection, using manual entry" -ForegroundColor Yellow
                $ctrlPort = Read-Host "Enter agent port (default: 1540)"
                if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
                $agentName = Read-Host "Enter agent host (default: localhost)"
                if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
                
                # Если выбрали ручной ввод, используем первую платформу с RAS
                $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
            }
        } else {
            $ctrlPort = Read-Host "Enter agent port (default: 1540)"
            if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
            $agentName = Read-Host "Enter agent host (default: localhost)"
            if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
            
            # Если выбрали ручной ввод, используем первую платформу с RAS
            $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
        }
    } else {
        $ctrlPort = Read-Host "Enter agent port (default: 1540)"
        if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
        $agentName = Read-Host "Enter agent host (default: localhost)"
        if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
        
        $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
    }
    
    if(-not $rasPlatform) {
        Write-Host "No platform with RAS found!" -ForegroundColor Red
        Write-Log "No platform with RAS found" "ERROR"
        return
    }
    
    # Рекомендуем порт RAS = порт агента + 5
    $defaultRasPort = [int]$ctrlPort + 5
    $rasPort = Read-Host "Enter RAS port (default: $defaultRasPort)"
    if([string]::IsNullOrWhiteSpace($rasPort)){ $rasPort = $defaultRasPort.ToString() }
    
    # Проверяем, свободен ли порт
    if(-not (Test-PortAvailable -Port ([int]$rasPort))) {
        Write-Host "Port $rasPort is already in use!" -ForegroundColor Red
        $existingRAS = Get-RASServices | Where-Object { $_.RASPort -eq $rasPort }
        if($existingRAS) {
            Write-Host "Existing RAS service on this port: $($existingRAS.Name)" -ForegroundColor Yellow
            $confirm = Read-Host "Delete existing and recreate? (y/n)"
            if($confirm -eq 'y') {
                $existingRAS | ForEach-Object { Remove-RASService $_.Name }
                Start-Sleep -Seconds 2
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
    
    $serviceShortName = "1C_RAS_$rasPort"
    $serviceDisplayName = "1C:Enterprise 8.3 ($($rasPlatform.Version)) RAS Agent ($arch) (agent:$ctrlPort, ras:$rasPort)"
    
    Write-Host ""
    Write-Host "=== СОЗДАНИЕ RAS СЛУЖБЫ ===" -ForegroundColor Cyan
    Write-Host "Platform version: $($rasPlatform.Version)" -ForegroundColor Green
    Write-Host "Architecture: $arch" -ForegroundColor Gray
    Write-Host "Service name (short): $serviceShortName" -ForegroundColor Green
    Write-Host "Display name: $serviceDisplayName" -ForegroundColor Green
    Write-Host "Agent: $agentName`:$ctrlPort" -ForegroundColor Gray
    Write-Host "RAS port: $rasPort" -ForegroundColor Gray
    Write-Host "RAS path: $rasPath" -ForegroundColor Gray
    
    $confirm = Read-Host "Create RAS service? (y/n)"
    if($confirm -ne 'y') {
        Write-Host "Operation cancelled" -ForegroundColor Yellow
        return
    }
    
    $binary = "`"$rasPath`" cluster --service --port=$rasPort $agentName`:$ctrlPort"
    
    try {
        $oldService = Get-Service -Name $serviceShortName -ErrorAction SilentlyContinue
        if($oldService) {
            Write-Host "Removing existing service..." -ForegroundColor Yellow
            Stop-Service $serviceShortName -Force -ErrorAction SilentlyContinue
            sc.exe delete $serviceShortName
            Start-Sleep -Seconds 2
        }
        
        Write-Host "Creating RAS service..." -ForegroundColor Cyan
        New-Service `
            -Name $serviceShortName `
            -BinaryPathName $binary `
            -DisplayName $serviceDisplayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        Write-Host "Service created successfully" -ForegroundColor Green
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
# МОНИТОРИНГ
# ============================================

function Monitor-1CServers {
    param($RefreshInterval = 5)
    
    Clear-Host
    Write-Host "Monitoring 1C Servers (Press Ctrl+C to stop)" -ForegroundColor Cyan
    Write-Host "Updates every $RefreshInterval seconds" -ForegroundColor Gray
    Write-Host "=" * 50
    Write-Host ""
    
    while($true) {
        Clear-Host
        Write-Host "=== 1C SERVER MONITOR ===" -ForegroundColor Cyan
        Write-Host "Last update: $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray
        Write-Host "Press Ctrl+C to stop monitoring" -ForegroundColor Yellow
        Write-Host ""
        
        $servers = Get-1CServerMap
        
        if(-not $servers) {
            Write-Host "No servers found" -ForegroundColor Yellow
        } else {
            foreach($srv in $servers) {
                $statusColor = if($srv.State -eq "Running") { "Green" } else { "Red" }
                Write-Host "Port $($srv.Port):" -ForegroundColor Yellow
                Write-Host "  Service: $($srv.Service)" -ForegroundColor Gray
                Write-Host "  Status: " -NoNewline
                Write-Host "$($srv.State)" -ForegroundColor $statusColor
                Write-Host "  Version: $($srv.Version)" -ForegroundColor Gray
                Write-Host "  Data dir: $($srv.SrvInfo)" -ForegroundColor DarkGray
                
                if($srv.State -eq "Running") {
                    $portAvailable = Test-PortAvailable -Port ([int]$srv.Port)
                    if($portAvailable) {
                        Write-Host "  Port: NOT RESPONDING!" -ForegroundColor Red
                    } else {
                        Write-Host "  Port: OK" -ForegroundColor Green
                    }
                }
                Write-Host ""
            }
        }
        
        Start-Sleep -Seconds $RefreshInterval
    }
}

# ============================================
# БЭКАП КОНФИГУРАЦИИ
# ============================================

function Backup-1CServerConfig {
    $servers = Get-1CServerMap
    
    if(-not $servers) {
        Write-Host "No servers found" -ForegroundColor Yellow
        return
    }
    
    Write-Host ""
    Write-Host "Select server to backup (or 0 to cancel)"
    Write-Host "========================================"
    
    $i = 1
    foreach($srv in $servers){
        Write-Host "$i) Port $($srv.Port) - $($srv.Version) - State: $($srv.State)"
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
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupDir = Join-Path $Script:BackupPath "1C_Server_$($srv.Port)_$timestamp"
    
    try {
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
        Write-Host "Creating backup in: $backupDir" -ForegroundColor Cyan
        
        $srv | Export-Csv -Path (Join-Path $backupDir "server_info.csv") -NoTypeInformation -Encoding UTF8
        
        $service = Get-WmiObject Win32_Service | Where-Object {$_.Name -eq $srv.Service}
        if($service) {
            $service | Export-Csv -Path (Join-Path $backupDir "service_config.csv") -NoTypeInformation -Encoding UTF8
        }
        
        $regPath = "HKLM:\SOFTWARE\1C\1Cv8\$($srv.Version)"
        if(Test-Path $regPath) {
            reg export "$regPath" (Join-Path $backupDir "registry_backup.reg") /y 2>$null
            Write-Host "Registry settings saved" -ForegroundColor Gray
        }
        
        $logPath = Join-Path $srv.SrvInfo "log"
        if(Test-Path $logPath) {
            Copy-Item -Path $logPath -Destination (Join-Path $backupDir "logs") -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Log files copied" -ForegroundColor Gray
        }
        
        $info = @"
Server Backup Information
=========================
Server Port: $($srv.Port)
Version: $($srv.Version)
Service Name: $($srv.Service)
Data Directory: $($srv.SrvInfo)
Backup Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@
        $info | Out-File -FilePath (Join-Path $backupDir "backup_info.txt") -Encoding UTF8
        
        Write-Host ""
        Write-Host "Backup completed successfully!" -ForegroundColor Green
        Write-Host "Backup location: $backupDir" -ForegroundColor Green
        Write-Log "Backup created for server on port $($srv.Port) at $backupDir"
    }
    catch {
        Write-Host "Error creating backup: $_" -ForegroundColor Red
        Write-Log "Error creating backup: $_" "ERROR"
    }
}

# ============================================
# ФУНКЦИИ РАБОТЫ С ЛОГОМ
# ============================================

function Show-Log {
    if(Test-Path $Script:LogFile) {
        Write-Host ""
        Write-Host "=== LOG FILE ===" -ForegroundColor Cyan
        Write-Host "Last 50 entries:" -ForegroundColor Yellow
        Write-Host ""
        Get-Content $Script:LogFile -Tail 50
    } else {
        Write-Host "Log file not found" -ForegroundColor Yellow
    }
}

function Clear-Log {
    $confirm = Read-Host "Clear log file? (y/n)"
    if($confirm -eq 'y') {
        Remove-Item $Script:LogFile -Force -ErrorAction SilentlyContinue
        Write-Host "Log cleared" -ForegroundColor Green
        Write-Log "Log cleared by user"
    }
}

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================

function Show-MainMenu {
    Clear-Host
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host "     1C SERVER MANAGER ULTIMATE    " -ForegroundColor White
    Write-Host "            v2.0                   " -ForegroundColor DarkGray
    Write-Host "==================================" -ForegroundColor Cyan
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
    Write-Host "=== MONITORING & BACKUP ===" -ForegroundColor Yellow
    Write-Host "11 - Monitor servers"
    Write-Host "12 - Backup server config"
    Write-Host ""
    Write-Host "=== SYSTEM ===" -ForegroundColor Yellow
    Write-Host "13 - Show log"
    Write-Host "14 - Clear log"
    Write-Host ""
    Write-Host "0 - Exit"
    Write-Host ""
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host "At any prompt, enter 0 to cancel" -ForegroundColor Yellow
    Write-Host "Log file: $Script:LogFile" -ForegroundColor DarkGray
    Write-Host "==================================" -ForegroundColor Cyan
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
            Monitor-1CServers
        }
        "12" {
            Clear-Host
            Backup-1CServerConfig
        }
        "13" {
            Clear-Host
            Show-Log
        }
        "14" {
            Clear-Host
            Clear-Log
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
    
    if($choice -ne "0" -and $choice -ne "11"){
        WaitForKeyPress
    }
    
} while ($choice -ne "0")
