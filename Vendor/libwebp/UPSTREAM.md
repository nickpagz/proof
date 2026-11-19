# Vendored libwebp

Upstream: [libwebp 1.6.0](https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz).
Release archive SHA-256: `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`.

The C and header files in `sharpyuv/` and `src/{dec,dsp,enc,mux,utils,webp}/`
are unmodified files from that archive. The selected directories supply the
codec and ICC profile muxing, without command-line tools or external image I/O
libraries. `COPYING`, `PATENTS`, and `AUTHORS` are also from the archive.

`ProofWebP.c` and `include/ProofWebP.h` are Proof's bridge, not upstream
files. SwiftPM compiles the sources into the executable without Homebrew.
When updating, replace the upstream files and notices, verify the new archive
and checksum, and rerun the WebP round-trip and signed-bundle checks.
