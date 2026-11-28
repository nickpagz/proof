#ifndef PROOF_WEBP_H
#define PROOF_WEBP_H

#include <stddef.h>
#include <stdint.h>

// Converts premultiplied RGBA to straight alpha in place. Release output with ProofWebPFree.
size_t ProofWebPEncode(uint8_t* rgba, int width, int height, int stride,
                       const uint8_t* icc, size_t icc_size, uint8_t** output);
void ProofWebPFree(void* data);
int ProofWebPMaxDimension(void);

#endif
