# arifetanga

iPhone 11 Pro (iOS 27) için sideload edilen flagship medya oynatıcı (video + ses). Tüm kısıtlar `docs/00-brief.md` dosyasında.

## Çalışma düzeni

Uygulama, üç aşamada ve her aşamada bir uzman ajanla hazırlanır. Ajan tanımları `.claude/agents/` klasöründe:

1. `fikir-ajani` → `docs/01-konsept.md`
2. `cozum-ajani` → `docs/02-cozum.md`
3. `tasarim-ajani` → `docs/03-tasarim.md`

Her aşamanın sonunda kullanıcı onayı alınır. Sonraki aşama, önceki çıktıları bağlayıcı girdi olarak kullanır. Belgeler Türkçe yazılır.

## Derleme

Mac yok. Derleme GitHub Actions macOS runner'ında yapılır. Proje dosyası XcodeGen/Tuist ile üretilir; `.xcodeproj` elle düzenlenmez.
