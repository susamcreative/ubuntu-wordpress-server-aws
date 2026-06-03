# Configuration Reference

Two kinds of instance configuration, both hand-editable, **neither committed to the repo**: the per-server `server.conf`, and the per-site registry records in `sites.d/`. The repo ships `.example` templates for both.

---

## `~/apps/server.conf`

Per-server settings. Copy from the example and edit; scripts fall back to the built-in defaults shown if the file (or a field) is absent.

```bash
cp ~/apps/server.conf.example ~/apps/server.conf
nano ~/apps/server.conf
```

| Field | Default | Meaning |
| --- | --- | --- |
| `ADMIN_EMAIL` | `admin@example.com` | WordPress admin email for sites created by `create-site.sh` |
| `CERTBOT_EMAIL` | `admin@example.com` | Let's Encrypt account email — receives certificate-expiry warnings |
| `WEBHOOK_URL` | *(empty)* | health-check notification endpoint (Make.com, Zapier, …); empty disables |
| `DISK_WARN_THRESHOLD` | `80` | disk-usage % that triggers a warning |
| `DISK_CRIT_THRESHOLD` | `90` | disk-usage % that triggers a critical alert |
| `SSL_WARN_DAYS` | `30` | warn when a certificate expires within this many days |
| `SSL_CRIT_DAYS` | `7` | critical when a certificate expires within this many days |
| `ERROR_WARN_COUNT` | `10` | nginx error-log lines that trigger a warning |
| `ERROR_CRIT_COUNT` | `50` | nginx error-log lines that trigger a critical alert |
| `ALERT_THROTTLE_HOURS` | `24` | minimum hours between repeats of the same alert |
| `PREDROP_DUMP_RETENTION_DAYS` | `30` | keep pre-removal safety dumps this long |
| `BACKUP_RETENTION_DAILY` | `31` | days to keep daily backup archives |
| `BACKUP_RETENTION_WEEKLY` | `91` | days to keep weekly backup archives |
| `BACKUP_RETENTION_MONTHLY` | `366` | days to keep monthly backup archives |
| `REGISTRY_SNAPSHOT_KEEP` | `30` | how many registry snapshots `backup.sh` retains |

---

## `~/apps/sites.d/<domain>.conf`

One record per site — the provenance of its database, files, and certificate. **The registry holds identity, not secrets**: database passwords stay in `wp-config.php`; the record records *which* database belongs to the site, and the two are cross-validated.

```bash
cp ~/apps/sites.d/example.com.conf.example ~/apps/sites.d/<domain>.conf
nano ~/apps/sites.d/<domain>.conf
```

### Identity

| Field | Meaning |
| --- | --- |
| `DOMAIN` | FQDN; must match the filename (`<domain>.conf`) |
| `TYPE` | `production` \| `dev` \| `staging` \| `blueprint` — selects the policy bundle (see Managing Sites) |
| `PARENT` | provenance: the blueprint or production parent this site derives from (`""` if none) |
| `STATUS` | `creating` \| `active` \| `promoting` \| `removing` — transient states older than 24h are flagged by health-check |
| `STATUS_SINCE` | epoch seconds of the last `STATUS` change (script-managed; how "stuck" is measured) |
| `CREATED` | creation date |
| `PROTECTED` | `true` = refuse all destructive operations (always set for blueprints) |

### Bindings (the provenance record)

| Field | Meaning |
| --- | --- |
| `DB_NAME` | the database that belongs to this site — what removal/restore acts on |
| `DB_USER` | the database user |
| `DB_HOST` | usually `localhost` |
| `TABLE_PREFIX` | WordPress table prefix |
| `DOC_ROOT` | absolute path to the site files (may be nested, e.g. a staging site under its parent) |

If a site's `wp-config.php` ever names a different `DB_NAME`/`DB_USER`/`TABLE_PREFIX` than its record, that is a **binding mismatch** — health-check flags it Critical and destructive operations hard-abort, because it is the precondition of dropping the wrong database.

### Policy (defaults from `TYPE`; override per-site)

| Field | Values | Meaning |
| --- | --- | --- |
| `BACKUP_FREQ` | `daily` \| `weekly` \| `monthly` \| `none` | backup cadence (cascading: a daily run backs up `daily` sites; weekly backs up `daily`+`weekly`; monthly backs up all but `none`) |
| `SSL_MODE` | `own` \| `wildcard:<cert-domain>` \| `none` | how TLS is provided |
| `INDEXING` | `allowed` \| `blocked` | whether search engines may index the site |

### Blueprint-only

| Field | Meaning |
| --- | --- |
| `NAMESPACE` | e.g. `dev.example.com` — enables the subdomain-label UX for clones and points them at this wildcard cert |

### Promotion history (set by `promote-site.sh`)

| Field | Meaning |
| --- | --- |
| `PROMOTED_FROM` | the dev domain this production site was promoted from |
| `PROMOTED_DATE` | promotion date |
| `REDIRECT_FROM` | dev domain still 301-redirecting here (`""` = no redirect); removed with the site |

---

## Editing safely

- Whole-file edits are fine — scripts read the current values at run time.
- A syntax error breaks only that one record; the rest of the registry is unaffected.
- After editing, run `~/apps/list-sites.sh` to confirm the record still matches reality.
- Records are owned by the app user. A root-owned record is itself a health-check warning (it would break hand-editing).
