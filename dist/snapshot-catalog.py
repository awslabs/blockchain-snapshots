#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Resolve a snapshot from the public regional catalog.

This module is the data boundary for snapshot.sh. It loads the active-region
registry, fetches that region's catalog, normalizes catalog v1 or v2 into one
versioned model, then selects an entry by stable ID or metadata selectors.
Execution code never sees catalog-v1 inference or chain-specific compatibility.

Normal use:
  snapshot-catalog.py resolve --registry URL --fallback FILE --region us-east-1 \
      --snapshot SNAPSHOT_ID --output /tmp/resolved.json
  snapshot-catalog.py list --registry URL --fallback FILE --region us-east-1

The registry and catalog are untrusted input. No values are emitted as shell
syntax and snapshot.sh never evals this program's output; it reads individual
JSON fields with the `get` subcommand.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

USER_AGENT = "blockchain-snapshots-consumer/1"
PUBLIC_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class CatalogError(Exception):
    """Invalid, unavailable, or ambiguous catalog data."""


def _read_json_bytes(raw, source):
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CatalogError(f"{source} is not valid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise CatalogError(f"{source} must contain a JSON object")
    return value


def _load_http(url, timeout=15):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return _read_json_bytes(response.read(), url)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise CatalogError(f"cannot fetch {url}: {exc}") from exc


def _load_file(path):
    try:
        with open(path, "rb") as stream:
            return _read_json_bytes(stream.read(), path)
    except OSError as exc:
        raise CatalogError(f"cannot read {path}: {exc.strerror}") from exc


def load_json(source):
    """Load JSON from https/http/file URL or filesystem path."""
    parsed = urllib.parse.urlparse(source)
    if parsed.scheme in ("http", "https"):
        return _load_http(source)
    if parsed.scheme == "file":
        return _load_file(urllib.request.url2pathname(parsed.path))
    if parsed.scheme:
        raise CatalogError(f"unsupported URL scheme in {source!r}")
    return _load_file(source)


def load_registry(primary, fallback=None):
    """Load canonical remote registry, falling back to its release-bundled copy."""
    try:
        registry = load_json(primary)
        source = primary
    except CatalogError as primary_error:
        if not fallback or not os.path.isfile(fallback):
            raise primary_error
        registry = load_json(fallback)
        source = fallback
    regions = registry.get("regions")
    if not isinstance(regions, list) or not regions:
        raise CatalogError(f"registry {source} has no active regions")
    return registry, source


def region_entry(registry, region):
    matches = [item for item in registry["regions"]
               if isinstance(item, dict) and item.get("code") == region]
    if not matches:
        active = sorted(item.get("code") for item in registry["regions"]
                        if isinstance(item, dict) and item.get("code"))
        raise CatalogError(
            f"region {region!r} is not active; choose one of: {', '.join(active)}"
        )
    if len(matches) != 1:
        raise CatalogError(f"registry contains region {region!r} more than once")
    item = matches[0]
    catalog_url = item.get("catalog_url") or item.get("catalogUrl")
    catalog_s3_uri = item.get("catalog_s3_uri")
    if not catalog_url and not catalog_s3_uri:
        raise CatalogError(f"registry entry for {region!r} has no catalog location")
    return item


def _load_s3_json(uri, region):
    """Read through the AWS CLI, which uses the S3 gateway endpoint and the
    caller's credentials. This is the private-subnet fallback when CloudFront
    is unreachable. AWS_ENDPOINT_URL is honored by the CLI for local tests."""
    try:
        result = subprocess.run(
            ["aws", "s3", "cp", uri, "-", "--region", region,
             "--only-show-errors"],
            capture_output=True, check=False, timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise CatalogError(f"cannot fetch {uri}: {exc}") from exc
    if result.returncode:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise CatalogError(f"cannot fetch {uri}: {detail or 'AWS CLI failed'}")
    return _read_json_bytes(result.stdout, uri)


def load_catalog(registry_item, region):
    """Prefer public CDN; fall back to S3 for private subnets."""
    url = registry_item.get("catalog_url") or registry_item.get("catalogUrl")
    errors = []
    if url:
        try:
            return load_json(url), url
        except CatalogError as exc:
            errors.append(str(exc))
    s3_uri = registry_item.get("catalog_s3_uri")
    if s3_uri:
        try:
            return _load_s3_json(s3_uri, region), s3_uri
        except CatalogError as exc:
            errors.append(str(exc))
    raise CatalogError("; fallback also failed: ".join(errors))


def _required_text(obj, key, context):
    value = obj.get(key)
    if not isinstance(value, str) or not value:
        raise CatalogError(f"{context} is missing non-empty {key!r}")
    return value


def _optional_int(value, context):
    if value is None:
        return None
    if isinstance(value, bool):
        raise CatalogError(f"{context} must be an integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise CatalogError(f"{context} must be an integer") from exc
    if result < 0:
        raise CatalogError(f"{context} must not be negative")
    return result


def _s3_parts(uri, context):
    parsed = urllib.parse.urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.strip("/"):
        raise CatalogError(f"{context} must be an s3://bucket/key URI")
    return parsed.netloc, parsed.path.lstrip("/")


def _safe_id(value, context):
    if not isinstance(value, str) or not PUBLIC_ID.fullmatch(value):
        raise CatalogError(
            f"{context} must be a non-empty public ID using letters, digits, '.', '_' or '-'"
        )
    return value


def _safe_filename(value, context):
    if value is None:
        return None
    if (not isinstance(value, str) or not value or value in (".", "..")
            or os.path.basename(value) != value or "\x00" in value):
        raise CatalogError(f"{context} must be a filename, not a path")
    return value


def _artifact(uri, size=None, filename=None, required=True):
    if not uri:
        if required:
            raise CatalogError("required artifact URI is missing")
        return None
    bucket, key = _s3_parts(uri, "artifact URI")
    value = {"uri": uri, "bucket": bucket, "key": key}
    size = _optional_int(size, f"size for {uri}")
    if size is not None:
        value["size_bytes"] = size
    if filename:
        value["filename"] = _safe_filename(filename, f"filename for {uri}")
    return value


def _legacy_id(entry):
    """Temporary v1 adapter only. Catalog v2 publishes the immutable config ID."""
    return "-".join(_required_text(entry, field, "catalog-v1 snapshot")
                    for field in ("blockchain", "network", "client"))


def _legacy_protocol(entry):
    # Compatibility inference is intentionally isolated here. Handlers never
    # inspect chain names or manifest presence.
    if entry.get("mode") == "remint":
        return "tar-zstd-seekable-v1"
    if entry.get("blockchain") == "solana":
        return "archive-set-v1"
    return "tar-zstd-stream-v1"


def normalize_v1(catalog, entry, catalog_source):
    context = "catalog-v1 snapshot"
    snapshot_id = _safe_id(entry.get("id") or _legacy_id(entry),
                           "catalog-v1 snapshot id")
    blockchain = _required_text(entry, "blockchain", context)
    network = _required_text(entry, "network", context)
    client = _required_text(entry, "client", context)
    protocol = _legacy_protocol(entry)
    bucket = catalog.get("bucket")
    uri = entry.get("s3_uri")
    if not uri:
        key = _required_text(entry, "key", context)
        if not bucket:
            raise CatalogError(f"{context} has neither s3_uri nor catalog bucket")
        uri = f"s3://{bucket}/{key}"
    full = _artifact(uri, entry.get("size_bytes"), entry.get("filename"))
    prefix = full["key"].rsplit("/", 1)[0]
    if protocol == "archive-set-v1":
        artifacts = {"full": full}
    else:
        artifacts = {"snapshot": full}

    if protocol == "tar-zstd-seekable-v1":
        manifest_key = entry.get("manifest") or f"{prefix}/download-manifest.json"
        artifacts["manifest"] = _artifact(f"s3://{full['bucket']}/{manifest_key}")
    elif protocol == "archive-set-v1":
        # Catalog v1 lacks a complete archive recipe. Preserve its current
        # sidecar conventions in this adapter only; archive_set() stays generic.
        artifacts["metadata"] = _artifact(
            f"s3://{full['bucket']}/{prefix}/solana-meta.json")
        incremental = entry.get("incremental")
        if isinstance(incremental, dict) and incremental.get("s3_uri"):
            artifacts["incremental"] = _artifact(
                incremental["s3_uri"], incremental.get("size_bytes"),
                incremental.get("filename"), required=False)
        artifacts["genesis"] = _artifact(
            f"s3://{full['bucket']}/{blockchain}/{network}/{client}/genesis.tar.bz2",
            required=False)

    compressed = full.get("size_bytes")
    if protocol == "tar-zstd-stream-v1" and compressed is not None:
        required_bytes = compressed * 2  # legacy estimate; v2 supplies exact value
    elif protocol == "archive-set-v1":
        known = sum(a.get("size_bytes", 0) for name, a in artifacts.items()
                    if name in ("full", "incremental") and a)
        required_bytes = (known * 105 + 99) // 100 if known else None
    else:
        required_bytes = None  # seekable manifest supplies uncompressed_size

    version_id = entry.get("latest_block")
    return {
        "schema_version": 2,
        "normalized_from": "catalog-v1",
        "catalog_source": catalog_source,
        "catalog_generated_at": catalog.get("generated_at"),
        "region": catalog.get("region"),
        "snapshot": {
            "id": snapshot_id,
            "blockchain": blockchain,
            "network": network,
            "client": client,
            "delivery": {"protocol": protocol},
            "version": {"id": str(version_id) if version_id is not None else None,
                        "display": str(version_id) if version_id is not None else None},
            "artifacts": artifacts,
            "storage": {"required_bytes": required_bytes},
        },
    }


def _normalize_v2_artifact(value, role):
    if not isinstance(value, dict):
        raise CatalogError(f"catalog-v2 artifact {role!r} must be an object")
    artifact = _artifact(value.get("uri"), value.get("size_bytes"),
                         value.get("filename"))
    for optional in ("sha256", "content_type"):
        if value.get(optional) is not None:
            artifact[optional] = value[optional]
    return artifact


def normalize_v2(catalog, entry, catalog_source):
    context = "catalog-v2 snapshot"
    snapshot_id = _safe_id(_required_text(entry, "id", context),
                           "catalog-v2 snapshot id")
    delivery = entry.get("delivery")
    if not isinstance(delivery, dict):
        raise CatalogError(f"{context} {snapshot_id!r} has no delivery object")
    protocol = _required_text(delivery, "protocol", f"delivery for {snapshot_id}")
    artifacts_in = entry.get("artifacts")
    if not isinstance(artifacts_in, dict) or not artifacts_in:
        raise CatalogError(f"{context} {snapshot_id!r} has no artifacts")
    artifacts = {role: _normalize_v2_artifact(value, role)
                 for role, value in artifacts_in.items() if value is not None}
    version = entry.get("version") or {}
    storage = entry.get("storage") or {}
    required = _optional_int(storage.get("required_bytes"),
                             f"storage.required_bytes for {snapshot_id}")
    return {
        "schema_version": 2,
        "normalized_from": "catalog-v2",
        "catalog_source": catalog_source,
        "catalog_generated_at": catalog.get("generated_at"),
        "region": catalog.get("region"),
        "snapshot": {
            "id": snapshot_id,
            "aliases": [_safe_id(alias, f"alias for {snapshot_id}")
                        for alias in (entry.get("aliases") or [])],
            "blockchain": entry.get("blockchain"),
            "network": entry.get("network"),
            "client": entry.get("client"),
            "delivery": {"protocol": protocol},
            "version": {"id": str(version.get("id")) if version.get("id") is not None else None,
                        "display": version.get("display")},
            "artifacts": artifacts,
            "storage": {"required_bytes": required},
        },
    }


def normalize_catalog(catalog, source, requested_region):
    snapshots = catalog.get("snapshots")
    if not isinstance(snapshots, list):
        raise CatalogError(f"catalog {source} has no snapshots array")
    catalog_region = catalog.get("region")
    if catalog_region and catalog_region != requested_region:
        raise CatalogError(
            f"catalog region {catalog_region!r} does not match requested {requested_region!r}"
        )
    version = catalog.get("schema_version", catalog.get("version"))
    if version not in (1, 2):
        raise CatalogError(
            f"unsupported catalog schema {version!r}; update the consumer tooling"
        )
    normalized = []
    for entry in snapshots:
        if not isinstance(entry, dict):
            raise CatalogError(f"catalog {source} contains a non-object snapshot")
        if version == 1:
            normalized.append(normalize_v1(catalog, entry, source))
        elif version == 2:
            normalized.append(normalize_v2(catalog, entry, source))
        else:
            raise CatalogError(
                f"unsupported catalog schema {version!r}; update the consumer tooling"
            )
    return normalized


def _matches(item, args):
    snapshot = item["snapshot"]
    if args.snapshot:
        if args.snapshot != snapshot["id"] and args.snapshot not in snapshot.get("aliases", []):
            return False
    selectors = ((args.chain, "blockchain"), (args.network, "network"),
                 (args.client, "client"))
    return all(value is None or snapshot.get(field) == value for value, field in selectors)


def select(items, args):
    matches = [item for item in items if _matches(item, args)]
    if not matches:
        selector = args.snapshot or "/".join(
            x or "*" for x in (args.chain, args.network, args.client)
        )
        available = ", ".join(sorted(item["snapshot"]["id"] for item in items))
        raise CatalogError(
            f"no snapshot matches {selector!r} in {args.region}; available: {available or 'none'}"
        )
    if len(matches) > 1:
        ids = ", ".join(sorted(item["snapshot"]["id"] for item in matches))
        raise CatalogError(
            f"selection is ambiguous in {args.region}; choose --snapshot from: {ids}"
        )
    return matches[0]


def resolve(args):
    registry, registry_source = load_registry(args.registry, args.fallback)
    item = region_entry(registry, args.region)
    catalog, catalog_source = load_catalog(item, args.region)
    normalized = normalize_catalog(catalog, catalog_source, args.region)
    selected = select(normalized, args)
    selected["registry_source"] = registry_source
    selected["registry_region"] = item
    return selected


def _get(value, path):
    current = value
    for part in path.split("."):
        if isinstance(current, dict):
            current = current.get(part)
        else:
            current = None
        if current is None:
            return None
    return current


def _print_list(items, as_json=False):
    rows = [{
        "id": item["snapshot"]["id"],
        "blockchain": item["snapshot"].get("blockchain"),
        "network": item["snapshot"].get("network"),
        "client": item["snapshot"].get("client"),
        "protocol": item["snapshot"]["delivery"]["protocol"],
        "version": item["snapshot"]["version"].get("display"),
    } for item in items]
    if as_json:
        print(json.dumps({"snapshots": rows}, indent=2))
        return
    if not rows:
        print("No snapshots are currently available.")
        return
    width = max(len(row["id"]) for row in rows)
    for row in sorted(rows, key=lambda value: value["id"]):
        print(f"{row['id']:<{width}}  {row['protocol']:<25}  {row['version'] or '-'}")


def add_source_args(parser):
    parser.add_argument("--registry", required=True)
    parser.add_argument("--fallback")
    parser.add_argument("--region", required=True)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    resolve_parser = sub.add_parser("resolve")
    add_source_args(resolve_parser)
    resolve_parser.add_argument("--snapshot")
    resolve_parser.add_argument("--chain")
    resolve_parser.add_argument("--network")
    resolve_parser.add_argument("--client")
    resolve_parser.add_argument("--output", required=True)

    list_parser = sub.add_parser("list")
    add_source_args(list_parser)
    list_parser.add_argument("--json", action="store_true")

    get_parser = sub.add_parser("get")
    get_parser.add_argument("file")
    get_parser.add_argument("path")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        if args.command == "get":
            value = load_json(args.file)
            result = _get(value, args.path)
            if result is None:
                return 1
            if isinstance(result, (dict, list)):
                print(json.dumps(result, separators=(",", ":")))
            elif isinstance(result, bool):
                print("true" if result else "false")
            else:
                print(result)
            return 0

        registry, _ = load_registry(args.registry, args.fallback)
        item = region_entry(registry, args.region)
        catalog, source = load_catalog(item, args.region)
        normalized = normalize_catalog(catalog, source, args.region)
        if args.command == "list":
            _print_list(normalized, args.json)
            return 0
        result = select(normalized, args)
        result["registry_region"] = item
        with open(args.output, "w") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
        return 0
    except CatalogError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
