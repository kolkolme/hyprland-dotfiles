#!/usr/bin/env bash
# Ставит прикладные программы: C++, VS Code, Steam, Telegram, Discord.
# Вызывается из install.sh, но работает и сам по себе:  ./apps.sh
set -uo pipefail          # без -e: одна упавшая программа не должна рушить остальные

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  •\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*"; }

OPT="$HOME/.local/opt"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
mkdir -p "$OPT" "$BIN" "$APPS"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

FAILED=()

# ─────────────────────────────────────────────── C++
say "C++: компилятор и инструменты"
if sudo apt-get install -y build-essential g++ gdb cmake make pkg-config >/dev/null 2>&1; then
    ok "g++ $(g++ -dumpversion 2>/dev/null), gdb, cmake, make"
else
    warn "не удалось"; FAILED+=("C++")
fi

# ─────────────────────────────────────────────── VS Code
say "VS Code"
if command -v code >/dev/null 2>&1; then
    ok "уже стоит: $(code --version 2>/dev/null | head -1)"
elif curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$TMP/ms.asc" 2>/dev/null; then
    gpg --dearmor < "$TMP/ms.asc" > "$TMP/microsoft.gpg" 2>/dev/null
    sudo install -D -o root -g root -m 644 "$TMP/microsoft.gpg" /etc/apt/keyrings/microsoft.gpg
    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/microsoft.gpg
EOF
    sudo apt-get update >/dev/null 2>&1
    if sudo apt-get install -y code >/dev/null 2>&1; then
        ok "поставлен из репозитория Microsoft"
    else
        warn "репозиторий добавлен, но пакет не встал"; FAILED+=("VS Code")
    fi
else
    warn "не скачался ключ Microsoft"; FAILED+=("VS Code")
fi

# ─────────────────────────────────────────────── Steam
say "Steam"
if command -v steam >/dev/null 2>&1; then
    ok "уже стоит"
else
    # Steam 32-битный, без архитектуры i386 не поставится
    dpkg --print-foreign-architectures | grep -qx i386 || {
        sudo dpkg --add-architecture i386 && ok "включил архитектуру i386"
        sudo apt-get update >/dev/null 2>&1
    }
    grep -rqi 'non-free' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null \
        || warn "в репозиториях нет non-free — Steam может не найтись"
    if sudo apt-get install -y steam-installer >/dev/null 2>&1; then
        ok "поставлен (докачает себя сам при первом запуске)"
    else
        warn "не удалось"; FAILED+=("Steam")
    fi
fi

# ─────────────────────────────────────────────── Telegram
say "Telegram Desktop"
if [ -x "$OPT/Telegram/Telegram" ]; then
    ok "уже стоит"
elif curl -fsSL "https://telegram.org/dl/desktop/linux" -o "$TMP/tg.tar.xz" 2>/dev/null; then
    if tar xJf "$TMP/tg.tar.xz" -C "$OPT" 2>/dev/null; then
        ln -sf "$OPT/Telegram/Telegram" "$BIN/telegram-desktop"
        cat > "$APPS/telegramdesktop.desktop" <<EOF
[Desktop Entry]
Name=Telegram Desktop
Comment=Официальный клиент Telegram
Exec=$OPT/Telegram/Telegram -- %u
Icon=telegram
Type=Application
Categories=Network;InstantMessaging;Chat;
MimeType=x-scheme-handler/tg;
StartupWMClass=TelegramDesktop
Terminal=false
EOF
        ok "в ~/.local/opt/Telegram, ярлык и команда telegram-desktop созданы"
    else
        warn "архив не распаковался"; FAILED+=("Telegram")
    fi
else
    warn "не скачался"; FAILED+=("Telegram")
fi

# ─────────────────────────────────────────────── Discord
say "Discord"
if [ -x "$OPT/Discord/discord" ]; then
    ok "уже стоит"
elif curl -fsSL "https://discord.com/api/download?platform=linux&format=tar.gz" -o "$TMP/dc.tar.gz" 2>/dev/null; then
    if tar xzf "$TMP/dc.tar.gz" -C "$OPT" 2>/dev/null; then
        ln -sf "$OPT/Discord/discord" "$BIN/discord"
        # свой ярлык: в комплектном Exec прописан /usr/bin/discord, а мы ставим в ~/.local/opt
        cat > "$APPS/discord.desktop" <<EOF
[Desktop Entry]
Name=Discord
Comment=Голосовой и текстовый чат
Exec=$OPT/Discord/discord --url -- %u
Icon=$OPT/Discord/discord.png
Type=Application
Categories=Network;InstantMessaging;
MimeType=x-scheme-handler/discord;
StartupWMClass=discord
Terminal=false
EOF
        ok "в ~/.local/opt/Discord, ярлык и команда discord созданы"
    else
        warn "архив не распаковался"; FAILED+=("Discord")
    fi
else
    warn "не скачался"; FAILED+=("Discord")
fi

update-desktop-database "$APPS" >/dev/null 2>&1 || true

say "Программы: готово"
if [ ${#FAILED[@]} -gt 0 ]; then
    warn "не установились: ${FAILED[*]}"
    echo "     Запусти ./apps.sh ещё раз — уже поставленное пропустится."
fi
