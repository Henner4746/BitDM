# SonarQube Cloud und Snyk einrichten

Stand 18.10.2026. Die Workflows liegen in `.github/workflows/sonar.yml` und
`.github/workflows/snyk.yml`, die Sonar-Einstellungen in
`sonar-project.properties`. Beide laufen bei jedem Push auf `main` und bei
jedem Pull-Request; Snyk zusätzlich jeden Donnerstag. Solange die Tokens
fehlen, überspringen sie sich selbst mit einem Hinweis und werden nicht rot.

## Was die beiden prüfen

| | SonarQube Cloud | Snyk |
|---|---|---|
| App (Dart) | Code: Fehler, Sicherheitslücken, Wartbarkeit | nur die Pakete, über eine Stückliste (bei Snyk noch „experimentell“) |
| Relay (Python) | Code | Pakete aus `requirements.txt`, voll |
| Android (Kotlin) | Code | Code |
| Web-Hülle, Seite (JavaScript, HTML) | Code | Code |
| Windows/Linux-Starter (C++) | aus, bräuchte einen Build-Wrapper | nicht dabei |

Die Codeprüfung für Dart gibt es bei Snyk nur im Enterprise-Plan. Für den
Dart-Code ist deshalb Sonar zuständig, für bekannte Lücken in Fremdpaketen
Snyk.

**Kein Audit.** Beide sind automatische Scanner. Ein unabhängiges
Sicherheitsaudit ersetzen sie nicht, und auf der Website und im README bleibt
„kein unabhängiges Audit“ stehen. Ehrlich formuliert wäre: „Jeder Push wird
automatisch mit SonarQube Cloud und Snyk geprüft.“ Nicht: „von Snyk geprüft“
oder „Sonar-zertifiziert“.

## 1. SonarQube Cloud

1. Öffne <https://sonarcloud.io> und wähle **Log in → GitHub**. Erlaube den
   Zugriff für dein Konto `Henner4746`.
2. Lege eine Organisation an: **+ → Create new organization → Import from
   GitHub**. Wähle dein Konto `Henner4746`. Bei der Frage, auf welche Repos
   die GitHub-App von SonarQube Cloud zugreifen darf, nimm **Only select
   repositories → BitDM**.
3. Wähle den **Free**-Plan (für öffentliche Repos kostenlos).
4. **Analyze new project → BitDM → Set up.** Bei der Analysemethode
   **With GitHub Actions** wählen, **nicht** „Automatic Analysis“.
   Falls „Automatic Analysis“ schon an ist: *Project → Administration →
   Analysis Method* → ausschalten. Sonst lehnt SonarQube Cloud den Lauf aus
   GitHub ab.
5. SonarQube Cloud zeigt jetzt einen Wert für **`SONAR_TOKEN`**. Kopiere ihn
   (er erscheint nur einmal; sonst unter *My Account → Security → Generate
   Tokens* neu erzeugen).
6. Vergleiche unter *Project → Information* die **Organization Key** und den
   **Project Key** mit den ersten Zeilen von `sonar-project.properties`
   (`henner4746` und `Henner4746_BitDM`). Steht dort etwas anderes, sag
   Claude die beiden Werte, dann wird die Datei angepasst.

## 2. Snyk

1. Öffne <https://app.snyk.io/login> und melde dich mit **GitHub** an.
2. Den Import des Repos über die Snyk-Oberfläche brauchst du **nicht**; der
   Workflow meldet das Relay-Projekt selbst an (`snyk monitor`).
3. Hol dir dein Token: Klick unten links auf dein Profil → **Account
   settings**. Je nach Oberfläche heißt es **Auth Token** („click to show“)
   oder unter **Personal access tokens → Generate**. Kopiere den Wert.

## 3. Beide Tokens bei GitHub hinterlegen

1. Öffne <https://github.com/Henner4746/BitDM/settings/secrets/actions>.
2. **New repository secret**: Name `SONAR_TOKEN`, Wert aus Schritt 1.5.
3. **New repository secret**: Name `SNYK_TOKEN`, Wert aus Schritt 2.3.

Die Werte gehören nirgends sonst hin: nicht in den Chat, nicht in eine Datei
im Repo. GitHub zeigt sie danach niemandem mehr an, auch dir nicht.

## 4. Erster Lauf

Sobald der Zweig `ci/sonar-snyk` auf `main` ist:

1. <https://github.com/Henner4746/BitDM/actions> → **SonarQube Cloud** → **Run
   workflow**, dasselbe für **Snyk**.
2. Ergebnisse:
   - Sonar: <https://sonarcloud.io/project/overview?id=Henner4746_BitDM>
   - Snyk: <https://app.snyk.io> (Projekt `bitdm-relay`) und im Repo unter
     **Security → Code scanning**
3. Beim ersten Mal ist mit vielen Befunden zu rechnen, vor allem bei Sonar
   (Wartbarkeit, lange Dateien). Wichtig sind zuerst die mit „Security“,
   „Vulnerability“ oder „Security Hotspot“.

## Wann ein Lauf rot wird

- **SonarQube Cloud:** wenn die Analyse selbst scheitert. Ob auch das
  Quality Gate („Sonar way“) den Lauf rot macht, stellst du in SonarQube
  Cloud ein; ab Werk wird es nur angezeigt.
- **Snyk:** nur bei einer bekannten Lücke ab „high“ in den Python-Paketen des
  Relays. Codeprüfung und Dart-Stückliste melden und laden hoch, halten aber
  nichts auf (`|| true` in `snyk.yml`), weil die Codeprüfung Fehlalarme kennt
  und die Stückliste bei Snyk noch experimentell ist.

## Pflege

- Die Aktionen sind auf Commits gepinnt (wie alle Workflows hier, siehe
  Scorecard), die Snyk-CLI auf eine Fassung (`snyk-version`). Beim
  Hochziehen beides gemeinsam ändern.
- Die Dart-Stückliste schreibt `secure-messenger/app/tool/sbom_pub.py` aus
  `pubspec.lock` (nur Pakete von pub.dev; SDK-Pakete wie `flutter` haben
  keine pub-Fassung und werden gezählt, nicht verschwiegen). Kein weiteres
  Fremdpaket im Prüfschritt.
