# KafaTakip

Old 3DS'te ön kamerayla kafa takibi ve kafa konumuna göre 3D perspektif
(head-coupled perspective). Üst ekran, arkasındaki bir kutuya açılan pencere
gibi davranır: kafanı oynatınca kutunun içini farklı açılardan görürsün.

## Nasıl çalışıyor

1. Ön kamera 160x120 görüntü verir, gri tonlamaya çevrilir.
2. [pico](https://github.com/nenadmarkus/pico) yüzü bulur. Yüz bulunduktan
   sonra sadece çevresinde aranır (hızlı); kaybolursa tüm görüntü taranır.
3. Yüz kutusunun boyutu cetvel gibi kullanılarak kafanın ekrana göre konumu
   cm cinsinden hesaplanır, One-Euro filtresiyle titremesi alınır.
4. Gyro füzyonu: konsol dönünce kafanın ekrana göre kayması gyro ile anında
   uygulanır, kamera ölçümleri tahmini düzeltir. Gyro eksenlerinin ekrana
   eşlemesi elle verilmez; kamera hareketiyle karşılaştırılarak öğrenilir
   (konsolu birkaç saniye sağa sola / ileri geri çevirmek yeterli).
5. Her göz için ekran kenarlarından geçen off-axis frustum ile stereo 3D
   sahne çizilir (citro3d).

## Yapılacaklar

- [ ] 3GX plugin denemesi

## .3dsx dosyasını alma (kurulum gerektirmez)

Her push'ta GitHub Actions uygulamayı derliyor.

1. GitHub'da repoda **Actions** sekmesine gir.
2. En üstteki yeşil tikli çalıştırmaya tıkla.
3. Sayfanın altındaki **Artifacts** bölümünden `kafatakip` dosyasını indir ve zip'i aç.
4. `kafatakip.3dsx` dosyasını SD kartta `/3ds/` klasörüne koy
   (ya da ftpd ile: `curl -T kafatakip.3dsx ftp://<3DS-IP>:5000/3ds/`).
5. 3DS'te Homebrew Launcher'dan **KafaTakip**'i aç.

## Kontroller

| Tuş | İşlev |
|---|---|
| A | Şu anki kafa konumunu merkez kabul et |
| B | Merkezi sıfırla |
| X / Y | Yatay / dikey hareket yönünü ters çevir |
| D-pad yukarı/aşağı | Hareket kazancını artır/azalt |
| L / R | Yüz algılama eşiğini azalt/artır |
| SELECT | Gyro füzyonunu aç/kapa |
| Circle pad | Kafayı elle kaydır (takipsiz test) |
| 3D slider | Stereo derinliği |
| START | Çıkış |

Alt ekranda takip durumu, kamera/çizim FPS'i, algılama süresi, kafa konumu
(cm) ve yüzün kameradaki yerini gösteren bir radar var.

## Ayarlanabilir varsayımlar

- `source/head.c`: kamera görüş açısı (60°), yüz genişliği (15 cm), kameranın
  ekran merkezinden yüksekliği (3 cm). Alt ekrandaki Z (uzaklık) gerçek
  uzaklıktan farklıysa görüş açısı düzeltilir.
- `source/scene.h`: ekran boyutu (Old 3DS 7.7 x 4.6 cm; XL için ~10.6 x 6.4).

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

## Üçüncü parti

- [pico](https://github.com/nenadmarkus/pico) (MIT, Nenad Markuš):
  `source/picornt.c`, `source/picornt.h` ve `data/facefinder.bin` yüz kaskadı,
  commit `7d550c7`. Lisans: `source/picornt.LICENSE`.
