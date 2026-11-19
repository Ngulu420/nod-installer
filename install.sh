#!/usr/bin/env bash
# =============================================================================
# nod-installer — установка и обслуживание Nod (n8n-io/nod) на VPS одной командой
#                 install & operate Nod (n8n-io/nod) on a VPS in one command
#
# Установка / Install (Debian/Ubuntu, root):
#   curl https://raw.githubusercontent.com/Ngulu420/nod-installer/main/install.sh | sudo bash
#   curl -fsSL .../install.sh | sudo bash -s -- --domain nod.example.ru     # HTTPS (Caddy)
#
# Потом / Afterwards:  nod-installer {status|backup|update|rotate-token}
# Справка / Help:      nod-installer help
#
# Основано на официальной документации Nod: nod.n8n.io/docs/deploy/self-host/
# =============================================================================
set -Eeuo pipefail
umask 077

# ---- Настройки по умолчанию (переопределяются переменными окружения) --------
NOD_REPO="${NOD_REPO:-https://github.com/n8n-io/nod.git}"
SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/Ngulu420/nod-installer/main/install.sh}"
INSTALL_DIR="${INSTALL_DIR:-/opt/nod}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/nod}"
KEEP_BACKUPS="${KEEP_BACKUPS:-4}"
BACKUP_CRON="${BACKUP_CRON:-0 4 * * 0}"          # по воскресеньям в 04:00
UI_LANG="${NOD_LANG:-ru}"
ALERT_TG_TOKEN="${ALERT_TG_TOKEN:-}"             # необязательно: бот для алертов
ALERT_TG_CHAT="${ALERT_TG_CHAT:-}"
INSTALL_OPENROUTER_KEY="${INSTALL_OPENROUTER_KEY:-}"
INSTALL_LLM_PROVIDER="${INSTALL_LLM_PROVIDER:-}"
INSTALL_LLM_MODEL="${INSTALL_LLM_MODEL:-}"
INSTALL_TG_BOT_TOKEN="${INSTALL_TG_BOT_TOKEN:-}"
INSTALL_TG_USER_ID="${INSTALL_TG_USER_ID:-}"

# ---- Состояние ---------------------------------------------------------------
CMD=install; POS1=""; DOMAIN=""; REF=""; ASSUME_YES=0; FORCE=0
MODE=tunnel; PROFILE_STR=""; CUR_REF=""
C_MODE=""; C_DOMAIN=""; C_REF=""; C_INSTALLED=0
SRC_DIR=""; COMPOSE_DIR=""; ENV_FILE=""; CONF=""; LOG_FILE=/dev/null; BUILD_LOG=""

