# 01 — Konsept ve İnovasyon

> **Aşama:** 1 / 3 · **Ajan:** `fikir-ajani` · **Tarih:** 25 Ekim 2026 · **Girdi:** `docs/00-brief.md` · **Durum:** rev. 2, kullanıcı geri bildirimi işlendi, onay bekliyor
>
> **Rev. 2 değişiklikleri (kullanıcı kararı):**
> - **Nit Çekirdeği eklendi ve en öncelikli özellik oldu (M2):** SDR'da da HDR'da da tipik beyaz yaklaşık 1200 nit.
> - **OCR, çeviri ve otomatik altyazı senkronu kapsamdan çıktı:** Altyazılar videoyla birlikte, gömülü olarak geliyor.
> - **OLED koruması parlaklığa dokunmayacak şekilde yeniden tanımlandı (P2).**
>
> **Rev. 3 (kullanıcı kararı):** AI diyalog netleştirme MVP'ye ayrı bir madde olarak eklendi (M9). MVP 9 özellik oldu.
>
> **Rev. 4 (kullanıcı kararı):**
> - `01b-ek-fikirler.md` onaylandı. **N1 Temiz Nit**, M2'nin ayrılmaz parçası olarak MVP'de. **N2 Ses Çekirdeği** v1.1'in ilk işi.
> - **M10 ses yükseltme (boost)** MVP'ye eklendi. En fazla %50; %150, yaklaşık +6 dB demek. MVP 10 özellik oldu.
>
> **Rev. 5 (kullanıcı kararı):** **Sahne bazlı referans beyaz tespiti** (V3'ün `L_ref` kısmı) v1.1'den MVP'ye, M2'nin içine çekildi. Gerekçe: Normal beyazı 100–150 nite koyan HDR10 filmlerde "Maksimum" modunda beyaz 640–980 nitte kalıyordu (`02-cozum.md` §3.5). Tam dinamik ton eşleme v1.1'de kalıyor.
>
> **İşaretler:** **[doğrulandı]** = Apple dokümantasyonu, WWDC oturumu ya da iOS 27 sürüm notlarıyla teyit edildi. **[doğrulanmalı]** = ikincil kaynak, forum raporu ya da çıkarım. Ajan 2 bunları spike ile teyit etmeli.
>
> **Puanlar:** **W** = wow etkisi (1–5). **F** = A13 + iOS 27 üzerinde fizibilite (1–5). 5, bilinen API ile kesin yapılabilir demek; 1, pratikte imkânsız demek.

---

## 0. Yönetici özeti

- **Vizyon:** Kendi diskinden aldığın film ve müzik, iPhone 11 Pro'nun verebileceği en sadık görüntü ve sesle oynar. Tek dokunuş yeter, ayar gerekmez, tüm AI cihazda çalışır.
- **MVP (10 özellik):**
  1. Evrensel oynatma çekirdeği (MKV/ISO/BDMV)
  2. **Nit Çekirdeği: SDR ve HDR'da tipik beyaz yaklaşık 1200 nit (en öncelikli).** 8-bit kaynakta bant gidermek için Temiz Nit dahil.
  3. HDR ve Dolby Vision çözme (P7'nin P8.1'e dönüştürülmesi dahil). Nit Çekirdeğini besler; ayrıca "Referans" modu var.
  4. Rotayı tanıyan sinema sesi (native Atmos, 7.1'in uzamsal sese aktarılması, diyalog/gece modu)
  5. Audiophile müzik (bit-perfect DAC, gapless, loudness)
  6. Gömülü altyazı (MKV içindeki PGS/SRT/ASS parçaları ekran çözünürlüğünde)
  7. Kaynaklar ve kütüphane (SMB, Jellyfin, Plex)
  8. Sıfır ayar deneyimi
  9. AI diyalog netleştirme (stereoda AUSoundIsolation, çok kanallıda merkez kanal)
  10. Ses yükseltme (boost): %100–%150, en fazla yaklaşık +6 dB, kırpma olmadan
- **iOS 27 araştırmasından çıkan üç kritik ders:**
  1. iOS 27 iPhone 11 Pro'yu destekliyor. Ancak A13 "temel katmanda": Apple Intelligence yok, Metal 4 yok, SpeechTranscriber muhtemelen yok.
  2. iOS 27 ile gelen yeni ML API'lerinin (Core AI, Music Understanding, VTFrameProcessor) A13'te nasıl çalıştığı belgelenmemiş. Bu yüzden MVP bunlara **bağımlı olmamalı**. Bu API'ler "varsa kullan" katmanında durur.
  3. iOS 27, uygulama arka plandayken Neural Engine erişimini kısıtladı ve bunun için yeni bir entitlement getirdi. Arka planda çalışacak AI işleri buna göre tasarlanmalı.

---

## 1. Vizyon

### 1.1 Ürün vaadi (tek cümle)

> **"Diskindeki film ve müzik, cebinde de diskteki gibi: gerçek Dolby Vision, gerçek Atmos, bit-perfect ses. Tek dokunuşla, ayarsız, tüm zekâsı cihazın içinde."**

### 1.2 Neden bu uygulama? (kullanıcının gözünden)

| Kullanıcının sorusu | Bugünkü durum | arifetanga'nın cevabı |
|---|---|---|
| "UHD remux'umu açınca gerçekten Dolby Vision mı görüyorum?" | Yaygın oynatıcılar Profile 7'yi sessizce HDR10'a düşürüyor (Infuse forumu) | P7, P8.1'e çevrilir ve DV olarak oynar. Ekranda ne oynadığı ve varsa neden düşürüldüğü açıkça görünür. |
| "AirPods'umda filmin Atmos'unu duyabilir miyim?" | Yerel dosyada Atmos'un uzamsal sese aktarılması sınırlı ya da hiç yok | E-AC-3 JOC, Apple'ın kendi Dolby çözücüsüne verilir. TrueHD ve DTS-HD 7.1'e açılıp head tracking'li uzamsal sesle çalınır. |
| "DAC'ımı taktım. Ses bit-perfect mi?" | Görünmez; çoğu uygulama bir şey söylemiyor | Örnekleme hızı otomatik değişir. "Dosya → çözücü → DAC" zinciri ekranda görünür. |
| "Blu-ray altyazısı küçük, Türkçesi yok, üstelik kaymış." | PGS bir görüntüdür; ne boyutu değişir ne çevrilebilir | PGS cihazda okunur, Türkçe'ye çevrilir ve siyah banda taşınır. Senkron kendiliğinden düzelir. |
| "Ayar yapmak istemiyorum ama uzman kontrolü de isterim." | Ya çok basit ya ayar cehennemi | Varsayılanlar rotaya, dosyaya ve ekrana göre doğru gelir. Uzman katmanı bir dokunuş uzakta. |
| "Verilerim buluta gitmesin." | Bazı AI özellikleri sunucuya gidiyor | Tüm AI cihazda çalışır. Hesap zorunlu değildir. |

### 1.3 Rakip haritası

| Uygulama | Güçlü yanı | Boşluk (bizim fırsatımız) |
|---|---|---|
| **Infuse** | Cilalı arayüz, geniş format desteği, Trakt | DV P7'yi HDR10'a düşürüyor ya da yeniden kodlama gerektiriyor (Firecore forumu, Ağustos 2026). TrueHD Atmos'un uzamsal sese aktarılması sınırlı. Cihazda AI yok. |
| **SenPlayer** | Geniş format desteği, HDR odaklı | Arayüzü karmaşık. AI yok. DV dönüşüm kalitesi **[doğrulanmalı]**. |
| **VLC** | Ücretsiz, neredeyse her şeyi açıyor | EDR ve DV zayıf. Ses sadakati kontrolü yok. |
| **nPlayer** | Geniş codec desteği | Eski arayüz, HDR zayıf **[doğrulanmalı]**. |
| **Plex / Jellyfin (Swiftfin)** | Sunucu ekosistemi | İstemci tarafı transcode'a bağımlı. DV ve ses sadakati tutarsız. |
| **Apple TV uygulaması** | Native HDR, DV ve Atmos için referans kalite | MKV, yerel dosya ve NAS desteği yok. |
| **Apple Music** | Lossless, hi-res, uzamsal ses | Kendi FLAC arşivini çalamıyor. DAC ve EQ kontrolü yok. |

**Konum:** Apple TV uygulamasının görüntü ve ses sadakati, Infuse'un format genişliği ve Apple framework'lerine dayanan, cihazda çalışan görünmez AI bir arada.

### 1.4 Tasarım ilkeleri

1. **Önce sadakat.** Kaynak bozulmadan gösterilir. Bir düşürme olursa kullanıcıya söylenir.
2. **Sıfır ayar, sınırsız derinlik.** Varsayılan her zaman doğrudur. Uzman kontrolleri katmanlı olarak açılır.
3. **Önce native.** AVFoundation, VideoToolbox, Core Audio ve Metal kullanılır. Üçüncü parti kod yalnızca gerçek bir boşluğu doldurur (MKV demux, TrueHD/DTS çözme, ASS render).
4. **Görünmez AI.** AI ayrı bir "mod" değildir. Altyazıyı, sesi ve kütüphaneyi sessizce iyileştirir. Hepsi cihazda çalışır.
5. **Cihazını tanı.** Uygulama A13'ün, 4 GB RAM'in ve 60 Hz ekranın sınırlarını bilir. Kalite yöneticisi ısıyı ve pili gözetir.

---

## 2. iOS 27 / WWDC26 araştırma bulguları

### 2.1 Platform gerçeği

- **iOS 27, iPhone 11 Pro'yu destekliyor.** Desteklenen cihaz listesi iOS 26 ile aynı kaldı ve iPhone 11 serisinin listeden çıkacağı söylentileri doğru çıkmadı. **[doğrulandı: birden çok haber kaynağı Apple duyurusuna dayanıyor]**
- **A13 en alt katmanda.** Üst katman yalnızca iPhone 17 Pro, 17 Pro Max ve Air; buradaki yeni Siri modeli en az 12 GB RAM istiyor. Orta katman iPhone 15 Pro ve 16 serisi; bunlarda Apple Intelligence var. iPhone 15'ten iPhone 11'e kadar olanlar Apple Intelligence olmadan iOS 27 alıyor (MacRumors).
- **Metal 4 iPhone 12 (A14) ve sonrasını istiyor.** Bu yüzden A13'te Metal 4, Metal tensors ve "neural rendering" oturumlarındaki yenilikler yok. **[doğrulandı: Apple destek sayfası]**
- **iOS 27.0.1:** Sürüm kullanıcının beyanıdır. Apple'ın sürüm notu dizininde 27 ve 27.2 notları var.

### 2.2 Yeni ve ilgili API'ler

| API (ilk sürüm) | Ne yapar | A13 durumu | Projeye etkisi |
|---|---|---|---|
| **Core AI** (iOS 27, yeni) | PyTorch modelini `.aimodel`'e çevirir ve CPU, GPU ya da ANE üzerinde çalıştırır (`ComputeUnitKind`). Specialization, `AIModelCache`, stateful çalıştırma (KV cache) ve Swift API'si sunar. Core ML ağ dışı modeller için yerinde kalıyor. | Apple "tüm Apple silicon'da" diyor. Ancak **AOT derleme yalnızca Apple Intelligence destekli cihazlar (A17 Pro+) için** var. A13'te ilk yüklemede tam specialization cihazın üzerinde yapılır. A13'te gerçekten çalıştığı **[doğrulanmalı]**. | Yeni modeller için tercih edilecek yol bu. A13'te Core ML yedek yolu şart. |
| **Arka planda Neural Engine kısıtı** (iOS 27) | Arka planda ANE'ye erişmek `com.apple.developer.background-tasks.continued-processing.inference` entitlement'ını istiyor. Kısıt Core AI, Core ML ve MPSGraph'ın hepsini kapsıyor. `BGContinuedProcessingTask` ile birlikte kullanılıyor. | Sürüm notu bunu "Apple Intelligence capable devices" bağlamında anlatıyor. A13'e uygulanıp uygulanmadığı ve ücretli hesapla profile eklenip eklenemeyeceği **[doğrulanmalı]**. | Ses arka planda çalarken AI işleri ya CPU'da ya da ön planda (şarjdayken) yapılmalı. |
| **Music Understanding** (iOS 27, yeni) | Altı boyutta analiz yapar: ton (key), ritim (BPM, beat ve bar), yapı (bölüm, segment, cümle), pace, enstrüman aktivitesi ve loudness (LUFS integrated/momentary/short-term, peak). Girdi `AVAsset` ya da `AVReadOnlyAudioPCMBuffer` akışı olabilir. Korumalı içerikte `hasProtectedContent` hatası verir. | Donanım şartı belgelenmemiş **[doğrulanmalı]**. | Loudness normalizasyonu, müzikal geçişler, görselleştirici ve "nakarata atla" için kullanılır. |
| **Now Playing framework** (iOS 27, yeni) | `@Observable` model ile Kilit Ekranı, Denetim Merkezi, Watch ve CarPlay'e bağlanır. `MovieContent` ve `Music` tiplerini ve uzak oturumları destekler. **`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter` ile karıştırılmamalı** (tanımsız davranış). | iOS 27 framework'ü olduğu için A13'te çalışır. iPhone 11 Pro'da Dynamic Island yok. | Medya kontrolleri baştan bu framework ile kurulur. |
| **Oluşturulan altyazılar** (iOS 27) | AVPlayer'da otomatik çalışır. İngilizce sesten İngilizce altyazı, İngilizce altyazıdan da başka dillere çeviri üretir. Cihazda çalışır ve uygulamanın bir şey yapması gerekmez. | İkincil kaynaklara göre özellik başlangıçta yalnızca İngilizce ve yalnızca ABD/Kanada için. Bir kaynak iPhone 15 Pro ve sonrasını şart koşuyor **[doğrulanmalı]**. A13'te SpeechTranscriber yok (aşağıya bakın). Bu yüzden A13'te **büyük olasılıkla çalışmıyor**. | Altyazı üretim ve çeviri hattını kendimiz kurmalıyız (I2, I3). Özel video hattına (MKV) bu özellik zaten gelmez. |
| **Altyazı stil önizleme** (iOS 26.4) | `AVPlayerLayer.setCaptionPreviewProfileID(_:position:text:)` ve `stopShowingCaptionPreview()`. Sistem stil profilleri `MACaptionAppearance…` ile okunur. | Çalışır. | Kendi altyazı motorumuz sistemdeki erişilebilirlik stil profillerini okumalı. Böylece sıfır ayarla erişilebilirlik sağlanır. |
| `AVPlayerItem.selectableMediaSelectionOptions(in:)` (iOS 27) | Gerçekten içerik üretebilecek medya seçeneklerini süzer. | Çalışır. | AVPlayer yolunda menünün doğru gelmesini sağlar. |
| `AVPlayer.disconnectedFromSystemAudio` (iOS 27) | Oynatıcıyı audio session'dan koparır. Oynatıcı oturumu etkinleştirmez ve rota değişince kendini yeniden yapılandırmaz. | Çalışır. | Önizleme, sarma ve sonraki öğenin hazırlanması çalan sesi bozmadan yapılabilir. |
| `AVSampleBufferVideoRenderer.Receiver` (iOS 27) | Yeni bir sample buffer besleme API'si: `enqueue`, `enqueueImmediately` ve `renderingEvents…`. | Çalışır. Davranış ayrıntıları **[doğrulanmalı]**. | Özel (MKV) video hattının çekirdek API adayı. |
| `AVAudioSession` async `activate`, `DeactivationContext`, `ResumptionRecommendation` (iOS 27) | Kesintiden sonra sistem "devam et" ya da "devam etme" önerisi verir; deaktivasyonun nedenini de bildirir. | Çalışır. | Arama ya da alarmdan sonra oynatma doğru şekilde kendiliğinden sürer. |
| `AVReadOnlyAudioPCMBuffer` (iOS 27) | Sendable, salt okunur bir PCM tamponu. | Çalışır. | Swift Concurrency ile güvenli analiz (Music Understanding ve Speech beslemesi). |
| Speech: `AssetInputSequenceProvider`, `AnalyzerInputConverter` (iOS 27) | Dosyadan ya da asset'ten konuşma analizi için girdi sağlar. | **SpeechTranscriber A13'te `isAvailable = false` döndürüyor.** iPhone SE 2 (A13) üzerinde test edildi; iPhone 11 serisi aynı listede (forum) **[doğrulanmalı]**. `DictationTranscriber` ise Apple'a göre "eski cihazlarla uyumlu" **[doğrulandı]**. | Yerel altyazı üretimi DictationTranscriber ya da Whisper (Core ML) ile yapılabilir. |
| **VideoToolbox VTFrameProcessor** ailesi (iOS 26). iOS 27'de LL süper çözünürlük 1.5x ölçeği destekliyor, LL ara kare 1080p'ye kadar her boyutu kabul ediyor. | ML tabanlı süper çözünürlük, ara kare, zamansal gürültü filtresi ve hareket bulanıklığı. | Destek çalışma anında `isSupported` ile anlaşılır. **Apple DTS'e göre `isSupported = true` dönen bir cihazda bile 1080p ve 720p için ölçek listesi boş geldi; 640×480 için `[2.0]` döndü.** Bu, DVD/SD için umut verici. A13'te durumu **[doğrulanmalı]**. | DVD/SD için AI ölçekleme (V9) ve deneysel "akıcı mod" (V8). |
| `AVDisplayDynamicRange` (iOS 26) | `AVPlayerViewController.preferredDisplayDynamicRange`: automatic / standard / constrainedHigh / high. | Çalışır (AVKit yolunda). | "Parlaklık kipi" seçeneği. Özel hatta eşdeğerini biz kurarız. |
| `TranslationSession.Strategy` (iOS 26.4) | `highFidelity` ya da `lowLatency`. Sistem cihaz yeteneğine göre seçim yapar. | A13'te hangisinin seçildiği **[doğrulanmalı]**. | Altyazı çevirisi (I3). |
| Vision (iOS 27): `GenerateIterativeSegmentationRequest`; Foundation Models için OCR ve barkod araçları | Dokunarak segmentasyon yapar; bunun için model indirmek gerekir. | FM araçları A13'te yok (Apple Intelligence gerektiriyor). Segmentasyon **[doğrulanmalı]**. | Düşük öncelik. |
| Foundation Models: `LanguageModel` protokolü + Core AI LM (iOS 27) | Kendi küçük LLM'ini (ör. Qwen 0.6B) aynı `LanguageModelSession` API'siyle çalıştırmayı sağlar. | `SystemLanguageModel` A13'te yok. Core AI LM'in A13'te çalışması **[doğrulanmalı]**. 4 GB RAM ciddi bir sınır. | v2'de deneysel. |
| **MediaExtension** | Sistem çapında format okuyucu ve çözücü eklentileri. | Hâlâ **yalnızca macOS 15+ ve Mac Catalyst 18** destekli; iOS'ta yok **[doğrulandı]**. | MKV ve TrueHD desteğini uygulamanın içinde kendimiz sağlarız. |
| Media Device Extension / AVSystemRouting (iOS 27) | Üçüncü parti yayın protokollerini sistemin rota seçicisine ekler. | Yönetilen bir entitlement istiyor ve kapsayıcı uygulamanın tek amacı bu eklentiyi dağıtmak olmalı → bize uygun değil. | Başkasının eklentisini AVSystemRouting ile kullanmak v2'ye kaldı. |
| AudioAccessoryKit (iOS 27) | Üçüncü parti kulaklıklara sabit uzamsal ses bilgisi verir. | Şimdilik yalnızca geliştirici testinde; müşterilere ileride ve yalnızca AB'de açılacak. | Etkisi yok. |

### 2.3 Araştırmadan çıkan tasarım kuralları (ajan 2 için girdi)

1. **"Varsa kullan" katmanı.** Core AI, Music Understanding ve VTFrameProcessor ancak çalışma anında yetenek kontrolünden geçerse devreye girer. Kontrol başarısızsa Core ML, Accelerate ya da Metal yedeği çalışır. MVP'nin hiçbir özelliği yalnızca bu üç API'ye bağlı olmamalı.
2. **AI zamanlaması.** AI işleri ön planda ya da "şarjda ve ekran açıkken" çalışır. Arka planda yalnızca CPU kullanılır; aksi halde yeni entitlement gerekir.
3. **İki oynatma yolu.** AVPlayer yolu MP4, MOV ve HLS içindir; özel yol MKV, ISO ve BDMV içindir. iOS 27'nin AVPlayer'a getirdiği yenilikler (oluşturulan altyazı, stil önizleme) özel yola kendiliğinden gelmez. Bu farkı kullanıcı görmemeli.
4. **Now Playing framework'ü seçilir.** MediaPlayer'ın eski API'leriyle karıştırılmaz.

---

## 3. Fikir havuzu

Toplam 54 fikir, altı eksende. Sütunlar: **#**, Fikir, Açıklama, Kullanıcı değeri, **W**, **F**, Fizibilite gerekçesi, Framework'ler.

### 3.A Görüntü kalitesi (HDR/EDR, Dolby Vision, renk, ton eşleme)

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| V1 | Referans HDR hattı | HDR10, HLG ve DV P5/P8.1/P8.4 sistemin kendi DV/HDR işleyişiyle EDR'de gösterilir. Renk matrisi, aralık (limited/full) ve chroma doğru seçilir. | "Disk neyse o" görüntü | 3 | 4 | A13'te HEVC Main10 ve DV için donanım çözme var. MKV'den doğru `CMFormatDescription` (dvcC/hvcC) kurmak emek ister **[doğrulanmalı]**. | AVFoundation (AVSampleBufferDisplayLayer / Receiver), VideoToolbox, Core Media, Core Video |
| V2 | DV P7'yi P8.1'e canlı dönüştürme | UHD BD remux'larındaki çift katmanlı P7'nin RPU'su P8.1'e çevrilir, EL atılır ve içerik DV olarak oynar. MEL'de kayıp neredeyse yoktur; FEL'de EL'nin katkısı kaybolur. | Rakiplerin HDR10'a düştüğü yerde DV | 5 | 3 | RPU ayrıştırıp yeniden yazmak CPU'da hafif bir iş. Riskler bit düzeyinde doğruluk ve FEL kaybı. DRM aşma yok; bu bir format dönüşümü. | VideoToolbox, Core Media; RPU mantığı (dovi_tool benzeri, lisans **[doğrulanmalı]**) |
| V3 | Ekrana göre dinamik ton eşleme | HDR10'un statik meta verisi yerine sahne ölçülür (histogram). Eğri `currentEDRHeadroom`'a göre sahne sahne kurulur; madVR mantığı. | Karanlık sahnede detay görünür, parlak sahnede patlama olmaz | 5 | 3 | Ekran çözünürlüğüne indirilmiş karede Metal compute ucuz. Ancak native HDR yolundan çıkıp CAMetalLayer + EDR'ye geçmek gerekiyor; bu yüzden iki ayrı mod olur. | Metal, QuartzCore (CAMetalLayer, CAEDRMetadata), UIKit (EDR headroom) |
| V4 | HDR10+ dinamik meta veri | SEI'deki HDR10+ eğrisi bizim ton eşleyicimizle uygulanır. | HDR10+ kaynaklı rip'lerde doğru görüntü | 3 | 3 | Sistemin iPhone 11 Pro'da HDR10+ işleyip işlemediği **[doğrulanmalı]**. V3 altyapısını kullanır. | Metal, VideoToolbox |
| V5 | HDR rozeti ve "Neden parlamıyor?" | Oynatma sırasında DV/HDR10/HLG rozeti ve anlık EDR headroom gösterilir. Parlaklık önerisi verilir; düşürme olduysa nedeni açıklanır. | Güven verir ve öğretir | 3 | 5 | `UIScreen.potentialEDRHeadroom` / `currentEDRHeadroom` (iOS 16) mevcut **[doğrulandı]**. | UIKit, AVFoundation |
| V6 | Isıyı gözeten kalite yöneticisi | `thermalState` ve pil durumuna göre ton eşleme, ölçekleme ve AI işleri kademeli olarak kısılır. | Film ortasında kasma ya da kararma olmaz | 2 | 5 | Standart API. | Foundation, MetricKit |
| V7 | Akıllı doldurma ("Doldur+") | 2.39:1 filmde 19.5:9 ekran en az kırpmayla doldurulur. 16:9 içerikte Vision saliency ile sahneyi izleyen yumuşak bir pan yapılır. | Küçük ekranda daha büyük görüntü | 4 | 3 | Saliency her karede değil, sahne başına hesaplanır. Estetik ve titreme riski var; varsayılan olarak kapalı. | Vision, Core Animation |
| V8 | 24p kadansında kusursuzluk ve "akıcı mod" | 23.976 fps içerik 60 Hz ekranda jitter'sız 3:2 kadansla gösterilir. İsteyen için ML ara kareyle akıcı mod sunulur. | Kaydırma sahnelerinde titreme azalır | 4 | 2 | Kadans tek başına F4 (CADisplayLink zamanlaması). Ara kare için VTLowLatencyFrameInterpolation 1080p'ye kadar çalışıyor, ama A13 desteği ve 24→60 gibi tam sayı olmayan oran belirsiz. Isınma da riskli. | AVFoundation, VideoToolbox (VTFrameProcessor), QuartzCore |
| V9 | SD/DVD/720p için AI ölçekleme | DVD (480/576) ve 720p ML ile 1.5x/2x büyütülür. Destek yoksa Metal shader yedeği (FSRCNN veya Anime4K tarzı) devreye girer. | Eski arşiv 458 ppi'de keskin görünür | 4 | 3 | Apple DTS: LL süper çözünürlük 640×480'de 2x destekliyor, ama 720p'de liste boş gelebilir. DVD için uygun. A13 `isSupported` **[doğrulanmalı]**. | VideoToolbox, Core ML, Metal |
| V10 | DVD gren ve gürültü temizleme | VTTemporalNoiseFilter ile eski ve gürültülü kaynaklar temizlenir. | Daha temiz görüntü | 3 | 2 | `isSupported` ve A13 performansı bilinmiyor. Gren sanatsal bir tercih olabilir. | VideoToolbox, Metal |
| V11 | Kaliteli deinterlace | DVD ve 1080i kaynaklar için Metal'de bwdif/yadif mantığıyla deinterlace. | Tarak çizgisi kalmaz | 3 | 4 | Bilinen algoritma; Metal'de ucuz. | Metal, Core Video |
| **V12** | **Nit Çekirdeği (kullanıcının 1 numaralı isteği)** | Her kare kendi Metal çekirdeğimizden geçer ve tipik beyaz panelin tepe parlaklığına (yaklaşık 1200 nit) çıkarılır. SDR: BT.1886 → lineer → beyaz (1.0) × `currentEDRHeadroom`. HDR/DV: PQ/HLG → nit → referans beyaz (yaklaşık 203 nit ya da içerik analizi) hedefe çekilir; üstündeki vurgular yumuşak dirsekle kalan alana sıkıştırılır. Ayrıntılar M2'de. | Her içerik HDR tepe parlaklığında: güneş altında, parlak odada canlı ve parlak görüntü | 5 | 4 | EDR API'leri iOS 16'dan beri iOS'ta var (CAMetalLayer + `wantsExtendedDynamicRangeContent`, `currentEDRHeadroom`) **[doğrulandı]**. Sınırlar fiziksel: ABL (tam beyaz ekranda 1200 nit sürdürülemeyebilir), termal kısma, Düşük Güç Modu **[ölçülmeli]**. | Metal, QuartzCore (CAMetalLayer), UIKit (EDR headroom), VideoToolbox, Core Video |

### 3.B Ses kalitesi (lossless, uzamsal ses, DAC, EQ)

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| A1 | Rotaya göre ses profilleri | Hoparlör, AirPods, BT, USB DAC ve AirPlay için zincir otomatik kurulur. DAC'ta bit-perfect, AirPods'ta head tracking'li uzamsal ses, hoparlörde Atmos sanallaştırma ve loudness. BT gecikmesi dudak senkronu için telafi edilir. | Hiç ayar yapmadan doğru ses | 4 | 4 | `AVAudioSession` rota bilgisi, `renderingMode`, `supportedOutputChannelLayouts` ve `outputLatency` mevcut **[doğrulandı]**. | AVFAudio, AVFoundation |
| A2 | Bit-perfect DAC zinciri ve görünür sinyal yolu | DAC örnekleme hızı dosyaya göre değişir. Dijital ses seviyesi ve DSP bypass edilir. "Dosya → çözücü → DAC" zinciri ekranda gösterilir. Lightning–USB 3 Kamera Adaptörü takılınca DAC profiline geçilir. | Audiophile güveni | 4 | 3 | `setPreferredSampleRate`'in DAC'ta ve iOS mikserinde nasıl davrandığı **[doğrulanmalı]**. Lightning USB 2.0 üzerinden güç sorunu olabilir. | AVFAudio, Core Audio, AudioToolbox |
| A3 | Native Atmos geçişi (E-AC-3 JOC) | MKV'deki E-AC-3 JOC paketleri çözülmeden Apple'ın Dolby çözücüsüne verilir. AirPods'ta ve hoparlörde gerçek Atmos duyulur. | Streaming servislerindeki Atmos deneyimi yerel dosyada | 5 | 3 | AVSampleBufferAudioRenderer'ın sıkıştırılmış `ec-3` akışını kabul edip JOC'u render ettiği **[doğrulanmalı]**. | AVFoundation (AVSampleBufferAudioRenderer, RenderSynchronizer), Core Media |
| A4 | Kayıpsız çok kanalın uzamsal sese aktarılması | TrueHD, DTS-HD MA, LPCM ve çok kanallı FLAC 7.1 PCM'e çözülür ve head tracking'li sistem uzamsallaştırmasına verilir. | Kulaklıkta sinema | 4 | 4 | FFmpeg çözme + çok kanallı PCM. Sistem uzamsallaştırması `allowedAudioSpatializationFormats` ile açılıyor. Atmos ve DTS:X nesneleri kaybolur; yalnızca yatak kanalları kalır. Lisans riski var (ajan 2). | AVFoundation, AVFAudio; FFmpeg (boşluk) |
| A5 | Diyalog netleştirme ve gece modu | Çok kanallı içerikte merkez kanal yükseltilir. Stereoda ML ses izolasyonu (AUSoundIsolation) kullanılır. Gece modu diyaloğu koruyan dinamik sıkıştırma uygular. | "Fısıltı sonra patlama" sorunu biter | 5 | 3 | Merkez kanal kısmı F5. AUSoundIsolation iOS 16'dan beri var **[doğrulandı]**, ama oynatma zincirinde kullanımı ve gecikmesi **[doğrulanmalı]**. | AVFAudio (AVAudioEngine), AudioToolbox (AUSoundIsolation, AUDynamicsProcessor), Accelerate |
| A6 | Kulaklık EQ'su ve crossfeed | Kulaklık modeli seçilince AutoEQ hedef eğrisi parametrik EQ olarak uygulanır. bs2b tarzı crossfeed eklenir. | Ucuz kulaklıkta bile nötr ses | 3 | 5 | AVAudioUnitEQ ya da vDSP biquad. Veri setinin lisansı **[doğrulanmalı]**. | AVFAudio, Accelerate |
| A7 | Akıllı loudness | ReplayGain etiketi yoksa EBU R128 ölçülür. Music Understanding mevcutsa LUFS oradan alınır. Albüm modunda albüm kazancı kullanılır. | Parçalar arasında ses zıplamaz | 3 | 4 | R128'i vDSP ile kendimiz hesaplayabiliriz. Music Understanding'in A13'te çalışması **[doğrulanmalı]**. | Music Understanding, Accelerate |
| A8 | Müzikal geçişler | Çalma listesinde BPM, ton ve yapı analizine göre beat'e hizalı crossfade yapılır. Albüm modunda kapalıdır; orada gapless çalınır. | DJ hissi | 4 | 3 | Music Understanding'in A13 desteği ve analiz süresi **[doğrulanmalı]**. Analiz önceden, ön planda yapılır. | Music Understanding, AVFAudio |
| A9 | DSD desteği | DSF ve DFF, DAC destekliyorsa DoP ile gönderilir; desteklemiyorsa kaliteli PCM'e dönüştürülür. | DSD arşivi çalınabilir | 3 | 2 | iOS'un DoP işaretçilerini bozmadan geçirmesi, yani bit-perfect ve doğru hız, **[doğrulanmalı]**. | Core Audio, Accelerate |
| A10 | Taptic subwoofer | LFE ve bas bandı Core Haptics'e çevrilir; patlamada titreşim avuçta hissedilir. | Hoparlörde sinema hissi | 5 | 4 | Core Haptics A13'te tam destekli. Ses ve haptiğin senkronu ile pil etkisi **[doğrulanmalı]**. Varsayılan olarak kapalı. | Core Haptics, Accelerate |
| A11 | Sahte hi-res dedektörü | Spektral analizle "24/96 görünen ama aslında 16/44 upsample" ya da lossy kaynaktan üretilmiş FLAC tespit edilir. | Kütüphaneye güven | 4 | 4 | vDSP FFT ile çevrimdışı, tek seferlik analiz. | Accelerate |

### 3.C Cihaz içi AI (Core ML/ANE, Vision, Sound Analysis, Speech, Translation)

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| I1 | PGS/VobSub OCR | Görüntü tabanlı altyazılar cihazda metne çevrilir. Böylece yeniden stillendirilebilir, boyutlandırılabilir, siyah banda taşınabilir ve aranabilir hale gelir. | Blu-ray altyazısı artık "metin" | 5 | 4 | Temiz arka plan üzerinde render edilmiş font olduğu için OCR kolay. Vision'ın Türkçe tanıma desteği **[doğrulanmalı]**; yedek plan Latin tanıma + sözlükle düzeltme. | Vision, Natural Language |
| I2 | Yerel altyazı üretimi | Altyazısı olmayan içerikte konuşmadan altyazı üretilir; ön planda ya da şarjdayken toplu iş olarak. | Erişilebilirlik ve yabancı dil | 4 | 2 | SpeechTranscriber A13'te yok (forum). DictationTranscriber eski cihazlarla uyumlu, ama dil ve kalite **[doğrulanmalı]**. Whisper'ın Core ML ile 8 çekirdekli ANE'deki hızı **[doğrulanmalı]**. | Speech (DictationTranscriber, AssetInputSequenceProvider), Core ML |
| I3 | Çevrimdışı altyazı çevirisi | Mevcut SRT ve ASS altyazılar ile OCR çıktısı Türkçe'ye çevrilir. İsteğe bağlı çift dilli gösterim. | Türkçe altyazısı olmayan film izlenebilir | 4 | 4 | Translation framework cihazda çalışıyor **[doğrulandı]**. A13'te strateji muhtemelen `lowLatency` **[doğrulanmalı]**. Çeviri önceden, toplu olarak yapılır. | Translation, Natural Language |
| I4 | İntro ve jenerik atlama | Bölümler arası ses parmak izi, jenerikteki metin yoğunluğu ve müzik sınıflandırması birleştirilerek intro ve outro işaretlenir. | Dizi maratonu | 4 | 4 | Accelerate ile kromagram parmak izi, Sound Analysis ile müzik/konuşma ayrımı. Analiz ön planda yapılır. | Accelerate, Sound Analysis, Vision |
| I5 | Sahne arama ("kumsalda gün batımı") | Anahtar kareler MobileCLIP ile vektörlenir; metin sorgusuyla ilgili zamana atlanır. | "O sahne neredeydi?" | 5 | 3 | MobileCLIP-S0 küçük ve ANE'ye uygun **[doğrulanmalı]**. 2 saatlik filmde yaklaşık 3.600 kare indekslenir. Arka planda ANE kısıtı var. | Core ML / Core AI, Vision, Natural Language |
| I6 | Akıllı kapak ve bölüm küçük resimleri | Poster yoksa en estetik, yüz içeren ve spoiler vermeyen kare seçilir. | Kütüphane güzel görünür | 3 | 5 | `CalculateImageAestheticsScoresRequest` iOS 18'den beri var **[doğrulandı]**. A13 performansı **[doğrulanmalı]**. | Vision |
| I7 | Otomatik altyazı senkron düzeltme | Konuşma etkinliği (VAD) ile altyazı başlangıçları hizalanır. Sabit kayma ve FPS farkı (23.976/25) otomatik düzeltilir. | "Altyazı kaymış" derdi biter | 5 | 4 | Sound Analysis'in `speech` sınıfı ya da enerji tabanlı VAD ile çapraz korelasyon. | Sound Analysis, Accelerate |
| I8 | Sese göre gece koruması | Sound Analysis ani yüksek olayı (patlama, silah) önceden fark eder ve limiter devreye girer. "Bebek uyuyor" modu. | Gece rahat izleme | 3 | 4 | Lookahead tamponu ile yapılabilir. | Sound Analysis, AVFAudio |
| I9 | Doğal dille kütüphane araması | "90'larda geçen uzay filmi, DV" gibi Türkçe bir sorgu anlamsal olarak eşleştirilir. | Büyük arşivde hızlı bulma | 4 | 3 | LLM yok; kural + `NLContextualEmbedding` hibrit yaklaşımı. Türkçe kalitesi **[doğrulanmalı]**. | Natural Language, Core Spotlight |
| I10 | Görselleştirici ve akıllı karıştırma | Enerji, ton ve tempoya göre ruh hali tabanlı karıştırma. Enstrüman aktivitesine tepki veren görselleştirici. | Müzikte keşif | 3 | 3 | Music Understanding'in A13 desteği **[doğrulanmalı]**. Görsel taraf Metal ile yapılır. | Music Understanding, Metal |
| I11 | Bakışa göre duraklatma | Kullanıcı ekrana bakmayı bırakınca ya da telefonu bırakınca oynatma duraklar (TrueDepth). | Hiçbir sahne kaçmaz | 4 | 3 | ARKit yüz takibi pil tüketir ve kamera göstergesini yakar. İsteğe bağlı. | ARKit, Vision |
| I12 | "Kim bu?" (X-Ray benzeri) | Duraklatınca ekrandaki yüzler TMDB oyuncu listesiyle eşleştirilir. | Oyuncu bilgisi | 5 | 2 | Vision'da kimlik tanıma API'si yok; ayrı bir yüz embedding modeli gerekir. Gizlilik ve doğruluk riski var. | Vision, Core ML |
| I13 | Yerel küçük LLM ile özet | "Önceki bölümde ne oldu?" sorusuna altyazı metninden özet. | Diziyi hatırlatır | 4 | 1 | Apple Intelligence yok. Qwen 0.6B'nin Core AI ile 4 GB RAM'de çalışması **[doğrulanmalı]**; kalite düşük olur. | Core AI, Foundation Models (`LanguageModel` protokolü) |

### 3.D Basitlik ve sıfır ayar

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| S1 | Akıllı parça seçimi | Ses için rotaya en uygun parça seçilir (lossless lossy'den önce gelir, kanal sayısına bakılır) ve dil tercihi uygulanır. Forced altyazı otomatik açılır, yorum parçaları atlanır. | Oynat'a basarsın, gerisi doğru gelir | 3 | 5 | Kural motoru. | AVFoundation, Foundation |
| S2 | Format teşhis kartı | "Ne oynuyor?" sorusunun cevabı: konteyner, codec, HDR/DV profili, ses formatı, donanım mı yazılım mı çözüyor, düşürme olduysa nedeni. | Uzman için şeffaflık | 4 | 5 | Veri zaten kendi hattımızda var. | SwiftUI |
| S3 | Disk sezgisi (ISO/BDMV) | Ana film MPLS ve seamless branching üzerinden otomatik bulunur ve menüye uğramadan başlatılır. Bölümler işaretlenir. | Remux kadar kolay | 4 | 3 | MPLS/CLPI ayrıştırma ve ISO içinde UDF okuma gerekir. Yalnızca şifresiz kaynaklar desteklenir. | Foundation; özel ayrıştırıcı |
| S4 | Kaynak keşfi | Bonjour ile SMB, Jellyfin ve Plex sunucuları bulunur; tek dokunuşla bağlanılır. | Kurulum gerekmez | 3 | 4 | Bonjour (NWBrowser) olağan şekilde çalışır. SSDP/DLNA çok noktaya yayın entitlement'ı (Apple onayı) gerektirir **[doğrulanmalı]**. | Network, Foundation |
| S5 | Katmanlı arayüz | Basit görünümün altında bir "Uzman" katmanı: dosya bazında ayar geçersiz kılma, ton eşleme eğrisi, ses gecikmesi, çözücü seçimi. | Herkese uyar | 3 | 5 | Arayüz işi. | SwiftUI, UIKit |
| S6 | Kaldığın yer ve bağlam | Devam ederken birkaç saniye geri sarılır ve önceki sahnenin mini önizlemesi gösterilir. İlerleme iCloud ile senkronlanır. | İzlemede kopukluk olmaz | 3 | 5 | CloudKit ya da KVS. | CloudKit, AVFoundation |
| S7 | Sistem entegrasyonu | Now Playing framework, PiP, Kısayollar/App Intents ve Spotlight. | Uygulama iOS'un bir parçası gibi hissettirir | 3 | 4 | PiP, AVSampleBufferDisplayLayer ile destekleniyor. Now Playing yeni framework. | Now Playing, AVKit, App Intents, Core Spotlight |

### 3.E Kütüphane ve keşif

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| L1 | Otomatik meta veri | Dosya ve klasör adından film, dizi ya da albüm eşleştirilir (TMDB, MusicBrainz). Çevrimdışı önbellek tutulur. | Güzel kütüphane | 2 | 5 | Standart iş. | Foundation, SwiftData |
| L2 | Kalite rafı | DV, Atmos, Hi-Res ve Remux rozetleri. "Bu gece için demo içerik" önerisi. | Ekipmanını gösterme keyfi | 4 | 5 | Teşhis verisi (S2) kullanılır. | SwiftUI |
| L3 | Audiophile albüm modu | Gapless çalma, çoklu disk, klasik müzik için eser/hareket yapısı, kitapçık PDF'i. | Müzik arşivine saygı | 3 | 4 | Etiket ayrıştırma. | AVFoundation, PDFKit |
| L4 | İzleme durumu senkronu | Trakt, Jellyfin ve Plex izlenme durumu senkronlanır. | Ekosistemle uyum | 2 | 4 | REST API'leri. | Foundation |
| L5 | Akıllı önbellek ve indirme | NAS'tan sıradaki bölümler Wi-Fi ve şarj varken cihaza indirilir. | Uçakta ve yolda izleme | 3 | 4 | BGProcessingTask ve URLSession background. | BackgroundTasks, Foundation |
| L6 | Sahne yer imleri ve klip | Sahneye yer imi konur; kısa bir HDR klip dışa aktarılır. | Paylaşma | 3 | 3 | Remux kesme yapılır. HDR/DV meta verisinin korunması **[doğrulanmalı]**. | AVFoundation |

### 3.F iPhone 11 Pro'ya özgü avantajlar

| # | Fikir | Açıklama | Kullanıcı değeri | W | F | Fizibilite gerekçesi | Framework'ler |
|---|---|---|---|---|---|---|---|
| P1 | OLED'e özgü sinema | Letterbox ve pillarbox bantlarında pikseller kapalı kalır (gerçek #000). Arayüz siyah öncelikli tasarlanır. Altyazı alttaki siyah banda taşınır. | Sonsuz kontrast; görüntünün üstünde yazı olmaz | 5 | 5 | Yalnızca render işi. 2.39:1'de üst-alt bant, 16:9'da yan bantlar oluşur. | Metal, SwiftUI |
| P2 | OLED yanma koruması (rev. 2: **parlaklığa dokunmaz**) | Yalnızca sabit arayüz öğeleri (kontroller, rozetler, saat) birkaç saniye sonra gizlenir. Kalıcı kalması gerekenler 1–2 px mikro kaydırılır. **Video ve altyazı asla karartılmaz.** Duraklatınca karartma (rev. 1) kaldırıldı. | Ekran ömrü uzar, parlaklıktan taviz verilmez | 2 | 5 | — | UIKit, SwiftUI |
| P3 | 458 ppi tipografi | ASS ve SRT ekran çözünürlüğünde vektör olarak render edilir. PGS kaliteli ölçeklenir. Font kalınlığı ayarlanabilir. | Baskı kalitesinde altyazı | 3 | 4 | libass (boşluk) ya da Core Text. | Core Text, Metal |
| P4 | Mesafeye göre altyazı | TrueDepth ile göz-ekran mesafesi ölçülür; altyazı boyutu ve keskinleştirme buna göre ayarlanır. | Yatakta ve uzaktan okunur | 4 | 3 | ARKit pil tüketir ve gizlilik sorusu doğurur; isteğe bağlı. | ARKit |
| P5 | Ortam ışığına uyum | Ön kameradan ışık tahmini yapılır; karanlık odada siyah seviyesi ve ton eşleme buna göre ayarlanır. | Karanlıkta göz yorulmaz | 4 | 2 | Kamerayı açık tutmak pil ve gizlilik maliyeti getirir. Doğruluk belirsiz. | ARKit, AVFoundation |
| P6 | Pil tahmini | "Bu film %X pille biter." Tahmin codec, HDR ve çözme maliyetine göre yapılır. | İzlemeyi planlama | 4 | 4 | Ölçüme dayalı basit bir model. | UIKit (pil), MetricKit |

### 3.G Öne çıkanlar (W × F ≥ 16)

| Sıra | # | Fikir | W×F |
|---|---|---|---|
| 1 | P1 | OLED'e özgü sinema ve altyazının siyah banda taşınması | 25 |
| 2 | I1 | PGS OCR | 20 |
| 2 | I7 | Otomatik altyazı senkronu | 20 |
| 2 | A10 | Taptic subwoofer | 20 |
| 2 | S2 | Format teşhis kartı | 20 |
| 2 | L2 | Kalite rafı | 20 |
| 7 | A1 | Rotaya göre ses profilleri | 16 |
| 7 | A4 | Kayıpsız çok kanalın uzamsal sese aktarılması | 16 |
| 7 | I3 | Çevrimdışı çeviri | 16 |
| 7 | I4 | İntro/jenerik atlama | 16 |
| 7 | A11 | Sahte hi-res dedektörü | 16 |

Not: V2 (DV P7) ve A3 (native Atmos) W×F'de 15 alıyor. Yine de MVP'deler, çünkü ürünün farklılaştırıcı vaadi doğrudan bunlara dayanıyor.

Rev. 2: V12 (Nit Çekirdeği, W×F = 20) kullanıcı kararıyla 1 numaralı özellik. I1, I3 ve I7 kullanıcı kararıyla kapsam dışı (bkz. bölüm 4).

---

## 4. Eleme listesi (cazip ama bu cihazda gerçekçi değil)

| Fikir | Neden elendi | Ne zaman tekrar bakılır |
|---|---|---|
| Apple Intelligence / `SystemLanguageModel` ile özet, sohbet asistanı, akıllı öneri | A17 Pro+ gerekiyor. A13 iOS 27'de temel katmanda. | Cihaz değişirse |
| iOS 27'nin oluşturulan altyazıları (sistem özelliği) | Başlangıçta yalnızca İngilizce ve ABD/Kanada. İkincil kaynak iPhone 15 Pro+ diyor **[doğrulanmalı]**. Ayrıca yalnızca AVPlayer yolunda çalışıyor. | Apple cihaz listesini genişletirse |
| SpeechTranscriber (iOS 26) | A13'te `isAvailable = false` (forum, SE 2 testi) **[doğrulanmalı]**. | — (yerine DictationTranscriber ya da Whisper) |
| 120 Hz ProMotion ve değişken yenileme hızı (24p için 48/72 Hz) | Ekran 60 Hz'de sabit. | — |
| Gerçek zamanlı 4K AI upscale | Ekran 1125p olduğu için anlamsız. A13 gücü de yetmez. | — |
| Metal 4, Metal tensors, neural rendering | iPhone 12 (A14) ve sonrasını istiyor. | — |
| Core AI'da AOT derleme | Yalnızca A17 Pro+ / M1+. A13'te model ilk yüklemede cihazda specialize edilir. | — |
| DV P7 FEL'in tam çift katmanlı çözümü | Apple VideoToolbox'ın P7 desteğini açmıyor. 4K'da yazılımla EL çözüp birleştirmek A13'te gerçek zamanlı yapılamaz. | — (yerine V2: P8.1'e dönüştürme) |
| TrueHD Atmos ve DTS:X nesne render'ı | Lisanslı nesne çözücüsü yok. FFmpeg yalnızca yatak kanallarını (7.1) veriyor. | — (yerine A3: E-AC-3 JOC native) |
| AV1 4K HDR'nin yazılımla çözülmesi | A13'te AV1 donanım çözücüsü yok. dav1d ile 4K 10-bit yazılım çözme gerçek zamanlıya çok yakın ya da onun altında kalır ve pili tüketir **[doğrulanmalı]**. | 1080p AV1 MVP'de tutuluyor |
| LDAC, aptX ve kayıpsız Bluetooth | Ne donanım ne de iOS destekliyor; yalnızca AAC var. | — |
| HDMI bitstream passthrough (Atmos/DTS'nin AV alıcısına gönderilmesi) | Lightning Digital AV Adapter bitstream geçişi yapmıyor **[doğrulanmalı]**. | — |
| Sistem çapında MKV eklentisi (MediaExtension) | Yalnızca macOS'ta var. | Apple iOS'a getirirse |
| Üçüncü parti yayın protokolü eklentisi (Media Device Extension) | Yönetilen entitlement istiyor ve kapsayıcı uygulamanın tek amacı bu olmalı. | — (AVSystemRouting ile tüketici olmak v2'de) |
| Arka planda sürekli ANE ile indeksleme | iOS 27'de yeni entitlement gerekiyor ve ücretli hesapla alınabilirliği belirsiz. | Entitlement doğrulanırsa (Ajan 2, AS-15) |
| Blu-ray menüleri (BD-J) ve AACS/BD+ | Java runtime gerektiriyor; kapsam ve risk çok büyük. **DRM aşma kesinlikle yok.** Yalnızca şifresi çözülmüş kendi rip'ler desteklenir. | — |
| True Tone, Night Shift ve parlaklığın programatik kontrolü | Public API yok (parlaklık dışında). | — (yerine kullanıcıya rehber gösterilir) |
| TrollStore veya private entitlement'lar (`no-sandbox`, `platform-application`) | iOS 27'de mümkün değil (brief). | — |
| PGS OCR (I1), çevrimdışı çeviri (I3), otomatik altyazı senkronu (I7) | **Kullanıcı kararı (rev. 2):** Altyazılar videoyla birlikte gömülü geliyor; bu özellikler gereksiz. | Kullanıcı isterse |

---

## 5. MVP seçimi

### 5.1 MVP: çekirdek deneyim (10 özellik)

| # | MVP özelliği | Kapsam (dahil) | Kapsam dışı | Fikir ID'leri | Kullanıcı açısından başarı ölçütü |
|---|---|---|---|---|---|
| M1 | **Evrensel oynatma çekirdeği** | MKV, MP4, M2TS, ISO ve BDMV (ana film tespiti). HEVC ve H.264 donanımla; AV1 (≤1080p), VC-1 ve MPEG-2 yazılımla çözülür. 3:2 kadans, temel deinterlace, PiP ve arka planda ses. | Menüler, 3D/MVC | V1, S3, V8 (yalnızca kadans), V11 | Kendi UHD remux arşivinin %95'i ilk denemede ve takılmadan oynar. |
| M2 | **Nit Çekirdeği: tipik beyaz yaklaşık 1200 nit (EN ÖNCELİKLİ)** | Aşağıdaki "M2 ayrıntısı" bölümüne bakın. SDR ve HDR'da beyaz panelin tepe parlaklığına çıkar. Varsayılan mod "Nit"; isteyene "Referans" modu (Apple'ın native HDR/DV yolu, disk neyse o) sunulur. Kontroller SDR'da kalır, gözü almaz. **Temiz Nit (N1, rev. 4)** bu hattın parçasıdır: 8-bit kaynakta, yalnızca nihai parlaklıkta görünür olacak bantlar giderilir (bkz. `01b-ek-fikirler.md` §2). | Parlaklık ve beyaz noktanın kullanıcı tarafından değiştirilmesi (sistem ayarı) **Sahne bazlı referans beyaz (rev. 5):** HDR'da `L_ref` sabit 203 nit değildir. Sahne bazında DV L1 meta verisinden ya da HDR10 histogramından tespit edilir; böylece her filmde beyaz hedefte (≈ 0,95 H) kalır. | V12, V5, P1, N1, V3 (yalnızca `L_ref`) | Aynı SDR film, Apple TV uygulamasındaki SDR'dan belirgin şekilde parlak görünür. Beyaz yamada ölçülen değer panel tepe değerine yakındır. 2 saatte kare kaybı 0. |
| M3 | **HDR ve Dolby Vision çözme** | HDR10, HLG ve DV P5/P8 çözülür ve Nit Çekirdeğine verilir. DV P7 → P8.1 dönüşümü yapılır. Referans modunda native EDR/DV yolu kullanılır. HDR rozeti ve teşhis kartı. | HDR10+ (v1.1) | V1, V2, V5, S2 | P5, P7 ve P8 test dosyaları iki modda da doğru renkle oynar. Referans modunda DV tetiklenir. |
| M4 | **Rotaya göre sinema sesi** | E-AC-3 JOC'un native Atmos'a verilmesi. TrueHD ve DTS-HD MA'nın 7.1'e açılıp uzamsal sese aktarılması. Gece modu. Bluetooth gecikme telafisi. Diyalog netleştirme M9'da. | — | A1, A3, A4 | AirPods'ta Atmos/uzamsal göstergesi yanar. |
| M5 | **Audiophile müzik** | FLAC, ALAC, WAV ve AIFF gapless. Bit-perfect DAC ve örnekleme hızı geçişi, sinyal yolu görünümü. R128/ReplayGain loudness. Temel albüm modu. | DSD, müzikal geçişler | A2, A7, L3 | DAC ekranı dosyanın örnekleme hızını gösterir. Albümler kesintisiz çalar. |
| M6 | **Gömülü altyazı** (rev. 2'de sadeleşti) | MKV içindeki PGS, SRT ve ASS parçaları ekran çözünürlüğünde, doğru zamanlamayla render edilir. Görüntüye yakılmış altyazıda ek iş gerekmez. Altyazı parlaklığı videodan ayrı ayarlanabilir. | OCR, çeviri, otomatik senkron (kapsam dışı) | P3 | Test setindeki tüm gömülü altyazı parçaları doğru konum ve zamanlamayla görünür. |
| M7 | **Kaynaklar ve kütüphane** | Files/yerel, SMB, Jellyfin ve Plex. Bonjour ile keşif. TMDB meta verisi. Kalite rozetleri ve kalite rafı. | DLNA (multicast onayına bağlı), Trakt (v1.1) | S4, L1, L2 | Yeni bir NAS üç dokunuşta kütüphaneye eklenir. |
| M8 | **Sıfır ayar deneyimi** | Akıllı parça seçimi. Kaldığın yerden devam ve iCloud senkronu. OLED arayüzü ve yanma koruması (yalnızca arayüz öğeleri; parlaklık düşürülmez). Oynatma sırasında otomatik kilit kapalı. Now Playing framework. Isıyı gözeten kalite yöneticisi. Katmanlı (basit/uzman) arayüz. | — | S1, S5, S6, S7, P1, P2, V6 | İlk açılışta hiçbir ayara dokunmadan "doğru" oynatma. |
| M9 | **AI diyalog netleştirme** (rev. 3, kullanıcı kararı) | **Stereo ve 2.0 içerik:** AUSoundIsolation (cihaz içi ML ses izolasyonu) ayrılmış sesi üretir. Bu ses orijinalin üzerine ayarlanabilir oranda geri karıştırılır; yani müzik ve efekt silinmez, yalnızca konuşma öne çıkar. **Çok kanallı içerik (5.1/7.1):** Merkez kanal yükseltilir. İsteğe bağlı olarak merkez kanala da izolasyon uygulanıp efekt sızıntısı bastırılır. Tek bir "Diyalog" düğmesi ve 3 kademe vardır. Görüntüyle senkron korunur (gecikme telafisi). | Konuşmanın metne çevrilmesi (I2, v2) | A5 | Seçilmiş 10 "fısıltı sahnesinde" diyalog belirgin şekilde anlaşılır hale gelir. Müzik ve efekt kaybı duyulmaz. Ses ile görüntü arasında kayma 0. CPU/ANE bütçesi AS-12'ye uyar. |
| M10 | **Ses yükseltme (boost)** (rev. 4, kullanıcı kararı: "mutlaka") | %100–%150 arası bir kaydırıcı. %150, yaklaşık +6 dB dijital kazanç demek; bu algısal olarak yaklaşık %50 daha yüksek ses. **Üst sınır kesin.** Kazanç PCM zincirinin sonunda, true-peak limiter'dan önce uygulanır. Bu sayede kırpma ve çatlama olmaz; sessiz kayıtlar gerçekten yükselir. Hoparlör, kulaklık ve BT'de çalışır. Native Atmos ve bit-perfect DAC yollarındaki davranışı ajan 2 belirler (ör. Atmos'ta boost açılınca PCM'e çözme, DAC'ta "bit-perfect değil" göstergesi). **Limiter aç/kapat (kullanıcı isteği, test için):**<br>• Varsayılan açık.<br>• Ses panelinde ve Uzman katmanında bir anahtar var.<br>• Kapalıyken kazanç doğrudan uygulanır ve 0 dBFS üstünde deterministik sert kırpma yapılır.<br>• Kapalıyken kırpma sayacı ve clip LED gösterilir; açıkken anlık kazanç azaltma (dB) gösterilir.<br>• Geçiş oynatma sırasında, tıklama sesi olmadan yapılır. | +6 dB üstü | — | Sessiz bir filmde boost %150'de ses belirgin şekilde yükselir. Limiter açıkken yüksek kayıtlı bir müzikte 0 kırpma olur ve duyulabilir pompalama olmaz. Limiter kapalıyken kırpma sayacı gerçek kırpmayı doğru sayar (AS-37). |

### 5.1.1 M2 ayrıntısı: Nit Çekirdeği

**Amaç:** Kullanıcının isteği şu: SDR'da da HDR'da da tipik beyaz, panelin HDR tepe parlaklığında (iPhone 11 Pro'da yaklaşık 1200 nit) görünsün.

**Hat:**

```
VideoToolbox (HEVC/H.264 donanım çözme) ─► CVPixelBuffer (10/8-bit YCbCr)
   ─► CVMetalTextureCache ─► Nit Çekirdeği (Metal)
        1. YCbCr → RGB (BT.709 / BT.2020, limited/full aralık)
        2. EOTF: SDR → BT.1886 · HDR10/DV → PQ · HLG → HLG + OOTF
        3. Gamut: 709/2020 → Display P3 (doğru dönüşüm, doygunluk şişirmesi yok)
        4. Parlaklık eğrisi (aşağıda)
        5. Ekran çözünürlüğüne ölçekleme (2436×1125)
   ─► CAMetalLayer (RGBA16Float, extendedLinearDisplayP3,
                    wantsExtendedDynamicRangeContent = true)
```

**Temel fikir:** EDR değer uzayında `1.0`, o anki SDR beyazıdır. Panelin tepe noktası ise `1.0 × currentEDRHeadroom` değerine karşılık gelir. Çekirdek beyazı doğrudan headroom'a eşler. Böylece kod nit değerini bilmek zorunda kalmaz ve parlaklık kaydırıcısı nerede olursa olsun beyaz panelin tepesine çıkar.

| İçerik | Eğri |
|---|---|
| **SDR** | `çıkış = lineer_değer × H`. `H = currentEDRHeadroom`, her karede okunur. Tüm görüntü aynı oranda parlar. Kontrast oranı korunur (OLED siyahı 0 kalır). |
| **HDR10 / DV / HLG: "Maksimum" (varsayılan)** | Referans beyaz (yaklaşık 203 nit ya da sahne analizi) `H`'ye eşlenir. Bunun üstündeki vurgular dar bir yumuşak dirsekle sıkıştırılır. Bedeli: beyaz zaten tepedeyse parlak vurgular (güneş, lamba) beyazla aynı seviyeye yaklaşır ve "HDR patlaması" azalır. |
| **HDR: "Dengeli" (seçenek)** | Referans beyaz `H` değerinin yaklaşık %75–80'ine çekilir. Kalan alan vurgulara ayrılır. Daha az parlak, daha "HDR" bir görüntü verir. |
| **DV** | P8.1 ve P7'den dönüşen P8.1'in taban katmanı PQ/BT.2020 olduğu için aynı yoldan geçer. P5 (IPTPQc2) için çekirdeğe reshaping ve matris adımı eklenir. RPU'daki dinamik meta veri ton eğrisini besler. |

**Kurallar:**
- Arayüz (kontroller, rozetler) SDR'da (`1.0`) kalır; yalnızca video ve isteğe bağlı olarak altyazı yükseltilir.
- `currentEDRHeadroom` sistem tarafından düşürülürse (ısı, ortam ışığı) eğri birkaç kare içinde yumuşakça uyum sağlar. Ani parlaklık sıçraması ya da kırpma olmaz.
- "Referans" modu her zaman bir dokunuş uzaklıkta: Apple'ın native HDR/DV yolu, "disk neyse o".

**Uygulamanın aşamayacağı fiziksel sınırlar** (dürüstçe yazılmalı, spike'ta ölçülmeli):
- **ABL (otomatik parlaklık sınırlama):** OLED, ekranın büyük bölümü beyazken tepe parlaklığı sürdüremez. Tipik film sahnelerinde beyaz alanlar 1200 nite yaklaşabilir; tam beyaz bir ekranda değer daha düşük kalır **[ölçülmeli]**.
- **Isı:** Uzun süre tepe parlaklıkta kalmak cihazı ısıtır ve iOS headroom'u kısar. Uygulama bunu engelleyemez; yalnızca yumuşakça uyum sağlar.
- **Düşük Güç Modu** EDR'yi kapatır.
- **Pil ve OLED aşınması** artar. Bu kullanıcının bilinçli tercihi.
- PiP ve AirPlay'de Nit modunun davranışı ayrıca çözülmeli (AS-31).

### 5.2 Yol haritası

**v1.1: Derinlik** (MVP'den sonra)
- **N2 Ses Çekirdeği (ilk iş, rev. 4):** Dinleme seviyesine göre ton düzeltmesi ve isteğe bağlı odyogram katmanı (bkz. `01b-ek-fikirler.md` §3).
- V3 Ekrana göre tam dinamik ton eşleme (sahne bazlı `L_ref` rev. 5'te MVP'ye alındı) · V4 HDR10+
- A6 Kulaklık EQ'su ve crossfeed · A10 Taptic subwoofer
- I4 İntro ve jenerik atlama · I6 Akıllı kapak · A11 Sahte hi-res dedektörü
- V7 Akıllı doldurma · P6 Pil tahmini · L4 Trakt/Jellyfin/Plex senkronu

**v1.2: Müzik zekâsı ve eski arşivler**
- V9 SD/DVD AI ölçekleme (VTFrameProcessor varsa, yoksa Metal) · V11+ gelişmiş deinterlace
- A7+ Music Understanding ile loudness · A8 Müzikal geçişler · I10 Görselleştirici ve akıllı karıştırma
- I8 Gece koruması · L5 Akıllı önbellek · L6 Sahne yer imleri ve klip

**v2: Deneysel ve sınırları zorlayan**
- I5 Sahne arama · I9 Doğal dille arama · I2 Yerel altyazı üretimi
- V8 Akıcı mod (ML ara kare) · V10 Gürültü temizleme · A9 DSD
- I11 Bakışa göre duraklatma · P4 Mesafeye göre altyazı · P5 Ortam ışığına uyum
- AVSystemRouting ile yayın · CarPlay ses (entitlement onayına bağlı) · I12 "Kim bu?" ve I13 yerel LLM (araştırma)

---

## 6. Ajan 2 için açık sorular ve risk hipotezleri

Her soru "şu çalışır mı?" biçiminde yazıldı ve ölçülebilir bir başarı ölçütü taşıyor. Soru kimlikleri `AS-n` biçimindedir; fikir kimlikleriyle (S1, V2…) karışmasın diye böyle seçildi. Önerilen öncelik: AS-1, AS-9, AS-11, AS-14, AS-15 ve AS-21 ilk iki haftadaki spike'larda ele alınmalı.

**Rev. 2:** AS-14, AS-18 ve AS-19 iptal edildi (OCR, çeviri ve otomatik senkron kapsam dışı). Nit Çekirdeği soruları (AS-26–AS-31) **en yüksek öncelikte**.

### 6.0 Nit Çekirdeği (en öncelikli)

| # | Soru | Başarı ölçütü | İlgili |
|---|---|---|---|
| AS-26 | iOS 27'de iPhone 11 Pro'da tam ekran bir CAMetalLayer'a SDR değerleri `× currentEDRHeadroom` ile yazıldığında sistem headroom'u gerçekten veriyor mu? Panel tepe parlaklığına çıkıyor mu? Maksimum, orta ve düşük parlaklık kaydırıcısında `potentialEDRHeadroom` ve `currentEDRHeadroom` değerleri ne? | Headroom kayıtları alınır. Beyaz yama, Apple'ın kendi HDR test videosundaki tepe beyazıyla yan yana aynı parlaklıkta görünür (ışıkölçer varsa nit cinsinden ölçülür). | M2 |
| AS-27 | ABL: Ekranın %10, %25, %50 ve %100'ünü kaplayan beyaz yamalarda gerçek parlaklık ne? Tipik film sahnesinde beyazlar ≥ 1000 nit mi? | Işıkölçer ya da lüksmetreyle bağıl ölçüm tablosu. | M2 |
| AS-28 | Nit modunda 2 saatlik oynatmada `currentEDRHeadroom` ve `thermalState` nasıl değişiyor? Pil tüketimi Referans moduna göre ne kadar fazla? | Dakika dakika kayıt. Headroom düşüşünde görünür sıçrama 0. Pil farkı raporlanır. | M2, M8 |
| AS-29 | Çekirdeğin maliyeti: 4K HEVC 10-bit kare → 2436×1125 RGBA16F (renk, EOTF, gamut, eğri ve ölçekleme) A13 GPU'da **< 3 ms/kare** sürer mi? | Instruments GPU ölçümü. 60 Hz'de kare kaybı 0. | M2, M1 |
| AS-30 | DV P5 (IPTPQc2 reshaping) ve P8.1 RPU'su Metal çekirdeğinde Referans moduyla **renk olarak eşleşiyor** mu (parlaklık farkı hariç)? | ΔE karşılaştırması ya da yan yana görsel test. Yeşil/mor renk kayması 0. | M2, M3 |
| AS-31 | Nit modunda PiP (AVSampleBufferDisplayLayer ister), AirPlay ve ekran kaydı nasıl davranır? Gerekirse bu durumlarda Referans moduna geçilir mi? | Her senaryo için tanımlı ve sorunsuz davranış. | M2, M8 |

### 6.1 Video

| # | Soru | Başarı ölçütü | İlgili |
|---|---|---|---|
| AS-1 | MKV'den demux edilen DV P8.1 HEVC örnekleri, dvcC'li `CMFormatDescription` ile beslendiğinde, iPhone 11 Pro'da AVSampleBufferDisplayLayer (ya da iOS 27 `Receiver`) üzerinden **gerçek Dolby Vision modunu** tetikler mi? | Aynı içeriğin MP4 remux'u AVPlayer'da nasıl görünüyorsa onunla birebir aynı görünür (yan yana ekran ölçümü). DV moduna geçiş doğrulanabilir. | V1, M3 |
| AS-2 | P7'nin (MEL ve FEL) RPU'sunu P8.1'e çevirme işi 4K24 içerikte **kare başına < 2 ms CPU** ile gerçek zamanlı yapılabilir mi? | 2 saatlik bir filmde kare kaybı 0. Sonuç AS-1 kriterini karşılar. | V2 |
| AS-3 | 4K HEVC Main10 remux (ortalama 60–80 Mbps, tepe noktası > 100 Mbps), SMB üzerinden Wi-Fi 6 ile kesintisiz akar mı? | 2 saatte 0 takılma. Sarma (seek) sonrası < 1,5 sn'de oynatma. | M1, M7 |
| AS-4 | Ekran çözünürlüğüne indirgenmiş karede (2436×1125) Metal ile dinamik ton eşleme yapmak **< 4 ms/kare** sürer ve pile etkisi < %10 olur mu? | Instruments ölçümü; 1 saatlik pil farkı. | V3 |
| AS-5 | 23.976 fps içerik 60 Hz'de 3:2 kadansla gösterildiğinde **kare zamanlama jitter'ı < 1 ms** olur mu? 59.94 ile 60 arasındaki sapma nasıl yönetilir? | 10 dakikalık kaydırma testinde kadans hatası 0. | V8, M1 |
| AS-6 | `VTLowLatencySuperResolutionScalerConfiguration.isSupported` A13'te true döner mi? 720×480 → 1440×960 dönüşümü **< 16 ms/kare** sürer mi? | Çalışma anında doğrulama ve gecikme ölçümü. | V9 |
| AS-7 | AV1 1080p 10-bit içerik dav1d ile A13'te **≥ 30 fps** çözülür mü? 2 saatlik pil tüketimi nedir? | Kare kaybı 0. Pil tüketimi < %35 / 2 saat. | M1 |
| AS-8 | ISO/BDMV'de ana playlist tespiti seamless branching'li diskler dahil **%95 doğrulukla** yapılabilir mi? | 20 diskten oluşan bir test setinde ≥ 19 doğru sonuç. | S3 |

### 6.2 Ses

| # | Soru | Başarı ölçütü | İlgili |
|---|---|---|---|
| AS-9 | MKV'den gelen sıkıştırılmış E-AC-3 JOC örnekleri AVSampleBufferAudioRenderer'a verildiğinde AirPods Pro'da **Dolby Atmos olarak uzamsal render** edilir mi? | Denetim Merkezi'nde Atmos/uzamsal göstergesi yanar. Aynı dosyanın MP4 sürümü AVPlayer'da nasıl duyuluyorsa öyle duyulur. | A3 |
| AS-10 | TrueHD 7.1'i FFmpeg ile PCM'e çözmek **bir P çekirdeğinin < %15'ini** kullanır mı? 7.1 PCM sistem uzamsallaştırmasına head tracking'li gider mi? | Instruments CPU ölçümü. Kulaklıkta kanallar doğru yerleşir (kanal test dosyası). | A4 |
| AS-11 | USB DAC'ta `setPreferredSampleRate` 44.1, 48, 96 ve 192 kHz geçişlerini **gerçekten DAC'a yansıtır** mı? Sinyal yolu bit-perfect mi? | DAC ekranında doğru hız görünür. Bit-perfect test dosyası (ör. HDCD/MQA işaretli dosya ya da loopback karşılaştırması) bit eşitliği verir. | A2 |
| AS-12 | **(rev. 3: MVP, yüksek öncelik)** AUSoundIsolation bir **oynatma** zincirinde (mikrofonda değil) A13'te gerçek zamanlı çalışır mı? Gecikmesi < 50 ms, CPU kullanımı < %20 olur mu? Hangi örnekleme hızı ve kanal düzenlerini kabul ediyor? Arka planda ve kilit ekranında da çalışıyor mu? | AVAudioEngine prototipi; ölçüm. Toplam gecikme video tarafında telafi edilir. | A5, M9 |
| AS-13 | Ses çalarken ve uygulama arka plandayken PCM işleme zinciri (EQ, loudness, crossfeed) **sesi kesmeden** çalışır mı? Gerçek zamanlı ses thread'i bütçesi aşılır mı? | 1 saatte 0 glitch, kilit ekranında. | A1, A6, A7 |

### 6.3 AI

| # | Soru | Başarı ölçütü | İlgili |
|---|---|---|---|
| AS-14 | **[İPTAL, rev. 2]** Vision OCR, PGS altyazıda **karakter doğruluğu ≥ %98** verir mi (İngilizce ve Türkçe)? Türkçe karakterler (ı, ğ, ş, İ) doğru okunur mu? | Elle doğrulanmış 500 satırlık set. 2 saatlik bir filmin OCR'ı < 2 dk sürer. | I1 |
| AS-15 | `com.apple.developer.background-tasks.continued-processing.inference` entitlement'ı ücretli geliştirici hesabıyla development profile'a **eklenebilir** mi? A13'te arka plan ANE kısıtı uygulanıyor mu? | Profilde entitlement görünür. Arka planda Core ML ANE çağrısı başarılı olur ya da belgelenmiş bir hata verir. | Kural 2.3/2 |
| AS-16 | Core AI A13'te **çalışıyor mu**? Küçük bir modelin (< 50 MB) ilk specialization süresi < 30 sn mi? ANE kullanılıyor mu? | `ComputeUnitKind.availableKinds` içinde `neuralEngine` var. Instruments'ta Core AI izi görünür. | Kural 2.3/1 |
| AS-17 | Music Understanding A13'te çalışır mı? 4 dakikalık bir parçanın analizi **< 10 sn** sürer mi? | `analyze(for: [.loudness, .rhythm])` süresi ölçülür. | A7, A8 |
| AS-18 | **[İPTAL, rev. 2]** Translation EN→TR, A13'te çevrimdışı olarak **satır başına < 300 ms** ile çalışır mı? 1.500 satırlık bir altyazının toplu çevirisi < 3 dk sürer mi? | `translate(batch:)` ölçümü ve okunabilirlik değerlendirmesi. | I3 |
| AS-19 | **[İPTAL, rev. 2]** Sound Analysis (`speech` sınıfı) ya da VAD ile altyazı senkronu **±100 ms** doğrulukla otomatik hizalanabilir mi? | Bilinen kayması olan 10 SRT dosyasının ≥ 9'u düzelir. | I7 |
| AS-20 | DictationTranscriber A13'te Türkçe (tr-TR) ve İngilizce için **çevrimdışı** çalışır mı? Kelime hata oranı (WER) < %15 olur mu? | Çevrimdışı mod ve WER ölçümü. Whisper (Core ML) karşılaştırması. | I2 |

### 6.4 Platform ve derleme

| # | Soru | Başarı ölçütü | İlgili |
|---|---|---|---|
| AS-21 | `increased-memory-limit` ile iPhone 11 Pro'da kullanılabilir bellek ne olur (`os_proc_available_memory`)? 4K demux tamponu, Nit Çekirdeği dokuları ve ses zinciri aynı anda sığar mı? | Gerçek limit ölçülür. Tepe kullanım < limitin %70'i. | M1, M2 |
| AS-22 | Özel hatta (AVSampleBufferAudioRenderer) **Now Playing framework** (iOS 27) ile kilit ekranı kontrolleri ve kesinti sonrası `ResumptionRecommendation` sorunsuz çalışır mı? | Arama, alarm ve Siri kesintisi senaryolarının hepsinde doğru davranış. | S7, M8 |
| AS-23 | SMB okuma hızı libsmb2 (ya da benzeri) ile Files/File Provider yolu arasında karşılaştırıldığında **≥ 20 MB/s** mi? | Aynı NAS üzerinde iperf benzeri ölçüm. | M7 |
| AS-24 | GitHub Actions macOS runner'ında FFmpeg (yalnızca LGPL bileşenleri), dav1d ve libass derlemesi **önbellekle < 15 dk** sürer mi? | CI süre ölçümü ve dakika maliyeti tahmini. | Derleme |
| AS-25 | AirPods head tracking'i sistem uzamsallaştırmasıyla kullanılırsa entitlement gerekmez. AUSpatialMixer/PHASE ile özel binaural render yapılırsa `com.apple.developer.coremotion.head-pose` gerekir. Bu entitlement ücretli hesapla alınabilir mi? | Profilde entitlement görünür ya da sistem yolu yeterli bulunur. | A4 |

---

## 7. En riskli varsayımlar

| Sıra | Varsayım | Neden riskli | Çürürse ne olur | Spike |
|---|---|---|---|---|
| **0 (rev. 2)** | **Nit Çekirdeği** iPhone 11 Pro + iOS 27'de SDR ve HDR'da beyazı panel tepesine (yaklaşık 1200 nit) çıkarabilir ve bunu film boyunca termal kısmaya takılmadan, renk doğruluğunu bozmadan sürdürebilir. | EDR API'si belgeli. Ancak gerçek nit değerini ABL, ısı ve sistem politikası belirliyor; bu ölçülmeden bilinemez. | Ürünün 1 numaralı vaadi "mümkün olan en parlak" düzeyine iner. Çekirdek yine çalışır, ama sabit 1200 nit garanti edilemez. | AS-26–AS-29 |
| **1** | MKV'den çıkarılan DV P8.1 ve P7'den dönüştürülmüş P8.1 içerik, iPhone 11 Pro'da özel hatla **gerçek Dolby Vision modunu** tetikler. | Apple bu yolu belgelemiyor. Infuse bile P7'de HDR10'a düşüyor. | Ürün vaadinin "gerçek DV" ayağı zayıflar. HDR10 + dinamik ton eşleme (V3) öne çekilir. | AS-1, AS-2 |
| **2** | iOS 27 ses yığını özel motorda **E-AC-3 JOC'u native Atmos olarak** render eder ve USB DAC'ta **bit-perfect ile örnekleme hızı geçişine** izin verir. | İkisi de belgelenmemiş davranışlara dayanıyor. Rakiplerde de sınırlı. | "Gerçek Atmos" ve "bit-perfect" iddiaları "en iyi çaba" düzeyine iner. | AS-9, AS-11 |
| **3** | A13 ve 4 GB RAM, 4K HDR remux çözme, Nit Çekirdeği ve AI işlerini **termal kısmaya uğramadan** birlikte kaldırır. iOS 27'nin yeni ML API'lerine bel bağlamadan da AI vaadi karşılanır. | Core AI, Music Understanding ve VTFrameProcessor'ın A13 desteği belgelenmemiş. Arka planda ANE kısıtlanmış. SpeechTranscriber yok. | AI özellikleri ön planda, "hazırlık" adımı olarak çalışır. Bazı özellikler v2'ye kayar. | AS-4, AS-15, AS-16, AS-21, AS-28 |

Diğer önemli riskler:
- Dolby, DTS ve FFmpeg lisans riskleri (ajan 2 karar kaydı).
- macOS runner dakika maliyeti (AS-24).
- Çok noktaya yayın entitlement onayı (fikir S4, DLNA).

---

## 8. Kaynaklar

**Apple (birincil)**
- [What's New — iOS (Apple Developer)](https://developer.apple.com/ios/whats-new/)
- [WWDC26 iOS rehberi](https://developer.apple.com/wwdc26/guides/ios/) · [WWDC26 oturum listesi](https://developer.apple.com/videos/wwdc2026/)
- [iOS & iPadOS 27 sürüm notları](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes) (Core AI, arka plan ANE, VideoToolbox, Media Sharing Extensions, AudioAccessoryKit)
- WWDC26 oturumları: [256 Oluşturulan altyazılar ve stiller](https://developer.apple.com/videos/play/wwdc2026/256/) · [253 Music Understanding](https://developer.apple.com/videos/play/wwdc2026/253/) · [312 Now Playing](https://developer.apple.com/videos/play/wwdc2026/312/) · [324 Meet Core AI](https://developer.apple.com/videos/play/wwdc2026/324/) · [326 Core AI entegrasyonu](https://developer.apple.com/videos/play/wwdc2026/326/) · [237 Image understanding](https://developer.apple.com/videos/play/wwdc2026/237/)
- Core AI: [framework](https://developer.apple.com/documentation/coreai) · [AOT derleme (yalnızca A17 Pro+/M1+)](https://developer.apple.com/documentation/coreai/compiling-core-ai-models-ahead-of-time) · [Specialization ve önbellek](https://developer.apple.com/documentation/coreai/managing-model-specialization-and-caching) · [AIModel](https://developer.apple.com/documentation/coreai/aimodel)
- [Background Inference entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.background-tasks.continued-processing.inference)
- [Music Understanding](https://developer.apple.com/documentation/musicunderstanding) · [MusicUnderstandingSession](https://developer.apple.com/documentation/musicunderstanding/musicunderstandingsession)
- [Now Playing framework](https://developer.apple.com/documentation/nowplaying)
- AVFoundation/AVKit/AVFAudio: [AVPlayer.disconnectedFromSystemAudio](https://developer.apple.com/documentation/avfoundation/avplayer/disconnectedfromsystemaudio) · [AVPlayerItem.selectableMediaSelectionOptions(in:)](https://developer.apple.com/documentation/avfoundation/avplayeritem/selectablemediaselectionoptions(in:)) · [AVSampleBufferVideoRenderer.Receiver](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer/receiver) · [AVPlayerLayer.setCaptionPreviewProfileID](https://developer.apple.com/documentation/avfoundation/avplayerlayer/setcaptionpreviewprofileid(_:position:text:)) · [AVDisplayDynamicRange](https://developer.apple.com/documentation/avkit/avdisplaydynamicrange) · [AVAudioSession.ResumptionRecommendation](https://developer.apple.com/documentation/avfaudio/avaudiosession/resumptionrecommendation) · [AVReadOnlyAudioPCMBuffer](https://developer.apple.com/documentation/avfaudio/avreadonlyaudiopcmbuffer)
- VideoToolbox: [VTFrameProcessor](https://developer.apple.com/documentation/videotoolbox/vtframeprocessor) · [VTLowLatencySuperResolutionScalerConfiguration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencysuperresolutionscalerconfiguration) · [VTLowLatencyFrameInterpolationConfiguration](https://developer.apple.com/documentation/videotoolbox/vtlowlatencyframeinterpolationconfiguration)
- Speech: [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) · [AssetInputSequenceProvider](https://developer.apple.com/documentation/speech/assetinputsequenceprovider)
- [TranslationSession.Strategy](https://developer.apple.com/documentation/translation/translationsession/strategy) · [CalculateImageAestheticsScoresRequest](https://developer.apple.com/documentation/vision/calculateimageaestheticsscoresrequest) · [kAudioUnitSubType_AUSoundIsolation](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation) · [UIScreen.potentialEDRHeadroom](https://developer.apple.com/documentation/uikit/uiscreen/potentialedrheadroom) · [CAEDRMetadata](https://developer.apple.com/documentation/quartzcore/caedrmetadata)
- [MediaExtension (yalnızca macOS)](https://developer.apple.com/documentation/mediaextension) · [media-device-extension entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.media-device-extension)
- [Apple cihazlarda Metal desteği (Metal 4: iPhone 12+)](https://support.apple.com/102894)

**Apple geliştirici forumları (ikincil, [doğrulanmalı])**
- [SpeechTranscriber desteklenen cihazlar (A13 / SE 2 desteklenmiyor)](https://developer.apple.com/forums/thread/807739)
- [VTFrameProcessor cihaz desteği — Apple DTS cevabı](https://developer.apple.com/forums/thread/821701) · [LL ara kare ve süper çözünürlük sorusu](https://developer.apple.com/forums/thread/814646)

**Haber ve topluluk kaynakları (ikincil)**
- [MacRumors — iOS 27 iPhone 11 ve sonrasını destekliyor](https://www.macrumors.com/2026/06/08/ios-27-supports-iphone-11-newer/) · [MacRumors — iOS 27 özellik katmanları](https://www.macrumors.com/2026/09/09/which-iphones-support-every-ios-27-feature/) · [Appleosophy — iOS 27 iPhone 11 desteği](https://appleosophy.com/2026/06/08/ios-27-supports-the-iphone-11-series-defying-recent-rumors/)
- [iPhoneSoft — iOS 27 oluşturulan altyazılar](https://iphonesoft.fr/2026/05/20/ios-27-sous-titres-generes-automatiquement-videos) · [iThinkDifferent — iOS 27 altyazılar, cihaz listesi [doğrulanmalı]](https://www.ithinkdiff.com/turn-on-subtitles-captions-iphone-ipad-ios-27/)
- [Firecore — Native Profile 7 FEL isteği (Ağustos 2026)](https://community.firecore.com/t/native-profile-7-fel-playback/60612) · [Firecore — DV Profile 7 & 8 desteği](https://community.firecore.com/t/dolby-vision-profile-7-8-support-ts-mkv-files/19713)
- [AppleInsider — Core AI'ın Core ML yerine gelmesi (WWDC öncesi haber)](https://appleinsider.com/articles/26/03/01/wwdc-2026-to-introduce-core-ai-as-replacement-for-core-ml). Not: Apple'ın belgeleri Core ML'in ağ dışı modeller için sürdüğünü gösteriyor; "Core ML'in yerini aldı" iddiası tam doğru değil.
