# Landing page

A zero-build static page listing public blockchain snapshots from the active
regional catalogs. Hostable on GitHub Pages, S3, or a local HTTP server.

## Active-region registry

`config/regions.json` is the canonical, committed production registry consumed
by both the page and `dist/snapshot.sh`. It contains only active regions and each
region's public CloudFront catalog URL plus its S3 URI (private-subnet fallback).
Adding a region is a data-only page update; it does not require a consumer-tool
or AWS deployment.

Current public URL:

```text
https://awslabs.github.io/blockchain-snapshots/config/regions.json
```

Regenerate it from existing stack outputs (read-only; this does not deploy):

```sh
./build-endpoints.sh --stage production --profile <profile>
```

Review the diff before publishing. The generator refuses to overwrite the file
when it finds no active catalogs.

## Files

- `index.html`, `site.css`, `app.js` — static page.
- `brand/` — AWS brand stylesheet, palette tokens, and logo. The page uses
  system fonts only; don't add web-font files.
- `assets/` — illustration and background images.
- `config/regions.json` — active Region + catalog registry.
- `build-endpoints.sh` — read-only registry generator from CloudFormation
  outputs.
- `catalog-endpoints.example.json` and the ignored
  `catalog-endpoints.json` — legacy development artifacts; no longer consumed
  by the page.

## Local preview

```sh
cd landing
python3 -m http.server 8791
# open http://127.0.0.1:8791
```

The page fetches `./config/regions.json`, then each region's current
`catalog.json`, and checks the catalogs again every 5 minutes while the tab is
visible. It lists only the chains in `ENABLED_CHAINS` (`app.js`); catalog
entries for any other chain are skipped. Catalog values are escaped before
rendering. Copyable commands use one entrypoint (`snapshot.sh`) and stable
catalog IDs; the script resolves the latest entry again when the operator runs
it, so a long-open page does not produce a stale artifact key.
