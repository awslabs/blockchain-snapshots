# Landing page

A zero-build static page listing the public blockchain snapshots, loaded live
from the per-region CloudFront catalog endpoints. Hostable anywhere (GitHub Pages,
S3, `python3 -m http.server`) — it only makes cross-origin `fetch`es to public
`catalog.json` endpoints that return `Access-Control-Allow-Origin: *`.

## Files

- `index.html` / `styles.css` / `app.js` — the page.
- `catalog-endpoints.json` — **gitignored, generated per environment**. The page
  fetches this at runtime to discover per-region catalog URLs.
- `catalog-endpoints.example.json` — committed placeholder showing the expected shape.
- `build-endpoints.sh` — generates `catalog-endpoints.json` from the deployed stacks.
- `.gitignore` — ensures `catalog-endpoints.json` is never committed.

## Environment isolation

The page is **environment-aware by design**: no staging URLs, account IDs, or
CloudFront domains are committed to source. Each environment's published landing
artifact carries only its own endpoints.

The separation:

| File | Committed? | Content |
|------|-----------|---------|
| `config/regions.json` | yes | region **codes** only — safe everywhere |
| `landing/catalog-endpoints.json` | **no** (gitignored) | per-env `{code, catalogUrl}` |

So if you push the `landing/` directory to a public GitHub repo for production,
it does NOT leak staging CloudFront URLs or internal account info.

## Generate endpoints

```sh
cd landing
./build-endpoints.sh --stage staging --profile <your-aws-profile>
# or for production:
./build-endpoints.sh --stage production --profile <your-aws-profile>
```

This reads deployed CloudFormation `CatalogUrl` outputs for each region in
`config/regions.json`. Regions where the catalog CDN isn't deployed yet are left
out of the file (and listed on stderr), so the page only shows live regions.

## Local dev

```sh
cd landing
# generate endpoints for whatever env you want to test against:
./build-endpoints.sh --stage staging --profile <your-aws-profile>
python3 -m http.server 8791
# open http://127.0.0.1:8791
```

## Deploy to production (public repo)

```sh
cd landing
./build-endpoints.sh --stage production --profile <your-aws-profile>
# now publish: index.html, styles.css, app.js, catalog-endpoints.json
# (catalog-endpoints.example.json and build-endpoints.sh are dev aids, optional)
```

Only `catalog-endpoints.json` (generated) carries env-specific data, and it's
generated fresh for the target environment at deploy time. The committed source
is clean.
