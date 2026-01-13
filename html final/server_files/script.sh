#!/usr/bin/env bash
set -euo pipefail

# path cache
CACHE_DIR="${CACHE_DIR:-/var/www/html/cache}"
# marime default 500 KiB (in bytes).
CACHE_MAX_BYTES="${CACHE_MAX_BYTES:-512000}"
TMP_SUFFIX=".tmp.$$"
# fisier lock ca sa nu apara erori daca se acceseaza cacheul de mai multe ori simultan
LOCKFILE="${CACHE_DIR}/.cache_lock"

URL="${1:-}"

usage() {
    cat >&2 <<EOF
Usage: $0 <url>
Environment:
  CACHE_DIR        directory to store cached files (default: /var/www/html/cache)
  CACHE_MAX_BYTES  max total size of files in cache in bytes (default: 512000 = 500KiB)
EOF
    exit 1
}

if [[ -z "$URL" ]]; then
    echo "Error: No URL provided" >&2
    usage
fi

if [[ ! "$URL" =~ ^https?:// ]]; then
    echo "Error: Invalid URL" >&2
    exit 1
fi

# asiguram ca exista cacheul si lockul
mkdir -p "$CACHE_DIR"
touch "$LOCKFILE"
# 
exec 200>"$LOCKFILE"
flock -x 200

# functii
# verificam spatiul ocupat curent
cache_used() {
    find "$CACHE_DIR" -maxdepth 1 -type f -print0 2>/dev/null | \
        xargs -0 -r stat -c '%s' 2>/dev/null | awk '{s+=$1} END {print s+0}'
}

# scoate cel mai vechi fisier din cache, returneaza 0 daca a sters ceva, 1 daca nu a sters nimic
evict_oldest() {
    # se uita doar prin fisere normale
    local oldest
    oldest=$(find "$CACHE_DIR" -maxdepth 1 -type f ! -name "$(basename "$LOCKFILE")" ! -name "*${TMP_SUFFIX}" -printf '%T@ %p\n' 2>/dev/null \
        | sort -n -k1,1 | head -n1 | awk '{$1=""; sub(/^ /,""); print}')
    if [[ -n "$oldest" ]]; then
        rm -f -- "$oldest" || return 1
        return 0
    fi
    return 1
}

# asiguram ca este destul spatiu.
# Returneaza 0 daca e destul, 1 altfel.
ensure_free_bytes() {
    local need="$1"
    if [[ "$need" -le 0 ]]; then
        return 0
    fi

    local used available
    used=$(cache_used)
    available=$((CACHE_MAX_BYTES - used))

    # daca spatiul disponibil e mai mare decat cel necesar am terminat
    if [[ "$available" -ge "$need" ]]; then
        return 0
    fi

    # stergem fisiere pana avem destul spatiu sau nu mai exista fisiere de sters.
    while [[ "$available" -lt "$need" ]]; do
        if ! evict_oldest; then
            # nu au mai ramas fisiere
            return 1
        fi
        used=$(cache_used)
        available=$((CACHE_MAX_BYTES - used))
    done

    return 0
}

# dam un nume generat unic fisierului descarcat
FILENAME="$(printf '%s' "$URL" | sha256sum | awk '{print $1}').html"
FILEPATH="$CACHE_DIR/$FILENAME"

# daca fisierul este in cache, ii updatam mtime (devine utilizat recent) asi returnam pathul
if [[ -f "$FILEPATH" ]]; then
    # updatam mtime
    touch -m -- "$FILEPATH" || true
    echo "$FILEPATH"
    exit 0
fi

# incercam sa determinam marimea fisierelor inainte de descarcare din header.
remote_size=""
# folosim curl ca sa luam headerul
if headers="$(curl -sS -I -L "$URL" 2>/dev/null || true)"; then
    # ne uitam dupa content lenght
    remote_size=$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ {print $2; exit}' | tr -d '\r')
    if [[ -z "$remote_size" ]]; then
        # incercam un request partial si cautam informatie de genul "bytes 0-0/12345"
        if headers="$(curl -sS -L -r 0-0 -I "$URL" 2>/dev/null || true)"; then
            cr=$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^Content-Range:/ {print $2; exit}' | tr -d '\r')
            if [[ -n "$cr" ]]; then
                # extragem totalul de dupa slash
                remote_size=$(printf '%s' "$cr" | awk -F/ '{print $2}')
            else
                # incercare de fallback
                remote_size=$(printf '%s\n' "$headers" | awk 'BEGIN{IGNORECASE=1} /^Content-Length:/ {print $2; exit}' | tr -d '\r')
            fi
        fi
    fi
fi

# transformam marimea intr-un integer
if [[ -n "${remote_size:-}" ]]; then
    # scoatem non cifrele
    remote_size="$(printf '%s' "$remote_size" | sed 's/[^0-9].*$//')"
    if [[ -z "$remote_size" ]]; then
        remote_size=""
    fi
fi

# daca stim marimea fisierului pe care vrem sa il descarcam e mai mare decat cacheul nu il descarcam
if [[ -n "${remote_size:-}" ]] && (( remote_size > CACHE_MAX_BYTES )); then
    echo "Error: remote file size (${remote_size} bytes) exceeds cache maximum (${CACHE_MAX_BYTES} bytes). Not downloading." >&2
    exit 1
fi

# daca stim marimea ne asiguram ca incape prin stergeri de fisiere
if [[ -n "${remote_size:-}" ]]; then
    need_bytes="$remote_size"
    if ! ensure_free_bytes "$need_bytes"; then
        echo "Error: Unable to make ${need_bytes} bytes free in cache (CACHE_MAX_BYTES=${CACHE_MAX_BYTES})." >&2
        exit 1
    fi
    # descarcam direct in locatie cu un fisier temporar
    TMPFILE="${FILEPATH}${TMP_SUFFIX}"
    # utilizam wget pentru download si stergem fisierul temporar daca apar probleme
    if ! wget -q --timeout=30 --tries=3 -O "$TMPFILE" -- "$URL"; then
        echo "Error: download failed" >&2
        rm -f -- "$TMPFILE"
        exit 1
    fi
    # verificam daca marimea reala este egala cu cea asteptata
    dl_size=$(stat -c '%s' "$TMPFILE" 2>/dev/null || echo 0)
    if [[ "$dl_size" -ne "$remote_size" ]]; then
        if (( dl_size > CACHE_MAX_BYTES )); then
            rm -f -- "$TMPFILE"
            echo "Error: downloaded file (${dl_size} bytes) exceeds cache maximum (${CACHE_MAX_BYTES} bytes)." >&2
            exit 1
        fi
    fi
    # setam permisiuni pentru fisier
    chmod 0644 "$TMPFILE" || true
    # il mutam in locatia corespunzatoare
    mv -f -- "$TMPFILE" "$FILEPATH"
    # il updatam ca utilizat recent
    touch -m -- "$FILEPATH" || true
    echo "$FILEPATH"
    exit 0
fi

# daca ajungem aici nu putem afla marimea inainte de download, deci downloadam separat si vedem daca ar incapea in cache.

TMPFILE="${FILEPATH}${TMP_SUFFIX}"

# downloadam un fisier temporar si verificam marimea daca este prea mare iesim cu o eroare.
if ! wget -q --timeout=30 --tries=3 -O "$TMPFILE" -- "$URL"; then
    echo "Error: download failed" >&2
    rm -f -- "$TMPFILE"
    exit 1
fi

dl_size=$(stat -c '%s' "$TMPFILE" 2>/dev/null || echo 0)

if (( dl_size > CACHE_MAX_BYTES )); then
    rm -f -- "$TMPFILE"
    echo "Error: downloaded file (${dl_size} bytes) exceeds cache maximum (${CACHE_MAX_BYTES} bytes). Not caching." >&2
    exit 1
fi

# daca current used + dl_size e mai mare decat CACHE_MAX_BYTES, stergem fisiere pana avem destul loc
used=$(cache_used)
available=$((CACHE_MAX_BYTES - used))
if (( available < dl_size )); then
    need=$((dl_size - available))
    if ! ensure_free_bytes "$need"; then
        rm -f -- "$TMPFILE"
        echo "Error: Unable to make space for downloaded file (${dl_size} bytes)." >&2
        exit 1
    fi
fi

# mutam temp fileul in locatia corecta si ii updatam permisiunile
chmod 0644 "$TMPFILE" || true
mv -f -- "$TMPFILE" "$FILEPATH" || { rm -f -- "$TMPFILE"; echo "Error: failed to move temp file into cache." >&2; exit 1; }
touch -m -- "$FILEPATH" || true
echo "$FILEPATH"
exit 0
