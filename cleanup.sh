#!/usr/bin/env bash
# Cleanup disk space: Docker, old models, ollama
# NOTE: No set -e — cleanup scripts should be resilient and continue on individual failures
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Cleanup script uses its own error handling (no set -e, no ERR trap)
trap '_default_cleanup' EXIT
trap 'log_warn "Interrupted"; exit 130' INT TERM

# Dry-run mode
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
    log_info "DRY RUN MODE — no changes will be made"
    echo ""
fi

# Track total space reclaimed
INITIAL_AVAIL=$(get_avail_gb "/")
RECLAIMED_ITEMS=()

run_or_dry() {
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would execute: $*"
    else
        "$@"
    fi
}

echo "=== Disk Cleanup ==="
echo ""
echo "Disk: $(get_disk_status)"
echo ""

# Docker cleanup
if command -v docker &>/dev/null; then
    echo "--- Docker ---"
    docker system df 2>/dev/null || log_warn "Docker daemon may not be running"
    echo ""

    # Stopped containers
    STOPPED=$(docker ps -a --filter "status=exited" --format "{{.ID}} {{.Names}} ({{.Image}}, {{.Status}})" 2>/dev/null || true)
    if [[ -n "$STOPPED" ]]; then
        echo "Stopped containers:"
        while IFS= read -r line; do echo "  $line"; done <<< "$STOPPED"
        echo ""
        if confirm "Remove stopped containers?" "N"; then
            run_or_dry docker container prune -f
            RECLAIMED_ITEMS+=("Docker containers")
        fi
    fi

    # Dangling images
    if confirm "Remove unused Docker images?" "N"; then
        run_or_dry docker image prune -a -f
        RECLAIMED_ITEMS+=("Docker images")
    fi

    # Build cache — use --format for reliable parsing
    BUILD_CACHE=$(docker system df --format '{{.Reclaimable}}' 2>/dev/null | tail -1 || true)
    if [[ -n "$BUILD_CACHE" && "$BUILD_CACHE" != "0B" && "$BUILD_CACHE" != "0 B" ]]; then
        if confirm "Remove Docker build cache ($BUILD_CACHE reclaimable)?" "N"; then
            run_or_dry docker builder prune -f
            RECLAIMED_ITEMS+=("Docker build cache")
        fi
    fi

    # Unused volumes
    UNUSED_VOLS=$(docker volume ls -q --filter dangling=true 2>/dev/null | wc -l || echo 0)
    if [[ "$UNUSED_VOLS" -gt 0 ]]; then
        if confirm "Remove $UNUSED_VOLS unused Docker volumes?" "N"; then
            run_or_dry docker volume prune -f
            RECLAIMED_ITEMS+=("Docker volumes")
        fi
    fi

    # Warn about New API containers (don't auto-remove)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api'; then
        echo ""
        log_info "New API containers detected (new-api, new-api-postgres, new-api-redis)"
        log_info "To remove: bash new-api.sh stop && docker compose -f ~/new-api/docker-compose.yml down -v"
    fi
    echo ""
fi

# Ollama models
if command -v ollama &>/dev/null; then
    echo "--- Ollama Models ---"
    OLLAMA_MODELS=$(ollama list 2>/dev/null | tail -n +2 || true)
    if [[ -n "$OLLAMA_MODELS" ]]; then
        echo "$OLLAMA_MODELS"
        echo ""
        echo "Models with 'embed' or 'rerank' in the name will be kept."
        if confirm "Remove non-embedding/rerank ollama models?" "N"; then
            while read -r NAME REST; do
                if echo "$NAME" | grep -qiE 'embed|rerank|bge'; then
                    echo "  KEEP: $NAME"
                else
                    echo "  REMOVE: $NAME"
                    run_or_dry ollama rm "$NAME" 2>/dev/null || true
                    RECLAIMED_ITEMS+=("Ollama model: $NAME")
                fi
            done <<< "$OLLAMA_MODELS"
        fi
    else
        echo "No ollama models found"
    fi
    echo ""
