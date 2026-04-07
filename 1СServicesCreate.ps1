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
                
                if(Test-Path $ragent){
                    $platforms += [PSCustomObject]@{
                        Version = $_.Name
                        Path = $_.FullName
                        Ragent = $ragent
                    }
                    Write-Host "    Found: $($_.Name)" -ForegroundColor Green
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
        Write-Host "$i) $($p.Version) - $($p.Path)" -ForegroundColor Green
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
    
    # Проверка свободного места
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
# MAIN MENU
# ============================================

function Show-MainMenu {
    Clear-Host
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "       1C SERVER MANAGER        " -ForegroundColor White
    Write-Host "           Version 3.0          " -ForegroundColor White
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "1 - Show installed platforms"
    Write-Host "2 - Show 1C services"
    Write-Host "3 - Show 1C server topology"
    Write-Host "4 - Restart 1C service"
    Write-Host "5 - Delete 1C service"
    Write-Host "6 - Create / Recreate 1C server"
    Write-Host ""
    Write-Host "0 - Exit"
    Write-Host ""
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "At any prompt, enter 0 to cancel" -ForegroundColor Yellow
    Write-Host "================================" -ForegroundColor Cyan
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
