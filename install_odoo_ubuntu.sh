#!/bin/bash

################################################################################
# Script for installing Odoo 19.0 on Ubuntu 26.04 LTS (Resolute Raccoon)
# Author: Hassan Daryanavard
#-------------------------------------------------------------------------------
# This script installs Odoo 19.0 on an Ubuntu 26.04 server. Several Odoo
# instances can live on one host: run the script again with a different
# OE_USER / OE_PORT / OE_CONFIG (and OE_HOME derives the venv per-instance).
#
# Ubuntu >= 23.04 enforces PEP 668 (externally-managed-environment), so
# system-wide "pip install" is refused. Every Python dependency is therefore
# installed into a dedicated virtualenv ($OE_VENV) owned by the service user.
#-------------------------------------------------------------------------------
# Docs: https://www.odoo.com/documentation/19.0/administration/on_premise.html
#
# Usage:
#   sudo nano install_odoo_ubuntu.sh      # paste this file, edit the vars below
#   sudo chmod +x install_odoo_ubuntu.sh
#   sudo ./install_odoo_ubuntu.sh
#
# Optional certbot auto-renew:
#   crontab -e
#   43 6 * * * certbot renew --post-hook "systemctl reload nginx"
################################################################################

OE_USER="odoo"
OE_HOME="/opt/$OE_USER"
OE_HOME_EXT="/opt/$OE_USER/${OE_USER}-server"
# Per-instance Python virtualenv (derived from OE_HOME so a second instance
# with a different OE_USER gets its own venv automatically).
OE_VENV="$OE_HOME/venv"
# Set to True if you want to install wkhtmltopdf, False if you don't need it or
# already have it installed.
INSTALL_WKHTMLTOPDF="True"
# Patched-Qt wkhtmltopdf version from wkhtmltopdf/packaging. This is the exact
# build Odoo S.A.'s official docker image uses; installed cross-release (jammy
# deb) because Ubuntu 26.04 has no wkhtmltopdf package at all.
WKHTMLTOX_VERSION="0.12.6.1-3"
# The default port this Odoo instance runs on (http_port in the .conf).
OE_PORT="8069"
# The Odoo version to install: 19.0, 18.0, 17.0 ... or 'master'.
OE_VERSION="19.0"
# Number of Odoo worker processes. workers > 0 is REQUIRED for the gevent
# (websocket / longpolling) port to listen. Rule of thumb: (CPU cores * 2) + 1.
OE_WORKERS="2"
# Set this to True to install the Odoo Enterprise version (needs partner access).
IS_ENTERPRISE="False"
# Set this to True to install and configure Nginx as a reverse proxy.
INSTALL_NGINX="True"
# The master password. If GENERATE_RANDOM_PASSWORD is True a random one is
# generated and this value is ignored.
OE_SUPERADMIN="admin"
# Set to True to generate a random master password, False to use OE_SUPERADMIN.
GENERATE_RANDOM_PASSWORD="True"
OE_CONFIG="${OE_USER}-server"
# The website name used for the Nginx server_name / SSL certificate.
WEBSITE_NAME="example.com"
# The gevent port (Odoo config key: gevent_port). Serves websockets/longpolling.
LONGPOLLING_PORT="8072"
# Set to True to install certbot and enable SSL, False to stay on http.
ENABLE_SSL="True"
# Email used to register the Let's Encrypt certificate.
ADMIN_EMAIL="odoo@example.com"
# Set to True to harden SSH (disables password login).
# !!! DANGER: with SSH_HARDENING=True, PasswordAuthentication no + UsePAM no
# !!! will LOCK YOU OUT unless a working key is already in ~/.ssh/authorized_keys.
# !!! Set this to False if you log in with a password.
SSH_HARDENING="True"

#--------------------------------------------------
# Harden SSH (optional)
#--------------------------------------------------
if [[ "$SSH_HARDENING" = "True" ]]; then
  echo -e "\n============== Hardening SSH (password login will be DISABLED) ======="
  echo "WARNING: make sure your SSH key already works, or you will be locked out."
  # Write the hardening to a drop-in that sorts BEFORE cloud-init's
  # 50-cloud-init.conf. sshd is first-match-wins and includes the drop-in dir at
  # the top of sshd_config, so a lower-numbered file overrides cloud-init's
  # 'PasswordAuthentication yes' (editing the main file alone is a no-op on most
  # cloud images). ChallengeResponseAuthentication is renamed to
  # KbdInteractiveAuthentication on Ubuntu 24.04+.
  sudo install -d -m 0755 /etc/ssh/sshd_config.d
  sudo tee /etc/ssh/sshd_config.d/00-odoo-hardening.conf >/dev/null <<'EOF'
