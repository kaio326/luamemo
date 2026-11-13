/* stub_gguf_shim.c — a stand-in for gguf_shim.so (development and CI only; never shipped).
 * The five lmembed_* symbols luamemo/embedders/gguf_ffi.lua declares, with a hashed bag of
 * words instead of llama.cpp: no model, no libllama, and a search still finds what was
 * written, because shared words give similar vectors. 384 dimensions, luamemo's default
 * embed_dim (embed.lua refuses a vector of another size).
 *   cc -O2 -fPIC -shared stub_gguf_shim.c -o gguf_shim.so -lm
 */
#include <ctype.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#define DIM 384

void * lmembed_load(const char * path, int n_ctx, int n_gpu_layers) {
    static int handle;
    (void) path; (void) n_ctx; (void) n_gpu_layers;
    return &handle;
}

int lmembed_dim(void * handle) { return handle ? DIM : -1; }

int lmembed_embed(void * handle, const char * text, float * out, int max_dim) {
    if (!handle || !text || !out || max_dim < DIM) return -1;
    memset(out, 0, sizeof(float) * DIM);
    uint32_t h = 2166136261u;
    int in_word = 0;
    for (const char * p = text;; p++) {
        if (*p && isalnum((unsigned char) *p)) {
            h = (h ^ (uint32_t) tolower((unsigned char) *p)) * 16777619u;
            in_word = 1;
        } else {
            if (in_word) out[h % DIM] += 1.0f;
            h = 2166136261u; in_word = 0;
            if (!*p) break;
        }
    }
    double ss = 0.0;
    for (int i = 0; i < DIM; i++) ss += (double) out[i] * out[i];
    if (ss == 0.0) { out[0] = 1.0f; return DIM; }
    double inv = 1.0 / sqrt(ss);
    for (int i = 0; i < DIM; i++) out[i] = (float) (out[i] * inv);
    return DIM;
}

int lmembed_last_truncated(void * handle) { (void) handle; return 0; }

void lmembed_free(void * handle) { (void) handle; }
