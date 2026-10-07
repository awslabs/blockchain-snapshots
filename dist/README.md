# Consumer tooling — one catalog-driven entrypoint

Use `snapshot.sh` to resolve and download the latest snapshot. Users select a
stable snapshot ID; the regional catalog declares where the artifact is and how
it must be delivered. There is no hardcoded snapshot list in the tooling.

```bash
sudo ./snapshot.sh \
  --snapshot ethereum-mainnet-geth \
  --region us-east-1 \
  --out /data/ethereum-mainnet-geth \
  --install-deps
```

Run `./snapshot.sh --list --region us-east-1` to discover IDs, or use selectors
such as `--chain solana --network mainnet`. A partial selection that matches
more than one entry lists the candidates rather than guessing.

## How resolution works

1. `snapshot.sh` reads the active-region registry published with the landing
   page:
   `https://awslabs.github.io/blockchain-snapshots/config/regions.json`.
2. It fetches the selected Region's current `catalog.json` (CloudFront first,
   S3 fallback for a private subnet).
3. It resolves the stable ID to the **latest** catalog entry at execution time.
   No block/slot/version is exposed as a user selection.
4. `snapshot-catalog.py` normalizes the deployed catalog-v1 entry into an
   explicit delivery protocol. This is a temporary adapter; the execution
   handlers only consume the normalized model.
5. `snapshot.sh` validates credentials, bucket access, artifact size, output
   safety, dependencies, and available space, then calls the protocol handler.

A copy of `regions.json` may sit beside the script in a dist-only release. It is
used only if the canonical registry cannot be reached.

## Delivery protocols

| Protocol | Behavior |
|---|---|
| `tar-zstd-seekable-v1` | Fetch manifest, decode independent zstd frames in parallel with `snapshot-extract.py`, write the filesystem tree |
| `tar-zstd-stream-v1` | Stream the archive through `zstd | tar`, write the filesystem tree |
| `archive-set-v1` | Retain named full/incremental/genesis archives for the node to unpack |

The catalog decides the protocol. The shell script never dispatches by chain
name. An unknown protocol fails clearly and tells the user to update the
consumer tooling.

## Files

| File | Role |
|---|---|
| `snapshot.sh` | **Public entrypoint:** resolve → validate → dispatch |
| `snapshot-catalog.py` | Untrusted JSON boundary, catalog-v1 adapter, catalog-v2 normalizer and selector |
| `snapshot-extract.py` | Parallel seekable-zstd extraction engine |
| `setup-storage.sh` | Optional local-NVMe RAID/XFS utility; not invoked by `snapshot.sh` |
| `download.sh` | One-release compatibility shim to `snapshot.sh` |
| `download-and-unpack.sh` | One-release compatibility shim for exact `--bucket/--prefix` callers |
| `requirements.txt` | Python dependencies used by the seekable path |

## Storage

Storage provisioning is outside the download command. Prepare a writable,
dedicated output directory on either:

- **Local instance-store NVMe** — fastest. `setup-storage.sh` discovers however
  many AWS instance-store NVMe devices are present, RAID-0s multiple devices,
  formats XFS, and mounts `/data`. It intentionally fails on an EBS-only host.
- **EBS** — mount a sufficiently large EBS filesystem and pass a dedicated
  subdirectory under it, such as `/data/ethereum-mainnet-geth`.

`snapshot.sh` never formats, attaches, RAID-joins or mounts an output device. It
refuses system/data roots and mount-point roots. Filesystem delivery refuses a
non-empty output unless `--force`; archive-set delivery adds named archives
without clearing unrelated files.

The command checks free space before downloading:

- Seekable delivery uses the manifest's exact uncompressed size.
- Stream delivery uses the catalog-v1 conservative estimate (2× compressed
  size) until catalog v2 provides `storage.required_bytes`.
- Archive-set delivery sums known retained artifacts plus a margin.

### O_DIRECT and containers

`--o-direct auto` enables O_DIRECT only on local instance-store NVMe and uses
buffered writes on EBS/unknown. Before enabling it, the extractor performs one
aligned test write; if the filesystem rejects O_DIRECT it warns and falls back
to buffered writes.

Worker count follows CPU affinity, cgroup CPU quota, host/cgroup memory
headroom, and a maximum of 96. This supports Docker, ECS and Kubernetes limits.

## Reading from S3

`--source auto|mount|s3` controls the data path for filesystem delivery:

- `mount`: mountpoint-s3 (FUSE; needs `/dev/fuse` and mount permission).
- `s3`: direct SDK/CLI reads; no FUSE or extra container capabilities.
- `auto`: use mountpoint-s3 when FUSE is usable, otherwise S3. A failed mount
  also falls back to S3.

Archive-set delivery always uses exact S3 artifact URIs from normalized catalog
data.

## Dependencies and OS/CPU support

Supported hosts: Amazon Linux 2023 and Ubuntu 22.04/24.04, x86_64 and arm64.

- Default: missing dependencies are reported with a fix.
- `--install-deps`: install them through apt/dnf/yum (directly as root or through
  sudo), including the architecture-matched AWS CLI v2 and mount-s3 where FUSE
  can work.
- Containers: bake dependencies into the image when possible; use `--source s3`
  or leave `auto`.

The Region is `--region`, then `AWS_REGION`/`AWS_DEFAULT_REGION`, then EC2 IMDSv2.
The container must receive credentials through an ECS task role, EKS Pod
Identity/IRSA, environment credentials, or reachable EC2 instance metadata.

## Compatibility

For one migration release:

```bash
# Old simple form (forwards to catalog-driven latest)
./download.sh --region us-east-1 ethereum-mainnet-geth /data/geth

# Old exact seekable form (preserves bucket/prefix automation)
./download-and-unpack.sh --bucket BUCKET --prefix PREFIX --out /data/extract
```

Both print a deprecation warning. The old `--block` option is removed: the
public experience is latest-only.

## Debugging and automation

- `--json` emits one machine-readable result on stdout; progress stays on
  stderr.
- `DEBUG=1` traces shell commands, keeps the per-run work directory, and logs
  each seekable extraction group.
- The result includes stable snapshot ID, resolved version, protocol, Region,
  output path, bytes, duration, and method. `block` remains as a JSON alias for
  `version` during the compatibility window.
- `--registry URL` selects a test/non-production registry.

## Integrity

The resolver validates catalog shape and exact S3 URIs. Artifact size is checked
against the catalog before delivery; seekable artifacts are also checked against
the download manifest. A future catalog schema can carry complete checksums and
producer-computed storage requirements.

## Disclaimer

These tools and snapshots are provided "AS IS", without warranty. Snapshot data
is mirrored from third-party blockchain publishers. Verify data by running the
node and allowing it to validate against its network peers. No availability,
freshness, or correctness guarantee. See [LICENSE](../LICENSE).