# Managed by the Odoo install script — key-based login only.
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
EOF
  # Validate before restarting so a broken config can never lock you out.
  if sudo sshd -t; then
    # The daemon is 'ssh.service' (socket-activated) on Ubuntu 24.04+; 'sshd' fails.
    sudo systemctl restart ssh
  else
    echo "ERROR: sshd config test failed — reverting and NOT restarting SSH."
    sudo rm -f /etc/ssh/sshd_config.d/00-odoo-hardening.conf
  fi
else
  echo -e "\n============== SSH hardening skipped by user choice =================="
fi

#--------------------------------------------------
# Update Server
#--------------------------------------------------
echo -e "\n============== Update Server ======================="
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y

#--------------------------------------------------
# Set up the timezone
#--------------------------------------------------
sudo timedatectl set-timezone Asia/Dubai
timedatectl

#--------------------------------------------------
# Install PostgreSQL Server (Ubuntu 26.04 ships PostgreSQL 18)
#--------------------------------------------------
echo -e "\n============== Installing PostgreSQL Server ========="
sudo apt install -y postgresql
sudo systemctl enable --now postgresql

echo -e "\n=============== Creating the Odoo PostgreSQL user ==="
sudo su - postgres -c "createuser -s $OE_USER" 2>/dev/null || true

#--------------------------------------------------
# Install system dependencies
#--------------------------------------------------
echo -e "\n=================== Installing system dependencies =="
sudo apt install -y git wget build-essential \
  python3 python3-dev python3-venv python3-pip \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev libssl-dev libpq-dev \
  libjpeg-dev zlib1g-dev libffi-dev fontconfig

#--------------------------------------------------
# Install Node.js, npm and rtlcss (required for RTL languages: fa / ar)
#--------------------------------------------------
echo -e "\n=========== Installing Node.js, npm and rtlcss ======"
# Node 20 is EOL (April 2026); use Ubuntu 26.04's own repo packages.
sudo apt install -y nodejs npm
sudo npm install -g rtlcss

#--------------------------------------------------
# Install wkhtmltopdf (optional)
#--------------------------------------------------
# Verification gate: the binary must exist, report a PATCHED Qt (required for
# QWeb report headers / footers / page-breaks) and actually render a PDF.
wkhtmltopdf_ok() {
  command -v wkhtmltopdf >/dev/null 2>&1 || return 1
  wkhtmltopdf --version 2>/dev/null | grep -qi "with patched qt" || return 1
  printf '<html><body>wkhtmltopdf smoke test</body></html>' > /tmp/wk_smoke.html
  if wkhtmltopdf /tmp/wk_smoke.html /tmp/wk_smoke.pdf >/dev/null 2>&1; then
    rm -f /tmp/wk_smoke.html /tmp/wk_smoke.pdf
    return 0
  fi
  rm -f /tmp/wk_smoke.html /tmp/wk_smoke.pdf
  return 1
}

# Symlink the /usr/local/bin binaries into /usr/bin (only if they exist, so we
# never leave a dangling link). Odoo also finds /usr/local/bin on PATH.
wk_symlink() {
  [[ -x /usr/local/bin/wkhtmltopdf ]]   && sudo ln -sf /usr/local/bin/wkhtmltopdf   /usr/bin/wkhtmltopdf
  [[ -x /usr/local/bin/wkhtmltoimage ]] && sudo ln -sf /usr/local/bin/wkhtmltoimage /usr/bin/wkhtmltoimage
  return 0
}

