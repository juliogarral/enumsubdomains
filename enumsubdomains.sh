#!/usr/bin/env bash
set -euo pipefail

# enum_subdomains.sh

# --- Banner ASCII ---
cat <<'EOF'
                                        ___.        .___                           .__               
  ____   ____  __ __  _____   ________ _\_ |__    __| _/____   _____   ____ _____  |__| ____   ______
_/ __ \ /    \|  |  \/     \ /  ___/  |  \ __ \  / __ |/  _ \ /     \ /    \\__  \ |  |/    \ /  ___/
\  ___/|   |  \  |  /  Y Y  \\___ \|  |  / \_\ \/ /_/ (  <_> )  Y Y  \   |  \/ __ \|  |   |  \\___ \ 
 \___  >___|  /____/|__|_|  /____  >____/|___  /\____ |\____/|__|_|  /___|  (____  /__|___|  /____  >
     \/     \/            \/     \/          \/      \/            \/     \/     \/        \/     \/  
EOF

# --- Argument check ---
if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <domain>"
  exit 1
fi

DOMAIN="$1"
OUTFILE="subdomains.txt"
ALIVE_OUT="alive_subdomains.txt"
TMPDIR="$(mktemp -d)"
ASSETFINDER_OUT="$TMPDIR/assetfinder.txt"
SUBDOMAINFINDER_OUT="$TMPDIR/subdomainfinder.txt"
CRTSH_OUT="$TMPDIR/crtsh.txt"

# --- Cleanup function ---
cleanup() {
    rm -rf "$TMPDIR"
}
trap cleanup EXIT

# --- Handle Ctrl+C ---
ctrl_c_handler() {
    echo -e "\n[!] Detected Ctrl+C. Exiting..."
    cleanup
    exit 130
}
trap ctrl_c_handler SIGINT

# --- Tool checks ---
missing=0
if ! command -v assetfinder >/dev/null 2>&1; then
  echo "Warning: assetfinder not found in PATH."
  missing=1
fi

if command -v subdomainfinder >/dev/null 2>&1; then
  SUBFINDER_CMD="subdomainfinder"
elif command -v subfinder >/dev/null 2>&1; then
  SUBFINDER_CMD="subfinder"
else
  echo "Warning: neither subdomainfinder nor subfinder found in PATH."
  SUBFINDER_CMD=""
  missing=1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required for crt.sh."
  exit 1
fi

if [[ $missing -eq 1 ]]; then
  echo "Some tools are missing. The script will continue with available sources."
fi

# --- assetfinder ---
if command -v assetfinder >/dev/null 2>&1; then
  echo "[*] Running assetfinder for: $DOMAIN"
  assetfinder --subs-only "$DOMAIN" 2>/dev/null | sed 's/^\*\.//; s/\*\.//g' | sort -u > "$ASSETFINDER_OUT" || true
fi

# --- subfinder/subdomainfinder ---
if [[ -n "${SUBFINDER_CMD}" ]] && command -v "$SUBFINDER_CMD" >/dev/null 2>&1; then
  echo "[*] Running $SUBFINDER_CMD for: $DOMAIN"
  if "$SUBFINDER_CMD" --help 2>&1 | grep -q -- "-silent"; then
    "$SUBFINDER_CMD" -d "$DOMAIN" -silent 2>/dev/null | sed 's/^\*\.//; s/\*\.//g' | sort -u > "$SUBDOMAINFINDER_OUT" || true
  else
    "$SUBFINDER_CMD" -d "$DOMAIN" 2>/dev/null | sed 's/^\*\.//; s/\*\.//g' | sort -u > "$SUBDOMAINFINDER_OUT" || true
  fi
fi

# --- crt.sh ---
echo "[*] Querying crt.sh for: $DOMAIN"
ESCAPED_DOMAIN="$(printf '%s' "$DOMAIN" | sed 's/\./\\./g')"
curl -s "https://crt.sh/?q=%25.$DOMAIN" \
  | grep -oP "(?<=<TD>)[a-zA-Z0-9._-]+\\.$ESCAPED_DOMAIN(?=</TD>)" \
  | sed 's/^\*\.//; s/\*\.//g' \
  | sort -u > "$CRTSH_OUT" || true

# --- Combine results ---
echo "[*] Combining results and removing duplicates..."
cat "$ASSETFINDER_OUT" "$SUBDOMAINFINDER_OUT" "$CRTSH_OUT" 2>/dev/null \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
  | grep -E "\.$(printf '%s' "$DOMAIN" | sed 's/\./\\./g')$" \
  | sort -u > "$OUTFILE"

echo "[+] Results written to: $OUTFILE"
echo "[+] Total unique subdomains: $(wc -l < "$OUTFILE")"

# --- Check live subdomains ---
if [[ ! -s "$OUTFILE" ]]; then
  echo "[!] subdomains.txt is empty. Nothing to check."
  exit 0
fi

if command -v httpx >/dev/null 2>&1; then
  echo "[*] Checking live hosts with httpx..."
  cat "$OUTFILE" | httpx -silent -o "$ALIVE_OUT" 2>/dev/null
  echo "[+] Live hosts saved to: $ALIVE_OUT"
else
  echo "[*] httpx not found, using curl fallback..."
  check_with_curl() {
    HOST="$1"
    if curl -s -I --max-time 5 -L "https://$HOST" >/dev/null 2>&1; then echo "$HOST"; 
    elif curl -s -I --max-time 5 -L "http://$HOST" >/dev/null 2>&1; then echo "$HOST"; fi
  }
  export -f check_with_curl
  awk 'NF && $0 !~ /^#/ {print $0}' "$OUTFILE" \
    | xargs -n1 -P40 -I{} bash -c 'check_with_curl "$@"' _ {} \
    > "$ALIVE_OUT" 2>/dev/null
  echo "[+] Live hosts saved to: $ALIVE_OUT"
fi

# --- No "Enumeration complete" message if interrupted ---
if [[ $? -eq 130 ]]; then
  exit 130
fi

echo "✅ Enumeration complete."
