# Blockchain Snapshots on AWS

Bootstrap public-blockchain nodes from current snapshots in Amazon S3 instead
of starting from genesis. This repository contains the catalog-driven consumer
tooling and the landing page listing active snapshots and Regions.

## Quick start

On an EC2 instance in an active Region, with a prepared EBS or local-NVMe output
volume and an S3 gateway VPC endpoint:

```bash
cd dist
sudo ./snapshot.sh \
  --snapshot ethereum-mainnet-geth \
  --region us-east-1 \
  --out /data/ethereum-mainnet-geth \
  --install-deps
```

Discover current IDs:

```bash
./snapshot.sh --list --region us-east-1
```

The command resolves the latest catalog entry at execution time, checks IAM,
S3 access, artifact size and free storage, then selects the delivery protocol
from catalog data. Users do not choose a block, a script, or an extraction
method.

See [dist/README.md](dist/README.md) for storage, containers, compatibility and
troubleshooting.

## Data-driven discovery

The active-region registry is published with the landing page at:

```text
https://awslabs.github.io/blockchain-snapshots/config/regions.json
```

It points at each active Region's `catalog.json`. The tooling contains no
hardcoded snapshot allowlist. Adding a snapshot that uses an existing delivery
protocol is a producer/catalog data change, not a consumer-tool release.

The currently deployed catalog schema is normalized through an isolated v1
adapter. Execution uses explicit protocols:

- `tar-zstd-seekable-v1` — parallel manifest-driven extraction.
- `tar-zstd-stream-v1` — streaming extraction.
- `archive-set-v1` — retained archives such as full/incremental/genesis.

## Contents

| Path | What |
|---|---|
| `dist/snapshot.sh` | Unified public entrypoint |
| `dist/snapshot-catalog.py` | Registry/catalog resolver and schema adapter |
| `dist/snapshot-extract.py` | Parallel seekable-zstd extraction engine |
| `dist/setup-storage.sh` | Optional local-NVMe setup utility |
| `landing/` | Static snapshot browser and active-region registry |

`dist/download.sh` and `dist/download-and-unpack.sh` are temporary compatibility
shims and print a deprecation warning.

## Storage and costs

The output may be on EBS or local instance-store NVMe. Storage provisioning is
outside the download command; pass a dedicated, writable output directory with
enough free capacity. Standard charges apply for the EC2, EBS and other AWS
resources in your account. The snapshots themselves are provided without
charge.

## Security

See [SECURITY.md](SECURITY.md) for vulnerability reporting. Do not report a
suspected vulnerability through a public GitHub issue.

## Disclaimer

**The snapshots and this tooling are provided "AS IS", without warranties or
conditions of any kind — use them at your own risk.**

Snapshot data is mirrored from third-party blockchain foundations and teams.
Availability does not constitute endorsement. No availability, freshness or
correctness guarantee is provided, and this is not an AWS service or SLA. A node
restored from a snapshot must validate against its network peers; the network is
the final arbiter of correctness.

## License

Apache-2.0. See [LICENSE](LICENSE).
