# Sicherheit / Security

## Eine Schwachstelle melden

**Bitte nicht als öffentliches Issue.** Zwei Wege, beide vertraulich:

1. **GitHub:** [Schwachstelle privat melden](https://github.com/Henner4746/BitDM/security/advisories/new)
   (Reiter *Security* → *Report a vulnerability*).
2. **E-Mail:** kontakt@bitdm.net

Hilfreich sind: betroffene Fassung (Einstellungen → Über), Plattform, Schritte
zum Nachvollziehen und was ein Angreifer damit erreicht. Eine Antwort kommt
innerhalb von 7 Tagen. Wir beheben, veröffentlichen eine neue Fassung und
nennen dich danach im Changelog, wenn du das möchtest.

## Report a vulnerability

**Please do not open a public issue.** Use GitHub's
[private vulnerability reporting](https://github.com/Henner4746/BitDM/security/advisories/new)
or write to kontakt@bitdm.net. You will get an answer within 7 days; we fix,
release, and credit you in the changelog if you wish.

## Unterstützte Fassungen / Supported versions

Nur die jeweils neueste Fassung von
[GitHub Releases](https://github.com/Henner4746/BitDM/releases) bekommt
Sicherheitskorrekturen. / Only the latest release receives security fixes.

## Im Umfang / In scope

- Die App (Android, Windows, Linux, Web unter bitdm.net/app/) — `secure-messenger/app`
- Relay und Zwischenlager — `secure-messenger/server`
- Die Auslieferung unter bitdm.net, relay.bitdm.net und dem Onion-Dienst des Relays

Besonders interessiert uns alles, was dem **Bedrohungsmodell** widerspricht:
Inhalt lesbar für den Relay, Adressen fälschbar, Metadaten, die über das in der
Datenschutzerklärung Genannte hinausgehen, Umgehung der App-Sperre, der
Fernlöschung oder der Einmal-Ansicht.

## Nicht im Umfang / Out of scope

- Denial of Service durch reine Last gegen die öffentlichen Server
- Fehlende Kopfzeilen ohne nachweisbare Auswirkung
- Angriffe, die ein entsperrtes Gerät in fremder Hand voraussetzen
- Social Engineering, physische Angriffe auf Infrastruktur

## Stand der Prüfung / Audit status

**Kein externes Sicherheitsaudit.** Eigene Prüfungen und die gefundenen
Befunde stehen unter [`secure-messenger/docs/`](secure-messenger/docs/);
was sich um ein unabhängiges Audit bemüht, steht in
[`secure-messenger/docs/AUDIT.md`](secure-messenger/docs/AUDIT.md).
