# llm - Qwen2.5-1.5B-Instruct on llama.cpp

A small language model served at `http://llm.llm.svc.cluster.local:8080/v1` (OpenAI-compatible: `/v1/chat/completions`,
`/v1/completions`, `/health`, `/metrics`). Model: `Qwen/Qwen2.5-1.5B-Instruct-GGUF`, 4-bit `Q4_K_M` (1.04 GiB), downloaded
from Hugging Face on first start into a node-local volume.

**Not deployed until pushed.** `llm` also has to be an allowed destination namespace in the Argo CD project:
`roles/argocd/templates/appproject.yaml.j2` has it now, so run `make deploy-argocd` (or add it to the live `home-pi`
AppProject by hand) before the first sync.

## Why llama.cpp

It is the leanest stack that runs on a Pi: one C++ binary with no Python runtime, weights loaded straight from the GGUF
file, ARM NEON/dot-product kernels chosen at runtime from CPU-specific builds in the image (armv8.2 for a Pi 5), a small compute buffer with flash attention, and an 8-bit KV cache. vLLM and TGI
need far more memory and a GPU; Ollama is llama.cpp plus a Go server on top.

## What was measured (these exact flags, build b11669, rpi-5-4 under its normal load)

| | Pi 5 |
|---|---|
| Generation | ~6-7 tokens/s |
| Prompt processing | ~40-45 tokens/s |
| Memory, anonymous | 1.11 GB (weights repacked by the ARMv8.2 kernels + KV cache + buffers) |
| Memory, file cache | 0.6 GB (reclaimable; the GGUF is not needed once repacked) |

The node was running its normal workloads during the test, so treat the speeds as a conservative floor.

## Memory limit

`values.yaml` requests 1280 Mi and limits 1536 Mi. The working set that cannot be given back is about 1.2-1.3 GB on
a Pi 5; a limit below that makes the kernel evict model pages and re-read them from disk for every token.
To try a tighter limit, lower it in steps and watch both of these stay low:

```bash
kubectl -n llm top pod
kubectl -n llm exec deploy/llm -- sh -c 'grep -E "^(anon|file) " /sys/fs/cgroup/memory.stat; grep oom_kill /sys/fs/cgroup/memory.events'
```

Other knobs, in order of effect on memory: `--ctx-size` (KV cache is allocated up front for the whole context; 4096 is
~60 MB at 8-bit), `--parallel` (each extra slot needs its own), `--batch-size`/`--ubatch-size` (scratch buffers).

## Re-running the comparison

```bash
kubectl -n llm port-forward svc/llm 8080:8080 &
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-1.5b-instruct","messages":[{"role":"user","content":"Explain in three sentences why the sky is blue."}],"max_tokens":128,"temperature":0}' \
  | python3 -c 'import json,sys; t=json.load(sys.stdin)["timings"]; print("prompt t/s", round(t["prompt_per_second"],1), "gen t/s", round(t["predicted_per_second"],2))'
```

The model volume is node-local (`local-path`), so it re-downloads (~1.1 GB) if the pod lands on a different node.

## Wiring it in

- **Bifrost:** add a provider of type OpenAI-compatible with base URL `http://llm.llm.svc.cluster.local:8080/v1` and model
  `qwen2.5-1.5b-instruct`. `apps/bifrost/manifests/networkpolicy.yaml` needs an egress rule to the `llm` namespace on 8080.
- **Access control:** llama-server has no API key here, so `manifests/networkpolicy.yaml` admits only Bifrost, Open WebUI
  and the metrics scraper, and lets the pod out only to DNS and public HTTPS (for the model download).
- **Metrics:** `manifests/vmservicescrape.yaml` scrapes `/metrics`.
