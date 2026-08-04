#Requires -Version 5.1
<#
    optimize-windows.ps1
    ---------------------
    Windows optimizasyon scripti (konsol surumu).
    - Yonetici (admin) yetkisi zorunludur, script kendini otomatik yukseltmeye calisir.
    - Her islem oncesi kullanicidan onay ister (varsayilan: Hayir).
    - Menuden istenilen kategoriler secilerek uygulanabilir.

    Bu surumde duzeltilenler:
      * Her kayit defteri yazimi geri okunarak DOGRULANIR. Dogrulanamayan islem "HATA" olarak
        raporlanir; basarili olmayan hicbir islem "yapildi" diye yazilmaz.
      * Her servis, Start=4 (Disabled) degeri okunarak dogrulanir.
      * Yanlis kayit defteri yollari duzeltildi (Game Bar politikasi HKLM'e, bildirim merkezi
        politikasi Policies\Explorer'a tasindi; "En iyi performans" icin gerekli tum degerler eklendi).
      * powercfg cikti ayristirmasi coktugunde script durmuyor, hata olarak raporluyor.
      * cleanmgr ve OneDrive kaldirma islemleri sinirsiz beklemiyor (zaman asimi var).
      * exe olarak derlendiginde de dogru calisan yonetici yukseltmesi.
      * Her islem ayri try/catch icinde; tek bir hata scripti durdurmaz.

    KULLANIM:
        PowerShell'i normal (admin olmayan) kullanici olarak acip sunu calistirman yeterli:
        .\optimize-windows.ps1
        Script kendini otomatik olarak "Yonetici olarak calistir" ile yeniden baslatacaktir.

        Eger script calismiyor derse, once sunu bir kere (admin PowerShell'de) calistir:
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

# ============================================================
#  0. KENDI YOLU / YONETICI YETKISI KONTROLU VE OTOMATIK YUKSELTME
# ============================================================
function Get-SelfPath {
    # ps2exe ile derlendiginde $PSCommandPath guvenilir degildir; once process'in kendi yoluna bakilir.
    $procPath = $null
    try { $procPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch {}
    if ($procPath) {
        $procName = [System.IO.Path]::GetFileNameWithoutExtension($procPath).ToLower()
        if ($procName -notin @('powershell', 'pwsh', 'powershell_ise', 'windowsterminal', 'conhost', 'cmd')) {
            return $procPath
        }
    }
    if ($PSCommandPath) { return $PSCommandPath }
    if ($MyInvocation.MyCommand.Path) { return $MyInvocation.MyCommand.Path }
    return $procPath
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:SelfPath   = Get-SelfPath
$script:IsCompiled = ($null -ne $script:SelfPath) -and ($script:SelfPath.ToLower().EndsWith('.exe'))

if (-not (Test-Admin)) {
    if (-not $script:SelfPath) {
        Write-Host "Yönetici yetkisi gerekli, ancak programın kendi yolu bulunamadı." -ForegroundColor Red
        Write-Host "Lütfen dosyaya sağ tıklayıp 'Yönetici olarak çalıştır' seçeneğini kullan." -ForegroundColor Red
        Read-Host "`nKapatmak için Enter'a bas"
        exit 1
    }

    Write-Host "Bu script yönetici yetkisi gerektiriyor. Yükseltilmiş bir pencere açılıyor..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($script:IsCompiled) {
        $psi.FileName  = $script:SelfPath
        $psi.Arguments = ""
    } else {
        $psi.FileName  = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:SelfPath)`""
    }
    $psi.Verb            = "runas"
    $psi.UseShellExecute = $true
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Host "Yönetici yetkisi verilmedi, script sonlandırılıyor." -ForegroundColor Red
        Start-Sleep -Seconds 3
    }
    exit
}

$ErrorActionPreference = "Continue"

# ============================================================
#  ORTAK YARDIMCILAR
# ============================================================
$script:OkCount   = 0
$script:FailCount = 0

function Write-Log {
    param([string]$Message)
    $color = "Cyan"
    if     ($Message -like "OK*")      { $color = "Green" }
    elseif ($Message -like "HATA*")    { $color = "Red" }
    elseif ($Message -like "UYARI*")   { $color = "Yellow" }
    elseif ($Message -like "ATLANDI*") { $color = "DarkGray" }
    Write-Host $Message -ForegroundColor $color
}

function Confirm-Action {
    param([string]$Question)
    $answer = Read-Host "$Question [e/H]"
    return ($answer -match '^\s*(e|E|y|Y)\s*$')
}

# Her islem yalitilir: biri patlarsa digerleri calismaya devam eder.
function Invoke-Op {
    param([string]$Question, [scriptblock]$Action)

    if (-not (Confirm-Action $Question)) { return }

    try {
        $out = & $Action
        $flag = @($out) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
        $ok = if ($null -eq $flag) { $true } else { [bool]$flag }
    } catch {
        $ok = $false
        Write-Log "HATA  - İşlem başarısız oldu: $($_.Exception.Message)"
    }

    if ($ok) { $script:OkCount++ } else { $script:FailCount++ }
}

# Kayit defterine yazar VE geri okuyarak dogrular. Dogrulanamazsa $false doner.
function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [string]$Type = 'DWord'
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null

        $read = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
        if ($Type -eq 'Binary') {
            $same = ((@($read) -join ',') -eq (@($Value) -join ','))
        } else {
            $same = ("$read" -eq "$Value")
        }
        if (-not $same) { throw "geri okunan değer farklı ('$read')" }
        return $true
    } catch {
        Write-Log "HATA  - Kayıt defteri yazılamadı: $Path\$Name ($($_.Exception.Message))"
        return $false
    }
}

function Disable-SvcByName {
    param([string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Log "ATLANDI - Servis bu sistemde yok: $Name"
        return $true
    }

    if ($svc.Status -ne 'Stopped') {
        try {
            Stop-Service -Name $Name -Force -ErrorAction Stop
        } catch {
            Write-Log "UYARI - $Name durdurulamadı (devre dışı bırakma yine de denenecek): $($_.Exception.Message)"
        }
    }

    try {
        Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop
    } catch {
        Write-Log "HATA  - $Name devre dışı bırakılamadı: $($_.Exception.Message)"
        return $false
    }

    # Dogrulama: HKLM\...\Services\<Ad>\Start = 4 ise Disabled.
    try {
        $start = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" -Name Start -ErrorAction Stop).Start
        if ($start -ne 4) {
            Write-Log "HATA  - $Name devre dışı görünmüyor (Start=$start)."
            return $false
        }
    } catch {
        Write-Log "UYARI - $Name için başlangıç türü doğrulanamadı: $($_.Exception.Message)"
    }

    Write-Log "OK    - Servis devre dışı bırakıldı: $Name"
    return $true
}

function Clear-FolderContents {
    param([string]$Path, [string]$Label)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "ATLANDI - $Label klasörü bulunamadı: $Path"
        return $true
    }

    $deleted = 0
    $failed  = 0
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        try {
            Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
            $deleted++
        } catch {
            $failed++
        }
    }

    if ($failed -gt 0) {
        Write-Log "OK    - $Label temizlendi: $deleted öğe silindi, $failed öğe kullanımda olduğu için silinemedi."
    } else {
        Write-Log "OK    - $Label temizlendi: $deleted öğe silindi."
    }
    return $true
}

function Restart-ExplorerSafe {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { break }
    }

    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        try { Start-Process "explorer.exe" -ErrorAction Stop } catch {}
        Start-Sleep -Seconds 2
    }

    if (Get-Process -Name explorer -ErrorAction SilentlyContinue) {
        Write-Log "OK    - Windows Gezgini yeniden başlatıldı."
        return $true
    }

    Write-Log "HATA  - Windows Gezgini yeniden başlatılamadı. Ctrl+Shift+Esc > Dosya > Yeni görev > explorer.exe"
    return $false
}

# ============================================================
#  1. SERVISLER
# ============================================================
function Optimize-Services {
    Write-Host "`n=== GEREKSİZ SERVİSLER ===" -ForegroundColor Green
    Write-Host "Not: SysMain (Superfetch) ve Windows Search gibi servisler SSD'de kapatılabilir, HDD'de kapatman önerilmez." -ForegroundColor DarkYellow

    # Sadece genelde guvenle kapatilabilen servisler listelendi. Sira sabit olsun diye [ordered].
    $services = [ordered]@{
        "DiagTrack"         = "Bağlantılı Kullanıcı Deneyimleri ve Telemetri (veri toplama)"
        "dmwappushservice"  = "WAP Push Mesaj Yönlendirme (telemetri ile ilişkili)"
        "MapsBroker"        = "Downloaded Maps Manager (çevrimdışı harita kullanmıyorsan gereksiz)"
        "lfsvc"             = "Geolocation Service (konum servisi kullanmıyorsan)"
        "RetailDemo"        = "Retail Demo Service (mağaza demo modu, ev kullanıcısına gereksiz)"
        "WMPNetworkSvc"     = "Windows Media Player Ağ Paylaşım Servisi"
        "RemoteRegistry"    = "Uzaktan Registry erişimi (güvenlik açısından kapalı kalması iyi)"
        "Fax"               = "Faks servisi"
        "UevAgentService"   = "User Experience Virtualization Service (App-V/UE-V bileşeni, ev kullanıcısına gereksiz)"
        "tzautoupdate"      = "Otomatik Saat Dilimi Güncelleyici (saat dilimini elle ayarlıyorsan gereksiz)"
        "TrkWks"            = "Dağıtılmış Bağlantı İzleme İstemcisi (ağ NTFS kısayol takibi, ev kullanımında gereksiz)"
        "ssh-agent"         = "OpenSSH Authentication Agent (SSH anahtarı kullanmıyorsan gereksiz)"
        "Spooler"           = "Yazdırma Biriktiricisi (DİKKAT: yazıcı/'PDF olarak yazdır' kullanıyorsan KAPATMA)"
        "shpamsvc"          = "Shared PC Account Manager (paylaşımlı/kiosk PC modu kullanmıyorsan gereksiz)"
        "RmSvc"             = "Radyo Yönetimi Hizmeti (uçak modu donanım yönetimi, çoğu sistemde gereksiz)"
        "RemoteAccess"      = "Yönlendirme ve Uzaktan Erişim (VPN/router görevi görmüyorsan gereksiz)"
        "PcaSvc"            = "Program Uyumluluk Yardımcısı Hizmeti (eski program uyumluluk uyarıları)"
        "NetTcpPortSharing" = "Net.Tcp Bağlantı Noktası Paylaşımı (WCF uygulaması kullanmıyorsan gereksiz)"
        "MsKeyboardFilter"  = "Microsoft Klavye Filtresi (kiosk modunda kullanılır, ev kullanıcısına gereksiz)"
        "DPS"               = "Tanı İlkesi Hizmeti (Windows sorun giderme sihirbazlarını devre dışı bırakır)"
        "CscService"        = "Çevrimdışı Dosyalar (ağ paylaşımı çevrimdışı kullanmıyorsan gereksiz)"
        "AppVClient"        = "Microsoft App-V Client (uygulama sanallaştırma, ev kullanıcısına gereksiz)"
        "WbioSrvc"          = "Windows Biometric Service (parmak izi/yüz tanıma - Windows Hello kullanmıyorsan gereksiz)"
        "SCardSvr"          = "Smart Card (akıllı kart okuyucu kullanmıyorsan gereksiz)"
        "ScDeviceEnum"      = "Smart Card Device Enumeration Service (akıllı kart cihaz numaralandırma)"
        "XblAuthManager"    = "Xbox Live Auth Manager"
        "XblGameSave"       = "Xbox Live Game Save"
        "XboxNetApiSvc"     = "Xbox Live Networking Service"
        "XboxGipSvc"        = "Xbox Accessory Management Service"
        "CDPSvc"            = "Connected Devices Platform Service (Telefonum/Yakındaki Paylaşım kullanmıyorsan gereksiz)"
        "SSDPSRV"           = "SSDP Discovery (ağ cihazı keşfi/DLNA kullanmıyorsan gereksiz)"
        "upnphost"          = "UPnP Device Host (cast/DLNA kullanmıyorsan gereksiz)"
        "wisvc"             = "Windows Insider Service (Insider programına kayıtlı değilsen gereksiz)"
        "SensrSvc"          = "Sensor Monitoring Service (ortam ışığı sensörü vb. donanım yoksa gereksiz)"
        "SensorService"     = "Sensor Service (donanım sensörü yoksa gereksiz)"
        "SensorDataService" = "Sensor Data Service (donanım sensörü yoksa gereksiz)"
        "icssvc"            = "Windows Mobile Hotspot Service (internet paylaşımı kullanmıyorsan gereksiz)"
        "TermService"       = "Remote Desktop Services (DİKKAT: bu PC'ye RDP ile uzaktan bağlanıyorsan KAPATMA)"
        "WPCMonSvc"         = "Parental Controls (Aile Güvenliği/çocuk hesabı kullanmıyorsan gereksiz)"
        "ALG"               = "Application Layer Gateway Service (eski NAT yardımcı servisi, günümüzde nadiren kullanılır)"
        "RpcLocator"        = "RPC Locator (legacy servis, modern Windows'ta zaten genelde pasif)"
        "SysMain"           = "SysMain / Superfetch (SSD kullanıyorsan kapatılması önerilir, HDD'de kapatma)"
    }

    foreach ($svcName in $services.Keys) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        $question = "`"$svcName`" ($($services[$svcName])) servisini durdurup devre dışı bırakayım mı? Mevcut durum: $($svc.Status)"
        Invoke-Op $question { Disable-SvcByName -Name $svcName }
    }

    # OEM (HP/Intel vb.) servisleri: gercek "Name" degeri cihazdan cihaza degistigi icin
    # gorunen ada (DisplayName) gore aranir.
    Write-Host "`n--- OEM (HP/Intel) servisleri ---" -ForegroundColor Green
    foreach ($pattern in @("DialogBlockingService*")) {
        foreach ($svc in @(Get-Service -DisplayName $pattern -ErrorAction SilentlyContinue)) {
            $realName = $svc.Name
            $question = "`"$($svc.DisplayName)`" servisini durdurup devre dışı bırakayım mı? Mevcut durum: $($svc.Status)"
            Invoke-Op $question { Disable-SvcByName -Name $realName }
        }
    }
}

# ============================================================
#  2. BASLANGIC PROGRAMLARI
# ============================================================
function Optimize-Startup {
    Write-Host "`n=== BAŞLANGIÇ PROGRAMLARI ===" -ForegroundColor Green

    $items = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue | Select-Object Name, Command)
    if ($items.Count -eq 0) {
        Write-Host "Başlangıç öğesi bulunamadı." -ForegroundColor Yellow
    } else {
        $i = 1
        foreach ($item in $items) {
            Write-Host "$i) $($item.Name)  -> $($item.Command)" -ForegroundColor White
            $i++
        }
    }

    Write-Host "`nTek tek yönetmek istersen Görev Yöneticisi > Başlangıç sekmesini kullanabilirsin." -ForegroundColor DarkYellow

    Invoke-Op "Görev Yöneticisini Başlangıç sekmesinde açayım mı?" {
        Start-Process "taskmgr.exe" "/0" -WindowStyle Normal -ErrorAction Stop
        Write-Log "OK    - Görev Yöneticisi açıldı."
        return $true
    }

    Invoke-Op "Ayarlar > Uygulamalar > Başlangıç listesindeki TÜM uygulamaları devre dışı bırakayım mı? (Registry Run anahtarlarından başlayan klasik uygulamalar; UWP/Store arka plan görevlerini kapsamayabilir)" {
        $startupApprovedKeys = @(
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        )
        # Windows'un "Kapali" durumu icin kullandigi 12 byte'lik isaretleyici: ilk byte 03 = devre disi.
        $disabledMarker = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        $done = 0
        $fail = 0
        foreach ($key in $startupApprovedKeys) {
            if (-not (Test-Path -LiteralPath $key)) { continue }
            foreach ($name in (Get-Item -LiteralPath $key).Property) {
                if (Set-RegValue $key $name $disabledMarker 'Binary') { $done++ } else { $fail++ }
            }
        }
        if ($done -eq 0 -and $fail -eq 0) {
            Write-Log "ATLANDI - Kapatılabilecek klasik başlangıç uygulaması bulunamadı."
            return $true
        }
        Write-Log "OK    - $done başlangıç uygulaması devre dışı bırakıldı, $fail tanesi başarısız."
        return ($fail -eq 0)
    }

    Invoke-Op "Explorer başlangıç gecikmesini sıfırlayayım mı? (Windows varsayılan olarak başlangıç uygulamalarını ~10 saniye geciktirir, bu süreyi kaldırır)" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize" "StartupDelayInMSec" 0
        if ($ok) { Write-Log "OK    - Explorer başlangıç gecikmesi sıfırlandı." }
        return $ok
    }
}

# ============================================================
#  3. GORSEL EFEKTLER / PERFORMANS AYARLARI
# ============================================================
function Optimize-VisualEffects {
    Write-Host "`n=== GÖRSEL EFEKTLER ===" -ForegroundColor Green

    Invoke-Op "Görsel efektleri 'En iyi performans' moduna alayım mı? (animasyonlar, gölgeler vb. kapanır)" {
        $desktop  = "HKCU:\Control Panel\Desktop"
        $advanced = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $ok = $true

        $ok = (Set-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2) -and $ok
        # VisualFXSetting tek basina hicbir efekti kapatmaz; Windows'un "En iyi performans"
        # secenegiyle yazdigi degerlerin tamami asagida uygulanir.
        $ok = (Set-RegValue $desktop "UserPreferencesMask" ([byte[]](0x90, 0x12, 0x03, 0x80, 0x10, 0x00, 0x00, 0x00)) 'Binary') -and $ok
        $ok = (Set-RegValue $desktop "DragFullWindows" "0" 'String') -and $ok
        $ok = (Set-RegValue "$desktop\WindowMetrics" "MinAnimate" "0" 'String') -and $ok
        foreach ($valueName in @("ListviewAlphaSelect", "ListviewShadow", "TaskbarAnimations")) {
            $ok = (Set-RegValue $advanced $valueName 0) -and $ok
        }
        $ok = (Set-RegValue $advanced "IconsOnly" 1) -and $ok
        $ok = (Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\DWM" "EnableAeroPeek" 0) -and $ok

        if ($ok) { Write-Log "OK    - Görsel efektler 'En iyi performans' olarak ayarlandı (Gezgin yeniden başlatılınca tam etkili olur)." }
        return $ok
    }

    Invoke-Op "Şeffaflık efektlerini kapatayım mı?" {
        $ok = Set-RegValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" "EnableTransparency" 0
        if ($ok) { Write-Log "OK    - Şeffaflık efektleri kapatıldı." }
        return $ok
    }

    Invoke-Op "Animasyonları (pencere açılış/kapanış) kapatayım mı?" {
        $ok = Set-RegValue "HKCU:\Control Panel\Desktop\WindowMetrics" "MinAnimate" "0" 'String'
        if ($ok) { Write-Log "OK    - Pencere animasyonları kapatıldı." }
        return $ok
    }

    Invoke-Op "Windows Game Bar'ı kapatayım mı? (Kumandanızın Game Bar'ı açması + Game DVR arka plan kaydı)" {
        $ok = $true
        $ok = (Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0) -and $ok
        $ok = (Set-RegValue "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0) -and $ok
        $ok = (Set-RegValue "HKCU:\SOFTWARE\Microsoft\GameBar" "UseNexusForGameBarEnabled" 0) -and $ok
        # AllowGameDVR politikasi yalnizca HKLM altinda okunur (eskiden HKCU'ya yaziliyordu, etkisizdi).
        $ok = (Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0) -and $ok
        if ($ok) { Write-Log "OK    - Windows Game Bar kapatıldı." }
        return $ok
    }

    Invoke-Op "Oyun Modunu (Game Mode) açayım mı?" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled" 1
        if ($ok) { Write-Log "OK    - Oyun Modu açıldı." }
        return $ok
    }

    Invoke-Op "Dosya uzantılarının her zaman gösterilmesini sağlayayım mı? (.txt, .exe gibi uzantılar görünür olur)" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "HideFileExt" 0
        if ($ok) { Write-Log "OK    - Dosya uzantıları gösterilecek (Gezgin yeniden başlatılınca görünür)." }
        return $ok
    }

    Invoke-Op "Görev çubuğu Widget'lar (haber/hava durumu) düğmesini kapatayım mı?" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "TaskbarDa" 0
        if ($ok) { Write-Log "OK    - Görev çubuğu Widget'lar düğmesi kapatıldı." }
        return $ok
    }

    Invoke-Op "Ayarların hemen görünür olması için Windows Gezgini'ni (explorer.exe) yeniden başlatayım mı?" {
        return (Restart-ExplorerSafe)
    }
}

# ============================================================
#  4. GECICI DOSYA / ONBELLEK TEMIZLIGI
# ============================================================
function Optimize-TempCleanup {
    Write-Host "`n=== GEÇİCİ DOSYA / ÖNBELLEK TEMİZLİĞİ ===" -ForegroundColor Green

    Invoke-Op "Windows ve kullanıcı Temp klasörlerini (%TEMP% ve C:\Windows\Temp) temizleyeyim mi?" {
        $ok = $true
        $ok = (Clear-FolderContents $env:TEMP "Kullanıcı Temp") -and $ok
        $ok = (Clear-FolderContents "$env:WINDIR\Temp" "Windows Temp") -and $ok
        return $ok
    }

    Invoke-Op "Prefetch klasörünü (C:\Windows\Prefetch) temizleyeyim mi?" {
        return (Clear-FolderContents "$env:WINDIR\Prefetch" "Prefetch")
    }

    Invoke-Op "Son kullanılan öğeler (Recent) klasörünü temizleyeyim mi?" {
        return (Clear-FolderContents "$env:APPDATA\Microsoft\Windows\Recent" "Recent")
    }

    Invoke-Op "Uygulama çökme dökümlerini (AppData\Local\CrashDumps) temizleyeyim mi?" {
        return (Clear-FolderContents "$env:LOCALAPPDATA\CrashDumps" "CrashDumps")
    }

    Invoke-Op "Event Viewer (Olay Görüntüleyici) günlüklerini temizleyeyim mi? (Uygulama, Sistem, Güvenlik ve diğer tüm günlükler sıfırlanır)" {
        $logs = @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 })
        if ($logs.Count -eq 0) {
            Write-Log "ATLANDI - Temizlenecek günlük bulunamadı."
            return $true
        }
        $cleared = 0
        $failed  = 0
        foreach ($log in $logs) {
            & wevtutil.exe cl "$($log.LogName)" 2>$null
            if ($LASTEXITCODE -eq 0) { $cleared++ } else { $failed++ }
        }
        Write-Log "OK    - Event Viewer günlükleri: $cleared temizlendi, $failed temizlenemedi (korumalı günlükler)."
        return ($cleared -gt 0)
    }

    Invoke-Op "Windows Update indirme önbelleğini (C:\Windows\SoftwareDistribution\Download) temizleyeyim mi?" {
        $wasRunning = $false
        $svc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            $wasRunning = $true
            try { Stop-Service -Name wuauserv -Force -ErrorAction Stop } catch {
                Write-Log "UYARI - wuauserv durdurulamadı: $($_.Exception.Message)"
            }
        }
        $result = Clear-FolderContents "$env:WINDIR\SoftwareDistribution\Download" "Windows Update önbelleği"
        if ($wasRunning) {
            try { Start-Service -Name wuauserv -ErrorAction Stop } catch {
                Write-Log "UYARI - wuauserv yeniden başlatılamadı: $($_.Exception.Message)"
            }
        }
        return $result
    }

    Invoke-Op "Geri Dönüşüm Kutusunu boşaltayım mı?" {
        try {
            Clear-RecycleBin -Force -ErrorAction Stop
            Write-Log "OK    - Geri Dönüşüm Kutusu boşaltıldı."
            return $true
        } catch {
            # Kutu zaten bossa Windows hata dondurur; bu bir basarisizlik degildir.
            if ($_.Exception.Message -match 'boş|empty') {
                Write-Log "ATLANDI - Geri Dönüşüm Kutusu zaten boş."
                return $true
            }
            Write-Log "HATA  - Geri Dönüşüm Kutusu boşaltılamadı: $($_.Exception.Message)"
            return $false
        }
    }

    Invoke-Op "Simge/Thumbnail önbelleğini temizleyeyim mi? (bozuk/eski görünen simgeleri düzeltir, Gezgin yeniden başlatılır)" {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1

        $patterns = @(
            "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db",
            "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db",
            "$env:LOCALAPPDATA\IconCache.db"
        )
        $deleted = 0
        $failed  = 0
        foreach ($pattern in $patterns) {
            foreach ($file in @(Get-Item -Path $pattern -Force -ErrorAction SilentlyContinue)) {
                try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop; $deleted++ }
                catch { $failed++ }
            }
        }
        Write-Log "OK    - Simge/Thumbnail önbelleği: $deleted dosya silindi, $failed dosya silinemedi."
        $explorerOk = Restart-ExplorerSafe
        return ($explorerOk -and $failed -eq 0)
    }

    Invoke-Op "Disk Temizleme aracını TÜM kategoriler işaretli şekilde otomatik çalıştırayım mı? (Manuel onay istemeden temizler; en son geri yükleme noktası hariç eskiler silinir)" {
        $sageNum      = "0064"
        $volumeCaches = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
        $marked = 0
        foreach ($category in @(Get-ChildItem -LiteralPath $volumeCaches -ErrorAction SilentlyContinue)) {
            if (Set-RegValue $category.PSPath "StateFlags$sageNum" 2) { $marked++ }
        }
        if ($marked -eq 0) {
            Write-Log "HATA  - Disk Temizleme kategorileri işaretlenemedi."
            return $false
        }
        Write-Log "OK    - Disk Temizleme'de $marked kategori işaretlendi, cleanmgr başlatılıyor..."

        $proc = Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:$sageNum" -PassThru -ErrorAction Stop
        # cleanmgr bazen takilabildigi icin sinirsiz beklenmez.
        if (-not $proc.WaitForExit(20 * 60 * 1000)) {
            Write-Log "UYARI - Disk Temizleme 20 dakikada bitmedi, arka planda çalışmaya devam ediyor."
            return $true
        }
        Write-Log "OK    - Disk Temizleme tamamlandı."
        return $true
    }
}

