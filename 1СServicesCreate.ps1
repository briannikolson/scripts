# ============================================
# 1C SERVER MANAGER
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
# HELPER FUNCTIONS
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

# ============================================
# DISK MANAGEMENT
# ============================================

function Get-AvailableDisks {
    Get-CimInstance Win32_LogicalDisk |
    Where-Object { $_.DriveType -eq 3 } |
    Select-Object DeviceID, FreeSpace
}

function Select-Disk {
    $disks = Get-AvailableDisks
    
    Write-Host ""
    Write-Host "Available disks (or 0 to cancel)"
    Write-Host "================================"
    
    $i = 1
    foreach($disk in $disks){
        $free = [math]::Round($disk.FreeSpace/1GB, 1)
        Write-Host "$i) $($disk.DeviceID)  Free: $free GB"
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
# PLATFORM MANAGEMENT
# ============================================

function Get-1CArchitecture {
    param($ExePath)
    
    try {
        $fs = [System.IO.File]::OpenRead($ExePath)
        $br = New-Object System.IO.BinaryReader($fs)
        
        $fs.Seek(0x3C,'Begin') | Out-Null
        $peOffset = $br.ReadInt32()
        
        $fs.Seek($peOffset+4,'Begin') | Out-Null
        $machine = $br.ReadUInt16()
        
        $fs.Close()
        
        switch ($machine) {
            0x8664 { return "x86-64" }
            0x14c { return "x86" }
            default { return "unknown" }
        }
    }
    catch {
        return "unknown"
    }
}

function Get-1CPlatforms {
    $paths = @(
        "C:\Program Files\1cv8",
        "C:\Program Files (x86)\1cv8",
        "D:\Program Files\1cv8",
        "D:\Program Files (x86)\1cv8"
    )
    
    $platforms = @()
    
    Write-Host "Searching for 1C platforms..." -ForegroundColor Cyan
    
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
# 1C SERVER SERVICES MANAGEMENT
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
        Write-Host "No services found"
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
        Write-Host "No servers found"
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
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    
    try{
        (Get-Service $ServiceName).WaitForStatus("Stopped","00:00:20")
    } catch {}
    
    sc.exe delete "$ServiceName" | Out-Null
    Write-Host "Service deleted: $ServiceName" -ForegroundColor Green
}

function Delete-1CService {
    $servers = Get-1CServerMap
    
    if(!$servers){
        Write-Host "No servers found"
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
    } else {
        Write-Host "Deletion cancelled" -ForegroundColor Yellow
    }
}

function Create-1CService {
    $platforms = Get-1CPlatforms
    
    if(!$platforms){
        Write-Host "No 1C platforms found!" -ForegroundColor Red
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
            $valid = $true
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
        Write-Host "Service name: $serviceName"
        Write-Host "Data directory: $srvinfo"
        Write-Host "Port: $port"
        Write-Host "RegPort: $regport"
        Write-Host "Range: $rangeStart`:$rangeEnd"
    }
    catch {
        Write-Host "Error creating service: $_" -ForegroundColor Red
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
}

# ============================================
# RAS SERVICES MANAGEMENT
# ============================================

function Get-RASServices {
    # Ищем все службы, в пути которых есть ras.exe
    Get-CimInstance Win32_Service |
    Where-Object {$_.PathName -match "ras\.exe"}
}

function Show-RASServices {
    $services = Get-RASServices
    
    Write-Host ""
    Write-Host "RAS Services"
    Write-Host "============"
    
    if(!$services){
        Write-Host "No RAS services found"
        return
    }
    
    foreach($svc in $services) {
        # Извлекаем порт из разных мест
        $port = "unknown"
        
        if($svc.Name -match "(\d+)$") {
            $port = $matches[1]
        }
        elseif($svc.DisplayName -match "ras:(\d+)") {
            $port = $matches[1]
        }
        elseif($svc.PathName -match "--port[= ](\d+)") {
            $port = $matches[1]
        }
        
        # Извлекаем порт агента
        $agentPort = "unknown"
        if($svc.DisplayName -match "agent:(\d+)") {
            $agentPort = $matches[1]
        }
        elseif($svc.PathName -match "(\w+):(\d+)") {
            $agentPort = $matches[2]
        }
        
        Write-Host ""
        Write-Host "Service Name  : $($svc.Name)" -ForegroundColor Green
        Write-Host "Display Name  : $($svc.DisplayName)" -ForegroundColor Gray
        Write-Host "RAS Port      : $port" -ForegroundColor Gray
        Write-Host "Agent Port    : $agentPort" -ForegroundColor Gray
        Write-Host "State         : $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Red"})
        Write-Host "-------------------"
    }
}

function Remove-RASService {
    param($ServiceName)
    
    Write-Host "Stopping RAS service: $ServiceName" -ForegroundColor Yellow
    Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
    
    try{
        (Get-Service $ServiceName).WaitForStatus("Stopped","00:00:20")
    } catch {}
    
    sc.exe delete "$ServiceName" | Out-Null
    Write-Host "RAS service deleted: $ServiceName" -ForegroundColor Green
}

function Create-RASService {
    # Ищем платформу с RAS
    $platforms = Get-1CPlatforms
    $rasPlatform = $platforms | Where-Object { $_.HasRAS } | Select-Object -First 1
    
    if(-not $rasPlatform) {
        Write-Host "No platform with RAS found!" -ForegroundColor Red
        return
    }
    
    # Показываем существующие RAS службы
    $existingRASServices = Get-RASServices
    if($existingRASServices) {
        Write-Host ""
        Write-Host "Existing RAS services found:" -ForegroundColor Yellow
        foreach($svc in $existingRASServices) {
            Write-Host "  - $($svc.Name) ($($svc.State))" -ForegroundColor Gray
        }
        Write-Host ""
    }
    
    # Показываем существующие серверы 1С
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
            } else {
                Write-Host "Invalid selection, using manual entry" -ForegroundColor Yellow
                $ctrlPort = Read-Host "Enter agent port (default: 1540)"
                if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
                $agentName = Read-Host "Enter agent host (default: localhost)"
                if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
            }
        } else {
            $ctrlPort = Read-Host "Enter agent port (default: 1540)"
            if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
            $agentName = Read-Host "Enter agent host (default: localhost)"
            if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
        }
    } else {
        $ctrlPort = Read-Host "Enter agent port (default: 1540)"
        if([string]::IsNullOrWhiteSpace($ctrlPort)){ $ctrlPort = "1540" }
        $agentName = Read-Host "Enter agent host (default: localhost)"
        if([string]::IsNullOrWhiteSpace($agentName)){ $agentName = "localhost" }
    }
    
    $rasPort = Read-Host "Enter RAS port (default: 1545)"
    if([string]::IsNullOrWhiteSpace($rasPort)){ $rasPort = "1545" }
    
    # Проверяем, не занят ли порт RAS
    $existingRAS = Get-RASServices | Where-Object { 
        $_.PathName -match "--port[= ]$rasPort" -or 
        $_.Name -match $rasPort -or 
        $_.DisplayName -match "ras:$rasPort"
    }
    
    if($existingRAS) {
        Write-Host "WARNING: RAS service on port $rasPort already exists!" -ForegroundColor Red
        Write-Host "Existing service: $($existingRAS.Name)" -ForegroundColor Yellow
        $confirm = Read-Host "Delete existing and recreate? (y/n)"
        if($confirm -eq 'y') {
            $existingRAS | ForEach-Object { Remove-RASService $_.Name }
            Start-Sleep -Seconds 2
        } else {
            Write-Host "Operation cancelled" -ForegroundColor Yellow
            return
        }
    }
    
    $rasPath = $rasPlatform.Ragent -replace "ragent.exe", "ras.exe"
    $arch = Get-1CArchitecture $rasPath
    
    # Используем короткое имя для службы (без пробелов)
    $serviceShortName = "1C_RAS_$rasPort"
    # Красивое имя для отображения
    $serviceDisplayName = "1C:Enterprise 8.3 ($($rasPlatform.Version)) RAS Agent ($arch) (agent:$ctrlPort, ras:$rasPort)"
    
    Write-Host ""
    Write-Host "=== СОЗДАНИЕ RAS СЛУЖБЫ ===" -ForegroundColor Cyan
    Write-Host "Platform version: $($rasPlatform.Version)" -ForegroundColor Gray
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
    
    # Команда с привязкой к конкретному агенту
    $binary = "`"$rasPath`" cluster --service --port=$rasPort $agentName`:$ctrlPort"
    
    # Используем PowerShell New-Service вместо sc.exe
    try {
        # Удаляем старую службу если есть
        $oldService = Get-Service -Name $serviceShortName -ErrorAction SilentlyContinue
        if($oldService) {
            Write-Host "Removing existing service..." -ForegroundColor Yellow
            Stop-Service $serviceShortName -Force -ErrorAction SilentlyContinue
            sc.exe delete $serviceShortName
            Start-Sleep -Seconds 2
        }
        
        # Создаем службу через PowerShell
        Write-Host "Creating RAS service..." -ForegroundColor Cyan
        New-Service `
            -Name $serviceShortName `
            -BinaryPathName $binary `
            -DisplayName $serviceDisplayName `
            -StartupType Automatic `
            -ErrorAction Stop
        
        Write-Host "Service created successfully" -ForegroundColor Green
        
        # Запускаем службу
        Write-Host "Starting RAS service..." -ForegroundColor Yellow
        Start-Service -Name $serviceShortName -ErrorAction Stop
        
        Start-Sleep -Seconds 5
        
        # Проверяем статус
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
        if($svc.Name -match "(\d+)$") {
            $port = $matches[1]
        }
        elseif($svc.DisplayName -match "ras:(\d+)") {
            $port = $matches[1]
        }
        else {
            $port = "unknown"
        }
        
        Write-Host "$i) $($svc.Name) - Port: $port - Status: $($svc.State)" -ForegroundColor $(if($svc.State -eq "Running"){"Green"}else{"Yellow"})
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
    
    Write-Host "Stopping service..." -ForegroundColor Yellow
    Stop-Service $selectedService.Name -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    
    Write-Host "Deleting service..." -ForegroundColor Yellow
    sc.exe delete $selectedService.Name 2>$null
    
    Write-Host "RAS service deleted successfully" -ForegroundColor Green
}

# ============================================
# MAIN MENU
# ============================================

function Show-MainMenu {
    Clear-Host
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host "        1C SERVER MANAGER         " -ForegroundColor White
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "=== 1C SERVER SERVICES ===" -ForegroundColor Yellow
    Write-Host " 1 - Show installed platforms"
    Write-Host " 2 - Show 1C services"
    Write-Host " 3 - Show 1C server topology"
    Write-Host " 4 - Restart 1C service"
    Write-Host " 5 - Delete 1C service"
    Write-Host " 6 - Create / Recreate 1C server"
    Write-Host ""
    Write-Host "=== RAS SERVICES ===" -ForegroundColor Yellow
    Write-Host " 7 - Show RAS services"
    Write-Host " 8 - Create RAS service"
    Write-Host " 9 - Delete RAS service"
    Write-Host ""
    Write-Host "0 - Exit"
    Write-Host ""
    Write-Host "==================================" -ForegroundColor Cyan
    Write-Host "At any prompt, enter 0 to cancel" -ForegroundColor Yellow
    Write-Host "==================================" -ForegroundColor Cyan
}

# ============================================
# SCRIPT MAIN LOOP
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
            Show-RASServices 
        }
        "8" { 
            Clear-Host
            Create-RASService 
        }
        "9" { 
            Clear-Host
            Delete-RASService 
        }
        "0" { 
            Clear-Host
            Write-Host "Exiting..." -ForegroundColor Green
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
