# Windows Optimizasyon Script

Windows 10/11 için performans, gizlilik ve disk temizliği ayarlarını tek yerden yöneten PowerShell aracı. İki sürümü var: konsol (menü tabanlı) ve WPF GUI (checkbox tabanlı).

## Sürümler

| Dosya | Açıklama |
|---|---|
| `optimize-windows.ps1` | Konsol sürümü. Numaralı menü, her işlem öncesi `[e/H]` onayı ister. |
| `optimize-windows-gui.ps1` | WPF GUI sürümü. Koyu tema, kilit ekranı, kategori bazlı checkbox listesi, ilerleme çubuğu ve canlı log kutusu. |
| `optimize-windows-gui.exe` | GUI sürümünün ps2exe ile derlenmiş hâli. Konsol penceresi açmaz, çift tıklayınca UAC otomatik sorar. |

GUI sürümündeki tüm optimizasyon mantığı (`Optimize-*` fonksiyonları) konsol sürümüyle birebir aynı; sadece onay mekanizması `Read-Host` yerine checkbox'lara bağlanmış.

## Özellikler

Aşağıdaki kategoriler altında, her biri ayrı onay/checkbox ile seçilebilir:

1. **Gereksiz servisler** — telemetri, Xbox, biyometrik, sensör, faks vb. onlarca servisi güvenle devre dışı bırakma
2. **Başlangıç programları** — Görev Yöneticisi'ni açma, Registry üzerinden başlangıç uygulamalarını kapatma, Explorer başlangıç gecikmesini sıfırlama
3. **Görsel efektler** — "En iyi performans" modu, şeffaflık/animasyon kapatma, Game Bar, dosya uzantıları, görev çubuğu widget'ları
4. **Geçici dosya / önbellek temizliği** — Temp, Prefetch, Recent, CrashDumps, Event Viewer günlükleri, Windows Update önbelleği, Geri Dönüşüm Kutusu, thumbnail/icon cache, Disk Temizleme
5. **Ağ / DNS** — DNS cache temizleme, Google DNS'e geçiş
6. **Güç planı** — Nihai Performans şeması oluşturma ve tüm gelişmiş güç ayarlarını en yükseğe çekme
7. **Ek optimizasyonlar** — Hibernation kapatma, bildirimler, Fast Startup, SSD TRIM kontrolü, OneDrive kaldırma, pagefile
8. **Başlangıç/Kurtarma ve Sistem Koruması** — boot menü zaman aşımı, crash log/reboot ayarları, sistem geri yükleme noktaları
9. **Gizlilik / arka plan** — arka plan uygulamaları, bildirimler, Cortana/Bing arama, telemetri seviyesi ve ilgili zamanlanmış görevler

Tüm kritik/geri alınması zor işlemler için ekranda uyarı notu var (ör. Spooler, RDP, sistem koruması, güç tasarrufu).

## Kullanım

### GUI (önerilen)

`optimize-windows-gui.exe` dosyasını çift tıkla. UAC istemini onayla, açılan kilit ekranına tıkla veya Enter'a bas, kategorilerden istediklerini işaretleyip çalıştır.

Kaynaktan çalıştırmak istersen:

```powershell
.\optimize-windows-gui.ps1
```

Script kendini otomatik olarak yönetici + STA modda yeniden başlatır.

### Konsol

```powershell
.\optimize-windows.ps1
```

Yönetici istemini onayla, menüden kategori numarasını seç. Her işlem tek tek `[e/H]` ile onay ister; `10` ile hepsi sırayla (yine onaylı) çalıştırılabilir.

Script çalışmazsa (execution policy hatası), bir kere şunu çalıştır:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## Derleme (ps2exe)

```powershell
Invoke-ps2exe -inputFile .\optimize-windows-gui.ps1 -outputFile .\optimize-windows-gui.exe `
    -noConsole -STA -requireAdmin -title "Windows Optimizasyon Aracı" -product "Windows Optimizasyon Aracı"
```

## Uyarılar

- Değişikliklerin çoğu geri alınabilir ama bazıları değil (sistem koruması/geri yükleme noktalarının silinmesi gibi). Emin olmadığın maddeleri işaretleme.
- Dizüstü kullanıyorsan Nihai Performans güç planı pil ömrünü belirgin şekilde kısaltır.
- Spooler, RDP (TermService) gibi servisleri kullanıyorsan kapatma.

## Sürümler (Releases)

Derlenmiş `.exe` dosyaları [Releases](../../releases) sekmesinden indirilebilir.
