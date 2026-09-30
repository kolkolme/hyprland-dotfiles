#!/usr/bin/env bash
# Разворачивает рабочий стол Hyprland: пакеты, конфиги, самописные утилиты.
# Рассчитан на чистую Kali (или другой Debian-based дистрибутив).
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.dotfiles-backup-$STAMP"

say()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m [!]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  •\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- проверки
[ "$(id -u)" -eq 0 ] && { echo "Не запускай от root — запусти от своего пользователя."; exit 1; }
command -v apt-get >/dev/null || { echo "Нужен apt (Debian/Kali/Ubuntu)."; exit 1; }

say "Установка рабочего стола из $SRC"
echo "   Пользователь: $USER"
echo "   Домашняя:     $HOME"
echo "   Бэкап старых конфигов уйдёт в: $BACKUP"
read -rp $'\nПродолжить? [y/N] ' a; [[ "$a" =~ ^[Yy]$ ]] || exit 0

# ---------------------------------------------------------------- пакеты
say "Ставлю пакеты"

# ---- доступны ли репозитории по HTTP ----
# В некоторых сетях порт 80 закрыт, а в sources.list у Debian по умолчанию
# именно http://. Тогда apt не может скачать ни одного пакета, а сообщение
# «Unable to connect ... :http» теряется среди сотен строк вывода.
# Проверяем заранее и при необходимости переключаем на HTTPS.
# || true обязателен: при set -e неудача подстановки убивает скрипт,
# а grep возвращает ненулевой код и когда ничего не нашёл, и когда
# шаблон *.list ни на что не раскрылся. Плюс head закрывает канал,
# и grep получает SIGPIPE, что при pipefail тоже считается провалом.
MIRROR_HOST="$(grep -rhoE 'https?://[^/ ]+' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
    | head -1 || true)"
if [ -n "$MIRROR_HOST" ] && [ "${MIRROR_HOST#http://}" != "$MIRROR_HOST" ]; then
    H="${MIRROR_HOST#http://}"
    if ! timeout 10 bash -c "echo > /dev/tcp/$H/80" 2>/dev/null; then
        warn "порт 80 закрыт — apt по HTTP работать не сможет"
        if timeout 10 bash -c "echo > /dev/tcp/$H/443" 2>/dev/null; then
            echo "   HTTPS доступен. Переключаю репозитории на него."
            sudo sed -i 's|http://|https://|g' /etc/apt/sources.list 2>/dev/null || true
            for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                [ -f "$f" ] && sudo sed -i 's|http://|https://|g' "$f" 2>/dev/null || true
            done
            ok "репозитории переведены на HTTPS"
        else
            warn "и HTTPS недоступен — проверь интернет или прокси"
        fi
    fi
fi

# ---- не занят ли apt ----
# Если другой apt уже работает (обновление в фоне, открытый «Менеджер
# приложений»), наш получит отказ по блокировке на каждом пакете и
# отрапортует «не встал» семьдесят раз подряд. Причина при этом
# потеряется среди вывода. Лучше сказать прямо и подождать.
for i in $(seq 1 60); do
    if sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || sudo lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        [ "$i" = 1 ] && warn "apt сейчас занят другим процессом, жду освобождения..."
        sleep 5
    else
        break
    fi
done
if sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo
    warn "apt занят уже пять минут. Кто его держит:"
    sudo fuser -v /var/lib/dpkg/lock-frontend 2>&1 | tail -3 | sed 's/^/     /'
    echo "   Закрой менеджер приложений или дождись фонового обновления,"
    echo "   потом запусти установщик заново."
    exit 1
fi

# ---- какой это дистрибутив ----
. /etc/os-release 2>/dev/null || true
DISTRO="${ID:-unknown}"
CODENAME="${VERSION_CODENAME:-}"
ok "дистрибутив: ${PRETTY_NAME:-$DISTRO}"

