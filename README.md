# KafaTakip

Old 3DS'te ön kamerayla kafa takibi ve kafa konumuna göre 3D perspektif
(head-coupled perspective).

## Aşamalar

- [x] **Aşama 1:** Ön kamera 160x120, gri görüntü alt ekranda, FPS ölçümü
- [x] **Aşama 2:** Yüz algılama (pico), yüzün etrafında kutu
- [ ] **Aşama 3:** Kafa konumu (x, y, uzaklık) + One-Euro filtresi
- [ ] **Aşama 4:** Off-axis stereo 3D sahne
- [ ] **Aşama 5:** Gyro füzyonu, kalibrasyon
- [ ] **Aşama 6:** 3GX plugin denemesi

## .3dsx dosyasını alma (kurulum gerektirmez)

Her push'ta GitHub Actions uygulamayı derliyor.

1. GitHub'da repoda **Actions** sekmesine gir.
2. En üstteki yeşil tikli çalıştırmaya tıkla.
3. Sayfanın altındaki **Artifacts** bölümünden `kafatakip` dosyasını indir ve zip'i aç.
4. `kafatakip.3dsx` dosyasını SD kartta `/3ds/` klasörüne koy.
5. 3DS'te Homebrew Launcher'dan **KafaTakip**'i aç.

## Mac'te kendin derlemek (isteğe bağlı)

1. devkitPro kurulum paketini indirip kur: <https://github.com/devkitPro/pacman/releases>
   (macOS için `devkitpro-pacman-installer.pkg`)
2. Terminal'de: `sudo dkp-pacman -S 3ds-dev`
3. `~/.zshrc` dosyasına ekle, sonra Terminal'i yeniden aç:
   ```
   export DEVKITPRO=/opt/devkitpro
   export DEVKITARM=$DEVKITPRO/devkitARM
   ```
4. `cd kafatakip && make`

## Kontroller

| Tuş | İşlev |
|---|---|
| START | Çıkış |
| A | Aynalamayı aç/kapa |
| L / R | Yüz algılama eşiğini azalt / artır |

Üst ekranda kamera FPS'i, gri çevirme ve çizim süreleri (ms) ve ortalama
parlaklık görünür. Kamerayı elinle kapatınca parlaklık 0'a yaklaşmalı.

Yüz bulununca alt ekranda en güvenilir yüz kalın yeşil kutuyla, diğerleri
ince kırmızı kutuyla çizilir. Eşik düşükse yanlış kutular çoğalır, yüksekse
yüz kaçırılır.

## Üçüncü parti

- [pico](https://github.com/nenadmarkus/pico) (MIT, Nenad Markuš):
  `source/picornt.c`, `source/picornt.h` ve `data/facefinder.bin` yüz kaskadı,
  commit `7d550c7`. Lisans: `source/picornt.LICENSE`.
