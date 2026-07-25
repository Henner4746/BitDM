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
| 5 | Serverprotokoll auf gekürzte IPs stellen | Die Datenschutzerklärung sagt „gekürzte IP-Adresse, 7 Tage" zu. Das muss die nginx-Konfiguration auch tun. |

Punkt 5 ist kein Detail: Eine Zusage in der Datenschutzerklärung, die der Server
nicht einhält, ist eine falsche Angabe gegenüber Google **und** gegenüber den
Nutzern.

## Deployment auf dem VPS

Dateien nach `/var/www/app.henrik.click/` legen, dann als nginx-vHost:

```nginx
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name app.henrik.click;

    root /var/www/app.henrik.click;
    index index.html;

    # Zusage der Datenschutzerklaerung: gekuerzte IP, 7 Tage Aufbewahrung.
    # Ohne diese map landen volle IPs im Log und die Erklaerung waere falsch.
    access_log /var/log/nginx/app.henrik.click.log anonymized;

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

Dazu in den `http`-Block (z. B. `/etc/nginx/conf.d/anonymized-log.conf`):

```nginx
map $remote_addr $ip_anon {
    ~(?P<ip>\d+\.\d+\.\d+)\.    "$ip.0";
    ~(?P<ip>[^:]+:[^:]+):       "$ip::";
    default                     "0.0.0.0";
}
log_format anonymized '$ip_anon - [$time_local] "$request" $status $body_bytes_sent';
```

Logrotation auf **7 Tage** stellen, passend zur Zusage.

Zertifikat wie die übrigen vHosts über Let's Encrypt.

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
