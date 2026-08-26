#!/usr/bin/env bash

THEMES_DIR="${HOME}/.config/kitty/themes"
STORED="${HOME}/.config/kitty/current-theme.conf"
TOTAL_MIN_THEMES=400
DEXPOTA_URL="https://github.com/dexpota/kitty-themes/archive/refs/heads/master.tar.gz"
KITTY_THEMES_URL="https://github.com/kovidgoyal/kitty-themes/archive/refs/heads/master.tar.gz"
SELF_URL="https://raw.githubusercontent.com/kastormdz/kitty-theme-picker/main/kitty-theme-picker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

KEY_RE='^(foreground|background|selection_foreground|selection_background|cursor|cursor_text_color|url_color|color[0-9]{1,2})[ \t]'

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

usage() {
  cat <<'USO'
kitty-theme-picker - selector interactivo de temas para kitty con preview en vivo

uso:
  kitty-theme-picker.sh             abre el selector (Enter aplica y guarda, Esc restaura)
  kitty-theme-picker.sh install     instala en ~/.local/bin, completa temas y valida el entorno
  kitty-theme-picker.sh refresh     re-descarga las colecciones para sumar temas nuevos
  kitty-theme-picker.sh -h          muestra esta ayuda

  instalar directamente desde GitHub (una sola linea):
    curl -fsSL https://raw.githubusercontent.com/kastormdz/kitty-theme-picker/main/kitty-theme-picker.sh | bash
USO
}

check_deps() {
  local c
  for c in fzf kitty awk sort cksum; do
    command -v "$c" >/dev/null 2>&1 || die "dependencia faltante: $c"
  done
  (( BASH_VERSINFO[0] >= 4 )) || die "requiere bash >= 4 (esta corriendo ${BASH_VERSION})"
}

fzf_has_pos() {
  local v maj rest min
  v="$(fzf --version 2>/dev/null)" || return 1
  maj="${v%%.*}"
  rest="${v#*.}"
  min="${rest%%.*}"
  (( maj > 0 || min >= 28 )) 2>/dev/null
}

find_socket() {
  if [[ -n "${KITTY_PICKER_SOCK:-}" && -S "$KITTY_PICKER_SOCK" ]]; then
    printf '%s\n' "$KITTY_PICKER_SOCK"
    return 0
  fi
  local s
  s="$(ls -t /tmp/kitty-theme-sync-* 2>/dev/null | head -n 1)"
  [[ -n "$s" ]] || return 1
  export KITTY_PICKER_SOCK="$s"
  printf '%s\n' "$s"
}

kc() {
  local sock
  sock="$(find_socket)" || return 1
  kitty @ --to "unix:${sock}" "$@"
}

resolve_theme() {
  local n="$1"
  case "$n" in
    /*) printf '%s\n' "$n" ;;
    *)  printf '%s/%s.conf\n' "$THEMES_DIR" "$n" ;;
  esac
}

theme_pairs() {
  awk '$0 ~ re { k=$1; sub(/[ \t]+/, "", k); print k "=" $2 }' re="$KEY_RE" "$1" 2>/dev/null
}

take_snapshot() {
  kc get-colors 2>/dev/null | awk '$0 ~ re' re="$KEY_RE" > "$TMP/orig.txt"
  [[ -s "$TMP/orig.txt" ]]
}

restore_original() {
  [[ -s "$TMP/orig.txt" ]] || return 0
  local pairs=()
  mapfile -t pairs < <(theme_pairs_stdin "$TMP/orig.txt")
  ((${#pairs[@]})) || return 0
  kc set-colors -a "${pairs[@]}" 2>/dev/null
}

theme_pairs_stdin() {
  awk '$0 ~ re { k=$1; sub(/[ \t]+/, "", k); print k "=" $2 }' re="$KEY_RE" "$1" 2>/dev/null
}

do_apply() {
  local f
  f="$(resolve_theme "$1")"
  [[ -f "$f" ]] || return 1
  local pairs=()
  mapfile -t pairs < <(theme_pairs "$f")
  ((${#pairs[@]})) || return 1
  kc set-colors -a "${pairs[@]}" 2>/dev/null
}

do_preview() {
  local f
  f="$(resolve_theme "$1")"
  [[ -f "$f" ]] || return 0
  local name="${f##*/}"
  name="${name%.conf}"
  local host_tag="${USER:-$(id -un)}@$(hostname -s 2>/dev/null || echo localhost)"
  local kv ver
  kv="$(kitty --version 2>/dev/null)"
  ver="${kv% created*}"

  local bg fg
  {
    read -r bg
    read -r fg
  } < <(awk '
      $0 ~ re {
        k=$1; sub(/[ \t]+/, "", k)
        if (k=="background") b=$2
        else if (k=="foreground") g=$2
      }
      END { print b; print g }
    ' re="$KEY_RE" "$f")

  echo
  printf '  \033[1m%s\033[0m\n' "$name"
  [ -n "$bg" ] && printf '  \033[2mfondo %-9s texto %s\033[0m\n' "$bg" "$fg"
  echo
  printf '  '
  local c
  for c in 41 42 44 46 43 45 47 40; do printf '\033[%sm  \033[0m' "$c"; done
  echo
  printf '  '
  for c in 101 102 104 106 103 105 107 100; do printf '\033[%sm  \033[0m' "$c"; done
  echo
  echo
  printf '  \033[32m%s\033[0m \033[34m~\033[0m $ kitty --version\n' "$host_tag"
  printf '  %s\n' "${ver:-kitty}"
  printf '  \033[32m%s\033[0m \033[34m~\033[0m $ git diff\n' "$host_tag"
  printf '  \033[32m+ linea agregada\033[0m\n'
  printf '  \033[31m- linea eliminada\033[0m\n'
  printf '  \033[33mwarning: algo requiere atencion\033[0m\n'
  printf '  \033[90m# comentario apagado\033[0m\n'
  printf '  \033[36mcyan\033[0m  \033[35mmagenta\033[0m  \033[94mbright-cyan\033[0m  \033[91mbright-red\033[0m\n'
  echo
}

