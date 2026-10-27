// Kafa takipli "akvaryum" sahnesi.
//
// Dünya koordinatları ekrana bağlı ve cm cinsinden: ekran z=0 düzleminde,
// merkezi orijinde. Kutu ekranın arkasında (z < 0), bir küp ekranın önünde
// (z > 0) durur. Her göz için ekran kenarlarından geçen asimetrik (off-axis)
// bir frustum kurulur; böylece ekran, sahneye açılan bir pencere gibi davranır.

#include <string.h>

#include <citro3d.h>

#include "scene.h"
#include "vshader_shbin.h"

typedef struct {
	float x, y, z;
	float r, g, b;
} Vertex;

#define MAX_VERTICES 4096

static DVLB_s* s_dvlb;
static shaderProgram_s s_program;
static int s_uMvp;

static Vertex* s_vbo;
static int s_count;
static int s_staticCount;     // kutu ve sabit küpler
static int s_spinStart;       // dönen küpün ilk köşesi
static int s_spinCount;

typedef struct {
	float x, y, z;
} Vec3;

static Vec3 v3(float x, float y, float z)
{
	Vec3 v = { x, y, z };
	return v;
}

static Vec3 v3_add(Vec3 a, Vec3 b)
{
	return v3(a.x + b.x, a.y + b.y, a.z + b.z);
}

static Vec3 v3_scale(Vec3 a, float s)
{
	return v3(a.x * s, a.y * s, a.z * s);
}

// Derinlik ipucu: uzaktaki köşeler daha koyu.
static float depth_shade(float z)
{
	if (z >= 0.0f)
		return 1.0f;
	float t = -z / BOX_DEPTH_CM;
	if (t > 1.0f)
		t = 1.0f;
	return 1.0f - 0.55f * t;
}

static void add_vertex(Vec3 p, const float color[3], float shade, bool depthShaded)
{
	if (s_count >= MAX_VERTICES)
		return;
	float k = shade * (depthShaded ? depth_shade(p.z) : 1.0f);
	Vertex* v = &s_vbo[s_count++];
	v->x = p.x;
	v->y = p.y;
	v->z = p.z;
	v->r = color[0] * k;
	v->g = color[1] * k;
	v->b = color[2] * k;
}

// a-b-c-d sıralı bir dörtgeni iki üçgen olarak ekler.
static void add_quad(Vec3 a, Vec3 b, Vec3 c, Vec3 d, const float color[3], float shade, bool depthShaded)
{
	add_vertex(a, color, shade, depthShaded);
	add_vertex(b, color, shade, depthShaded);
	add_vertex(c, color, shade, depthShaded);
	add_vertex(a, color, shade, depthShaded);
	add_vertex(c, color, shade, depthShaded);
	add_vertex(d, color, shade, depthShaded);
}

// origin'den u ve v yönlerinde nu x nv karolu dama desenli duvar.
static void add_checker_wall(Vec3 origin, Vec3 u, Vec3 v, int nu, int nv,
	const float colorA[3], const float colorB[3])
{
	for (int i = 0; i < nu; i++) {
		for (int j = 0; j < nv; j++) {
			Vec3 p00 = v3_add(origin, v3_add(v3_scale(u, (float)i / nu), v3_scale(v, (float)j / nv)));
			Vec3 p10 = v3_add(origin, v3_add(v3_scale(u, (float)(i + 1) / nu), v3_scale(v, (float)j / nv)));
			Vec3 p11 = v3_add(origin, v3_add(v3_scale(u, (float)(i + 1) / nu), v3_scale(v, (float)(j + 1) / nv)));
			Vec3 p01 = v3_add(origin, v3_add(v3_scale(u, (float)i / nu), v3_scale(v, (float)(j + 1) / nv)));
			add_quad(p00, p10, p11, p01, ((i + j) & 1) ? colorA : colorB, 1.0f, true);
		}
	}
}

