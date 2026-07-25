update () 
{ 
    sudo -v || return 1;
    echo "━━━ [1/6] apt update (refresh package lists) ━━━";
    sudo apt update || return 1;
    echo "━━━ [2/6] available upgrades ━━━";
    apt list --upgradable 2> /dev/null;
    echo "━━━ [3/6] apt full-upgrade (handles dependency changes too) ━━━";
    sudo apt full-upgrade -y || return 1;
    echo "━━━ [4/6] autoremove (purge orphaned packages + their configs) ━━━";
    sudo apt autoremove --purge -y;
    echo "━━━ [5/6] clean apt cache (frees /var/cache/apt/archives) ━━━";
    sudo apt clean;
    echo "━━━ [6/6] npm global packages ━━━";
    if command -v npm > /dev/null; then
        outdated=$(npm outdated -g --parseable 2> /dev/null);
        if [ -n "$outdated" ]; then
            echo "Outdated packages found, updating...";
            npm update -g;
        else
            echo "All npm globals up to date.";
        fi;
    fi;
    echo "";
    echo "✅ System updated.";
    df -h / | awk 'NR<=2'
}