if [ "$DISTRO" = "debian" ]; then
    # В Debian весь Hyprland лежит не в main, а в backports.
    # Без них install провалится на шести пакетах сразу.
    if [ -n "$CODENAME" ] && ! grep -rq "$CODENAME-backports" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        echo "deb http://deb.debian.org/debian $CODENAME-backports main contrib non-free" \
            | sudo tee /etc/apt/sources.list.d/backports.list >/dev/null
        ok "подключил $CODENAME-backports (там лежит Hyprland)"
    fi
    # Steam и часть прошивок живут в contrib/non-free
    if ! grep -rqE '^[^#]*\bnon-free\b' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        warn "в репозиториях нет contrib/non-free — Steam и часть прошивок не поставятся"
        warn "добавь их в /etc/apt/sources.list и запусти скрипт заново"
    fi
fi

# Пароль спрашиваем один раз, заранее и явно. Иначе sudo спросит его
# посреди установки, и если вывод куда-то перенаправлен — запрос не видно,
# и всё выглядит как зависший скрипт.
# sudo -v не годится как проверка: он всегда пытается обновить метку
# времени и, если хоть одно правило требует пароль, просит терминал —
# даже когда обычный sudo прекрасно работает без него.
need_sudo() {
    sudo -n true 2>/dev/null && return 0
    echo "   Нужен пароль sudo:"
    sudo -v
}
if ! need_sudo; then
    warn "не удалось получить sudo заранее"
    warn "пароль спросят при первой же команде, требующей root"
fi

# Ни один пакет не должен открыть диалог и ждать ответа в тишине.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# sddm спрашивает, какой менеджер входа сделать основным — отвечаем заранее
echo "sddm shared/default-x-display-manager select sddm" | sudo debconf-set-selections 2>/dev/null || true

LOG="$BACKUP/apt.log"; mkdir -p "$BACKUP"

# Индексы обновляем ДО отбора пакетов: backports подключили только что,
# и без update отбор посчитал бы весь Hyprland несуществующим.
echo "   Обновляю списки пакетов..."
sudo -E apt-get update 2>&1 | tail -2

mapfile -t ALL_PKGS < <(grep -vE '^\s*(#|$)' "$SRC/packages.txt")
# Отсеиваем то, чего в этих репозиториях нет: иначе один отсутствующий
# пакет роняет всю групповую установку в медленный поштучный режим.
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
PKGS=(); SKIPPED=()
for p in "${ALL_PKGS[@]}"; do
    if pkg_available "$p"; then
        PKGS+=("$p")
    else
        SKIPPED+=("$p")
    fi
