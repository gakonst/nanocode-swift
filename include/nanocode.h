#ifndef NANOCODE_H
#define NANOCODE_H

#include <stddef.h>
#include <stdint.h>

typedef struct NanocodeHandle NanocodeHandle;

typedef void (*NanocodeCallback)(void *context, const uint8_t *data, size_t length);

NanocodeHandle *nanocode_start(const uint8_t *config, size_t length, NanocodeCallback callback, void *context);

void nanocode_send(NanocodeHandle *handle, const uint8_t *data, size_t length);

void nanocode_stop(NanocodeHandle *handle);

#endif
