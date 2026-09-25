# Relay als Onion-Dienst

Seit 25.09.2026 ist der Relay zusaetzlich unter

    tpbryhlguq6bhrxzv3qlcqk2ogkrv4hot7auqa54pnmeksaoiwsnuqqd.onion

erreichbar. Die App nimmt diese Adresse, wenn "Ueber Tor verbinden" an ist
(`relayTorUri` in `app/lib/main.dart`); dann verlaesst die Verbindung das
Tor-Netz nicht, und kein Ausgangsknoten sieht sie. Das Zwischenlager bleibt
bei `dateien.bitdm.net` (ueber einen Tor-Ausgang).

Einrichtung auf dem Haupt-VPS (Ubuntu 22.04):

    apt-get install -y tor
    cp relay-onion.nginx /etc/nginx/sites-available/relay-onion
    ln -s /etc/nginx/sites-available/relay-onion /etc/nginx/sites-enabled/
    cat torrc.snippet >> /etc/tor/torrc
    nginx -t && systemctl reload nginx && systemctl restart tor
    cat /var/lib/tor/bitdm_relay/hostname

Pruefen (auf dem VPS, ueber das lokale SOCKS von Tor):

    curl --socks5-hostname 127.0.0.1:9050 http://<onion>/prekey/aaaa   # 404 JSON vom Relay
    curl --socks5-hostname 127.0.0.1:9050 http://<onion>/health        # 404

WICHTIG: `/var/lib/tor/bitdm_relay/hs_ed25519_secret_key` IST die
Onion-Adresse. Geht die Datei verloren, ist die Adresse weg, und jede
ausgelieferte App zeigt ins Leere. Sie gehoert in die Sicherung des VPS —
und nirgends sonst hin.
