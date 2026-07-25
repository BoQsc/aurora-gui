#!/usr/bin/env python3
"""Build, verify, and publish Aurora-D source archives with a commit marker.

Only Python's standard library is used. A successful run publishes a ZIP, a
tar.gz, external SHA-256 checksums, a machine-readable release report, and the
captured verification log. No final artifact is replaced until every requested
release gate has passed.
"""
from __future__ import annotations

import argparse
import datetime as dt
import gzip
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

TOP_LEVEL_FILES = (
    ".editorconfig",
    ".gitignore",
    "CHANGELOG.md",
    "LICENSE",
    "LICENSE-UNICODE.txt",
    "README.md",
    "dub.json",
)
TOP_LEVEL_DIRECTORIES = (
    "demos",
    "docs",
    "resources",
    "scripts",
    "shaders",
    "source",
    "tests",
    "tools",
)
EXCLUDED_DIRECTORY_NAMES = {
    ".cache",
    ".dub",
    ".git",
    ".idea",
    ".vscode",
    "__pycache__",
    "build",
    "dist",
}
FORBIDDEN_SUFFIXES = {
    ".a",
    ".class",
    ".dll",
    ".dylib",
    ".exe",
    ".ilk",
    ".jar",
    ".lib",
    ".o",
    ".obj",
    ".pdb",
    ".ppm",
    ".res",
    ".pyc",
    ".so",
    ".wasm",
}
DOCUMENT_IMAGE_SUFFIXES = {".jpeg", ".jpg", ".png", ".svg", ".webp"}
SHADER_SUFFIXES = {".frag", ".glsl", ".hlsl", ".spv", ".vert"}
GENERATED_PAYLOAD_FILES = {"MANIFEST.sha256", "PACKAGE-METADATA.json"}
FIXED_ZIP_EPOCH = 315532800  # 1980-01-01, ZIP's earliest portable timestamp.