warn() { printf 'aviso: %s\n' "$1" >&2; }

theme_count() {
  local f n=0
  for f in "$THEMES_DIR"/*.conf; do
    [[ -e "$f" ]] && n=$((n+1))
  done
  printf '%s\n' "$n"
}

fetch_collection() {
  local url="$1" label="$2" t="$TMP/coll.$$"
  command -v tar >/dev/null 2>&1 || { warn "sin tar, no puedo bajar $label"; return 1; }
  local dl
  if command -v curl >/dev/null 2>&1; then
    dl=(curl -fsSL "$url" -o)
  elif command -v wget >/dev/null 2>&1; then
    dl=(wget -qO)
  else
    warn "sin curl ni wget, no puedo bajar $label"
    return 1
  fi
  mkdir -p "$t"
  printf 'bajando coleccion %s...\n' "$label" >&2
  "${dl[@]}" "$t/c.tgz" || { warn "fallo la descarga de $label"; rm -rf "$t"; return 1; }
  tar xzf "$t/c.tgz" -C "$t" 2>/dev/null \
    && find "$t" -type f -path '*/themes/*.conf' -exec cp -n {} "$THEMES_DIR"/ \; \
    || warn "no pude extraer $label"
  rm -rf "$t"
}

ensure_themes() {
  mkdir -p "$THEMES_DIR"
  local have
  have="$(theme_count)"
  (( have >= TOTAL_MIN_THEMES )) && return 0
  warn "hay $have temas (umbral $TOTAL_MIN_THEMES) — completando coleccion"
  fetch_collection "$DEXPOTA_URL" "dexpota/kitty-themes"
  fetch_collection "$KITTY_THEMES_URL" "kovidgoyal/kitty-themes (oficial)"
  printf '%s temas disponibles\n' "$(theme_count)" >&2
}

build_list() {
  local f n
  for f in "$THEMES_DIR"/*.conf; do
    [[ -e "$f" ]] || return 0
    n="${f##*/}"
    printf '%s\n' "${n%.conf}"
  done | LC_ALL=C sort -f > "$1"
}

detect_active() {
  [[ -f "$STORED" ]] || return 0
  local crc sz hit
  read -r crc sz _ < <(cksum "$STORED" 2>/dev/null) || return 0
  hit="$(cksum "$THEMES_DIR"/*.conf 2>/dev/null \
        | awk -v c="$crc" -v s="$sz" '$1==c && $2==s {print $3; exit}')" || return 0
  [[ -n "$hit" ]] || return 0
  local n="${hit##*/}"
  printf '%s\n' "${n%.conf}"
}

