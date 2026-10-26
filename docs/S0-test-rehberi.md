# Nit Laboratuvarı: kurulum ve test rehberi

**Sürüm 0.6.0 (S0 + S0b + S2).** Amaç, ürünün 1 numaralı vaadini cihazda ölçmek: iPhone 11 Pro + iOS 27, SDR'da da HDR'da da beyazı panel tepesine (≈ 1200 nit) çıkarabiliyor mu ve bunu film boyunca sürdürebiliyor mu? (02-cozum §10.1)

## 1. Kurulum

1. GitHub'da repo → **Actions** → **iOS derleme** → en son yeşil çalıştırma → **Artifacts** bölümünden `Arifetanga-unsigned-ipa`'yı indir. Zip'i aç; içinden `Arifetanga-unsigned.ipa` çıkar.
2. Bilgisayarda **Sideloadly**'yi aç, iPhone'u kabloyla bağla.
3. IPA'yı sürükle ve **ücretli Apple Developer** hesabınla giriş yap. Ücretli hesapta imza 1 yıl geçerlidir.
   - Sideloadly'nin "Advanced options" bölümünde bundle ID'yi değiştirmesine izin verebilirsin.
4. iPhone'da:
   - **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu** açık olmalı (ilk kurulumda yeniden başlatma ister).
   - **Ayarlar → Genel → VPN ve Aygıt Yönetimi** altında geliştirici profilini onayla.

## 1b. İsteğe bağlı: CI'da imzalı IPA

Sideloadly yolu yeterliyse bu bölümü atlayabilirsin. **Actions → İmzalı IPA → Run workflow** iş akışı, sertifikan ve profilinle imzalanmış bir IPA üretir. Bunun için Mac gerekmez; OpenSSL yeter:

1. Anahtar ve imza isteği (CSR) oluştur:
   ```bash
   openssl genrsa -out dev.key 2048
   openssl req -new -key dev.key -out dev.csr -subj "/emailAddress=SENIN@EPOSTAN/CN=Adın Soyadın"
   ```
2. developer.apple.com → Certificates → **Apple Development** sertifikası oluştur ve `dev.csr`'yi yükle. İndirdiğin `.cer` dosyasını p12'ye çevir:
   ```bash
   openssl x509 -inform DER -in development.cer -out dev.pem
   openssl pkcs12 -export -legacy -inkey dev.key -in dev.pem -out dev.p12
   ```
3. Identifiers bölümünde App ID'yi oluştur: `com.feardarks.arifetanga` (ya da kendi kimliğin). Devices bölümüne iPhone'unun UDID'sini ekle. Profiles bölümünde bu App ID ve cihaz için **iOS App Development** (ya da Ad Hoc) profili oluşturup indir.
4. GitHub → repo → **Settings → Secrets and variables → Actions** altına şu dört Secret'ı ekle:
   - `IOS_CERT_P12_BASE64`: `base64 -i dev.p12` çıktısı
   - `IOS_CERT_PASSWORD`: p12 parolası
   - `IOS_PROFILE_BASE64`: `base64 -i profil.mobileprovision` çıktısı
   - `KEYCHAIN_PASSWORD`: herhangi bir parola
5. **Run workflow** → `Arifetanga-signed-ipa` artifact'ı. Bu IPA zaten imzalı olduğu için yeniden imzalamadan yüklenmeli: `ideviceinstaller -i Arifetanga.ipa` (libimobiledevice) ya da 3uTools gibi bir araçla.

> Secrets eklenmeden iş akışı açık bir hata mesajıyla durur. Bu yol henüz gerçek bir sertifikayla denenmedi; ilk çalıştırmada hata çıkarsa günlüğü bana gönder.

## 2. Test dosyaları

**v0.5'ten itibaren MKV, M2TS ve TS dosyaları doğrudan açılır** (kendi hattımız: FFmpeg demux → VideoToolbox; HUD'daki biçim satırının sonunda "kendi hattımız" yazar). Bu yolda henüz **ses yok** (S3). MP4/MOV dosyaları varsayılan olarak AVPlayer ile açılır; Dosya panelindeki **MP4/MOV'u kendi hattımızla aç** anahtarıyla onlar da kendi hattımızdan oynatılır.

