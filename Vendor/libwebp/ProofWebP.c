#include "ProofWebP.h"
#include "src/webp/encode.h"
#include "src/webp/mux.h"

int ProofWebPMaxDimension(void) { return WEBP_MAX_DIMENSION; }
void ProofWebPFree(void* data) { WebPFree(data); }

size_t ProofWebPEncode(uint8_t* rgba, int width, int height, int stride,
                       const uint8_t* icc, size_t icc_size, uint8_t** output) {
  *output = NULL;
  if (width < 1 || height < 1 || width > WEBP_MAX_DIMENSION ||
      height > WEBP_MAX_DIMENSION || stride < width * 4) {
    return 0;
  }

  for (int y = 0; y < height; ++y) {
    uint8_t* pixel = rgba + (size_t)y * stride;
    for (int x = 0; x < width; ++x, pixel += 4) {
      const unsigned alpha = pixel[3];
      if (alpha == 0 || alpha == 255) continue;
      for (int channel = 0; channel < 3; ++channel) {
        const unsigned value = (pixel[channel] * 255u + alpha / 2u) / alpha;
        pixel[channel] = (uint8_t)(value < 255 ? value : 255);
      }
    }
  }

  uint8_t* encoded = NULL;
  const size_t size = WebPEncodeLosslessRGBA(rgba, width, height, stride, &encoded);
  if (!size || !icc_size) {
    *output = encoded;
    return size;
  }

  const WebPData image = {encoded, size};
  const WebPData profile = {icc, icc_size};
  WebPData assembled = {NULL, 0};
  WebPMux* mux = WebPMuxNew();
  const int ok = mux && WebPMuxSetImage(mux, &image, 0) == WEBP_MUX_OK &&
      WebPMuxSetChunk(mux, "ICCP", &profile, 0) == WEBP_MUX_OK &&
      WebPMuxAssemble(mux, &assembled) == WEBP_MUX_OK;
  WebPMuxDelete(mux);
  WebPFree(encoded);
  if (!ok) {
    WebPDataClear(&assembled);
    return 0;
  }
  // WebPMuxAssemble allocates a buffer owned by the caller.
  *output = (uint8_t*)assembled.bytes;
  return assembled.size;
}