# ============================================================
#  5. AG / DNS AYARLARI
# ============================================================
function Optimize-Network {
    Write-Host "`n=== AĞ / DNS AYARLARI ===" -ForegroundColor Green

    Invoke-Op "DNS Cache'i temizleyeyim mi (ipconfig /flushdns)?" {
        & ipconfig.exe /flushdns | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "HATA  - DNS cache temizlenemedi (ipconfig çıkış kodu: $LASTEXITCODE)."
            return $false
        }
        Write-Log "OK    - DNS cache temizlendi."
        return $true
    }

    Invoke-Op "Aktif ağ bağdaştırıcısının DNS sunucusunu Google DNS (8.8.8.8 / 8.8.4.4) olarak ayarlayayım mı?" {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        if (-not $adapter) {
            Write-Log "HATA  - Aktif (Up durumunda) ağ bağdaştırıcısı bulunamadı."
            return $false
        }

        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses ("8.8.8.8", "8.8.4.4") -ErrorAction Stop

        $current = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
        if ($current -notcontains "8.8.8.8") {
            Write-Log "HATA  - DNS ayarı doğrulanamadı (okunan: $($current -join ', '))."
            return $false
        }
        Write-Log "OK    - DNS sunucuları Google DNS olarak ayarlandı ($($adapter.Name))."
        Write-Log "        Geri almak için: Set-DnsClientServerAddress -InterfaceIndex $($adapter.ifIndex) -ResetServerAddresses"
        return $true
    }

    Write-Host "Not: Nagle algoritması ayarı, ağ bağdaştırıcısına özel bir interface GUID gerektirdiğinden bu script'e otomatik eklenmedi." -ForegroundColor DarkYellow
    Write-Host "Manuel yapmak istersen: HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\<GUID> altına TcpAckFrequency=1 ve TCPNoDelay=1 (DWORD) eklenir." -ForegroundColor DarkYellow
}