fi

# Large GGUF files
echo "--- GGUF Model Files ---"
GGUF_FILES=$(find "$HOME" -name "*.gguf" -size +100M 2>/dev/null | grep -v vocab | sort || true)
if [[ -n "$GGUF_FILES" ]]; then
    while IFS= read -r f; do
        SIZE=$(format_file_size "$f")
        echo "  $SIZE  $f"
    done <<< "$GGUF_FILES"
    echo ""
    read -r -p "Delete any GGUF files? Enter path or 'skip': " DEL_GGUF
    while [[ "$DEL_GGUF" != "skip" && -n "$DEL_GGUF" ]]; do
        # Validate it's actually a .gguf file
        if [[ "$DEL_GGUF" != *.gguf ]]; then
            log_warn "Not a .gguf file. Skipping for safety: $DEL_GGUF"
        elif [[ -f "$DEL_GGUF" ]]; then
            DEL_SIZE=$(format_file_size "$DEL_GGUF")
            run_or_dry rm -v "$DEL_GGUF"
            RECLAIMED_ITEMS+=("GGUF file: $(basename "$DEL_GGUF") ($DEL_SIZE)")
        else
            log_warn "File not found: $DEL_GGUF"
        fi
        read -r -p "Delete another? Enter path or 'skip': " DEL_GGUF
    done
else
    echo "No large GGUF files found"
fi

# HuggingFace cache
echo ""
echo "--- HuggingFace Cache ---"
HF_CACHE_FOUND=false
for cache_dir in "${HF_HOME:-$HOME/.cache/huggingface}/hub" "${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub" "$HOME/.cache/huggingface/hub"; do
    if [[ -d "$cache_dir" ]]; then
        CACHE_SIZE=$(du -sh "$cache_dir" 2>/dev/null | awk '{print $1}')
        echo "  $cache_dir: $CACHE_SIZE"
        HF_CACHE_FOUND=true
    fi
done
# Only check /root paths if running as root
if [[ "$EUID" -eq 0 && -d "/root/.cache/huggingface/hub" ]]; then
    CACHE_SIZE=$(du -sh "/root/.cache/huggingface/hub" 2>/dev/null | awk '{print $1}')
    echo "  /root/.cache/huggingface/hub: $CACHE_SIZE"
    HF_CACHE_FOUND=true
fi

if [[ "$HF_CACHE_FOUND" == true ]]; then
    echo ""
    if confirm "Clean HuggingFace download cache?" "N"; then
        if command -v huggingface-cli &>/dev/null; then
            run_or_dry huggingface-cli cache purge --yes 2>/dev/null || true
            RECLAIMED_ITEMS+=("HuggingFace cache")
        elif command -v hf &>/dev/null; then
            run_or_dry hf cache purge --yes 2>/dev/null || true
            RECLAIMED_ITEMS+=("HuggingFace cache")
        else
            log_warn "HuggingFace CLI not found. Remove cache manually:"
            echo "  rm -rf ~/.cache/huggingface/hub/models--*/.cache"
        fi
    fi
else
    echo "  No HuggingFace cache found"
fi

# Summary
echo ""
echo "=== Cleanup Summary ==="
FINAL_AVAIL=$(get_avail_gb "/")
RECLAIMED=$((FINAL_AVAIL - INITIAL_AVAIL))

if [[ ${#RECLAIMED_ITEMS[@]} -gt 0 ]]; then
    echo "Actions taken:"
    for item in "${RECLAIMED_ITEMS[@]}"; do
        echo "  ✓ $item"
    done
    echo ""
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY RUN — no actual changes were made."
else
    if [[ "$RECLAIMED" -gt 0 ]]; then
        log_success "Reclaimed approximately ${RECLAIMED}GB of disk space"
    fi
fi

echo ""
echo "=== Final disk status ==="
echo "Disk: $(get_disk_status)"
