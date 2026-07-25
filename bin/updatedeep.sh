updatedeep () 
{ 
    update || return 1;
    echo "";
    echo "━━━ [+] Docker prune (dangling images, stopped containers, unused networks) ━━━";
    command -v docker > /dev/null && docker system prune -f;
    echo "";
    echo "━━━ [+] Ollama version check ━━━";
    if command -v ollama > /dev/null; then
        current=$(ollama --version 2> /dev/null | grep -oP '\d+\.\d+\.\d+' | head -1);
        latest=$(curl -fsSL https://api.github.com/repos/ollama/ollama/releases/latest | grep -oP '"tag_name":\s*"v\K[^"]+');
        echo "Installed: $current";
        echo "Latest:    $latest";
        if [ "$current" != "$latest" ] && [ -n "$latest" ]; then
            echo "→ Upgrading Ollama...";
            curl -fsSL https://ollama.com/install.sh | sh;
            sudo systemctl daemon-reload;
            sudo systemctl restart ollama;
        else
            echo "→ Ollama is up to date, skipping.";
        fi;
    fi;
    echo "";
    AI_STACK_DIR="$HOME/ai-stack";
    if [ -f "$AI_STACK_DIR/docker-compose.yml" ] && command -v docker > /dev/null && docker info > /dev/null 2>&1; then
        echo "━━━ [+] AI stack — pull pinned images + recreate if needed ━━━";
        ( cd "$AI_STACK_DIR" && docker compose pull && docker compose up -d );
        echo "";
        echo "━━━ [i] Pinned image update check (informational, no auto-upgrade) ━━━";
        function check_gh_release () 
        { 
            local name="$1" repo="$2" current="$3";
            local cur_clean="${current##*@}";
            cur_clean="${cur_clean#v}";
            local cur_major="${cur_clean%%.*}";
            local releases;
            releases=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=50" 2> /dev/null | jq -r --arg maj "$cur_major" '
                           [.[]
                             | select(.prerelease==false and .draft==false)
                             | .tag_name
                             | sub("^.*@"; "")
                             | sub("^v"; "")
                             | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                           ]
                           | (map(select(startswith($maj + "."))) | .[0]) as $same
                           | .[0] as $any
                           | "\($same // "none")|\($any // "none")"
                         ' 2> /dev/null);
            local same_major="${releases%|*}";
            local any_major="${releases#*|}";
            if [ -z "$same_major" ] || [ "$same_major" = "null" ] || [ "$same_major" = "none" ]; then
                echo "  ? $name: could not check (rate-limited or parse failed)";
                return;
            fi;
            if [ "$cur_clean" != "$same_major" ]; then
                echo "  ⚠ $name: pinned $cur_clean → latest in $cur_major.x is $same_major  (review changelog)";
            else
                echo "  ✓ $name: $cur_clean (up to date in $cur_major.x)";
            fi;
            local any_major_num="${any_major%%.*}";
            if [ -n "$any_major" ] && [ "$any_major" != "none" ] && [ "$any_major_num" -gt "$cur_major" ] 2> /dev/null; then
                echo "       ⚡ NEW MAJOR available: $any_major  (breaking changes — read migration guide before upgrading)";
            fi
        };
        owui_tag=$(grep -oP 'open-webui:\K[v0-9.]+' "$AI_STACK_DIR/docker-compose.yml" | head -1);
        n8n_tag=$(grep -oP 'n8nio/n8n:\K[0-9.]+' "$AI_STACK_DIR/docker-compose.yml" | head -1);
        [ -n "$owui_tag" ] && check_gh_release "Open WebUI" "open-webui/open-webui" "$owui_tag";
        [ -n "$n8n_tag" ] && check_gh_release "n8n" "n8n-io/n8n" "$n8n_tag";
        echo "";
    fi;
    echo "━━━ [+] AI stack health ━━━";
    if command -v systemctl > /dev/null; then
        printf "  Ollama service: ";
        systemctl is-active ollama 2> /dev/null || echo "inactive";
    fi;
    if command -v ollama > /dev/null; then
        echo "  Models loaded in VRAM:";
        ollama ps 2> /dev/null | tail -n +2 | awk '{printf "    %s (%s, %s)\n", $1, $4, $5}';
    fi;
    if command -v docker > /dev/null && docker info > /dev/null 2>&1; then
        echo "  Containers:";
        docker ps --format '    {{.Names}} — {{.Status}}' | grep --color=auto -E 'open-webui|n8n|ollama-keepalive|searxng' || echo "    (none running)";
    fi;
    if command -v nvidia-smi > /dev/null; then
        echo "  GPU:";
        nvidia-smi --query-gpu=memory.used,memory.free,utilization.gpu --format=csv,noheader | awk -F', ' '{printf "    VRAM used: %s | free: %s | GPU util: %s\n", $1, $2, $3}';
    fi;
    echo "";
    echo "✅ Deep clean complete."
}