Aşağıdaki MP4 dönüşümleri artık yalnızca karşılaştırma içindir (AVPlayer yolu, AS-1 testi). Yeniden kodlama yapılmaz:

```bash
# SDR (1080p Blu-ray, H.264): görüntü kopyalanır, ses AAC'ye çevrilir
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a 256k -t 600 sdr.mp4

# HDR10 (UHD Blu-ray, HEVC 10-bit): Apple için hvc1 etiketi şart
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -tag:v hvc1 -c:a aac -b:a 256k -t 600 hdr10.mp4

# Dolby Vision'lı kaynakta (P7/P8) RPU'yu at, saf HDR10 kalsın (ffmpeg ≥ 7)
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -bsf:v dovi_rpu=strip=1 -tag:v hvc1 -c:a aac -b:a 256k -t 600 hdr10.mp4

# MKV'nin ilk 2 dakikası, MKV olarak (DV korunur; T13–T15 için kısa örnek)
ffmpeg -i film.mkv -map 0:v:0 -c:v copy -t 120 ornek-dv.mkv
```

Dolby Vision profilini görmek için: `ffprobe -v error -show_streams -select_streams v:0 film.mkv | grep -i dv_` (`dv_profile=7/8/5`). Uygulamada da HUD'daki biçim satırında "DV P8.1", "DV P7 (BL+EL)" gibi görünür.

`-t 600` ilk 10 dakikayı alır. 2 saatlik dayanıklılık testi için bunu kaldır; Laboratuvar'daki **Döngü** de dosyayı sürekli tekrarlar.

Dosyaları iPhone'a **Dosyalar** uygulaması (iCloud Drive, "iPhone'umda" ya da SMB) üzerinden koy. Laboratuvarda **Dosya → Dosyalar'dan aç…** ile seç.

## 3. Ekran

- **HUD (sol üst):**
  - Headroom göstergesi: beyaz dolgu `H_eff`, amber kesikli çizgi `H_pot`, üçgen çıkış maksimumu.
  - Durum satırı:
    - "Panel tepesinde": iyi.
    - "Kaydırıcı sınırlı": parlaklık kaydırıcısı düşük; Tepe Kilidi açıksa yükseltir.
    - "Sistem HDR'yi kıstı", "Düşük Güç Modu", "Isıl kısma".
  - P-1 / P-2 denetimleri, GPU süresi, düşen kare ve kadans.