if [[ "$INSTALL_WKHTMLTOPDF" = "True" ]]; then
  echo -e "\n================== Installing wkhtmltopdf ==========="
  # Fonts installed BEFORE the deb so apt dependency resolution stays clean.
  sudo apt install -y xfonts-75dpi xfonts-encodings xfonts-utils xfonts-base fontconfig

  WK_ARCH="$(dpkg --print-architecture)"
  case "$WK_ARCH" in
    amd64) WK_SHA1="967390a759707337b46d1c02452e2bb6b2dc6d59" ;;
    arm64) WK_SHA1="90f6e69896d51ef77339d3f3a20f8582bdf496cc" ;;
    *)     WK_SHA1="" ;;
  esac
  WK_DEB="wkhtmltox_${WKHTMLTOX_VERSION}.jammy_${WK_ARCH}.deb"
  WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/${WK_DEB}"
  WK_TMP="/tmp/${WK_DEB}"

  # Download the pinned deb once and verify its SHA1 (shared by steps 1 and 2).
  WK_HAVE_DEB=0
  if [[ -n "$WK_SHA1" ]]; then
    rm -f "$WK_TMP"
    if wget -q -O "$WK_TMP" "$WK_URL" && echo "${WK_SHA1}  ${WK_TMP}" | sha1sum -c - >/dev/null 2>&1; then
      WK_HAVE_DEB=1
    else
      echo "WARNING: could not download or verify ${WK_DEB} (SHA1 mismatch or network)."
      rm -f "$WK_TMP"
    fi
  else
    echo "WARNING: no pinned wkhtmltopdf deb for architecture '${WK_ARCH}'."
  fi

  # --- Step 1: patched-Qt jammy deb, cross-release (what odoo/docker:19.0 does) ---
  if [[ "$WK_HAVE_DEB" = "1" ]]; then
    echo "Step 1: installing patched-Qt wkhtmltopdf ${WKHTMLTOX_VERSION} (jammy/${WK_ARCH})..."
    # 'apt install ./file.deb' resolves the deb's deps; on 26.04 libssl3 and
    # libpng16-16 are satisfied by the t64 packages' versioned Provides. The deb
    # Provides/Conflicts/Replaces 'wkhtmltopdf'. Never bare 'dpkg -i'.
    sudo apt-get install -y --no-install-recommends "$WK_TMP" || true
    wk_symlink
  fi

  # --- Step 2: manual extract if apt could not resolve the deps on resolute ---
  if [[ "$WK_HAVE_DEB" = "1" ]] && ! wkhtmltopdf_ok; then
    echo "Step 2: extracting the verified deb manually with its 26.04 runtime deps..."
    # Install deps one at a time so a single unavailable name (e.g. a future
    # rename) can't abort the whole set; most are already on a base image.
    for pkg in libssl3t64 libpng16-16t64 libjpeg-turbo8 libfreetype6 \
               libx11-6 libxcb1 libxext6 libxrender1 xfonts-75dpi xfonts-base \
               fontconfig zlib1g ca-certificates; do
      sudo apt install -y "$pkg" || echo "  note: '$pkg' unavailable on this release (skipped)."
    done
    # dpkg -x bypasses maintainer scripts, so ldconfig must index the shipped
    # /usr/local/lib/libwkhtmltox.so that the CLI links against.
    sudo dpkg -x "$WK_TMP" /
    sudo ldconfig
    wk_symlink
  fi
  rm -f "$WK_TMP"

  # --- Step 3: last resort — generic static 0.12.4 tarball (amd64 only) ---
  if ! wkhtmltopdf_ok && [[ "$WK_ARCH" = "amd64" ]]; then
    echo "Step 3: falling back to the generic static wkhtmltox 0.12.4 tarball (OLD -- retry step 1 later)."
    WK_TARBALL="wkhtmltox-0.12.4_linux-generic-amd64.tar.xz"
    WK_TAR_SHA1="3f923f425d345940089e44c1466f6408b9619562"
    WK_TAR_URL="https://github.com/wkhtmltopdf/wkhtmltopdf/releases/download/0.12.4/${WK_TARBALL}"
    WK_TAR_TMP="/tmp/${WK_TARBALL}"
    rm -rf /tmp/wkhtmltox
    # SHA1-pinned like the deb path — never install an unverified binary.
    if wget -q -O "$WK_TAR_TMP" "$WK_TAR_URL" && echo "${WK_TAR_SHA1}  ${WK_TAR_TMP}" | sha1sum -c - >/dev/null 2>&1; then
      tar xf "$WK_TAR_TMP" -C /tmp
      sudo cp -a /tmp/wkhtmltox/bin/. /usr/local/bin/
      [[ -d /tmp/wkhtmltox/lib ]] && sudo cp -a /tmp/wkhtmltox/lib/. /usr/local/lib/
      sudo ldconfig
      wk_symlink
    else
      echo "WARNING: 0.12.4 tarball download or SHA1 verification failed; skipping."
    fi
    rm -f "$WK_TAR_TMP"
    rm -rf /tmp/wkhtmltox
  fi

  # --- Mandatory verification gate ---
  if wkhtmltopdf_ok; then
    echo "wkhtmltopdf OK: $(wkhtmltopdf --version 2>/dev/null | head -n1)"
  else
    echo "WARNING: no working patched wkhtmltopdf was installed. QWeb PDF reports"
    echo "         will not render. Odoo still runs fine without PDF export."
    if [[ -n "$WK_SHA1" ]]; then
      echo "         To fix manually once, run:"
      echo "           wget ${WK_URL}"
      echo "           sudo apt-get install -y --no-install-recommends ./${WK_DEB}"
    else
      echo "         No patched build is published for architecture '${WK_ARCH}'."
      echo "         See https://github.com/wkhtmltopdf/packaging/releases"
    fi
    echo "         Continuing the install."
  fi