// Yüzleri farklı tonlarda gölgelenmiş küp (basit sabit ışık).
static void add_cube(Vec3 c, float h, const float color[3], bool depthShaded)
{
	Vec3 p[8];
	for (int i = 0; i < 8; i++)
		p[i] = v3(c.x + ((i & 1) ? h : -h), c.y + ((i & 2) ? h : -h), c.z + ((i & 4) ? h : -h));

	add_quad(p[4], p[5], p[7], p[6], color, 0.90f, depthShaded); // ön (+z)
	add_quad(p[1], p[0], p[2], p[3], color, 0.45f, depthShaded); // arka (-z)
	add_quad(p[2], p[6], p[7], p[3], color, 1.00f, depthShaded); // üst (+y)
	add_quad(p[0], p[1], p[5], p[4], color, 0.35f, depthShaded); // alt (-y)
	add_quad(p[5], p[1], p[3], p[7], color, 0.70f, depthShaded); // sağ (+x)
	add_quad(p[0], p[4], p[6], p[2], color, 0.60f, depthShaded); // sol (-x)
}

static void build_geometry(void)
{
	const float W = SCREEN_W_CM, H = SCREEN_H_CM, D = BOX_DEPTH_CM;
	const float wallA[3] = { 0.25f, 0.45f, 0.85f };
	const float wallB[3] = { 0.15f, 0.30f, 0.65f };
	const float floorA[3] = { 0.85f, 0.85f, 0.85f };
	const float floorB[3] = { 0.35f, 0.35f, 0.40f };

	s_count = 0;

	// Arka duvar
	add_checker_wall(v3(-W / 2, -H / 2, -D), v3(W, 0, 0), v3(0, H, 0), 8, 5, wallA, wallB);
	// Zemin ve tavan
	add_checker_wall(v3(-W / 2, -H / 2, 0), v3(W, 0, 0), v3(0, 0, -D), 8, 12, floorA, floorB);
	add_checker_wall(v3(-W / 2, H / 2, 0), v3(W, 0, 0), v3(0, 0, -D), 8, 12, wallA, wallB);
	// Yan duvarlar
	add_checker_wall(v3(-W / 2, -H / 2, 0), v3(0, 0, -D), v3(0, H, 0), 12, 5, wallA, wallB);
	add_checker_wall(v3(W / 2, -H / 2, 0), v3(0, 0, -D), v3(0, H, 0), 12, 5, wallA, wallB);

	// Zemindeki küpler, farklı derinliklerde
	const float red[3] = { 0.95f, 0.25f, 0.25f };
	const float green[3] = { 0.30f, 0.90f, 0.35f };
	const float purple[3] = { 0.70f, 0.35f, 0.90f };
	add_cube(v3(-2.2f, -H / 2 + 0.8f, -9.0f), 0.8f, red, true);
	add_cube(v3(2.3f, -H / 2 + 0.6f, -5.0f), 0.6f, green, true);
	add_cube(v3(-1.2f, -H / 2 + 0.4f, -2.5f), 0.4f, purple, true);

	// Ekranın önünde süzülen küp (3D'de ekrandan dışarı çıkar)
	const float orange[3] = { 1.00f, 0.65f, 0.15f };
	add_cube(v3(1.6f, -0.9f, 1.2f), 0.35f, orange, false);

	s_staticCount = s_count;

	// Kutunun ortasında dönen küp (orijinde üretilir, model matrisiyle taşınır)
	const float yellow[3] = { 1.00f, 0.90f, 0.20f };
	s_spinStart = s_count;
	add_cube(v3(0, 0, 0), 0.7f, yellow, false);
	s_spinCount = s_count - s_spinStart;
}

