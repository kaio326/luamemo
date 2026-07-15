/* gguf_shim.c — thin, stable C shim over llama.cpp for in-process embedding.
 *
 * Purpose: expose a tiny 4-function API so LuaJIT's FFI binds primitives only,
 * never llama.cpp's version-fragile parameter/batch structs (those live inside
 * this shim, compiled against the real llama.h so their layout is always right).
 *
 * The "one native library" is llama.cpp (libllama + libggml); this shim is the
 * glue. Loads ANY llama.cpp-compatible GGUF embedding model (recommended default
 * EmbeddingGemma-300M, but swappable), mean-pools the token embeddings, and
 * L2-normalises the result.
 *
 * Build (see luamemo/embedders/native/build.sh):
 *   cc -O2 -fPIC -shared gguf_shim.c -o gguf_shim.so \
 *      -I<llama.cpp>/include -I<llama.cpp>/ggml/include \
 *      -L<llama.cpp>/build/bin -lllama -lm
 */
#include "llama.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

typedef struct {
    struct llama_model       * model;
    struct llama_context     * ctx;
    const struct llama_vocab * vocab;
    int                        n_embd;
} lmembed_t;

static int g_backend_ready = 0;

/* Load a GGUF embedding model. CPU only (n_gpu_layers = 0). Returns an opaque
 * handle, or NULL on failure. n_ctx <= 0 uses a 2048 default. */
void * lmembed_load(const char * path, int n_ctx, int n_gpu_layers) {
    if (!g_backend_ready) { llama_backend_init(); g_backend_ready = 1; }

    struct llama_model_params mp = llama_model_default_params();
    /* n_gpu_layers: 0 = CPU (default), N = offload N layers, <0 = all layers.
     * Harmless on a CPU-only libllama (ignored — no GPU backend registered). */
    mp.n_gpu_layers = (n_gpu_layers >= 0) ? n_gpu_layers : 999;
    struct llama_model * model = llama_model_load_from_file(path, mp);
    if (!model) return NULL;

    struct llama_context_params cp = llama_context_default_params();
    cp.embeddings   = true;
    cp.n_ctx        = (n_ctx > 0) ? (uint32_t) n_ctx : 2048u;
    cp.n_batch      = cp.n_ctx;
    cp.n_ubatch     = cp.n_ctx;
    cp.pooling_type = LLAMA_POOLING_TYPE_MEAN;   /* EmbeddingGemma uses mean pooling */

    struct llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); return NULL; }

    lmembed_t * h = (lmembed_t *) malloc(sizeof(lmembed_t));
    if (!h) { llama_free(ctx); llama_model_free(model); return NULL; }
    h->model  = model;
    h->ctx    = ctx;
    h->vocab  = llama_model_get_vocab(model);
    h->n_embd = llama_model_n_embd(model);
    return h;
}

int lmembed_dim(void * handle) {
    return handle ? ((lmembed_t *) handle)->n_embd : -1;
}

/* Embed `text` into `out` (up to max_dim floats). Returns the number of floats
 * written (the embedding dim), or -1 on failure. Output is L2-normalised. */
int lmembed_embed(void * handle, const char * text, float * out, int max_dim) {
    if (!handle || !text || !out) return -1;
    lmembed_t * h = (lmembed_t *) handle;
    const int32_t n_ctx = (int32_t) llama_n_ctx(h->ctx);
    const int32_t tlen  = (int32_t) strlen(text);

    /* two-pass tokenise: first get the count (negated), then fill */
    int32_t need = -llama_tokenize(h->vocab, text, tlen, NULL, 0, true, false);
    if (need <= 0) return -1;
    if (need > n_ctx) need = n_ctx;                 /* truncate to context */
    llama_token * toks = (llama_token *) malloc(sizeof(llama_token) * need);
    if (!toks) return -1;
    int32_t n = llama_tokenize(h->vocab, text, tlen, toks, need, true, false);
    if (n < 0) n = need;                            /* was truncated */
    if (n <= 0) { free(toks); return -1; }

    struct llama_batch batch = llama_batch_init(n, 0, 1);
    for (int32_t i = 0; i < n; i++) {
        batch.token[i]      = toks[i];
        batch.pos[i]        = i;
        batch.n_seq_id[i]   = 1;
        batch.seq_id[i][0]  = 0;
        batch.logits[i]     = 1;                    /* all tokens pooled (MEAN) */
    }
    batch.n_tokens = n;

    int32_t rc = llama_model_has_encoder(h->model)
        ? llama_encode(h->ctx, batch)
        : llama_decode(h->ctx, batch);
    if (rc != 0) { llama_batch_free(batch); free(toks); return -1; }

    const float * emb = llama_get_embeddings_seq(h->ctx, 0);
    if (!emb) emb = llama_get_embeddings(h->ctx);
    if (!emb) { llama_batch_free(batch); free(toks); return -1; }

    int d = h->n_embd;
    if (d > max_dim) d = max_dim;
    double ss = 0.0;
    for (int i = 0; i < h->n_embd; i++) ss += (double) emb[i] * (double) emb[i];
    double inv = (ss > 0.0) ? 1.0 / sqrt(ss) : 1.0;
    for (int i = 0; i < d; i++) out[i] = (float) (emb[i] * inv);

    llama_batch_free(batch);
    free(toks);
    return d;
}