else
  echo "wkhtmltopdf install skipped by user choice."
fi

#--------------------------------------------------
# Create the Odoo system user
#--------------------------------------------------
echo -e "\n============== Creating Odoo system user ============"
sudo adduser --system --quiet --shell=/bin/bash --home="$OE_HOME" --gecos 'ODOO' --group "$OE_USER"

echo -e "\n=========== Creating log directory =================="
sudo mkdir -p "/var/log/$OE_USER"
sudo chown -R "$OE_USER:$OE_USER" "/var/log/$OE_USER"
sudo chmod 750 "/var/log/$OE_USER"

#--------------------------------------------------
# Install Odoo from source
#--------------------------------------------------
echo -e "\n========== Installing Odoo server =================="
sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/odoo "$OE_HOME_EXT/"

#--------------------------------------------------
# Create the per-instance virtualenv and install requirements (PEP 668)
#--------------------------------------------------
echo -e "\n========== Creating Python virtualenv =============="
sudo -u "$OE_USER" python3 -m venv "$OE_VENV"
sudo -u "$OE_USER" "$OE_VENV/bin/pip" install --upgrade pip wheel setuptools
sudo -u "$OE_USER" "$OE_VENV/bin/pip" install -r "$OE_HOME_EXT/requirements.txt"

if [[ "$IS_ENTERPRISE" = "True" ]]; then
  echo -e "\n============= Installing Enterprise Python libraries ="
  # Enterprise extras installed into the venv. Only these three are genuinely
  # missing: num2words, ofxparse, pyOpenSSL and psycopg2 are already pinned in
  # Odoo's requirements.txt, and ebaysdk is a dead project — all dropped.
  sudo -u "$OE_USER" "$OE_VENV/bin/pip" install pdfminer.six dbfread firebase_admin

  sudo -u "$OE_USER" mkdir -p "$OE_HOME/enterprise/addons"
  GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
  while [[ "$GITHUB_RESPONSE" == *"Authentication"* ]]; do
    echo -e "\n============== WARNING ====================="
    echo "Your GitHub authentication failed! Please try again."
    printf 'To clone the Odoo Enterprise version you must be an official Odoo\npartner with access to https://github.com/odoo/enterprise.\n'
    echo "TIP: press Ctrl+C to stop this script."
    echo "============================================="
    GITHUB_RESPONSE=$(sudo git clone --depth 1 --branch "$OE_VERSION" https://github.com/odoo/enterprise "$OE_HOME/enterprise/addons" 2>&1)
  done
  echo -e "\n========= Enterprise code added under $OE_HOME/enterprise/addons ="
fi

echo -e "\n========= Creating custom module directory =========="
sudo -u "$OE_USER" mkdir -p "$OE_HOME/custom/addons"

echo -e "\n======= Setting permissions on the home folder ======"
sudo chown -R "$OE_USER:$OE_USER" "$OE_HOME/"

#--------------------------------------------------
# Create the Odoo server config file
#--------------------------------------------------
echo -e "\n========== Creating server config file =============="
if [[ "$GENERATE_RANDOM_PASSWORD" = "True" ]]; then
  echo "Generating a random master password..."
  OE_SUPERADMIN="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 20 | head -n 1)"
fi

if [[ "$IS_ENTERPRISE" = "True" ]]; then
  ADDONS_PATH="${OE_HOME}/enterprise/addons,${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
else
  ADDONS_PATH="${OE_HOME_EXT}/addons,${OE_HOME}/custom/addons"
fi

sudo tee "/etc/${OE_CONFIG}.conf" >/dev/null <<EOF
[options]
; This is the password that allows database operations:
admin_passwd = ${OE_SUPERADMIN}
http_port = ${OE_PORT}
gevent_port = ${LONGPOLLING_PORT}
logfile = /var/log/${OE_USER}/${OE_CONFIG}.log
; workers > 0 is required for the gevent_port (websocket) to listen.
workers = ${OE_WORKERS}
addons_path = ${ADDONS_PATH}
EOF

sudo chown "root:$OE_USER" "/etc/${OE_CONFIG}.conf"
sudo chmod 640 "/etc/${OE_CONFIG}.conf"

# When Nginx sits in front, trust its forwarded headers. Written BEFORE the
# service starts so the running instance actually applies it.
if [[ "$INSTALL_NGINX" = "True" ]]; then
  echo "proxy_mode = True" | sudo tee -a "/etc/${OE_CONFIG}.conf" >/dev/null
fi

#--------------------------------------------------
# Register Odoo as a systemd service
#--------------------------------------------------
echo -e "\n========== Creating Odoo systemd unit ==============="
sudo tee "/lib/systemd/system/${OE_USER}.service" >/dev/null <<EOF
[Unit]
Description=Odoo Open Source ERP and CRM
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_VENV}/bin/python3 ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
KillMode=mixed
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo chmod 644 "/lib/systemd/system/${OE_USER}.service"
sudo chown root: "/lib/systemd/system/${OE_USER}.service"

