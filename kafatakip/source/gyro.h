#pragma once

#include <3ds.h>

// Gyro füzyonu.
//
// Konsol döndüğünde, sabit duran kafa ekrana göre hemen yer değiştirir.
// Kamera bunu ancak birkaç kare sonra görür; gyro anında görür. Gyro
// eksenlerinin üst ekrana göre yönü menteşe açısına bağlı olduğundan
// eşleme elle verilmez: kameranın ölçtüğü kafa kayması ile gyro dönüşü
// karşılaştırılarak (özyinelemeli en küçük kareler) öğrenilir.
//
// Öğrenilen model: kamera aralığındaki dönüş vektörü g (rad) için
//   yatay açı = g . a   ->  kafa x kayması = -z * (g . a)
//   dikey açı = g . b   ->  kafa y kayması = +z * (g . b)

// Gyro eşlemesi güvenilir sayılmadan önce gereken öğrenme örneği sayısı.
#define GYRO_MIN_SAMPLES 25

bool gyro_init(void);

// Her döngüde çağrılır; bu adımdaki dönüşü (rad) geçmişe kaydeder ve döndürür.
void gyro_update(u64 nowMs, float dt, float outDelta[3]);

// (fromMs, toMs] aralığındaki toplam dönüş (rad).
void gyro_integral(u64 fromMs, u64 toMs, float out[3]);

// Bir dönüş vektörünün yol açtığı kafa kayması (cm), z uzaklığında.
void gyro_head_shift(const float rot[3], float z, float* dx, float* dy);

// Kamera aralığından bir örnek: rot bu aralıktaki gyro dönüşü, headDx/headDy
// kameranın ölçtüğü kafa kayması (cm), z uzaklık (cm).
void gyro_learn(const float rot[3], float headDx, float headDy, float z);

bool gyro_trained(void);
int gyro_samples(void);

void gyro_exit(void);
