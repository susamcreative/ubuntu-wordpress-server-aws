# Ubuntu WordPress Server

Production-ready WordPress hosting on Ubuntu 24.04 LTS with Nginx, PHP 8.4, MariaDB 11.8, and Redis.

This repository provides optimized configurations for nginx (with SSL/TLS), oh-my-zsh terminal customization, and automated backup scripts for WordPress.

The documentation is platform-agnostic and works with any VPS provider (Hetzner, DigitalOcean, Vultr, AWS, etc.).

## Documentation

- [Initial Setup](docs/Initial%20Setup.md) - Server creation and initial configuration
- [Install LEMP Stack](docs/Install%20LEMP.md) - PHP, MariaDB, Nginx, Redis installation
- [WordPress](docs/Wordpress.md) - First WordPress site setup
- [SSL Let's Encrypt](docs/SSL%20Let's%20Encrypt.md) - Free SSL certificates
- [Add Another Site](docs/Add%20Another%20Site.md) - Quick workflow for additional sites
- [Migrate Existing Site](docs/Migrate%20Existing%20Site.md) - Move WordPress from another server
- [Automation](docs/Automation.md) - Automated backups and maintenance

## Stack Versions

- Ubuntu 24.04 LTS
- PHP 8.4
- MariaDB 11.8 LTS
- Nginx Mainline (1.29+)
- Redis 7.0+
- Certbot (APT-based)