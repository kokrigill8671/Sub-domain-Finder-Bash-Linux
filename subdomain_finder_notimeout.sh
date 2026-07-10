#!/usr/bin/env bash
#
# subdomain_finder_notimeout.sh
#
# Passive subdomain discovery via crt.sh (Certificate Transparency logs)
# + active check to see which discovered subdomains respond over HTTP/HTTPS.
#
# This is a bash port of subdomain_finder_notimeout.py. Request timeouts are
# DISABLED (curl --max-time is not set), so requests wait indefinitely for a
# response instead of erroring out. This trades "fails fast with a retry"
# for "never gives up on a slow response" — useful on flaky/slow networks,
# but a genuinely dead host can hang forever unless you Ctrl+C.
#
# USAGE:
#   ./subdomain_finder_notimeout.sh example.com
#   ./subdomain_finder_notimeout.sh example.com --threads 30
#   ./subdomain_finder_notimeout.sh example.com --retries 8 --alive-retries 2
#
# REQUIREMENTS:
#   curl, jq
#
# ONLY run this against domains you own or are authorized to test.
#
set -u -o pipefail

# ---------------------------------------------------------------------------
# Defaults (mirrors the Python script's argparse defaults)
# ---------------------------------------------------------------------------
THREADS=20            # concurrent liveness-check jobs
ALIVE_RETRIES=2        # retry attempts per scheme (http/https) on connection errors
CRT_RETRIES=8          # max retry attempts for crt.sh on 429/500/502/503/504 or empty results

RETRY_BACKOFF_BASE=5   # seconds; grows as BASE * attempt
RETRY_BACKOFF_MAX=60   # cap so it doesn't grow unbounded

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $0 <domain> [--threads N] [--alive-retries N] [--retries N]"
    echo
    echo "  <domain>            Target domain, e.g. example.com"
    echo "  --threads N         Concurrent liveness-check jobs (default: ${THREADS})"
    echo "  --alive-retries N   Retry attempts per scheme http/https on connection"
    echo "                      errors during liveness checks (default: ${ALIVE_RETRIES})"
    echo "  --retries N         Max retry attempts for crt.sh on rate-limit/server"
    echo "                      errors or empty responses (default: ${CRT_RETRIES})"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

DOMAIN="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --threads)
            THREADS="$2"; shift 2 ;;
        --alive-retries)
            ALIVE_RETRIES="$2"; shift 2 ;;
        --retries)
            CRT_RETRIES="$2"; shift 2 ;;
        -h|--help)
            usage ;;
        *)
            echo "[!] Unknown argument: $1"
            usage ;;
    esac
done

# Lowercase + trim the domain (bash equivalent of domain.strip().lower())
DOMAIN="$(echo "${DOMAIN}" | tr '[:upper:]' '[:lower:]' | xargs)"

if ! command -v curl >/dev/null 2>&1; then
    echo "[!] curl is required but not installed. See README.md for install instructions."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "[!] jq is required but not installed. See README.md for install instructions."
    exit 1
fi

RAW_FILE="subdomains_raw_${DOMAIN}.txt"
ALIVE_FILE="subdomains_alive_${DOMAIN}.txt"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# backoff_sleep <attempt>
backoff_sleep() {
    local attempt="$1"
    local wait=$(( RETRY_BACKOFF_BASE * attempt ))
    if (( wait > RETRY_BACKOFF_MAX )); then
        wait="${RETRY_BACKOFF_MAX}"
    fi
    echo "[*] Waiting ${wait}s before retrying (crt.sh rate-limit cooldown)..."
    sleep "${wait}"
}

# is_retryable_status <code> -> 0 (true) if in the retryable set
is_retryable_status() {
    case "$1" in
        429|500|502|503|504) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# get_subdomains: query crt.sh, with retry on throttling/empty responses
