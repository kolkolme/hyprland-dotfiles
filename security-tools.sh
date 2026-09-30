#!/usr/bin/env bash
# Инструменты безопасности из набора Kali — работает и на Kali, и на Debian.
#
# ВАЖНО: репозитории Kali сюда НЕ подключаются. Kali собрана на базе
# Debian testing/sid, и подключение её репозиториев к обычному Debian
# ломает систему — об этом пишет и сама команда Kali. Поэтому то, чего
# в Debian нет, ставится из официальных источников самих разработчиков.
set -uo pipefail

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  •\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*"; }

. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown}"
OPT="$HOME/.local/opt"; BIN="$HOME/.local/bin"
mkdir -p "$OPT" "$BIN"
LOG="$HOME/.dotfiles-security.log"; : > "$LOG"
export DEBIAN_FRONTEND=noninteractive
FAILED=()      # то, без чего набор считается несобранным
OPTIONAL=()    # необязательное: недоступно на этом дистрибутиве или не собралось

# При set -o pipefail конструкция `cmd | grep -q` ложно падает:
# grep -q закрывает канал по первому совпадению, cmd получает SIGPIPE,
# и весь конвейер считается упавшим, хотя совпадение было.
# Поэтому нигде ниже не используем grep -q в конвейере.
pkg_available() {
    local out
    out="$(apt-cache policy "$1" 2>/dev/null)" || return 1
    case "$out" in
        *"Candidate: (none)"*) return 1 ;;
        *Candidate:*)          return 0 ;;
        *)                     return 1 ;;
    esac
}
need_sudo() { sudo -n true 2>/dev/null && return 0; echo "   Нужен пароль sudo:"; sudo -v; }

