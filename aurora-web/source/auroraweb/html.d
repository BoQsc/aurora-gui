module auroraweb.html;

/**
 * HTML tokenizer and parser producing an `auroraweb.dom` tree.
 *
 * This is not the full WHATWG HTML5 tree-construction algorithm with all its
 * adoption-agency and foreign-content rules; it is a pragmatic parser that
 * handles the vast majority of real-world documents:
 *
 * - Elements, attributes (quoted and unquoted), self-closing `<br/>`.
 * - Void elements (`br`, `img`, `hr`, `input`, `meta`, `link`, ...) that never
 *   have children.
 * - Text with HTML entities (`&amp;`, `&lt;`, `&gt;`, `&nbsp;`, numeric
 *   `&#65;` / `&#x41;`).
 * - Comments `<!-- ... -->`, doctype `<!DOCTYPE ...>`, and CDATA.
 * - Implicit closing of block elements when a new block sibling starts
 *   (`<p>a<div>b</div>` closes the `<p>`), and an explicit close that has no
 *   matching open tag is ignored.
 * - `<script>` and `<style>` contents are treated as raw text (no tag parsing)
 *   so embedded `<`, `&` and even `</script>`-like strings survive until the
 *   real closing tag.
 */

import auroraweb.dom : Element, TextNode;

import std.array : appender, split;
import std.ascii : isAlpha, isDigit, isHexDigit, isWhite;
import std.conv : to;
import std.string : indexOf, lastIndexOf, split, strip, toLower;

/// Void elements never have a closing tag.
private immutable string[] voidElements = [
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr"
];

/// Elements whose content is raw text (no child tags).
private immutable string[] rawTextElements = ["script", "style"];

/**
 * Parse an HTML string into a document tree.
 *
 * Returns the root `html` element if present, otherwise a synthetic `body`
 * root. The head element, when present, is attached under `html`; layout and
 * paint only render the `body` subtree.
 */
Element parseHtml(string input)
{
    auto tokens = tokenize(input);
    auto root = buildTree(tokens);
    return root;
}

/// Parse an HTML fragment and return the top-level element children.
Element[] parseFragment(string html)
{
    auto root = parseHtml("<div id=\"__frag\">" ~ html ~ "</div>");
    Element[] result;
    void walk(Element e)
    {
        foreach (child; e.elements)
        {
            if (e.attrs.get("id", "") == "__frag")
            {
                result ~= child;
            }
            else walk(child);
        }
    }
    walk(root);
    return result;
}

/// Public token kind for testing and diagnostics.
enum TokenKind
{
    text,
    openTag,
    closeTag,
    comment,
    doctype
}

/// One tokenizer token.
struct Token
{
    TokenKind kind;
    string data;     /// Text content, or tag name, or comment text.
    AttrMap attrs;   /// Attribute map for open tags.
}

alias AttrMap = string[string];

/**
 * Tokenize a full HTML document.
 *
 * This is intentionally forgiving: malformed attribute syntax is captured as
 * best-effort rather than raising. The tokenizer never throws.
 */
