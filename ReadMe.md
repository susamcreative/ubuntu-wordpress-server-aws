# Ubuntu WordPress Server

Production-ready WordPress hosting on Ubuntu 24.04 LTS with Nginx, PHP 8.4, MariaDB 11.8, and Redis.

This repository provides optimized configurations for nginx (with SSL/TLS), oh-my-zsh terminal customization, and automated backup scripts for WordPress.

The documentation is platform-agnostic and works with any VPS provider (Hetzner, DigitalOcean, Vultr, AWS, etc.).

## Documentation

### Core Setup (Follow in Order)

1. [Initial Setup](docs/Initial%20Setup.md) - Server creation and initial configuration
2. [Install LEMP Stack](docs/Install%20LEMP.md) - PHP, MariaDB, Nginx, Redis installation
3. [WordPress](docs/Wordpress.md) - First WordPress site setup
4. [SSL Let's Encrypt](docs/SSL%20Let's%20Encrypt.md) - Free SSL certificates
5. [Automation](docs/Automation.md) - Automated backups and maintenance

### Additional Workflows

- [Add Another Site](docs/Add%20Another%20Site.md) - Quick workflow for additional sites
- [Migrate Existing Site](docs/Migrate%20Existing%20Site.md) - Move WordPress from another server

## Automation Scripts

For faster setup with validation and error handling:

- **`apps/add-site.sh`** - Automated WordPress site creation
  - Validates prerequisites and DNS
  - Creates database, downloads WordPress
  - Configures nginx and obtains SSL
  - Sets up automated backups
  - Resumable if interrupted

- **`apps/restore-backup.sh`** - Restore WordPress from backup
  - Lists all sites and their backups
  - Validates backup integrity
  - Restores database and/or files
  - Creates safety backups before restoration

The scripts are optional - all manual steps are documented for learning and customization.

## Stack Versions

- Ubuntu 24.04 LTS
- PHP 8.4
- MariaDB 11.8 LTS
- Nginx Mainline (1.29+)
- Redis 7.0+
- Certbot (APT-based)