# Ставит только то, что реально есть в подключённых репозиториях.
apt_some() {
    local avail=() p
    for p in "$@"; do
        pkg_available "$p" && avail+=("$p")
    done
    [ ${#avail[@]} -eq 0 ] && return 1
    need_sudo || return 1
    sudo -E apt-get install -y "${avail[@]}" 2>&1 | tee -a "$LOG" >/dev/null
    ok "из репозиториев: ${avail[*]}"
}

# git-инструмент: клонируем и делаем команду в ~/.local/bin
git_tool() {   # git_tool <имя> <url> <файл-точка-входа>
    local name="$1" url="$2" entry="$3"
    if [ -d "$OPT/$name" ]; then ok "$name уже есть"; return 0; fi
    if git clone --depth 1 "$url" "$OPT/$name" >>"$LOG" 2>&1; then
        [ -n "$entry" ] && [ -f "$OPT/$name/$entry" ] && {
            chmod +x "$OPT/$name/$entry"; ln -sf "$OPT/$name/$entry" "$BIN/$name"; }
        ok "$name → ~/.local/opt/$name"
    else
        warn "$name не склонировался"; OPTIONAL+=("$name")
    fi
}

say "Дистрибутив: ${PRETTY_NAME:-$DISTRO}"

# ─────────────────────────────── что есть в обоих дистрибутивах
say "Инструменты из репозиториев"
# dnsutils переименован в bind9-dnsutils; недоступные имена apt_some отсеет сам
apt_some nmap wireshark tcpdump aircrack-ng hydra john hashcat sqlmap \
         binwalk foremost gobuster dirb wfuzz ffuf masscan recon-ng \
         netcat-openbsd socat smbclient whois bind9-dnsutils dnsutils nikto

if [ "$DISTRO" = "kali" ]; then
    say "Kali: остальное тоже в репозиториях"
    apt_some metasploit-framework burpsuite netexec responder \
             seclists exploitdb wpscan enum4linux theharvester
    say "Готово"
    exit 0
fi

# ─────────────────────────────── Debian: чего нет — из официальных источников
say "Debian: ставлю то, чего нет в репозиториях, из официальных источников"
warn "репозитории Kali НЕ подключаю — они ломают обычный Debian"

# netexec собирает нативные расширения: нужны заголовки Python и Rust,
# иначе pipx падает на "Python.h: No such file" и "can't find Rust compiler"
need_sudo && sudo -E apt-get install -y git curl pipx ruby ruby-dev build-essential \
    python3-dev libffi-dev libssl-dev pkg-config rustc cargo \
    perl libwww-perl libnet-ssleay-perl >>"$LOG" 2>&1
pipx ensurepath >>"$LOG" 2>&1 || true

say "netexec и theHarvester (через pipx)"
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
for spec in "netexec:git+https://github.com/Pennyw0rth/NetExec" \
            "theharvester:git+https://github.com/laramies/theHarvester"; do
    n="${spec%%:*}"; u="${spec#*:}"
    if command -v "$n" >/dev/null 2>&1; then ok "$n уже есть"; continue; fi
    # одна повторная попытка: сборка тянет зависимости с GitHub,
    # и случайный сбой сети не должен выглядеть как поломка
    if pipx install "$u" >>"$LOG" 2>&1 || { sleep 5; pipx install "$u" >>"$LOG" 2>&1; }; then
        ok "$n"
    elif grep -q "requires a different Python" "$LOG" 2>/dev/null; then
        warn "$n требует более свежий Python, чем $PYV в этой системе — пропускаю"
        OPTIONAL+=("$n (нужен Python новее $PYV)")
    else
        warn "$n не собрался"; OPTIONAL+=("$n")
    fi
done

say "Инструменты с GitHub"
git_tool responder   https://github.com/lgandx/Responder            Responder.py
git_tool enum4linux  https://github.com/CiscoCXSecurity/enum4linux  enum4linux.pl

say "exploitdb (searchsploit)"
if [ -d "$OPT/exploitdb" ]; then ok "уже есть"
elif git clone --depth 1 https://gitlab.com/exploit-database/exploitdb "$OPT/exploitdb" >>"$LOG" 2>&1; then
    ln -sf "$OPT/exploitdb/searchsploit" "$BIN/searchsploit"; ok "searchsploit готов"
else warn "не склонировался"; OPTIONAL+=("exploitdb"); fi

say "wpscan (ruby gem)"
if command -v wpscan >/dev/null 2>&1; then ok "уже есть"
elif gem install --user-install wpscan >>"$LOG" 2>&1; then ok "wpscan"
else warn "не встал — нужен ruby-dev"; OPTIONAL+=("wpscan"); fi

say "metasploit-framework (официальный установщик Rapid7)"
if command -v msfconsole >/dev/null 2>&1; then ok "уже есть"
else
    T=$(mktemp -d)
    if curl -fsSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb \
         -o "$T/msfinstall" 2>>"$LOG"; then
        chmod +x "$T/msfinstall"
        need_sudo && sudo "$T/msfinstall" >>"$LOG" 2>&1 && ok "metasploit" \
            || { warn "metasploit не встал"; OPTIONAL+=("metasploit"); }
    else warn "установщик не скачался"; OPTIONAL+=("metasploit"); fi
    rm -rf "$T"
fi

say "SecLists (словари, около 1 ГБ)"
if [ -d "$OPT/seclists" ]; then ok "уже есть"
elif git clone --depth 1 https://github.com/danielmiessler/SecLists "$OPT/seclists" >>"$LOG" 2>&1; then
    mkdir -p "$HOME/.local/share"; ln -sfn "$OPT/seclists" "$HOME/.local/share/seclists"
    ok "в ~/.local/opt/seclists"
else warn "не склонировался"; OPTIONAL+=("seclists"); fi

say "Burp Suite"
warn "ставится вручную: у PortSwigger лицензионное соглашение в установщике"
echo "     https://portswigger.net/burp/communitydownload"

say "Проверяю инструменты"
# john и ряд других ставятся в /usr/sbin, а его нет в PATH обычного
# пользователя — command -v их не находит, хотя пакет установлен
have_tool() {
    command -v "$1" >/dev/null 2>&1 && return 0
    for d in /usr/sbin /sbin /usr/local/sbin; do
        [ -x "$d/$1" ] && return 0
    done
    return 1
}
for c in nmap sqlmap hydra john hashcat aircrack-ng; do
    have_tool "$c" && ok "$c" \
        || { printf '\033[1;31m  ✗\033[0m %s\n' "$c"; FAILED+=("$c"); }
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo
    warn "НЕ УСТАНОВИЛИСЬ: ${FAILED[*]}"
    echo "     Подробности: $LOG. Повторный запуск пропустит готовое."
    exit 1
fi
say "Инструменты: базовый набор на месте"
if [ ${#OPTIONAL[@]} -gt 0 ]; then
    echo
    warn "Необязательное, чего нет на этой системе: ${OPTIONAL[*]}"
    echo "     Остальное работает. Повторный запуск попробует их снова."
fi
echo
echo "   Команды из ~/.local/bin: responder, enum4linux, searchsploit"
echo "   Словари SecLists: ~/.local/share/seclists"
