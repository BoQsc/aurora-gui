// SPDX-License-Identifier: BSL-1.0
// Copyright (c) 2026 Aurora OpenCode contributors

#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifndef va_copy
#define va_copy(destination, source) ((destination) = (source))
#endif

#define STB_SPRINTF_IMPLEMENTATION
#include "third_party/stb_sprintf.h"
#define FFC_IMPL
#include "third_party/ffc.h"

extern void *malloc(size_t);
extern void free(void *);
extern size_t fwrite(const void *, size_t, size_t, void *);
extern void *__acrt_iob_func(unsigned int);
extern int *_errno(void);

int vsnprintf(char *output, size_t capacity, const char *format, va_list arguments)
{
    if (!format || (!output && capacity)) return -1;
    if (capacity > INT32_MAX) capacity = INT32_MAX;
    return stbsp_vsnprintf(output, (int)capacity, format, arguments);
}

int snprintf(char *output, size_t capacity, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int result = vsnprintf(output, capacity, format, arguments);
    va_end(arguments);
    return result;
}

static int print_to_stream(void *stream, const char *format, va_list arguments)
{
    va_list count_arguments;
    va_copy(count_arguments, arguments);
    int required = vsnprintf(NULL, 0, format, count_arguments);
    va_end(count_arguments);
    if (required < 0) return -1;
    char *buffer = malloc((size_t)required + 1);
    if (!buffer) return -1;
    int formatted = vsnprintf(buffer, (size_t)required + 1, format, arguments);
    int result = formatted >= 0 &&
                 fwrite(buffer, 1, (size_t)formatted, stream) == (size_t)formatted
                 ? formatted : -1;
    free(buffer);
    return result;
}

int fprintf(void *stream, const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int result = print_to_stream(stream, format, arguments);
    va_end(arguments);
    return result;
}

int printf(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    int result = print_to_stream(__acrt_iob_func(1), format, arguments);
    va_end(arguments);
    return result;
}

double aurora_crt_strtod(const char *input, char **end_pointer)
{
    if (!input)
    {
        if (end_pointer) *end_pointer = NULL;
        return 0;
    }
    const char *start = input;
    while (*start == ' ' || (*start >= '\t' && *start <= '\r')) ++start;
    double value = 0;
    ffc_result parsed = ffc_parse_double(strlen(start), start, &value);
    if (parsed.outcome == FFC_OUTCOME_INVALID_INPUT)
    {
        if (end_pointer) *end_pointer = (char *)input;
        return 0;
    }
    if (parsed.outcome == FFC_OUTCOME_OUT_OF_RANGE)
    {
        int *error = _errno();
        if (error) *error = 34;
    }
    if (end_pointer) *end_pointer = (char *)parsed.ptr;
    return value;
}

// DMD's parseoptions.d is the only Aurora-linked caller of sscanf. It uses
// the generated format "%<width>f%n" for a float runtime option.
int sscanf(const char *input, const char *format, ...)
{
    if (!input || !format || format[0] != '%') return 0;
    const char *part = format + 1;
    size_t width = 0;
    while (*part >= '0' && *part <= '9')
    {
        if (width > (SIZE_MAX - 9) / 10) return 0;
        width = width * 10 + (size_t)(*part++ - '0');
    }
    if (part[0] != 'f' || part[1] != '%' || part[2] != 'n' || part[3])
        return 0;
    const char *start = input;
    while (*start == ' ' || (*start >= '\t' && *start <= '\r')) ++start;
    size_t available = strlen(start);
    if (width && width < available) available = width;
    va_list arguments;
    va_start(arguments, format);
    float *target = va_arg(arguments, float *);
    int *consumed = va_arg(arguments, int *);
    float value = 0;
    ffc_result parsed = ffc_parse_float(available, start, &value);
    int result = 0;
    if (parsed.outcome == FFC_OUTCOME_OK && parsed.ptr > start && target)
    {
        *target = value;
        if (consumed) *consumed = (int)(parsed.ptr - input);
        result = 1;
    }
    va_end(arguments);
    return result;
}
