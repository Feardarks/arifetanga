#include <math.h>

#include "head.h"

// Varsayımlar; uzaklık ya da hareket miktarı yanlış çıkarsa bunlar ayarlanır.
#define CAM_HFOV_DEG     60.0f // iç kameranın yatay görüş açısı (tahmini)
#define FACE_WIDTH_CM    15.0f // pico kutusunun gerçek boyutu (yaklaşık yüz genişliği)
#define EYES_ABOVE_BOX   0.15f // gözler kutu merkezinin bu kadar (boyut oranı) üstünde
#define CAM_ABOVE_SCREEN 3.0f  // kameranın ekran merkezinden yüksekliği (cm)

HeadPos head_from_face(const Face* face, int camWidth, int camHeight, bool flipX, bool flipY)
{
	float cmPerPixel = FACE_WIDTH_CM / face->size;
	float focalPx = (camWidth / 2.0f) / tanf(CAM_HFOV_DEG * (float)M_PI / 360.0f);

	float eyeRow = face->y - EYES_ABOVE_BOX * face->size;

	// İç kamera görüntüyü ayna gibi verir (konsolda doğrulandı): izleyici kendi
	// sağına gidince yüz görüntüde de sağa kayar. Görüntü satırları aşağı doğru artar.
	float dx = (face->x - camWidth / 2.0f) * cmPerPixel;
	float dy = -(eyeRow - camHeight / 2.0f) * cmPerPixel;
	if (flipX)
		dx = -dx;
	if (flipY)
		dy = -dy;

	HeadPos p;
	p.x = dx;
	p.y = dy + CAM_ABOVE_SCREEN;
	p.z = focalPx * cmPerPixel;
	return p;
}