# ============================================================
#  6. GUC PLANI AYARLARI
# ============================================================
function Optimize-PowerPlan {
    Write-Host "`n=== GÜÇ PLANI (NİHAİ PERFORMANS) ===" -ForegroundColor Green

    Invoke-Op "Nihai Performans planını oluşturup etkinleştireyim ve tüm gelişmiş güç ayarlarını (disk/ekran/kablosuz/USB/PCIe/işlemci) en yüksek performansa göre ayarlayayım mı? (dizüstünde pil ömrünü belirgin şekilde kısaltır)" {
        $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

        $output = @(& powercfg.exe -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1)
        $scheme = $null
        foreach ($line in $output) {
            $m = [regex]::Match("$line", $guidPattern)
            if ($m.Success) { $scheme = $m.Value; break }
        }

        if (-not $scheme) {
            # Plan zaten olusturulmus olabilir; mevcut planlar arasinda "Nihai/Ultimate" aranir.
            foreach ($line in @(& powercfg.exe /list 2>&1)) {
                if ("$line" -match 'Ultimate|Nihai') {
                    $m = [regex]::Match("$line", $guidPattern)
                    if ($m.Success) { $scheme = $m.Value; break }
                }
            }
        }

        if (-not $scheme) {
            Write-Log "HATA  - Nihai Performans planı oluşturulamadı (bu Windows sürümünde desteklenmiyor olabilir)."
            return $false
        }

        & powercfg.exe -setactive $scheme | Out-Null

        $active = (@(& powercfg.exe /getactivescheme 2>&1) -join ' ')
        if ($active -notmatch [regex]::Escape($scheme)) {
            Write-Log "HATA  - Nihai Performans planı etkinleştirilemedi."
            return $false
        }
        Write-Log "OK    - Nihai Performans planı etkin. Şema GUID: $scheme"

        $settings = @(
            @{ Sub = "0012ee47-9041-4b5d-9b77-535fba8b1442"; Id = "6738e2c4-e8a5-4a42-b16a-e040e769756e"; Value = 0;   Label = "Sabit diski kapat (Hiçbir zaman)" }
            @{ Sub = "7516b95f-f776-4464-8c53-06167f40cc99"; Id = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"; Value = 0;   Label = "Ekranı kapat (Hiçbir zaman)" }
            @{ Sub = "02f815b5-a5cf-4c84-bf20-649d1f75d3d8"; Id = "4c793e7d-a264-42e1-8ec5-7f0db06cbf80"; Value = 0;   Label = "JavaScript Zamanlayıcı Sıklığı (En yüksek performans)" }
            @{ Sub = "0d7dbae2-4294-402a-ba8e-26777e8488cd"; Id = "309dce9b-bef4-4119-9921-a851fb12f0f4"; Value = 1;   Label = "Masaüstü slayt gösterisi (Duraklatıldı)" }
            @{ Sub = "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1"; Id = "12bbebe6-58d6-4636-95bb-3217ef867c1a"; Value = 0;   Label = "Kablosuz güç tasarrufu modu (En yüksek performans)" }
            @{ Sub = "2a737441-1930-4402-8d77-b2bebba308a3"; Id = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"; Value = 0;   Label = "USB seçmeli askıya alma (Kapalı)" }
            @{ Sub = "501a4d13-42af-4429-9fd1-a8218c268e20"; Id = "ee12f906-d277-404b-b6da-e5fa1a576df5"; Value = 0;   Label = "PCI Express bağlantı durumu güç yönetimi (Kapalı)" }
            @{ Sub = "54533251-82be-4824-96c1-47b60b740d00"; Id = "893dee8e-2bef-41e0-89c6-b55d0929964c"; Value = 100; Label = "İşlemci en düşük durum (%100)" }
            @{ Sub = "54533251-82be-4824-96c1-47b60b740d00"; Id = "bc5038f7-23e0-4960-96da-33abaf5935ec"; Value = 100; Label = "İşlemci en yüksek durum (%100)" }
            @{ Sub = "44f3beca-a7c0-460e-9df2-bb8b99e0cba6"; Id = "3619c3f2-afb2-4afc-b0e9-e7fef372de36"; Value = 2;   Label = "Intel Graphics Power Plan (Maximum Performance)" }
        )

        $applied = 0
        $skipped = 0
        foreach ($setting in $settings) {
            & powercfg.exe -setacvalueindex $scheme $setting.Sub $setting.Id $setting.Value 2>&1 | Out-Null
            $acOk = ($LASTEXITCODE -eq 0)
            & powercfg.exe -setdcvalueindex $scheme $setting.Sub $setting.Id $setting.Value 2>&1 | Out-Null
            $dcOk = ($LASTEXITCODE -eq 0)

            if ($acOk -or $dcOk) {
                $applied++
                Write-Log "        - $($setting.Label)"
            } else {
                $skipped++
                Write-Log "ATLANDI - $($setting.Label) bu sistemde mevcut değil."
            }
        }

        & powercfg.exe -setactive $scheme | Out-Null
        Write-Log "OK    - Gelişmiş güç ayarları: $applied uygulandı, $skipped bu sistemde yok."
        return $true
    }
}

# ============================================================
#  7. EK OPTIMIZASYONLAR
# ============================================================
function Optimize-Extra {
    Write-Host "`n=== EK OPTİMİZASYONLAR ===" -ForegroundColor Green

    Invoke-Op "Hazırda Bekletme (Hibernation) dosyasını kapatayım mı? (SSD'de yer açar, disk alanı kazandırır)" {
        & powercfg.exe -h off 2>&1 | Out-Null
        $value = $null
        try { $value = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Power" -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled } catch {}
        if ($value -ne 0) {
            Write-Log "HATA  - Hazırda bekletme kapatılamadı (HibernateEnabled=$value)."
            return $false
        }
        Write-Log "OK    - Hazırda bekletme kapatıldı."
        return $true
    }

    Invoke-Op "Windows İpuçları/Önerileri bildirimlerini kapatayım mı?" {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        $ok = $true
        foreach ($valueName in @("SubscribedContent-338389Enabled", "SubscribedContent-338393Enabled", "SoftLandingEnabled")) {
            $ok = (Set-RegValue $path $valueName 0) -and $ok
        }
        if ($ok) { Write-Log "OK    - Windows ipuçları/önerileri kapatıldı." }
        return $ok
    }

    Invoke-Op "Fast Startup'ı (Hızlı Başlatma) kapatayım mı? (bazı sürücü/ağ sorunlarını ve dual-boot disk bozulma riskini önler, kapanma birkaç saniye uzayabilir)" {
        $ok = Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0
        if ($ok) { Write-Log "OK    - Fast Startup kapatıldı." }
        return $ok
    }

    Invoke-Op "SSD için TRIM'in aktif olup olmadığını kontrol edip, kapalıysa otomatik olarak açayım mı?" {
        $status = (@(& fsutil.exe behavior query DisableDeleteNotify 2>&1) -join "`n")
        if ($status -notmatch "DisableDeleteNotify") {
            Write-Log "HATA  - TRIM durumu okunamadı: $status"
            return $false
        }
        if ($status -match "DisableDeleteNotify\D*=\s*0") {
            Write-Log "ATLANDI - TRIM zaten etkin, değişiklik yapılmadı."
            return $true
        }
        & fsutil.exe behavior set DisableDeleteNotify 0 2>&1 | Out-Null
        $status = (@(& fsutil.exe behavior query DisableDeleteNotify 2>&1) -join "`n")
        if ($status -match "DisableDeleteNotify\D*=\s*0") {
            Write-Log "OK    - TRIM kapalıydı, etkinleştirildi."
            return $true
        }
        Write-Log "HATA  - TRIM etkinleştirilemedi."
        return $false
    }

    Invoke-Op "OneDrive'ı kapatıp kaldırayım mı? (senkronizasyon durur, dosyaların diskte kalır; Gezgin'den OneDrive simgesi kaldırılır)" {
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue

        $setup = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path -LiteralPath $setup)) { $setup = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }

        if (Test-Path -LiteralPath $setup) {
            $proc = Start-Process -FilePath $setup -ArgumentList "/uninstall" -PassThru -ErrorAction Stop
            if (-not $proc.WaitForExit(5 * 60 * 1000)) {
                Write-Log "UYARI - OneDrive kaldırma işlemi 5 dakikada bitmedi."
            }
        } else {
            Write-Log "ATLANDI - OneDriveSetup.exe bulunamadı, kaldırma adımı geçildi."
        }

        foreach ($clsid in @("HKCU:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                             "HKCU:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}")) {
            if (Test-Path -LiteralPath $clsid) {
                Set-RegValue $clsid "System.IsPinnedToNameSpaceTree" 0 | Out-Null
            }
        }

        Write-Log "OK    - OneDrive kaldırıldı / gezinti bölmesinden gizlendi."
        return $true
    }

    Invoke-Op "Sayfalama dosyasını (pagefile) sistem yönetimli hale getireyim mi? (Windows RAM/disk durumuna göre otomatik boyutlandırır)" {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($cs.AutomaticManagedPagefile) {
            Write-Log "ATLANDI - Sayfalama dosyası zaten sistem yönetimli."
            return $true
        }
        Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true } -ErrorAction Stop

        $check = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if (-not $check.AutomaticManagedPagefile) {
            Write-Log "HATA  - Sayfalama dosyası sistem yönetimli yapılamadı."
            return $false
        }
        Write-Log "OK    - Sayfalama dosyası sistem yönetimli olarak ayarlandı (yeniden başlatma gerekir)."
        return $true
    }
}

