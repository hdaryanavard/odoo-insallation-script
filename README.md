# Installation Script for Odoo Open Source

Bash script to install **Odoo 19.0** on **Ubuntu 26.04 LTS (Resolute Raccoon)**.

It generates an Odoo config under `/etc/` with a configurable `http_port`, so it
can be safely used on a multi-Odoo server: run it again with a different
`OE_USER` / `OE_PORT` / `OE_CONFIG` and each instance gets its own service,
config, log and Python virtualenv.

> **Ubuntu 26.04 note:** the distro enforces [PEP 668](https://peps.python.org/pep-0668/)
> (externally-managed-environment), so system-wide `pip install` is refused. This
> script installs every Python dependency into a dedicated **virtualenv**
> (`OE_VENV`, `/opt/<user>/venv` by default) owned by the service user.

## Installing Nginx and workers

If you set `INSTALL_NGINX` to `True`, the script writes an Nginx reverse-proxy
config and sets `proxy_mode = True` in the Odoo config. It also configures
`OE_WORKERS` workers. **`workers` must be `> 0`** for the gevent port
(`gevent_port`, used by websockets / longpolling) to listen — otherwise you will
get connection-loss issues. See the
[Odoo 19 deployment guide](https://www.odoo.com/documentation/19.0/administration/on_premise/deploy.html).

Since Odoo 16 the longpolling endpoint was renamed: Nginx now proxies
**`/websocket`** (not `/longpolling`) with the HTTP `Upgrade` / `Connection: upgrade`
headers, which this script sets up for you.

## wkhtmltopdf caveat (important on 26.04)

Odoo's PDF reports need the **patched-Qt** wkhtmltopdf (for report headers,
footers and page breaks). Ubuntu 26.04 has **no `wkhtmltopdf` package at all** —
it was removed with the Debian 13 base. So the script installs the same build
Odoo S.A.'s own docker image uses: the patched-Qt **`wkhtmltox` `0.12.6.1-3`
jammy `.deb`** (`WKHTMLTOX_VERSION`), cross-release, with its SHA1 pinned and
`amd64`/`arm64` auto-detected. With `INSTALL_WKHTMLTOPDF=True` the script tries,
in order, and stops at the first that passes a `--version` + real-PDF check:

1. **`apt install ./wkhtmltox…jammy.deb`** — the pinned patched-Qt deb (deps
   auto-resolved; on 26.04 `libssl3`/`libpng16-16` come from the `t64` packages).
2. **Manual extract** — install the deps by their 26.04 names, then `dpkg -x` the
   verified deb into place and `ldconfig`.
3. **Generic static `0.12.4` tarball** (amd64) — old but patched-Qt; a warning
   suggests retrying step 1 later.

If all three fail it prints manual instructions and continues — Odoo runs fine
without PDF export.

## Running multiple Odoo instances on one server

To install a second parallel instance, re-run the script with **all** of these
set to values that differ from the first instance, so nothing is clobbered:

- `OE_USER` — the systemd unit, home, virtualenv, log dir and PostgreSQL role are all derived from it.
- `OE_CONFIG` — the `/etc/<config>.conf` file and the Nginx upstream names.
- `OE_PORT` **and** `LONGPOLLING_PORT` — both must be unique per instance (each Odoo binds its own http and gevent ports).
- `WEBSITE_NAME` — the Nginx site file, its symlink and the per-site logs.

The script is written for fresh installs / new instances; re-running it over an
existing instance with the **same** `OE_USER` is not idempotent (the source clone
and the system user already exist).

## Installation procedure

##### 1. Download the script:
```
wget https://raw.githubusercontent.com/hdaryanavard/odoo-insallation-script/19.0/install_odoo_ubuntu.sh
```
##### 2. Modify the parameters as you wish.
The most used settings:<br/>
```OE_USER``` the system user Odoo runs as (also the PostgreSQL role and, by default, the systemd service name).<br/>
```OE_VERSION``` the Odoo version to install, for example ```19.0```.<br/>
```OE_PORT``` the HTTP port Odoo runs on, for example 8069 (written as ```http_port```).<br/>
```OE_WORKERS``` number of worker processes. Must be ```> 0``` for the gevent/websocket port to listen. Rule of thumb: ```(CPU cores * 2) + 1```.<br/>
```OE_VENV``` the Python virtualenv path (defaults to ```/opt/<user>/venv```); all Python deps install here (PEP 668).<br/>
```LONGPOLLING_PORT``` the gevent port (Odoo key ```gevent_port```), used for websockets/longpolling.<br/>
```IS_ENTERPRISE``` set to ```True``` to install Odoo Enterprise on top (requires Odoo partner access to the enterprise repo), ```False``` for Community.<br/>
```INSTALL_WKHTMLTOPDF``` set to ```True``` to install wkhtmltopdf (see the caveat above), ```False``` to skip.<br/>
```GENERATE_RANDOM_PASSWORD``` if ```True``` (default) a random master password is generated; if ```False``` the value in ```OE_SUPERADMIN``` is used.<br/>
```OE_SUPERADMIN``` the master password for this Odoo installation (used only when ```GENERATE_RANDOM_PASSWORD``` is ```False```).<br/>
```INSTALL_NGINX``` set to ```False``` if you don't want the Nginx reverse proxy (default ```True```).<br/>
```WEBSITE_NAME``` the domain used for the Nginx ```server_name``` and the SSL certificate.<br/>
```ENABLE_SSL``` set to ```True``` to install [certbot](https://certbot.eff.org/) and enable HTTPS with a free Let's Encrypt certificate. Requires ```INSTALL_NGINX=True``` and a real ```WEBSITE_NAME``` (not ```example.com```).<br/>
```ADMIN_EMAIL``` email used to register the Let's Encrypt certificate.<br/>
```SSH_HARDENING``` set to ```True``` to disable SSH password login. **Danger: this locks you out unless a working SSH key is already in ```~/.ssh/authorized_keys```.** Set to ```False``` if you log in with a password.<br/>
  _By enabling SSL through Let's Encrypt you agree to their [terms](https://letsencrypt.org/repository/)._ <br/>

#### 3. Make the script executable
```
sudo chmod +x install_odoo_ubuntu.sh
```
##### 4. Execute the script:
```
sudo ./install_odoo_ubuntu.sh
```

Once finished, Odoo runs as a systemd service (`sudo systemctl status <OE_USER>`),
served through Nginx on ports 80/443 (or directly on `OE_PORT` if Nginx is
disabled). Right-to-left languages (Persian `fa`, Arabic `ar`) work because
`rtlcss` is installed globally for asset compilation.

For help with hosting, upgrading to Odoo Enterprise, or changing your domain,
contact me at hdaryanavard@gmail.com