echo -e "\n======== Starting Odoo service ======================"
sudo systemctl daemon-reload
sudo systemctl enable --now "${OE_USER}.service"

#--------------------------------------------------
# Install and configure Nginx (optional)
#--------------------------------------------------
if [[ "$INSTALL_NGINX" = "True" ]]; then
  echo -e "\n======== Installing and configuring Nginx ==========="
  sudo apt install -y nginx
  sudo systemctl enable nginx

  # HTTP-only reverse proxy. certbot (below) upgrades it to HTTPS in place and
  # injects the 'listen 443 ssl' block + the 80->443 redirect — so we never ship
  # a config that references certs before they exist. Upstream names are keyed to
  # OE_CONFIG (not OE_USER) so parallel instances never collide.
  sudo tee "/etc/nginx/sites-available/$WEBSITE_NAME.conf" >/dev/null <<EOF
# Odoo server
upstream ${OE_CONFIG} {
  server 127.0.0.1:$OE_PORT;
}

upstream ${OE_CONFIG}-chat {
  server 127.0.0.1:$LONGPOLLING_PORT;
}

server {
  listen 80;
  server_name $WEBSITE_NAME;

  # Maximum accepted body size of a client request.
  client_max_body_size 500M;

  # Logs (per site so parallel instances don't interleave).
  access_log /var/log/nginx/$WEBSITE_NAME-access.log;
  error_log /var/log/nginx/$WEBSITE_NAME-error.log;

  keepalive_timeout 300;

  # Increase proxy buffers to handle large Odoo web requests.
  proxy_buffers 16 64k;
  proxy_buffer_size 128k;

  proxy_read_timeout 720s;
  proxy_connect_timeout 720s;
  proxy_send_timeout 720s;

  # Headers for Odoo proxy mode
  proxy_set_header Host \$host;
  proxy_set_header X-Forwarded-Host \$host;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$scheme;
  proxy_set_header X-Real-IP \$remote_addr;

  # Odoo backend
  location / {
    proxy_redirect off;
    proxy_pass http://${OE_CONFIG};
  }

  # Websocket / longpolling (Odoo 16+ renamed /longpolling to /websocket).
  location /websocket {
    proxy_pass http://${OE_CONFIG}-chat;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Host \$host;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP \$remote_addr;
  }

  # Cache static assets in memory to relieve the Odoo web interface.
  location ~* /web/static/ {
    proxy_cache_valid 200 90m;
    proxy_buffering on;
    expires 864000;
    proxy_pass http://${OE_CONFIG};
  }

  gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript;
  gzip on;

  client_body_in_file_only clean;
  client_body_buffer_size 32K;
  sendfile on;
  send_timeout 600s;
}
EOF

  sudo ln -sf "/etc/nginx/sites-available/$WEBSITE_NAME.conf" "/etc/nginx/sites-enabled/$WEBSITE_NAME.conf"
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo rm -f /etc/nginx/sites-available/default

  # Validate before reloading so a bad config never brings nginx down.
  if sudo nginx -t; then
    sudo systemctl reload nginx
  else
    echo "WARNING: 'nginx -t' failed; not reloading. Review the config above."
  fi
  echo "Done! Nginx config: /etc/nginx/sites-available/$WEBSITE_NAME.conf"