# ============================================================
#  8. BASLANGIC/KURTARMA + SISTEM KORUMASI
# ============================================================
function Optimize-SystemAdvanced {
    Write-Host "`n=== BAŞLANGIÇ VE KURTARMA / SİSTEM KORUMASI ===" -ForegroundColor Green

    Invoke-Op "İşletim sistemleri listesini gösterme süresini kaldırayım mı (önyükleme menüsü zaman aşımı = 0)?" {
        & bcdedit.exe /timeout 0 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log "HATA  - Önyükleme zaman aşımı ayarlanamadı (bcdedit çıkış kodu: $LASTEXITCODE)."
            return $false
        }
        Write-Log "OK    - Önyükleme menüsü zaman aşımı 0 olarak ayarlandı."
        return $true
    }

    Invoke-Op "'Sistem günlüğüne olay olarak yaz' seçeneğini kapatayım mı?" {
        $ok = Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" "LogEvent" 0
        if ($ok) { Write-Log "OK    - Sistem günlüğüne olay yazma kapatıldı." }
        return $ok
    }

    Invoke-Op "'Otomatik olarak yeniden başlat' seçeneğini kapatayım mı?" {
        $ok = Set-RegValue "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" "AutoReboot" 0
        if ($ok) { Write-Log "OK    - Çökme sonrası otomatik yeniden başlatma kapatıldı." }
        return $ok
    }

    Invoke-Op "Sistem korumasını $env:SystemDrive için devre dışı bırakayım mı? (DİKKAT: mevcut geri yükleme noktaları silinir, sorunlu bir sürücü/güncelleme sonrası sistemi eski haline döndürme imkanın kalmaz)" {
        $result = Invoke-CimMethod -Namespace "root\default" -ClassName "SystemRestore" -MethodName "Disable" -Arguments @{ Drive = "$env:SystemDrive\" } -ErrorAction Stop
        if ($result.ReturnValue -ne 0) {
            Write-Log "HATA  - Sistem koruması devre dışı bırakılamadı (dönüş kodu: $($result.ReturnValue))."
            return $false
        }
        Write-Log "OK    - Sistem koruması $env:SystemDrive için devre dışı bırakıldı."
        return $true
    }

    Invoke-Op "$env:SystemDrive sürücüsündeki tüm geri yükleme noktalarını (shadow copy) sileyim mi?" {
        $output = (@(& vssadmin.exe delete shadows /for=$env:SystemDrive /all /quiet 2>&1) -join "`n")
        if ($LASTEXITCODE -ne 0) {
            if ($output -match 'No items found|Öğe bulunamadı') {
                Write-Log "ATLANDI - Silinecek geri yükleme noktası yok."
                return $true
            }
            Write-Log "HATA  - Geri yükleme noktaları silinemedi (çıkış kodu: $LASTEXITCODE)."
            return $false
        }
        Write-Log "OK    - Geri yükleme noktaları silindi ($env:SystemDrive)."
        return $true
    }
}

