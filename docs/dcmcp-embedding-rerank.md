# Side-note: optional local-embedding rerank for `dc_recall` (Phase 3)

> **Deferred.** The shipped `dc_recall` (see [`dcmcp-plan.md`](dcmcp-plan.md)) uses a ripgrep
> lexical prefilter and lets the in-session model rank candidates — zero dependencies, fully
> local. This note records *if/when lexical proves too blunt* how a local-embedding rerank would
> be added, what hardware it needs, and a coarse plan. Nothing here is built yet.

## When this becomes worth it

The lexical path misses **pure-synonym / conceptual** matches — a query for "swap the relay to a
pull model" won't hit a chat that only ever said "receiver-initiated mirror." If, in practice,
recalls keep missing because the words differ from the query, add a semantic rerank. Until that
actually bites, don't — the corpus is ~100 files and lexical + a frontier model reranking snippets
covers most cases.

## Hard constraint: stays local (no third party)

Same rule as the rest of dotclaude — transcripts/memory carry sensitive paths, so **no hosted
embedding API** (Voyage/OpenAI/etc.). The embedder must run on the NAS box. That rules the
hardware question.

## Hardware reality on the archive host (Raspberry Pi 5)

- the archive host is a **Pi 5 (`rpi-2712`), ARM64, ~8 GB RAM**, CPU-only (no usable GPU/NPU for this).
- Corpus is tiny: **~39 readables + 9 plans + 12 memories ≈ 60–100 docs**, chunked maybe
  ~1–3k chunks. Embedding that **once** is seconds-to-minutes on CPU; re-embedding only the
  *new* session on each relay is trivial. Query-time is one embedding + a brute-force cosine over
  a few thousand vectors — **milliseconds, no vector DB needed** (a NumPy array + `argpartition`,
  or `sqlite-vec` if you want it on disk).
- Model options (all CPU-friendly, ARM64):
  - **Ollama `nomic-embed-text`** (768-dim, ~274 MB) — simplest to operate; `ollama serve`
    already a tidy local daemon, one HTTP call to embed. Recommended if Ollama is acceptable on
    the Pi.
  - **`sentence-transformers` `all-MiniLM-L6-v2`** (384-dim, ~90 MB) — lighter, pure-Python via
    `uv`, no separate daemon; slightly weaker but more than enough at this scale.
  - **`bge-small-en-v1.5`** (384-dim) — a notch better than MiniLM, similar footprint.
- RAM/throughput: any of these fit comfortably in <1 GB resident on the Pi; the bottleneck is
  first-run model download, not inference at this corpus size.

## Coarse plan (Phase 3, slab H)

1. **Index sidecar.** Store vectors next to the archive, e.g.
   `dotclaude-storage/.dcmcp/embeddings.sqlite` (or `.npz` + a json manifest). Never inside the
   `readable/`/`.jsonl` trees, never committed — it's a derived cache.
2. **Chunking.** Split each readable transcript into turn-aligned chunks (reuse the turn anchors
   `dc_search_within` already computes) so a hit maps back to a turn/line. Memories/plans = one
   chunk each (they're small).
3. **Incremental build.** A hook on relay (or a `dcmcp --reindex`) embeds only files whose mtime
   is newer than the manifest. Full rebuild is cheap enough to be a fallback.
4. **Rerank, don't replace.** Keep ripgrep as the recall **prefilter**; embeddings only **reorder**
   the candidate set (hybrid: lexical recall ∪ top-k cosine, then merge scores). This keeps exact
   keyword matches reliable and adds semantic reach, and means the embedder being down degrades to
   today's behaviour rather than breaking recall.
5. **Gate it.** Behind `DOTCLAUDE_MCP_EMBED=1` (or auto-on if the model/daemon is present), so the
   zero-dependency lexical path stays the default and a fresh machine needs nothing extra.
6. **Runtime.** Embedder runs on the archive host only (where the archive + the server live); remote machines
   get reranked results for free once Phase 2's HTTP-over-WG endpoint exists — they never run the
   model themselves.

## Rough effort / risk

- Effort: small — the search plumbing (`dc_recall`, anchors, candidate set) already exists from
  Phase 1; this adds an embed step + a cosine sort + an incremental cache. ~Half a day.
- Risk: low and **contained** — it's a rerank over an existing candidate list, fully local, gated,
  and falls back cleanly. Main cost is operational (a model/daemon to keep alive on the Pi), which
  is exactly why it's deferred until lexical recall demonstrably falls short.
