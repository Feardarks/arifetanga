# S0 Nit Laboratuvarı: kurulum ve test rehberi

**Sürüm 0.1.0.** Amaç, ürünün 1 numaralı vaadini cihazda ölçmek: iPhone 11 Pro + iOS 27, SDR'da da HDR'da da beyazı panel tepesine (≈ 1200 nit) çıkarabiliyor mu ve bunu film boyunca sürdürebiliyor mu? (02-cozum §10.1)

## 1. Kurulum

1. GitHub'da repo → **Actions** → **iOS derleme** → en son yeşil çalıştırma → **Artifacts** bölümünden `Arifetanga-unsigned-ipa`'yı indir. Zip'i aç; içinden `Arifetanga-unsigned.ipa` çıkar.
2. Bilgisayarda **Sideloadly**'yi aç, iPhone'u kabloyla bağla.
3. IPA'yı sürükle ve **ücretli Apple Developer** hesabınla giriş yap. Ücretli hesapta imza 1 yıl geçerlidir.
   - Sideloadly'nin "Advanced options" bölümünde bundle ID'yi değiştirmesine izin verebilirsin.
4. iPhone'da:
   - **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu** açık olmalı (ilk kurulumda yeniden başlatma ister).
   - **Ayarlar → Genel → VPN ve Aygıt Yönetimi** altında geliştirici profilini onayla.

> İmzalı IPA'yı doğrudan CI'da üretmek (sertifika ve profil GitHub Secrets'ta) v0.2'de eklenecek. O zamana kadar imzayı Sideloadly yapıyor.

## 2. Test dosyaları

S0, AVFoundation'ın açabildiği **MP4/MOV** dosyalarıyla çalışır. MKV desteği S2'de gelecek. Kendi rip'lerinden, yeniden kodlamadan şöyle MP4 üretebilirsin:

```bash
# SDR (1080p Blu-ray, H.264): görüntü kopyalanır, ses AAC'ye çevrilir
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a 256k -t 600 sdr.mp4

# HDR10 (UHD Blu-ray, HEVC 10-bit): Apple için hvc1 etiketi şart
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -tag:v hvc1 -c:a aac -b:a 256k -t 600 hdr10.mp4

# Dolby Vision'lı kaynakta (P7/P8) RPU'yu at, saf HDR10 kalsın (ffmpeg ≥ 7)
ffmpeg -i film.mkv -map 0:v:0 -map 0:a:0 -c:v copy -bsf:v dovi_rpu=strip=1 -tag:v hvc1 -c:a aac -b:a 256k -t 600 hdr10.mp4
```

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
| T9 | **Dayanıklılık (K8, AS-28)** | HDR10 dosyası, Döngü açık, 2 saat. Üç ayrı çalıştırma: Nit + Tepe Kilidi, Nit (kilit kapalı), Referans. Şarjda değil, oda sıcaklığında. | CSV'yi paylaş. Headroom çöküşü olup olmadığını, ısıyı ve pil yüzdesini (başta ve sonda) not et. |

Her testten sonra CSV'yi paylaşıp (AirDrop, Dosyalar ya da e-posta) bana gönderebilirsin. Raporu (`τ_up`, `w`/`κ`, γ, titreşim ve Tepe Kilidi varsayılanları) bu verilerden çıkaracağım.

## 5. Bilinen sınırlar (v0.1)

- Yalnızca MP4/MOV. MKV, Dolby Vision işleme, altyazı ve PiP yok (S2 ve sonrası).
- Desenler yalnızca Nit yolunda çizilir.
- Eşitlik testi (S0-C) ve tonalite testi (S0-D) v0.2'de.
- Ölçekleyici bilineer. Bicubic ve vsync hizalı sunum v0.2'de.
- HDR'da referans beyaz sabit 203 nit. Sahne bazlı tespit S0b'de; Parametreler'den elle 100–300 nit arası değiştirilebilir.
