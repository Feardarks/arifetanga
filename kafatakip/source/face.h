#pragma once

#include <3ds.h>

// Bulunan bir yüz; koordinatlar kamera görüntüsü pikseli cinsinden.
typedef struct {
	float x;    // merkez sütun
	float y;    // merkez satır
	float size; // kare kutunun kenar uzunluğu
	float q;    // güven puanı (yüksek = daha emin)
} Face;

// Pico yüz kaskadını yükler.
bool face_init(void);

// Gri görüntüde yüz arar. Eşiği geçen yüzleri güvene göre azalan sırada
// out dizisine yazar ve sayısını döndürür.
int face_detect(const u8* gray, int width, int height, float qthreshold, Face* out, int maxOut);

void face_exit(void);