# ---- Вывод / Output ----------------------------------------------------------
t() { if [ "$UI_LANG" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say()  { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
info() { say "[*] $(t "$1" "$2")"; }
ok()   { say "[+] $(t "$1" "$2")"; }
warn() { say "[!] $(t "$1" "$2")"; }
die()  { say "[x] $(t "$1" "$2")"; notify "❌ nod-installer ($(hostname)): $(t "$1" "$2")"; exit 1; }

has_tty() { ( : </dev/tty ) 2>/dev/null; }

# ask "ru" "en" -> 0 = explicit yes; empty/unknown input repeats the question.
ask() {
  local a hint="y/n"
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  if ! has_tty; then
    die "Для подтверждения нужен терминал. Для явного согласия без терминала используйте --yes." \
        "Confirmation requires a terminal. Use --yes for explicit noninteractive consent."
  fi
  while true; do
    if ! IFS= read -r -p "$(t "$1" "$2") [$hint] " a </dev/tty; then
      die "Не удалось прочитать ответ из терминала" "Could not read an answer from the terminal"
    fi
    # Some SSH clients include CR or bracketed-paste markers in pasted input.
    a="${a//$'\r'/}"
    a="${a//$'\e[200~'/}"
    a="${a//$'\e[201~'/}"
    a="${a// / }"
    a="${a// / }"
    a="${a#"${a%%[![:space:]]*}"}"
    a="${a%"${a##*[![:space:]]}"}"
    case "${a,,}" in
      y|yes|да|д) return 0 ;;
      n|no|нет|н) return 1 ;;
      *) printf '%s\n' "$(t 'Введите y (да) или n (нет). Пустой ввод не принимается.' 'Enter y (yes) or n (no). Empty input is not accepted.')" >/dev/tty ;;
    esac
  done
}

# Алерт в Telegram (токен не попадает в аргументы процесса)
notify() {
  [ -n "$ALERT_TG_TOKEN" ] && [ -n "$ALERT_TG_CHAT" ] || return 0
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$ALERT_TG_TOKEN" \
    | curl -fsS -m 10 -K - --data-urlencode "chat_id=$ALERT_TG_CHAT" \
        --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

on_err() {
  local code=$? line="$1"
  trap - ERR
  say "[x] $(t "Сбой на строке $line (код $code). Лог: $LOG_FILE" "Failure at line $line (exit $code). Log: $LOG_FILE")"
  notify "❌ nod-installer ($(hostname)): line $line, exit $code"
  exit "$code"
}

usage() {
  cat <<'EOF'
nod-installer — Nod (n8n-io/nod) on a VPS / Nod на VPS

  install [--domain HOST] [--ref TAG] [--dir DIR] [--yes] [--force] [--lang ru|en]
  status
  backup [ABS_DEST_DIR]
  update [--ref TAG] [--yes]
  rotate-token
  help

Без --domain: режим SSH-туннеля (порт только на 127.0.0.1).
С --domain:   HTTPS через Caddy (нужны A-запись и свободные порты 80/443).

Переменные окружения / Environment (необязательно / optional):
  INSTALL_OPENROUTER_KEY, INSTALL_LLM_PROVIDER, INSTALL_LLM_MODEL
  INSTALL_TG_BOT_TOKEN + INSTALL_TG_USER_ID   (Telegram-канал Nod; станет server-managed)
  ALERT_TG_TOKEN + ALERT_TG_CHAT              (алерты установщика, отдельный бот)
  INSTALL_DIR, BACKUP_ROOT, KEEP_BACKUPS, BACKUP_CRON, NOD_REPO, SELF_URL

Модель и каналы можно подключить и в самом приложении (ключи хранятся зашифрованно в БД).
EOF
}

# ---- Аргументы ---------------------------------------------------------------
parse_args() {
  case "${1:-}" in
    install|update|backup|rotate-token|status|help) CMD="$1"; shift ;;
    -h|--help) CMD=help; shift ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)   [ $# -ge 2 ] || die "--domain требует значение" "--domain needs a value"; DOMAIN="$2"; shift 2 ;;
      --domain=*) DOMAIN="${1#*=}"; shift ;;
      --ref)      [ $# -ge 2 ] || die "--ref требует значение" "--ref needs a value"; REF="$2"; shift 2 ;;
      --ref=*)    REF="${1#*=}"; shift ;;
      --dir)      [ $# -ge 2 ] || die "--dir требует значение" "--dir needs a value"; INSTALL_DIR="$2"; shift 2 ;;
      --dir=*)    INSTALL_DIR="${1#*=}"; shift ;;
      --lang)     [ $# -ge 2 ] || die "--lang требует значение" "--lang needs a value"; UI_LANG="$2"; shift 2 ;;
      --lang=*)   UI_LANG="${1#*=}"; shift ;;
      -y|--yes)   ASSUME_YES=1; shift ;;
      --force)    FORCE=1; shift ;;
      -h|--help)  CMD=help; shift ;;
      -*)         die "Неизвестный параметр: $1" "Unknown option: $1" ;;
      *)          POS1="$1"; shift ;;
    esac
  done
  case "$UI_LANG" in ru|en) ;; *) UI_LANG=ru ;; esac
}

init_paths() {
  SRC_DIR="$INSTALL_DIR/src"
  COMPOSE_DIR="$SRC_DIR/deployment/self-host"
  ENV_FILE="$COMPOSE_DIR/.env"
  CONF="$INSTALL_DIR/installer.conf"
  mkdir -p "$INSTALL_DIR/logs"
  chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/logs"
  LOG_FILE="$INSTALL_DIR/logs/installer.log"
  BUILD_LOG="$INSTALL_DIR/logs/build.log"
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
}

# ---- Конфиг установщика (не секретный) и алерты ------------------------------
conf_get() { grep -m1 "^$1=" "$CONF" 2>/dev/null | cut -d= -f2- || true; }

load_conf() {
  [ -f "$CONF" ] || return 0
  C_MODE="$(conf_get MODE)"; C_DOMAIN="$(conf_get DOMAIN)"
  C_REF="$(conf_get REF)";   C_INSTALLED="$(conf_get INSTALLED)"
  C_INSTALLED="${C_INSTALLED:-0}"
}

save_conf() { # $1 = installed (0|1)
  cat >"$CONF" <<EOF
MODE=$MODE
DOMAIN=$DOMAIN
REF=$REF
INSTALLED=$1
EOF
  chmod 600 "$CONF"
}

load_alert() {
  local f="$INSTALL_DIR/alert.env"
  [ -f "$f" ] || return 0
  [ -n "$ALERT_TG_TOKEN" ] || ALERT_TG_TOKEN="$(grep -m1 '^ALERT_TG_TOKEN=' "$f" | cut -d= -f2- || true)"
  [ -n "$ALERT_TG_CHAT" ]  || ALERT_TG_CHAT="$(grep -m1 '^ALERT_TG_CHAT=' "$f" | cut -d= -f2- || true)"
}

