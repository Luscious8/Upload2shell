# ============================================================================
# CVE-2026-125396 "Upload2Shell" reproduction lab - AUTHORIZED USE ONLY
#
# Stage 1 compiles the vulnerable Ghostscript 10.07.0 (pre-fix) from the
# official upstream tarball. Stage 2 is the runtime: a Flask + Pillow
# thumbnail web app whose EPS handling hands uploaded PostScript content to
# `gs -dSAFER` - the documented remote entry point for this CVE.
# ============================================================================
FROM debian:bookworm AS gsbuild

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc make libc6-dev ca-certificates curl file && apt-get clean

# Build Ghostscript 10.07.0 into /usr/local/gs (vulnerable; fixed in 10.08.0).
# GCC >= 13/14 promotes several legacy warnings to hard errors inside
# Ghostscript's unused-here XPS/PCL modules, while older GCCs reject the new
# -Wno-error= flag names outright - so no fixed flag set works everywhere.
# Each candidate flag is therefore probed against the builder's actual GCC
# using the POSITIVE form (-Wfoo: unknown -Wfoo always hard-errors, whereas
# unknown -Wno-* forms are silently tolerated on old GCC) and only the flags
# this compiler understands are passed to make. Works on GCC 11/12/13/14+.
RUN set -eux; \
    curl -fsSL -o /tmp/ghostpdl.tar.gz \
      https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/gs10070/ghostpdl-10.07.0.tar.gz; \
    tar -xzf /tmp/ghostpdl.tar.gz -C /tmp; \
    cd /tmp/ghostpdl-10.07.0; \
    ./configure --prefix=/usr/local/gs --disable-cups --disable-gtk --without-tesseract; \
    XCFLAGS=""; \
    for f in incompatible-pointer-types implicit-function-declaration \
             int-conversion implicit-int return-mismatch; do \
      if echo 'int main(void){return 0;}' | gcc -xc - "-W$f" -S -o /dev/null 2>/dev/null; then \
        XCFLAGS="$XCFLAGS -Wno-error=$f"; \
      fi; \
    done; \
    echo "selected XCFLAGS:${XCFLAGS:- <none>}"; \
    make -j"$(nproc)" XCFLAGS="$XCFLAGS"; \
    make install XCFLAGS="$XCFLAGS"

# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates python3 python3-flask python3-pil && apt-get clean

# Bring in the pinned vulnerable Ghostscript and wire it into PATH/ld.
# PATH is critical: Pillow's EPS decoder spawns the literal command name `gs`,
# so the interpreter must be resolvable through PATH for the whole chain
# (upload -> Pillow -> gs -dSAFER -> payload) to work.
COPY --from=gsbuild /usr/local/gs /usr/local/gs
ENV PATH="/usr/local/gs/bin:${PATH}"
RUN echo "/usr/local/gs/lib" > /etc/ld.so.conf.d/000-gs.conf \
    && ldconfig \
    && /usr/local/gs/bin/gs --version

# Non-root service user, like a real www-data-style deployment
RUN useradd --create-home --shell /usr/sbin/nologin appuser
WORKDIR /app
COPY app/ /app/
RUN mkdir -p /app/uploads/thumbs && chown -R appuser:appuser /app

USER appuser
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s \
  CMD python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/healthz')" || exit 1
CMD ["python3", "app.py"]
