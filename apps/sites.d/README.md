# sites.d/ — the site registry

One file per site, `<domain>.conf`, in `key="value"` format. This directory is the
**single source of truth** for what sites exist and what database / files / certs
belong to each. Every other store (filesystem, MySQL, nginx, certbot, backups) is
verified *against* it.

- **Hand-editable.** Edit a record with `nano <domain>.conf`. A typo breaks only that
  one record, never the whole registry.
- **Script-managed too.** `create-site.sh`, `promote-site.sh`, `remove-site.sh`, and the
  staging adoption tool write/delete whole files atomically — they never edit in place.
- **Instance state.** Real records are never committed (see repo `.gitignore`). The
  committed `example.com.conf.example` documents the format.

See `example.com.conf.example` for every field, and `DESIGN.md` §5 for the model.

To register a manually-built site, copy the example and fill it in:

```bash
cp example.com.conf.example mysite.com.conf
nano mysite.com.conf      # set DOMAIN, DB_NAME, DB_USER, TABLE_PREFIX, DOC_ROOT, ...
```