else
  echo -e "\n===== Nginx install skipped by user choice =========="
fi

#--------------------------------------------------
# Enable SSL with certbot (optional)
#--------------------------------------------------
if [[ "$INSTALL_NGINX" = "True" ]] && [[ "$ENABLE_SSL" = "True" ]] && [[ "$WEBSITE_NAME" != "example.com" ]] && [[ "$ADMIN_EMAIL" != "odoo@example.com" ]]; then
  sudo apt-get remove -y certbot
  sudo snap install core
  sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -sf /snap/bin/certbot /usr/bin/certbot
  # certbot --nginx reads the HTTP-only site above, obtains the cert, and injects
  # the 'listen 443 ssl' block + a 80->443 redirect into it.
  sudo certbot --nginx -d "$WEBSITE_NAME" --non-interactive --agree-tos -m "$ADMIN_EMAIL" --redirect
  sudo systemctl reload nginx
  echo -e "\n============ SSL/HTTPS is enabled! =================="
else
  echo -e "\n==== SSL/HTTPS not enabled (disabled, or WEBSITE_NAME/ADMIN_EMAIL left at defaults) ="
  echo "     If Nginx is installed, Odoo is served over plain HTTP on port 80."
fi

#--------------------------------------------------
# UFW Firewall
#--------------------------------------------------
echo -e "\n============== Configuring UFW firewall ============="
sudo apt install -y ufw

sudo ufw allow 22/tcp
if [[ "$INSTALL_NGINX" = "True" ]]; then
  # Nginx proxies Odoo; do NOT expose 8069/8072 publicly. 'Nginx Full' = 80+443.
  sudo ufw allow 'Nginx Full'
else
  # No reverse proxy: expose Odoo's http and gevent ports directly.
  sudo ufw allow "${OE_PORT}/tcp"
  sudo ufw allow "${LONGPOLLING_PORT}/tcp"
fi
sudo ufw --force enable

#--------------------------------------------------
# Summary
#--------------------------------------------------
echo -e "\n================== Status of Odoo service ==========="
sudo systemctl status "$OE_USER" --no-pager
echo -e "\n====================================================="
echo "Done! The Odoo server is up and running. Specifications:"
echo "Odoo version:        $OE_VERSION"
echo "HTTP port:           $OE_PORT"
echo "Gevent port:         $LONGPOLLING_PORT"
echo "Service user:        $OE_USER"
echo "PostgreSQL user:     $OE_USER"
echo "Code location:       $OE_HOME_EXT"
echo "Virtualenv:          $OE_VENV"
echo "Addons folder:       $OE_HOME/custom/addons"
echo "Config file:         /etc/${OE_CONFIG}.conf"
echo "Master password:     $OE_SUPERADMIN"
echo "Start service:       sudo systemctl start $OE_USER"
echo "Stop service:        sudo systemctl stop $OE_USER"
echo "Restart service:     sudo systemctl restart $OE_USER"
if [[ "$INSTALL_NGINX" = "True" ]]; then
  echo "Nginx config file:   /etc/nginx/sites-available/$WEBSITE_NAME.conf"
fi
echo "====================================================="