# ---------------------------------------------------------------------------
get_subdomains() {
    local url="https://crt.sh/?q=%25.${DOMAIN}&output=json"
    local body_file="${WORKDIR}/crt_body.json"
    local attempt

    for (( attempt=1; attempt<=CRT_RETRIES; attempt++ )); do
        echo "[*] Querying crt.sh for subdomains of: ${DOMAIN} (attempt ${attempt}/${CRT_RETRIES}, no timeout)..."

        # --max-time is intentionally omitted -> waits indefinitely for a response
        local http_code
        http_code=$(curl -s -o "${body_file}" -w "%{http_code}" \
            -A "Mozilla/5.0" "${url}")
        local curl_status=$?

        if [[ ${curl_status} -ne 0 ]]; then
            echo "[!] Attempt ${attempt}/${CRT_RETRIES} failed (curl exit ${curl_status}, connection error). Retrying..."
            if (( attempt < CRT_RETRIES )); then backoff_sleep "${attempt}"; fi
            continue
        fi

        echo "HTTP Status: ${http_code}"

        if is_retryable_status "${http_code}"; then
            echo "[!] Attempt ${attempt}/${CRT_RETRIES}: got HTTP ${http_code} (server likely overloaded/rate-limiting). Retrying..."
            if (( attempt < CRT_RETRIES )); then backoff_sleep "${attempt}"; fi
            continue
        fi

        if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
            echo "[!] Error contacting crt.sh: HTTP ${http_code}"
            if (( attempt < CRT_RETRIES )); then backoff_sleep "${attempt}"; continue; fi
            return 1
        fi

        if ! jq empty "${body_file}" >/dev/null 2>&1; then
            echo "[!] crt.sh returned invalid JSON (it may be rate-limiting you)."
            if (( attempt < CRT_RETRIES )); then backoff_sleep "${attempt}"; continue; fi
            return 1
        fi

        local record_count
        record_count=$(jq 'length' "${body_file}")
        echo "Number of records: ${record_count}"

        if [[ "${record_count}" -eq 0 ]]; then
            if (( attempt < CRT_RETRIES )); then
                echo "[!] Got 0 records — likely a rate-limit, not a real empty result. Retrying..."
                backoff_sleep "${attempt}"
                continue
            else
                echo "[!] Still 0 records after all retries — treating as a genuine empty result."
                return 1
            fi
        fi

        # Extract name_value fields, split on newlines, normalize, filter,
        # and keep only entries that end with the target domain.
        jq -r '.[].name_value' "${body_file}" \
            | tr '[:upper:]' '[:lower:]' \
            | while IFS= read -r line; do
                line="$(echo "${line}" | xargs)"        # trim whitespace
                [[ "${line}" == \*.* ]] && line="${line:2}"
                [[ "${line}" == *"*"* ]] && continue
                [[ "${line}" == *"${DOMAIN}" ]] && echo "${line}"
              done \
            | sort -u > "${RAW_FILE}.tmp"

        local sub_count
        sub_count=$(wc -l < "${RAW_FILE}.tmp" | xargs)
        echo "Subdomains collected: ${sub_count}"

        mv "${RAW_FILE}.tmp" "${RAW_FILE}"
        return 0
    done

    echo "[!] Giving up after ${CRT_RETRIES} attempts."
    return 1
}

# ---------------------------------------------------------------------------
# check_alive: try HTTPS then HTTP, no timeout, retrying connection errors
# ---------------------------------------------------------------------------
# Usage: check_alive <subdomain> <alive_retries>
# Prints "url|status_code|scheme" on success, nothing on failure.
check_alive() {
    local subdomain="$1"
    local retries="$2"
    local scheme url attempt http_code curl_status

    for scheme in https http; do
        url="${scheme}://${subdomain}"
        for (( attempt=1; attempt<=retries; attempt++ )); do
            # -L follows redirects; --max-time intentionally omitted (no timeout)
            http_code=$(curl -s -o /dev/null -L -w "%{http_code}" "${url}")
            curl_status=$?

            if [[ ${curl_status} -eq 0 ]]; then
                echo "${url}|${http_code}|${scheme}"
                return 0
            elif [[ ${curl_status} -eq 6 || ${curl_status} -eq 7 ]]; then
                # 6 = could not resolve host, 7 = failed to connect -> retry this scheme
                continue
            else
                # Non-retryable error (e.g. SSL/cert error) -> try next scheme
                break
            fi
        done
    done
    return 1
}
export -f check_alive
export -f is_retryable_status

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    if ! get_subdomains; then
        echo "[!] No subdomains found."
        exit 0
    fi

    local sub_count
    sub_count=$(wc -l < "${RAW_FILE}" | xargs)
    echo "[+] Found ${sub_count} unique subdomains (saved to ${RAW_FILE})"

    echo "[*] Checking liveness with ${THREADS} threads (no timeout, retries=${ALIVE_RETRIES})..."

    # Run liveness checks in parallel using xargs, capture "ALIVE" lines
    : > "${WORKDIR}/alive_raw.txt"
    export -f check_alive
    export ALIVE_RETRIES

    cat "${RAW_FILE}" | xargs -P "${THREADS}" -I{} bash -c '
        result="$(check_alive "{}" "'"${ALIVE_RETRIES}"'")"
        if [[ -n "${result}" ]]; then
            IFS="|" read -r url code scheme <<< "${result}"
            echo "[ALIVE][${scheme}] {} -> ${code}"
            echo "${url} [${code}]" >> "'"${WORKDIR}"'/alive_raw.txt"
        fi
    '

    sort -u "${WORKDIR}/alive_raw.txt" > "${ALIVE_FILE}" 2>/dev/null || touch "${ALIVE_FILE}"

    local alive_count
    alive_count=$(wc -l < "${ALIVE_FILE}" | xargs)

    echo
    echo "[+] Done. ${alive_count} alive subdomains saved to: ${ALIVE_FILE}"
    echo "=================================================="
    echo "Total Found : ${sub_count}"
    echo "Alive       : ${alive_count}"
    echo "=================================================="
}

main
