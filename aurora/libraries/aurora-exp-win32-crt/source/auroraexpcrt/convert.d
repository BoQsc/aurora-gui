// SPDX-License-Identifier: 0BSD
/// Aurora CRT character classification and numeric conversion.
module auroraexpcrt.convert;

extern(C) int isdigit(int value)
{
    return value >= '0' && value <= '9';
}

extern(C) int isspace(int value)
{
    return value == ' ' || value == '\t' || value == '\n' || value == '\v'
        || value == '\f' || value == '\r';
}

extern(C) int toupper(int value)
{
    return value >= 'a' && value <= 'z' ? value - ('a' - 'A') : value;
}

extern(C) int tolower(int value)
{
    return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

extern(C) int isalpha(int value)
{
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z');
}

extern(C) int isalnum(int value)
{
    return isalpha(value) || isdigit(value);
}

extern(C) int isxdigit(int value)
{
    return isdigit(value) || (value >= 'a' && value <= 'f')
        || (value >= 'A' && value <= 'F');
}

extern(C) int islower(int value)
{
    return value >= 'a' && value <= 'z';
}

extern(C) int isupper(int value)
{
    return value >= 'A' && value <= 'Z';
}

extern(C) int ispunct(int value)
{
    return value > ' ' && value < 127 && !isalnum(value);
}

extern(C) int isprint(int value)
{
    return value >= ' ' && value < 127;
}

extern(C) int iscntrl(int value)
{
    return (value >= 0 && value < ' ') || value == 127;
}

/// Decimal floating-point parse: sign, digits, fraction, exponent.
extern(C) double strtod(const char* text, char** end)
{
    auto cursor = cast(char*) text;
    while (isspace(*cursor))
        ++cursor;

    bool negative;
    if (*cursor == '+' || *cursor == '-')
    {
        negative = *cursor == '-';
        ++cursor;
    }

    double value;
    bool anyDigits;
    while (isdigit(*cursor))
    {
        value = value * 10.0 + (*cursor - '0');
        ++cursor;
        anyDigits = true;
    }
    if (*cursor == '.')
    {
        ++cursor;
        double scale = 0.1;
        while (isdigit(*cursor))
        {
            value += (*cursor - '0') * scale;
            scale *= 0.1;
            ++cursor;
            anyDigits = true;
        }
    }
    if (anyDigits && (*cursor == 'e' || *cursor == 'E'))
    {
        auto exponentCursor = cursor + 1;
        bool exponentNegative;
        if (*exponentCursor == '+' || *exponentCursor == '-')
        {
            exponentNegative = *exponentCursor == '-';
            ++exponentCursor;
        }
        int exponent;
        bool anyExponent;
        while (isdigit(*exponentCursor))
        {
            exponent = exponent * 10 + (*exponentCursor - '0');
            ++exponentCursor;
            anyExponent = true;
        }
        if (anyExponent)
        {
            cursor = exponentCursor;
            while (exponent > 0)
            {
                value = exponentNegative ? value / 10.0 : value * 10.0;
                --exponent;
            }
        }
    }

    if (end !is null)
        *end = cast(char*) cursor;
    return negative ? -value : value;
}

/// Minimal stable error text; errno-specific strings come later.
extern(C) char* strerror(int code)
{
    __gshared char[16] text = "error";
    return text.ptr;
}
