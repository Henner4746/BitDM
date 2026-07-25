# BitDM — Website

Statische Seite, **live unter https://bitdm.net**. Zwei Dateien, keine
Build-Schritte, keine Abhängigkeiten, keine Fremdanfragen zur Laufzeit.

```
website/
├─ index.html      Startseite
├─ privacy.html    Datenschutzerklärung + Impressum   ← Play-Pflicht
├─ fonts/          Doto + Chivo Mono (SIL OFL, lokal eingebettet)
└─ README.md
```

## Warum sie so aussieht, wie sie aussieht

Die Gestaltung erbt die Nocturne-Welt aus App und Prototyp und tritt als
**Frontplatte eines Signalgeräts** auf — Anzeigen, eingebrannte Beschriftungen,
Statusleuchten. Der Richtungsvertrag steht im Kopfkommentar von `index.html`,
die durchgehenden Systemregeln in `../DESIGN.md`.

Eine Regel ist keine Gestaltungslaune, sondern Produktversprechen: **die Seite
lädt nichts von Dritten.** Keine Schriften von Google, keine Skripte, keine
Zählpixel. Ein Datenschutz-Messenger, dessen Website Besucher verfolgt,
widerlegt sich selbst. `performance.getEntriesByType('resource')` liefert auf
beiden Seiten eine leere Liste — das ist nachprüfbar, nicht behauptet.

## Vor dem Livegang zu erledigen

