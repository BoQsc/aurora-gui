#!/usr/bin/env python3
"""Read-only credential diagnostic for Aurora OpenCode.

Run this on the machine that reports
"Upstream returned HTTP 401: Invalid credential" and paste the whole output.

It shows what the app would send to each provider endpoint, whether the
OpenCode gateway accepts those credentials (GET /zen/go/v1/usage is an
authentication check that generates no tokens), and where each credential came
from. Credentials are never printed: each one is described by its scheme,
length, a SHA-256 prefix and any suspicious characters.

    python diagnose-opencode-credentials.py
    python diagnose-opencode-credentials.py --offline   # skip network probes

Exit status is 0 even when a credential is rejected; the report is the result.
"""

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

GO_BASE = "https://opencode.ai/zen/go/v1"
COMMANDCODE_BASE = "https://api.commandcode.ai/provider/v1"
LOCAL_BASE = "http://127.0.0.1:8080/v1"
USER_AGENT = "Aurora-OpenCode-Credential-Diagnostic"

# Mirrors ProviderPreset in aurora-opencode-core/source/auroraopencode/core.d.
PRESETS = (
    {"id": "opencode", "name": "OpenCode", "base": GO_BASE,
     "model": "deepseek-v4.1-flash"},
    {"id": "commandcode", "name": "CommandCode", "base": COMMANDCODE_BASE,
     "model": "deepseek/deepseek-v4.1-flash"},
    {"id": "qwen", "name": "Qwen 3.8 27B", "base": LOCAL_BASE,
     "model": "Qwen/Qwen3.8-27B"},
    {"id": "llama", "name": "Local llama.cpp", "base": LOCAL_BASE, "model": ""},
)

# Legacy key files the app still consults, in its order (core.d).
LEGACY_KEY_FILES = (
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode-api/data/key.txt",
    "C:/Users/Windows10_new/Documents/web_webserver/domains/opencode/data/arena/key.txt",
)


def norm(url):
    return (url or "").strip().lower().rstrip("/")


def preset_for(base):
    wanted = norm(base)
    for preset in PRESETS:
        if norm(preset["base"]) == wanted:
            return preset
    return None


def describe(key):
    """Describe a credential without revealing any of its characters."""
    digest = hashlib.sha256(key.encode("utf-8", "surrogatepass")).hexdigest()[:12]
    if key.startswith("oc_sk_"):
        scheme = "oc_sk_<redacted>"
    elif key.startswith("user_"):
        scheme = "user_<redacted>"
    elif key.startswith("sk-"):
        scheme = "sk-<redacted>"
    else:
        scheme = "<redacted>"
    flags = []
    if key != key.strip():
        flags.append("surrounding whitespace")
    if any(ord(ch) < 32 or ord(ch) > 126 for ch in key):
        flags.append("control or non-ASCII character")
    return scheme + " len=" + str(len(key)) + " sha256=" + digest + (
        " [" + ", ".join(flags) + "]" if flags else "")


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, "missing"
    except OSError as error:
        return None, "unreadable ({0})".format(error)
    except ValueError as error:
        return None, "invalid JSON ({0})".format(error)


