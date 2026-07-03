# Changelog

All notable changes to this installation script are documented here.

This repository follows Odoo's one-branch-per-version model: each version line
(`17.0`, `18.0`, `19.0`, …) is maintained independently. This file lives on the
`19.0` branch and tracks the Odoo 19.0 / Ubuntu 26.04 line.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [19.0] - 2026-07-03

Migrates the installer from Odoo 18 / Ubuntu 24.04 to **Odoo 19.0 / Ubuntu 26.04
LTS (Resolute Raccoon)**. The distro's Python 3.14 and PostgreSQL 18 are used
as-is (no Python is compiled from source).

### Added
- Per-instance Python virtualenv `OE_VENV` (`/opt/<user>/venv`), required by
  PEP 668 — Ubuntu ≥ 23.04 refuses system-wide `pip install`.
- `OE_WORKERS` variable → `workers` in the Odoo config (must be `> 0` for the
  gevent/websocket port to listen).
- `gevent_port` in the Odoo config (replaces the old longpolling port key).
- `WKHTMLTOX_VERSION` variable plus a patched-Qt wkhtmltopdf install with a
  SHA1-pinned, architecture-aware (amd64/arm64) fallback chain and a
  "with patched qt" + real-PDF verification gate.
- `SSH_HARDENING` toggle with a loud lock-out warning.
- README sections documenting `OE_VENV`, `OE_WORKERS`, the websocket change, the
  wkhtmltopdf caveat, and running multiple instances on one host.

### Changed
- All Python dependencies (including enterprise extras) install into the venv;
  systemd `ExecStart` runs the venv's `python3`.
- wkhtmltopdf: install the patched-Qt `wkhtmltox 0.12.6.1-3` jammy `.deb`
  cross-release (the exact build `odoo/docker:19.0` uses), because Ubuntu 26.04
  ships no `wkhtmltopdf` package. Fallbacks: manual `dpkg -x` + `ldconfig` with
  26.04-named runtime deps, then a SHA1-pinned generic `0.12.4` tarball; the
  install never aborts if PDF support cannot be provisioned.
- Nginx proxies `/websocket` (not `/longpolling`) with `Upgrade`/`Connection:
  upgrade` headers; the site is emitted HTTP-only and `certbot --nginx` upgrades
  it to TLS in place; `upstream` blocks are keyed to `OE_CONFIG` and logs are
  written per site.
- systemd unit: `After=network.target postgresql.service`, `Restart=on-failure`,
  `SyslogIdentifier=<config>`, mode `644`; final status check uses `--no-pager`.
- SSH hardening writes a `00-odoo-hardening.conf` drop-in (overrides cloud-init),
  validates with `sshd -t` before restarting `ssh`, and self-reverts on failure.
- Node.js and npm come from the Ubuntu 26.04 repositories (NodeSource dropped);
  `rtlcss` is still installed globally for RTL (fa/ar) assets.
- Enterprise extras trimmed to `pdfminer.six dbfread firebase_admin`
  (num2words, ofxparse, pyOpenSSL and psycopg2 are already in `requirements.txt`).
- Config file owned `root:<user>`, mode `640`; log directory mode `750`.
- Documentation links point to `/documentation/19.0/`; the README `wget` URL
  points to the `19.0` branch.

### Fixed
- The Odoo config always writes `http_port` (the old `[ $OE_VERSION > "11.0" ]`
  test was a shell redirect that created a file named `11.0`).
- Enterprise `addons_path` again includes `<home>/custom/addons`.
- `proxy_mode` is written before the service starts, so it is actually applied.
- Removed the stray `mv ~/odoo /etc/nginx/sites-available/` line.
- SSH restart targets `ssh.service` (Ubuntu 24.04+), not `sshd`.
- `certbot` removal and `ufw enable` run non-interactively.

### Security
- The service user is no longer added to the `sudo` group.
- With Nginx installed, UFW no longer exposes 8069/8072 publicly; SSH (22) is
  allowed before `ufw --force enable` to avoid self-lock-out.
- `ChallengeResponseAuthentication` replaced by `KbdInteractiveAuthentication`.
- wkhtmltopdf downloads are SHA1-verified before installation.

### Removed
- All global `sudo pip3 install …` calls.
- NodeSource `setup_20.x`, `node-less`, global `less`, `node-gyp`, and the
  `nodejs → node` symlink.
- The dead `ebaysdk` enterprise dependency.
- Pruned apt packages: `gdebi`, `node-less`, `libatlas-base-dev`, `libblas-dev`,
  `python3-cffi`, `python3-wheel`, `python3-setuptools`.