| # | Was | Warum |
|---|---|---|
| 1 | **Anschrift im Impressum ergänzen** (`privacy.html`, Abschnitt „Verantwortlicher") | Google Play verlangt eine vollständige Entwickleridentität. Ohne das wird die App abgelehnt. |
| 2 | **Data-Safety-Formular** in der Play Console ausfüllen, **passend zu dieser Seite** | Play prüft auf Widersprüche zwischen Formular und Datenschutzerklärung. |
| 3 | Play-Link setzen, sobald verfügbar | In `index.html` die Bedienleiste, Slot „Google Play" |
| 4 | APK + SHA-256-Fingerabdruck eintragen | Slot „Direkter Download". Erst wenn mit dem echten Release-Schlüssel signiert. |
| 5 | ~~Serverprotokoll ohne IP-Adressen~~ | ✅ **erledigt** — Format `bitdm_noip`, im Betrieb verifiziert: null IP-Treffer im Protokoll. |

Eine Zusage in der Datenschutzerklärung, die der Server nicht einhält, wäre eine
falsche Angabe gegenüber Google **und** gegenüber den Nutzern. Punkt 5 ist
deshalb bereits umgesetzt und nachgewiesen; die Punkte 1 bis 4 stehen noch aus.

## Cloudflare

`bitdm.net` läuft über den Cloudflare-Proxy (orange Wolke). Das hat drei
Folgen, die man kennen muss:

1. **Cloudflare sieht jeden Besucher** — IP, Zeitpunkt, aufgerufene Seite. Das
   ist in der Datenschutzerklärung unter „Weitergabe an Dritte" benannt, samt
   Hinweis auf die USA und die Standardvertragsklauseln. Wird der Proxy
   abgeschaltet, muss dieser Abschnitt wieder raus.
2. **Am Ursprung kommt nur Cloudflare an.** `$remote_addr` ist eine
   Cloudflare-Adresse, nicht die des Besuchers. Die echte stünde in
   `CF-Connecting-IP` — **die stellen wir bewusst nicht wieder her.** Dadurch
   sieht unser Server tatsächlich keine Besucher-IPs, und genau das sagt die
   Erklärung zu.
3. **Der Relay-Server darf NIE über Cloudflare laufen.** Bei der Website sieht
   Cloudflare, wer eine öffentliche Infoseite liest. Beim Relay sähe es, wer
   wann mit wem verbunden ist — also exakt die Metadaten, die das ganze Produkt
   klein zu halten versucht. Für den Relay-Hostnamen gilt: graue Wolke,
   DNS only.

Cloudflare steht auf „Full (strict)", erwartet am Ursprung also ein gültiges
Zertifikat. Solange der vHost fehlt, antwortet die Domain mit **HTTP 526**
(„Invalid SSL certificate") — das ist kein Fehler in der Konfiguration, sondern
die korrekte Meldung für „Ursprung noch nicht eingerichtet".

## Deployment auf dem VPS

**Ist bereits ausgerollt.** Die Seite läuft unter https://bitdm.net.
Dieser Abschnitt hält fest, wie — und wo es Fallstricke gab.

### Quelle: git statt Dateikopie

Der Server holt sich den Stand selbst über einen **schreibgeschützten
Deploy-Key**:

```bash
git -C /opt/bitdm pull
```

Mehr ist ein Update nicht. Der private Schlüssel liegt unter
`/root/.ssh/bitdm_deploy` und hat den Server nie verlassen; auf GitHub ist nur
der öffentliche Teil als *read-only* Deploy-Key eingetragen. nginx liefert
direkt aus dem Arbeitsverzeichnis (`root /opt/bitdm/secure-messenger/website`),
es gibt also keine zweite Kopie, die veralten könnte.

### Zwei Fallstricke, die Zeit gekostet haben

**1. `add_header` im `location`-Block löscht die Elternebene.**
Ein `add_header Cache-Control` in `location ~* \.html$` hat sämtliche
Sicherheitsheader der Serverebene entfernt — CSP, X-Frame-Options und den Rest,
und zwar ausgerechnet für die HTML-Seiten. Von außen sah man davon nichts außer
fehlenden Headern. Deshalb steht in den Location-Blöcken jetzt nur `expires`,
das Cache-Control ohne diesen Nebeneffekt setzt.

**2. `http2 on;` gibt es erst ab nginx 1.25.**
Auf dem Server läuft 1.18, dort heißt es `listen 443 ssl http2;`. Der
Konfigurationstest schlägt sonst fehl — nginx läuft dabei mit der alten
Konfiguration weiter, die anderen vHosts sind also nicht betroffen.

### Aktive Konfiguration

`/etc/nginx/sites-available/bitdm.net`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name bitdm.net;

    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://$host$request_uri; }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name bitdm.net;

    root /opt/bitdm/secure-messenger/website;
    index index.html;

    ssl_certificate     /etc/letsencrypt/live/bitdm.net/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/bitdm.net/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    access_log /var/log/nginx/bitdm.net.log bitdm_noip;

    add_header X-Frame-Options        "DENY"        always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy        "no-referrer" always;
    add_header Permissions-Policy     "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
    add_header Content-Security-Policy "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;

    location / { try_files $uri $uri/ =404; }
    # KEIN add_header hier — siehe Fallstrick 1.
    location ~* \.ttf$  { expires 1y; }
    location ~* \.html$ { expires 10m; }
    location ~ /\.      { deny all; }
}
```

`/etc/nginx/conf.d/bitdm-noip-log.conf`:

```nginx
log_format bitdm_noip '[$time_local] "$request" $status $body_bytes_sent';
```

Kein `$remote_addr`, kein `$http_x_forwarded_for`, kein `CF-Connecting-IP`. Was
nicht protokolliert wird, kann weder erbeutet noch herausverlangt werden.
Aufbewahrung 7 Tage über `/etc/logrotate.d/bitdm.net`, passend zur Zusage
in der Datenschutzerklärung.

Zertifikat von Let's Encrypt, Erneuerung über den vorhandenen `certbot.timer`.

## Prüfen nach dem Deployment

```bash
curl -sI https://bitdm.net | head -20
```

Erwartet: `200`, die Sicherheitsheader, und **keine** Weiterleitung auf eine
andere Domain — Google Play verlangt eine direkt erreichbare, nicht geoblockte
URL für die Datenschutzerklärung.

## Sprache

Beide Sprachen liegen im HTML; umgeschaltet wird über ein Attribut auf `<html>`.
Ohne JavaScript bleibt **Deutsch** vollständig lesbar — der Text entsteht nicht
erst durch ein Skript. Mit JavaScript entscheidet die Browsersprache, die Wahl
bleibt lokal gespeichert.

Beim Ändern von Texten **immer beide Sprachfassungen anfassen**. Ein `.de`-Block
ohne passenden `.en`-Block erscheint sonst je nach Umschaltung als Lücke.