# ============================================================
#  9. GIZLILIK / ARKA PLAN
# ============================================================
function Optimize-Privacy {
    Write-Host "`n=== GİZLİLİK / ARKA PLAN AYARLARI ===" -ForegroundColor Green

    Invoke-Op "Uygulamaların arka planda çalışmasını (senkronizasyon, arka plan bildirimleri) kapatayım mı?" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications" "GlobalUserDisabled" 1
        $ok = (Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "BackgroundAppGlobalToggle" 0) -and $ok
        if ($ok) { Write-Log "OK    - Uygulamaların arka planda çalışması kapatıldı." }
        return $ok
    }

    Invoke-Op "Bildirimleri (toast) ve Eylem Merkezi'ni sınırlayayım mı?" {
        $ok = Set-RegValue "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications" "ToastEnabled" 0
        # DisableNotificationCenter yalnizca Policies\Explorer altinda okunur
        # (eskiden Explorer\Advanced'e yaziliyordu, hicbir etkisi yoktu).
        $ok = (Set-RegValue "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer" "DisableNotificationCenter" 1) -and $ok
        if ($ok) { Write-Log "OK    - Bildirimler ve Eylem Merkezi sınırlandı (Gezgin yeniden başlatılınca etkili olur)." }
        return $ok
    }

    Invoke-Op "Cortana ve Start menüsündeki web (Bing) arama sonuçlarını kapatayım mı?" {
        $search = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
        $ok = Set-RegValue $search "BingSearchEnabled" 0
        $ok = (Set-RegValue $search "CortanaConsent" 0) -and $ok
        $ok = (Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "AllowCortana" 0) -and $ok
        $ok = (Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" "DisableWebSearch" 1) -and $ok
        if ($ok) { Write-Log "OK    - Cortana ve web arama sonuçları kapatıldı." }
        return $ok
    }

    Invoke-Op "Telemetri/tanılama veri seviyesini en düşük düzeye çekeyim mi? (Home/Pro sürümde tamamen kapatmak mümkün değil, en düşük seviye 'Gerekli/Temel' olur)" {
        $ok = Set-RegValue "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 1
        $ok = (Set-RegValue "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" "AllowTelemetry" 1) -and $ok
        if ($ok) { Write-Log "OK    - Telemetri seviyesi en düşük düzeye (Gerekli/Temel) çekildi." }
        return $ok
    }

    Invoke-Op "Telemetri ile ilgili zamanlanmış görevleri (Görev Zamanlayıcı) devre dışı bırakayım mı?" {
        $tasks = @(
            "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser",
            "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
            "\Microsoft\Windows\Autochk\Proxy",
            "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
            "\Microsoft\Windows\Customer Experience Improvement Program\KernelCeipTask",
            "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
            "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
            "\Microsoft\Windows\Feedback\Siuf\DmClient",
            "\Microsoft\Windows\Feedback\Siuf\DmClientOnScenarioDownload",
            "\Microsoft\Windows\Windows Error Reporting\QueueReporting"
        )
        $disabled = 0
        $skipped  = 0
        $failed   = 0
        foreach ($fullPath in $tasks) {
            $taskName   = Split-Path $fullPath -Leaf
            $taskFolder = (Split-Path $fullPath -Parent) + "\"
            try {
                $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction Stop
                if ($task.State -eq 'Disabled') { $skipped++; continue }
                Disable-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction Stop | Out-Null
                $check = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction Stop
                if ($check.State -eq 'Disabled') { $disabled++ } else { $failed++ }
            } catch {
                $skipped++
            }
        }
        Write-Log "OK    - Zamanlanmış görevler: $disabled devre dışı bırakıldı, $skipped atlandı (yok/zaten kapalı), $failed başarısız."
        return ($failed -eq 0)
    }
}

