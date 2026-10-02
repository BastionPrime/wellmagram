#!/usr/bin/env bash
# net_audit.sh — network egress audit for release-build pcaps (plan T-0.9/T-5.6).
#
# Extracts DNS query names and TLS SNI names from a pcap file (or a live
# interface), compares them against the whitelist in net_audit_hosts.txt and
# exits 1 when any host outside the whitelist is found.
#
# Usage:
#   tools/net_audit.sh <file.pcap> [--report]
#   tools/net_audit.sh --flavor google|foss <file.pcap>   (FCM gate)
#   tools/net_audit.sh --live <iface> [--seconds N]       (root/cap_net_raw)
#
# Dependencies: bash, tshark, tcpdump (only for --live).
# Exit codes: 0 = all hosts whitelisted, 1 = unknown host found,
#             2 = usage/dependency error.
#
# No root is needed when auditing an existing pcap file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHITELIST_FILE="${SCRIPT_DIR}/net_audit_hosts.txt"

MODE="file"          # file | live
PCAP=""
IFACE=""
SECONDS_TO_CAPTURE=10
FLAVOR="google"      # default flavor: FCM hosts allowed
REPORT=0

usage() {
    cat <<USAGE
net_audit.sh — egress audit: DNS names + TLS SNI vs whitelist

  tools/net_audit.sh <file.pcap> [--report]
      Audit an existing pcap (tshark; text2pcap/PCAPdroid output works too).
  tools/net_audit.sh --live <iface> [--seconds N] [--report]
      Capture N seconds on <iface> with tcpdump, then audit (needs root).
  tools/net_audit.sh --flavor google|foss <file.pcap>
      foss: FCM hosts (mtalk.google.com, fcm.googleapis.com) are forbidden.

Options:
  --report        print a per-host summary table in addition to findings
  --seconds N     live capture length (default 10)
  --hosts FILE    override whitelist path (default tools/net_audit_hosts.txt)
USAGE
}

die2() { echo "net_audit: $*" >&2; exit 2; }

ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --report) REPORT=1 ;;
        --live) MODE="live" ;;
        --flavor) shift; FLAVOR="${1:-}"; [ -n "$FLAVOR" ] || die2 "--flavor needs a value" ;;
        --seconds) shift; SECONDS_TO_CAPTURE="${1:-}"; [ -n "$SECONDS_TO_CAPTURE" ] || die2 "--seconds needs a value" ;;
        --hosts) shift; WHITELIST_FILE="${1:-}"; [ -n "$WHITELIST_FILE" ] || die2 "--hosts needs a value" ;;
        -h|--help) usage; exit 0 ;;
        -*) die2 "unknown option: $1" ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

