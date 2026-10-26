#include <metal_stdlib>
using namespace metal;

// Swift tarafındaki `NitUniforms` ile birebir aynı düzen: yalnızca float4 alanlar.
struct NitUniforms {
    float4 yRange;   // yOffset, yScale, cOffset, cScale
    float4 ycc0;     // Y'CbCr → R'G'B' satırları
    float4 ycc1;
    float4 ycc2;
    float4 gam0;     // doğrusal kaynak RGB → doğrusal Display P3 satırları
    float4 gam1;
    float4 gam2;
    float4 curve;    // D, u_k, x_k, g
    float4 tone;     // H_eff, transfer (0 SDR, 1 PQ, 2 HLG), SDR gaması, 1 / L_ref
    float4 dither;   // açık (0/1), genlik, tohum, -
    float4 pattern;  // tür (0 = video), pencere oranı, seviye (nit ya da PQ kodu), pencere merkezi x
    float4 scaler;   // kalite (0 bilineer, 1 kaliteli), ölçek (hedef/kaynak), 1/hedef genişlik, 1/hedef yükseklik
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

// Tek üçgenle tam ekran.
vertex VOut nitVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

static float pqEOTF(float e) {
    const float m1 = 2610.0 / 16384.0;
    const float m2 = 2523.0 / 4096.0 * 128.0;
    const float c1 = 3424.0 / 4096.0;
    const float c2 = 2413.0 / 4096.0 * 32.0;
    const float c3 = 2392.0 / 4096.0 * 32.0;
    float ep = pow(max(e, 0.0), 1.0 / m2);
    return 10000.0 * pow(max(ep - c1, 0.0) / (c2 - c3 * ep), 1.0 / m1);
}

static float hlgInverseOETF(float e) {
    const float a = 0.17883277;
    const float b = 1.0 - 4.0 * a;
    const float c = 0.5 - a * log(4.0 * a);
    e = max(e, 0.0);
    return e <= 0.5 ? e * e / 3.0 : (exp((e - c) / a) + b) / 12.0;
}

// Sinyal → doğrusal ışık. SDR: beyaz-göreli. PQ/HLG: mutlak nit.
static float3 decodeTransfer(float3 s, int tf, float gamma) {
    if (tf == 1) {
        return float3(pqEOTF(s.r), pqEOTF(s.g), pqEOTF(s.b));
    }
    if (tf == 2) {
        float3 scene = float3(hlgInverseOETF(s.r), hlgInverseOETF(s.g), hlgInverseOETF(s.b));
        float ys = dot(float3(0.2627, 0.6780, 0.0593), scene);
        return scene * (1000.0 * pow(max(ys, 1e-6), 0.2));
    }
    return pow(max(s, float3(0.0)), float3(gamma));
}

// Nit eğrisi (02-cozum §3.5): doğrusal bölge + log uzayında üstel omuz; çıkış < 1.
static float nitCurve(float x, float4 c) {
    if (x <= c.z) {
        return c.w * x;
    }
    return exp2(-c.x * exp(-(log2(x) - c.y) / c.x));
}

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Desenler: (sinyal, HDR mi) üretir. HDR ise değer mutlak nit, SDR ise sinyal.
static float3 patternSignal(float2 uv, float4 pat, thread bool &isHDR) {
    int kind = int(pat.x);
    float half_ = 0.5 * sqrt(clamp(pat.y, 0.0, 1.0));
    bool inside = abs(uv.x - pat.w) <= half_ && abs(uv.y - 0.5) <= half_;
    switch (kind) {
        case 1: // SDR beyaz pencere
            isHDR = false;
            return float3(inside ? 1.0 : 0.0);
        case 2: // PQ beyaz pencere, seviye nit cinsinden
            isHDR = true;
            return float3(inside ? pat.z : 0.0);
        case 3: // ince rampa: SDR sinyali 0,45 → 0,55, sürekli
            isHDR = false;
            return float3(mix(0.45, 0.55, uv.x));
        case 4: // karanlık rampa: SDR sinyali 0 → 0,15, sürekli
            isHDR = false;
            return float3(mix(0.0, 0.15, uv.x));
        case 5: // SDR gri rampa, 16 basamak
            isHDR = false;
            return float3(floor(uv.x * 16.0) / 15.0);
        case 6: // okunabilirlik: tam alan PQ 10000 nit
            isHDR = true;
            return float3(10000.0);
        default:
            isHDR = false;
            return float3(0.0);
    }
}

// Catmull-Rom bicubic, 9 bilineer örnekle (büyütme için).
static float sampleCatmullRom(texture2d<float> tex, sampler s, float2 uv) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 pos = uv * size;
    float2 p1 = floor(pos - 0.5) + 0.5;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1.0) / size;
    float2 t12 = (p1 + w2 / w12) / size;
    float2 t3 = (p1 + 2.0) / size;
    float r = 0.0;
    r += tex.sample(s, float2(t0.x, t0.y)).r * w0.x * w0.y;
    r += tex.sample(s, float2(t12.x, t0.y)).r * w12.x * w0.y;
    r += tex.sample(s, float2(t3.x, t0.y)).r * w3.x * w0.y;
    r += tex.sample(s, float2(t0.x, t12.y)).r * w0.x * w12.y;
    r += tex.sample(s, float2(t12.x, t12.y)).r * w12.x * w12.y;
    r += tex.sample(s, float2(t3.x, t12.y)).r * w3.x * w12.y;
    r += tex.sample(s, float2(t0.x, t3.y)).r * w0.x * w3.y;
    r += tex.sample(s, float2(t12.x, t3.y)).r * w12.x * w3.y;
    r += tex.sample(s, float2(t3.x, t3.y)).r * w3.x * w3.y;
    return r;
}

