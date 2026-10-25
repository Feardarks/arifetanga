# 01b — Ek Fikirler: İki Yeni Özellik

> **Aşama:** 1 (ek) · **Ajan:** `fikir-ajani` · **Tarih:** 25 Ekim 2026 · **Girdi:** `docs/00-brief.md`, `docs/01-konsept.md` (rev. 3) · **Durum:** **onaylandı (rev. 4):** N1 → MVP (M2'nin parçası), N2 → v1.1'in ilk işi
>
> Bu belge `01-konsept.md`'yi değiştirmez; yalnızca ona eklenecek iki fikri önerir. Spike numaraları AS-32'den başlar.
>
> **İşaretler:** **[doğrulandı]** = Apple dokümantasyonuyla teyit edildi. **[doğrulanmalı]** = çıkarım, ikincil kaynak ya da ölçülmesi gereken davranış.

---

## 0. Özet

| | **N1 — Temiz Nit** | **N2 — Ses Çekirdeği** |
|---|---|---|
| **Vaat** | Nit Çekirdeği 8-bit filmi 1200 nite çıkardığında beliren bantlar (gökyüzü, sis, karanlık sahne) yok olur. Parlaklıktan ve detaydan taviz verilmez. | Sesi kıstığında bas ve tiz kaybolmaz. Film ve müzik, her ses seviyesinde stüdyodaki referans tonal dengeyle duyulur. |
| **Sinerji** | Nit Çekirdeği (M2) ile doğrudan: M2'nin kendi yan etkisini çözer. | Ses zinciri ile: M4, M5, M9, A1 ve A7'nin üstüne oturur. |
| **Neden her gün hissedilir?** | Her 1080p Blu-ray, DVD ve 8-bit WEB kaynağı Nit modunda bu sorunu taşır. | iPhone'da neredeyse hiç referans seviyesinde dinlenmez: yolda, gece ve hoparlörde ses hep daha kısıktır. |
| **A13 maliyeti** | GPU'da yaklaşık 1–1,5 ms/kare **[doğrulanmalı]**. ANE kullanmaz. | CPU'da %1'in altında. GPU ve ANE kullanmaz. |
| **Öneri** | **MVP** (M2'nin parçası) | **v1.1** (ilk iş) |
| **Spike** | AS-32, AS-33 | AS-34, AS-35, AS-36 |

**AI notu:** İki fikirde de Neural Engine merkezde değil, bu bilinçli bir karar. 12 adayın içinde ANE'yi gerçekten kullanan 4 aday vardı (bkz. bölüm 1). Hiçbiri "süs değil, her gün hissedilir, sadakati bozmaz" süzgecinden geçemedi. Kullanıcı süs için eklenen AI'ı istemediği için ANE'yi zorla eklemedim. N1'de öğrenilmiş bir maske için koşullu bir v1.1 yolu açık bıraktım; ancak ölçülebilir fark yaratırsa eklenecek.

---

## 1. Seçim süreci

### 1.1 Ölçütler

Her aday beş ölçüte göre değerlendirildi:

1. **Öncelik:** Parlaklık, ses kalitesi, basitlik ve gerçek AI'dan en az birine doğrudan hizmet ediyor mu?
2. **Sinerji:** Nit Çekirdeği ya da ses zinciriyle bağlantılı mı?
3. **Fizibilite:** iPhone 11 Pro, iOS 27 ve ücretli hesapla gerçekten yapılabilir mi?
4. **Günlük his:** Bir kez denenip unutulmuyor mu?
5. **Özgünlük:** Mevcut 54 fikrin ve MVP'nin tekrarı ya da küçük varyasyonu değil mi?

Bunlara ek olarak kullanıcının iki kırmızı çizgisi uygulandı: **parlaklık düşürülmez** ve **abartı özellik eklenmez**.

### 1.2 Aday havuzu

Puanlar 1–5 arasıdır. ✗ = elendi.

| # | Aday | Öncelik | Sinerji | Fizibilite | Günlük his | Özgün mü? | Karar |
|---|---|---|---|---|---|---|---|
| K1 | **Temiz Nit:** algı eşiğine göre çalışan bit derinliği genişletme (debanding) | 5 | 5 (Nit) | 4 | 5 | Evet (V10 gürültü, V3 ton eşleme; bu ikisinden farklı) | **SEÇİLDİ** |
| K2 | **Ses Çekirdeği:** seviyeye göre eşit ses yüksekliği telafisi ve kişisel işitme profili | 5 | 5 (ses) | 5 | 5 | Evet (A6 kulaklık EQ'su, A7 normalizasyon; bu ikisinden farklı) | **SEÇİLDİ** |
| K3 | ABL Kalkanı: saliency yönlendirmeli APL yönetimi (Vision/ANE) | 4 | 5 (Nit) | 3 | 4 | Kısmen (V3 ve V12'ye yakın) | ✗ |
| K4 | ML kaynak ayrıştırmalı stereodan uzamsala upmix (ANE) | 3 | 4 | 2 | 3 | Evet | ✗ |
| K5 | Hoparlör için psikoakustik bas ve loudness maksimize edici | 3 | 4 | 4 | 3 | Kısmen (A10) | ✗ |
| K6 | TrueDepth ile baş takipli hoparlör crosstalk iptali (ARKit/ANE) | 3 | 3 | 2 | 2 | Evet | ✗ |
| K7 | SDR'dan HDR'a AI ters ton eşleme (ANE) | 3 | 3 | 3 | 4 | Evet | ✗ |
| K8 | Parlaklık öncelikli ısıl bütçe planlayıcı | 4 | 5 | 4 | 3 | Hayır (V6 varyasyonu) | ✗ |
| K9 | İçerik türüne göre otomatik profil (anime/konser/film; Vision ve Sound Analysis) | 2 | 3 | 4 | 3 | Hayır (S1/A1 varyasyonu) | ✗ |
| K10 | ML chroma upsampling (4:2:0'dan 4:4:4'e, ANE) | 2 | 3 | 3 | 1 | Evet | ✗ |
| K11 | Lossy ses restorasyonu (bant genişliği genişletme) | 2 | 3 | 3 | 1 | Evet | ✗ |
| K12 | TPDF dither ve gürültü şekillendirmeli "audiophile" ses seviyesi | 2 | 4 | 5 | 1 | Evet | ✗ |

Elenme gerekçeleri bölüm 4'te.

---

## 2. N1 — Temiz Nit: 1200 nite hazır, bantsız görüntü

### 2.1 Ad ve vaat

**Temiz Nit.** *"Nit Çekirdeği 8-bit filmi 12 kat parlattığında beliren gökyüzü, sis ve karanlık sahne bantlarını, detaya ve parlaklığa dokunmadan görünmez kılar. Ayar yok."*

### 2.2 Çözdüğü gerçek problem

**Kök neden: Nit Çekirdeği'nin kendi yan etkisi.**

- 1080p Blu-ray (AVC), DVD ve WEB 1080p kaynakların büyük çoğunluğu **8-bit**tir.
- 8-bit gamma kodlaması yaklaşık **100 nitlik SDR referansı** için tasarlandı. Bu seviyede ardışık iki kod değeri arasındaki parlaklık farkı, gözün fark etme eşiğinin hemen üstünde kalır. Kaynaktaki gren ve gürültü de bunu örter.
- M2, SDR beyazını yaklaşık 1200 nite, yani referansın **yaklaşık 12 katına** çıkarıyor. Doğrusal ölçekleme, adımların oransal büyüklüğünü değiştirmez. Ama insan gözünün kontrast eşiği parlaklık arttıkça düşer (Barten CSF modeli; PQ eğrisi bu yüzden geliştirildi). Bu yüzden 100 nitte zar zor görünen basamaklar 1200 nitte **açıkça görünür hale gelir**.

**Kaba hesap.** Gamma 2.4 ve 8-bit kabul edildi. Adım ve nit değerleri matematiksel; eşik değerleri **yaklaşık, Barten modelinden çıkarım** ve **[doğrulanmalı]**.

| Kod değeri (0–255) | 1 kod adımının bağıl parlaklık farkı | 100 nit referansta parlaklık | Nit modunda (×12) | Adım / eşik oranı (yaklaşık): referans → Nit |
|---|---|---|---|---|
| 32 (karanlık sahne) | %7,6 | 0,7 nit | 8,2 nit | ~2× → ~5× |
| 64 (gölge) | %3,8 | 3,6 nit | 44 nit | ~2× → ~4× |
| 128 (orta ton, sis, gökyüzü) | %1,9 | 19 nit | 229 nit | ~2× → ~3× |

Sonuç olarak, bant görünürlüğü Nit modunda kabaca **1,5–2,5 kat artar**. En çok etkilenenler gökyüzü gradyanları, sis, gün batımı, karanlık sahnelerdeki "basamaklı" gölgeler ve kodlayıcının karanlıkta ürettiği düz bloklardır.

**Kullanıcı bunu nasıl fark eder?** Nit modunu her açtığında. Bu bir kez denenip unutulan bir özellik değil; kullanıcının 1 numaralı özelliğinin en sık görülen kusurunu kapatıyor. Temiz Nit olmadan, "en parlak mod" aynı zamanda "en çok bant gösteren mod" olur.

**Mevcut fikirlerden farkı:**
- **V10** VTTemporalNoiseFilter ile DVD'deki gürültüyü ve greni temizler; bant sorununu çözmez.
- **V3** HDR10 için ton eşlemedir.
- **V12 / M2** parlaklık eğrisidir ve kuantalamayla ilgilenmez.
- Temiz Nit, **çıkış parlaklığını bilen** bir dekuantalayıcıdır. Bir pikseli ancak o pikselin basamağı nihai nit değerinde görünür olacaksa düzeltir.

### 2.3 Nasıl çalışır?

Mevcut M2 hattına, kod değerleri alanında bir **0. adım** ve çıkışta bir **6. adım** eklenir. Hat aynı Metal komut tamponunda kalır ve ek kopya yapılmaz.

```
VideoToolbox (donanım çözme) ─► CVPixelBuffer  8-bit Y'CbCr 4:2:0 (BT.709/601)
        │                         (10-bit HDR/DV: düşük güçte, yalnızca dedektör tetiklerse)
        ▼  CVMetalTextureCache (kopyasız)
┌──────────────────────── Nit Çekirdeği (Metal, tek komut tamponu) ────────────────────────┐
│ 0a  BANT HARİTASI         1/4 çözünürlük, 32×32 karolar                                  │
│     · gradyan büyüklüğü, karodaki farklı kod sayısı                                      │
│     · "düzlük + ±1 kod basamağı" deseni → bant olasılığı                                 │
│     · yüksek frekans doku enerjisi → koruma (cilt, kumaş, gren)                          │
│     · zamansal histerezis (karo başına ~0,5 sn): titreme olmaz                           │
│ 0b  ALGI EŞİĞİ            LUT[kod, H] → "1 LSB adımı nihai nitte görünür mü?"            │
│     · H = currentEDRHeadroom (her karede okunur, M2 ile aynı değer)                      │
│     · LUT bir kez hazırlanır (Barten tabanlı; H değiştikçe yeniden seçilir)              │
│ 0c  DEKUANTALAMA          yalnızca (harita = bant) ∧ (eşik = görünür) olan piksellerde   │
│     · 2–3 iterasyon, her birinde yarıçap büyür ve eşik küçülür                            │
│     · her iterasyonda 4 rastgele örnek; tümü |fark| < t ise ortalama alınır, değilse      │
│       piksel olduğu gibi kalır (kenar ve doku korunur)                                   │
│     · çıkış float'tır: kesirli kod değeri = gerçek bit derinliği genişlemesi             │
│     · karanlık bölge (Y' < ~40): kodlayıcı blok ızgarasına (4/8 px) duyarlı yumuşatma    │
│ 1–5 M2 adımları: Y'CbCr→RGB · EOTF · gamut → P3 · Nit eğrisi (×H) · ekran ölçekleme      │
│ 6   ÇIKIŞ TİTREŞİMİ       zamanla değişen mavi gürültü, çıkış LSB'si genliğinde          │
│     (sistem/panel 16F'yi daha düşük bit derinliğine indiriyorsa yeni bant oluşmaz;       │
│      AS-33)                                                                              │
└──────────────────────────────────────────────────────────────────────────────────────────┘
        ▼
CAMetalLayer (RGBA16Float, extendedLinearDisplayP3, wantsExtendedDynamicRangeContent)
```

**Algoritmanın özü.** Klasik debanding (mpv/libplacebo, madVR) sabit bir eşikle çalışır, bu yüzden ya fazla yumuşatır ya da yetersiz kalır. Temiz Nit'in farkı, eşiğin **o pikselin ekranda ulaşacağı nit değerine** göre seçilmesidir:

- Adım görünmeyecekse piksel **hiç değiştirilmez**. Böylece detay en üst düzeyde korunur.
- H büyüdükçe (daha parlak) eşik otomatik olarak sıkılaşır.
- 8-bit SDR kaynakta etki tam güçtedir.
- 10-bit HDR'da yalnızca kaynağa "gömülü" banding varsa devreye girer.
- **Referans modunda** devre dışıdır; bu yol Apple'ın native hattıdır ve "disk neyse o" ilkesine uyar.

**Kullanılacak API'ler ve framework'ler:**
- **Metal:** compute çekirdekleri, `MTLTexture` r16Float ara dokular, blue-noise doku.
- **Core Video:** `CVMetalTextureCache`, piksel biçiminden bit derinliğinin anlaşılması (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` / `…10BiPlanar…`).
- **VideoToolbox / Core Media:** `CMFormatDescription` ile kaynak bit derinliği, renk matrisi ve aralık.
- **QuartzCore:** `CAMetalLayer` EDR.
- **UIKit:** `UIScreen.currentEDRHeadroom` **[doğrulandı]**.
- **Accelerate:** Barten LUT'unu üretmek için, bir kez.
- **os_signpost / MetricKit:** ölçüm.
- **(v1.1, koşullu) Core ML:** öğrenilmiş bant maskesi (bkz. 2.6).

### 2.4 A13 bütçesi

| Kaynak | Tahmin | Gerekçe |
|---|---|---|
| **GPU** | 1080p kaynakta **~0,8–1,5 ms/kare** **[doğrulanmalı, AS-32]** | 2,07 Mpx × (2–3 iterasyon × 4 örnek) ≈ 15–25 M doku okuması, artı 1/4 çözünürlükte harita. A13 GPU için hafif bir yük. Toplam M2 bütçesi AS-29'un 3 ms'i ile birlikte **≤ 4,5 ms/kare** hedeflenir. |
| **Çalışma oranı** | %10–11 GPU doluluğu | Çekirdek ekran yenileme hızında değil, **kaynak kare hızında** (24 fps) çalışır; 60 Hz'de aynı kare yeniden sunulur. 4,5 ms × 24 ≈ 108 ms/sn. |
| **CPU** | ~0 | Yalnızca komut kodlama. |
| **ANE** | 0 (MVP) | Öğrenilmiş maske v1.1'de koşullu (2.6). |
| **Bellek** | < 10 MB | 1/4 çözünürlükte harita, 2 adet r16F ara doku, 64×64 blue-noise doku. |
| **Gecikme** | 0 ek kare | Aynı geçişin içinde çalışır; A/V senkronu etkilenmez. |
| **Pil ve ısı** | İhmal edilebilir: tahmini < 100 mW **[doğrulanmalı]** | 1200 nitteki ekranın tüketimi (watt mertebesi) yanında küçük kalır. Isıl kısmaya katkısı önemsizdir. AS-28 bunu ayrıca gözler. |

### 2.5 Kullanıcı deneyimi

**Basit mod (varsayılan): görünmez.**
- Ayrı bir düğme yok. Temiz Nit, **Nit modunun ayrılmaz bir parçasıdır**.
- Kaynak 8-bit ise otomatik açılır, Referans modunda otomatik kapanır.
- Format teşhis kartında (S2) tek satır görünür: *"Bit derinliği genişletme: etkin (8-bit kaynak, ×11,8 yükseltme)"*.
- **Ayar gerektirmeden neden doğru çalışır?** Karar üç nesnel girdiden çıkar: kaynak bit derinliği, anlık headroom ve piksel bazında görünürlük eşiği. Kullanıcının bilmesi gereken bir parametre yoktur.

**Uzman modu:**
- **Kip:** Otomatik (varsayılan) / Güçlü (eski ve kötü kodlanmış kaynaklar için) / Kapalı.
- **A/B karşılaştırma:** Ekran ikiye bölünür; sol yarı ham Nit, sağ yarı Temiz Nit. Kullanıcı farkı kendi gözüyle görür ve özelliğe güveni bu sayede oluşur.
- **"Bant haritasını göster":** Hangi bölgelerin düzeltildiğini gösteren yarı saydam bir katman.
- **Titreşim (grain) düzeyi:** Kapalı / ince (varsayılan) / orta.

### 2.6 Riskler, doğrulanmalı noktalar, yedek plan

| Risk | Olasılık | Önlem / yedek plan |
|---|---|---|
| **Çıkış zinciri bit derinliği:** iOS kompozitörü ya da panel RGBA16F EDR katmanını titreşim uygulamadan düşük bit derinliğine indiriyorsa, çıkışta yeni bantlar oluşur **[doğrulanmalı, AS-33]** | Orta | 6. adımdaki mavi gürültü titreşimi tam bu durum için var. Kompozitör zaten titreşim uyguluyorsa 6. adım kapatılır. |
| İnce, düşük kontrastlı dokular (cilt, sis, film greni) yumuşayabilir | Orta | Algı eşiği kapısı ve doku enerjisi koruması. AS-32'deki doku kaybı ölçütü sağlanmazsa varsayılan güç düşürülür. |
| Harita zamanla titreşebilir | Düşük | Karo başına histerezis ve sahne kesiminde sıfırlama. |
| GPU bütçesinin aşılması (M2 + Temiz Nit > 4,5 ms) | Düşük | İterasyon sayısı 3'ten 2'ye iner; harita her 2 karede bir güncellenir; 4K 8-bit kaynakta işlem ekran çözünürlüğünde yapılır. |
| Barten LUT'u gerçek panelde fazla ya da az agresif kalabilir | Orta | AS-32'deki kör A/B testine göre LUT'a ölçek katsayısı verilir. |
| Bir kaynak 8-bit işaretli ama içerik 10-bit'ten dithering ile üretilmiş olabilir (zaten temiz) | Düşük | Harita bant bulamaz ve hiçbir şey değişmez. Yanlış pozitif olmaz. |

**Koşullu v1.1 yolu: öğrenilmiş maske (ANE).**
- **Ne zaman eklenir?** Yalnızca AS-32'de deterministik dedektör doku bölgelerinde ≥ %5 yanlış pozitif verirse.
- **Model:** 480×270 luma üzerinde karo sınıflandırması (bant / doku / düz / kenar) yapan küçük bir CNN. Maske 6 Hz'de güncellenir. ANE'de tahminen 1–2 ms **[doğrulanmalı]**.
- **Eğitim:** 10/16-bit kaynaklar 8-bit'e kuantalanıp x264 ile kodlanarak sentetik veri üretilir.
- **Kısıt:** PiP ya da arka plandayken iOS 27 ANE'yi kısıtlar (01-konsept §2.2). Bu durumda deterministik maskeye düşülür.

### 2.7 Ölçülebilir başarı ölçütü ve spike'lar

**Kullanıcı açısından başarı ölçütü:**
- Seçilmiş 20 SDR klipte (gökyüzü, gün batımı, sis, karanlık sahne, animasyon) Nit modunda bant **görünmez** olur.
- Kör A/B testinde kullanıcı Temiz Nit'i **≥ 8/10** klipte tercih eder.
- Hiçbir klipte "görüntü yumuşadı" yorumu çıkmaz.

| # | Soru ("şu çalışır mı?") | Başarı ölçütü | Süre |
|---|---|---|---|
| **AS-32** | Temiz Nit, A13'te Nit modunda 8-bit kaynaklardaki bantları **ölçülebilir şekilde** azaltırken detayı korur mu, ve bunu bütçe içinde yapar mı? | (1) **CAMBI** (Netflix'in bant metriği, libvmaf): çıkış nit cinsinden PQ 10-bit'e kodlanıp ölçüldüğünde skor **≥ %50 düşer**. (2) Doku bölgelerinde yüksek frekans enerji kaybı **≤ %2**. (3) A13 GPU'da 1080p için **≤ 1,5 ms/kare**. (4) 2 saatte **0 kare kaybı**. (5) Kör A/B testinde **≥ 8/10** tercih. | 4–5 gün |
| **AS-33** | iPhone 11 Pro'da RGBA16Float EDR katmanına yazılan ince bir gradyan (çok küçük adımlı rampa × H) ekranda bantsız görünür mü? Sistem titreşim uyguluyor mu? Mavi gürültü titreşimi görünür bir fark yaratıyor mu? | Ekrandan makro çekimle (kamera) ve görsel testle karar verilir. Sonuç: "6. adım gerekli / gereksiz". | 1–2 gün |

### 2.8 MVP mi, v1.1 mi? → **MVP (M2'nin alt bileşeni)**

**Gerekçe:**
1. M2 kullanıcının 1 numaralı özelliği. Kullanıcının en sık izlediği içerik ise 8-bit (1080p Blu-ray remux, DVD). Temiz Nit olmadan M2, bu içerikte ilk izlemede bant gösterme riski taşır ve 1 numaralı özellik kötü bir ilk izlenim bırakır.
2. Maliyeti düşük. Yeni bir hat ya da framework gerektirmez; M2 çekirdeğine iki adım eklenir. Tahmini iş 1–2 hafta (shader ve ayar) **[doğrulanmalı]**.
3. Kapsam sabit kalır. MVP'ye yeni bir madde eklenmez; M2'nin kalite garantisi olarak girer.
4. Öğrenilmiş maske (ANE) **v1.1'e** ve AS-32 sonucuna bağlı olarak kalır.

---

## 3. N2 — Ses Çekirdeği: her ses seviyesinde stüdyo tonalitesi

### 3.1 Ad ve vaat

**Ses Çekirdeği.** *"Sesi kıstığında bas ve tizler kaybolmaz. Film ve müzik, mikserin referans seviyesinde duyduğu tonal dengeyle çalar: kulaklıkta, hoparlörde, gece kısık seste. Ayar yok."*

Bu özellik Nit Çekirdeği'nin kulaktaki karşılığıdır. Nit Çekirdeği gözün gördüğünü panelin sınırına taşır; Ses Çekirdeği ise kulağın duyduğunu, miksin yapıldığı referans koşula taşır.

### 3.2 Çözdüğü gerçek problem

**Kök neden: insan kulağının doğrusal olmayan duyarlılığı.**

- Kulağın frekanslara duyarlılığı ses seviyesine göre değişir. Bu, eşit ses yüksekliği eğrileriyle tanımlanır (ISO 226:2023).
- Filmler sinema referans seviyesinde miksajlanır: kanal başına 85 dB SPL. TV ve ev miksleri için tipik değer 79–82 dB'dir. Müzik masterlarında yaygın değer yaklaşık 80–85 dB'dir.
- iPhone'da ise dinleme neredeyse her zaman bu seviyenin **altında** yapılır: yolda AirPods ile yaklaşık 65–75 dB, gece 50–60 dB, hoparlörde ise daha da düşük **[tipik değerler, doğrulanmalı]**.
- 85 phon yerine 60 phon'da dinlendiğinde, aynı tonal dengeyi algılamak için 50 Hz'in göreli olarak yaklaşık **+6–8 dB** daha yüksek olması gerekir **[yaklaşık; kesin değer ISO 226 tablosundan hesaplanacak]**. Benzer ama daha küçük bir kayıp en üst tizlerde de oluşur.

**Sonuç:** Kısık seste ses "ince, cansız ve uzak" gelir. Kullanıcı bunu telafi etmek için sesi açar; bu kez diyalog ve patlamalar fazla yükselir, kulak yorulur ve işitme riski artar.

**Kişisel katman.** Yetişkinlerde 4–8 kHz bölgesinde hafif işitme kaybı yaygındır. Health'te kayıtlı bir işitme testi (odyogram) varsa, bu kayıp kulak başına sınırlı bir kazançla telafi edilir. Böylece "en yüksek ses kalitesi" bu kullanıcının kendi kulağında gerçekleşir.

**Kullanıcı bunu nasıl fark eder?** Her kısık ses dinlemesinde: gece film izlerken, toplu taşımada müzik dinlerken. Sesi kıstığı anda ses incelmez. Etki sürekli ve her gün yaşanan bir durumdur. Hi-fi dünyasında bu ihtiyaç çoktan kabul görmüştür: AV alıcılarındaki Audyssey Dynamic EQ ve amfilerdeki "Loudness" düğmesi aynı sorunu çözer.

**Mevcut fikirlerden farkı:**
- **A7** parçalar arasındaki seviyeyi eşitler, tonal dengeyle ilgilenmez.
- **A6** kulaklığın frekans yanıtını düzeltir, dinleme seviyesine bakmaz.
- **A5 / M9** diyaloğu öne çıkarır ve dinamik sıkıştırma yapar.
- Ses Çekirdeği ise **dinleme seviyesine bağlı**, kişiye özel tonal düzeltme yapar ve bu üçüyle üst üste çalışır.

### 3.3 Nasıl çalışır?

```
Çözülmüş PCM (float32, n kanal: FLAC/ALAC/TrueHD/DTS-HD/LPCM/AAC)
   │
   ├──► SEVİYE TAHMİNCİSİ (kontrol thread'i, 20 Hz; ses thread'ine dokunmaz)
   │       içerik seviyesi : AC-3/E-AC-3/TrueHD dialnorm  |  ReplayGain/R128 (A7)
   │                         | kısa süreli LUFS (vDSP; Music Understanding varsa ondan)
   │       sistem sesi     : AVAudioSession.outputVolume  (KVO)            [doğrulandı]
   │       rota            : port tipi + model tablosu (AirPods/EarPods/hoparlör/BT)
   │                         → "dBFS → dB SPL" ofseti
   │       kalibrasyon     : HealthKit headphoneAudioExposure (dBA, isteğe bağlı) ile
   │                         rota başına ofset kendini düzeltir
   │       ⇒ L_play (phon)                L_ref = 85 (film) / 83 (müzik)
   │
   ├──► KONTUR FARKI  Δ(f) = ISO226(L_ref, f) − ISO226(L_play, f)   (1 kHz'de 0'a normalize)
   │       · %70 uygulama katsayısı (temkinli varsayılan), üst sınır: bas +10 dB, tiz +4 dB
   │       · hoparlör rotasında bas bandı panelin kesim frekansında sınırlanır
   │         (~150–200 Hz altı yükseltilmez; boşa headroom harcanmaz) [doğrulanmalı]
   │       · Δ(f) → 3 minimum-faz biquad (low-shelf ~100 Hz, LF peaking ~50 Hz, high-shelf ~10 kHz)
   │
   ├──► KİŞİSEL KATMAN (isteğe bağlı, tek seferlik izin)
   │       HKAudiogramSample → kulak başına eşik (250 Hz–8 kHz)
   │       → kazanç = 0,5 × (kayıp − 20 dB HL), sınır [0, +12 dB]   (yarım kazanç kuralı)
   │       → kulak başına 6 peaking biquad
   │
   ▼  SES THREAD'İ (gerçek zamanlı, kilitsiz katsayı takası, 10 ms yumuşak geçiş: "zipper" olmaz)
 [Ön kazanç −Δmax] → [Kontur EQ] → [Kişisel EQ] → [True-peak limiter, 1,5 ms lookahead]
   │
   ▼  M9 diyalog → A1 rota profili → sistem uzamsallaştırma / çıkış
```

**Zincirdeki yeri ve kurallar:**
- **Uygulanır:** Uygulamanın PCM ürettiği tüm yollarda. Bunlar FLAC/ALAC müzik, TrueHD/DTS-HD'nin 7.1'e çözüldüğü yol (A4) ve stereo/AAC içeriktir.
- **Uygulanmaz:**
  - **E-AC-3 JOC native Atmos yolu (A3).** Sıkıştırılmış akış doğrudan Apple'ın çözücüsüne gidiyor; araya DSP konamaz. Kart bunu açıkça yazar: *"Ses Çekirdeği: native Atmos'ta devre dışı"*.
  - **Bit-perfect DAC rotası (A2).** Varsayılan olarak kapalıdır, çünkü bit-perfect vaadi önceliklidir ve DAC'ın analog ses seviyesi bilinemez.
- **Uzamsal yolda kişisel katman:** Kulak başına EQ, sistemin binaural render'ından **önce** uygulanabildiği için yaklaşık kalır. Bu yolda iki kulağın ortalaması kullanılır; kulak başına tam düzeltme yalnızca stereo ve uzamsal olmayan yolda yapılır.
- **Referans seviyede şeffaflık:** L_play ≈ L_ref olduğunda Δ(f) ≈ 0 olur ve özellik kendiliğinden etkisizleşir.

**Kullanılacak API'ler ve framework'ler:**
- **AVFAudio:**
  - `AVAudioSession.outputVolume` (KVO) **[doğrulandı]**
  - `currentRoute` / port tipi
  - `outputLatency`
  - `AVAudioUnitEQ` ya da kendi biquad'larımız
- **Accelerate (vDSP):** biquad, LUFS ölçümü, true-peak.
- **AudioToolbox:** gerekirse `AUDynamicsProcessor` / `AUPeakLimiter`.
- **HealthKit:**
  - `HKAudiogramSample`, `HKAudiogramSensitivityPoint` ve iOS 18.1 ile gelen `HKAudiogramSensitivityTest` (kulak tarafı, test tipi) **[doğrulandı]**
  - `HKQuantityTypeIdentifier.headphoneAudioExposure` (dBA) **[doğrulandı]**
  - HealthKit capability'si ücretli hesapta standarttır; `NSHealthShareUsageDescription` gerekir.
- **Music Understanding (iOS 27):** `LoudnessResult` varsa içerik seviyesini oradan alır; yoksa vDSP R128 kullanılır **[A13 desteği doğrulanmalı, AS-17]**.

### 3.4 A13 bütçesi

| Kaynak | Tahmin | Gerekçe |
|---|---|---|
| **CPU (ses thread'i)** | Bir E çekirdeğinin **%1'inden az** | 8 kanal × 3 biquad × 48 kHz ≈ 1,2 M biquad-örnek/sn ≈ 10 MFLOP/s. Kişisel katman (2 × 6 biquad) ≈ 5 MFLOP/s. Limiter birkaç MFLOP/s. Toplam < 30 MFLOP/s. |
| **CPU (kontrol thread'i)** | ~0 | 20 Hz'de filtre tasarımı (tablo enterpolasyonu ve biquad katsayıları). |
| **GPU / ANE** | 0 | — |
| **Gecikme** | ≤ 2 ms | Minimum-faz biquad'lar ve 1,5 ms limiter lookahead. Bu gecikme A1'in A/V senkron telafisine eklenir. |
| **Bellek** | < 1 MB | ISO 226 tablosu ve rota model tablosu. |
| **Pil ve ısı** | İhmal edilebilir | — |
| **Arka plan** | Sorun yok | Yalnızca CPU kullanır. iOS 27'nin arka plan ANE kısıtı bu özelliği etkilemez. |

### 3.5 Kullanıcı deneyimi

**Basit mod (varsayılan): kendiliğinden doğru.**

| Rota | Varsayılan |
|---|---|
| AirPods / kulaklık / BT | Açık |
| Dahili hoparlör | Açık (bas sınırlamasıyla) |
| USB DAC (bit-perfect) | Kapalı |
| AirPlay | Kapalı **[doğrulanmalı]** |
| Native Atmos (E-AC-3 JOC) | Uygulanamaz |

- Kullanıcı hiçbir şey yapmaz. Sesi kıstığında ton dengesi korunur, açtığında düzeltme kendiliğinden azalır ve referans seviyede tamamen kaybolur.
- **Tek seferlik soru:** Health'te bir odyogram varsa (ör. AirPods Pro işitme testi), ilk açılışta bir kart görünür: *"İşitme testi sonucun bulundu. Ses kulaklarına göre ayarlansın mı?"* Kullanıcı Evet ya da Hayır der. Apple'ın kendi işitme cihazı ya da kulaklık uyarlama özelliğini kullanıyorsa, çifte telafiyi önlemek için "Hayır" demesi önerilir.
- Ses kartında (S2'nin ses karşılığı) tek satır görünür: *"Ses Çekirdeği: ~62 phon → referans 85 · +7 dB @50 Hz"*.

**Uzman modu:**
- **Referans seviyesi:** Film 85 / TV 79 / Müzik 83 / Kapalı.
- **Uygulama yoğunluğu:** %0–100 (varsayılan %70).
- **Kalibrasyon:** "Health ile otomatik kalibre et" seçeneği ve elle ofset (± dB).
- **Kişisel katman yoğunluğu:** Varsayılan yarım kazanç kuralı; kulak başına eğrinin görünümü.
- **Bypass A/B:** Basılı tutulduğu sürece ham sesi dinletir. Etki duyularak doğrulanır.

### 3.6 Riskler, doğrulanmalı noktalar, yedek plan

| Risk | Olasılık | Önlem / yedek plan |
|---|---|---|
| **SPL tahmini hatası** (ses seviyesi adımlarının dB karşılığı ve rota duyarlılığı bilinmiyor) **[doğrulanmalı, AS-34]** | Orta | Kontur farkı seviyeyle yavaş değişir, bu yüzden ±5 dB hata sonucu kabaca 1–2 dB bas hatasına çevirir. %70 uygulama katsayısı ve üst sınırlar var. Kalibrasyon Health ile kendini düzeltir. |
| `headphoneAudioExposure` örneklerinin sıklığı ve gecikmesi kalibrasyona yetmeyebilir **[doğrulanmalı]** | Orta | Kalibrasyon olmadan model tablosu kullanılır. Kalibrasyon yalnızca iyileştirme sağlar. |
| Purist kullanıcı "renklendirme" olarak algılayabilir | Düşük–orta | Referans seviyede etki sıfırdır. DAC rotasında kapalıdır. Bypass A/B sunulur. Başarı ölçütü kör testtir (3.7). |
| Bas yükseltmesi clip ya da distorsiyon yaratabilir | Düşük | Negatif ön kazanç ve true-peak limiter. Hoparlörde bas sınırlıdır. |
| Native Atmos (E-AC-3 JOC) yolunda DSP uygulanamıyor | Kesin | Kullanıcıya açıkça söylenir. İsteyen kullanıcı için uzman seçeneği: "E-AC-3'ü PCM'e çöz" (nesneler kaybolur, 7.1 yatak kalır). Varsayılan native Atmos'tur. |
| Apple'ın işitme cihazı ya da kulaklık uyarlama özelliği açıksa çifte telafi olur; bunu public API ile tespit etmek muhtemelen mümkün değil **[doğrulanmalı, AS-36]** | Orta | Kişisel katman yalnızca tek seferlik onayla açılır ve kartta uyarı bulunur. |
| AirPods işitme testi verisinin üçüncü parti uygulama tarafından okunabilmesi **[doğrulanmalı, AS-36]** | Düşük–orta | `HKAudiogramSensitivityTest` (iOS 18.1) bu verinin HealthKit'te tutulduğunu gösteriyor. Okunamazsa kişisel katman yalnızca elle içe aktarılan odyogramla çalışır. Kontur katmanı her durumda çalışır. |
| ISO 226 veri tablolarının lisansı **[doğrulanmalı]** | Düşük | ISO 226:2003'teki formül ve katsayılar yaygın olarak yayımlanmıştır. Gerekirse açık araştırma verisinden türetilmiş bir eğri seti kullanılır. |
| Tıbbi cihaz algısı | Düşük | Kişisel katman "tonal kişiselleştirme" olarak sunulur, işitme cihazı olarak değil. Üst sınır +12 dB'dir ve konuşma bandı dışında agresif değildir. |

### 3.7 Ölçülebilir başarı ölçütü ve spike'lar

**Kullanıcı açısından başarı ölçütü:**
- Düşük seviyede (≤ 60 phon) kör A/B testinde kullanıcı Ses Çekirdeği'ni **≥ 8/10** klipte (film ve müzik) tercih eder.
- Referans seviyede bypass ile **ayırt edilemez** (ABX'te şans düzeyi).
- Sesi kısınca kullanıcı "ses inceldi" demez.

| # | Soru ("şu çalışır mı?") | Başarı ölçütü | Süre |
|---|---|---|---|
| **AS-34** | Dinleme seviyesi (phon) yeterince doğru tahmin edilebilir mi? | (1) `outputVolume` adım → dB eğrisi her rota için çıkarılır (dijital loopback; hoparlör için ölçüm mikrofonu). (2) AirPods'ta 10 oturum boyunca tahmin ile HealthKit `headphoneAudioExposure` karşılaştırılır; **ortalama mutlak hata ≤ 4 dB**. (3) `headphoneAudioExposure` örneklerinin sıklığı ve gecikmesi raporlanır. | 3 gün |
| **AS-35** | Kontur EQ ve limiter PCM yoluna sorunsuz eklenebilir mi? Kulağa doğru gelir mi? | (1) FLAC ve TrueHD → 7.1 → (AVSampleBufferAudioRenderer ya da AVAudioEngine) yolunda **CPU < %1**, **ek gecikme < 2 ms**, kilit ekranında 1 saatte **0 glitch**. (2) Çıkış yanıtı hedef Δ(f)'ye **±1,5 dB** içinde uyar (dijital ölçüm, 20 Hz–16 kHz). (3) Kör test: düşük seviyede **≥ 8/10 tercih**, referans seviyede ABX şans düzeyi. (4) Sistem uzamsallaştırmasıyla birlikte çalıştığı doğrulanır. | 4 gün |
| **AS-36** | Kişisel katman için gerekenler mevcut mu? | (1) AirPods Pro işitme testinden gelen `HKAudiogramSample` okuma izniyle okunur ve kulak tarafları ayrılır. (2) Apple'ın işitme cihazı ya da kulaklık uyarlama özelliğinin açık olduğu tespit edilebiliyor mu? Evet ya da hayır. (3) ISO 226 eğri verisinin kullanım koşulları netleşir. | 1–2 gün |

### 3.8 MVP mi, v1.1 mi? → **v1.1 (ilk iş)**

**Gerekçe:**
1. **Bağımlılık:** Ses Çekirdeği, MVP'deki PCM DSP zincirinin üzerine oturur (M4, M5, M9, AS-12, AS-13). Ekleme noktası ve gerçek zamanlı thread modeli önce MVP'de kanıtlanmalı.
2. **MVP'nin ses riski zaten yüksek:** Native Atmos (AS-9), bit-perfect (AS-11) ve AI diyalog (AS-12) aynı ekibin dikkatini istiyor. Ses Çekirdeği düşük riskli, ama kör test ve kalibrasyon için dinleme zamanı gerektiriyor.
3. **Maliyeti düşük, getirisi yüksek:** Bu yüzden v1.1'in ilk maddesi. AS-34 MVP sırasında ve paralelde sonuçlanırsa, **yalnızca kontur katmanı** (kişisel katman olmadan) MVP sonuna çekilebilir.

---

## 4. Elenen adaylar

| # | Aday | Neden elendi |
|---|---|---|
| K3 | ABL Kalkanı (Vision saliency ile geniş parlak alanları kısıp özneyi tepede tutmak) | Görüntünün bir kısmını bilinçli olarak karartıyor; kullanıcının "parlaklığa dokunma" çizgisiyle çatışıyor. ABL ve headroom davranışı ölçülmeden (AS-27) faydası belirsiz. AS-27'den sonra yeniden bakılabilir. |
| K4 | ML kaynak ayrıştırmalı stereodan uzamsala upmix | ANE'yi gerçekten kullanıyor, ama orijinal miksi değiştiriyor; audiophile için "abartı". A13'te gerçek zamanlı ayrıştırma ağır. |
| K5 | Hoparlör için psikoakustik bas ve loudness maksimize edici | Algılanan bası artırıyor, ama sıkıştırma ve yapay harmonik ses kalitesini düşürüyor. A10 (Taptic subwoofer) ile örtüşüyor. |
| K6 | TrueDepth ile baş takipli hoparlör crosstalk iptali | Wow etkisi yüksek, ama ön kamera sürekli açık kalıyor (pil, gizlilik, kamera göstergesi) ve sweet spot küçük. Günlük kullanıma uygun değil. |
| K7 | SDR'dan HDR'a AI ters ton eşleme | M2'de beyaz zaten tepede; vurgulara yer kalmadığı için ya etkisiz kalıyor ya da beyazı düşürmeyi gerektiriyor. Kullanıcı tercihiyle çelişiyor. |
| K8 | Parlaklık öncelikli ısıl bütçe planlayıcı | V6'nın (ısıyı gözeten kalite yöneticisi) varyasyonu. Ajan 2'ye V6'nın uygulama notu olarak iletilebilir. |
| K9 | İçerik türüne göre otomatik profil (anime/konser/film) | S1/A1'in varyasyonu; süs olma riski taşıyor. |
| K10 | ML chroma upsampling (4:2:0 → 4:4:4) | 458 ppi'de ve 4K → 1125p küçültmede algısal fark çok küçük; günlük hissedilmez. |
| K11 | Lossy ses restorasyonu (bant genişliği genişletme) | Kullanıcının içeriği zaten kayıpsız (remux, FLAC); faydası yok. |
| K12 | TPDF dither ve gürültü şekillendirmeli "audiophile" ses seviyesi | iOS'un float mikserinde duyulabilir bir fark yok; plasebo. |

**Ajan 2'ye yan not (yeni fikir değil):** M9 (AI diyalog) müzikli sahnelerde AUSoundIsolation'ı otomatik olarak gevşetmeli (Sound Analysis'in müzik sınıfı ile). Bu M9'un bir uygulama ayrıntısıdır.

---

## 5. Ajan 2 için entegrasyon özeti

Bu belge `02-cozum.md`'yi değiştirmez. Ajan 2 onay sonrası bu notları kendi belgesine işleyebilir.

| Fikir | Hatta yeri | Paylaştığı veri | Etkilediği mevcut spike'lar |
|---|---|---|---|
| N1 Temiz Nit | M2 Metal geçişi: 0. adım (kod değerleri alanında) ve 6. adım (çıkış titreşimi) | `currentEDRHeadroom` (M2 ile aynı okuma), kaynak bit derinliği (`CMFormatDescription`) | AS-29 (toplam GPU bütçesi ≤ 4,5 ms), AS-28 (ısı) |
| N2 Ses Çekirdeği | PCM DSP zinciri: M9'dan sonra, A1 rota profili ve uzamsallaştırmadan önce; zincirin sonundaki limiter | Rota bilgisi (A1), içerik seviyesi (A7 / dialnorm), `outputVolume` | AS-12, AS-13 (gerçek zamanlı thread), AS-17 (Music Understanding) |

---

## 6. Kaynaklar

**Apple (birincil)**
- [UIScreen.potentialEDRHeadroom](https://developer.apple.com/documentation/uikit/uiscreen/potentialedrheadroom) · [CAEDRMetadata](https://developer.apple.com/documentation/quartzcore/caedrmetadata)
- [AVAudioSession.outputVolume](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume)
- HealthKit: [HKAudiogramSample](https://developer.apple.com/documentation/healthkit/hkaudiogramsample) · [HKAudiogramSensitivityPoint](https://developer.apple.com/documentation/healthkit/hkaudiogramsensitivitypoint) · [HKAudiogramSensitivityTest (iOS 18.1)](https://developer.apple.com/documentation/healthkit/hkaudiogramsensitivitytest) · [headphoneAudioExposure](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/headphoneaudioexposure)
- [AirPods Pro ile İşitme Testi (sonuçlar Health'te saklanır)](https://support.apple.com/120991)
- [iOS & iPadOS 27 sürüm notları: arka planda ANE kısıtı](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)

**Görüntü: bantlanma ve algı**
- [CAMBI: Contrast-aware Multiscale Banding Index (Netflix, arXiv 2102.00079)](https://arxiv.org/pdf/2102.00079) · [CAMBI belgesi (libvmaf)](https://github.com/AyazKhuraishi/netfllix-vmaf/blob/master/resource/doc/cambi.md)
- [SMPTE: PQ'nun Barten modeline dayanması](https://www.smpte.org/blog/etia-2015-introduction-image-quality) · [Tom's Hardware: 10/12-bit ve Barten eşiği](https://www.tomshardware.com/news/what-is-10-bit-color,36912.html)
- [libplacebo debanding parametreleri (FFmpeg belgesi)](https://ffmpeg.org/pipermail/ffmpeg-devel/2022-April/294880.html) · [libplacebo MR 594: deband varsayılanlarının ayarlanması](https://code.videolan.org/videolan/libplacebo/-/merge_requests/594)

**Ses: eşit ses yüksekliği ve referans seviyesi**
- [ISO 226:2023 eşit ses yüksekliği eğrileri (DIN kaydı)](https://www.din.de/en/wdc-proj:din21:379070391)
- [Sound & Vision: Audyssey Dynamic EQ](https://soundandvision.com/node/92634) · [Sound & Vision: loudness düzeltmelerinin karşılaştırması](https://www.soundandvision.com/markfleischmann/loudness/index.html) · [CinemaConfig: Dynamic EQ](https://cinemaconfig.com/reference/audyssey-dynamic-eq)
- Dialnorm: [Microsoft eAVDecDDOperationalMode (−31 dBFS referansı)](https://learn.microsoft.com/en-us/windows/win32/api/codecapi/ne-codecapi-eavdecddoperationalmode) · [FFmpeg AC-3 dialnorm yaması](https://ffmpeg.org/pipermail/ffmpeg-devel/2014-August/161911.html) · [TV Technology: Dialnorm](https://www.tvtechnology.com/opinions/dialnorm-a-good-idea-gone-bad)