do_install() {
  local self src bin_dir dst dl_tmp
  src="${BASH_SOURCE[0]:-}"
  bin_dir="${HOME}/.local/bin"
  dst="${bin_dir}/kitty-theme-picker.sh"

  if [[ -n "$src" && -f "$src" ]]; then
    self="$(readlink -f -- "$src")"
    [[ -r "$self" ]] || die "no puedo leer el script fuente ($self)"
  else
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
      || die "necesito curl o wget para descargarme"
    dl_tmp="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "$SELF_URL" -o "$dl_tmp" \
        || die "fallo al descargar desde $SELF_URL"
    else
      wget -qO "$dl_tmp" "$SELF_URL" \
        || die "fallo al descargar desde $SELF_URL"
    fi
    [[ -s "$dl_tmp" ]] || die "descarga vacia desde $SELF_URL"
    chmod 755 "$dl_tmp"
    self="$dl_tmp"
    printf 'descargado desde %s\n' "$SELF_URL"
  fi

  mkdir -p "$bin_dir"

  if [[ -L "$dst" ]]; then
    printf 'script: ya instalado por enlace simbolico (%s -> %s)\n' "$dst" "$(readlink -- "$dst")"
  elif [[ "$self" == "$dst" ]]; then
    printf 'script: ya vive en %s\n' "$dst"
  else
    cp -f -- "$self" "$dst"
    chmod 755 "$dst"
    printf 'script: copiado a %s\n' "$dst"
  fi

  [[ -n "${dl_tmp:-}" ]] && rm -f "$dl_tmp"

  case ":$PATH:" in
    *":$bin_dir:"*) printf 'path: %s en PATH\n' "$bin_dir" ;;
    *) warn "$bin_dir no esta en PATH - agregalo al profile de tu shell" ;;
  esac

  local c
  for c in fzf kitty awk sort cksum tar; do
    command -v "$c" >/dev/null 2>&1 || warn "dependencia faltante: $c"
  done
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || warn "sin curl ni wget: no voy a poder descargar temas"

  ensure_themes
  printf '%s temas disponibles en %s\n' "$(theme_count)" "$THEMES_DIR"

  local kc_conf="${HOME}/.config/kitty/kitty.conf"
  if [[ ! -f "$kc_conf" ]]; then
    warn "no existe $kc_conf - crealo antes de usar el preview en vivo"
  elif ! grep -Eq '^[[:space:]]*allow_remote_control[[:space:]]+(yes|socket-only)' "$kc_conf" \
     || ! grep -Eq '^[[:space:]]*listen_on[[:space:]]+unix:/tmp/kitty-theme-sync' "$kc_conf"; then
    warn "a kitty.conf le faltan las lineas de IPC para el preview en vivo:"
    printf '  allow_remote_control yes\n' >&2
    printf '  listen_on unix:/tmp/kitty-theme-sync-{kitty_pid}\n' >&2
  else
    printf 'ipc de kitty: OK\n'
  fi

  printf 'listo - ejecuta "%s" dentro de una ventana de kitty\n' "$dst"
}

do_refresh() {
  local before after
  mkdir -p "$THEMES_DIR"
  before="$(theme_count)"
  printf 'actualizando catalogo de temas...\n'
  fetch_collection "$DEXPOTA_URL" "dexpota/kitty-themes"
  fetch_collection "$KITTY_THEMES_URL" "kovidgoyal/kitty-themes (oficial)"
  after="$(theme_count)"
  printf 'catalogo al dia: %s -> %s temas (%s nuevos)\n' "$before" "$after" "$((after - before))"
}

main() {
  check_deps
  ensure_themes

  take_snapshot || die "sin IPC de kitty (¿hay una ventana abierta con allow_remote_control?)"

  trap restore_original INT TERM

  local list="$TMP/list.txt"
  build_list "$list"

  local pos=0 cur
  cur="$(detect_active)"
  if [[ -n "$cur" ]]; then
    pos="$(grep -nFx -- "$cur" "$list" 2>/dev/null)"
    pos="${pos%%:*}"
  fi

  local args
  args=(--height=100% --reverse
        --header='Enter: aplicar y guardar   Esc: cancelar y restaurar'
        --preview "$0 --preview {}"
        --preview-window 'right:58%:wrap'
        --bind "focus:execute-silent($0 --apply {})")
  if [[ "$pos" =~ ^[0-9]+$ ]] && (( pos >= 1 )) && fzf_has_pos; then
    args+=(--sync --bind "start:pos($pos)")
  fi

  local choice status
  choice="$(fzf "${args[@]}" < "$list")"
  status=$?

  trap - INT TERM

  if [[ "$status" -eq 0 && -n "$choice" ]]; then
    cp -f "$(resolve_theme "$choice")" "$STORED"
    printf 'tema aplicado y guardado: %s\n' "$choice"
  else
    restore_original
    echo 'cancelado — colores originales restaurados'
  fi
}

case "${1:-}" in
  -h|--help|help) usage ;;
  install)        do_install ;;
  refresh)        do_refresh ;;
  --preview)      do_preview "$2" ;;
  --apply)        do_apply "$2" ;;
  *)
    if [[ ! -f "${BASH_SOURCE[0]:-}" ]]; then
      do_install
    else
      main
    fi ;;
esac
