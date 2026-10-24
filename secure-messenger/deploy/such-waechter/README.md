# Such-Waechter

Prueft alle 6 Stunden vom Haupt-VPS aus, ob bitdm.net fuer Google richtig
steht, und meldet ueber das eigene ntfy (`push.bitdm.net`, dasselbe Thema wie
der Storage-Waechter), wenn nicht, und wenn es wieder stimmt.

## Anlass

Am 24.10.2026 stand bei der Google-Suche „BitDM“ nicht mehr die Startseite
oben, sondern die F-Droid-Quelle `bitdm.net/fdroid/repo/` (doppelt im Index,
auch als `/index.html` und `/?fingerprint=…`). fdroidserver erzeugt diese
Seite bei jedem `fdroid update` neu, mit Titel „BitDM“ und `robots: index`.
Bemerkt hat es erst Henrik, beim Suchen. Behoben mit `X-Robots-Tag: noindex`
fuer `/fdroid/` in nginx (siehe `../../fdroid/verzeichnis/README.md`) und einem
Entfernungsantrag in der Search Console.

## Was er prueft

| Pruefung | Warum |
|---|---|
| Jede Seite aus `sitemap.xml`: HTTP 200, kein `noindex` (Header oder `<meta>`), Canonical zeigt auf sich selbst | Eine Seite mit noindex oder fremdem Canonical faellt still aus dem Index |
| Die Startseite steht in der Sitemap, ihr Titel enthaelt „BitDM“ | Genau um diese Suche geht es |
| `/fdroid/repo/` und `/fdroid/repo/index.html` senden `noindex` | Sonst verdraengen sie die Startseite wieder |
| `robots.txt` sperrt nicht alles und nennt die Sitemap | Ein `Disallow: /` nimmt die ganze Seite heraus |
| `http://bitdm.net/` und `https://www.bitdm.net/` leiten per 301 auf `https://bitdm.net/` | Eine Adresse fuer die Startseite; bis 22.10.2026 zeigte Google noch die http-Fassung |

Abgerufen wird ueber Cloudflare, mit einem Parameter je Lauf, damit kein
alter Stand aus dem Zwischenspeicher antwortet. Ein Befund zaehlt erst, wenn
er eine Minute spaeter noch da ist.

Was er **nicht** sieht: die Platzierung bei Google selbst. Die kennt nur die
Search Console, und die liefert ihre Zahlen zwei bis drei Tage spaeter.

## Einrichtung (Haupt-VPS, als root)

Nutzer `bitdm-waechter` und `/etc/bitdm/waechter.env` gibt es schon vom
Storage-Waechter. Dann nur:

    cd /opt/bitdm/secure-messenger/deploy/such-waechter
    install -m 755 bitdm-such-waechter.sh /usr/local/sbin/bitdm-such-waechter
    install -m 644 bitdm-such-waechter.service bitdm-such-waechter.timer /etc/systemd/system/
    systemctl daemon-reload && systemctl enable --now bitdm-such-waechter.timer
    systemctl start bitdm-such-waechter.service
    journalctl -u bitdm-such-waechter -n 5 --no-pager     # "ok: 8 Seiten der Sitemap, ..."

Ausprobieren ohne ntfy, auch am eigenen Rechner:

    TROCKEN=1 NTFY_TOPIC=x STATE_DIRECTORY=/tmp/sw ./bitdm-such-waechter.sh

## Wenn er meldet

1. `site:bitdm.net` und die Suche „BitDM“ bei Google ansehen.
2. Die gemeldete Adresse mit `curl -sI` und im Quelltext pruefen (noindex,
   Canonical). Neue, automatisch erzeugte Seiten (wie die F-Droid-Quelle)
   bekommen in nginx `X-Robots-Tag: noindex`.
3. In der Search Console die Startseite pruefen und ggf. „Indexierung
   beantragen“; eine falsche Seite unter „Entfernen“ vorlaeufig herausnehmen.