if [ "${MODE}" = "live" ]; then
    command -v tcpdump >/dev/null 2>&1 || die2 "tcpdump not found (required for --live)"
    [ ${#ARGS[@]} -gt 1 ] && die2 "--live takes an interface name, not a file"
    IFACE="${ARGS[0]:-}"
    [ -n "$IFACE" ] || die2 "--live requires an interface name"
    [ "$EUID" -eq 0 ] || die2 "--live requires root (raw socket capture)"
    TMP_PCAP="$(mktemp "${TMPDIR:-/tmp}/net_audit_live.XXXXXX.pcap")"
    trap 'rm -f "$TMP_PCAP"' EXIT
    echo "net_audit: capturing ${SECONDS_TO_CAPTURE}s on ${IFACE} (tcpdump)..." >&2
    tcpdump -i "$IFACE" -s 0 -G "$SECONDS_TO_CAPTURE" -W 1 -w "$TMP_PCAP" 'port 53 or port 443' >/dev/null 2>&1
    PCAP="$TMP_PCAP"
else
    [ ${#ARGS[@]} -eq 1 ] || { usage >&2; die2 "exactly one pcap file expected"; }
    PCAP="${ARGS[0]}"
    [ -f "$PCAP" ] || die2 "pcap not found: $PCAP"
fi

command -v tshark >/dev/null 2>&1 || die2 "tshark not found (install tshark/wireshark-cli)"
[ -r "$WHITELIST_FILE" ] || die2 "whitelist not readable: $WHITELIST_FILE"

# ---------------------------------------------------------------- whitelist --
# Normalized whitelist: lowercase, one host per line, comments stripped.
WL="$(grep -Ev '^[[:space:]]*(#|$)' "$WHITELIST_FILE" | tr '[:upper:]' '[:lower:]' | sort -u || true)"

# FCM gate: in foss flavor the FCM hosts are forbidden.
FCM_HOSTS="mtalk.google.com
fcm.googleapis.com"
case "$FLAVOR" in
    google) : ;;
    foss)   WL="$(comm -23 <(printf '%s\n' "$WL") <(printf '%s\n' "$FCM_HOSTS" | sort))" ;;
    *)      die2 "flavor must be 'google' or 'foss' (got: $FLAVOR)" ;;
esac

in_whitelist() {
    # exact or subdomain-of-whitelisted match: a whitelist entry "max.ru"
    # whitelists "cdn.max.ru" but "max.ru.evil.net" does not match, because
    # we walk the *suffix labels* of the queried name only.
    local h="$1"
    while [ -n "$h" ]; do
        if printf '%s\n' "$WL" | grep -Fxq "$h"; then return 0; fi
        case "$h" in
            *.*) h="${h#*.}" ;;
            *)   break ;;
        esac
    done
    return 1
}

# ---------------------------------------------------------------- extraction --
# DNS query names (all record types; PCAPdroid and text2pcap output both
# dissect cleanly with a single -r pass).
dns_names() {
    tshark -r "$PCAP" -Y 'dns.flags.response == 0' -T fields \
        -e dns.qry.name 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# SNI names from TLS ClientHello (works for classic TLS; QUIC CRYPTO frames
# are dissected by recent tshark versions as tls too).
sni_names() {
    tshark -r "$PCAP" -Y 'tls.handshake.extensions_server_name' -T fields \
        -e tls.handshake.extensions_server_name 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# All unique observed names: trailing dots stripped (DNS wire form), lowercased.
ALL="$( { dns_names; sni_names; } | sed 's/[[:space:]]*$//; s/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u )"

if [ -z "$ALL" ]; then
    echo "net_audit: no DNS names or SNI found in $PCAP — nothing to audit (OK)."
    [ "$REPORT" -eq 1 ] && echo "report: 0 hosts observed, 0 unknown."
    exit 0
fi

# ---------------------------------------------------------------- decision --
UNKNOWN=""
KNOWN=""
while IFS= read -r host; do
    [ -n "$host" ] || continue
    if in_whitelist "$host"; then
        KNOWN+="$host"$'\n'
    else
        UNKNOWN+="$host"$'\n'
    fi
done <<< "$ALL"

exit_code=0
if [ -n "$UNKNOWN" ]; then
    echo "net_audit: FAIL — hosts outside the whitelist ($WHITELIST_FILE):" >&2
    sed '/^$/d' <<< "$UNKNOWN" | sed 's/^/  unknown: /' >&2
    exit_code=1
else
    echo "net_audit: OK — every observed host is whitelisted."
fi

if [ "$REPORT" -eq 1 ]; then
    n_total=$(grep -c . <<< "$ALL" || true)
    n_known=$(printf '%s' "$KNOWN" | grep -c . || true)
    n_unknown=$(printf '%s' "$UNKNOWN" | grep -c . || true)
    echo
    echo "=== report ==="
    echo "pcap:       $PCAP"
    echo "flavor:     $FLAVOR"
    echo "whitelist:  $WHITELIST_FILE ($(printf '%s\n' "$WL" | grep -c .) entries)"
    echo "observed:   $n_total host(s)"
    echo "known:      $n_known"
    echo "unknown:    $n_unknown"
    echo "--- per-host ---"
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        if printf '%s' "$UNKNOWN" | grep -Fxq "$host"; then
            echo "  UNKNOWN  $host"
        else
            echo "  ok       $host"
        fi
    done <<< "$ALL"
fi

exit "$exit_code"
