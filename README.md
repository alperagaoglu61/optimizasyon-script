# Windows Optimizasyon Script

Windows 10/11 için performans, gizlilik ve disk temizliği ayarlarını tek yerden yöneten PowerShell aracı. İki sürümü var: konsol (menü tabanlı) ve WPF GUI (checkbox tabanlı).

## Sürümler

| Dosya | Açıklama |
|---|---|
| `optimize-windows.ps1` | Konsol sürümü. Numaralı menü, her işlem öncesi `[e/H]` onayı ister. |
| `optimize-windows-gui.ps1` | WPF GUI sürümü. Koyu tema, kilit ekranı, kategori bazlı checkbox listesi, ilerleme çubuğu ve canlı log kutusu. |
| `optimize-windows-gui.exe` | GUI sürümünün ps2exe ile derlenmiş hâli. Konsol penceresi açmaz, çift tıklayınca UAC otomatik sorar. |
| `optimize-windows.exe` | Konsol sürümünün ps2exe ile derlenmiş hâli. Çift tıklayınca UAC otomatik sorar. |

GUI sürümündeki tüm optimizasyon mantığı (`Optimize-*` fonksiyonları) konsol sürümüyle birebir aynı; sadece onay mekanizması `Read-Host` yerine checkbox'lara bağlanmış.

## Çalışma mantığı ve doğrulama

- **Her değişiklik doğrulanır.** Kayıt defterine yazılan her değer hemen geri okunup karşılaştırılır; servisler `Start=4` (Disabled) değeri okunarak kontrol edilir. Doğrulanamayan işlem log'a `HATA` olarak yazılır. Yani "yapıldı" yazan bir satır, gerçekten yapıldığı doğrulanmış demektir.
- **Arayüz donmaz.** GUI sürümünde tarama ve uygulama işleri ayrı bir runspace'te (arka plan iş parçacığında) çalışır; pencere açık kalır, log ve ilerleme çubuğu canlı akar.
- **Her işlem yalıtılmıştır.** Bir işlem hata verirse diğerleri çalışmaya devam eder, program kapanmaz.
- **İşlemler kararlı bir anahtarla eşleştirilir.** Servis durumu ("Çalışıyor/Durduruldu") değişse bile seçtiğin işlem doğru eşleşir; ikinci uygulamada sessizce atlanmaz.
- Bazı ayarlar (görsel efektler, dosya uzantıları, bildirimler) yalnızca Gezgin yeniden başlatıldıktan veya oturum kapatılıp açıldıktan sonra görünür olur. Görsel Efektler kategorisinde bunun için ayrı bir "Gezgin'i yeniden başlat" seçeneği vardır.

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
Install-Module ps2exe -Scope CurrentUser   # kurulu değilse

Invoke-ps2exe -inputFile .\optimize-windows-gui.ps1 -outputFile .\optimize-windows-gui.exe `
    -noConsole -STA -requireAdmin -title "Windows Optimizasyon Aracı" -product "Windows Optimizasyon Aracı" `
    -description "Windows optimizasyon aracı (GUI)"

Invoke-ps2exe -inputFile .\optimize-windows.ps1 -outputFile .\optimize-windows.exe `
    -requireAdmin -title "Windows Optimizasyon Scripti" -product "Windows Optimizasyon Aracı" `
    -description "Windows optimizasyon scripti (konsol)"
```

GUI sürümü `-STA` olmadan derlenmemelidir; WPF penceresi yalnızca STA modunda açılır. Her iki `.ps1` dosyası da UTF-8 BOM ile kaydedilmelidir, aksi halde Türkçe karakterler bozulur.

## Uyarılar

- Değişikliklerin çoğu geri alınabilir ama bazıları değil (sistem koruması/geri yükleme noktalarının silinmesi gibi). Emin olmadığın maddeleri işaretleme.
- Dizüstü kullanıyorsan Nihai Performans güç planı pil ömrünü belirgin şekilde kısaltır.
- Spooler, RDP (TermService) gibi servisleri kullanıyorsan kapatma.

## Sürümler (Releases)

Derlenmiş `.exe` dosyaları [Releases](../../releases) sekmesinden indirilebilir.

## Lisans ve Kullanım Koşulları

**Telif Hakkı © 2026 Alper İbrahimağaoğlu — Tüm Hakları Saklıdır (All Rights Reserved).**

Bu depo **açık kaynak değildir**. Kod herkese açık olarak görüntülenebilir olması, serbestçe kullanılabileceği anlamına gelmez. Tam hukuki metin için [LICENSE](LICENSE) dosyasına bakınız.

### İzin verilenler

- Kaynak kodu kişisel veya eğitim amacıyla görüntülemek ve incelemek.
- Değiştirilmemiş bir kopyayı indirip kendi cihazınızda kişisel, ticari olmayan amaçla çalıştırmak.

### Yazılı izin olmadan yasaklananlar

- **Değiştirme / türev eser (No Derivatives):** kodu düzenlemek, uyarlamak, çevirmek veya ondan türetilmiş bir sürüm üretmek.
- **Yeniden dağıtım (No Redistribution):** kodu kopyalayıp başka bir depoda, web sitesinde, mağazada veya platformda yayımlamak, aynalamak (mirror), yeniden yüklemek.
- **Ticari kullanım (No Commercial Use):** satmak, kiralamak, lisanslamak veya bir ürün/hizmetin parçası hâline getirmek.
- Telif başlıklarını veya lisans dosyasını kaldırmak ya da değiştirmek.
- Kodu yapay zekâ modeli eğitiminde veri kümesi olarak kullanmak.

### Atıf zorunluluğu

Bu projeye yapılan her referans, alıntı veya bahis; **Alper İbrahimağaoğlu** adını ve bu deponun bağlantısını açıkça belirtmek zorundadır:

> Windows Optimizasyon Aracı — © 2026 Alper İbrahimağaoğlu
> https://github.com/alperagaoglu61/optimizasyon-script

### Sorumluluk reddi

Yazılım "olduğu gibi" sunulur, hiçbir garanti verilmez. Windows ayarlarında ve kayıt defterinde kalıcı değişiklikler yapar; oluşabilecek veri kaybı veya sistem kararsızlığından telif sahibi sorumlu değildir. Tüm risk kullanıcıya aittir.

Yukarıda yasaklanan kullanımlar için izin talebi: https://github.com/alperagaoglu61
