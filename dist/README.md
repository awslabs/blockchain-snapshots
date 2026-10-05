# Consumer tooling — download & extract snapshots

The tools an operator runs to fetch + extract a blockchain snapshot, fast and
byte-identically. The flow is three verbs — **provision → download → extract** —
built around the manifest-driven, O_DIRECT `snapshot-extract.py`.

## What the producer publishes

For each snapshot, two objects under its prefix:
```
<prefix>/snapshot.tar.zst        the multi-frame seekable zstd artifact
<prefix>/download-manifest.json  frames[] byte-ranges + tar members[] (the recipe)
```
The artifact decompresses with any standard zstd tool; the speed comes from the
manifest, which lets many workers decode independent frames in parallel.

## Files

The fast path (recommended):

| file | role |
|---|---|
| `provision-instance.sh` | **provision** — launch an i-class instance + NVMe + mount-s3 toolkit (account-agnostic, flags/env) |
| `setup-storage.sh` | RAID-0 the instance NVMe + mount `/data` (a provisioning sub-step; idempotent, fails loud) |
| `download-and-unpack.sh` | **download + extract** entry point (mountpoint-s3 → parallel decode → O_DIRECT write) |
| `snapshot-extract.py` | the manifest-driven parallel extractor (invoked by `download-and-unpack.sh`) |

Alternate paths:

| file | role |
|---|---|
| `download.sh` | **simple single-stream** download (no manifest/RAID needed) + one-time S3 VPC-endpoint / IAM bootstrap. Slower; use when the full toolkit isn't set up. |
| `provision-and-download.sh` | **EBS-delivery** variant — provision a worker, download onto a new EBS volume, detach and hand the volume back (different shape from the local-NVMe fast path). |

## Run it (three steps)

**1. Provision** (from your workstation):
```bash
./provision-instance.sh --subnet <subnet-id> --sg <sg-id> --region us-east-1
# default --type i8g.12xlarge (~132s); --type i8g.24xlarge for ~70s
```
Needs an SSM-capable instance profile (default `EC2-SSM-Role`; `--iam-profile` to override).

**2. Set up storage** (on the instance, as root):
```bash
sudo bash setup-storage.sh   # RAID-0 + mount /data; idempotent
```

**3. Download + unpack** (on the instance):
```bash
./download-and-unpack.sh --bucket <bucket> --prefix <artifact-dir> --region us-east-1
# e.g. --prefix ethereum/mainnet/geth/<block>   -> extracts to /data/extract
```
Workers auto-tune to `min(nproc, 96)` (96 = the measured mountpoint-s3 sweet spot).

## Performance (full Base sepolia reth, 765 GB, verified byte-identical)

| instance | vCPU | end-to-end | vs `zstd -d \| tar` |
|---|---|---|---|
| i8g.12xlarge | 48 | 132s | 3.9× |
| **i8g.24xlarge** | 96 | **70s** | **7.3×** |

Bottleneck is mountpoint-s3 download concurrency (~6 GB/s at 96 workers), not CPU
or disk. The win requires the producer to have re-packaged the snapshot into many
independent zstd frames (a single-frame `.tar.zst` can't be decoded in parallel).

## Verify integrity

Every published artifact is byte-identical to a serial extraction (full sha256,
all files). To self-check: `sha256sum` an extracted file vs a
`zstd -dc snapshot.tar.zst | tar -x` of the same.

## Sharing with another AWS account

Grant read with a cross-account bucket policy — see
`service/security/policies/peer-bucket-policy.json` for the template (lists peer
account IDs, scoped to read). Peers then run the steps above with their own creds.

## Disclaimer

These tools and the snapshots they consume are provided "AS IS", without warranty
of any kind. Snapshot data is mirrored from third-party blockchain foundations
and teams; verify integrity yourself (hash comparison + node peer validation).
No availability, freshness, or correctness guarantee. See [LICENSE](../LICENSE).
