# Proje Özeti (Brief) — çalışma adı: arifetanga

Üç uzman ajanın ortak girdisi. Buradaki kısıtlar bağlayıcıdır; değişirse önce bu dosya güncellenir.

## Hedef

iPhone 11 Pro için sideload edilen, **flagship seviyesinde bir medya oynatıcı (video + ses)**.

- **Basit:** İlk açılıştan itibaren sıfır ayarla doğru çalışır.
- **Çok yetenekli:** Uzman kullanıcı için derin kontrol sunar.
- **Kalite:** Cihazın verebileceği en yüksek görüntü ve ses kalitesi. HDR/EDR, renk doğruluğu ve bit-perfect'e en yakın ses zinciri.
- **1 numaralı özellik, Nit Çekirdeği:** SDR'da da HDR'da da tipik beyaz, panelin HDR tepe parlaklığında (yaklaşık 1200 nit) görünür. Bunu kendi Metal çekirdeğimiz EDR ile yapar. Uygulama parlaklığı hiçbir koşulda kendiliğinden düşürmez. Ayrıntılar `docs/01-konsept.md` içindeki M2'de.
- **Kapsam dışı (kullanıcı kararı):** Altyazı OCR'ı, çeviri ve otomatik senkron. Altyazılar videoyla birlikte, gömülü olarak gelir.
- **AI:** A13 Neural Engine üzerinde, cihaz içinde çalışan özellikler.
- **Apple framework'leri:** Mümkün olan her yerde native API kullanılır. Üçüncü parti yalnızca gerçek bir boşluğu dolduruyorsa eklenir.

Ana içerik: Blu-ray / UHD Blu-ray rip'leri (MKV remux, ISO, BDMV), HDR10 / HDR10+ / Dolby Vision, lossless ve hi-res müzik (FLAC, ALAC, WAV, DSD?). Kaynaklar: yerel dosyalar, SMB/NAS, Plex/Jellyfin.

## Hedef cihaz: iPhone 11 Pro

| Alan | Değer |
|---|---|
| SoC | A13 Bionic: 2P + 4E CPU, 4 çekirdek GPU, 8 çekirdek Neural Engine |
| RAM | 4 GB |
| Ekran | 5,8" OLED, 2436×1125 (458 ppi), **60 Hz**, P3. Tipik 800 nit, HDR tepe 1200 nit. HDR10 / Dolby Vision / HLG. |
| Ses | Stereo hoparlör (Atmos / uzamsal sanallaştırma). Kulaklık girişi yok. Lightning (USB 2.0) üzerinden harici DAC. Bluetooth 5.0 (AAC; aptX / LDAC yok). |
| Donanım çözücü | H.264, HEVC Main/Main10. **AV1 donanım çözücüsü yok** (yazılımla çözülür). |
| OS | **iOS 27.0.1** (kullanıcı beyanı, resmi sürüm) |
| AI | **Apple Intelligence / Foundation Models YOK** (A17 Pro+ gerekir). Kullanılabilenler: Core ML (ANE), Vision, Sound Analysis, Speech, Natural Language, Translation, Accelerate/BNNS, Metal Performance Shaders. |

Not: 4K içerik 1125p'lik bir ekrana küçültülür. AI ile çözünürlük artırma ancak SD/DVD/720p kaynaklarda anlamlıdır.

## Dağıtım ve entitlement'lar

- **Ücretli Apple Developer hesabı.** Development / ad-hoc imza, 1 yıllık sertifika, cihaz UDID'si kayıtlı.
- **TrollStore yok** (iOS 27). Private entitlement, `no-sandbox` ve `platform-application` **kullanılamaz**.
- Kullanılabilen güçlü public entitlement'lar:
  - `com.apple.developer.kernel.increased-memory-limit`
  - `com.apple.developer.kernel.extended-virtual-addressing`
  - `UIBackgroundModes: audio`
  - App Groups, iCloud, File Provider, Network Extension
- Apple onayı gerektirenler (ör. multicast) ayrıca talep edilir.

## Derleme hattı

- Mac yok. **GitHub Actions macOS runner** üzerinde Xcode ile derlenir.
- Proje dosyası metin tabanlı üretilir (XcodeGen veya Tuist). `.xcodeproj` elle düzenlenmez.
- İmza: sertifika (.p12) ve provisioning profile GitHub Secrets'ta tutulur. CI imzalı IPA üretir. Cihaza Sideloadly / AltStore (kendi sertifikayla) / Xcode ile yüklenir.
- Private repoda macOS dakikaları ücretli olabilir (macOS runner'larda dakika çarpanı yüksek).

## Aşamalar ve ajanlar

| # | Aşama | Ajan | Çıktı |
|---|---|---|---|
| 1 | Konsept ve İnovasyon | `fikir-ajani` | `docs/01-konsept.md` |
| 2 | Problem Çözme ve Teknik Mimari | `cozum-ajani` | `docs/02-cozum.md` |
| 3 | Ürün ve Arayüz Tasarımı | `tasarim-ajani` | `docs/03-tasarim.md` |

Her aşamanın sonunda kullanıcı onayı alınır. Bir sonraki ajan, önceki çıktıları bağlayıcı girdi olarak okur. Üç aşama bitince uygulama (kod) aşamasına geçilir.

## Doğrulama kuralı

iOS 27 SDK'sı ve yeni API'ler eğitim verisinden daha güncel olabilir. Kesin olmayan her API, cihaz desteği veya entitlement iddiası **"doğrulanmalı"** olarak işaretlenir ve mümkünse Apple dokümantasyonuyla teyit edilir.
