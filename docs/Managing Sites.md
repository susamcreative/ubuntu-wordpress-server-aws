# Managing Sites

Once the server is set up (see Initial Setup → Install LEMP → WordPress → SSL → Automation), sites are managed by the scripts in `~/apps/`. This is the operator's guide to that system. Every script supports `--help`; this page covers how the pieces fit together.

## The registry

`~/apps/sites.d/` is the **single source of truth** for what sites exist and what belongs to each — one hand-editable `key="value"` file per site, recording its database, files, and certificate. Every other store (the filesystem, MySQL, nginx, certbot, backups) is verified *against* it.

This is why removal and restore never destroy the wrong thing: they resolve their target from the registry record, not from a `wp-config.php` that might be stale or wrong. Field-by-field documentation is in **Configuration Reference**.

Site records are **instance state** — never committed to the repo. Edit one with `nano ~/apps/sites.d/<domain>.conf`; a typo breaks only that record, never the whole registry.

**MySQL root password.** The operations that create or drop databases (`create-site`, `promote-site`, `remove-site`) authenticate as MySQL root via the `MYSQL_ROOT_PASS` environment variable — supply it per command, e.g. `MYSQL_ROOT_PASS=… ~/apps/create-site.sh clientname`. Backups and health checks do **not** need it (they read each site's credentials from its `wp-config.php`).

## Site types

`TYPE` selects a policy bundle (defaults that any record can override by hand):

| Type | SSL | Backups | Indexing | Removal |
| --- | --- | --- | --- | --- |
| `production` | own certbot cert | daily/weekly/monthly | allowed | `remove-site.sh` |
| `dev` | namespace wildcard | weekly | blocked | `remove-site.sh` |
| `staging` | wildcard | none | blocked | `remove-staging.sh` |
| `blueprint` | wildcard | weekly | blocked | refused while `PROTECTED=true` |

## Creating a site

```bash
~/apps/create-site.sh <name-or-domain>
```

- With a **blueprint** registered, this clones it (your common path). With a `NAMESPACE` set on the blueprint, you pass just a subdomain label (`clientname` → `clientname.dev.example.com`); otherwise pass a full domain.
- With **no blueprint**, it does a vanilla WordPress install. Force it with `--vanilla`; pick a specific blueprint with `--from <domain>`.
- The registry record is written **first** (status `creating`), before any resource — so an interrupted run leaves a record to resume or roll back, never an invisible orphan.

Manual creation (the WordPress guide) does the same steps by hand; you finish by writing the registry record (see "Register the Site" there).

## Listing & health

```bash
~/apps/list-sites.sh        # every registered site, cross-checked against reality, plus orphans
~/apps/health-check.sh      # disk/SSL/services + registry checks (binding mismatches, orphans, stuck ops)
```

An **orphan** is a database/directory/config not traceable to a registry record (e.g. a half-finished clone). A **binding mismatch** is a live site whose `wp-config.php` names a different database than its record — the precondition of a wrong-target removal — and is flagged Critical.

## Removing a site

```bash
~/apps/remove-site.sh [--dry-run] [--force] <domain>
```

Resolves the database/files/cert from the **registry**, takes a **pre-drop database dump** (kept under `~/backups/<domain>/pre-removal/`), then removes through guards that refuse to drop a database claimed by another site or a `PROTECTED` one. A site with registered children (e.g. a staging site) must have those removed first. Use `remove-staging.sh` for staging sites.

## Promotion (dev → production)

```bash
~/apps/promote-site.sh <dev-domain> <new-domain>
```

A **rename in place**: the dev site becomes the production site, and the dev domain becomes a 301 redirect. The certificate for the new domain is obtained **first** — if DNS isn't pointed yet and that fails, the dev site is left completely untouched. URLs are rebased serialization-safely (via PHP, no wp-cli), the cache salt is rotated, backups switch on, and search-engine indexing is enabled.

Point the new domain's DNS at this server before promoting. (For relaunches over an existing live site, set up a temporary redirect for the old site first, as usual.)

## Blueprint & namespace

A **blueprint** is a normal WordPress site you designate as the template all new sites clone from. To create one: build the site (theme, base plugins, starter content), then mark its registry record:

```bash
nano ~/apps/sites.d/blueprint.dev.example.com.conf
#   TYPE="blueprint"
#   PROTECTED="true"               # never removable while set
#   NAMESPACE="dev.example.com"    # new clones become <label>.dev.example.com
```

The `NAMESPACE` needs a **wildcard certificate** (`*.dev.example.com`), issued via DNS-01 — see `SSL Let's Encrypt.md` → "Cloudflare DNS Challenge". All dev clones and their redirect blocks reuse that one cert.

Keep the blueprint healthy: every new site inherits its WordPress core and plugin versions, so update it like any production site.

## Staging

Staging sites are created by cloning plugins (WP Staging, Duplicator, …). After the plugin makes one, **adopt** it:

```bash
~/apps/setup-staging-nginx.sh staging.<parent-domain>
```

This **verifies before adopting**: a staging clone whose `wp-config.php` still points at a live site's database is a broken clone and is hard-rejected — so removing it later can never drop the parent's database. A verified staging site is registered (`TYPE=staging`, blocked from search engines) and configured without caching.

## Backups & restore

Backups are registry-driven and run from cron (see Automation). Each archive is **self-describing** (site files + database dump + the registry record), so a removed site can be fully resurrected from its backup alone:

```bash
~/apps/restore-backup.sh <domain>            # lists that site's archives
~/apps/restore-backup.sh <domain> <archive>  # restores (with a safety dump first)
```

## Deploying script updates

Update the scripts from the repo without touching instance state:

```bash
scp -r apps/* <server-alias>:~/apps/          # required, simple
# or:  ./apps/deploy.sh <server-alias>        # optional convenience (never --delete, excludes instance state)
```

`sites.d/*.conf`, `server.conf`, and per-site nginx configs are server-owned and are never overwritten.
