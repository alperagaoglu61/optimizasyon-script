#Requires -Version 5.1
<#
    optimize-windows.ps1
    ---------------------
    Windows optimizasyon scripti.
    - Yönetici (admin) yetkisi zorunludur, script kendini otomatik yükseltmeye çalışır.
    - Her işlem öncesi kullanıcıdan onay ister (varsayılan: Hayır).
    - Menüden istenilen kategoriler seçilerek uygulanabilir.
    - Değişiklik yapmadan önce ilgili ayarların bir kısmı için geri alma bilgisi ekrana yazılır.

    KULLANIM:
        PowerShell'i normal (admin olmayan) kullanıcı olarak açıp şunu çalıştırman yeterli:
        .\optimize-windows.ps1
        Script kendini otomatik olarak "Yönetici olarak çalıştır" ile yeniden başlatacaktır.

        Eğer script çalışmıyor derse, önce şunu bir kere (admin PowerShell'de) çalıştır:
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#>

# ============================================================
#  0. YÖNETİCİ YETKİSİ KONTROLÜ VE OTOMATİK YÜKSELTME
# ============================================================
function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "Bu script yönetici yetkisi gerektiriyor. Yükseltilmiş bir pencere açılıyor..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try {
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {
        Write-Host "Yönetici yetkisi verilmedi, script sonlandırılıyor." -ForegroundColor Red
    }
    exit
}

$ErrorActionPreference = "Continue"
$logFile = Join-Path $env:USERPROFILE "Desktop\optimize-windows-log.txt"

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $logFile -Value $line
    Write-Host $Message -ForegroundColor Cyan
}

function Confirm-Action {
    param([string]$Question)
    $answer = Read-Host "$Question [e/H]"
    return ($answer -match '^(e|E|y|Y)$')
}

