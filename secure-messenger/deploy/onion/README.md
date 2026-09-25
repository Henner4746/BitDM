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

## Grenzen fuer den Onion-Weg (seit 25.09.2026)

Ueber Tor kommt JEDE Verbindung von 127.0.0.1. Jede Bremse "je IP" — in nginx
wie im Relay — war dort eine einzige Bremse fuer alle Tor-Nutzer zusammen: ein
Stoerer sperrte alle anderen aus, oder (wo keine griff) er flutete ungebremst.
Deshalb gilt ueber Tor:

| Wo | Was |
|---|---|
| tor (`torrc.snippet`) | `HiddenServiceMaxStreams 20` je Circuit, darueber wird der Circuit geschlossen |
| nginx (`relay-onion.nginx`) | ein Deckel fuer den ganzen Dienst: 512 offene Verbindungen, 30 neue Anfragen/s (Stoss 60–120) |
| nginx | setzt `X-BitDM-Onion: 1` — der Relay laesst daraufhin seine Bremse je IP weg |
| Relay | Grenzen je Adresse (Einmalschluessel, Puffern, Nonces), Vorraum-Deckel fuer nicht angemeldete WebSockets, Speicherdach |

Der Relay glaubt `X-BitDM-Onion` nur zusammen mit der Herkunft 127.0.0.1 (siehe
`kommt_ueber_onion` in `relay_server.py`), und der oeffentliche vHost setzt die
Kopfzeile leer. Wer von aussen die Kopfzeile faelscht, bringt trotzdem seine
eigene IP mit.

### Aufspielen der Aenderung vom 25.09.2026

    cd /opt/bitdm && git pull
    cp secure-messenger/deploy/onion/relay-onion.nginx /etc/nginx/sites-available/relay-onion
    # In /etc/tor/torrc die beiden neuen Zeilen aus torrc.snippet unter den
    # bestehenden HiddenService-Block setzen (NICHT den ganzen Schnipsel ein
    # zweites Mal anhaengen — zweimal HiddenServiceDir laesst tor nicht starten):
    #   HiddenServiceMaxStreams 20
    #   HiddenServiceMaxStreamsCloseCircuit 1
    tor --verify-config -f /etc/tor/torrc
    nginx -t && systemctl reload nginx && systemctl restart tor
