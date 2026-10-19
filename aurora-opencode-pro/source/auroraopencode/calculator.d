module auroraopencode.calculator;

import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, JSONType, parseJSON;
import std.math : isFinite, pow;

/// A bounded arithmetic grammar. No identifiers, code execution or file access.
private struct Arithmetic
{
    string text;
    size_t cursor, depth;

    bool take(char token)
    {
        while (cursor < text.length && (text[cursor] == ' ' || text[cursor] == '\t' || text[cursor] == '\n' || text[cursor] == '\r')) ++cursor;
        if (cursor == text.length || text[cursor] != token) return false;
        ++cursor;
        return true;
    }

    double finite(double value)
    {
        enforce(isFinite(value), "Arithmetic overflow or non-finite result.");
        return value;
    }

    double expression()
    {
        auto value = product();
        while (true)
        {
            if (take('+')) value = finite(value + product());
            else if (take('-')) value = finite(value - product());
            else return value;
        }
    }

    double product()
    {
        auto value = unary();
        while (true)
        {
            if (take('*')) value = finite(value * unary());
            else if (take('/'))
            {
                const divisor = unary();
                enforce(divisor != 0, "Division by zero.");
                value = finite(value / divisor);
            }
            else if (take('%'))
            {
                const divisor = unary();
                enforce(divisor != 0, "Remainder by zero.");
                value = finite(value % divisor);
            }
            else return value;
        }
    }

    double unary()
    {
        enforce(++depth <= 32, "Expression nesting exceeds 32 levels.");
        scope(exit) --depth;
        if (take('+')) return unary();
        if (take('-')) return -unary();
        auto value = primary();
        if (take('^')) value = finite(pow(value, unary()));
        return value;
    }

    double primary()
    {
        if (take('('))
        {
            const value = expression();
            enforce(take(')'), "Missing closing parenthesis.");
            return value;
        }
        take(' ');
        const begin = cursor;
        size_t digits;
        while (cursor < text.length && text[cursor] >= '0' && text[cursor] <= '9') { ++cursor; ++digits; }
        if (cursor < text.length && text[cursor] == '.')
        {
            ++cursor;
            while (cursor < text.length && text[cursor] >= '0' && text[cursor] <= '9') { ++cursor; ++digits; }
        }
        enforce(digits != 0, "Expected a number or parenthesized expression.");
        if (cursor < text.length && (text[cursor] == 'e' || text[cursor] == 'E'))
        {
            ++cursor;
            if (cursor < text.length && (text[cursor] == '+' || text[cursor] == '-')) ++cursor;
            const exponent = cursor;
            while (cursor < text.length && text[cursor] >= '0' && text[cursor] <= '9') ++cursor;
            enforce(cursor > exponent, "Expected exponent digits.");
        }
        return finite(to!double(text[begin .. cursor]));
    }
}

double evaluateArithmetic(string expression)
{
    enforce(expression.length && expression.length <= 512, "Each expression must contain 1 to 512 bytes.");
    auto parser = Arithmetic(expression);
    const value = parser.expression();
    parser.take(' ');
    enforce(parser.cursor == expression.length, "Unexpected input; use arithmetic operators and numbers only.");
    return value;
}

string calculateExpressions(string arguments)
{
    const request = parseJSON(arguments);
    enforce(request.type == JSONType.object, "calculate requires an expressions array.");
    const expressions = "expressions" in request.object;
    enforce(expressions !is null && expressions.type == JSONType.array &&
        expressions.array.length >= 1 && expressions.array.length <= 16, "Provide 1 to 16 expressions.");
    JSONValue result;
    result["results"] = JSONValue.emptyArray;
    foreach (expression; expressions.array)
    {
        enforce(expression.type == JSONType.string, "Every expression must be a string.");
        JSONValue row;
        row["expression"] = expression.str;
        row["value"] = evaluateArithmetic(expression.str);
        result["results"].array ~= row;
    }
    return result.toString();
}