// Parlaklık (Y') örneklemesi: büyütmede bicubic, küçültmede (4K → 1125p) 2×2 süper örnekleme.
static float sampleLuma(texture2d<float> tex, sampler s, float2 uv, float4 sc) {
    if (sc.x < 0.5) {
        return tex.sample(s, uv).r;
    }
    if (sc.y >= 1.0) {
        return sampleCatmullRom(tex, s, uv);
    }
    float2 d = 0.25 * sc.zw;
    return 0.25 * (tex.sample(s, uv + float2(-d.x, -d.y)).r + tex.sample(s, uv + float2(d.x, -d.y)).r
                 + tex.sample(s, uv + float2(-d.x, d.y)).r + tex.sample(s, uv + float2(d.x, d.y)).r);
}

fragment float4 nitFragment(VOut in [[stage_in]],
                            texture2d<float> lumaTex [[texture(0)]],
                            texture2d<float> chromaTex [[texture(1)]],
                            constant NitUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Referans yaması (eşitlik testi): PQ renk uzaylı katmana PQ kodu doğrudan yazılır,
    // ton eşlemeyi sistem yapar. Nit eğrisi uygulanmaz.
    if (int(u.pattern.x) == 7) {
        float half_ = 0.5 * sqrt(clamp(u.pattern.y, 0.0, 1.0));
        bool inside = abs(in.uv.x - u.pattern.w) <= half_ && abs(in.uv.y - 0.5) <= half_;
        return float4(float3(inside ? u.pattern.z : 0.0), 1.0);
    }

    int tf = int(u.tone.y);
    bool isHDR = tf != 0;
    float3 lin;

    if (u.pattern.x < 0.5) {
        float y = sampleLuma(lumaTex, s, in.uv, u.scaler);
        float2 c = chromaTex.sample(s, in.uv).rg;
        float3 ycc = float3((y - u.yRange.x) * u.yRange.y,
                            (c.x - u.yRange.z) * u.yRange.w,
                            (c.y - u.yRange.z) * u.yRange.w);
        float3 rgbSignal = clamp(float3(dot(u.ycc0.xyz, ycc), dot(u.ycc1.xyz, ycc), dot(u.ycc2.xyz, ycc)), float3(0.0), float3(1.0));
        lin = decodeTransfer(rgbSignal, tf, u.tone.z);
    } else {
        float3 sig = patternSignal(in.uv, u.pattern, isHDR);
        lin = isHDR ? sig : pow(max(sig, float3(0.0)), float3(u.tone.z));
    }

    // HDR: mutlak nit → beyaz-göreli (L_ref = 1).
    if (isHDR) {
        lin *= u.tone.w;
    }

    // Gamut: kaynak primerleri → Display P3 (doğrusal). Gamut dışı negatifler kırpılır.
    float3 p3 = max(float3(dot(u.gam0.xyz, lin), dot(u.gam1.xyz, lin), dot(u.gam2.xyz, lin)), float3(0.0));

    float H = u.tone.x;
    float3 outc;
    if (!isHDR) {
        outc = min(p3, float3(1.0)) * H;          // SDR: beyaz = H
    } else {
        float m = max(p3.r, max(p3.g, p3.b));
        outc = m > 0.0 ? p3 * (H * nitCurve(m, u.curve) / m) : float3(0.0);
    }

    // Çıkış titreşimi (AS-33): üçgen dağılımlı, değere orantılı ±1 LSB.
    if (u.dither.x > 0.5) {
        float2 p = in.position.xy + u.dither.z;
        float n = hash12(p) + hash12(p + 17.31) - 1.0;
        outc *= 1.0 + n * u.dither.y;
    }

    return float4(min(outc, float3(H)), 1.0);
}
