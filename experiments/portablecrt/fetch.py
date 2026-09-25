"""0BSD: Download the latest successful Windows UCRT backend artifact."""

import io
import json
from pathlib import Path
import subprocess
import urllib.error
import urllib.request
import zipfile


API = "https://api.github.com/repos/BoQsc/aurora-gui"
ROOT = Path(__file__).resolve().parent


def github_token():
    result = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True,
        text=True,
        check=True,
    )
    values = dict(line.split("=", 1) for line in result.stdout.splitlines()
                  if "=" in line)
    return values["password"]


def request(url, token):
    return urllib.request.Request(
        url, headers={"User-Agent": "Aurora-portablecrt",
                      "Authorization": f"Bearer {token}"}
    )


def json_get(url, token):
    with urllib.request.urlopen(request(url, token), timeout=30) as response:
        return json.load(response)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


token = github_token()
runs = json_get(
    API + "/actions/workflows/portablecrt.yml/runs"
    "?branch=codex%2Fportable-crt-experiment&status=success&per_page=1",
    token,
)["workflow_runs"]
if not runs:
    raise SystemExit("No successful portablecrt workflow run was found")
run = runs[0]
artifacts = json_get(f"{API}/actions/runs/{run['id']}/artifacts", token)["artifacts"]
artifact = next((item for item in artifacts
                 if item["name"] == "portablecrt-windows-ucrt"
                 and not item["expired"]), None)
if artifact is None:
    raise SystemExit("The latest successful portablecrt artifact is unavailable")

opener = urllib.request.build_opener(NoRedirect())
try:
    with opener.open(request(artifact["archive_download_url"], token),
                     timeout=30) as response:
        archive = response.read()
except urllib.error.HTTPError as response:
    if response.code not in (301, 302, 303, 307, 308):
        raise
    location = response.headers["Location"]
    if not location.startswith("https://"):
        raise SystemExit("GitHub returned an unexpected artifact URL")
    with urllib.request.urlopen(location, timeout=30) as redirected:
        archive = redirected.read()

with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
    library = zipped.read("portablecrt.lib")
if not library.startswith(b"!<arch>\n"):
    raise SystemExit("Downloaded artifact is not a COFF archive")
target = ROOT / "portablecrt.lib"
temporary = ROOT / "portablecrt.lib.tmp"
temporary.write_bytes(library)
temporary.replace(target)
print(f"Downloaded run {run['id']}: {target} ({len(library)} bytes)")
