# LLM Server Toolkit

Scripts for setting up and managing a local LLM inference server on NVIDIA GPU machines.

Tested on Ubuntu 22.04/24.04 with NVIDIA GPUs (e.g., 2x RTX 3090, 48GB total VRAM).

## Prerequisites

Ensure these tools are available on your system:

| Tool | Required by | Install |
|------|-------------|---------|
| `git` | build-llama.sh | `apt install git` |
| `cmake` ≥ 3.18 | build-llama.sh | `apt install cmake` |
| `g++` | build-llama.sh | `apt install build-essential` |
| `tmux` | llama-server.sh | `apt install tmux` |
| `wget` | setup-nvidia.sh, setup-cuda.sh | `apt install wget` |
| `curl` | llama-server.sh (health checks) | `apt install curl` |
| `python3` | llama-server.sh (status formatting) | `apt install python3` |
| `lspci` | setup-nvidia.sh (GPU detection) | `apt install pciutils` |
| `uv` or `pip` | download-model.sh | See [uv docs](https://docs.astral.sh/uv/) |

## Scripts

| Script | Purpose | Run as |
|--------|---------|--------|
| `setup-nvidia.sh` | Install NVIDIA driver with DKMS (survives kernel upgrades) | `sudo` |
| `setup-cuda.sh` | Install CUDA toolkit | `sudo` |
| `build-llama.sh` | Clone and build llama.cpp (or turboquant fork) with CUDA | user |
| `download-model.sh` | Download GGUF models from HuggingFace | user |
| `llama-server.sh` | Start/stop/restart/manage llama-server (tmux or systemd) | user |
| `benchmark.sh` | Benchmark with various KV cache types (saves CSV/JSON) | user |
| `cleanup.sh` | Free disk space (Docker, models, caches) with dry-run mode | user |
| `new-api.sh` | Manage New API gateway (setup/start/stop/channels/tokens) | user |
| `cloudflared.sh` | Manage Cloudflare Tunnel for HTTPS access | user |

### Shared Library

All scripts use `lib/common.sh` which provides:
- Colored logging (`log_info`, `log_warn`, `log_error`, `log_success`)
- Error traps and temp file cleanup
- GPU detection helpers
- Input validation (numeric, range)
- Confirmation prompts
- CUDA/model/binary path finding

## Quick Start

```bash
# 1. Setup GPU (run as root)
sudo bash setup-nvidia.sh
sudo bash setup-cuda.sh

# 2. Build llama.cpp
bash build-llama.sh

# 3. Download a model
bash download-model.sh

# 4. Start serving
bash llama-server.sh start

# 5. Check status
bash llama-server.sh status

# 6. (Optional) Setup New API gateway
bash new-api.sh setup
bash new-api.sh add-channel

# 7. Run benchmarks
bash benchmark.sh

# 8. Free disk space (optional)
bash cleanup.sh              # interactive cleanup
bash cleanup.sh --dry-run    # preview what would be cleaned
```

## Server Management

The server can run in two modes:
- **tmux** (default) — foreground session, easy to attach and see output
- **systemd** — background service, survives reboots, auto-restarts on crash

```bash
# Start (interactive — prompts for model, GPU mode, context, port, run mode)
bash llama-server.sh start

# Or specify the mode directly:
bash llama-server.sh start --tmux       # run in tmux
bash llama-server.sh start --systemd    # run as systemd service

# Stop (auto-detects which mode is running)
bash llama-server.sh stop

# Restart (preserves the current run mode)
bash llama-server.sh restart

# Health check
bash llama-server.sh status

# View recent logs (tmux or journalctl, auto-detected)
bash llama-server.sh logs

# systemd only: enable/disable auto-start on boot
bash llama-server.sh enable
bash llama-server.sh disable

# tmux only: attach to live server output
tmux attach -t llama
```

## API Usage

Once the server is running, it exposes an OpenAI-compatible API:

```bash
# Health check
curl http://localhost:8000/health

# Chat completion
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-27B-UD-Q4_K_XL",
    "messages": [{"role": "user", "content": "Hello!"}],
    "temperature": 0.7
  }'

# Streaming
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen3.5-27B-UD-Q4_K_XL",
    "messages": [{"role": "user", "content": "Write a poem"}],
    "stream": true
  }'
```

## Benchmark Results

The benchmark script saves results in multiple formats:

```bash
bash benchmark.sh
# Results saved to benchmark-results/
#   benchmark-YYYYMMDD-HHMMSS.log   # Human-readable log
#   benchmark-YYYYMMDD-HHMMSS.csv   # CSV for spreadsheets
#   benchmark-YYYYMMDD-HHMMSS.json  # JSON for programmatic use
```

A comparison summary table is printed at the end showing tokens/sec across KV cache types.

## GPU Configuration

- **Single GPU (≤20GB model):** Automatically uses one GPU. ~30 t/s decode for 27B Q4.
- **Dual GPU (>20GB model):** Automatically splits across both GPUs. ~25 t/s decode for 27B Q6 (limited by PCIe bandwidth between GPUs).

## KV Cache Types

| Type | Bits/value | Best for |
|------|------------|----------|
| `f16` | 16 | Maximum quality, highest VRAM |
| `q8_0` | 8.5 | Recommended default — no quality loss |
| `q4_0` | 4.5 | Long context on limited VRAM |
| `turbo2` | 2.5 | Maximum context length (turboquant fork only) |
| `turbo3` | 3 | Balance of quality and compression (turboquant fork only) |

## Recommended Models

### Qwen3.5-27B (text-only, dense, great for coding)

| Model | Size | Single 24GB GPU | Quality |
|-------|------|-----------------|---------|
| Qwen3.5-27B-UD-Q4_K_XL | 17 GB | Yes (with q8_0 KV) | Good |
| Qwen3.5-27B-UD-Q6_K_XL | 24 GB | No (needs 2x GPU) | Better |
| Qwen3.5-27B-Q8_0 | 30 GB | No (needs 2x GPU) | Best GGUF |

### Gemma-4-26B-A4B (multimodal MoE, 26B total / 4B active params)

| Model | Size | Single 24GB GPU | Quality |
|-------|------|-----------------|---------|
| gemma-4-26B-A4B-it-UD-Q4_K_XL | 17 GB | Yes (with q8_0 KV) | Good |
| gemma-4-26B-A4B-it-UD-Q6_K_XL | 22 GB | Yes (tight) | Better |
| gemma-4-26B-A4B-it-Q8_0 | 27 GB | No (needs 2x GPU) | Best GGUF |

> **Note:** Gemma 4 requires upstream llama.cpp (not the turboquant fork). Use `build-llama.sh` with `https://github.com/ggml-org/llama.cpp` and branch `master`.

## Cleanup

```bash
# Interactive cleanup — prompts before each action
bash cleanup.sh

# Dry-run mode — shows what would be cleaned without making changes
bash cleanup.sh --dry-run
```

The cleanup script handles:
- Docker containers, images, volumes, and build cache
- Ollama models (preserves embedding/rerank models)
- GGUF model files
- HuggingFace download cache

It shows a summary of reclaimed space at the end.

## New API Gateway

[New API](https://github.com/QuantumNous/new-api) provides a unified OpenAI-compatible gateway with token management, usage tracking, and multi-backend support.

### Setup

```bash
# Initial setup (creates Docker containers, admin account, API token)
bash new-api.sh setup

# Add local llama-server as a channel
bash llama-server.sh start
bash new-api.sh add-channel

# Create additional API tokens
bash new-api.sh create-token
```

### Management

```bash
bash new-api.sh start          # Start gateway
bash new-api.sh stop           # Stop gateway
bash new-api.sh restart        # Restart gateway
bash new-api.sh status         # Health check + stats
bash new-api.sh logs           # View logs
bash new-api.sh list-channels  # Show configured channels
bash new-api.sh update         # Pull latest image and restart
```

### Usage via New API

```bash
# List available models
curl http://localhost:3000/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"

# Chat completion (proxied to local llama-server)
curl http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -d '{
    "model": "gemma-4-26B-A4B-Q4",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

The Web UI is available at `http://localhost:3000` for visual management of channels, tokens, and usage statistics.

## Cloudflare Tunnel (Public HTTPS Access)

Expose your New API to the internet via [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — zero open ports, automatic SSL, DDoS protection.

### Setup

```bash
# Interactive setup — installs cloudflared, configures tunnel, creates DNS record
bash cloudflared.sh setup
```

You'll need:
1. A **tunnel token** from [Cloudflare Zero Trust](https://one.dash.cloudflare.com) → Networks → Tunnels → Create
2. (Optional) A **Cloudflare API token** with DNS edit permissions for auto-creating DNS records

### Management

```bash
bash cloudflared.sh status     # connection status + reachability check
bash cloudflared.sh logs       # view tunnel logs
bash cloudflared.sh restart    # reconnect tunnel
bash cloudflared.sh stop       # stop tunnel
bash cloudflared.sh dns        # add/update DNS records
```

### Traffic Flow

```
Client → Cloudflare CDN (SSL) → Tunnel → localhost:3000 (New API) → localhost:8000 (llama-server)
```

## Troubleshooting

### "CUDA not found" after setup-cuda.sh
The CUDA PATH isn't in your current shell. Fix:
```bash
source /etc/profile.d/cuda.sh
# Or manually:
export PATH=/usr/local/cuda-12.8/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-12.8/lib64:${LD_LIBRARY_PATH:-}
```

### "hf command not found" after download-model.sh
If installed via `pip`, the command is `huggingface-cli`, not `hf`. The script handles both automatically. If PATH is the issue:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### NVIDIA driver disappears after reboot
Caused by kernel auto-upgrades without DKMS. Fixed by `setup-nvidia.sh` (installs DKMS and optionally blacklists kernel auto-upgrades).

### PCIe bottleneck on dual GPU
RTX 3090s connected via PCIe (not NVLink) limit decode speed to ~25 t/s regardless of model quantization.

### Gibberish output
Try `--cache-type-k bf16 --cache-type-v bf16` per Unsloth docs.

### Server won't start / out of VRAM
- Use a smaller model or lower quantization
- Reduce context size (e.g., `-c 32768` instead of 262144)
- Use `q4_0` or `turbo2` KV cache to reduce VRAM usage

## Known Issues

- **Default repo is a fork.** `build-llama.sh` defaults to `spiritbuun/llama-cpp-turboquant-cuda` for turbo KV cache support. Change to `https://github.com/ggml-org/llama.cpp` for upstream.
- **CUDA keyring version.** `setup-cuda.sh` uses `cuda-keyring_1.1-1_all.deb` which may need updating for future CUDA releases.
