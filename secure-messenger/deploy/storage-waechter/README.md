# Storage-Waechter

Prueft alle 5 Minuten vom Haupt-VPS aus, ob das Zwischenlager auf dem
Storage-VPS lebt (Dienst, Platz, HTTPS von aussen), und meldet Ausfall,
knappen Platz und Wiederkehr ueber das eigene ntfy (`push.bitdm.net`).
Anlass: drei Tage unbemerkter Ausfall im September 2026 (Rechnung offen).

## Rechte: kein root, auf keiner Seite (seit 25.09.2026)

Die erste Fassung lief als root und meldete sich mit `/root/.ssh/storage_transfer`
als **root** auf dem Storage-VPS an. Ein Fehler in diesem kleinen Skript — oder
in curl, ssh, der ntfy-Antwort — waere root auf beiden Rechnern gewesen, und der
Schluessel konnte drueben alles.

Jetzt:

| Seite | Wer | Was er darf |
|---|---|---|
| Haupt-VPS | Systemnutzer `bitdm-waechter`, gehaertete Unit | Schluessel in `/etc/bitdm/waechter_ssh/` lesen, eigenes StateDirectory |
| Storage-VPS | Systemnutzer `bitdm-waechter` | per `authorized_keys` **nur** `curl -fsS -m 10 http://127.0.0.1:8081/health`, nur vom Haupt-VPS, ohne Terminal, ohne Weiterleitungen |

`/root/.ssh/storage_transfer` bleibt, wie es ist — der Schluessel wird fuer
anderes gebraucht (Zwischenlager-Zugang). Der Waechter benutzt ihn nur nicht mehr.

## Einrichtung bzw. Umstellung

### 1. Haupt-VPS: Nutzer und Schluessel

    id bitdm-waechter >/dev/null 2>&1 || useradd --system --no-create-home \
        --home-dir /nonexistent --shell /usr/sbin/nologin \
        --comment "BitDM Storage-Waechter" bitdm-waechter
    install -d -o root -g bitdm-waechter -m 0750 /etc/bitdm/waechter_ssh
    ssh-keygen -t ed25519 -N '' -C bitdm-waechter@haupt \
        -f /etc/bitdm/waechter_ssh/id_ed25519
    chown root:bitdm-waechter /etc/bitdm/waechter_ssh/id_ed25519
    chmod 0640 /etc/bitdm/waechter_ssh/id_ed25519
    # Hostschluessel des Storage-VPS festhalten — aus dem known_hosts von root,
    # der ihn schon kennt (StrictHostKeyChecking=yes bleibt an):
    ssh-keygen -F 5.231.234.142 -f /root/.ssh/known_hosts | grep -v '^#' \
        > /etc/bitdm/waechter_ssh/known_hosts
    chmod 0644 /etc/bitdm/waechter_ssh/known_hosts
    test -s /etc/bitdm/waechter_ssh/known_hosts || echo "known_hosts LEER — Hostschluessel pruefen!"
    cat /etc/bitdm/waechter_ssh/id_ed25519.pub      # fuer Schritt 2

### 2. Storage-VPS: eingeschraenkter Nutzer

Die Shell muss `/bin/sh` sein, nicht `nologin`: sshd fuehrt auch den
erzwungenen Befehl ueber die Shell des Nutzers aus. Mehr als dieser eine Befehl
geht trotzdem nicht — `command=` ersetzt alles, was der Client verlangt, und
`restrict` schaltet Terminal, Weiterleitungen, Agent und X11 ab. `from=` laesst
den Schluessel nur vom Haupt-VPS gelten (IP vorher mit `curl -4 ifconfig.me` auf
dem Haupt-VPS pruefen; zuletzt bekannt: 77.90.4.46).

    id bitdm-waechter >/dev/null 2>&1 || useradd --system --create-home \
        --home-dir /var/lib/bitdm-waechter --shell /bin/sh \
        --comment "BitDM Storage-Waechter" bitdm-waechter
    passwd -l bitdm-waechter
    install -d -o bitdm-waechter -g bitdm-waechter -m 0700 /var/lib/bitdm-waechter/.ssh
    # EINE Zeile; <PUBKEY> ist die Ausgabe von Schritt 1 (ssh-ed25519 AAAA... bitdm-waechter@haupt):
    printf '%s\n' 'command="curl -fsS -m 10 http://127.0.0.1:8081/health",restrict,from="77.90.4.46" <PUBKEY>' \
        > /var/lib/bitdm-waechter/.ssh/authorized_keys
    chown bitdm-waechter:bitdm-waechter /var/lib/bitdm-waechter/.ssh/authorized_keys
    chmod 0600 /var/lib/bitdm-waechter/.ssh/authorized_keys
    # Steht in /etc/ssh/sshd_config ein "AllowUsers"/"AllowGroups", muss
    # bitdm-waechter dort dazu, sonst weist sshd ihn ab:
    grep -Ei '^\s*(AllowUsers|AllowGroups|DenyUsers)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/* 2>/dev/null

### 3. Haupt-VPS: Probe, dann Skript und Unit

    # Muss das /health-JSON liefern — gleich, welcher Befehl verlangt wird:
    sudo -u bitdm-waechter ssh -F /dev/null -i /etc/bitdm/waechter_ssh/id_ed25519 \
        -o IdentitiesOnly=yes -o BatchMode=yes \
        -o UserKnownHostsFile=/etc/bitdm/waechter_ssh/known_hosts \
        bitdm-waechter@5.231.234.142 'id; cat /etc/shadow'
    # -> {"ok":true,"dateien":...}   (NICHT die Ausgabe von id)

    cd /opt/bitdm/secure-messenger/deploy/storage-waechter
    install -m 755 bitdm-storage-waechter.sh /usr/local/sbin/bitdm-storage-waechter
    install -m 644 bitdm-storage-waechter.service bitdm-storage-waechter.timer /etc/systemd/system/
    # Nur bei der Ersteinrichtung — ein bestehendes Thema NICHT ueberschreiben.
    # ntfy hat keine Anmeldung, der Name ist das Geheimnis:
    test -f /etc/bitdm/waechter.env || {
        printf 'NTFY_TOPIC=bitdm-waechter-%s\n' "$(openssl rand -hex 12)" > /etc/bitdm/waechter.env
        chmod 600 /etc/bitdm/waechter.env; }
    systemctl daemon-reload && systemctl enable --now bitdm-storage-waechter.timer
    systemctl start bitdm-storage-waechter.service
    journalctl -u bitdm-storage-waechter -n 5 --no-pager     # "ok, frei ... GB"
    systemd-analyze security bitdm-storage-waechter

`/etc/bitdm/waechter.env` bleibt root-eigen und 0600: systemd liest es, bevor
es die Rechte abgibt. Das StateDirectory `/var/lib/bitdm-waechter` uebergibt
systemd beim ersten Start von selbst an den neuen Nutzer.

In der ntfy-App `https://push.bitdm.net` als Server und das Thema aus
`/etc/bitdm/waechter.env` abonnieren.
