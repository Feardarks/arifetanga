// libsmb2 için küçük C yardımcıları (S7): Swift'ten zaman uyumsuz geri çağrı ve DCE/RPC birlikleri yerine
// tek çağrılık, bloklayan arayüzler.
#ifndef SMBShim_h
#define SMBShim_h

#include <stdint.h>
#include <time.h>
#include <fcntl.h>
#include <smb2/smb2.h>
#include <smb2/libsmb2.h>

/// Sunucudaki disk paylaşımlarını listeler (IPC$'a bağlı bağlamda; gizli "$" paylaşımları hariç).
/// Başarıda 0 döner; `*names` "\n" ile ayrılmış adlardır ve `free()` ile bırakılır. Hata: -errno.
int arif_smb2_share_enum(struct smb2_context *smb2, int timeout_ms, char **names);

/// `offset`'ten `count` baytı ardışık düzenle okur: aynı anda en çok `depth` okuma isteği (her biri en çok
/// `piece` bayt ve sunucunun azami okuma boyutu) uçuştadır; tek isteklik gidiş-dönüş beklemesi gizlenir.
/// `timeout_ms` boyunca hiçbir istek tamamlanmazsa vazgeçilir.
/// Dönen: baştan kesintisiz okunan bayt (kısa yanıtta ya da dosya sonunda `count`'tan az) ya da -errno.
/// Hata dönerse bağlam artık kullanılmamalı, `smb2_destroy_context` ile kapatılmalıdır: yarıda kalan istekler
/// tampona yazabilir; yok edilince geri çağrıları iptal durumuyla çalışır ve kendi durumlarını bırakır.
int64_t arif_smb2_pread_pipelined(struct smb2_context *smb2, struct smb2fh *fh, uint8_t *buf, uint64_t count,
                                  uint64_t offset, uint32_t piece, int depth, int timeout_ms);

#endif
