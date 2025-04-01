#ifndef TIKTOKEN_FFI_H
#define TIKTOKEN_FFI_H

#include <stddef.h>

int tiktoken_init(const char* encoding);
size_t tiktoken_count(const char* text);
void tiktoken_cleanup();

#endif
