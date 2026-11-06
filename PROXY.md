# An HTTPS proxy for WtF

How to put WtF behind nginx on Ubuntu 26.04 LTS, with a free certificate from Let's Encrypt. nginx takes the HTTPS connections from browsers and the apps, and passes the requests on to `wtfd` as plain HTTP.

```text
browser, app, wtf  --HTTPS-->  nginx (ports 80 and 443)  --HTTP-->  wtfd (port 8080)
```

`wtfd` speaks plain HTTP only, and the web app needs HTTPS in practice: browsers keep the secure session cookie, and allow the camera, only over HTTPS. For what `wtfd` expects of a proxy, see "Deployment assumptions" in [WTFD.md](WTFD.md).

Below, `wtf.example.org` stands for your server's name: replace it everywhere.

## Before you start

- **A machine with Ubuntu 26.04 LTS** and `sudo`. It can be the machine `wtfd` runs on, or another one that can reach it (for example, `wtfd` as a Windows service on another machine on the same network).
- **A DNS name for it,** `wtf.example.org`, whose A record (and AAAA record, if it has IPv6) points at the machine's public address.
- **Ports 80 and 443 open to the internet,** forwarded by your router if the machine is behind one. Let's Encrypt checks that you control the name by fetching a file over port 80; the renewals every two months do the same, so port 80 stays open. A machine that the internet can't reach needs the DNS challenge instead; see [A server only on your own network](#a-server-only-on-your-own-network).

## 1. Install nginx and Certbot

```sh
sudo apt update
sudo apt install nginx certbot
```

Ubuntu starts nginx at once and at every boot. If the firewall, `ufw`, is on (`sudo ufw status`), open both ports:

```sh
sudo ufw allow 'Nginx Full'
```

## 2. Serve the name over HTTP

Make the folder Let's Encrypt's checks are served from:

```sh
sudo mkdir -p /var/www/letsencrypt
```

Ubuntu's own site, `default`, stays: it answers requests that name no site of nginx's, such as those by IP address, with nginx's welcome page.

Create `/etc/nginx/sites-available/wtf` with this, for now only port 80:

```nginx
# WtF: port 80 answers Let's Encrypt's checks and sends everything else to HTTPS.
server {
    listen 80;
    listen [::]:80;
    server_name wtf.example.org;

    location /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}
```

Turn it on, check it, and load it:

```sh
sudo ln -s /etc/nginx/sites-available/wtf /etc/nginx/sites-enabled/wtf
sudo nginx -t
sudo systemctl reload nginx
```

## 3. Get the certificate

```sh
sudo certbot certonly --webroot -w /var/www/letsencrypt -d wtf.example.org \
    --deploy-hook 'systemctl reload nginx'
```

The first time, Certbot asks for an email address and for you to agree to Let's Encrypt's terms. The certificate and its key end up in `/etc/letsencrypt/live/wtf.example.org/`.

**Renewal** is done by the package's timer, `certbot.timer`, twice a day; Certbot renews only a certificate that is close to expiring, and the deploy hook, which Certbot remembers, makes nginx load the new one. The package doesn't always turn the timer on, and its cron job (`/etc/cron.d/certbot`) does nothing on a system with systemd, leaving it to the timer, so turn it on, now and at every boot:

```sh
sudo systemctl enable --now certbot.timer
systemctl list-timers certbot.timer
```

The second shows when it runs next, like this:

```text
NEXT                        LEFT LAST                         PASSED UNIT          ACTIVATES
Sat 2026-11-07 06:54:58 CET   8h Sat 2026-10-24 13:57:05 CEST      - certbot.timer certbot.service

1 timers listed.
```

"0 timers listed" means it is off. Then try a renewal without changing anything:

```sh
sudo certbot renew --dry-run
```

Let's Encrypt no longer emails a warning before a certificate expires, so the dry run is worth doing once now.

## 4. Pass HTTPS on to wtfd

Add the HTTPS server to `/etc/nginx/sites-available/wtf`, below the one for port 80:

```nginx
# WtF over HTTPS, passed on to wtfd.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name wtf.example.org;

    ssl_certificate     /etc/letsencrypt/live/wtf.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/wtf.example.org/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # The largest file wtfd takes (--max-attachment-size, 100 MiB by
    # default), and 1 MiB more for the rest of the upload.
    client_max_body_size 101m;

    location / {
        # wtfd on this machine; for wtfd on another one, its address,
        # such as http://192.168.10.20:8080.
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        # wtfd compares the browser's Origin with the Host it gets, to refuse
        # changes sent from other sites, so Host must be the name people use.
        proxy_set_header Host $host;
        # The client's address, for the logs and the list of sessions.
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        # Tells wtfd the request came over HTTPS, so the session cookie is
        # marked Secure.
        proxy_set_header X-Forwarded-Proto $scheme;

        # Uploads go straight through to wtfd, rather than first into a
        # temporary file here.
        proxy_request_buffering off;
    }
}
```

Then check it and load it:

```sh
sudo nginx -t
sudo systemctl reload nginx
```

`proxy_pass` names `wtfd` by its address, not by a name, so nginx doesn't depend on name lookups to start.

**HTTPS by IP address:** Ubuntu's `default` site answers only on port 80. Over HTTPS, a request that names no site (`https://` and the machine's address) goes to the first HTTPS site instead, WtF's, with a certificate warning. To refuse such connections rather than show WtF, add this to the `default` site (`/etc/nginx/sites-available/default`), and reload nginx:

```nginx
# HTTPS for names nginx has no site for: refused, as there is no certificate for them.
server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    ssl_reject_handshake on;
}
```

The browser then says the connection failed, while plain HTTP by IP address still shows the welcome page.

## 5. Tell wtfd about the proxy

`wtfd` needs to believe the client's address that nginx passes on, which it does only for the proxies named in `trusted-proxies`. Its config file is `/etc/wtf/wtfd.conf` on Linux and `%ProgramData%\WtF\wtfd.conf` on Windows (see "Configuration" in [WTFD.md](WTFD.md)).

**wtfd on the same machine:** it listens on this machine only, and the proxy reaches it as `127.0.0.1`:

```text
listen = 127.0.0.1:8080
trusted-proxies = 127.0.0.1
```

**wtfd on another machine:** it listens on the network, and believes only the proxy's address (here `192.168.10.5`):

```text
listen = 0.0.0.0:8080
trusted-proxies = 192.168.10.5
```

Let only the proxy reach port 8080 there, so that nobody goes around the proxy, and around HTTPS. On Windows, limit the rule `wtfd install` added:

```powershell
netsh advfirewall firewall set rule name="WtF server" new remoteip=192.168.10.5
```

Between the proxy and `wtfd`, the requests, passwords included, travel unencrypted, so keep the two on a network you trust.

Restart `wtfd` to read the file: on Windows, `Restart-Service wtfd`, as an administrator.

## 6. Check it

```sh
curl https://wtf.example.org/api/health
```

answers `wtfd`'s health, with `"status":"ok"`. Then open `https://wtf.example.org/` in a browser and log in. Under **Account**, your session should show your own address, not the proxy's. The apps and `wtf` use `https://wtf.example.org` as the server's address.

**Once all of that works,** you can tell browsers to use only HTTPS for this name from then on (HSTS), by adding this to the HTTPS server, after `ssl_session_timeout`:

```nginx
    add_header Strict-Transport-Security "max-age=31536000" always;
```

Browsers then refuse plain HTTP to `wtf.example.org` for a year, even if HTTPS stops working, so add it only when you're sure you'll keep HTTPS.

## A server only on your own network

When the internet can't reach the machine, Let's Encrypt can't fetch the file over port 80. It can check a DNS record instead, if your DNS provider has an API that Certbot has a plugin for (`apt search python3-certbot-dns` lists them). For example, with Cloudflare:

```sh
sudo apt install python3-certbot-dns-cloudflare
sudo certbot certonly --dns-cloudflare --dns-cloudflare-credentials /root/cloudflare.ini \
    -d wtf.example.org --deploy-hook 'systemctl reload nginx'
```

The plugin's documentation says what goes in the credentials file (mode 600). The name must still be in public DNS, but it may point at a private address, such as `192.168.10.5`. The port 80 server in step 2 then only sends people to HTTPS.

## When something is wrong

| What you see | Why, and what to do |
|--------------|---------------------|
| `502 Bad Gateway` from nginx | nginx can't reach `wtfd`: it isn't running, or listens on another address or port than `proxy_pass` names, or a firewall is in the way. `curl http://127.0.0.1:8080/api/health` on the `wtfd` machine shows whether it answers. |
| `413 Request Entity Too Large` from nginx, on uploads | `client_max_body_size` is smaller than the file. Keep it 1 MiB above `wtfd`'s `max-attachment-size`. |
| `403`, "Cross-site request", when logging in or saving | The `Host` that reaches `wtfd` isn't the name in the browser. Check `proxy_set_header Host $host;`. On a port other than 443, use `$http_host`, which keeps the port. |
| The sessions under Account show the proxy's address | `trusted-proxies` in `wtfd.conf` doesn't name the address the proxy connects from, or `wtfd` hasn't been restarted since. |
| The browser refuses the connection: `SSL_ERROR_UNRECOGNIZED_NAME_ALERT` (Firefox) or `ERR_SSL_UNRECOGNIZED_NAME_ALERT` (Chrome) | nginx has no HTTPS site for the name in the address, and the default HTTPS site refuses it, as intended for addresses by IP. If it was the server's name, it isn't the `server_name` of WtF's HTTPS site: check for `wtf.example.org` left unreplaced, or a typo. `sudo nginx -T \| grep server_name` lists the names nginx has. |
| Certbot fails with "unauthorized" or a timeout | Let's Encrypt couldn't fetch the check over port 80: the DNS name doesn't point at this machine, or port 80 isn't open or forwarded to it. |