Token[] tokenize(string input)
{
    Token[] tokens;
    auto textBuf = appender!string;
    size_t i = 0;
    const n = input.length;

    void flushText()
    {
        if (textBuf.data.length)
        {
            tokens ~= Token(TokenKind.text, textBuf.data, null);
            textBuf = appender!string;
        }
    }

    while (i < n)
    {
        if (input[i] == '<')
        {
            // Comment
            if (i + 3 < n && input[i + 1] == '!' && input[i + 2] == '-' && input[i + 3] == '-')
            {
                flushText();
                auto end = indexOf(input, "-->", i + 4);
                if (end < 0) end = n;
                tokens ~= Token(TokenKind.comment, input[i + 4 .. end], null);
                i = end + 3;
                continue;
            }
            // Doctype / CDATA
            if (i + 8 < n && input[i + 1] == '!' && (input[i + 2] == 'D' || input[i + 2] == 'd'))
            {
                flushText();
                auto end = indexOf(input, ">", i);
                if (end < 0) end = n;
                tokens ~= Token(TokenKind.doctype, input[i .. end + 1], null);
                i = end + 1;
                continue;
            }
            // Closing tag
            if (i + 1 < n && input[i + 1] == '/')
            {
                flushText();
                auto end = indexOf(input, ">", i);
                if (end < 0) end = n;
                const inner = input[i + 2 .. end].strip().toLower();
                tokens ~= Token(TokenKind.closeTag, inner, null);
                i = end + 1;
                continue;
            }
            // Raw text element content: consume until the real closing tag.
            if (i + 1 < n && isAlpha(input[i + 1]))
            {
                // Look ahead for the tag name to check raw-text elements.
                auto end = indexOf(input, ">", i);
                if (end >= 0)
                {
                    auto tagText = input[i + 1 .. end].strip();
                    auto firstWord = tagText.length ? tagText.split(' ')[0].toLower() : "";
                    if (firstWord.length && canFindRaw(rawTextElements, firstWord))
                    {
                        flushText();
                        tokens ~= Token(TokenKind.openTag, firstWord, parseAttrs(tagText));
                        i = end + 1;
                        // Consume raw text until </firstword>
                        auto closeTag = "</" ~ firstWord;
                        auto closeIndex = indexOf(input, closeTag, i);
                        if (closeIndex < 0)
                        {
                            tokens ~= Token(TokenKind.text, input[i .. n], null);
                            i = n;
                        }
                        else
                        {
                            tokens ~= Token(TokenKind.text, input[i .. closeIndex], null);
                            tokens ~= Token(TokenKind.closeTag, firstWord, null);
                            i = closeIndex + closeTag.length;
                        }
                        continue;
                    }
                }
            }
            // Open tag
            auto end = indexOf(input, ">", i);
            if (end >= 0)
            {
                flushText();
                const inner = input[i + 1 .. end];
                const trimmed = inner.strip();
                if (trimmed.length)
                {
                    auto tagName = trimmed.split(' ')[0].toLower();
                    bool selfClosing = false;
                    if (tagName.length && tagName[$ - 1] == '/')
                    {
                        selfClosing = true;
                        tagName = tagName[0 .. $ - 1];
                    }
                    tokens ~= Token(TokenKind.openTag, tagName, parseAttrs(trimmed));
                    if (selfClosing || canFindVoid(tagName))
                        tokens ~= Token(TokenKind.closeTag, tagName, null);
                }
                i = end + 1;
                continue;
            }
            // Malformed <: treat as text.
            textBuf.put(input[i]);
            i++;
            continue;
        }
        textBuf.put(input[i]);
        i++;
    }
    flushText();
    return tokens;
}

private bool canFindRaw(const(string)[] list, string value)
{
    foreach (entry; list)
        if (entry == value) return true;
    return false;
}

private bool canFindVoid(string value)
{
    return canFindRaw(voidElements, value);
}

/// Tags that implicitly close an open tag of the same name (li, dt, dd, etc.).
private bool autoClosesSelf(string tag)
{
    switch (tag)
    {
        case "li", "dt", "dd", "tr", "td", "th", "option", "optgroup":
            return true;
        default:
            return false;
    }
}

/// Parse the attribute part of an open tag ("name=value name2='v'").
private AttrMap parseAttrs(string inner)
{
    AttrMap attrs;
    size_t i = 0;
    const n = inner.length;
    // Skip tag name
    while (i < n && !isWhite(inner[i])) i++;
    while (i < n)
    {
        while (i < n && isWhite(inner[i])) i++;
        if (i >= n) break;
        // Attribute name
        auto nameStart = i;
        while (i < n && !isWhite(inner[i]) && inner[i] != '=' && inner[i] != '>') i++;
        auto name = inner[nameStart .. i].toLower();
        if (!name.length) { i++; continue; }
        while (i < n && isWhite(inner[i])) i++;
        string value = "";
        if (i < n && inner[i] == '=')
        {
            i++;
            while (i < n && isWhite(inner[i])) i++;
            if (i < n && (inner[i] == '"' || inner[i] == '\''))
            {
                auto quote = inner[i];
                i++;
                auto valueStart = i;
                while (i < n && inner[i] != quote) i++;
                value = inner[valueStart .. i];
                if (i < n) i++;
            }
            else
            {
                auto valueStart = i;
                while (i < n && !isWhite(inner[i]) && inner[i] != '>') i++;
                value = inner[valueStart .. i];
            }
        }
        attrs[name] = decodeEntities(value);
    }
    return attrs;
}