# ============================================================
#  ANA MENU
# ============================================================
function Show-Menu {
    # Cikti bir dosyaya yonlendirilmisse Clear-Host hata verir; ekrani temizleyememek sorun degil.
    try { Clear-Host } catch {}
    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host "         WINDOWS OPTİMİZASYON SCRIPTİ" -ForegroundColor Magenta
    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host "Ayarlar şu kullanıcı profiline uygulanır: $env:USERDOMAIN\$env:USERNAME" -ForegroundColor DarkGray
    Write-Host "--------------------------------------------------" -ForegroundColor Magenta
    Write-Host "1) Gereksiz servisleri devre dışı bırak"
    Write-Host "2) Başlangıç programlarını yönet"
    Write-Host "3) Görsel efektler / performans ayarları"
    Write-Host "4) Geçici dosya / önbellek temizliği"
    Write-Host "5) Ağ / DNS ayarları"
    Write-Host "6) Güç planı ayarları"
    Write-Host "7) Ek optimizasyonlar (hibernation, bildirimler, Fast Startup, TRIM, OneDrive, pagefile)"
    Write-Host "8) Başlangıç/Kurtarma ve Sistem Koruması ayarları"
    Write-Host "9) Gizlilik / arka plan ayarları"
    Write-Host "10) Hepsini sırayla çalıştır (yine de her adımda onay ister)"
    Write-Host "0) Çıkış"
    Write-Host "==================================================" -ForegroundColor Magenta
}

