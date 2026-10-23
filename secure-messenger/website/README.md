# BitDM — Website

Statische Seiten, **live unter https://bitdm.net**. Keine Build-Schritte, keine
Abhängigkeiten, keine Fremdanfragen zur Laufzeit.

```
website/
├─ index.html      Startseite
├─ vs.html         BitDM neben anderen Messengern (Vergleich)
├─ docs.html       Server selbst betreiben
├─ privacy.html    Datenschutzerklärung + Impressum   ← Play-Pflicht
├─ messenger-without-phone-number.html      Ratgeber: ohne Telefonnummer
├─ messaging-without-internet-bluetooth.html Ratgeber: ohne Internet, per Bluetooth
├─ anonymous-messenger-without-account.html Ratgeber: anonym, ohne Konto
├─ llms.txt        maschinenlesbare Kurzfassung für KI-Werkzeuge
├─ robots.txt      alles lesbar ausser /app/
├─ sitemap.xml     alle Seiten oben + llms.txt, je mit .html
├─ 1e0f…5274.txt   IndexNow-Schlüssel (öffentlich mit Absicht, siehe unten)
├─ favicon.ico     Seitenzeichen 16/32/48 px, favicon.svg dasselbe als Vektor
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
    # NACH der Sperre: sonst lieferte sie jede .txt unter /.well-known/ aus.
    location ~* \.txt$  { charset utf-8; }

    # security.txt (RFC 9116). Die Sperre oben trifft auch /.well-known/;
    # geoeffnet wird genau diese eine Datei.
    location = /.well-known/security.txt {
        alias /opt/bitdm/secure-messenger/website/security.txt;
        charset utf-8;
    }
    # llms.txt ist der Name nach llmstxt.org; manche Pruefer fragen /llm.txt.
    location = /llm.txt {
        alias /opt/bitdm/secure-messenger/website/llms.txt;
        charset utf-8;
    }
}
```

**Die Textdateien im Wurzelordner** (seit 18.10.2026):

| Datei | Wofür |
|---|---|
| `security.txt` | Meldeweg für Schwachstellen nach RFC 9116, ausgeliefert unter `/.well-known/security.txt`. **Läuft am 01.10.2027 ab**; der Workflow `security-txt.yml` wird 30 Tage vorher rot. Verlängern heißt: `Expires` höchstens ein Jahr nach vorn setzen und ausrollen. |
| `llms.txt` | Kurzfassung für Sprachmodelle (llmstxt.org), auch unter `/llm.txt` |
| `ai.txt` | KI-Training ausdrücklich erlaubt, auch für große Firmen (seit 18.10.2026, vorher verboten); dieselbe Erlaubnis steht als `Content-Signal` in der robots.txt. |
| `humans.txt` | wer dahintersteht, nur mit GitHub-Namen |
| `ads.txt` | Platzhalter nach IAB: keine Werbung, niemand darf Werbeplätze verkaufen |

Bis 18.10.2026 war die robots.txt, die Besucher sahen, länger als die Datei
hier: Cloudflare setzte einen eigenen Block davor (`ai-train=no` und 32
gesperrte KI-Crawler wie GPTBot und ClaudeBot). Eingestellt wird das im
Cloudflare-Dashboard unter Security → Settings → Bot traffic → „Configure AI
bot policies“: Search, Agent und **Training stehen auf Allow**, „Bot Preference
Sync“ ist an und setzt dann nichts mehr davor. Taucht der Block wieder auf, hat
dort jemand „Training“ auf Disallow gestellt.

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

**Das Seitenzeichen liegt als Datei vor, nicht im HTML.** Bis Oktober 2026
stand es als `data:`-Bild im `<link rel="icon">`. Browser zeigen das, Google
aber nicht: für die Suchergebnisse braucht es eine abrufbare Adresse, und
`/favicon.ico` lieferte 404 (so in den Crawling-Statistiken der Search
Console). Jetzt verweist jede Seite auf `/favicon.ico` (48 px, für Google) und
`/favicon.svg`.

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

Die Suchmaschinen stößt der Git-Hook nach dem Pull selbst an (siehe
IndexNow). Ohne Hook, oder um alle Seiten neu zu melden:

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

Das Laufenlassen übernimmt `../deploy/git-hooks/post-merge`: nach jedem
`git pull` in `/opt/bitdm` meldet er nur die Seiten, die der Pull geändert hat
(`indexnow.py --seit ORIG_HEAD`). Gemeldet wird, was in der Sitemap steht, dazu
gelöschte `.html`-Seiten; Bilder, Schriften und `_test-*.html` nicht. Einmal
einrichten, auf dem Haupt-VPS:

```bash
ln -sf ../../secure-messenger/deploy/git-hooks/post-merge /opt/bitdm/.git/hooks/post-merge
```

Ein Fehlschlag stört den Pull nicht; der Hook schreibt dann, wie man von Hand
meldet.

**Stand Bing, 23.10.2026:** Die Suche nach „BitDM" findet bitdm.net auf
Platz 1, aber nur die Startseite und mit altem Titel. `vs.html` und die drei
Ratgeberseiten fehlen dort, deshalb taucht BitDM bei allgemeinen Suchen wie
„Messenger ohne Telefonnummer" in Bing, Edge und Copilot nicht auf. IndexNow ist
nur ein Hinweis. Schneller geht es über die Bing Webmaster Tools (Henriks
Konto): dort die Seite per „Aus Google Search Console importieren" übernehmen,
das bestätigt die Domain und reicht die Sitemap ein. Eine Datei oder ein
Meta-Tag auf der Seite ist dafür nicht nötig.

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
- **Die drei Ratgeber sind ebenfalls englisch zuerst** (seit 14.10.2026).
  Jeder beantwortet genau eine Suchfrage und hat deshalb einen sprechenden
  englischen Dateinamen. Die Antworten unter „Short answers“ stehen
  wörtlich auch im FAQPage-Datenblock im Kopf — wer sie ändert, ändert beide.
  Fakten nur aus dem Repository; was dort fehlt, steht auch hier nicht.
- **`docs.html` und `privacy.html` sind deutsch zuerst** und folgen der
  Browsersprache — die Datenschutzerklärung ist ein deutscher Rechtstext.

Die Wahl im Umschalter gilt seitenübergreifend (`localStorage` `bitdm-lang`)
und schlägt jede Voreinstellung. Ein kleines Skript ganz oben im `<head>`
setzt sie, bevor etwas gezeichnet ist — sonst blitzt die andere Sprache kurz
auf.

Beim Ändern von Texten **immer beide Sprachfassungen anfassen**. Ein `.de`-Block
ohne passenden `.en`-Block erscheint sonst je nach Umschaltung als Lücke.