done
[ ${#SKIPPED[@]} -gt 0 ] && warn "нет в репозиториях, пропускаю: ${SKIPPED[*]}"
# Сначала пробуем поставить всё одной командой — так быстрее и apt
# сам разрулит зависимости. Если упадёт, разбираем по одному.
MISSING=()
echo "   Пакетов к установке: ${#PKGS[@]}. Полный лог: $LOG"
# На Debian ставим ВСЁ одной командой с -t backports.
# Иначе выходит так: Hyprland из backports тянет свежий libxkbcommon0,
# а waybar и pipewire из main требуют старый — apt упирается в
# «held broken packages» и они не встают. С -t apt подбирает
# согласованный набор: что нужно берёт из backports, остальное из main.
APT_T=()
if [ "$DISTRO" = "debian" ] && [ -n "$CODENAME" ]; then
    APT_T=(-t "$CODENAME-backports")
    echo "   Debian: там, где нужно, беру версии из $CODENAME-backports"
fi

echo "   Это несколько минут. Ниже идёт вывод apt — так видно, что работа идёт."
if sudo -E apt-get install -q -y --no-install-recommends "${APT_T[@]}" "${PKGS[@]}" 2>&1 | tee -a "$LOG"; then
    ok "все ${#PKGS[@]} пакетов"
else
    warn "пакетом не вышло, ставлю по одному (так видно, что именно ломается)"
    for p in "${PKGS[@]}"; do
        # пароль мог протухнуть за время долгой установки — спрашиваем видимо
        sudo -n true 2>/dev/null || { echo "   Нужен пароль sudo:"; sudo -v; }
        if sudo -E apt-get install -q -y --no-install-recommends "${APT_T[@]}" "$p" >>"$LOG" 2>&1; then
            ok "$p"
        else
            MISSING+=("$p"); warn "не встал: $p"
        fi
    done
fi

# ------------------------------------------------------- сеанс и устройства
# Hyprland сам не открывает /dev/input — он просит устройства у logind
# по D-Bus, а тот отдаёт их только внутри активного сеанса на seat.
# Без включённого менеджера входа такого сеанса нет, и в Hyprland
# не работают ни мышь, ни клавиатура.
say "Настраиваю вход в систему"
# Если менеджер входа уже настроен (в Kali часто lightdm) — не трогаем его:
# два включённых менеджера дерутся за экран. Нам важно лишь, чтобы
# хоть какой-то был включён, иначе не будет сеанса logind.
DM_LINK=/etc/systemd/system/display-manager.service
CUR_DM=""
# именно -e, а не readlink: для несуществующего пути readlink -f
# возвращает сам путь, и basename дал бы мнимое имя службы
[ -e "$DM_LINK" ] && CUR_DM="$(basename "$(readlink -f "$DM_LINK")" .service)"
if [ -n "$CUR_DM" ]; then
    sudo systemctl enable "$CUR_DM" >/dev/null 2>&1 \
        && ok "менеджер входа уже настроен ($CUR_DM), включил его"
elif systemctl list-unit-files sddm.service >/dev/null 2>&1; then
    sudo systemctl enable sddm >/dev/null 2>&1 && ok "sddm включён при загрузке"
else
    warn "менеджера входа нет — Hyprland придётся запускать из консоли,"
    warn "и тогда мышь с клавиатурой могут не заработать"
fi
sudo systemctl set-default graphical.target >/dev/null 2>&1 \
    && ok "система будет грузиться в графику"

# Запасной путь: если сеанс logind почему-то не поднимется, прямой доступ
# к устройствам даёт членство в группах.
for g in input video render; do
    getent group "$g" >/dev/null 2>&1 || continue
    case " $(id -nG "$USER" 2>/dev/null) " in *" $g "*) continue ;; esac
    sudo usermod -aG "$g" "$USER" && ok "добавил тебя в группу $g"
done

# ---------------------------------------------------------------- конфиги
say "Раскладываю конфиги в ~/.config"
mkdir -p "$BACKUP" "$HOME/.config"
for item in "$SRC"/config/*; do
    name="$(basename "$item")"
    target="$HOME/.config/$name"
    [ -e "$target" ] && { mv "$target" "$BACKUP/"; warn "старый $name сохранён в бэкап"; }
    cp -r "$item" "$target"
    ok "$name"
done

# ---------------------------------------------------------------- скрипты
say "Ставлю утилиты в ~/.local/bin"
mkdir -p "$HOME/.local/bin"
for f in "$SRC"/bin/*; do
    name="$(basename "$f")"
    [ -e "$HOME/.local/bin/$name" ] && mv "$HOME/.local/bin/$name" "$BACKUP/"
    install -m 755 "$f" "$HOME/.local/bin/$name"
done
ok "$(find "$SRC/bin" -type f | wc -l) шт."

# ---------------------------------------------------------------- оболочка
say "Настраиваю zsh"
if [ -e "$HOME/.zshrc" ]; then
    mv "$HOME/.zshrc" "$BACKUP/zshrc"; warn "старый .zshrc сохранён в бэкап"
fi
cp "$SRC/shell/zshrc" "$HOME/.zshrc"
ok ".zshrc — алиасы, функции, starship, fastfetch"

if [ "$(getent passwd "$USER" | cut -d: -f7)" != "$(command -v zsh)" ]; then
    warn "Оболочка по умолчанию — не zsh."
    read -rp "     Сделать zsh основной? [y/N] " z
    if [[ "$z" =~ ^[Yy]$ ]]; then
        chsh -s "$(command -v zsh)" && ok "готово, применится при следующем входе"
    else
        ok "пропускаю — конфиг положен, но подхватится только в zsh"
    fi
fi

# ---------------------------------------------------------------- обои и курсоры
say "Обои и курсоры"
mkdir -p "$HOME/Pictures/wallpapers" "$HOME/.local/share/icons"
cp -n "$SRC"/wallpapers/* "$HOME/Pictures/wallpapers/" 2>/dev/null || true
ok "обои -> ~/Pictures/wallpapers"
cp -rn "$SRC"/icons/* "$HOME/.local/share/icons/" 2>/dev/null || true
ok "курсоры -> ~/.local/share/icons"

# ---------------------------------------------------------------- пути
say "Переписываю абсолютные пути под $HOME"
# в конфигах зашит путь исходной машины — меняем на домашнюю папку этого пользователя
grep -rlZ '/home/meetme' "$HOME/.config" 2>/dev/null \
  | xargs -0 -r sed -i "s|/home/meetme|$HOME|g"
ok "готово"

# ---------------------------------------------------------------- данные
say "Создаю пустые хранилища для заметок и задач"
mkdir -p "$HOME/.local/share/notes" "$HOME/.local/share/english"
[ -f "$HOME/.local/share/tasks.json" ] || echo '[]' > "$HOME/.local/share/tasks.json"
ok "заметки, задачи, english — пустые, это твои, не чужие"

# ---------------------------------------------------------------- PATH
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *)
    say "Добавляю ~/.local/bin в PATH"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        grep -q '\.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        ok "$(basename "$rc")"
    done
    ;;
esac

fc-cache -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------- программы
# Сбой прикладных программ не должен обрывать установку: при set -e
# любой их ненулевой код завершал весь скрипт, и до инструментов
# безопасности и до финальной самопроверки дело уже не доходило.
# Записываем неудачу и идём дальше — проверка в конце обязана отработать.
SUBFAIL=()
if [ -x "$SRC/apps.sh" ]; then
    "$SRC/apps.sh" || { SUBFAIL+=("прикладные программы (apps.sh)"); warn "apps.sh отработал с ошибкой, продолжаю"; }
else
    warn "apps.sh не найден — прикладные программы пропущены"
fi

# ------------------------------------------------- инструменты безопасности
if [ -x "$SRC/security-tools.sh" ]; then
    say "Инструменты безопасности из набора Kali"
    echo "   nmap, wireshark, metasploit, sqlmap, hashcat, SecLists и прочее."
    echo "   Займёт несколько гигабайт (одни словари SecLists около 1 ГБ)."
    read -rp "   Поставить? [y/N] " st
    if [[ "$st" =~ ^[Yy]$ ]]; then
        "$SRC/security-tools.sh" || { SUBFAIL+=("инструменты безопасности (security-tools.sh)"); warn "security-tools.sh отработал с ошибкой, продолжаю"; }
    else
        ok "пропускаю — поставить потом можно так: ./security-tools.sh"
    fi
fi

# ------------------------------------------------------- проверка результата
# Раньше установщик мог отчитаться успехом, когда половина не встала:
# apt писал «не встал: waybar» где-то в середине вывода, и всё.
# Теперь в конце проверяем то, без чего рабочий стол не работает,
# и если чего-то нет — говорим об этом громко и выходим с ошибкой.
say "Проверяю, что получилось"
BROKEN=()

chk_cmd() {  # chk_cmd <команда> <зачем нужна>
    if command -v "$1" >/dev/null 2>&1; then ok "$1"
    else BROKEN+=("$1 — $2"); printf '\033[1;31m  ✗\033[0m %s — %s\n' "$1" "$2"; fi
}
chk_path() {
    if [ -e "$1" ]; then ok "$2"
    else BROKEN+=("$2"); printf '\033[1;31m  ✗\033[0m %s\n' "$2"; fi
}

chk_cmd Hyprland   "сам оконный менеджер"
chk_cmd waybar     "панель сверху"
chk_cmd kitty      "терминал"
chk_cmd wofi       "меню запуска"
chk_cmd hyprlock   "блокировка экрана"
chk_cmd hyprpaper  "обои"
chk_cmd wpctl      "управление звуком (wireplumber)"
chk_cmd zsh        "оболочка, под неё написан .zshrc"

chk_path "$HOME/.config/hypr/hyprland.conf" "конфиг Hyprland"
chk_path "$HOME/.config/waybar/config.jsonc" "конфиг Waybar"
chk_path "$HOME/.local/bin/wallpick"         "утилиты в ~/.local/bin"
chk_path "$HOME/.zshrc"                      "настройки оболочки"
chk_path /usr/share/wayland-sessions/hyprland.desktop "сессия Hyprland на экране входа"

# менеджер входа: без него не будет сеанса logind, а значит ни мыши, ни клавиатуры
if [ -e /etc/systemd/system/display-manager.service ]; then
    ok "менеджер входа настроен"
else
    BROKEN+=("менеджер входа не настроен — в Hyprland не будет мыши и клавиатуры")
    printf '\033[1;31m  ✗\033[0m менеджер входа не настроен\n'
fi

if [ ${#SUBFAIL[@]} -gt 0 ]; then
    echo
    warn "Отработали с ошибкой: ${SUBFAIL[*]}"
    echo "     Их можно запустить отдельно, готовое пропустится."
fi

if [ ${#BROKEN[@]} -gt 0 ]; then
    echo
    printf '\033[1;31m╔══════════════════════════════════════════════════════╗\033[0m\n'
    printf '\033[1;31m║  УСТАНОВКА НЕ ЗАВЕРШЕНА — не хватает вот этого:      ║\033[0m\n'
    printf '\033[1;31m╚══════════════════════════════════════════════════════╝\033[0m\n'
    for b in "${BROKEN[@]}"; do echo "   • $b"; done
    echo
    echo "   Что делать:"
    echo "     1. Посмотри, что сказал apt:  tail -40 $LOG"
    echo "     2. Запусти установщик ещё раз — готовое пропустится"
    echo "     3. Если не поможет, покажи этот список и лог"
    echo
    [ ${#MISSING[@]} -gt 0 ] && echo "   Не установились пакеты: ${MISSING[*]}"
    exit 1
fi

# ---------------------------------------------------------------- итог
say "Готово"
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Не установились (поставь руками или пропусти): ${MISSING[*]}"
    warn "Что сказал apt — последние строки:"
    tail -15 "$LOG" 2>/dev/null | sed 's/^/       /'
fi
cat <<'EOT'

Дальше:
  1. ПЕРЕЗАГРУЗИСЬ. Не просто выйди из сессии — нужен новый вход,
     иначе не подхватятся группы и не поднимется сеанс logind.
     После перезагрузки на экране входа выбери сессию Hyprland
     (переключатель обычно в левом верхнем углу).
  2. Hyprland: Super+Q — терминал, Super+R — меню. Полный список биндов: hypr-help
  3. Обои и цвета системы:  wallpick
     Он генерирует палитру waybar/wofi/kitty из выбранных обоев.
     В комплекте три штуки, остальные докинь в ~/Pictures/wallpapers

ВАЖНО — это настроено под другой ноутбук, проверь у себя:
  • dim, nightmode   — яркость через brightnessctl, может не подхватить твой экран
  • vpn              — заточен под чужую сеть, свои настройки задай сам
  • wifi, bt         — универсальные, но профили сети у тебя будут свои
  • звук             — если тишина, смотри alsamixer: на некоторых ноутбуках
                       отдельный ключ громкости глушит и колонки, и наушники
  • steam-quit, games — управление Steam и игрушки для терминала

Программы ставятся отдельным скриптом apps.sh (он уже отработал выше):
  g++ и инструменты C++, VS Code, Steam, Telegram, Discord.
  Если что-то не встало — запусти ./apps.sh повторно, готовое пропустится.

EOT