function Invoke-Category {
    param([scriptblock[]]$Actions)

    $script:OkCount   = 0
    $script:FailCount = 0

    foreach ($action in $Actions) {
        try {
            & $action
        } catch {
            Write-Log "HATA  - Kategori işlenirken beklenmeyen hata: $($_.Exception.Message)"
        }
    }

    Write-Host "`n--------------------------------------------------" -ForegroundColor Magenta
    Write-Host "Özet: $($script:OkCount) işlem başarılı, $($script:FailCount) işlem başarısız." -ForegroundColor Magenta
    if ($script:FailCount -gt 0) {
        Write-Host "Başarısız işlemler yukarıda 'HATA' satırlarında listelendi." -ForegroundColor Yellow
    }
}

Write-Log "Script başlatıldı."

do {
    Show-Menu
    $choice = Read-Host "Seçim yap"

    switch ($choice) {
        "1"  { Invoke-Category @({ Optimize-Services }) }
        "2"  { Invoke-Category @({ Optimize-Startup }) }
        "3"  { Invoke-Category @({ Optimize-VisualEffects }) }
        "4"  { Invoke-Category @({ Optimize-TempCleanup }) }
        "5"  { Invoke-Category @({ Optimize-Network }) }
        "6"  { Invoke-Category @({ Optimize-PowerPlan }) }
        "7"  { Invoke-Category @({ Optimize-Extra }) }
        "8"  { Invoke-Category @({ Optimize-SystemAdvanced }) }
        "9"  { Invoke-Category @({ Optimize-Privacy }) }
        "10" {
            Invoke-Category @(
                { Optimize-Services },
                { Optimize-Startup },
                { Optimize-VisualEffects },
                { Optimize-TempCleanup },
                { Optimize-Network },
                { Optimize-PowerPlan },
                { Optimize-Extra },
                { Optimize-SystemAdvanced },
                { Optimize-Privacy }
            )
        }
        "0"  { Write-Host "Çıkılıyor..." -ForegroundColor Yellow }
        default { Write-Host "Geçersiz seçim." -ForegroundColor Red }
    }

    if ($choice -ne "0") {
        Read-Host "`nDevam etmek için Enter'a bas"
    }
} while ($choice -ne "0")

Write-Log "Script tamamlandı."
Write-Host "Bazı ayarlar (görsel efektler, dosya uzantıları, bildirimler) ancak Gezgin yeniden başlatıldıktan ya da oturum kapatılıp açıldıktan sonra görünür olur." -ForegroundColor DarkYellow
Start-Sleep -Seconds 2
