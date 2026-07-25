# BitDM — Website

Statische Seite für **`app.henrik.click`**. Zwei Dateien, keine Build-Schritte,
keine Abhängigkeiten, keine Fremdanfragen zur Laufzeit.

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
| 5 | Serverprotokoll ohne IP-Adressen führen | Die Datenschutzerklärung sagt zu, dass unser Server **keine Besucher-IPs** sieht. Das muss die nginx-Konfiguration auch einhalten. |

Punkt 5 ist kein Detail: Eine Zusage in der Datenschutzerklärung, die der Server
nicht einhält, ist eine falsche Angabe gegenüber Google **und** gegenüber den
Nutzern.

## Cloudflare

`app.henrik.click` läuft über den Cloudflare-Proxy (orange Wolke). Das hat drei
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

Dateien nach `/var/www/app.henrik.click/` legen, dann als nginx-vHost:

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name app.henrik.click;

    root /var/www/app.henrik.click;
    index index.html;

    # Zusage der Datenschutzerklaerung: unser Server sieht keine Besucher-IPs.
    # Hinter dem Cloudflare-Proxy waere $remote_addr ohnehin nur eine
    # Cloudflare-Adresse; wir protokollieren sie erst gar nicht mit.
    # CF-Connecting-IP wird bewusst NICHT wiederhergestellt.
    access_log /var/log/nginx/app.henrik.click.log noip;

    add_header X-Content-Type-Options    "nosniff"          always;
    add_header X-Frame-Options           "DENY"             always;
    add_header Referrer-Policy           "no-referrer"      always;
    add_header Permissions-Policy        "interest-cohort=(), geolocation=(), microphone=(), camera=()" always;
    # Die Seite laedt ausschliesslich eigene Ressourcen — das laesst sich hart zusagen.
    add_header Content-Security-Policy   "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; font-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;

    location ~* \.(ttf)$   { expires 1y;  add_header Cache-Control "public, immutable"; }
    location ~* \.(html)$  { expires 10m; add_header Cache-Control "public"; }
}

server {
    listen 80; listen [::]:80;
    server_name app.henrik.click;
    return 301 https://$host$request_uri;
}
```

Dazu in den `http`-Block (z. B. `/etc/nginx/conf.d/noip-log.conf`):

```nginx
log_format noip '[$time_local] "$request" $status $body_bytes_sent';
```

Kein `$remote_addr`, kein `$http_x_forwarded_for`, kein `CF-Connecting-IP`. Was
nicht protokolliert wird, kann weder erbeutet noch herausverlangt werden.

Logrotation auf **7 Tage** stellen, passend zur Zusage.

Zertifikat wie die übrigen vHosts über Let's Encrypt. Cloudflare steht auf
„Full (strict)" und verlangt am Ursprung ein gültiges Zertifikat — der
`certbot`-Lauf muss also **vor** dem ersten erfolgreichen Aufruf durch sein.

## Prüfen nach dem Deployment

```bash
curl -sI https://app.henrik.click | head -20
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
