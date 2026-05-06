"""
Minimal embedder sidecar for luamemo.

Implements the generic contract:
    POST /embed  { "text": "..." }  -> { "vector": [...] }

Uses sentence-transformers/all-MiniLM-L6-v2 (384 dims) by default.
Override with the EMBED_MODEL environment variable.
"""

import os
from flask import Flask, request, jsonify
from sentence_transformers import SentenceTransformer

MODEL_NAME = os.environ.get("EMBED_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
PORT       = int(os.environ.get("PORT", "8000"))

app   = Flask(__name__)
model = SentenceTransformer(MODEL_NAME)
DIM   = model.get_sentence_embedding_dimension()
print(f"Loaded {MODEL_NAME} (dim={DIM})", flush=True)


@app.route("/embed", methods=["POST"])
def embed():
    payload = request.get_json(silent=True) or {}
    text = payload.get("text")
    if not isinstance(text, str) or not text:
        return jsonify({"error": "text is required"}), 400
    vec = model.encode(text, normalize_embeddings=True).tolist()
    return jsonify({"vector": vec, "dim": DIM, "model": MODEL_NAME})


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"ok": True, "model": MODEL_NAME, "dim": DIM})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
