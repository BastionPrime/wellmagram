# tools/net_audit.sh — network egress audit of release builds

`net_audit.sh` extracts every DNS query name and every TLS SNI name from a
packet capture of the running app and compares them against the whitelist in
`tools/net_audit_hosts.txt`. Any host outside the whitelist fails the audit
(exit code 1). This is the release-checklist item from plan T-0.9/T-5.6: the
release build must talk only to the hosts it is allowed to talk to.

## Whitelist format

`tools/net_audit_hosts.txt` — one hostname per line, `#` starts a comment.
A whitelist entry covers its subdomains too: an entry `cdn.max.ru`
whitelists `video.cdn.max.ru`, but `evil.max.ru.attacker.net` does NOT match
(suffix-label matching only, so an attacker cannot smuggle a foreign host
through a whitelisted-looking prefix).

Current whitelist groups: MAX backend (`api.oneme.ru`, `api2.oneme.ru`),
MAX media (`cdn.max.ru`, `media.max.ru`), Telegram DC/MTProto endpoints,
`static.telegram.org`, and — **google flavor only** — the FCM hosts
(`mtalk.google.com`, `fcm.googleapis.com`).

## How to capture a trace (plan §6.4 reference)

On a rooted device / dev phone:

    adb root && adb shell tcpdump -i any -s 0 -w /sdcard/trace.pcap 'port 53 or port 443'
    # exercise the app for 1–2 minutes (login, chat open, media load, push), then:
    adb pull /sdcard/trace.pcap

Without root, use PCAPdroid (no-root capture, exports standard pcap) or
collect on the Wi-Fi AP/router with tcpdump. A text2pcap-reconstructed file
also works — the script only needs tshark to dissect it.

On a workstation with the emulator on the same box:

    sudo tcpdump -i <iface> -s 0 -w trace.pcap 'port 53 or port 443'

Capture both ports 53 (DNS) and 443 (TLS); the audit reads only DNS query
names and TLS ClientHello SNI, never payload data.

## How to run

    # audit a finished pcap (no root needed):
    tools/net_audit.sh trace.pcap

    # with a summary table:
    tools/net_audit.sh trace.pcap --report

    # foss flavor: FCM hosts are forbidden (fail if present):
    tools/net_audit.sh --flavor foss trace.pcap

    # live capture + audit in one step (needs root):
    sudo tools/net_audit.sh --live wlan0 --seconds 120 --report

Exit codes: `0` — every observed host is whitelisted; `1` — at least one
host outside the whitelist; `2` — usage/dependency error (missing tshark,
missing file, bad flavor…).

Dependencies: `tshark` (Wireshark CLI) for pcap analysis; `tcpdump` only for
`--live`. Run `--help` for the full option list.

## What to do when an audit fails (unknown host found)

1. Look at the reported host in the `UNKNOWN` list. Classify it:
   - **Known app dependency missing from the whitelist** (e.g. a new MAX
     media CDN): verify the host in the backend docs / code
     (`lib/core/backends/...`), then add it to `net_audit_hosts.txt` with a
     comment naming the source, and re-run the audit in the PR.
   - **OS/Google-play services noise** (e.g. `time.android.com`, update
     servers): decide whether the build under test is `google` or `foss`
     flavor; for foss builds such traffic is a real finding — report it,
     do not whitelist.
   - **Unexpected third party** (analytics, ads, crash reporters): this is
     a privacy finding — do NOT whitelist. File it with the pcap excerpt and
     the exact packet numbers (`tshark -r trace.pcap -Y 'dns.qry.name ==
     "<host>"'`).
2. Re-run with `--report` and attach the summary to the release checklist.
3. Never widen the whitelist to make an audit pass without a written reason
   per host — the whitelist is the auditable contract.

## Synthetic self-test (no real traffic)

Generate a demo pcap with two whitelisted DNS names, one whitelisted SNI and
one foreign SNI, then audit it (expects exit 1 with exactly
`ad.tracker.example.org` unknown):

    python3 - <<'PY' && tools/net_audit.sh demo.pcap --report
    from scapy.all import Ether, IP, UDP, TCP, DNS, DNSQR, Raw, wrpcap
    wrpcap("demo.pcap", [
        Ether()/IP(src="192.168.0.2", dst="192.168.0.1")/UDP(sport=40000, dport=53)
            /DNS(rd=1, qd=DNSQR(qname="api2.oneme.ru", qtype="A")),
        Ether()/IP(src="192.168.0.2", dst="192.168.0.1")/UDP(sport=40001, dport=53)
            /DNS(rd=1, qd=DNSQR(qname="cdn.max.ru", qtype="A")),
        Ether()/IP(src="192.168.0.2", dst="149.154.167.50")/TCP(sport=44100, dport=443, flags="PA")
            /Raw(load=b"\x16\x03\x01" + b"\x00"*32 + b"venus.web.telegram.org"),
        Ether()/IP(src="192.168.0.2", dst="203.0.113.50")/TCP(sport=44101, dport=443, flags="PA")
            /Raw(load=b"\x16\x03\x01" + b"\x00"*32 + b"ad.tracker.example.org"),
    ])
    PY
