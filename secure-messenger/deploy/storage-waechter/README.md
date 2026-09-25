# Storage-Waechter

Prueft alle 5 Minuten vom Haupt-VPS aus, ob das Zwischenlager auf dem
Storage-VPS lebt (Dienst, Platz, HTTPS von aussen), und meldet Ausfall,
knappen Platz und Wiederkehr ueber das eigene ntfy (`push.bitdm.net`).
Anlass: drei Tage unbemerkter Ausfall im September 2026 (Rechnung offen).

Installation auf dem Haupt-VPS:

    install -m 755 bitdm-storage-waechter.sh /usr/local/sbin/bitdm-storage-waechter
    install -m 644 bitdm-storage-waechter.service bitdm-storage-waechter.timer /etc/systemd/system/
    # Thema zufaellig waehlen — ntfy hat keine Anmeldung, der Name ist das Geheimnis:
    printf 'NTFY_TOPIC=bitdm-waechter-%s\n' "$(openssl rand -hex 12)" > /etc/bitdm/waechter.env
    chmod 600 /etc/bitdm/waechter.env
    systemctl daemon-reload && systemctl enable --now bitdm-storage-waechter.timer

In der ntfy-App `https://push.bitdm.net` als Server und das Thema aus
`/etc/bitdm/waechter.env` abonnieren.
