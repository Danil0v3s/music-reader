# Music Reader OMR server: Audiveris + a stdlib Python HTTP wrapper.
# Audiveris ships x86_64 Linux packages only, so the image is linux/amd64 (it runs emulated on Apple silicon).
#
#   docker build --platform linux/amd64 -t music-reader-omr server/
#   docker run --platform linux/amd64 -p 8765:8765 -v omr-data:/data music-reader-omr
FROM --platform=linux/amd64 ubuntu:24.04

ARG AUDIVERIS_VERSION=5.11.0
# English OCR data for titles, tempo words and expressions. Audiveris drives Tesseract's legacy engine,
# which the "fast" models lack, so this is the standard tessdata model.
ARG TESSDATA_REF=4.1.0
ENV DEBIAN_FRONTEND=noninteractive

# The .deb is a jpackage bundle with its own Java runtime; it still needs the system graphics/font libs
# that AWT and Tesseract (text recognition: titles, tempo words, dynamics) load. Its files are extracted
# directly: the package's install script registers a desktop menu entry, which fails in a container.
# Audiveris loads GTK 3 through JNA at startup even in batch mode, so libgtk-3 must be present.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl python3 python3-pil \
      libfreetype6 fontconfig fonts-dejavu-core libxext6 libxrender1 libxtst6 libxi6 libasound2t64 \
      libgtk-3-0t64 \
 && curl -fsSL -o /tmp/audiveris.deb \
      "https://github.com/Audiveris/audiveris/releases/download/${AUDIVERIS_VERSION}/Audiveris-${AUDIVERIS_VERSION}-ubuntu24.04-x86_64.deb" \
 && dpkg-deb -x /tmp/audiveris.deb / \
 && rm -rf /tmp/audiveris.deb /var/lib/apt/lists/* \
 && ln -sf "$(find /opt -path '*/bin/Audiveris' -type f | head -1)" /usr/local/bin/audiveris \
 && test -x /usr/local/bin/audiveris \
 && mkdir -p /usr/share/tessdata \
 && curl -fsSL -o /usr/share/tessdata/eng.traineddata \
      "https://github.com/tesseract-ocr/tessdata/raw/${TESSDATA_REF}/eng.traineddata"

# Headless: no display in the container; batch mode never opens a window.
ENV JAVA_TOOL_OPTIONS="-Djava.awt.headless=true -Xmx3g" \
    AUDIVERIS_CMD=/usr/local/bin/audiveris \
    TESSDATA_PREFIX=/usr/share/tessdata \
    OMR_DATA=/data \
    OMR_PORT=8765

RUN useradd --create-home --uid 10001 omr && mkdir -p /data && chown omr /data
USER omr
WORKDIR /home/omr
COPY --chown=omr omr_server.py api.py accounts.py apple_tokens.py db.py idtokens.py library_store.py mailer.py shares.py ./
COPY --chown=omr legal ./legal

VOLUME /data
EXPOSE 8765
HEALTHCHECK --interval=60s --timeout=10s CMD python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8765/health')"
CMD ["python3", "omr_server.py"]