void lmembed_free(void * handle) {
    if (!handle) return;
    lmembed_t * h = (lmembed_t *) handle;
    llama_free(h->ctx);
    llama_model_free(h->model);
    free(h);
}

/* ======================================================================
 * Generation (Phase 9 — in-process sensing / "dreams" extraction).
 * A SEPARATE handle for a small generative GGUF (instruct model). Greedy /
 * deterministic decoding so extraction is reproducible. Loaded on-demand.
 * ==================================================================== */

typedef struct {
    struct llama_model       * model;
    struct llama_context     * ctx;
    const struct llama_vocab * vocab;
    struct llama_sampler     * smpl;
} lmgen_t;

void * lmgen_load(const char * path, int n_ctx, int n_gpu_layers) {
    if (!g_backend_ready) { llama_backend_init(); g_backend_ready = 1; }

    struct llama_model_params mp = llama_model_default_params();
    /* n_gpu_layers: 0 = CPU, N = offload N layers, <0 = all. A 4B instruct model
     * fits comfortably on a 6GB GPU and extracts far more reliably than 1B-CPU.
     * Harmless on a CPU-only libllama (ignored). */
    mp.n_gpu_layers = (n_gpu_layers >= 0) ? n_gpu_layers : 999;
    struct llama_model * model = llama_model_load_from_file(path, mp);
    if (!model) return NULL;

    struct llama_context_params cp = llama_context_default_params();
    cp.n_ctx   = (n_ctx > 0) ? (uint32_t) n_ctx : 4096u;
    cp.n_batch = cp.n_ctx;

    struct llama_context * ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); return NULL; }

    struct llama_sampler * smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());   /* deterministic argmax */

    lmgen_t * h = (lmgen_t *) malloc(sizeof(lmgen_t));
    if (!h) { llama_sampler_free(smpl); llama_free(ctx); llama_model_free(model); return NULL; }
    h->model = model; h->ctx = ctx; h->vocab = llama_model_get_vocab(model); h->smpl = smpl;
    return h;
}

/* Greedily complete `prompt` into `out` (NUL-terminated, up to max_out-1 bytes).
 * Returns the number of bytes written, or -1 on failure. KV cache is cleared each
 * call so completions are independent. */
int lmgen_complete(void * handle, const char * prompt, char * out, int max_out, int max_tokens) {
    if (!handle || !prompt || !out || max_out < 1) return -1;
    lmgen_t * h = (lmgen_t *) handle;

    llama_memory_clear(llama_get_memory(h->ctx), true);   /* fresh context per call */

    const int32_t plen = (int32_t) strlen(prompt);
    int32_t need = -llama_tokenize(h->vocab, prompt, plen, NULL, 0, true, true);
    if (need <= 0) return -1;
    llama_token * toks = (llama_token *) malloc(sizeof(llama_token) * need);
    if (!toks) return -1;
    int32_t np = llama_tokenize(h->vocab, prompt, plen, toks, need, true, true);
    if (np <= 0) { free(toks); return -1; }

    struct llama_batch batch = llama_batch_get_one(toks, np);
    if (llama_decode(h->ctx, batch) != 0) { free(toks); return -1; }
    free(toks);

    if (max_tokens <= 0) max_tokens = 256;
    int out_len = 0;
    for (int i = 0; i < max_tokens; i++) {
        llama_token tok = llama_sampler_sample(h->smpl, h->ctx, -1);
        if (llama_vocab_is_eog(h->vocab, tok)) break;
        char piece[512];
        int32_t pn = llama_token_to_piece(h->vocab, tok, piece, (int32_t) sizeof(piece), 0, false);
        if (pn > 0) {
            if (out_len + pn >= max_out) break;
            memcpy(out + out_len, piece, (size_t) pn);
            out_len += pn;
        }
        llama_token one = tok;
        struct llama_batch b1 = llama_batch_get_one(&one, 1);
        if (llama_decode(h->ctx, b1) != 0) break;
    }
    out[out_len] = '\0';
    return out_len;
}

void lmgen_free(void * handle) {
    if (!handle) return;
    lmgen_t * h = (lmgen_t *) handle;
    if (h->smpl) llama_sampler_free(h->smpl);
    llama_free(h->ctx);
    llama_model_free(h->model);
    free(h);
}
