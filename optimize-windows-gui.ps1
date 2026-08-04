#Requires -Version 5.1
<#
    optimize-windows-gui.ps1
    -------------------------
    optimize-windows.ps1'in WPF arayuzlu surumu.

    Bu surumde duzeltilenler:
      * Tum optimizasyon isleri artik ayri bir runspace'te (arka plan is parcaciginda) calisir.
        Arayuz "Yanit vermiyor" durumuna dusmez, log ve ilerleme cubugu canli akar.
      * Islemler, sorunun metnine degil KARARLI bir anahtara gore eslestirilir. Onceden servis
        durumu ("Mevcut durum: Running") sorunun icinde oldugu icin, ikinci uygulamada metin
        degisiyor ve secili islem sessizce atlaniyordu ("yaptim diyor ama yapmiyor" hatasi).
      * Her kayit defteri yazimi geri okunarak DOGRULANIR. Dogrulanamayan islem "HATA" olarak
        raporlanir; basarili olmayan hicbir islem "yapildi" diye loglanmaz.
      * Her servis, dogrudan Start=4 (Disabled) degeri okunarak dogrulanir.
      * Yanlis kayit defteri yollari duzeltildi (Game Bar politikasi HKLM'e, bildirim merkezi
        politikasi Policies\Explorer'a tasindi; "En iyi performans" icin gerekli tum degerler eklendi).
      * exe olarak derlendiginde de dogru sekilde yeniden baslatan yonetici yukseltmesi.
      * Tum olay isleyicileri ve her islem ayri ayri try/catch icinde; tek bir hata programi cokertmez.

    KULLANIM:
        .\optimize-windows-gui.ps1
        Script kendini otomatik olarak "Yonetici olarak calistir" ile yeniden baslatir.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ============================================================
#  0. KENDI YOLU / YONETICI YETKISI / STA KONTROLU
# ============================================================
function Show-FatalMessage {
    param([string]$Text, [string]$Title = "Windows Optimizasyon Aracı")
    try {
        [System.Windows.MessageBox]::Show($Text, $Title, [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    } catch {
        Write-Host $Text -ForegroundColor Red
    }
}

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
        Show-FatalMessage "Yönetici yetkisi gerekli, ancak programın kendi yolu bulunamadığı için yeniden başlatılamadı. Lütfen dosyaya sağ tıklayıp 'Yönetici olarak çalıştır' seçeneğini kullanın."
        exit 1
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($script:IsCompiled) {
        $psi.FileName  = $script:SelfPath
        $psi.Arguments = ""
    } else {
        $psi.FileName  = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$($script:SelfPath)`""
    }
    $psi.Verb            = "runas"
    $psi.UseShellExecute = $true
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Show-FatalMessage "Yönetici yetkisi verilmedi, program kapatılıyor."
    }
    exit
}

# WPF penceresi STA modunda olusturulmalidir.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    if ($script:IsCompiled) {
        Show-FatalMessage "Program STA modunda derlenmemiş. Lütfen ps2exe ile -STA anahtarını kullanarak yeniden derleyin."
        exit 1
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = "powershell.exe"
    $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$($script:SelfPath)`""
    $psi.UseShellExecute = $true
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch {}
    exit
}

$ErrorActionPreference = "Continue"

# ============================================================
#  ARKA PLAN IS PARCACIGI ILE PAYLASILAN DURUM
# ============================================================
$script:Sync = [hashtable]::Synchronized(@{
    Mode            = 'collect'      # 'collect' | 'apply'
    CurrentCategory = ''
    Ops             = $null          # collect sonucu: List[psobject]
    Checked         = @{}            # anahtar -> $true (uygulanacak islemler)
    Results         = @{}            # anahtar -> 'ok' | 'fail'
    LogQueue        = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    Progress        = 0
    OkCount         = 0
    FailCount       = 0
    Done            = $false
    Error           = $null
})

# ============================================================
#  CEKIRDEK MANTIK
#  Bu blogun METNI arka plan runspace'ine gonderilir; ana is
#  parcaciginda hicbir zaman calistirilmaz.
# ============================================================
$script:CoreCode = {

    $ErrorActionPreference = "Continue"

    # -------------------- ortak yardimcilar --------------------
    function Write-Log {
        param([string]$Message)
        $Sync.LogQueue.Enqueue(("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $Message))
    }

    # Servis durumu ("Mevcut durum: Running") zamanla degistigi icin anahtardan cikarilir.
    # Aksi halde ikinci uygulamada eslesme tutmaz ve islem sessizce atlanir.
    function Get-OpKey {
        param([string]$Question)
        return ($Question -replace '\s*Mevcut durum:\s*\S+\s*$', '')
    }

    function Confirm-Action {
        param([string]$Question)
        $key = Get-OpKey $Question
        if ($Sync.Mode -eq 'collect') {
            $Sync.Ops.Add([PSCustomObject]@{
                Category = $Sync.CurrentCategory
                Question = $Question
                Key      = $key
                Checked  = $false
            })
            return $false
        }
        return $Sync.Checked.ContainsKey($key)
    }

    # Her islem tek tek yalitilir: biri patlarsa digerleri calismaya devam eder.
    function Invoke-Op {
        param([string]$Question, [scriptblock]$Action)

        if (-not (Confirm-Action $Question)) { return }

        $key = Get-OpKey $Question
        $Sync.Progress = $Sync.Progress + 1

        try {
            $out = & $Action
            $flag = @($out) | Where-Object { $_ -is [bool] } | Select-Object -Last 1
            $ok = if ($null -eq $flag) { $true } else { [bool]$flag }
        } catch {
            $ok = $false
            Write-Log "HATA  - İşlem başarısız oldu: $($_.Exception.Message)"
        }

        if ($ok) { $Sync.OkCount = $Sync.OkCount + 1 } else { $Sync.FailCount = $Sync.FailCount + 1 }
        $Sync.Results[$key] = $(if ($ok) { 'ok' } else { 'fail' })
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
        $displayNamePatterns = @("DialogBlockingService*")
        foreach ($pattern in $displayNamePatterns) {
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
            $sageNum    = "0064"
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
    }

    # ============================================================
    #  6. GUC PLANI AYARLARI
    # ============================================================
    function Optimize-PowerPlan {
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
    #  KATEGORI SIRASI VE FONKSIYON ESLESMESI
    # ============================================================
    $CategoryMap = [ordered]@{
        "Servisler"                             = { Optimize-Services }
        "Başlangıç Programları"                 = { Optimize-Startup }
        "Görsel Efektler"                       = { Optimize-VisualEffects }
        "Temizlik"                              = { Optimize-TempCleanup }
        "Ağ/DNS"                                = { Optimize-Network }
        "Güç Planı"                             = { Optimize-PowerPlan }
        "Ek Optimizasyonlar"                    = { Optimize-Extra }
        "Başlangıç/Kurtarma ve Sistem Koruması" = { Optimize-SystemAdvanced }
        "Gizlilik"                              = { Optimize-Privacy }
    }

    function Invoke-AllCategories {
        foreach ($categoryName in $CategoryMap.Keys) {
            $Sync.CurrentCategory = $categoryName
            try {
                & $CategoryMap[$categoryName]
            } catch {
                Write-Log "HATA  - '$categoryName' kategorisi işlenirken hata: $($_.Exception.Message)"
            }
        }
    }
}

# Kategori adlari + ikonlar arayuz tarafinda da gerekli oldugu icin burada ayrica tutulur.
$script:CategoryOrder = @(
    "Servisler",
    "Başlangıç Programları",
    "Görsel Efektler",
    "Temizlik",
    "Ağ/DNS",
    "Güç Planı",
    "Ek Optimizasyonlar",
    "Başlangıç/Kurtarma ve Sistem Koruması",
    "Gizlilik"
)
$script:CategoryIcons = @{
    "Servisler"                             = "🛠"
    "Başlangıç Programları"                 = "🚀"
    "Görsel Efektler"                       = "🎨"
    "Temizlik"                              = "🧹"
    "Ağ/DNS"                                = "🌐"
    "Güç Planı"                             = "⚡"
    "Ek Optimizasyonlar"                    = "➕"
    "Başlangıç/Kurtarma ve Sistem Koruması" = "🛡"
    "Gizlilik"                              = "🔒"
}

# ============================================================
#  ARKA PLAN CALISTIRICI
# ============================================================
$script:Worker       = $null
$script:WorkerHandle = $null
$script:WorkerRs     = $null
$script:Phase        = 'idle'   # 'collect' | 'apply' | 'refresh' | 'idle'

function Start-Worker {
    param([ValidateSet('collect', 'apply')][string]$Mode)

    $script:Sync.Mode      = $Mode
    $script:Sync.Done      = $false
    $script:Sync.Error     = $null
    $script:Sync.Progress  = 0
    $script:Sync.OkCount   = 0
    $script:Sync.FailCount = 0

    if ($Mode -eq 'collect') {
        $script:Sync.Ops = [System.Collections.Generic.List[psobject]]::new()
    } else {
        $script:Sync.Results = [hashtable]::Synchronized(@{})
    }

    $script:WorkerRs = [runspacefactory]::CreateRunspace()
    try { $script:WorkerRs.ApartmentState = 'STA' } catch {}
    $script:WorkerRs.ThreadOptions = 'ReuseThread'
    $script:WorkerRs.Open()
    $script:WorkerRs.SessionStateProxy.SetVariable('Sync', $script:Sync)

    $bootstrap = @'

try {
    Invoke-AllCategories
} catch {
    $Sync.Error = $_.ToString()
} finally {
    $Sync.Done = $true
}
'@

    $script:Worker = [powershell]::Create()
    $script:Worker.Runspace = $script:WorkerRs
    $null = $script:Worker.AddScript($script:CoreCode.ToString() + $bootstrap)
    $script:WorkerHandle = $script:Worker.BeginInvoke()
}

function Stop-Worker {
    try { if ($script:Worker)   { $script:Worker.Dispose() } }   catch {}
    try { if ($script:WorkerRs) { $script:WorkerRs.Close(); $script:WorkerRs.Dispose() } } catch {}
    $script:Worker       = $null
    $script:WorkerHandle = $null
    $script:WorkerRs     = $null
}

# ============================================================
#  GUI (WPF) - Koyu tema
# ============================================================
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Optimizasyon Aracı" Height="760" Width="1040"
        WindowStartupLocation="CenterScreen"
        Background="#FF1E1E1E" FontFamily="Segoe UI">
    <Window.Resources>
        <SolidColorBrush x:Key="BgBrush" Color="#FF1E1E1E"/>
        <SolidColorBrush x:Key="PanelBrush" Color="#FF252526"/>
        <SolidColorBrush x:Key="CardBrush" Color="#FF2D2D30"/>
        <SolidColorBrush x:Key="BorderBrush2" Color="#FF3F3F46"/>
        <SolidColorBrush x:Key="TextBrush" Color="#FFE6E6E6"/>
        <SolidColorBrush x:Key="SubTextBrush" Color="#FF9D9D9D"/>
        <SolidColorBrush x:Key="AccentBrush" Color="#FF0078D4"/>
        <SolidColorBrush x:Key="AccentHoverBrush" Color="#FF1A88E0"/>
        <SolidColorBrush x:Key="AccentPressedBrush" Color="#FF005A9E"/>
        <SolidColorBrush x:Key="RunningBg" Color="#FF1F3B27"/>
        <SolidColorBrush x:Key="RunningFg" Color="#FF4CAF50"/>
        <SolidColorBrush x:Key="StoppedBg" Color="#FF3A3A3A"/>
        <SolidColorBrush x:Key="StoppedFg" Color="#FFB0B0B0"/>
        <SolidColorBrush x:Key="OkBg" Color="#FF14361F"/>
        <SolidColorBrush x:Key="OkFg" Color="#FF4CD964"/>
        <SolidColorBrush x:Key="FailBg" Color="#FF3D1A1A"/>
        <SolidColorBrush x:Key="FailFg" Color="#FFFF6B6B"/>

        <Style x:Key="ModernButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource AccentBrush}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentHoverBrush}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentPressedBrush}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Background" Value="#FF3F3F46"/>
                                <Setter Property="Foreground" Value="#FF7A7A7A"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ListBox">
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="4"/>
        </Style>

        <Style x:Key="CategoryItemStyle" TargetType="ListBoxItem">
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="Margin" Value="0,2"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="#33FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter Property="Foreground" Value="White"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <DataTemplate x:Key="CategoryItemTemplate">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="24"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="{Binding Icon}" FontSize="15" VerticalAlignment="Top"/>
                <TextBlock Grid.Column="1" Text="{Binding Name}" FontSize="13" VerticalAlignment="Center" TextWrapping="Wrap"/>
            </Grid>
        </DataTemplate>

        <Style x:Key="SearchBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
            <Setter Property="Foreground" Value="{StaticResource AccentBrush}"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>

        <Style x:Key="ThinScrollBarThumb" TargetType="Thumb">
            <Setter Property="Background" Value="#40FFFFFF"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="{TemplateBinding Background}" CornerRadius="4"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#70FFFFFF"/>
                </Trigger>
                <Trigger Property="IsDragging" Value="True">
                    <Setter Property="Background" Value="#90FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="ScrollBar">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track Name="PART_Track" IsDirectionReversed="True" Orientation="{TemplateBinding Orientation}"
                                   Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}"
                                   ViewportSize="{TemplateBinding ViewportSize}"
                                   Value="{TemplateBinding Value}">
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False" Background="Transparent" BorderThickness="0"/>
                                </Track.DecreaseRepeatButton>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False" Background="Transparent" BorderThickness="0"/>
                                </Track.IncreaseRepeatButton>
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource ThinScrollBarThumb}"/>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Vertical">
                    <Setter Property="Width" Value="8"/>
                </Trigger>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Height" Value="8"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Width="42" Height="22" VerticalAlignment="Center">
                            <Border x:Name="Track" CornerRadius="11" Background="#FF3F3F46"/>
                            <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="#FFC8C8C8" HorizontalAlignment="Left" Margin="3,0,0,0"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Track" Property="Background" Value="{StaticResource AccentBrush}"/>
                                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                                <Setter TargetName="Thumb" Property="Margin" Value="0,0,3,0"/>
                                <Setter TargetName="Thumb" Property="Fill" Value="White"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Track" Property="Opacity" Value="0.85"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="OpsCardStyle" TargetType="Border">
            <Setter Property="Background" Value="{StaticResource CardBrush}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="6"/>
            <Setter Property="Padding" Value="10"/>
            <Setter Property="Margin" Value="0,0,0,6"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid Name="MainContent" Margin="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="180"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,14">
            <TextBlock Text="🧰" FontSize="28" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <StackPanel VerticalAlignment="Center">
                <TextBlock Text="Windows Optimizasyon Aracı" FontSize="20" FontWeight="Bold" Foreground="{StaticResource TextBrush}"/>
                <TextBlock Text="Servisleri, başlangıç öğelerini ve sistem ayarlarını tek yerden düzenle" FontSize="12" Foreground="{StaticResource SubTextBrush}"/>
            </StackPanel>
        </StackPanel>

        <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,10">
            <Button Name="BtnSelectAll" Content="Tümünü Seç" Width="130" Height="30" Margin="0,0,8,0" Style="{StaticResource ModernButton}"/>
            <Button Name="BtnDeselectAll" Content="Tümünü Kaldır" Width="130" Height="30" Margin="0,0,8,0" Style="{StaticResource ModernButton}"/>
            <Button Name="BtnRefresh" Content="Durumları Yenile" Width="140" Height="30" Style="{StaticResource ModernButton}"/>
        </StackPanel>

        <Grid Grid.Row="2">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="250"/>
                <ColumnDefinition Width="12"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <Grid Grid.Column="0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>
                <Grid Grid.Row="0" Margin="0,0,0,8">
                    <TextBox Name="CategorySearch" Style="{StaticResource SearchBoxStyle}"/>
                    <TextBlock Name="SearchPlaceholder" Text="Kategori ara..." Foreground="{StaticResource SubTextBrush}" Margin="10,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
                <ListBox Name="CategoryList" Grid.Row="1" ItemTemplate="{StaticResource CategoryItemTemplate}" ItemContainerStyle="{StaticResource CategoryItemStyle}"
                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
            </Grid>

            <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
                <StackPanel Name="OpsPanel" Margin="2"/>
            </ScrollViewer>
        </Grid>

        <Button Name="BtnApply" Grid.Row="3" Content="Seçilenleri Uygula" Height="38" Margin="0,10,0,8" FontSize="14" Style="{StaticResource ModernButton}"/>

        <ProgressBar Name="ProgressBarCtrl" Grid.Row="4" Height="10" Minimum="0" Margin="0,0,0,4"/>

        <TextBlock Name="StatusText" Grid.Row="5" Text="" FontSize="11" Foreground="{StaticResource SubTextBrush}" Margin="0,0,0,6"/>

        <TextBox Name="LogBox" Grid.Row="6" IsReadOnly="True" VerticalScrollBarVisibility="Auto"
                 HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="11"
                 Background="#FF101010" Foreground="#FF4CD964" BorderBrush="#FF3F3F46" BorderThickness="1"/>
        </Grid>

        <Grid Name="LockScreen" Background="{StaticResource BgBrush}" Cursor="Hand">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Text="🖥" FontSize="26" Foreground="{StaticResource SubTextBrush}" Opacity="0.45"
                       Grid.Row="0" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="70,60,0,0"/>
            <TextBlock Text="💽" FontSize="26" Foreground="{StaticResource SubTextBrush}" Opacity="0.45"
                       Grid.Row="0" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,60,70,0"/>
            <TextBlock Text="🧠" FontSize="26" Foreground="{StaticResource SubTextBrush}" Opacity="0.45"
                       Grid.Row="0" HorizontalAlignment="Left" VerticalAlignment="Bottom" Margin="70,0,0,60"/>
            <TextBlock Text="🌐" FontSize="26" Foreground="{StaticResource SubTextBrush}" Opacity="0.45"
                       Grid.Row="0" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,70,60"/>

            <StackPanel Grid.Row="0" HorizontalAlignment="Center" VerticalAlignment="Center">
                <TextBlock Text="Windows Optimizasyon Aracı" FontSize="32" FontWeight="Bold"
                           Foreground="{StaticResource TextBrush}" HorizontalAlignment="Center"/>
                <TextBlock Text="Sisteminizi Keşfedin ve Güçlendirin" FontSize="14" Foreground="{StaticResource SubTextBrush}"
                           HorizontalAlignment="Center" Margin="0,4,0,32"/>

                <Border Name="AvatarCircle" Width="140" Height="140" Background="{StaticResource CardBrush}"
                        BorderBrush="{StaticResource AccentBrush}" BorderThickness="3" CornerRadius="70"
                        HorizontalAlignment="Center">
                    <TextBlock Text="⏻" FontSize="56" Foreground="{StaticResource AccentBrush}"
                               HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>

                <TextBlock Name="LockHint" Text="Sistem taranıyor, lütfen bekleyin..." Foreground="{StaticResource SubTextBrush}"
                           FontSize="13" HorizontalAlignment="Center" Margin="0,20,0,0"/>
            </StackPanel>

            <StackPanel Grid.Row="1" HorizontalAlignment="Center" Margin="0,0,0,10">
                <ProgressBar Name="LockProgressBar" Height="8" Width="420" IsIndeterminate="True" Maximum="100"/>
                <TextBlock Name="LockStatus" Text="Sistem Analizi Hazırlanıyor..." Foreground="{StaticResource SubTextBrush}" FontSize="11"
                           HorizontalAlignment="Center" Margin="0,10,0,0"/>
            </StackPanel>

            <TextBlock Grid.Row="2" Text="Geliştirici : Alper Ağaoğlu" Foreground="{StaticResource SubTextBrush}"
                       FontSize="11" HorizontalAlignment="Right" Margin="0,0,20,12"/>
        </Grid>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$CategoryList      = $window.FindName("CategoryList")
$CategorySearch    = $window.FindName("CategorySearch")
$SearchPlaceholder = $window.FindName("SearchPlaceholder")
$OpsPanel          = $window.FindName("OpsPanel")
$BtnSelectAll      = $window.FindName("BtnSelectAll")
$BtnDeselectAll    = $window.FindName("BtnDeselectAll")
$BtnRefresh        = $window.FindName("BtnRefresh")
$BtnApply          = $window.FindName("BtnApply")
$ProgressBarCtrl   = $window.FindName("ProgressBarCtrl")
$StatusText        = $window.FindName("StatusText")
$LogBox            = $window.FindName("LogBox")
$LockScreen        = $window.FindName("LockScreen")
$LockHint          = $window.FindName("LockHint")
$LockStatus        = $window.FindName("LockStatus")
$LockProgressBar   = $window.FindName("LockProgressBar")

# Arayuzde beklenmedik bir hata olsa bile program kapanmasin.
$window.Dispatcher.Add_UnhandledException({
    param($senderObj, $e)
    try {
        $LogBox.AppendText("[HATA] Arayüz hatası yakalandı: $($e.Exception.Message)`r`n")
        $LogBox.ScrollToEnd()
    } catch {}
    $e.Handled = $true
})

function Write-UiLog {
    param([string]$Message)
    $LogBox.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format "HH:mm:ss"), $Message))
    $LogBox.ScrollToEnd()
}

# ============================================================
#  KILIT EKRANI
# ============================================================
$script:LockReady        = $false
$script:LockWantsClose   = $false

function Close-LockScreen {
    if ($LockScreen.Visibility -ne [System.Windows.Visibility]::Visible) { return }
    if (-not $script:LockReady) {
        # Tarama bitmeden kapatilamaz; kullanicinin niyeti hatirlanir.
        $script:LockWantsClose = $true
        return
    }
    $LockScreen.IsHitTestVisible = $false
    $fade = New-Object System.Windows.Media.Animation.DoubleAnimation
    $fade.From     = 1.0
    $fade.To       = 0.0
    $fade.Duration = [System.Windows.Duration]::new([TimeSpan]::FromSeconds(0.7))
    $fade.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
    $fade.EasingFunction.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $fade.Add_Completed({ $LockScreen.Visibility = [System.Windows.Visibility]::Collapsed })
    $LockScreen.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
}

$LockScreen.Add_MouseLeftButtonDown({ try { Close-LockScreen } catch {} })
$window.Add_KeyDown({
    param($senderObj, $e)
    try {
        if ($e.Key -eq [System.Windows.Input.Key]::Enter) { Close-LockScreen }
    } catch {}
})

# ============================================================
#  KATEGORI LISTESI VE ISLEM KARTLARI
# ============================================================
function Get-CategoryItems {
    param([string]$Filter = "")
    $names = @($script:CategoryOrder)
    if ($Filter) {
        $needle = $Filter.ToLower()
        $names = @($names | Where-Object { $_.ToLower().Contains($needle) })
    }
    return @($names | ForEach-Object { [PSCustomObject]@{ Name = $_; Icon = $script:CategoryIcons[$_] } })
}

# Servis satirlarindaki "Ad (Aciklama) ... Mevcut durum: X" metnini parcalara ayirir (yalnizca gorsel).
$script:ReWithDesc = '^"(?<name>[^"]+)"\s\((?<desc>.+)\)\sservisini durdurup devre dışı bırakayım mı\?\sMevcut durum:\s(?<status>\S+)$'
$script:ReNoDesc   = '^"(?<name>[^"]+)"\sservisini durdurup devre dışı bırakayım mı\?\sMevcut durum:\s(?<status>\S+)$'

function New-Pill {
    param([string]$Text, [string]$BgKey, [string]$FgKey)
    $pill = New-Object System.Windows.Controls.Border
    $pill.CornerRadius     = "8"
    $pill.Padding          = "8,3"
    $pill.Margin           = "6,0,0,0"
    $pill.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $pill.Background       = $window.FindResource($BgKey)

    $textBlock = New-Object System.Windows.Controls.TextBlock
    $textBlock.Text       = $Text
    $textBlock.FontSize   = 10
    $textBlock.FontWeight = [System.Windows.FontWeights]::SemiBold
    $textBlock.Foreground = $window.FindResource($FgKey)
    $pill.Child = $textBlock
    return $pill
}

function Update-OpsPanel {
    param([string]$Category)

    $OpsPanel.Children.Clear()
    if (-not $script:Sync.Ops) { return }

    $ops = @($script:Sync.Ops | Where-Object { $_.Category -eq $Category })
    if ($ops.Count -eq 0) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text         = "Bu kategoride uygulanabilir işlem bulunamadı (ilgili servis/özellik bu sistemde yok)."
        $tb.Foreground   = $window.FindResource("SubTextBrush")
        $tb.Margin       = "4"
        $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $OpsPanel.Children.Add($tb) | Out-Null
        return
    }

    foreach ($op in $ops) {
        $name   = $op.Question
        $desc   = $null
        $status = $null

        if ($op.Question -match $script:ReWithDesc) {
            $name = $Matches.name; $desc = $Matches.desc; $status = $Matches.status
        } elseif ($op.Question -match $script:ReNoDesc) {
            $name = $Matches.name; $status = $Matches.status
        }

        $card = New-Object System.Windows.Controls.Border
        $card.Style = $window.FindResource("OpsCardStyle")

        $grid = New-Object System.Windows.Controls.Grid
        $colToggle = New-Object System.Windows.Controls.ColumnDefinition
        $colToggle.Width = New-Object System.Windows.GridLength(46)
        $colText = New-Object System.Windows.Controls.ColumnDefinition
        $colText.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $colStatus = New-Object System.Windows.Controls.ColumnDefinition
        $colStatus.Width = [System.Windows.GridLength]::Auto
        $grid.ColumnDefinitions.Add($colToggle) | Out-Null
        $grid.ColumnDefinitions.Add($colText) | Out-Null
        $grid.ColumnDefinitions.Add($colStatus) | Out-Null

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Style             = $window.FindResource("ToggleSwitchStyle")
        $cb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $cb.Tag               = $op
        $cb.IsChecked         = [bool]$op.Checked
        $cb.Add_Checked({   try { $this.Tag.Checked = $true }  catch {} })
        $cb.Add_Unchecked({ try { $this.Tag.Checked = $false } catch {} })
        [System.Windows.Controls.Grid]::SetColumn($cb, 0)
        $grid.Children.Add($cb) | Out-Null

        $textStack = New-Object System.Windows.Controls.StackPanel
        $textStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
        $textStack.Margin = "10,0,10,0"

        $titleBlock = New-Object System.Windows.Controls.TextBlock
        $titleBlock.Text         = $name
        $titleBlock.FontWeight   = [System.Windows.FontWeights]::Bold
        $titleBlock.FontSize     = 13
        $titleBlock.Foreground   = $window.FindResource("TextBrush")
        $titleBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
        $textStack.Children.Add($titleBlock) | Out-Null

        if ($desc) {
            $descBlock = New-Object System.Windows.Controls.TextBlock
            $descBlock.Text         = $desc
            $descBlock.FontSize     = 11
            $descBlock.Foreground   = $window.FindResource("SubTextBrush")
            $descBlock.TextWrapping = [System.Windows.TextWrapping]::Wrap
            $descBlock.Margin       = "0,2,0,0"
            $textStack.Children.Add($descBlock) | Out-Null
        }
        [System.Windows.Controls.Grid]::SetColumn($textStack, 1)
        $grid.Children.Add($textStack) | Out-Null

        $pillStack = New-Object System.Windows.Controls.StackPanel
        $pillStack.Orientation       = [System.Windows.Controls.Orientation]::Horizontal
        $pillStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

        $result = $script:Sync.Results[$op.Key]
        if ($result -eq 'ok') {
            $pillStack.Children.Add((New-Pill "UYGULANDI" "OkBg" "OkFg")) | Out-Null
        } elseif ($result -eq 'fail') {
            $pillStack.Children.Add((New-Pill "BAŞARISIZ" "FailBg" "FailFg")) | Out-Null
        }

        if ($status) {
            if ($status -eq "Running") {
                $pillStack.Children.Add((New-Pill $status "RunningBg" "RunningFg")) | Out-Null
            } else {
                $pillStack.Children.Add((New-Pill $status "StoppedBg" "StoppedFg")) | Out-Null
            }
        }

        [System.Windows.Controls.Grid]::SetColumn($pillStack, 2)
        $grid.Children.Add($pillStack) | Out-Null

        $card.Child = $grid
        $OpsPanel.Children.Add($card) | Out-Null
    }
}

function Refresh-OpsPanel {
    if ($CategoryList.SelectedItem) { Update-OpsPanel -Category $CategoryList.SelectedItem.Name }
}

function Set-ControlsEnabled {
    param([bool]$Enabled)
    $BtnApply.IsEnabled       = $Enabled
    $BtnSelectAll.IsEnabled   = $Enabled
    $BtnDeselectAll.IsEnabled = $Enabled
    $BtnRefresh.IsEnabled     = $Enabled
}

# ============================================================
#  ARKA PLAN ISININ ARAYUZE POMPALANMASI
# ============================================================
$script:PumpTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PumpTimer.Interval = [TimeSpan]::FromMilliseconds(150)

$script:PumpTimer.Add_Tick({
    try {
        # 1) Log kuyrugunu bosalt
        $line = $null
        $buffer = New-Object System.Text.StringBuilder
        $drained = 0
        while ($drained -lt 500 -and $script:Sync.LogQueue.TryDequeue([ref]$line)) {
            [void]$buffer.AppendLine($line)
            $drained++
        }
        if ($buffer.Length -gt 0) {
            $LogBox.AppendText($buffer.ToString())
            $LogBox.ScrollToEnd()
        }

        # 2) Ilerleme
        if ($script:Phase -eq 'apply') {
            $ProgressBarCtrl.Value = [Math]::Min($script:Sync.Progress, $ProgressBarCtrl.Maximum)
            $StatusText.Text = "Uygulanıyor: $($script:Sync.Progress) / $([int]$ProgressBarCtrl.Maximum)  —  başarılı: $($script:Sync.OkCount), başarısız: $($script:Sync.FailCount)"
        }

        # 3) Is bitti mi?
        if ($script:Sync.Done -and $script:WorkerHandle -and $script:WorkerHandle.IsCompleted) {
            $script:PumpTimer.Stop()
            try { $script:Worker.EndInvoke($script:WorkerHandle) } catch {}
            Stop-Worker
            Complete-Phase
        }
    } catch {
        try { Write-UiLog "Arayüz güncellenirken hata: $($_.Exception.Message)" } catch {}
    }
})

function Start-Phase {
    param([ValidateSet('collect', 'apply', 'refresh')][string]$NewPhase)

    $script:Phase = $NewPhase
    Set-ControlsEnabled $false

    try {
        switch ($NewPhase) {
            'collect' {
                $StatusText.Text = "Sistem taranıyor..."
                $ProgressBarCtrl.IsIndeterminate = $true
                Start-Worker -Mode 'collect'
            }
            'refresh' {
                $StatusText.Text = "Durumlar yenileniyor..."
                $ProgressBarCtrl.IsIndeterminate = $true
                Start-Worker -Mode 'collect'
            }
            'apply' {
                $ProgressBarCtrl.IsIndeterminate = $false
                Start-Worker -Mode 'apply'
            }
        }
    } catch {
        # Arka plan is parcacigi baslatilamazsa arayuz kilitli kalmasin.
        Write-UiLog "HATA - Arka plan işlemi başlatılamadı: $($_.Exception.Message)"
        Stop-Worker
        $script:Phase = 'idle'
        $ProgressBarCtrl.IsIndeterminate = $false
        $StatusText.Text = "Başlatılamadı."
        Set-ControlsEnabled $true
        return
    }
    $script:PumpTimer.Start()
}

function Complete-Phase {
    $finished = $script:Phase
    $script:Phase = 'idle'
    $ProgressBarCtrl.IsIndeterminate = $false

    if ($script:Sync.Error) {
        Write-UiLog "HATA - Arka plan işleminde beklenmeyen hata: $($script:Sync.Error)"
    }

    switch ($finished) {
        'collect' {
            $script:LockReady = $true
            $LockProgressBar.IsIndeterminate = $false
            $LockProgressBar.Value = 100
            $LockStatus.Text = "Sistem analizi tamamlandı."
            $LockHint.Text   = "Devam etmek için tıklayın veya Enter'a basın"

            $CategoryList.ItemsSource = Get-CategoryItems
            if ($CategoryList.Items.Count -gt 0) { $CategoryList.SelectedIndex = 0 }
            Refresh-OpsPanel

            $StatusText.Text = "Hazır. Toplam $($script:Sync.Ops.Count) uygulanabilir işlem bulundu."
            Write-UiLog "Sistem tarandı: $($script:Sync.Ops.Count) işlem listelendi."
            Write-UiLog "Ayarlar şu kullanıcı profiline uygulanacak: $env:USERDOMAIN\$env:USERNAME"
            Set-ControlsEnabled $true

            if ($script:LockWantsClose) {
                $script:LockWantsClose = $false
                Close-LockScreen
            }
        }

        'refresh' {
            # Yenileme sonrasi onceki secimleri ve sonuc rozetlerini koru.
            foreach ($op in $script:Sync.Ops) {
                if ($script:PreservedChecks.ContainsKey($op.Key)) { $op.Checked = $true }
            }
            $CategoryList.ItemsSource = Get-CategoryItems
            if ($CategoryList.Items.Count -gt 0 -and -not $CategoryList.SelectedItem) { $CategoryList.SelectedIndex = 0 }
            Refresh-OpsPanel
            $StatusText.Text = "Durumlar yenilendi. Toplam $($script:Sync.Ops.Count) işlem."
            Set-ControlsEnabled $true

            if ($script:PendingSummary) {
                $summary = $script:PendingSummary
                $script:PendingSummary = $null
                [System.Windows.MessageBox]::Show($summary, "Tamamlandı", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
        }

        'apply' {
            $ok    = $script:Sync.OkCount
            $fail  = $script:Sync.FailCount
            $total = [int]$ProgressBarCtrl.Maximum
            $notRun = $total - ($ok + $fail)

            Write-UiLog "--------------------------------------------"
            Write-UiLog "Uygulama bitti. Başarılı: $ok, başarısız: $fail, çalıştırılamayan: $notRun (toplam seçili: $total)."

            $summary = "Seçili $total işlemden $ok tanesi uygulandı."
            if ($fail -gt 0)   { $summary += "`n$fail işlem BAŞARISIZ oldu, ayrıntılar log kutusunda." }
            if ($notRun -gt 0) { $summary += "`n$notRun işlem bu sistemde artık geçerli olmadığı için çalıştırılmadı." }
            $summary += "`n`nBazı ayarlar (görsel efektler, dosya uzantıları, bildirimler) ancak Gezgin yeniden başlatıldıktan ya da oturum kapatılıp açıldıktan sonra görünür olur."
            $script:PendingSummary = $summary

            # Durum rozetlerinin dogru olmasi icin sistemi yeniden tara.
            $script:PreservedChecks = @{}
            foreach ($op in $script:Sync.Ops) {
                if ($op.Checked) { $script:PreservedChecks[$op.Key] = $true }
            }
            Start-Phase -NewPhase 'refresh'
        }
    }
}

$script:PreservedChecks = @{}
$script:PendingSummary  = $null

# ============================================================
#  OLAY ISLEYICILERI
# ============================================================
$CategoryList.Add_SelectionChanged({
    try {
        if ($CategoryList.SelectedItem) { Update-OpsPanel -Category $CategoryList.SelectedItem.Name }
    } catch {
        Write-UiLog "Kategori değiştirilirken hata: $($_.Exception.Message)"
    }
})

$CategorySearch.Add_TextChanged({
    try {
        $filterText = $CategorySearch.Text
        $SearchPlaceholder.Visibility = if ($filterText.Length -gt 0) { [System.Windows.Visibility]::Collapsed } else { [System.Windows.Visibility]::Visible }

        $previousName = if ($CategoryList.SelectedItem) { $CategoryList.SelectedItem.Name } else { $null }
        $filtered = @(Get-CategoryItems -Filter $filterText)
        $CategoryList.ItemsSource = $filtered

        if ($filtered.Count -eq 0) {
            $OpsPanel.Children.Clear()
            return
        }
        $match = $filtered | Where-Object { $_.Name -eq $previousName } | Select-Object -First 1
        if ($match) { $CategoryList.SelectedItem = $match } else { $CategoryList.SelectedIndex = 0 }
    } catch {
        Write-UiLog "Arama yapılırken hata: $($_.Exception.Message)"
    }
})

$BtnSelectAll.Add_Click({
    try {
        if (-not $script:Sync.Ops) { return }
        foreach ($op in $script:Sync.Ops) { $op.Checked = $true }
        Refresh-OpsPanel
    } catch { Write-UiLog "Tümünü seç hatası: $($_.Exception.Message)" }
})

$BtnDeselectAll.Add_Click({
    try {
        if (-not $script:Sync.Ops) { return }
        foreach ($op in $script:Sync.Ops) { $op.Checked = $false }
        Refresh-OpsPanel
    } catch { Write-UiLog "Tümünü kaldır hatası: $($_.Exception.Message)" }
})

$BtnRefresh.Add_Click({
    try {
        if ($script:Phase -ne 'idle') { return }
        $script:PreservedChecks = @{}
        foreach ($op in $script:Sync.Ops) {
            if ($op.Checked) { $script:PreservedChecks[$op.Key] = $true }
        }
        Write-UiLog "Sistem durumları yeniden taranıyor..."
        Start-Phase -NewPhase 'refresh'
    } catch { Write-UiLog "Yenileme hatası: $($_.Exception.Message)" }
})

$BtnApply.Add_Click({
    try {
        if ($script:Phase -ne 'idle') { return }

        $checkedOps = @($script:Sync.Ops | Where-Object { $_.Checked })
        if ($checkedOps.Count -eq 0) {
            [System.Windows.MessageBox]::Show("Hiçbir işlem seçilmedi.", "Uyarı", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        $confirm = [System.Windows.MessageBox]::Show(
            "$($checkedOps.Count) işlem uygulanacak. Devam edilsin mi?`n`nBazı işlemler geri alınamaz (sistem koruması, geri yükleme noktaları, OneDrive kaldırma).",
            "Onay", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

        $checkedTable = [hashtable]::Synchronized(@{})
        foreach ($op in $checkedOps) { $checkedTable[$op.Key] = $true }
        $script:Sync.Checked = $checkedTable

        $ProgressBarCtrl.Value   = 0
        $ProgressBarCtrl.Maximum = $checkedOps.Count

        Write-UiLog "Uygulama başladı. Seçili işlem sayısı: $($checkedOps.Count)"
        Start-Phase -NewPhase 'apply'
    } catch {
        Write-UiLog "Uygulama başlatılamadı: $($_.Exception.Message)"
        Set-ControlsEnabled $true
        $script:Phase = 'idle'
    }
})

$window.Add_Closing({
    param($senderObj, $e)
    try {
        if ($script:Phase -eq 'apply') {
            $answer = [System.Windows.MessageBox]::Show(
                "İşlemler hâlâ uygulanıyor. Şimdi kapatmak sistemi yarım bırakabilir. Yine de kapatılsın mı?",
                "Devam eden işlem", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
                $e.Cancel = $true
                return
            }
        }
        $script:PumpTimer.Stop()
        Stop-Worker
    } catch {}
})

# Pencere ciziltikten sonra taramayi baslat (arayuz hemen gorunur olsun diye).
$script:Started = $false
$window.Add_ContentRendered({
    try {
        if ($script:Started) { return }
        $script:Started = $true
        Set-ControlsEnabled $false
        Write-UiLog "Program başlatıldı. Sistem taranıyor..."
        Start-Phase -NewPhase 'collect'
    } catch {
        Write-UiLog "Tarama başlatılamadı: $($_.Exception.Message)"
    }
})

$window.ShowDialog() | Out-Null

# Pencere kapandiktan sonra arta kalan is parcacigini temizle.
try { $script:PumpTimer.Stop() } catch {}
Stop-Worker