class ReleaseError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_checked(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def package_version(root: Path) -> str:
    metadata = json.loads((root / "dub.json").read_text(encoding="utf-8"))
    version = metadata.get("version")
    if not isinstance(version, str) or not version:
        raise ReleaseError("dub.json has no package version")
    return version


def should_skip(relative: Path) -> bool:
    return any(part in EXCLUDED_DIRECTORY_NAMES for part in relative.parts)


def is_allowed_release_file(relative: Path, generated: bool = False) -> bool:
    posix = relative.as_posix()
    if len(relative.parts) == 1:
        if posix in TOP_LEVEL_FILES:
            return True
        return generated and posix in GENERATED_PAYLOAD_FILES

    top = relative.parts[0]
    suffix = relative.suffix.lower()
    if top in {"source", "demos", "tests"}:
        return suffix == ".d"
    if top == "resources":
        return relative.parts[:2] == ("resources", "windows") and suffix in {".manifest", ".rc"}
    if top == "scripts":
        return suffix in {".ps1", ".sh"}
    if top == "shaders":
        return suffix in SHADER_SUFFIXES
    if top == "docs":
        return suffix == ".md" or suffix in DOCUMENT_IMAGE_SUFFIXES
    if top == "tools":
        if len(relative.parts) >= 4 and relative.parts[:3] == ("tools", "unicode", "17.0.0"):
            return suffix == ".txt"
        return suffix == ".py"
    return False


def copy_release_inputs(root: Path, destination: Path) -> None:
    destination.mkdir(parents=True)
    for name in TOP_LEVEL_FILES:
        source = root / name
        if source.is_symlink():
            raise ReleaseError(f"release input may not be a symlink: {name}")
        if not source.is_file():
            raise ReleaseError(f"required release file is missing: {name}")
        shutil.copyfile(source, destination / name)

    for directory_name in TOP_LEVEL_DIRECTORIES:
        source_directory = root / directory_name
        if source_directory.is_symlink():
            raise ReleaseError(f"release input may not be a symlink: {directory_name}")
        if not source_directory.is_dir():
            raise ReleaseError(f"required release directory is missing: {directory_name}")
        for source in sorted(source_directory.rglob("*"), key=lambda path: path.as_posix()):
            relative = source.relative_to(root)
            if should_skip(relative):
                continue
            if source.is_symlink():
                raise ReleaseError(f"release input may not be a symlink: {relative}")
            target = destination / relative
            if source.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            elif source.is_file():
                if not is_allowed_release_file(relative):
                    raise ReleaseError(f"unexpected release input type: {relative}")
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            else:
                raise ReleaseError(f"unsupported release input: {relative}")


def payload_files(payload: Path) -> list[Path]:
    return sorted(
        (path for path in payload.rglob("*") if path.is_file()),
        key=lambda path: path.relative_to(payload).as_posix(),
    )


def payload_directories(payload: Path) -> list[Path]:
    return sorted(
        (path for path in payload.rglob("*") if path.is_dir()),
        key=lambda path: (len(path.relative_to(payload).parts), path.relative_to(payload).as_posix()),
    )


def normalized_mode(path: Path) -> int:
    if path.is_dir():
        return 0o755
    if path.suffix in {".sh", ".py"}:
        return 0o755
    return 0o644


def actual_mode(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def normalize_payload(payload: Path, epoch: int) -> None:
    for path in [payload, *payload_directories(payload), *payload_files(payload)]:
        mode = normalized_mode(path)
        try:
            path.chmod(mode)
            os.utime(path, (epoch, epoch), follow_symlinks=False)
        except (NotImplementedError, OSError) as error:
            raise ReleaseError(f"could not normalize {path}: {error}") from error


def validate_payload(payload: Path) -> None:
    problems: list[str] = []
    for path in payload.rglob("*"):
        relative = path.relative_to(payload)
        if path.is_symlink():
            problems.append(f"symlink: {relative}")
            continue
        if any(part in EXCLUDED_DIRECTORY_NAMES for part in relative.parts):
            problems.append(f"excluded directory: {relative}")
        if path.is_file():
            if path.suffix.lower() in FORBIDDEN_SUFFIXES:
                problems.append(f"generated/binary artifact: {relative}")
            if not is_allowed_release_file(relative, generated=True):
                problems.append(f"unexpected file type: {relative}")
        elif not path.is_dir():
            problems.append(f"unsupported filesystem entry: {relative}")
    if (payload / "ucd-17.0.0").exists():
        problems.append("duplicate Unicode data directory: ucd-17.0.0")
    if problems:
        raise ReleaseError("invalid release payload:\n  " + "\n  ".join(problems))


def write_package_metadata(payload: Path, version: str, archive_root: str, epoch: int) -> None:
    source_files = payload_files(payload)
    metadata = {
        "archiveRoot": archive_root,
        "formatVersion": 1,
        "name": "aurora-d",
        "sourceDateEpoch": epoch,
        "sourceFileCount": len(source_files),
        "unicodeVersion": "17.0.0",
        "version": version,
    }
    (payload / "PACKAGE-METADATA.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def write_manifest(payload: Path) -> Path:
    manifest = payload / "MANIFEST.sha256"
    lines: list[str] = []
    for path in payload_files(payload):
        if path == manifest:
            continue
        relative = path.relative_to(payload).as_posix()
        lines.append(f"{sha256_file(path)}  {relative}\n")
    manifest.write_text("".join(lines), encoding="utf-8")
    return manifest


def zip_datetime(epoch: int) -> tuple[int, int, int, int, int, int]:
    instant = dt.datetime.fromtimestamp(max(epoch, FIXED_ZIP_EPOCH), tz=dt.timezone.utc)
    # ZIP timestamps have two-second precision.
    second = instant.second - instant.second % 2
    return instant.year, instant.month, instant.day, instant.hour, instant.minute, second


def create_zip(payload: Path, archive: Path, archive_root: str, epoch: int) -> None:
    timestamp = zip_datetime(epoch)
    with zipfile.ZipFile(
        archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9, strict_timestamps=True
    ) as output:
        for path in payload_files(payload):
            relative = path.relative_to(payload).as_posix()
            info = zipfile.ZipInfo(f"{archive_root}/{relative}", date_time=timestamp)
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (normalized_mode(path) & 0xFFFF) << 16
            info.flag_bits |= 0x800
            output.writestr(
                info,
                path.read_bytes(),
                compress_type=zipfile.ZIP_DEFLATED,
                compresslevel=9,
            )


def tar_info(name: str, path: Path, epoch: int, is_directory: bool) -> tarfile.TarInfo:
    info = tarfile.TarInfo(name + ("/" if is_directory and not name.endswith("/") else ""))
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = epoch
    info.mode = normalized_mode(path)
    if is_directory:
        info.type = tarfile.DIRTYPE
        info.size = 0
    else:
        info.type = tarfile.REGTYPE
        info.size = path.stat().st_size
    return info


def create_tar_gz(payload: Path, archive: Path, archive_root: str, epoch: int) -> None:
    with archive.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=epoch) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as output:
                output.addfile(tar_info(archive_root, payload, epoch, True))
                for directory in payload_directories(payload):
                    relative = directory.relative_to(payload).as_posix()
                    output.addfile(tar_info(f"{archive_root}/{relative}", directory, epoch, True))
                for path in payload_files(payload):
                    relative = path.relative_to(payload).as_posix()
                    info = tar_info(f"{archive_root}/{relative}", path, epoch, False)
                    with path.open("rb") as stream:
                        output.addfile(info, stream)


def expected_archive_files(payload: Path, archive_root: str) -> dict[str, tuple[int, int]]:
    return {
        f"{archive_root}/{path.relative_to(payload).as_posix()}": (
            path.stat().st_size,
            normalized_mode(path),
        )
        for path in payload_files(payload)
    }


def validate_zip_archive(
    archive: Path, payload: Path, archive_root: str, epoch: int
) -> None:
    expected = expected_archive_files(payload, archive_root)
    expected_timestamp = zip_datetime(epoch)
    with zipfile.ZipFile(archive) as source:
        infos = source.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise ReleaseError("ZIP contains duplicate member names")
        if set(names) != set(expected):
            missing = sorted(set(expected) - set(names))
            extra = sorted(set(names) - set(expected))
            raise ReleaseError(f"ZIP members differ; missing={missing}, extra={extra}")
        for info in infos:
            safe_member_path(Path("/archive-check"), info.filename)
            expected_size, expected_mode = expected[info.filename]
            mode = (info.external_attr >> 16) & 0o777
            if info.is_dir() or info.file_size != expected_size:
                raise ReleaseError(f"invalid ZIP member size/type: {info.filename}")
            if mode != expected_mode:
                raise ReleaseError(
                    f"invalid ZIP mode for {info.filename}: {mode:o} != {expected_mode:o}"
                )
            if info.date_time != expected_timestamp:
                raise ReleaseError(f"invalid ZIP timestamp for {info.filename}")


def validate_tar_archive(
    archive: Path, payload: Path, archive_root: str, epoch: int
) -> None:
    expected_files = expected_archive_files(payload, archive_root)
    expected_directories = {archive_root: 0o755}
    expected_directories.update(
        {
            f"{archive_root}/{path.relative_to(payload).as_posix()}": normalized_mode(path)
            for path in payload_directories(payload)
        }
    )
    with tarfile.open(archive, "r:gz") as source:
        members = source.getmembers()
        normalized_names = [member.name.rstrip("/") for member in members]
        if len(normalized_names) != len(set(normalized_names)):
            raise ReleaseError("tar.gz contains duplicate member names")
        expected_names = set(expected_files) | set(expected_directories)
        if set(normalized_names) != expected_names:
            missing = sorted(expected_names - set(normalized_names))
            extra = sorted(set(normalized_names) - expected_names)
            raise ReleaseError(f"tar.gz members differ; missing={missing}, extra={extra}")
        for member, name in zip(members, normalized_names):
            safe_member_path(Path("/archive-check"), name)
            if member.uid != 0 or member.gid != 0 or member.uname or member.gname:
                raise ReleaseError(f"non-normalized tar ownership: {name}")
            if int(member.mtime) != epoch:
                raise ReleaseError(f"non-normalized tar timestamp: {name}")
            if name in expected_directories:
                if not member.isdir() or stat.S_IMODE(member.mode) != expected_directories[name]:
                    raise ReleaseError(f"invalid tar directory metadata: {name}")
            else:
                expected_size, expected_mode = expected_files[name]
                if not member.isfile() or member.size != expected_size:
                    raise ReleaseError(f"invalid tar member size/type: {name}")
                if stat.S_IMODE(member.mode) != expected_mode:
                    raise ReleaseError(f"invalid tar member mode: {name}")


def safe_member_path(root: Path, member_name: str) -> Path:
    pure = PurePosixPath(member_name)
    if pure.is_absolute() or ".." in pure.parts or not pure.parts:
        raise ReleaseError(f"archive contains unsafe path: {member_name}")
    target = root.joinpath(*pure.parts).resolve()
    try:
        target.relative_to(root.resolve())
    except ValueError as error:
        raise ReleaseError(f"archive path escapes extraction root: {member_name}") from error
    return target


def extract_zip(archive: Path, destination: Path) -> None:
    with zipfile.ZipFile(archive) as source:
        for info in source.infolist():
            target = safe_member_path(destination, info.filename)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(info) as input_stream, target.open("wb") as output_stream:
                shutil.copyfileobj(input_stream, output_stream)
            mode = (info.external_attr >> 16) & 0o777
            target.chmod(mode or 0o644)


def extract_tar_gz(archive: Path, destination: Path) -> None:
    with tarfile.open(archive, "r:gz") as source:
        for member in source.getmembers():
            target = safe_member_path(destination, member.name)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(member.mode & 0o777)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                input_stream = source.extractfile(member)
                if input_stream is None:
                    raise ReleaseError(f"could not read archive member: {member.name}")
                with input_stream, target.open("wb") as output_stream:
                    shutil.copyfileobj(input_stream, output_stream)
                target.chmod(member.mode & 0o777)
            else:
                raise ReleaseError(f"unexpected archive member type: {member.name}")


def file_map(payload: Path, include_modes: bool) -> dict[str, tuple[str, int | None]]:
    return {
        path.relative_to(payload).as_posix(): (
            sha256_file(path),
            actual_mode(path) if include_modes else None,
        )
        for path in payload_files(payload)
    }


def compare_payloads(expected: Path, actual: Path, label: str) -> None:
    # Windows does not preserve POSIX executable bits through chmod/stat. Archive
    # metadata is still checked above; extracted modes are compared on POSIX.
    include_modes = os.name != "nt"
    expected_map = file_map(expected, include_modes)
    actual_map = file_map(actual, include_modes)
    if expected_map != actual_map:
        missing = sorted(set(expected_map) - set(actual_map))
        extra = sorted(set(actual_map) - set(expected_map))
        changed = sorted(
            name for name in set(expected_map) & set(actual_map) if expected_map[name] != actual_map[name]
        )
        raise ReleaseError(
            f"{label} payload differs; missing={missing}, extra={extra}, changed={changed}"
        )


def verify_manifest(payload: Path) -> None:
    manifest = payload / "MANIFEST.sha256"
    if not manifest.is_file():
        raise ReleaseError("archive payload has no MANIFEST.sha256")
    expected: dict[str, str] = {}
    for line_number, line in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
        if "  " not in line:
            raise ReleaseError(f"invalid manifest line {line_number}")
        digest, relative = line.split("  ", 1)
        if len(digest) != 64 or any(character not in "0123456789abcdef" for character in digest):
            raise ReleaseError(f"invalid manifest digest on line {line_number}")
        if relative in expected:
            raise ReleaseError(f"duplicate manifest entry: {relative}")
        target = safe_member_path(payload, relative)
        if not target.is_file():
            raise ReleaseError(f"manifest entry is missing: {relative}")
        expected[relative] = digest
        if sha256_file(target) != digest:
            raise ReleaseError(f"manifest digest mismatch: {relative}")
    actual = {
        path.relative_to(payload).as_posix()
        for path in payload_files(payload)
        if path != manifest
    }
    if actual != set(expected):
        raise ReleaseError("manifest does not cover exactly the payload files")


def reproducibility_check(
    payload: Path, archive_root: str, epoch: int, zip_archive: Path, tar_archive: Path, work: Path
) -> None:
    second_zip = work / "reproducibility.zip"
    second_tar = work / "reproducibility.tar.gz"
    create_zip(payload, second_zip, archive_root, epoch)
    create_tar_gz(payload, second_tar, archive_root, epoch)
    if sha256_file(second_zip) != sha256_file(zip_archive):
        raise ReleaseError("ZIP output is not reproducible")
    if sha256_file(second_tar) != sha256_file(tar_archive):
        raise ReleaseError("tar.gz output is not reproducible")


def tee_process(command: list[str], cwd: Path, env: dict[str, str], log: Path) -> None:
    print("+", " ".join(command), flush=True)
    with log.open("w", encoding="utf-8", newline="\n") as output:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
            output.write(line)
        code = process.wait()
    if code != 0:
        raise ReleaseError(f"archive verification failed with exit code {code}; see {log}")


def verify_extracted_release(
    extracted_payload: Path,
    log: Path,
    compiler: str | None,
    dub_command: str | None,
    python_command: str,
    verify_vulkan: bool,
    verify_gui: bool,
) -> None:
    env = os.environ.copy()
    if compiler:
        env["DC"] = compiler
    if dub_command:
        env["DUB"] = dub_command
    env["PYTHON"] = python_command
    env["AURORA_VERIFY_VULKAN"] = "1" if verify_vulkan else "0"
    env["AURORA_VERIFY_GUI"] = "1" if verify_gui else "0"
    if verify_gui:
        env["AURORA_GUI_RENDERERS"] = "software vulkan" if verify_vulkan else "software"

    if os.name == "nt":
        powershell = shutil.which("pwsh") or shutil.which("powershell")
        if not powershell:
            raise ReleaseError("PowerShell is required to verify a Windows package")
        command = [
            powershell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(extracted_payload / "scripts/verify-release.ps1"),
        ]
    else:
        command = ["sh", str(extracted_payload / "scripts/verify-release.sh")]
    tee_process(command, extracted_payload, env, log)


def write_checksums(output: Path, version: str, archives: list[Path]) -> Path:
    target = output / f"aurora-d-{version}.sha256"
    target.write_text(
        "".join(f"{sha256_file(path)}  {path.name}\n" for path in archives), encoding="utf-8"
    )
    return target


def write_report(
    output: Path,
    version: str,
    archive_root: str,
    epoch: int,
    payload: Path,
    archives: list[Path],
    manifest: Path,
    checksum_file: Path,
    verification_log: Path,
    verification: str,
    verify_vulkan: bool,
    verify_gui: bool,
) -> Path:
    report = {
        "archiveRoot": archive_root,
        "archives": [
            {"bytes": path.stat().st_size, "name": path.name, "sha256": sha256_file(path)}
            for path in archives
        ],
        "checks": {
            "archiveMetadata": "passed",
            "assetRegeneration": "passed",
            "crossArchivePayload": "passed",
            "deterministicSecondBuild": "passed",
            "embeddedManifests": "passed",
            "extractedReleaseVerification": verification,
            "sourceAllowlist": "passed",
        },
        "checksumFileSha256": sha256_file(checksum_file),
        "formatVersion": 2,
        "guiRuntimeSmoke": verify_gui and verification == "passed",
        "host": {
            "platform": platform.platform(),
            "pythonImplementation": platform.python_implementation(),
            "pythonVersion": platform.python_version(),
        },
        "manifestSha256": sha256_file(manifest),
        "name": "aurora-d",
        "payloadBytes": sum(path.stat().st_size for path in payload_files(payload)),
        "payloadFiles": len(payload_files(payload)),
        "publicationStrategy": "per-file-atomic-report-last",
        "sourceDateEpoch": epoch,
        "verification": verification,
        "verificationLogSha256": sha256_file(verification_log),
        "verificationOptions": {"gui": verify_gui, "vulkan": verify_vulkan},
        "version": version,
        "vulkanRuntimeSmoke": verify_vulkan and verification == "passed",
    }
    target = output / f"aurora-d-{version}.release.json"
    target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return target


def publish_artifacts(staged: list[Path], output: Path) -> list[Path]:
    if not staged or not staged[-1].name.endswith(".release.json"):
        raise ReleaseError("the release report must be the last staged publication artifact")

    output.mkdir(parents=True, exist_ok=True)
    temporary: list[tuple[Path, Path]] = []
    report_source = staged[-1]
    report_final = output / report_source.name
    report_removed = False
    try:
        for source in staged:
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{source.name}.", suffix=".tmp", dir=output
            )
            temporary_path = Path(temporary_name)
            with os.fdopen(descriptor, "wb") as destination, source.open("rb") as input_stream:
                shutil.copyfileobj(input_stream, destination)
                destination.flush()
                os.fsync(destination.fileno())
            temporary_path.chmod(0o644)
            if sha256_file(temporary_path) != sha256_file(source):
                raise ReleaseError(f"publication staging copy differs: {source.name}")
            temporary.append((source, temporary_path))

        # Remove a stale commit marker before changing any member of the release
        # set. If publication is interrupted, no report remains to identify a
        # partial replacement as complete.
        report_final.unlink(missing_ok=True)
        report_removed = True

        published: list[Path] = []
        for source, temporary_path in temporary[:-1]:
            final = output / source.name
            os.replace(temporary_path, final)
            if sha256_file(final) != sha256_file(source):
                raise ReleaseError(f"published artifact differs: {source.name}")
            published.append(final)

        # The report is the commit marker and is replaced only after every
        # preceding artifact is present and hash-verified.
        report_temporary = temporary[-1][1]
        os.replace(report_temporary, report_final)
        if sha256_file(report_final) != sha256_file(report_source):
            raise ReleaseError(f"published artifact differs: {report_source.name}")
        published.append(report_final)

        if hasattr(os, "O_DIRECTORY"):
            directory_descriptor = os.open(output, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory_descriptor)
            finally:
                os.close(directory_descriptor)
        return published
    except Exception:
        if report_removed:
            report_final.unlink(missing_ok=True)
        raise
    finally:
        for _, temporary_path in temporary:
            temporary_path.unlink(missing_ok=True)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--compiler", default=os.environ.get("DC"))
    parser.add_argument("--dub", dest="dub_command", default=os.environ.get("DUB"))
    parser.add_argument("--python", dest="python_command", default=sys.executable)
    parser.add_argument(
        "--source-date-epoch",
        type=int,
        default=int(os.environ.get("SOURCE_DATE_EPOCH", FIXED_ZIP_EPOCH)),
    )
    parser.add_argument("--skip-verify", action="store_true")
    parser.add_argument("--verify-vulkan", action="store_true")
    parser.add_argument("--verify-gui", action="store_true")
    parser.add_argument("--keep-work", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_arguments()
    root = args.root.resolve()
    output = (args.output or (root / "dist")).resolve()
    epoch = max(args.source_date_epoch, FIXED_ZIP_EPOCH)
    work: Path | None = None
    succeeded = False

    try:
        version = package_version(root)
        archive_root = f"aurora-d-{version}"
        run_checked([args.python_command, str(root / "tools/verify_assets.py"), "--root", str(root)], root)

        work = Path(tempfile.mkdtemp(prefix=f"aurora-d-{version}-release-"))
        artifact_stage = work / "artifacts"
        artifact_stage.mkdir()
        payload = work / "stage" / archive_root
        copy_release_inputs(root, payload)
        validate_payload(payload)
        write_package_metadata(payload, version, archive_root, epoch)
        manifest = write_manifest(payload)
        normalize_payload(payload, epoch)
        validate_payload(payload)
        verify_manifest(payload)

        zip_archive = artifact_stage / f"aurora-d-{version}.zip"
        tar_archive = artifact_stage / f"aurora-d-{version}.tar.gz"
        create_zip(payload, zip_archive, archive_root, epoch)
        create_tar_gz(payload, tar_archive, archive_root, epoch)
        validate_zip_archive(zip_archive, payload, archive_root, epoch)
        validate_tar_archive(tar_archive, payload, archive_root, epoch)
        reproducibility_check(payload, archive_root, epoch, zip_archive, tar_archive, work)

        zip_extract = work / "zip-extract"
        tar_extract = work / "tar-extract"
        zip_extract.mkdir()
        tar_extract.mkdir()
        extract_zip(zip_archive, zip_extract)
        extract_tar_gz(tar_archive, tar_extract)
        zip_payload = zip_extract / archive_root
        tar_payload = tar_extract / archive_root
        compare_payloads(payload, zip_payload, "ZIP")
        compare_payloads(payload, tar_payload, "tar.gz")
        compare_payloads(zip_payload, tar_payload, "cross-archive")
        verify_manifest(zip_payload)
        verify_manifest(tar_payload)

        verification_log = artifact_stage / f"aurora-d-{version}-verification.log"
        if args.skip_verify:
            verification_log.write_text(
                "Release verification was explicitly skipped.\n", encoding="utf-8"
            )
            verification = "skipped"
        else:
            verify_extracted_release(
                zip_payload,
                verification_log,
                args.compiler,
                args.dub_command,
                args.python_command,
                args.verify_vulkan,
                args.verify_gui,
            )
            verification = "passed"

        checksum_file = write_checksums(artifact_stage, version, [zip_archive, tar_archive])
        report_file = write_report(
            artifact_stage,
            version,
            archive_root,
            epoch,
            payload,
            [zip_archive, tar_archive],
            manifest,
            checksum_file,
            verification_log,
            verification,
            args.verify_vulkan,
            args.verify_gui,
        )

        # The report is published last; its presence signals that all other
        # files in this release set were generated and validated successfully.
        staged = [zip_archive, tar_archive, checksum_file, verification_log, report_file]
        published = publish_artifacts(staged, output)
        published_by_name = {path.name: path for path in published}

        for source in staged:
            print(f"Created {published_by_name[source.name]}")
        print(
            f"Payload: {len(payload_files(payload))} files, "
            f"{sum(path.stat().st_size for path in payload_files(payload)):,} bytes"
        )
        succeeded = True
        return 0
    except (ReleaseError, OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(f"Release packaging failed: {error}", file=sys.stderr)
        return 1
    finally:
        if work is not None:
            if args.keep_work or not succeeded:
                print(f"Kept release work directory: {work}", file=sys.stderr)
            else:
                shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