# ============================================================
#  1. SERVİSLER
# ============================================================
function Optimize-Services {
    Write-Host "`n=== GEREKSİZ SERVİSLER ===" -ForegroundColor Green
    # Servis adı => Açıklama. Sadece genelde güvenle kapatılabilen servisler listelendi.
    $services = @{
        "DiagTrack"              = "Bağlantılı Kullanıcı Deneyimleri ve Telemetri (veri toplama)"
        "dmwappushservice"       = "WAP Push Mesaj Yönlendirme (telemetri ile ilişkili)"
        "MapsBroker"             = "Downloaded Maps Manager (çevrimdışı harita kullanmıyorsan gereksiz)"
        "lfsvc"                  = "Geolocation Service (konum servisi kullanmıyorsan)"
        "RetailDemo"             = "Retail Demo Service (mağaza demo modu, ev kullanıcısına gereksiz)"
        "WMPNetworkSvc"          = "Windows Media Player Ağ Paylaşım Servisi"
        "RemoteRegistry"         = "Uzaktan Registry erişimi (güvenlik açısından kapalı kalması iyi)"
        "Fax"                    = "Faks servisi"
        # --- Hizmetler ekranında zaten "Devre Dışı" görünen ek Windows bileşenleri ---
        "UevAgentService"        = "User Experience Virtualization Service (App-V/UE-V bileşeni, ev kullanıcısına gereksiz)"
        "tzautoupdate"           = "Otomatik Saat Dilimi Güncelleyici (saat dilimini elle ayarlıyorsan gereksiz)"
        "TrkWks"                 = "Dağıtılmış Bağlantı İzleme İstemcisi (ağ NTFS kısayol takibi, ev kullanımında gereksiz)"
        "ssh-agent"              = "OpenSSH Authentication Agent (SSH anahtarı kullanmıyorsan gereksiz)"
        "Spooler"                = "Yazdırma Biriktiricisi (DİKKAT: yazıcı/'PDF olarak yazdır' kullanıyorsan KAPATMA)"
        "shpamsvc"               = "Shared PC Account Manager (paylaşımlı/kiosk PC modu kullanmıyorsan gereksiz)"
        "RmSvc"                  = "Radyo Yönetimi Hizmeti (uçak modu donanım yönetimi, çoğu sistemde gereksiz)"
        "RemoteAccess"           = "Yönlendirme ve Uzaktan Erişim (VPN/router görevi görmüyorsan gereksiz)"
        "PcaSvc"                 = "Program Uyumluluk Yardımcısı Hizmeti (eski program uyumluluk uyarıları)"
        "NetTcpPortSharing"      = "Net.Tcp Bağlantı Noktası Paylaşımı (WCF uygulaması kullanmıyorsan gereksiz)"
        "MsKeyboardFilter"       = "Microsoft Klavye Filtresi (kiosk modunda kullanılır, ev kullanıcısına gereksiz)"
        "DPS"                    = "Tanı İlkesi Hizmeti (Windows sorun giderme sihirbazlarını devre dışı bırakır)"
        "CscService"             = "Çevrimdışı Dosyalar (ağ paylaşımı çevrimdışı kullanmıyorsan gereksiz)"
        "AppVClient"             = "Microsoft App-V Client (uygulama sanallaştırma, ev kullanıcısına gereksiz)"
        # --- Donanıma bağlı (kullanmıyorsan güvenle kapatılabilir) ---
        "WbioSrvc"               = "Windows Biometric Service (parmak izi/yüz tanıma - Windows Hello kullanmıyorsan gereksiz)"
        "SCardSvr"               = "Smart Card (akıllı kart okuyucu kullanmıyorsan gereksiz)"
        "ScDeviceEnum"           = "Smart Card Device Enumeration Service (akıllı kart cihaz numaralandırma)"
        # --- Xbox ile ilgili (Xbox app/Game Pass kullanmıyorsan) ---
        "XblAuthManager"         = "Xbox Live Auth Manager"
        "XblGameSave"            = "Xbox Live Game Save"
        "XboxNetApiSvc"          = "Xbox Live Networking Service"
        "XboxGipSvc"             = "Xbox Accessory Management Service"
        # --- Diğer ---
        "CDPSvc"                 = "Connected Devices Platform Service (Telefonum/Yakındaki Paylaşım kullanmıyorsan gereksiz)"
        "SSDPSRV"                = "SSDP Discovery (ağ cihazı keşfi/DLNA kullanmıyorsan gereksiz)"
        "upnphost"               = "UPnP Device Host (cast/DLNA kullanmıyorsan gereksiz)"
        "wisvc"                  = "Windows Insider Service (Insider programına kayıtlı değilsen gereksiz)"
        # --- Sensör/kamera (masaüstü/çoğu laptopta donanımı yok) ---
        "SensrSvc"               = "Sensor Monitoring Service (ortam ışığı sensörü vb. donanım yoksa gereksiz)"
        "SensorService"          = "Sensor Service (donanım sensörü yoksa gereksiz)"
        "SensorDataService"      = "Sensor Data Service (donanım sensörü yoksa gereksiz)"
        # --- Bağlantı/paylaşım (kullanmıyorsan) ---
        "icssvc"                 = "Windows Mobile Hotspot Service (internet paylaşımı kullanmıyorsan gereksiz)"
        "TermService"            = "Remote Desktop Services (DİKKAT: bu PC'ye RDP ile uzaktan bağlanıyorsan KAPATMA)"
        "WPCMonSvc"               = "Parental Controls (Aile Güvenliği/çocuk hesabı kullanmıyorsan gereksiz)"
        "ALG"                    = "Application Layer Gateway Service (eski NAT yardımcı servisi, günümüzde nadiren kullanılır)"
        # --- Eski/legacy ---
        "RpcLocator"             = "RPC Locator (legacy servis, modern Windows'ta zaten genelde pasif)"
    }

    foreach ($svcName in $services.Keys) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($null -eq $svc) { continue }
        $desc = $services[$svcName]
        if (Confirm-Action "`"$svcName`" ($desc) servisini durdurup devre dışı bırakayım mı? Mevcut durum: $($svc.Status)") {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop
                Write-Log "Servis devre dışı bırakıldı: $svcName"
            } catch {
                Write-Log "HATA - $svcName devre dışı bırakılamadı: $_"
            }
        }
    }

    # --- OEM servisleri (HP / Intel / diğer üreticiye özel) ---
    # Bu servislerin gerçek "Name" değeri cihazdan cihaza değişebildiği için görünen ada (DisplayName) göre aranıyor.
    Write-Host "`n--- OEM (HP/Intel) servisleri ---" -ForegroundColor Green
    $displayNamePatterns = @(
        "Intel(R) SUR QC Software Asset Manager*",
        "HP Insights Analytics*",
        "HP System Info HSA Service*",
        "HP Omen HSA Service*",
        "HP Network HSA Service*",
        "HP Diagnostics HSA Service*",
        "HP App Helper HSA Service*",
        "Intel(R) Driver & Support Assistant*",
        "DialogBlockingService*"
    )
    foreach ($pattern in $displayNamePatterns) {
        $matches = Get-Service -DisplayName $pattern -ErrorAction SilentlyContinue
        foreach ($svc in $matches) {
            if (Confirm-Action "`"$($svc.DisplayName)`" servisini durdurup devre dışı bırakayım mı? Mevcut durum: $($svc.Status)") {
                try {
                    Stop-Service -InputObject $svc -Force -ErrorAction SilentlyContinue
                    Set-Service -InputObject $svc -StartupType Disabled -ErrorAction Stop
                    Write-Log "Servis devre dışı bırakıldı: $($svc.DisplayName) ($($svc.Name))"
                } catch {
                    Write-Log "HATA - $($svc.DisplayName) devre dışı bırakılamadı: $_"
                }
            }
        }
    }

    Write-Host "Not: SysMain (Superfetch) ve Windows Search gibi bazı servisler SSD'lerde kapatılabilir ama HDD'de kapatman önerilmez." -ForegroundColor DarkYellow
    if (Confirm-Action "SysMain (Superfetch) servisini de devre dışı bırakayım mı? (SSD kullanıyorsan önerilir)") {
        Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Log "Servis devre dışı bırakıldı: SysMain"
    }
}

# ============================================================
#  2. BAŞLANGIÇ PROGRAMLARI
# ============================================================
function Optimize-Startup {
    Write-Host "`n=== BAŞLANGIÇ PROGRAMLARI ===" -ForegroundColor Green
    $items = Get-CimInstance Win32_StartupCommand | Select-Object Name, Command, Location, User
    if (-not $items) {
        Write-Host "Başlangıç öğesi bulunamadı." -ForegroundColor Yellow
        return
    }
    $i = 1
    foreach ($item in $items) {
        Write-Host "$i) $($item.Name)  -> $($item.Command)" -ForegroundColor White
        $i++
    }
    Write-Host "`nBaşlangıç programlarını doğrudan registry üzerinden kapatmak riskli olabileceğinden,"
    Write-Host "bunun yerine Görev Yöneticisi > Başlangıç sekmesini açmanı öneriyorum."
    if (Confirm-Action "Görev Yöneticisini Başlangıç sekmesinde açayım mı?") {
        Start-Process "taskmgr.exe" "/0" -WindowStyle Normal
        Write-Log "Görev Yöneticisi Başlangıç sekmesi açıldı."
    }

    if (Confirm-Action "Ayarlar > Uygulamalar > Başlangıç listesindeki TÜM uygulamaları devre dışı bırakayım mı? (Registry Run anahtarlarından başlayan klasik uygulamalar; UWP/Store arka plan görevlerini kapsamayabilir)") {
        $startupApprovedKeys = @(
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
        )
        # Windows'un "Kapalı" durumu için kullandığı 12 byte'lık işaretleyici: ilk byte 03 = devre dışı.
        $disabledMarker = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
        $count = 0
        foreach ($key in $startupApprovedKeys) {
            if (-not (Test-Path $key)) { continue }
            $names = (Get-Item -Path $key).Property
            foreach ($name in $names) {
                try {
                    Set-ItemProperty -Path $key -Name $name -Value $disabledMarker -Type Binary
                    Write-Log "Başlangıç uygulaması devre dışı bırakıldı: $name"
                    $count++
                } catch {
                    Write-Log "HATA - $name devre dışı bırakılamadı: $_"
                }
            }
        }
        Write-Host "$count başlangıç uygulaması devre dışı bırakıldı." -ForegroundColor Cyan
    }

    if (Confirm-Action "Explorer başlangıç gecikmesini sıfırlayayım mı? (Windows varsayılan olarak başlangıç uygulamalarını ~10 saniye geciktirir, bu süreyi kaldırır)") {
        $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "StartupDelayInMSec" -Value 0 -Type DWord
        Write-Log "Explorer başlangıç gecikmesi sıfırlandı."
    }
}

# ============================================================
#  3. GÖRSEL EFEKTLER / PERFORMANS AYARLARI
# ============================================================
function Optimize-VisualEffects {
    Write-Host "`n=== GÖRSEL EFEKTLER ===" -ForegroundColor Green
    if (Confirm-Action "Görsel efektleri 'En iyi performans' moduna alayım mı? (animasyonlar, gölgeler vb. kapanır)") {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "VisualFXSetting" -Value 2 -Type DWord
        Write-Log "Görsel efektler 'En iyi performans' olarak ayarlandı (Explorer yeniden başlatılmalı)."
    }
    if (Confirm-Action "Şeffaflık efektlerini kapatayım mı?") {
        Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Type DWord
        Write-Log "Şeffaflık efektleri kapatıldı."
    }
    if (Confirm-Action "Animasyonları (pencere açılış/kapanış) kapatayım mı?") {
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value 0 -Type String
        Write-Log "Pencere animasyonları kapatıldı."
    }

    if (Confirm-Action "Windows Game Bar'ı kapatayım mı? (Kumandanızın Game Bar'ı açması + Game DVR arka plan kaydı)") {
        $gameDvrPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR"
        if (-not (Test-Path $gameDvrPath)) { New-Item -Path $gameDvrPath -Force | Out-Null }
        Set-ItemProperty -Path $gameDvrPath -Name "AppCaptureEnabled" -Value 0 -Type DWord

        $gameConfigPath = "HKCU:\System\GameConfigStore"
        if (-not (Test-Path $gameConfigPath)) { New-Item -Path $gameConfigPath -Force | Out-Null }
        Set-ItemProperty -Path $gameConfigPath -Name "GameDVR_Enabled" -Value 0 -Type DWord

        $gameBarPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
        if (-not (Test-Path $gameBarPath)) { New-Item -Path $gameBarPath -Force | Out-Null }
        Set-ItemProperty -Path $gameBarPath -Name "UseNexusForGameBarEnabled" -Value 0 -Type DWord

        # Politika seviyesinde de kapatarak Game Bar'ın tamamen açılmasını engelliyoruz.
        $policyPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
        if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "AllowGameDVR" -Value 0 -Type DWord

        Write-Log "Windows Game Bar kapatıldı."
    }

    if (Confirm-Action "Oyun Modunu (Game Mode) açayım mı?") {
        $gameBarPath = "HKCU:\SOFTWARE\Microsoft\GameBar"
        if (-not (Test-Path $gameBarPath)) { New-Item -Path $gameBarPath -Force | Out-Null }
        Set-ItemProperty -Path $gameBarPath -Name "AutoGameModeEnabled" -Value 1 -Type DWord
        Write-Log "Oyun Modu açıldı."
    }

    if (Confirm-Action "Dosya uzantılarının her zaman gösterilmesini sağlayayım mı? (.txt, .exe gibi uzantılar görünür olur)") {
        $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Set-ItemProperty -Path $path -Name "HideFileExt" -Value 0 -Type DWord
        Write-Log "Dosya uzantıları gösteriliyor olarak ayarlandı (Gezgin yeniden başlatılmalı)."
    }

    if (Confirm-Action "Görev çubuğu Widget'lar (haber/hava durumu) düğmesini kapatayım mı?") {
        $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Set-ItemProperty -Path $path -Name "TaskbarDa" -Value 0 -Type DWord
        Write-Log "Görev çubuğu Widget'lar düğmesi kapatıldı."
    }
}

# ============================================================
#  4. GEÇİCİ DOSYA / ÖNBELLEK TEMİZLİĞİ
# ============================================================
function Optimize-TempCleanup {
    Write-Host "`n=== GEÇİCİ DOSYA / ÖNBELLEK TEMİZLİĞİ ===" -ForegroundColor Green

    if (Confirm-Action "Windows ve kullanıcı Temp klasörlerini (%TEMP% ve C:\Windows\Temp) temizleyeyim mi?") {
        $paths = @($env:TEMP, "$env:WINDIR\Temp")
        foreach ($p in $paths) {
            Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Temp klasörleri temizlendi."
    }

    if (Confirm-Action "Prefetch klasörünü (C:\Windows\Prefetch) temizleyeyim mi?") {
        Remove-Item -Path "$env:WINDIR\Prefetch\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Prefetch klasörü temizlendi."
    }

    if (Confirm-Action "Son kullanılan öğeler (Recent) klasörünü temizleyeyim mi?") {
        Remove-Item -Path "$env:APPDATA\Microsoft\Windows\Recent\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Recent klasörü temizlendi."
    }

    if (Confirm-Action "Uygulama çökme dökümlerini (C:\Users\$env:USERNAME\AppData\Local\CrashDumps) temizleyeyim mi?") {
        Remove-Item -Path "$env:LOCALAPPDATA\CrashDumps\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "CrashDumps klasörü temizlendi."
    }

    if (Confirm-Action "Event Viewer (Olay Görüntüleyici) günlüklerini temizleyeyim mi? (Uygulama, Sistem, Güvenlik ve diğer tüm günlükler sıfırlanır)") {
        $logs = Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 }
        $cleared = 0
        foreach ($log in $logs) {
            try {
                wevtutil cl "$($log.LogName)" 2>$null
                $cleared++
            } catch {}
        }
        Write-Log "Event Viewer günlükleri temizlendi ($cleared günlük)."
    }

    if (Confirm-Action "Windows Update indirme önbelleğini (C:\Windows\SoftwareDistribution\Download) temizleyeyim mi?") {
        Stop-Service -Name wuauserv -Force
        Remove-Item -Path "$env:WINDIR\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv
        Write-Log "Windows Update önbelleği temizlendi."
    }

    if (Confirm-Action "Geri Dönüşüm Kutusunu boşaltayım mı?") {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Write-Log "Geri Dönüşüm Kutusu boşaltıldı."
    }

    if (Confirm-Action "Simge/Thumbnail önbelleğini temizleyeyim mi? (bozuk/eski görünen simgeleri düzeltir, Gezgin yeniden başlatılır)") {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:LOCALAPPDATA\IconCache.db" -Force -ErrorAction SilentlyContinue
        Start-Process explorer.exe
        Write-Log "Simge/Thumbnail önbelleği temizlendi."
    }

    if (Confirm-Action "Disk Temizleme aracını 'Sistem dosyalarını temizle' seçeneği zaten etkinmiş gibi, TÜM kategoriler (Sistem Geri Yükleme ve Gölge Kopyaları dahil) işaretli şekilde tamamen otomatik çalıştırayım mı? (Manuel onay istemeden direkt temizler; en son geri yükleme noktası hariç eskiler silinir)") {
        $sageNum = "0064"
        $vcPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
        $categories = Get-ChildItem -Path $vcPath -ErrorAction SilentlyContinue
        foreach ($cat in $categories) {
            try {
                Set-ItemProperty -Path $cat.PSPath -Name "StateFlags$sageNum" -Value 2 -Type DWord -ErrorAction SilentlyContinue
            } catch {}
        }
        Write-Log "Disk Temizleme'deki tüm kategoriler (Sistem Geri Yükleme ve Gölge Kopyaları dahil) işaretlendi."
        Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:$sageNum" -Wait
        Write-Log "Disk Temizleme (sistem dosyaları + tüm kategoriler) tamamlandı."
    }
}

# ============================================================
#  5. AĞ / DNS AYARLARI
# ============================================================
function Optimize-Network {
    Write-Host "`n=== AĞ / DNS AYARLARI ===" -ForegroundColor Green

    if (Confirm-Action "DNS Cache'i temizleyeyim mi (ipconfig /flushdns)?") {
        ipconfig /flushdns | Out-Null
        Write-Log "DNS cache temizlendi."
    }

    if (Confirm-Action "Aktif ağ bağdaştırıcısının DNS sunucusunu Google DNS (8.8.8.8 / 8.8.4.4) olarak ayarlayayım mı?") {
        $adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
        if ($adapter) {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses ("8.8.8.8","8.8.4.4")
            Write-Log "DNS sunucuları Google DNS olarak ayarlandı ($($adapter.Name)). Geri almak için: Set-DnsClientServerAddress -InterfaceIndex $($adapter.ifIndex) -ResetServerAddresses"
        } else {
            Write-Host "Aktif ağ bağdaştırıcısı bulunamadı." -ForegroundColor Red
        }
    }

    Write-Host "Not: Nagle algoritması ayarı, ağ bağdaştırıcısına özel bir interface GUID gerektirdiğinden bu script'e otomatik eklenmedi." -ForegroundColor DarkYellow
    Write-Host "İstersen bunu manuel yapman için: Kayıt Defteri'nde HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\<GUID> altına TcpAckFrequency=1 ve TCPNoDelay=1 (DWORD) eklenir." -ForegroundColor DarkYellow
}

# ============================================================
#  6. GÜÇ PLANI AYARLARI
# ============================================================
function Optimize-PowerPlan {
    Write-Host "`n=== GÜÇ PLANI (NİHAİ PERFORMANS) ===" -ForegroundColor Green

    if (-not (Confirm-Action "Nihai Performans planını oluşturup etkinleştireyim ve tüm gelişmiş güç ayarlarını (disk/ekran/kablosuz/USB/PCIe/işlemci/IE) en yüksek performansa göre ayarlayayım mı? (dizüstünde pil ömrünü belirgin şekilde kısaltır)")) {
        return
    }

    $output = powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61
    $scheme = ($output | Select-String -Pattern '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Matches[0].Value
    if (-not $scheme) {
        Write-Log "HATA - Nihai Performans planı oluşturulamadı."
        return
    }
    powercfg -setactive $scheme
    Write-Log "Nihai Performans planı oluşturuldu ve etkinleştirildi. Şema GUID: $scheme"

    function Set-PowerSetting {
        param($SubGroup, $Setting, $Value, $Label)
        powercfg -setacvalueindex $scheme $SubGroup $Setting $Value
        powercfg -setdcvalueindex $scheme $SubGroup $Setting $Value
        Write-Log "  - $Label => $Value (AC ve DC)"
    }

    Set-PowerSetting "0012ee47-9041-4b5d-9b77-535fba8b1442" "6738e2c4-e8a5-4a42-b16a-e040e769756e" 0 "Sabit diski kapat (Hiçbir zaman)"
    Set-PowerSetting "7516b95f-f776-4464-8c53-06167f40cc99" "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e" 0 "Ekranı kapat (Hiçbir zaman)"
    Set-PowerSetting "02f815b5-a5cf-4c84-bf20-649d1f75d3d8" "4c793e7d-a264-42e1-8ec5-7f0db06cbf80" 0 "IE JavaScript Zamanlayıcı Sıklığı (En yüksek performans)"
    Set-PowerSetting "0d7dbae2-4294-402a-ba8e-26777e8488cd" "309dce9b-bef4-4119-9921-a851fb12f0f4" 1 "Masaüstü slayt gösterisi (Duraklatıldı)"
    Set-PowerSetting "19cbb8fa-5279-450e-9fac-8a3d5fedd0c1" "12bbebe6-58d6-4636-95bb-3217ef867c1a" 0 "Kablosuz güç tasarrufu modu (En yüksek performans)"
    Set-PowerSetting "2a737441-1930-4402-8d77-b2bebba308a3" "48e6b7a6-50f5-4782-a5d4-53bb8f07e226" 0 "USB seçmeli askıya alma (Kapalı)"
    Set-PowerSetting "501a4d13-42af-4429-9fd1-a8218c268e20" "ee12f906-d277-404b-b6da-e5fa1a576df5" 0 "PCI Express bağlantı durumu güç yönetimi (Kapalı)"
    Set-PowerSetting "54533251-82be-4824-96c1-47b60b740d00" "893dee8e-2bef-41e0-89c6-b55d0929964c" 100 "İşlemci en düşük durum (%100)"
    Set-PowerSetting "54533251-82be-4824-96c1-47b60b740d00" "bc5038f7-23e0-4960-96da-33abaf5935ec" 100 "İşlemci en yüksek durum (%100)"

    # Intel Graphics Power Plan sadece Intel grafik sürücüsü kurulu sistemlerde mevcuttur.
    try {
        powercfg -setacvalueindex $scheme 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2 2>$null
        powercfg -setdcvalueindex $scheme 44f3beca-a7c0-460e-9df2-bb8b99e0cba6 3619c3f2-afb2-4afc-b0e9-e7fef372de36 2 2>$null
        Write-Log "  - Intel Graphics Power Plan => Maximum Performance (varsa uygulandı)"
    } catch {
        Write-Log "  - Intel Graphics Power Plan ayarı bu sistemde bulunamadı, atlandı."
    }

    powercfg -setactive $scheme
    Write-Log "Tüm gelişmiş güç ayarları uygulandı ve Nihai Performans planı aktif edildi."
}

# ============================================================
#  7. EK OPTİMİZASYONLAR
# ============================================================
function Optimize-Extra {
    Write-Host "`n=== EK OPTİMİZASYONLAR ===" -ForegroundColor Green

    if (Confirm-Action "Hazırda Bekletme (Hibernation) dosyasını kapatayım mı? (SSD'de yer açar, disk alanı kazandırır)") {
        powercfg -h off
        Write-Log "Hibernation kapatıldı."
    }

    if (Confirm-Action "Windows İpuçları/Önerileri bildirimlerini kapatayım mı?") {
        $path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "SubscribedContent-338389Enabled" -Value 0 -Type DWord
        Write-Log "Windows ipuçları/önerileri kapatıldı."
    }

    if (Confirm-Action "Fast Startup'ı (Hızlı Başlatma) kapatayım mı? (bazı sürücü/ağ sorunlarını ve dual-boot disk bozulma riskini önler, kapanma birkaç saniye uzayabilir)") {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
        Set-ItemProperty -Path $path -Name "HiberbootEnabled" -Value 0 -Type DWord
        Write-Log "Fast Startup kapatıldı."
    }

    if (Confirm-Action "SSD için TRIM'in aktif olup olmadığını kontrol edip, kapalıysa otomatik olarak açayım mı?") {
        $trimStatus = fsutil behavior query DisableDeleteNotify
        Write-Host $trimStatus -ForegroundColor White
        if ($trimStatus -match "DisableDeleteNotify\s*=\s*1") {
            fsutil behavior set DisableDeleteNotify 0 | Out-Null
            Write-Log "TRIM kapalıydı, etkinleştirildi."
        } else {
            Write-Log "TRIM zaten etkin, değişiklik yapılmadı."
        }
    }

    if (Confirm-Action "OneDrive'ı kapatıp kaldırayım mı? (senkronizasyon durur, dosyaların diskte kalır; Gezgin'den OneDrive simgesi kaldırılır)") {
        Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
        $oneDriveSetup = "$env:SYSTEMROOT\SysWOW64\OneDriveSetup.exe"
        if (-not (Test-Path $oneDriveSetup)) { $oneDriveSetup = "$env:SYSTEMROOT\System32\OneDriveSetup.exe" }
        if (Test-Path $oneDriveSetup) {
            Start-Process $oneDriveSetup "/uninstall" -Wait -ErrorAction SilentlyContinue
        }
        # Gezgin gezinme bölmesindeki OneDrive kısayolunu gizle
        foreach ($clsid in @("HKCU:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
                              "HKCU:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}")) {
            if (Test-Path $clsid) {
                Set-ItemProperty -Path $clsid -Name "System.IsPinnedToNameSpaceTree" -Value 0 -Type DWord -ErrorAction SilentlyContinue
            }
        }
        Write-Log "OneDrive kaldırıldı."
    }

    if (Confirm-Action "Sayfalama dosyasını (pagefile) sistem yönetimli hale getireyim mi? (Windows RAM/disk durumuna göre otomatik boyutlandırır)") {
        try {
            $cs = Get-WmiObject Win32_ComputerSystem -EnableAllPrivileges
            $cs.AutomaticManagedPagefile = $true
            $cs.Put() | Out-Null
            Write-Log "Sayfalama dosyası sistem yönetimli olarak ayarlandı."
        } catch {
            Write-Log "HATA - Sayfalama dosyası ayarlanamadı: $_"
        }
    }
}

# ============================================================
#  8. BAŞLANGIÇ/KURTARMA + SİSTEM KORUMASI (GELİŞMİŞ SİSTEM ÖZELLİKLERİ)
# ============================================================
function Optimize-SystemAdvanced {
    Write-Host "`n=== BAŞLANGIÇ VE KURTARMA / SİSTEM KORUMASI ===" -ForegroundColor Green

    if (Confirm-Action "İşletim sistemleri listesini gösterme süresini kaldırayım mı (önyükleme menüsü zaman aşımı = 0)?") {
        bcdedit /timeout 0 | Out-Null
        Write-Log "Önyükleme menüsü zaman aşımı 0 olarak ayarlandı (liste gösterilmeyecek)."
    }

    if (Confirm-Action "'Sistem günlüğüne olay olarak yaz' seçeneğini kapatayım mı?") {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "LogEvent" -Value 0 -Type DWord
        Write-Log "Sistem günlüğüne olay yazma kapatıldı."
    }

    if (Confirm-Action "'Otomatik olarak yeniden başlat' seçeneğini kapatayım mı?") {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "AutoReboot" -Value 0 -Type DWord
        Write-Log "Otomatik yeniden başlatma kapatıldı."
    }

    if (Confirm-Action "Sistem korumasını $env:SystemDrive için devre dışı bırakayım mı? (DİKKAT: mevcut geri yükleme noktaları silinir, sorunlu bir sürücü/güncelleme sonrası sistemi eski haline döndürme imkanın kalmaz)") {
        try {
            Disable-ComputerRestore -Drive "$env:SystemDrive\"
            Write-Log "Sistem koruması $env:SystemDrive için devre dışı bırakıldı."
        } catch {
            Write-Log "HATA - Sistem koruması devre dışı bırakılamadı: $_"
        }
    }

    if (Confirm-Action "$env:SystemDrive sürücüsündeki tüm geri yükleme noktalarını (shadow copy) sileyim mi?") {
        try {
            vssadmin delete shadows /for=$env:SystemDrive /all /quiet | Out-Null
            Write-Log "Geri yükleme noktaları silindi ($env:SystemDrive)."
        } catch {
            Write-Log "HATA - Geri yükleme noktaları silinemedi: $_"
        }
    }
}

# ============================================================
#  9. GİZLİLİK / ARKA PLAN
# ============================================================
function Optimize-Privacy {
    Write-Host "`n=== GİZLİLİK / ARKA PLAN AYARLARI ===" -ForegroundColor Green

    if (Confirm-Action "Uygulamaların arka planda çalışmasını (senkronizasyon, arka plan bildirimleri) kapatayım mı?") {
        $path = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name "GlobalUserDisabled" -Value 1 -Type DWord
        Write-Log "Uygulamaların arka planda çalışması kapatıldı."
    }

    if (Confirm-Action "Bildirimleri (toast) ve Eylem Merkezi'ni sınırlayayım mı?") {
        $pushPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications"
        if (-not (Test-Path $pushPath)) { New-Item -Path $pushPath -Force | Out-Null }
        Set-ItemProperty -Path $pushPath -Name "ToastEnabled" -Value 0 -Type DWord

        $advPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        if (-not (Test-Path $advPath)) { New-Item -Path $advPath -Force | Out-Null }
        Set-ItemProperty -Path $advPath -Name "DisableNotificationCenter" -Value 1 -Type DWord
        Write-Log "Bildirimler ve Eylem Merkezi sınırlandı."
    }

    if (Confirm-Action "Cortana ve Start menüsündeki web (Bing) arama sonuçlarını kapatayım mı?") {
        $searchPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
        if (-not (Test-Path $searchPath)) { New-Item -Path $searchPath -Force | Out-Null }
        Set-ItemProperty -Path $searchPath -Name "BingSearchEnabled" -Value 0 -Type DWord
        Set-ItemProperty -Path $searchPath -Name "CortanaConsent" -Value 0 -Type DWord

        $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
        if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "AllowCortana" -Value 0 -Type DWord
        Write-Log "Cortana ve web arama sonuçları kapatıldı."
    }

    if (Confirm-Action "Telemetri/tanılama veri seviyesini en düşük düzeye çekeyim mi? (Home/Pro sürümde tamamen kapatmak mümkün değil, en düşük seviye 'Gerekli/Temel' olur)") {
        $policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
        if (-not (Test-Path $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -Path $policyPath -Name "AllowTelemetry" -Value 1 -Type DWord
        Write-Log "Telemetri seviyesi en düşük düzeye (Gerekli/Temel) çekildi."
    }

    if (Confirm-Action "Telemetri ile ilgili zamanlanmış görevleri (Görev Zamanlayıcı) devre dışı bırakayım mı?") {
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
        foreach ($taskPath in $tasks) {
            $taskName = Split-Path $taskPath -Leaf
            $taskFolder = Split-Path $taskPath -Parent
            try {
                Disable-ScheduledTask -TaskName $taskName -TaskPath "$taskFolder\" -ErrorAction Stop | Out-Null
                Write-Log "Zamanlanmış görev devre dışı bırakıldı: $taskName"
            } catch {
                Write-Log "Atlandı (bulunamadı/zaten kapalı): $taskName"
            }
        }
    }
}

# ============================================================
#  ANA MENÜ
# ============================================================
function Show-Menu {
    Clear-Host
    Write-Host "==================================================" -ForegroundColor Magenta
    Write-Host "         WINDOWS OPTİMİZASYON SCRIPTİ" -ForegroundColor Magenta
    Write-Host "==================================================" -ForegroundColor Magenta
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

Write-Log "Script başlatıldı. Log dosyası: $logFile"

do {
    Show-Menu
    $choice = Read-Host "Seçim yap"
    switch ($choice) {
        "1" { Optimize-Services }
        "2" { Optimize-Startup }
        "3" { Optimize-VisualEffects }
        "4" { Optimize-TempCleanup }
        "5" { Optimize-Network }
        "6" { Optimize-PowerPlan }
        "7" { Optimize-Extra }
        "8" { Optimize-SystemAdvanced }
        "9" { Optimize-Privacy }
        "10" {
            Optimize-Services
            Optimize-Startup
            Optimize-VisualEffects
            Optimize-TempCleanup
            Optimize-Network
            Optimize-PowerPlan
            Optimize-SystemAdvanced
            Optimize-Extra
            Optimize-Privacy
        }
        "0" { Write-Host "Çıkılıyor..." -ForegroundColor Yellow }
        default { Write-Host "Geçersiz seçim." -ForegroundColor Red }
    }
    if ($choice -ne "0") {
        Read-Host "`nDevam etmek için Enter'a bas"
    }
} while ($choice -ne "0")

Write-Log "Script tamamlandı."
Write-Host "`nTüm işlemler $logFile dosyasına kaydedildi." -ForegroundColor Green
