# Web-Fassung unter bitdm.net/app/

Stand 25.09.2026 (1.8.0). Abgeschrieben vom laufenden Server, damit die
Einstellungen nicht nur dort liegen.

## Bauen

    cd app
    flutter build web --release --base-href /app/ --no-web-resources-cdn
    tar -C build/web -czf ../releases/bitdm-web-1.8.0.tar.gz .

`--no-web-resources-cdn` ist Pflicht: ohne lädt Flutter CanvasKit von
gstatic.com, und die CSP unten verbietet das (zu Recht).

### Seit 2.0.0: libsignal als WASM

Der Build-Hook des Pakets `libsignal` legt beim Web-Bau `app/web/pkg/` an
(`libsignal_frb.js`, `libsignal_frb_bg.wasm`, `.wasm-version` = Crate-Fassung
7.0.0) und Flutter kopiert sie nach `build/web/pkg/`. Der Ordner steht in
`.gitignore`. Die Prüfsumme, gegen die der Hook prüft, liegt im selben
GitHub-Release wie die Dateien; das fängt kaputte Downloads ab, aber kein
ausgetauschtes Release. Darum vor dem Packen gegen diese Werte prüfen
(Paket libsignal 8.0.0, Dateien aus dem Release `libsignal_frb-7.0.0`,
Archiv `libsignal_frb-7.0.0-wasm32.tar.gz`, gemessen am 16.10.2026):

    cd app/build/web/pkg
    echo "432f8028350acfef8ef5cdfa76d8b0e2c9bf5f82012bcf74d5662819764bb645  libsignal_frb.js" | sha256sum -c
    echo "5f3d15e5fe3aeb76c5b233d407520212343d6c966637b1a660394f87d1b70d8c  libsignal_frb_bg.wasm" | sha256sum -c

Ändern sich die Werte ohne Fassungswechsel im `pubspec.yaml`, nicht ausliefern.

`web/libsignal_ohne_eval.js` muss mit ausgeliefert werden. Ohne das Skript
bräuchte flutter_rust_bridge `'unsafe-eval'` in der CSP und bleibt sonst beim
Anlegen der Identität stehen (Begründung im Skript,
`test/web/libsignal_ohne_eval_test.dart` wacht darüber).

In der Konsole steht danach „Buffers cannot be shared due to missing
cross-origin headers“. Das ist gewollt: COOP/COEP bräuchte nur der
Worker-Pool von flutter_rust_bridge, und den baut libsignal nicht ein.
Durchstich am 16.10.2026: zwei Web-Clients mit dieser CSP gegen einen lokalen
Relay mit Kyber-Pflicht, Anfrage, Annahme, Nachricht und Antwort.

## Ausliefern

    cd /opt/bitdm/secure-messenger/website
    curl -fsSLO https://github.com/Henner4746/BitDM/releases/download/v1.8.0/bitdm-web-1.8.0.tar.gz
    echo "eefb8e6a61edb4a1294d7c4e9dcce027f9804b35a2c35461d55372523397c7d0  bitdm-web-1.8.0.tar.gz" | sha256sum -c
    rm -rf app.neu && mkdir app.neu && tar -C app.neu -xzf bitdm-web-1.8.0.tar.gz
    rm -rf app.alt && { [ -d app ] && mv app app.alt; true; } && mv app.neu app

`website/app/` steht in `.gitignore` — der Bau gehört nicht ins Repo.

## nginx: bitdm.net

Achtung: `/etc/nginx/sites-enabled/bitdm.net` ist auf dem Server eine
**Datei**, kein Verweis auf sites-available. Dort wird bearbeitet.

Die Seite selbst verbietet jedes Skript aus einer Datei; die App ist eines.
Darum ein eigener Block mit eigenen Kopfzeilen (ein `add_header` im Block
löscht alle der Serverebene, deshalb stehen die übrigen hier noch einmal):

```nginx
location ^~ /app/ {
    add_header X-Frame-Options        "DENY"        always;
    add_header X-Content-Type-Options "nosniff"     always;
    add_header Referrer-Policy        "no-referrer" always;
    add_header Permissions-Policy     "geolocation=(), microphone=(), camera=(), interest-cohort=()" always;
    add_header Content-Security-Policy "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' https://relay.bitdm.net wss://relay.bitdm.net; worker-src 'self' blob:; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-ancestors 'none'" always;
    # nginx 1.18 kennt .wasm noch nicht; ein types-Block ersetzt die ganze Liste,
    # darum stehen hier alle Arten, die ein Flutter-Webbau enthaelt.
    types { application/wasm wasm; application/javascript js mjs; text/html html; application/json json; image/png png; image/svg+xml svg; image/x-icon ico; text/css css; font/ttf ttf; font/otf otf; font/woff2 woff2; application/octet-stream bin frag symbols; }
    # Flutter-Dateien tragen keinen Inhalts-Hash im Namen: ohne no-cache
    # hielt Cloudflare sie 4 h und mischte nach einem Update alt und neu.
    # no-cache heisst "jedes Mal nachfragen" — meist ein 304.
    add_header Cache-Control "no-cache" always;
    try_files $uri $uri/ /app/index.html;
}
```

Das `no-cache` kam erst nach dem ersten Ausliefern dazu (25.09.2026). Was
Cloudflare vorher schon zwischengespeichert hatte, bleibt bis zum Ablauf dort
(bis 4 h) — oder man leert den Cache im Cloudflare-Dashboard.

Ohne den types-Block kommt `sqlite3mc.wasm` als `application/octet-stream`,
und `WebAssembly.instantiateStreaming` verweigert es.

## nginx: relay.bitdm.net (CORS)

`relay_server.py` schickt keine CORS-Kopfzeilen und soll es auch nicht: die
Freigabe gilt genau einer Herkunft und steht darum im nginx davor, auf
Serverebene des 443-Blocks:

```nginx
set $bitdm_cors "";
if ($http_origin = "https://bitdm.net") { set $bitdm_cors "https://bitdm.net"; }
add_header Access-Control-Allow-Origin  $bitdm_cors always;
add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
add_header Access-Control-Allow-Headers "Content-Type" always;
add_header Vary Origin always;
```

und in den REST-Orten die Vorabfrage beantworten, bevor sie den Relay
erreicht:

```nginx
location = /register/challenge { if ($request_method = OPTIONS) { return 204; } ... }
location = /register           { if ($request_method = OPTIONS) { return 204; } ... }
location ^~ /prekey/           { if ($request_method = OPTIONS) { return 204; } ... }
```

Bei leerem `$bitdm_cors` lässt nginx die Kopfzeile ganz weg — eine fremde
Herkunft bekommt also keine. Nachgeprüft:

    curl -si -X OPTIONS -H "Origin: https://bitdm.net" https://relay.bitdm.net/register | grep -i "^HTTP\|allow-origin"
    curl -si -X OPTIONS -H "Origin: https://example.com" https://relay.bitdm.net/register | grep -ci allow-origin   # 0