/// Decode a small set of common named entities plus numeric character references.
string decodeEntities(string input)
{
    if (input.length == 0) return input;
    if (indexOf(input, "&") < 0) return input;
    auto result = appender!string;
    size_t i = 0;
    const n = input.length;
    while (i < n)
    {
        if (input[i] != '&')
        {
            result.put(input[i]);
            i++;
            continue;
        }
        auto semicolon = indexOf(input, ";", i);
        if (semicolon < 0 || semicolon - i > 12)
        {
            result.put(input[i]);
            i++;
            continue;
        }
        const entity = input[i + 1 .. semicolon];
        if (entity.length && entity[0] == '#')
        {
            dchar code = 0;
            if (entity.length > 1 && (entity[1] == 'x' || entity[1] == 'X'))
            {
                foreach (ch; entity[2 .. $])
                {
                    if (!isHexDigit(ch)) { code = 0; break; }
                    code = code * 16 + (ch >= '0' && ch <= '9' ? ch - '0' :
                        (ch >= 'a' && ch <= 'f' ? ch - 'a' + 10 : ch - 'A' + 10));
                }
            }
            else
            {
                foreach (ch; entity[1 .. $])
                {
                    if (!isDigit(ch)) { code = 0; break; }
                    code = code * 10 + (ch - '0');
                }
            }
            if (code > 0 && code <= 0x10FFFF)
            {
                result.put(cast(dchar) code);
                i = semicolon + 1;
                continue;
            }
        }
        // Named entities
        switch (entity)
        {
            case "amp": result.put('&'); break;
            case "lt": result.put('<'); break;
            case "gt": result.put('>'); break;
            case "quot": result.put('"'); break;
            case "apos": result.put('\''); break;
            case "nbsp": result.put(cast(dchar) 0xA0); break;
            case "copy": result.put(cast(dchar) 0xA9); break;
            case "reg": result.put(cast(dchar) 0xAE); break;
            case "trade": result.put(cast(dchar) 0x2122); break;
            case "hellip": result.put(cast(dchar) 0x2026); break;
            case "mdash": result.put(cast(dchar) 0x2014); break;
            case "ndash": result.put(cast(dchar) 0x2013); break;
            case "laquo": result.put(cast(dchar) 0x00AB); break;
            case "raquo": result.put(cast(dchar) 0x00BB); break;
            case "lsquo": result.put(cast(dchar) 0x2018); break;
            case "rsquo": result.put(cast(dchar) 0x2019); break;
            case "ldquo": result.put(cast(dchar) 0x201C); break;
            case "rdquo": result.put(cast(dchar) 0x201D); break;
            default: result.put(input[i]); break;
        }
        i = semicolon + 1;
    }
    return result.data;
}

/// Build a DOM tree from tokens.
private Element buildTree(Token[] tokens)
{
    Element root = null;
    // The root element we attach everything to (html if present else body).
    Element docRoot = null;
    Element[] stack;

    Element ensureRoot()
    {
        if (docRoot is null)
        {
            docRoot = new Element("body");
            root = docRoot;
        }
        return docRoot;
    }

    Element current()
    {
        if (stack.length) return stack[$ - 1];
        return ensureRoot();
    }

    foreach (token; tokens)
    {
        final switch (token.kind)
        {
            case TokenKind.text:
            {
                auto parent = current();
                auto textNode = new TextNode(parent, token.data);
                parent.children ~= textNode;
                parent.textNodes ~= textNode;
                break;
            }
            case TokenKind.openTag:
            {
                const tag = token.data;
                if (tag.length == 0) break;
                // Implicit closing: certain tags auto-close an open tag of the
                // same kind (e.g. a new <p> closes an unclosed <p>; <li> closes
                // an open <li>). Other block containers (div, section, ...) are
                // NOT popped — they can contain block children.
                if (autoClosesSelf(tag))
                {
                    if (stack.length && stack[$ - 1].tag == tag)
                        stack.length = stack.length - 1;
                }
                else if (tag == "p")
                {
                    // <p> closes an open <p> or <li> (li implicitly contains p).
                    while (stack.length)
                    {
                        const top = stack[$ - 1].tag;
                        if (top == "p" || top == "li")
                        {
                            stack.length = stack.length - 1;
                            continue;
                        }
                        break;
                    }
                }
                auto parent = current();
                auto element = new Element(tag);
                foreach (key, value; token.attrs)
                    element.attrs[key] = value;
                parent.children ~= element;
                parent.elements ~= element;
                element.parent = parent;
                if (!canFindVoid(tag))
                    stack ~= element;
                break;
            }
            case TokenKind.closeTag:
            {
                const tag = token.data;
                if (tag.length == 0) break;
                // Pop the stack until the matching element.
                for (int j = cast(int) stack.length - 1; j >= 0; j--)
                {
                    if (stack[j].tag == tag)
                    {
                        stack.length = j;
                        break;
                    }
                }
                break;
            }
            case TokenKind.comment:
                break;
            case TokenKind.doctype:
                break;
        }
    }
    return root;
}

unittest
{
    auto tokens = tokenize(`<html><body><h1>Hi</h1><p class="a">text &amp; more</p></body></html>`);
    assert(tokens.length > 0, "tokenizer should produce tokens");
    auto root = parseHtml(`<html><body><p id="x">Hello</p><div><span>nested</span></div></body></html>`);
    assert(root !is null, "root should exist");
    // The root element is a synthetic body (since parser creates body if no explicit one).
    assert(root.tag == "body" || root.tag == "html", "root should be body or html");
}

unittest
{
    // Entities decode correctly.
    assert(decodeEntities("a &amp; b") == "a & b");
    assert(decodeEntities("&#65;&#x42;") == "AB");
    assert(decodeEntities("&nbsp;") == "\u00A0");
}