def read_text_key(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace").strip()
    except (FileNotFoundError, OSError):
        return ""


def state_directory():
    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "Aurora OpenCode"
    return Path.home() / "AppData" / "Roaming" / "Aurora OpenCode"


def profile_directory():
    profile = os.environ.get("USERPROFILE")
    return Path(profile) if profile else Path.home()


def slot_keys(entry):
    keys = [entry.get("apiKey") or "", entry.get("additionalApiKey") or ""]
    for extra in entry.get("extraApiKeys") or []:
        keys.append(extra if isinstance(extra, str) else "")
    return keys


def active_slot(entry):
    keys = slot_keys(entry)
    index = entry.get("activeKeyIndex")
    if not isinstance(index, int) or isinstance(index, bool) or \
            index < 0 or index >= len(keys):
        index = 1 if entry.get("additionalKeyActive") else 0
    if 0 <= index < len(keys) and keys[index]:
        return index, keys[index]
    for position, key in enumerate(keys):
        if key:
            return position, key
    return None, ""


def provider_entry(settings, base):
    if not settings:
        return None
    owner = (preset_for(base) or {}).get("id") or norm(base)
    for entry in settings.get("providerKeys") or []:
        if isinstance(entry, dict) and entry.get("providerId") == owner:
            return entry
    return None


def cli_auth_key(auth, provider_id):
    entry = (auth or {}).get(provider_id)
    if not isinstance(entry, dict):
        return "", "no entry"
    if isinstance(entry.get("key"), str) and entry["key"]:
        return entry["key"], "api key"
    access = entry.get("access")
    if isinstance(access, str) and access:
        expires = entry.get("expires")
        if isinstance(expires, (int, float)) and not isinstance(expires, bool) \
                and 0 < expires <= time.time() * 1000:
            return "", "OAuth access token (expired)"
        return access, "OAuth access token"
    return "", "no usable credential"


def provider_key_fallback(preset, auth, env_key):
    """readProviderKey() in core.d, for machines with no stored provider key."""
    pid = preset["id"]
    if pid in ("qwen", "llama"):
        return "", "local preset (a key is optional)"
    if pid == "opencode":
        for name in ("opencode-go", "opencode"):
            key, kind = cli_auth_key(auth, name)
            if key:
                return key, "opencode CLI auth.json [{0}] ({1})".format(name, kind)
        if env_key:
            return env_key, "OPENCODE_API_KEY environment variable"
        for candidate in LEGACY_KEY_FILES:
            value = read_text_key(Path(candidate))
            if value:
                return value, "legacy key file " + candidate
        return "", "none"
    key, kind = cli_auth_key(auth, pid)
    if key:
        return key, "opencode CLI auth.json [{0}] ({1})".format(pid, kind)
    if pid == "commandcode":
        candidate = profile_directory() / ".config" / "opencode" / "commandcode.key"
        value = read_text_key(candidate)
        if value:
            return value, "CLI key file {0}".format(candidate)
    return "", "none"


def resolve(settings, base, auth, env_key):
    """The credential the app sends for `base`, in core.d's precedence order."""
    entry = provider_entry(settings, base)
    if entry is not None:
        index, key = active_slot(entry)
        if key:
            return key, "settings.json providerKeys[{0}] slot #{1}".format(
                entry.get("providerId"), index)
    if settings and norm(base) == norm(settings.get("baseUrl")):
        live = settings.get("apiKey") or ""
        if live:
            return live, "settings.json apiKey (live credential)"
    preset = preset_for(base)
    if preset:
        return provider_key_fallback(preset, auth, env_key)
    if env_key:
        return env_key, "OPENCODE_API_KEY environment variable"
    return "", "none"


def http_get(url, key=None, limit=400):
    headers = {"Accept": "application/json", "User-Agent": USER_AGENT}
    if key:
        headers["Authorization"] = "Bearer " + key
    try:
        with urlopen(Request(url, headers=headers), timeout=20) as response:
            return response.status, response.read(limit).decode("utf-8", "replace"), None
    except HTTPError as error:
        return error.code, error.read(limit).decode("utf-8", "replace"), None
    except URLError as error:
        return None, "", str(error.reason)
    except OSError as error:
        return None, "", str(error)


def one_line(text, limit=220):
    text = " ".join((text or "").split())
    return text if len(text) <= limit else text[:limit] + "..."


def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true",
                        help="skip the gateway network checks")
    args = parser.parse_args(argv)

    state = state_directory()
    settings_path = state / "settings.json"
    profile = profile_directory()
    auth_path = profile / ".local" / "share" / "opencode" / "auth.json"
    config_paths = (profile / ".config" / "opencode" / "opencode.json",
                    profile / ".config" / "opencode" / "opencode.jsonc")

    print("Aurora OpenCode credential diagnostic")
    print("=====================================")
    print("when:            " + time.strftime("%Y-%m-%d %H:%M:%S"))
    print("python:          " + sys.version.split()[0])
    print("state directory: " + str(state) + "   (the app reads this one)")
    print()

    settings, settings_error = read_json(settings_path)
    if settings is not None and not isinstance(settings, dict):
        settings, settings_error = None, "not a JSON object"

    print("Files")
    print("-----")
    if settings is None:
        print("settings.json:   " + str(settings_path) + " -> " + str(settings_error))
    else:
        print("settings.json:   " + str(settings_path))
        print("  baseUrl={0!r} model={1!r}".format(
            settings.get("baseUrl"), settings.get("model")))
        print("  apiKey present: " + ("yes" if settings.get("apiKey") else "no"))
    legacy_settings = state / "Aurora OpenCode" / "settings.json"
    if legacy_settings.exists():
        print("  note: a second settings file exists at " + str(legacy_settings))
        print("        (older or portable state directory; the app does not read it)")

    auth, auth_error = read_json(auth_path)
    if auth is not None and not isinstance(auth, dict):
        auth, auth_error = None, "not a JSON object"
    if auth is None:
        print("opencode auth:   " + str(auth_path) + " -> " + str(auth_error))
    else:
        print("opencode auth:   " + str(auth_path))
        if not auth:
            print("  no provider entries")
        for name, entry in auth.items():
            if not isinstance(entry, dict):
                continue
            key, detail = cli_auth_key({name: entry}, name)
            expiry = ""
            expires = entry.get("expires")
            if isinstance(expires, (int, float)) and not isinstance(expires, bool) \
                    and expires > 0:
                expiry = " expires=" + time.strftime(
                    "%Y-%m-%d %H:%M", time.localtime(expires / 1000.0))
                if expires <= time.time() * 1000:
                    expiry += " (EXPIRED)"
            print("  {0}: type={1}{2} -> {3}".format(
                name, entry.get("type", "?"), expiry,
                describe(key) if key else detail))

    raw_env = os.environ.get("OPENCODE_API_KEY") or ""
    env_key = raw_env.strip()
    env_note = ""
    if env_key and raw_env != env_key:
        env_note = " [surrounding whitespace stripped]"
    print("OPENCODE_API_KEY: "
          + ("set -> " + describe(env_key) + env_note if env_key else "not set"))

    config_key = ""
    found_config = False
    for path in config_paths:
        if not path.exists():
            continue
        found_config = True
        config, error = read_json(path)
        print("opencode config: " + str(path)
              + (" -> " + str(error) if config is None else ""))
        if not isinstance(config, dict):
            continue
        providers = config.get("provider") or config.get("providers") or {}
        if not isinstance(providers, dict):
            continue
        for name, provider in providers.items():
            options = provider.get("options") if isinstance(provider, dict) else None
            if not isinstance(options, dict):
                continue
            candidate = options.get("apiKey")
            if isinstance(candidate, str) and candidate:
                config_key = candidate
                print("  provider[{0}].options.apiKey -> {1}".format(
                    name, describe(candidate)))
                print("  note: the app does not read opencode.json, so this key is not sent")
            base = options.get("baseURL") or options.get("baseUrl")
            if isinstance(base, str) and base:
                print("  provider[{0}].options.baseURL={1!r} (app does not read it)".format(
                    name, base))
    if not found_config:
        print("opencode config: none at " + str(config_paths[0]))

    print()
    print("Stored provider keys (settings.json providerKeys)")
    print("------------------------------------------------")
    entries = [entry for entry in (settings or {}).get("providerKeys") or []
               if isinstance(entry, dict)]
    if not entries:
        print("  none")
    for entry in entries:
        index, _ = active_slot(entry)
        print("  providerId={0!r} storedBaseUrl={1!r} activeSlot={2}".format(
            entry.get("providerId"), entry.get("baseUrl"), index))
        for position, key in enumerate(slot_keys(entry)):
            marker = "  (ACTIVE)" if position == index else ""
            print("    slot #{0}: {1}{2}".format(
                position, describe(key) if key else "(empty)", marker))
        stored = entry.get("baseUrl")
        matching = next((preset["base"] for preset in PRESETS
                         if preset["id"] == entry.get("providerId")), None)
        if stored and matching and norm(stored) != norm(matching):
            print("    note: stored baseUrl differs from the preset endpoint; "
                  "keys are matched by providerId, so this does not matter")

    print()
    print("What the app sends for each endpoint")
    print("------------------------------------")
    resolved = {}
    for name, base in (("OpenCode", GO_BASE), ("CommandCode", COMMANDCODE_BASE)):
        key, source = resolve(settings, base, auth, env_key)
        resolved[base] = (key, source)
        print("{0} {1}".format(name, base))
        print("  source: " + source)
        print("  credential: " + (describe(key) if key else
                                  "NONE (no Authorization header is sent)"))
    print()

    if args.offline:
        print("Network checks skipped (--offline).")
        return 0

    print("Live gateway checks")
    print("-------------------")
    status, body, transport = http_get(GO_BASE + "/models", limit=4_000_000)
    models = []
    if status is None:
        print("  model catalog: unreachable (" + str(transport) + ")")
    else:
        if status == 200:
            try:
                models = [item.get("id") for item in json.loads(body).get("data") or []]
            except (ValueError, AttributeError):
                models = []
        print("  model catalog: HTTP {0}{1}{2}".format(
            status,
            ", {0} models".format(len(models)) if models else "",
            " -> " + one_line(body) if status != 200 else ""))
        saved_model = (settings or {}).get("model") or ""
        if status == 200 and saved_model:
            print("  saved model {0!r} listed: {1}".format(
                saved_model, "yes" if saved_model in models else "no"))

    candidates = []
    selected_key, selected_source = resolved[GO_BASE]
    if selected_key:
        candidates.append(
            ("app would send this for OpenCode (" + selected_source + ")", selected_key))
    for entry in entries:
        if entry.get("providerId") != "opencode":
            continue
        for position, key in enumerate(slot_keys(entry)):
            if key:
                candidates.append(
                    ("settings.json providerKeys[opencode] slot #{0}".format(position), key))
    if settings and settings.get("apiKey"):
        candidates.append(("settings.json apiKey (live credential)", settings["apiKey"]))
    for name in ("opencode-go", "opencode"):
        key, _ = cli_auth_key(auth, name)
        if key:
            candidates.append(("opencode CLI auth.json [{0}]".format(name), key))
    if env_key:
        candidates.append(("OPENCODE_API_KEY", env_key))
    if config_key:
        candidates.append(("opencode.json provider options.apiKey (app ignores it)",
                           config_key))

    unique = []
    for source, key in candidates:
        if not any(key == existing for _, existing in unique):
            unique.append((source, key))
    candidates = unique

    if not candidates:
        print("  no credential exists anywhere on this machine:")
        print("    settings.json apiKey, providerKeys, auth.json and OPENCODE_API_KEY are empty")
    accepted = []
    for source, key in candidates:
        status, body, transport = http_get(GO_BASE + "/usage", key)
        if status is None:
            print("  [{0}] {1} -> network error: {2}".format(
                source, describe(key), transport))
        elif status == 200:
            accepted.append((source, key))
            print("  [{0}] {1} -> HTTP 200 (credential accepted)".format(
                source, describe(key)))
        else:
            print("  [{0}] {1} -> HTTP {2} {3}".format(
                source, describe(key), status, one_line(body)))

    print()
    print("Verdict")
    print("-------")
    key, source = resolved[GO_BASE]
    if not key:
        print("  The app sends NO credential for OpenCode, so the gateway answers 401.")
        if accepted:
            print("  An accepted credential exists: " + accepted[0][0] + ".")
            print("  Put it in Settings > provider OpenCode > API Key #1 and click Save")
            print("  (keys typed into Settings are staged until Save), or set")
            print("  OPENCODE_API_KEY before Aurora OpenCode starts.")
        else:
            print("  No accepted credential was found on this machine either.")
            print("  If you supply the key through a shortcut or launcher environment")
            print("  variable, run this script from the same context, or paste the key")
            print("  into Settings > provider OpenCode > API Key #1 and click Save.")
    else:
        status, body, transport = http_get(GO_BASE + "/usage", key)
        if status is None:
            print("  Could not verify the selected credential: " + str(transport))
        elif status == 200:
            print("  The credential the app would send (" + source + ") is ACCEPTED.")
            print("  If Aurora OpenCode still shows 401 for OpenCode, the running app is")
            print("  older than the 2026-11-19 build that resolves OPENCODE_API_KEY and")
            print("  auth.json OAuth sessions, or the request went to another endpoint.")
            print("  Update and restart it, open Settings once, and check that the")
            print("  toolbar key badge says \"Key set\".")
        else:
            print("  The credential the app would send (" + source + ") is REJECTED:")
            print("    HTTP {0} {1}".format(status, one_line(body)))
            if accepted:
                print("  An accepted credential exists: " + accepted[0][0] + ".")
                print("  Replace API Key #1 under Settings > provider OpenCode with it")
                print("  and click Save (the toolbar badge must say \"Key set\").")
            else:
                print("  No credential on this machine is accepted, so the key itself is")
                print("  invalid, expired or revoked. Create a new key in the OpenCode")
                print("  console, then put it in Settings > provider OpenCode >")
                print("  API Key #1 and click Save.")

    print()
    print("Paste this whole output (it contains no credential characters).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