- **Şerit (alt):**
  - Oynatma ve **Döngü**
  - **Nit | Referans**
  - **Maksimum | Dengeli** (HDR'da)
  - **Tepe Kilidi**, **Titreşim**
  - **Parametreler**, **CSV paylaş**, **HUD küçült**, **Kapat**
- **Videoya dokunmak** şeridi gizler ya da gösterir.
- **Kayıt:** Laboratuvar açık olduğu sürece telemetri 2 Hz'de kaydedilir. **CSV paylaş** ile dışa aktarılır.

## 4. Test protokolü (sırayla)

| # | Test | Nasıl | Ne kaydedilir |
|---|---|---|---|
| T1 | **Headroom tablosu (K2)** | Tepe Kilidi **kapalı**. SDR dosyası oynarken parlaklık kaydırıcısını sırayla %25, %50, %75 ve %100'e getir; her birinde 10 sn bekle. | HUD'daki `H_cur` ve `H_pot`. CSV'de de var. |
| T2 | **Tepe Kilidi (K2, K9)** | Kaydırıcıyı ≈ %10'a indir, Tepe Kilidi **açık**. | Parlaklık kendiliğinden yükselip "Panel tepesinde"ye geçmeli. Parlaklık **hiç düşmemeli**. |
| T3 | **Nit ↔ Referans (K6, K-T3)** | Aynı SDR ve HDR10 sahnede birkaç kez geçiş yap. | HUD'da "son geçiş … ms" (≤ 500). Siyah kare olmamalı, ses kesilmemeli. Gözle: Nit belirgin şekilde daha parlak olmalı. |
| T4 | **Maliyet (K3)** | 4K HDR10 ve 1080p SDR dosyalarını 1'er dk oynat. | GPU p95: HDR ≤ 3,0 ms, SDR ≤ 1,5 ms. Düşen kare 0. |
| T5 | **Headroom uyumu (K5)** | Oynatma sırasında kaydırıcıyı hızlıca aşağı yukarı oynat. | P-2 her zaman ✓. Gözle: flaş ya da ani sıçrama olmamalı. |
| T6 | **Pencere desenleri (AS-27, ABL)** | Desenler → Beyaz pencereler · SDR, sırayla %1/10/25/50/100. Aynısını PQ 1000 ile de yap. | Gözle ve varsa lüksmetreyle (telefon uygulaması bile olur) bağıl parlaklık. Büyük pencerede düşüş beklenir. |
| T7 | **Rampalar (AS-33, K7)** | Rampa · ince ve Rampa · karanlık. Titreşim açık ve kapalı karşılaştır; Parametreler'den b = 8 ve b = 10 dene. | Bant görünüyor mu? Titreşim fark yaratıyor mu? |
| T8 | **Okunabilirlik (K-T1)** | Okunabilirlik deseni (tam ekran 10000 nit). | HUD ve şerit metinleri okunuyor mu? Ekran fotoğrafı çek. |
| T10 | **Eşitlik testi (AS-26, K2)** | Şerit → **Eşitlik testi**. %10 pencere ve PQ 1000 ile **Başlat**. 5 denemede A/B'den hangisi daha parlak, ya da **Aynı** mı, yanıtla. Bir yarı Nit (SDR beyaz × H), diğeri Apple'ın kendi HDR beyazı; hangisinin hangisi olduğu gizli. | Sonuç kartı (≥ 4/5 "Aynı" → geçti). Ekran fotoğrafı ve CSV. PQ 4000 ve 10000 ile tekrarla. |
| T11 | **Tonalite testi (K11)** | Bir SDR video aç, şerit → **Tonalite testi**. Solda Apple'ın SDR video işleyişi, sağda Nit (H = 1). 2,2 / 2,4 / 1,96 arasında geçiş yap; sol yarıya en çok benzeyeni seçip **Bu eşleşiyor**'a bas. | Seçilen gama varsayılan olur ve CSV'ye yazılır. |
| T12 | **Sahne beyazı (S0b, AS-38)** | HDR10 bir film aç (tercihen beyazı 100–150 nite koyulmuş, "karanlık" görünen bir film). Parametreler → HDR referans beyazı = **Sahne**. HUD'daki satırı izle: `sahne beyazı X nit · çapa A · L_ref L → 0,95 H`. Aynı sahnede **Sabit 203**'e geçip "→ … H" değerini karşılaştır. Parlak bir obje (far, patlama, beyaz çarşaf) giren sahnelerde parlaklık "pompalıyor" mu, gözle bak. 10 dk izleyip CSV'yi paylaş. | Gündüz ve diyalog sahnelerinde beyaz ≥ 0,9 H olmalı (Sahne kipinde). Pompalama görülmemeli. CSV'de `L_ref`, `W_f`, `W_hat`, `A` kolonları ve "Sahne kesimi" olayları var. Kesimler kaçıyorsa Parametreler → Kesim eşiği'ni 0,05'e indirip tekrarla. |
| T13 | **Kendi hattımız (S2.2)** | Bir MKV (HEVC HDR10), bir M2TS (Blu-ray remux) ve bir 1080p H.264 MKV aç. Her birinde 1'er dk oynat, ileri/geri sar, **Nit ↔ Referans** arasında geçiş yap, Döngü'yü dene. | Görüntü geliyor mu, takılma ya da yeşil/bozuk kare var mı? HUD'da düşen kare ve kadans (24p'de "3:2" ya da "5:5"). Hata mesajı çıkarsa ekran fotoğrafı. |
| T14 | **Referans'ta Dolby Vision (AS-1, S2.3)** | DV **P8.1** bir MKV'yi Referans'ta aç. Aynı dosyanın RPU'su atılmış MP4'ünü (`hdr10.mp4`, yukarıda) de Referans'ta aç. Parlak sahnelerde ikisini karşılaştır. Sonra **P7** bir MKV (UHD Blu-ray'den) ile tekrarla. | DV tetikleniyorsa MKV'deki görüntü HDR10 sürümünden farklı (genellikle vurgularda daha kontrollü, sahneden sahneye değişen) olmalı. İkisi birebir aynıysa DV tetiklenmiyor demektir; yaz. P7'de biçim satırında "Referans'ta DV P8.1" ve olaylarda "DV P7 EL türü: MEL/FEL" görünmeli. |
| T15 | **DV L1 sahne beyazı (AS-38 DV, AS-2)** | DV bir MKV'yi Nit'te, Parametreler → HDR referans beyazı = **Sahne** ile 10 dk izle. | HUD: `… · DV L1 (k = 4) · hist P90 X` satırı ve `RPU … · ort … · en kötü … ms` satırı. RPU süresi ortalamada < 2 ms olmalı. CSV'de `W_f` (L1'den), `W_hist` (histogramdan) ve `rpu_us` kolonları var; bu ikisinin oranından `k` kalibre edilecek. "DV L1 geçersiz" olayı çıkarsa yaz. |
| T16 | **DV P5 Nit'te (AS-30, S2.4)** | Bir DV **P5** dosya aç (genellikle akış servislerinden gelen WEB-DL'ler; `ffprobe` çıktısında `dv_profile=5`). Nit'te birkaç dakika izle; aynı sahnelerde **Referans**'a geçip renkleri karşılaştır. Cilt tonu, gökyüzü, kırmızı/yeşil nesneler ve koyu sahnelere bak. | **Yeşil ya da mor renk kayması olmamalı**; renkler Referans'la aynı olmalı, yalnızca parlaklık farklı. HUD'da `P5 Nit: Y … parça poli · Cb … MMR3 · Cr … MMR3` satırı. "okunamayan" sayısı 0 olmalı. 2 sn içinde kod çözümü kurulamazsa uygulama kendiliğinden Referans'a geçer ve sebebini yazar; olursa ekran fotoğrafı al. |
| T9 | **Dayanıklılık (K8, AS-28)** | HDR10 dosyası, Döngü açık, 2 saat. Üç ayrı çalıştırma: Nit + Tepe Kilidi, Nit (kilit kapalı), Referans. Şarjda değil, oda sıcaklığında. | CSV'yi paylaş. Headroom çöküşü olup olmadığını, ısıyı ve pil yüzdesini (başta ve sonda) not et. |

