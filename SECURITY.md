# Security

## Reporting a vulnerability

Do not open a public GitHub issue for a suspected security vulnerability.
Report it through the [AWS vulnerability reporting process](https://aws.amazon.com/security/vulnerability-reporting/).
Include the affected script or component, the observed behavior, reproduction steps, and any relevant logs with secrets removed.

AWS will acknowledge the report and coordinate triage and disclosure. Do not publicly disclose the issue until AWS has completed its review.

## Scope

The public project contains customer-run download, storage setup, and snapshot extraction tools, plus a static snapshot catalog page. The tools run in the customer's AWS account and use the customer's ambient AWS credential chain. They do not accept or store long-term credentials.

Security-relevant areas include:

- path and size validation for snapshot manifests;
- command and argument handling in shell and Python tools;
- IAM examples and EC2 provisioning defaults;
- IMDSv2 use;
- snapshot download and extraction integrity; and
- browser rendering of catalog-controlled values.

## Supported versions

Security fixes are applied to the latest version on the default branch. Users should update to the latest version before reporting an issue that may already be fixed.

## Snapshot integrity

Snapshots are mirrored from third-party public sources and are provided "AS IS" without warranty. Verify integrity before use. Parallel extraction is designed to produce the same file bytes as serial extraction of the same artifact. A restored blockchain node must also validate state against its network peers.
