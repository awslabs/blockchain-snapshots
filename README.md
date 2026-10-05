# Blockchain Snapshots on AWS

Snapshots for public blockchains on Amazon S3. Bootstrap a node in minutes instead
of hours. Snapshots are re-packaged into a multi-frame **seekable** zstd
format so they download and extract in parallel, roughly **7× faster** than a
single-stream `zstd -d | tar`.

This repository contains the **consumer tooling** (download + parallel extract)
and a **landing page** that lists what's currently available across regions.

## What's published

For each snapshot, two objects live under its prefix in a regional bucket:

```
<blockchain>/<network>/<client>/<block>/snapshot.tar.zst        the seekable zstd artifact
<blockchain>/<network>/<client>/<block>/download-manifest.json  frame byte-ranges + tar members (the recipe)
```

The artifact decompresses with any standard zstd tool. The speed comes from the
manifest, which lets many workers decode independent frames in parallel and write
them with `O_DIRECT`.

Each region also publishes a public `catalog.json` at its bucket root (served over
CloudFront with permissive CORS) — a stable, self-describing inventory of every
available snapshot: blockchain, network, client, latest block, size, and the
canonical object URL.

## Quick start

On an EC2 instance in a supported region:

```bash
# 1. RAID-0 the instance NVMe → /data
sudo bash dist/setup-storage.sh

# 2. download + extract a snapshot in parallel
dist/download-and-unpack.sh \
  --bucket <bucket> \
  --prefix ethereum/mainnet/geth/<block>
```

See [dist/README.md](dist/README.md) for the full workflow (provision →
setup-storage → download-and-unpack), performance numbers, and integrity
verification. A simpler single-stream path is [`dist/download.sh`](dist/download.sh).

## Discovering snapshots

The [landing page](landing/) is a zero-build static site that reads each region's
public `catalog.json` and lets you browse available snapshots by region and
blockchain, with copy-paste download URLs. Host it anywhere (S3, GitHub Pages,
`python3 -m http.server`) — see [landing/README.md](landing/README.md).

## Contents

| Path | What |
|------|------|
| `dist/` | Download + parallel-extract tooling (provision, storage, extract) |
| `landing/` | Static page listing available snapshots across regions |

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability reporting process and the
security scope of the published tooling. Do not report a suspected vulnerability
through a public GitHub issue.

## Disclaimer

**The snapshots and this tooling are provided "AS IS", without warranties or
conditions of any kind — use them at your own risk.**

- **Snapshot data is mirrored from third-party sources.** Snapshots are
  re-packaged copies of node databases published by the respective network
  foundations and teams. We do not create, validate, or curate the blockchain
  data they contain, and the same disclaimers of warranty made by those upstream
  providers apply to the mirrored copies. Verify integrity before relying on a
  snapshot: extraction is byte-identical to the upstream archive (compare
  hashes), and a node restored from any snapshot validates against its network
  peers — the network, not this mirror, is the final arbiter of correctness.
- **No availability or freshness guarantee.** Snapshots refresh on the upstream
  provider's cadence, may lag the chain tip, and may be replaced or removed at
  any time. This is not an AWS service and carries no SLA.
- **No endorsement.** Availability of a network's snapshots does not constitute
  an endorsement of any blockchain network, protocol, or digital asset.
- **Costs.** The snapshots are provided without charge, but standard charges for
  the AWS resources you use to download, store, and run them (EC2, EBS, etc.)
  still apply to your account.
- **Code** in this repository is licensed under Apache-2.0 and provided on an
  "AS IS" basis per its Section 7 (Disclaimer of Warranty) and Section 8
  (Limitation of Liability). See [LICENSE](LICENSE).

## License

This project is licensed under the Apache-2.0 License. See [LICENSE](LICENSE).