bool scene_init(void)
{
	s_dvlb = DVLB_ParseFile((u32*)vshader_shbin, vshader_shbin_size);
	if (!s_dvlb)
		return false;
	shaderProgramInit(&s_program);
	shaderProgramSetVsh(&s_program, &s_dvlb->DVLE[0]);
	C3D_BindProgram(&s_program);
	s_uMvp = shaderInstanceGetUniformLocation(s_program.vertexShader, "mvp");

	C3D_AttrInfo* attrInfo = C3D_GetAttrInfo();
	AttrInfo_Init(attrInfo);
	AttrInfo_AddLoader(attrInfo, 0, GPU_FLOAT, 3); // v0 = konum
	AttrInfo_AddLoader(attrInfo, 1, GPU_FLOAT, 3); // v1 = renk

	s_vbo = linearAlloc(MAX_VERTICES * sizeof(Vertex));
	if (!s_vbo)
		return false;
	build_geometry();
	GSPGPU_FlushDataCache(s_vbo, s_count * sizeof(Vertex));

	C3D_BufInfo* bufInfo = C3D_GetBufInfo();
	BufInfo_Init(bufInfo);
	BufInfo_Add(bufInfo, s_vbo, sizeof(Vertex), 2, 0x10);

	// Köşe rengini doğrudan kullan.
	C3D_TexEnv* env = C3D_GetTexEnv(0);
	C3D_TexEnvInit(env);
	C3D_TexEnvSrc(env, C3D_Both, GPU_PRIMARY_COLOR, 0, 0);
	C3D_TexEnvFunc(env, C3D_Both, GPU_REPLACE);

	// Dörtgen yönleri karışık; arka yüz elemeyi kapat.
	C3D_CullFace(GPU_CULL_NONE);
	C3D_DepthTest(true, GPU_GREATER, GPU_WRITE_ALL);
	return true;
}

// Göz (ex, ey, ez) için ekran kenarlarından geçen off-axis frustum, 3DS'in
// yan yatık ekranına göre döndürülmüş. Derinlik aralığı PICA'ya uygun
// [-1, 0] (citro3d Mtx_PerspTilt ile aynı düzen).
static void offaxis_tilt(C3D_Mtx* m, float ex, float ey, float ez, float nearZ, float farZ)
{
	float a = 2.0f * ez / SCREEN_W_CM;  // yatay ölçek
	float c = -2.0f * ex / SCREEN_W_CM; // yatay kayma
	float b = 2.0f * ez / SCREEN_H_CM;  // dikey ölçek
	float d = -2.0f * ey / SCREEN_H_CM; // dikey kayma

	Mtx_Zeros(m);
	// Ekran yan yatık: çıktı x dikey eksenden, çıktı y (eksi) yatay eksenden gelir.
	m->r[0].y = b;
	m->r[0].z = d;
	m->r[1].x = -a;
	m->r[1].z = -c;
	m->r[2].z = nearZ / (nearZ - farZ);
	m->r[2].w = farZ * nearZ / (nearZ - farZ);
	m->r[3].z = -1.0f;
}

void scene_render_eye(float eyeX, float eyeY, float eyeZ, float timeSec)
{
	C3D_Mtx proj, view, viewProj, model, mvp;

	offaxis_tilt(&proj, eyeX, eyeY, eyeZ, 0.5f, eyeZ + BOX_DEPTH_CM + 10.0f);
	Mtx_Identity(&view);
	Mtx_Translate(&view, -eyeX, -eyeY, -eyeZ, true);
	Mtx_Multiply(&viewProj, &proj, &view);

	C3D_FVUnifMtx4x4(GPU_VERTEX_SHADER, s_uMvp, &viewProj);
	C3D_DrawArrays(GPU_TRIANGLES, 0, s_staticCount);

	// Dönen küp: kutunun ortasında
	Mtx_Identity(&model);
	Mtx_Translate(&model, 0.0f, 0.3f, -BOX_DEPTH_CM * 0.45f, true);
	Mtx_RotateY(&model, timeSec * 0.8f, true);
	Mtx_RotateX(&model, timeSec * 0.5f, true);
	Mtx_Multiply(&mvp, &viewProj, &model);

	C3D_FVUnifMtx4x4(GPU_VERTEX_SHADER, s_uMvp, &mvp);
	C3D_DrawArrays(GPU_TRIANGLES, s_spinStart, s_spinCount);
}

void scene_exit(void)
{
	if (s_vbo)
		linearFree(s_vbo);
	s_vbo = NULL;
	shaderProgramFree(&s_program);
	if (s_dvlb)
		DVLB_Free(s_dvlb);
	s_dvlb = NULL;
}