Her testten sonra CSV'yi paylaşıp (AirDrop, Dosyalar ya da e-posta) bana gönderebilirsin. Raporu (`τ_up`, `w`/`κ`, γ, titreşim ve Tepe Kilidi varsayılanları) bu verilerden çıkaracağım.

## 5. Bilinen sınırlar (v0.5)

- Kendi hattımızda (MKV/M2TS/TS) ses yok; S3'te gelecek. Altyazı ve PiP yok.
- Dolby Vision **P5** Nit'te kendi kod çözümümüzle (RPU şekillendirme + IPT → LMS → BT.2020) gösterilir. Henüz cihazda doğrulanmadı (T16). Dolby'nin kendi ton eşlemesi (DM) yerine Nit eğrisi kullanılır; parlaklık farkı bu yüzden beklenir, renk farkı beklenmez.
- UHD Blu-ray'in **iki ayrı PID'li** M2TS'sinde (BL ve EL ayrı akış) yalnızca BL okunur: görüntü HDR10 olarak oynar, DV devreye girmez. MKV'ye (makemkv / dovi_tool ile tek iz) dönüştürülmüş P7 dosyalarında DV çalışır.
- DV'de L2/L8 trim düzeltmesi henüz uygulanmıyor; sahne beyazı yalnızca L1'den (`k = 4`).
- 10-bit H.264 (Hi10P) donanımda çözülmez; HEVC ve 8-bit H.264 desteklenir.
- Desenler yalnızca Nit yolunda çizilir.
- Ölçekleyici varsayılan olarak "Kaliteli": büyütmede bicubic, 4K küçültmede 2×2 süper örnekleme. Parametreler'den bilineere geçilebilir. Kareler hedef vsync'e hizalı sunulur.
- Sahne bazlı referans beyaz HDR10 ve HLG'de histogramdan, Dolby Vision'da (P7/P8, Nit yolunda) RPU L1'den gelir. Film çapası başlık (dosya adı) bazında hatırlanır; ikinci izlemede çapa baştan doğrudur.
- Desenler her zaman sabit 203 nit (ya da elle değer) kullanır; sahne tahmini desen ölçümünü etkilemez.
