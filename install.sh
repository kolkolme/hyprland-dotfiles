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
mapfile -t PKGS < <(grep -vE '^\s*(#|$)' "$SRC/packages.txt")
sudo apt-get update
# по одному: один отсутствующий пакет не должен рушить всю установку
MISSING=()
for p in "${PKGS[@]}"; do
    if sudo apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1; then
        ok "$p"
    else
        MISSING+=("$p"); warn "не встал: $p"
    fi
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
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$HOME/.local/bin"; then
    say "Добавляю ~/.local/bin в PATH"
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$rc" ] || continue
        grep -q '\.local/bin' "$rc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        ok "$(basename "$rc")"
    done
fi

fc-cache -f >/dev/null 2>&1 || true

# ---------------------------------------------------------------- программы
if [ -x "$SRC/apps.sh" ]; then
    "$SRC/apps.sh"
else
    warn "apps.sh не найден — прикладные программы пропущены"
fi

# ---------------------------------------------------------------- итог
say "Готово"
if [ ${#MISSING[@]} -gt 0 ]; then
    warn "Не установились (поставь руками или пропусти): ${MISSING[*]}"
fi
cat <<'EOT'

Дальше:
  1. Выйди из сессии и зайди снова, выбрав Hyprland.
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
