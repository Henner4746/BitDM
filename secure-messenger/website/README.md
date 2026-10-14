# BitDM — Website

Statische Seiten, **live unter https://bitdm.net**. Keine Build-Schritte, keine
Abhängigkeiten, keine Fremdanfragen zur Laufzeit.

```
website/
├─ index.html      Startseite
├─ vs.html         BitDM neben anderen Messengern (Vergleich)
├─ docs.html       Server selbst betreiben
├─ privacy.html    Datenschutzerklärung + Impressum   ← Play-Pflicht
├─ llms.txt        maschinenlesbare Kurzfassung für KI-Werkzeuge
├─ robots.txt      alles lesbar ausser /app/
├─ sitemap.xml     die vier Seiten oben + llms.txt, je mit .html
├─ 1e0f…5274.txt   IndexNow-Schlüssel (öffentlich mit Absicht, siehe unten)
├─ bilder/         App-Icon
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

`bitdm.net` läuft über den Cloudflare-Proxy (orange Wolke). Das hat drei Folgen,
die man kennen muss:

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
   klein zu halten versucht. Für `relay.bitdm.net` gilt: **graue Wolke,
   DNS only.**

Cloudflare steht auf „Full (strict)", erwartet am Ursprung also ein gültiges
Zertifikat. Fehlt der vHost, antwortet die Domain mit **HTTP 526** — kein
Konfigurationsfehler, sondern die korrekte Meldung für „Ursprung noch nicht
eingerichtet".

### Frühere Adresse

Die Seite lag kurzzeitig unter `app.henrik.click`. Diese Domain wurde am
25.07.2026 aufgegeben: DNS-Eintrag gelöscht, nginx-vHost und Let's-Encrypt-
Zertifikat entfernt. Sonst wäre die Zertifikatserneuerung nach ~60 Tagen in
einen Dauerfehler gelaufen, weil certbot die Domain nicht mehr erreicht.

**Falls in der Play Console noch `app.henrik.click` steht: umtragen.** Die
Adresse ist tot, und Play verlangt eine erreichbare, nicht geoblockte URL.

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

    location / { try_files $uri $uri.html $uri/ =404; }
    # KEIN add_header hier — siehe Fallstrick 1.
    location ~* \.ttf$  { expires 1y; }
    location ~* \.html$ { expires 10m; }
    location ~ /\.      { deny all; }
}
```

Der Ausschnitt zeigt die Website; der Block für die Web-App unter `/app/`
steht in `../deploy/webapp/README.md`. Live liegt die Datei unter
`sites-enabled/` als eigene Datei, nicht als Verweis — wer sie ändert, ändert
dort.

**Eine Seite, eine Adresse.** Wegen `$uri.html` liefert nginx jede Seite auch
ohne Endung aus: `/vs` und `/vs.html` sind derselbe Inhalt unter zwei
Adressen. Für Suchmaschinen ist das eine Dublette. Die gültige Form ist die
mit `.html` — so steht sie in der Sitemap, in `og:url`, in `llms.txt` und als
`<link rel="canonical">` im Kopf jeder Seite, und so verlinkt die Startseite.
Die endungslose Form bleibt erreichbar, damit alte Links nicht brechen.

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

Danach die Suchmaschinen anstoßen:

```bash
python3 /opt/bitdm/secure-messenger/deploy/indexnow.py
```

## IndexNow

bitdm.net stand im Oktober 2026 in keinem Suchindex — die Suche nach „BitDM"
fand das GitHub-Repo und bitdms.net, nie die Seite selbst. IndexNow meldet
geänderte Adressen ohne Konto an Bing, Yandex, Seznam und andere; Bing liefert
die Treffer für die ChatGPT-Suche und Copilot. Google nimmt nicht teil, dafür
braucht es die Search Console (Henriks Konto).

Den Nachweis, dass eine Meldung von uns kommt, liefert die Datei
`<schlüssel>.txt` in diesem Ordner: ihr Inhalt ist ihr eigener Name. Sie
**muss** öffentlich lesbar bleiben, sonst verwirft die Suchmaschine jede
Meldung — kein Geheimnis, nicht in die `.gitignore`, nicht löschen.

`../deploy/indexnow.py` meldet alle Adressen aus `sitemap.xml` (oder nur die
übergebenen), prüft aber vorher, ob die Schlüsseldatei **live** ausgeliefert
wird. Ohne diese Probe antwortet die API trotzdem mit 202 und verwirft die
Meldung später still. Erwartet: `HTTP 200` oder `202`. Nach jedem Deploy, der
Seiteninhalte ändert, einmal laufen lassen; `lastmod` in der Sitemap vorher
mitziehen.

## Sprache

Beide Sprachen liegen im HTML; umgeschaltet wird über ein Attribut auf `<html>`.
Der Text entsteht nicht erst durch ein Skript — wer Englisch liest, hat
Deutsch einen Klick entfernt schon geladen.

- **Startseite und Vergleich (`vs.html`) sind englisch zuerst** — die
  Startseite seit 27.09.2026, der Vergleich seit 14.10.2026. `lang="en"`,
  Titel, Beschreibung und Vorschaukarte sind englisch, auch für deutsche
  Browser. Grund: Suchmaschinen und KI-Leser ordnen eine Seite nach diesen
  Angaben einer Sprache zu; mit `lang="de"` war der Vergleich für die Suche
  „BitDM vs Signal" eine deutsche Seite.
- **`docs.html` und `privacy.html` sind deutsch zuerst** und folgen der
  Browsersprache — die Datenschutzerklärung ist ein deutscher Rechtstext.

Die Wahl im Umschalter gilt seitenübergreifend (`localStorage` `bitdm-lang`)
und schlägt jede Voreinstellung. Ein kleines Skript ganz oben im `<head>`
setzt sie, bevor etwas gezeichnet ist — sonst blitzt die andere Sprache kurz
auf.

Beim Ändern von Texten **immer beide Sprachfassungen anfassen**. Ein `.de`-Block
ohne passenden `.en`-Block erscheint sonst je nach Umschaltung als Lücke.