save_alert() {
  [ -n "$ALERT_TG_TOKEN" ] && [ -n "$ALERT_TG_CHAT" ] || return 0
  printf 'ALERT_TG_TOKEN=%s\nALERT_TG_CHAT=%s\n' "$ALERT_TG_TOKEN" "$ALERT_TG_CHAT" >"$INSTALL_DIR/alert.env"
  chmod 600 "$INSTALL_DIR/alert.env"
}

# ---- .env helpers ------------------------------------------------------------
get_env() { grep -m1 "^$1=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true; }

set_env() {
  local k="$1" v="$2" tmp
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  K="$k" V="$v" awk '
    BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; n = length(k) + 1; d = 0 }
    substr($0, 1, n) == k "=" { print k "=" v; d = 1; next }
    { print }
    END { if (!d) print k "=" v }' "$ENV_FILE" >"$tmp"
  cat "$tmp" >"$ENV_FILE"; rm -f "$tmp"
  chmod 600 "$ENV_FILE"
}

# ---- docker compose в каталоге установки --------------------------------------
dc() {
  # shellcheck disable=SC2086
  ( cd "$COMPOSE_DIR" && docker compose $PROFILE_STR "$@" )
}

set_mode() {
  if [ -n "$DOMAIN" ]; then MODE=https; PROFILE_STR="--profile https"
  else MODE=tunnel; PROFILE_STR=""; fi
}

# ---- Проверки системы ---------------------------------------------------------
preflight() {
  [ -r /etc/os-release ] || die "Не удалось определить ОС" "Cannot detect the OS"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian) ;;
    *) case "${ID_LIKE:-}" in
         *debian*|*ubuntu*) ;;
         *) die "Поддерживаются Debian/Ubuntu (у вас: ${ID:-?})" "Debian/Ubuntu only (you have: ${ID:-?})" ;;
       esac ;;
  esac
  case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) die "Нужна архитектура amd64 или arm64" "amd64 or arm64 is required" ;;
  esac

  local mem_kb cpus avail_gb path=/
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  cpus="$(nproc)"
  [ -d /var/lib/docker ] && path=/var/lib/docker
  avail_gb="$(df -BG --output=avail "$path" | tail -n1 | tr -dc '0-9')"
  info "CPU: $cpus, RAM: $((mem_kb / 1024)) МБ, свободно на диске: ${avail_gb} ГБ" \
       "CPU: $cpus, RAM: $((mem_kb / 1024)) MB, free disk: ${avail_gb} GB"

  if [ "$FORCE" != 1 ]; then
    [ "$mem_kb" -ge 7000000 ] || die "Нужно ≥ 8 ГБ RAM (рекомендация документации). Обход: --force" "≥ 8 GB RAM required (docs recommendation). Override: --force"
    [ "$cpus" -ge 2 ]         || die "Нужно ≥ 2 CPU. Обход: --force" "≥ 2 CPUs required. Override: --force"
    [ "${avail_gb:-0}" -ge 35 ] || die "Нужно ≥ 35 ГБ свободного места (рекомендуется 50). Обход: --force" "≥ 35 GB free disk required (50 recommended). Override: --force"
  fi
  [ "${avail_gb:-0}" -ge 50 ] || warn "Рекомендуется 50 ГБ диска: сборка и данные занимают много места" "50 GB disk recommended: build and data need a lot of space"
}

apt_run() {
  apt-get -o Acquire::Retries=2 -o Acquire::http::Timeout=30 \
    -o Acquire::https::Timeout=30 "$@" 2>&1 | tee -a "$LOG_FILE"
}

ensure_docker() {
  local base_packages=(ca-certificates curl git openssl util-linux gnupg)
  export DEBIAN_FRONTEND=noninteractive
  if dpkg-query -W -f='${db:Status-Status}\n' "${base_packages[@]}" 2>/dev/null \
      | awk '$0 != "installed" { bad = 1 } END { exit (bad || NR != 6) }'; then
    info "Базовые пакеты уже установлены — пропускаю их загрузку" "Base packages already installed — skipping downloads"
  else
    info "Установка базовых пакетов" "Installing base packages"
    apt_run update
    apt_run install -y "${base_packages[@]}"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден — ставлю из официального репозитория Docker" "Docker not found — installing from the official Docker repository"
    # shellcheck disable=SC1091
    . /etc/os-release
    local distro=debian codename="${VERSION_CODENAME:-}"
    if [ "${ID:-}" = ubuntu ] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; then
      distro=ubuntu; codename="${UBUNTU_CODENAME:-$codename}"
    fi
    [ -n "$codename" ] || die "Не удалось определить кодовое имя релиза" "Cannot detect the release codename"
    install -m 0755 -d /etc/apt/keyrings
    curl -fL --connect-timeout 15 --max-time 60 "https://download.docker.com/linux/$distro/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$distro" "$codename" >/etc/apt/sources.list.d/docker.list
    apt_run update
    apt_run install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if command -v systemctl >/dev/null 2>&1; then systemctl enable --now docker 2>&1 | tee -a "$LOG_FILE" || true; fi
  docker info >/dev/null 2>&1 || die "Docker не запущен" "Docker is not running"
  docker compose version >/dev/null 2>&1 || die "Нужен Docker Compose v2 (плагин docker-compose-plugin)" "Docker Compose v2 plugin is required"

  local v major
  v="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  major="${v%%.*}"
  [[ "$major" =~ ^[0-9]+$ ]] || die "Не удалось определить версию Docker" "Cannot detect the Docker version"
  [ "$major" -ge 25 ] || die "Нужен Docker Engine ≥ 25 (у вас $v)" "Docker Engine ≥ 25 is required (you have $v)"
  ok "Docker $v, Compose v2" "Docker $v, Compose v2"
}

