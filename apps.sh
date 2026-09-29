#!/usr/bin/env bash
# Ставит прикладные программы: C++, VS Code, Steam, Telegram, Discord.
# Вызывается из install.sh, но работает и сам по себе:  ./apps.sh
set -uo pipefail          # без -e: одна упавшая программа не должна рушить остальные

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  •\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*"; }

. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown}"
CODENAME="${VERSION_CODENAME:-}"

# Никаких диалогов, ждущих ответа в тишине
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
LOG="${LOG:-$HOME/.dotfiles-apps.log}"
: > "$LOG"

# Пароль sudo протухает за 15 минут, а запрос печатается в stderr.
# Если stderr уведён в лог — запрос не видно, и скрипт молча ждёт ввода.
# Поэтому спрашиваем видимо, перед каждым шагом, который требует root.
need_sudo() {
    sudo -n true 2>/dev/null && return 0
    echo "   Нужен пароль sudo:"
    sudo -v
}

# apt печатает и в терминал, и в лог. Ничего невидимого больше нет.
apt_install() {
    need_sudo || return 1
    sudo -E apt-get install -y --no-install-recommends "$@" 2>&1 | tee -a "$LOG"
}

OPT="$HOME/.local/opt"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
mkdir -p "$OPT" "$BIN" "$APPS"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

FAILED=()

# ─────────────────────────────────────────────── C++
say "C++: компилятор и инструменты"
echo "   Качается около 200 МБ, это несколько минут."
if apt_install build-essential g++ gdb cmake make pkg-config; then
    ok "g++ $(g++ -dumpversion 2>/dev/null), gdb, cmake, make"
else
    warn "не удалось"; FAILED+=("C++")
fi

# ─────────────────────────────────────────────── VS Code
say "VS Code"
if command -v code >/dev/null 2>&1; then
    ok "уже стоит: $(code --version 2>/dev/null | head -1)"
elif curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$TMP/ms.asc" 2>/dev/null; then
    # Без gpg: apt понимает ключ в текстовом виде, если файл .asc.
    # В чистом Debian команды gpg просто нет, и раньше здесь молча
    # получался пустой ключ, а репозиторий выходил неподписанным.
    if [ ! -s "$TMP/ms.asc" ]; then
        warn "ключ Microsoft скачался пустым"; FAILED+=("VS Code")
    else
    need_sudo && sudo install -D -o root -g root -m 644 "$TMP/ms.asc" /etc/apt/keyrings/microsoft.asc
    sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64
Signed-By: /etc/apt/keyrings/microsoft.asc
EOF
    need_sudo && sudo -E apt-get update 2>&1 | tail -2 | tee -a "$LOG"
    if apt_install code; then
        ok "поставлен из репозитория Microsoft"
    else
        warn "репозиторий добавлен, но пакет не встал"; FAILED+=("VS Code")
    fi
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
    case " $(dpkg --print-foreign-architectures 2>/dev/null) " in *" i386 "*) : ;; *)
        need_sudo && sudo dpkg --add-architecture i386 && ok "включил архитектуру i386"
        need_sudo && sudo -E apt-get update 2>&1 | tail -2 | tee -a "$LOG"
        ;;
    esac
    grep -rqi 'non-free' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null \
        || warn "в репозиториях нет non-free — Steam может не найтись"
    # Steam показывает лицензию и ждёт согласия — отвечаем заранее,
    # иначе установка встаёт на невидимом диалоге
    printf 'steam steam/question select I AGREE\nsteam steam/license note\n' \
        | sudo debconf-set-selections 2>/dev/null || true
    echo "   Steam тянет много 32-битных библиотек, это долго."
    # Hyprland уже притянул 64-битную Mesa из backports, а 32-битная
    # по умолчанию берётся из main — версии не сходятся, и Steam не встаёт.
    # Просим обе из backports.
    STEAM_T=()
    if [ "$DISTRO" = "debian" ]; then
        [ -n "$CODENAME" ] && STEAM_T=(-t "$CODENAME-backports")
    fi
    need_sudo
    if sudo -E apt-get install -y "${STEAM_T[@]}" steam-installer 2>&1 | tee -a "$LOG" >/dev/null; then
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

say "Проверяю программы"
for c in g++ code steam; do
    command -v "$c" >/dev/null 2>&1 && ok "$c" \
        || { printf '\033[1;31m  ✗\033[0m %s\n' "$c"; FAILED+=("$c"); }
done
[ -x "$OPT/Telegram/Telegram" ] && ok "Telegram" || { printf '\033[1;31m  ✗\033[0m Telegram\n'; FAILED+=("Telegram"); }
[ -x "$OPT/Discord/discord" ]   && ok "Discord"  || { printf '\033[1;31m  ✗\033[0m Discord\n';  FAILED+=("Discord"); }

if [ ${#FAILED[@]} -gt 0 ]; then
    echo
    warn "НЕ УСТАНОВИЛИСЬ: ${FAILED[*]}"
    echo "     Подробности: $LOG"
    tail -12 "$LOG" 2>/dev/null | sed 's/^/       /'
    echo "     Запусти ./apps.sh ещё раз — уже поставленное пропустится."
    exit 1
fi
say "Программы: все на месте"