# ---- Версия (тег) -------------------------------------------------------------
resolve_ref() {
  if [ -z "$REF" ]; then
    info "Ищу последний релизный тег nod-vX.Y.Z" "Looking for the latest release tag nod-vX.Y.Z"
    local tags
    if ! tags="$(timeout 120 git ls-remote --tags --refs --sort=-v:refname "$NOD_REPO" 'nod-v*' \
        2> >(tee -a "$LOG_FILE" >&2))"; then
      die "Не удалось получить версии Nod за отведённое время. Подробности выше и в $LOG_FILE" \
          "Could not retrieve Nod versions within the time limit. See the output and $LOG_FILE"
    fi
    REF="$(printf '%s\n' "$tags" | awk '$2 ~ /^refs\/tags\/nod-v[0-9]+\.[0-9]+\.[0-9]+$/ && !found { sub(/^refs\/tags\//, "", $2); print $2; found = 1 }')"
    [ -n "$REF" ] || die "Релизные теги не найдены. Укажите версию: --ref <тег|коммит>" "No release tags found. Pass one: --ref <tag|commit>"
  fi
  [[ "$REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "Недопустимое значение --ref" "Invalid --ref value"
}

fetch_source() {
  info "Загрузка исходников Nod" "Downloading Nod source"
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" fetch --tags --force --progress origin 2>&1 | tee -a "$LOG_FILE"
  else
    git clone --progress "$NOD_REPO" "$SRC_DIR" 2>&1 | tee -a "$LOG_FILE"
  fi
  git -C "$SRC_DIR" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null \
    || die "Тег/коммит '$REF' не найден в репозитории" "Tag/commit '$REF' not found in the repository"
  git -C "$SRC_DIR" checkout --detach "$REF" 2>&1 | tee -a "$LOG_FILE"
  [ -f "$COMPOSE_DIR/setup.sh" ] \
    || die "В $COMPOSE_DIR нет setup.sh — структура репозитория изменилась, сверьтесь с документацией" \
           "No setup.sh in $COMPOSE_DIR — repo layout changed, check the docs"
  ok "Исходники: $REF ($(git -C "$SRC_DIR" rev-parse --short HEAD))" "Source: $REF ($(git -C "$SRC_DIR" rev-parse --short HEAD))"
}

# ---- Домен / DNS / порты -------------------------------------------------------
public_ip() {
  local ip s
  for s in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip="$(curl -4fsS -m 8 "$s" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

port_busy() { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }

print_nginx_hint() {
  say "$(t 'Порты 80/443 заняты. Вариант со своим nginx (профиль https не использовать):' 'Ports 80/443 are busy. Use your own nginx instead (do not use the https profile):')"
  printf '%s\n' \
    "  server {" \
    "    listen 443 ssl; server_name $DOMAIN;" \
    "    # ssl_certificate ... (certbot)" \
    "    location / {" \
    "      proxy_pass http://127.0.0.1:4310;" \
    "      proxy_set_header Host \$host;" \
    "      proxy_http_version 1.1;" \
    "      proxy_set_header Upgrade \$http_upgrade;" \
    "      proxy_set_header Connection \"upgrade\";" \
    "      proxy_buffering off;" \
    "      proxy_read_timeout 3600s;" \
    "    }" \
    "  }" | tee -a "$LOG_FILE"
  say "$(t 'И в .env: NOD_PUBLIC_URL=https://'"$DOMAIN"' ; запуск: docker compose up -d --build --wait' 'And in .env: NOD_PUBLIC_URL=https://'"$DOMAIN"' ; start: docker compose up -d --build --wait')"
}

check_domain() {
  DOMAIN="${DOMAIN,,}"
  [[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "Некорректное имя домена (нужен ASCII/punycode, без http:// и пути): $DOMAIN" "Invalid domain (ASCII/punycode, no scheme or path): $DOMAIN"

  if [ "$C_MODE" != https ]; then
    local p
    for p in 80 443; do
      if port_busy "$p"; then print_nginx_hint; die "Порт $p занят" "Port $p is busy"; fi
    done
  fi

  local want got i
  want="$(public_ip)" || die "Не удалось определить публичный IP сервера" "Cannot detect the server's public IP"
  info "DNS pre-check: $DOMAIN должен указывать на $want" "DNS pre-check: $DOMAIN must point to $want"
  for i in $(seq 1 20); do
    got="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
    case " $got " in
      *" $want "*) ok "DNS в порядке" "DNS is fine"; return 0 ;;
    esac
    warn "Попытка $i/20: сейчас '${got:-нет записи}'. Жду 15 с (DNS ещё распространяется?)" \
         "Attempt $i/20: currently '${got:-no record}'. Waiting 15s (DNS still propagating?)"
    sleep 15
  done
  die "Домен не указывает на $want. Проверьте A-запись (у Cloudflare — выключите проксирование) и запустите установку снова" \
      "Domain does not point to $want. Check the A record (disable Cloudflare proxy) and re-run"
}

configure_ufw() {
  command -v ufw >/dev/null 2>&1 || { info "UFW не установлен — пропускаю" "UFW not installed — skipping"; return 0; }
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    local sshp
    sshp="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)"
    ufw allow "${sshp:-22}/tcp" >/dev/null
    if [ "$MODE" = https ]; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
    ok "Правила UFW добавлены (SSH${MODE:+, $MODE})" "UFW rules added (SSH${MODE:+, $MODE})"
  else
    warn "UFW установлен, но выключен — не включаю сам (риск потерять SSH). Порт Nod слушает только 127.0.0.1" \
         "UFW installed but inactive — not enabling it (SSH lock-out risk). Nod listens on 127.0.0.1 only"
  fi
}

# ---- .env ----------------------------------------------------------------------
prepare_env() {
  local existed=0
  if [ -f "$ENV_FILE" ]; then existed=1; fi
  if [ "$existed" = 1 ]; then
    warn ".env уже существует — ключи и токен сохраняются" ".env already exists — keys and token are preserved"
    if ! ask "Применить управляемые настройки (телеметрия, URL) к существующему .env? Будет сделана копия" \
             "Apply managed settings (telemetry, URL) to the existing .env? A copy will be made" y; then
      info "Пропускаю изменение .env" "Skipping .env changes"; return 0
    fi
    cp -p "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  fi

  info "Генерация конфигурации (setup.sh)" "Generating configuration (setup.sh)"
  ( cd "$COMPOSE_DIR" && sh setup.sh </dev/null ) 2>&1 | tee -a "$LOG_FILE" \
    || die "setup.sh завершился с ошибкой, см. $LOG_FILE" "setup.sh failed, see $LOG_FILE"
  [ -f "$ENV_FILE" ] || die ".env не создан" ".env was not created"
  chmod 600 "$ENV_FILE"

  # Телеметрия выключена (по умолчанию уходит команде n8n)
  set_env NOD_ANALYTICS_ENABLED false
  set_env NOD_FEEDBACK_ENABLED false
  set_env NOD_ONBOARDING_EMAIL_URL ""
  set_env NOD_TRACES_URL ""

  if [ "$MODE" = https ]; then set_env NOD_PUBLIC_URL "https://$DOMAIN"; fi

  if [ -n "$INSTALL_OPENROUTER_KEY" ]; then
    set_env OPENROUTER_API_KEY "$INSTALL_OPENROUTER_KEY"
    if [ -n "$INSTALL_LLM_PROVIDER" ]; then set_env LLM_PROVIDER "$INSTALL_LLM_PROVIDER"; fi
    if [ -n "$INSTALL_LLM_MODEL" ]; then set_env LLM_MODEL "$INSTALL_LLM_MODEL"; fi
    ok "Ключ OpenRouter записан в .env (chmod 600)" "OpenRouter key written to .env (chmod 600)"
  fi
  if [ -n "$INSTALL_TG_BOT_TOKEN" ] && [ -n "$INSTALL_TG_USER_ID" ]; then
    set_env TELEGRAM_BOT_TOKEN "$INSTALL_TG_BOT_TOKEN"
    set_env TELEGRAM_ALLOWED_USER_ID "$INSTALL_TG_USER_ID"
    ok "Telegram-канал Nod настроен через .env (polling)" "Nod Telegram channel configured via .env (polling)"
  fi
  INSTALL_OPENROUTER_KEY=""; INSTALL_TG_BOT_TOKEN=""
}

# ---- Сборка и проверка ----------------------------------------------------------
run_build() {
  local status="$INSTALL_DIR/.build-status" waited=0 limit=2700 rc build_pid viewer_pid
  rm -f "$status"; : >"$BUILD_LOG"; chmod 600 "$BUILD_LOG"
  info "Сборка и запуск (первый раз ~12+ мин). Лог: $BUILD_LOG. Если SSH оборвётся — сборка продолжится." \
       "Building and starting (first run ~12+ min). Log: $BUILD_LOG. If SSH drops, the build continues."
  # Keep the builder independent of SSH; stream its log to this terminal.
  setsid nohup bash -c '
    cd "$1" || { printf "%s\n" "$?" >"$2"; exit 1; }
    export BUILDKIT_PROGRESS=plain
    if [ -n "$3" ]; then
      docker compose --progress plain --profile https up -d --build --wait
    else
      docker compose --progress plain up -d --build --wait
    fi
    rc=$?
    printf "%s\n" "$rc" >"$2"
    exit "$rc"
  ' bash "$COMPOSE_DIR" "$status" "$PROFILE_STR" \
    >>"$BUILD_LOG" 2>&1 </dev/null &
  build_pid=$!
  tail --pid="$build_pid" --sleep-interval=0.2 -n +1 -f "$BUILD_LOG" &
  viewer_pid=$!
  while [ ! -f "$status" ]; do
    sleep 2; waited=$((waited + 2))
    if [ ! -f "$status" ] && ! kill -0 "$build_pid" 2>/dev/null; then
      kill "$viewer_pid" 2>/dev/null || true
      wait "$viewer_pid" 2>/dev/null || true
      wait "$build_pid" 2>/dev/null || true
      die "Процесс сборки завершился без результата. Подробности: $BUILD_LOG" \
          "Builder exited without a result. See $BUILD_LOG"
    fi
    if [ $((waited % 60)) -eq 0 ]; then
      info "Сборка продолжается: прошло ${waited} с" "Build still running: ${waited}s elapsed"
    fi
    if [ "$waited" -ge "$limit" ]; then
      kill "$viewer_pid" 2>/dev/null || true
      wait "$viewer_pid" 2>/dev/null || true
      die "Таймаут ожидания сборки (45 мин). Сборка продолжает работать; лог: $BUILD_LOG" \
          "Build wait timed out (45 min). Builder is still running; log: $BUILD_LOG"
    fi
  done
  wait "$viewer_pid" || true
  wait "$build_pid" || true
  rc="$(cat "$status")"
  if [ "$rc" != 0 ]; then
    tail -n 40 "$BUILD_LOG" | tee -a "$LOG_FILE" || true
    die "Сборка/запуск завершились с ошибкой (код $rc)" "Build/start failed (exit $rc)"
  fi
  ok "Контейнеры запущены и healthy" "Containers are up and healthy"
}

wait_http() { # url tries
  local code i
  for i in $(seq 1 "$2"); do
    code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "$1" 2>/dev/null || true)"
    case "$code" in 2??|3??|401|403) return 0 ;; esac
    sleep 5
  done
  return 1
}

verify() {
  local port; port="$(get_env PORT)"; port="${port:-4310}"
  dc ps 2>&1 | tee -a "$LOG_FILE" || true
  info "Проверка ответа Nod на 127.0.0.1:$port" "Checking Nod at 127.0.0.1:$port"
  wait_http "http://127.0.0.1:$port/" 24 \
    || die "Nod не отвечает на 127.0.0.1:$port. Логи: docker compose logs --tail 100 server" \
           "Nod does not answer on 127.0.0.1:$port. Logs: docker compose logs --tail 100 server"
  ok "Nod отвечает на 127.0.0.1:$port" "Nod answers on 127.0.0.1:$port"
  if [ "$MODE" = https ]; then
    if wait_http "https://$DOMAIN/" 36; then ok "HTTPS работает: https://$DOMAIN" "HTTPS works: https://$DOMAIN"
    else warn "https://$DOMAIN пока недоступен (сертификат выпускается?). Проверьте логи Caddy: docker compose --profile https logs --tail 100" \
              "https://$DOMAIN is not reachable yet (certificate pending?). Check Caddy logs: docker compose --profile https logs --tail 100"
    fi
  fi
}

# ---- Самоустановка и cron-бэкап --------------------------------------------------
install_self() {
  local dst=/usr/local/sbin/nod-installer src="${BASH_SOURCE[0]:-}" tmp
  tmp="$(mktemp "${dst}.XXXXXX")" || return 1
  if [ -n "$src" ] && [ -f "$src" ] && [ -r "$src" ]; then
    cp "$src" "$tmp" || { rm -f "$tmp"; return 1; }
  else
    curl -fL --connect-timeout 15 --max-time 60 "$SELF_URL" -o "$tmp" \
      || { rm -f "$tmp"; return 1; }
  fi
  if ! head -n1 "$tmp" | grep -q '^#!/usr/bin/env bash' || ! bash -n "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  chmod 755 "$tmp" && mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

schedule_backup() {
  [[ "$BACKUP_CRON" =~ ^[0-9*/,-]+(\ [0-9*/,-]+){4}$ ]] || { warn "BACKUP_CRON некорректен — cron не создан" "BACKUP_CRON invalid — cron not created"; return 0; }
  cat >/etc/cron.d/nod-backup <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$BACKUP_CRON root /usr/local/sbin/nod-installer backup --yes --dir $INSTALL_DIR >>/var/log/nod-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/nod-backup
  ok "Автобэкап по расписанию '$BACKUP_CRON' (хранится $KEEP_BACKUPS копий в $BACKUP_ROOT)" \
     "Scheduled backup '$BACKUP_CRON' (keeping $KEEP_BACKUPS copies in $BACKUP_ROOT)"
}

rotate_backups() {
  local n=0 d
  while IFS= read -r d; do
    n=$((n + 1))
    if [ "$n" -gt "$KEEP_BACKUPS" ]; then
      case "$d" in "$BACKUP_ROOT"/nod-backup-*) rm -rf -- "$d" ;; esac
    fi
  done < <(ls -1dt "$BACKUP_ROOT"/nod-backup-* 2>/dev/null || true)
}

show_token() {
  local tok; tok="$(get_env NOD_AUTH_TOKEN)"
  if has_tty; then
    printf '\n  NOD_AUTH_TOKEN = %s\n  (%s)\n\n' "$tok" "$(t 'показан только в терминале, в лог не пишется; далее — в .env' 'shown on the terminal only, never logged; later it lives in .env')" >/dev/tty
  else
    warn "Нет терминала — токен не выводится. Возьмите NOD_AUTH_TOKEN из $ENV_FILE" "No terminal — token not printed. Read NOD_AUTH_TOKEN from $ENV_FILE"
  fi
}

summary() {
  local port ip; port="$(get_env PORT)"; port="${port:-4310}"; ip="$(public_ip || echo '<IP-сервера>')"
  say ""
  say "================ $(t 'Nod установлен' 'Nod is installed') ================"
  say "$(t 'Версия' 'Version'): $REF"
  if [ "$MODE" = https ]; then
    say "$(t 'Адрес' 'URL'): https://$DOMAIN"
  else
    say "$(t 'Режим SSH-туннеля. На своём компьютере выполните:' 'SSH-tunnel mode. On your computer run:')"
    say "  ssh -L ${port}:127.0.0.1:${port} <user>@${ip}"
    say "$(t 'и откройте' 'then open') http://localhost:${port}"
  fi
  show_token
  say "$(t 'Дальше:' 'Next:')"
  say "  1) $(t 'Откройте адрес, введите токен, подключите модель (раздел Models).' 'Open the URL, enter the token, connect a model (Models).')"
  say "     $(t 'Для боевых задач берите сильную модель: проверка действий (trust check) использует выбранную модель.' 'Use a strong model for real work: the trust check runs on the model you select.')"
  say "  2) $(t 'Telegram: раздел Channels (или переменные INSTALL_TG_*).' 'Telegram: Channels section (or INSTALL_TG_* variables).')"
  say "  3) $(t 'Задайте месячный лимит расходов на API-модели (Spending and usage).' 'Set a monthly spending limit for API models (Spending and usage).')"
  say "  4) $(t 'Облачный VPS: ограничьте доступ к metadata-сервису провайдера (см. документацию Nod).' 'Cloud VPS: restrict the provider metadata service (see Nod docs).')"
  say "  5) $(t 'Бэкапы копируйте с сервера: в них секреты и Vault-ключ.' 'Copy backups off the server: they contain secrets and the Vault key.')"
  say "$(t 'Команды: nod-installer status | backup | update | rotate-token' 'Commands: nod-installer status | backup | update | rotate-token')"
}

# ---- Команды ----------------------------------------------------------------------
cmd_install() {
  load_conf
  if [ -f "$CONF" ]; then
    if [ "$C_INSTALLED" = 1 ] && [ -n "$REF" ] && [ "$REF" != "$C_REF" ]; then
      die "Nod уже установлен ($C_REF). Для смены версии: nod-installer update --ref $REF" \
          "Nod is already installed ($C_REF). To change version: nod-installer update --ref $REF"
    fi
    [ -n "$REF" ] || REF="$C_REF"
    [ -n "$DOMAIN" ] || DOMAIN="$C_DOMAIN"
  fi
  set_mode

  if ! ask "Начать установку Nod?" "Start installing Nod?" n; then
    die "Установка отменена пользователем" "Installation cancelled by the user"
  fi
  preflight
  ensure_docker
  resolve_ref
  info "Устанавливаю версию $REF из $NOD_REPO" "Installing version $REF from $NOD_REPO"
  if [ "$MODE" = https ]; then check_domain; fi

  fetch_source
  save_conf 0
  prepare_env
  save_alert
  configure_ufw
  run_build
  verify

  if install_self; then schedule_backup
  else warn "Не удалось установить nod-installer в /usr/local/sbin (проверьте SELF_URL) — автобэкап не создан" \
            "Could not install nod-installer to /usr/local/sbin (check SELF_URL) — auto-backup not created"
  fi
  save_conf 1
  summary
  notify "✅ Nod $REF installed on $(hostname) ($MODE${DOMAIN:+, $DOMAIN})"
}

require_installed() {
  load_conf
  [ "$C_INSTALLED" = 1 ] || die "Установка Nod не найдена в $INSTALL_DIR" "No Nod installation found in $INSTALL_DIR"
  MODE="$C_MODE"; DOMAIN="$C_DOMAIN"; CUR_REF="$C_REF"
  set_mode
  [ -f "$ENV_FILE" ] || die "Не найден $ENV_FILE" "$ENV_FILE not found"
}

cmd_status() {
  require_installed
  say "$(t 'Версия' 'Version'): $CUR_REF  |  $(t 'режим' 'mode'): $MODE${DOMAIN:+ ($DOMAIN)}"
  dc ps || true
  say "$(t 'Диск' 'Disk'): $(df -h / | awk 'NR==2{print $4" free / "$2}')"
  say "$(t 'Последние бэкапы' 'Latest backups'):"
  ls -1dt "$BACKUP_ROOT"/nod-backup-* 2>/dev/null | head -n3 || say "  —"
}

cmd_backup() {
  require_installed
  local dest="${POS1:-$BACKUP_ROOT/nod-backup-$(date +%Y%m%d-%H%M%S)}"
  case "$dest" in /*) ;; *) die "Путь бэкапа должен быть абсолютным" "Backup path must be absolute" ;; esac
  [ ! -e "$dest" ] || die "$dest уже существует" "$dest already exists"
  mkdir -p "$(dirname "$dest")"; chmod 700 "$(dirname "$dest")" 2>/dev/null || true
  warn "На время копирования сервер, браузер и workspace будут остановлены" "Server, browser and workspace are stopped while copying"
  ( cd "$COMPOSE_DIR" && sh backup.sh "$dest" ) 2>&1 | tee -a "$LOG_FILE" \
    || die "backup.sh завершился с ошибкой, см. $LOG_FILE" "backup.sh failed, see $LOG_FILE"
  [ -f "$dest/complete" ] || die "Бэкап неполный (нет маркера complete)" "Backup incomplete (missing 'complete' marker)"
  chmod -R go-rwx "$dest"
  case "$dest" in "$BACKUP_ROOT"/*) rotate_backups ;; esac
  ok "Бэкап: $dest (секреты внутри — храните зашифрованным и скопируйте с сервера)" \
     "Backup: $dest (contains secrets — keep it encrypted and copy it off the server)"
}

cmd_update() {
  require_installed
  local target="$REF"
  REF=""; [ -z "$target" ] || REF="$target"
  resolve_ref
  target="$REF"
  if [ "$target" = "$CUR_REF" ]; then ok "Уже установлена версия $CUR_REF" "Already on $CUR_REF"; return 0; fi
  info "Обновление: $CUR_REF → $target" "Update: $CUR_REF → $target"
  warn "Миграции БД идут при старте; откат — только восстановлением из бэкапа (restore в свежую установку)" \
       "DB migrations run on start; rollback is only via restore from backup (restore into a fresh installation)"
  if ! ask "Продолжить? Сначала будет сделан бэкап." "Continue? A backup is taken first." y; then die "Отменено" "Cancelled"; fi

  POS1=""; cmd_backup
  info "Останавливаю стек" "Stopping the stack"
  dc stop 2>&1 | tee -a "$LOG_FILE"
  fetch_source
  run_build
  verify
  save_conf 1
  ok "Обновлено до $target" "Updated to $target"
  notify "✅ Nod updated to $target on $(hostname)"
}

cmd_rotate_token() {
  require_installed
  if ! ask "Заменить NOD_AUTH_TOKEN? Все клиенты потеряют доступ до ввода нового токена" \
           "Replace NOD_AUTH_TOKEN? All clients lose access until the new token is entered" n; then die "Отменено" "Cancelled"; fi
  cp -p "$ENV_FILE" "$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  set_env NOD_AUTH_TOKEN "$(openssl rand -hex 32)"
  dc up -d --wait server 2>&1 | tee -a "$LOG_FILE" || die "Не удалось перезапустить server" "Could not restart server"
  ok "Токен заменён. NOD_VAULT_KEY не менялся (и менять его нельзя)" "Token replaced. NOD_VAULT_KEY untouched (never change it)"
  show_token
}

main() {
  parse_args "$@"
  if [ "$CMD" = help ]; then usage; return 0; fi
  [ "$(id -u)" -eq 0 ] || die "Запустите от root: curl ... | sudo bash" "Run as root: curl ... | sudo bash"
  init_paths
  exec 9>/var/lock/nod-installer.lock
  flock -n 9 || die "Другой экземпляр nod-installer уже работает" "Another nod-installer instance is running"
  load_alert
  trap 'on_err $LINENO' ERR
  case "$CMD" in
    install)      cmd_install ;;
    status)       cmd_status ;;
    backup)       cmd_backup ;;
    update)       cmd_update ;;
    rotate-token) cmd_rotate_token ;;
  esac
}

main "$@"

