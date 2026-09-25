"""test_blob.py — das Zwischenlager fuer grosse Anhaenge.

Laeuft ohne Netz und ohne laufenden Server: FastAPI liefert einen Testclient,
der die App direkt anspricht. Anders als test_relay.py, wo der WebSocket-Weg
einen echten Socket braucht.

WAS HIER WIRKLICH GEPRUEFT WIRD, und warum es nicht selbstverstaendlich ist:

  * DIE MARKE HAENGT AN GROESSE UND KENNUNG. Haenge sie nur an der Kennung,
    und jeder mit einer Marke fuer eine 1-MB-Datei legt drei Gigabyte ab.
  * DIE ANGEKUENDIGTE GROESSE IST EINE BEHAUPTUNG. Wer weiterschickt, als er
    angesagt hat, muss beim Schreiben gestoppt werden — nicht danach, denn
    danach liegt es schon auf der Platte.
  * ABBRUECHE HINTERLASSEN NICHTS. Bei drei Gigabyte auf Mobilfunk ist der
    Abbruch der Normalfall, nicht die Ausnahme.

Start:
    py -m pytest server/test_blob.py -q
"""

import hashlib
import hmac
import importlib
import os
import re
import threading
import time

import pytest
from fastapi.testclient import TestClient

GEHEIMNIS = "x" * 48
KENNUNG = "a" * 52


@pytest.fixture()
def lager(tmp_path, monkeypatch):
    """Ein frisches Lager je Test.

    Die Module lesen ihre Einstellungen beim IMPORT — deshalb erst die Umgebung
    setzen, dann neu laden. Ohne das reload haenge alle Tests am Verzeichnis des
    ersten.
    """
    monkeypatch.setenv("BITDM_BLOB_DIR", str(tmp_path))
    monkeypatch.setenv("BITDM_BLOB_SECRET", GEHEIMNIS)
    monkeypatch.setenv("BITDM_BLOB_MAX", str(10 * 1024**2))
    # Sonst lehnt jeder Upload mit 507 ab, weil auf der Testmaschine keine
    # 50 GB frei sein muessen.
    monkeypatch.setenv("BITDM_BLOB_MIN_FREE", "0")
    import blob_server

    importlib.reload(blob_server)
    return tmp_path, blob_server


@pytest.fixture()
def client(lager):
    _, blob_server = lager
    return TestClient(blob_server.app)


def marke(kennung: str, groesse: int, ablauf: int, geheimnis: str = GEHEIMNIS) -> str:
    nachricht = f"{kennung}|{groesse}|{ablauf}".encode()
    return hmac.new(geheimnis.encode(), nachricht, hashlib.sha256).hexdigest()


def kopf(kennung: str, groesse: int, ablauf: int | None = None, **abweichung):
    """Die drei Kopfzeilen, die ein Upload braucht — standardmaessig stimmig."""
    ablauf = ablauf if ablauf is not None else int(time.time()) + 300
    return {
        "X-Bitdm-Size": str(abweichung.get("size", groesse)),
        "X-Bitdm-Expires": str(ablauf),
        "X-Bitdm-Token": abweichung.get(
            "token", marke(abweichung.get("kennung", kennung), groesse, ablauf)
        ),
    }


# --------------------------------------------------------------------------- #
#  Der Normalfall
# --------------------------------------------------------------------------- #

def test_ablegen_und_wieder_loeschen(client, lager):
    verzeichnis, _ = lager
    inhalt = b"verschluesselter Block" * 100

    antwort = client.put(
        f"/ablegen/{KENNUNG}", content=inhalt, headers=kopf(KENNUNG, len(inhalt))
    )

    assert antwort.status_code == 200, antwort.text
    assert antwort.json()["bytes"] == len(inhalt)
    assert (verzeichnis / KENNUNG).read_bytes() == inhalt

    # Loeschen braucht KEINE Marke: die Kennung kennen nur die beiden
    # Beteiligten, und wer sie hat, darf die Datei ohnehin lesen.
    assert client.delete(f"/wegwerfen/{KENNUNG}").status_code == 200
    assert not (verzeichnis / KENNUNG).exists()


def test_es_bleibt_kein_bruchstueck_liegen(client, lager):
    verzeichnis, _ = lager
    inhalt = b"." * 500

    client.put(f"/ablegen/{KENNUNG}", content=inhalt, headers=kopf(KENNUNG, len(inhalt)))

    assert list(verzeichnis.glob(".*")) == [], "die Nebendatei muss weg sein"


# --------------------------------------------------------------------------- #
#  Die Marke
# --------------------------------------------------------------------------- #

def test_ohne_marke_kein_upload(client):
    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 10)
    assert antwort.status_code == 422  # die Kopfzeilen fehlen


def test_fremde_marke_wird_abgelehnt(client, lager):
    verzeichnis, _ = lager
    inhalt = b"x" * 10
    fremd = kopf(KENNUNG, len(inhalt))
    fremd["X-Bitdm-Token"] = marke(KENNUNG, len(inhalt), int(time.time()) + 300, "y" * 48)

    antwort = client.put(f"/ablegen/{KENNUNG}", content=inhalt, headers=fremd)

    assert antwort.status_code == 403
    assert not (verzeichnis / KENNUNG).exists()


def test_DIE_GROESSE_STECKT_IN_DER_MARKE(client, lager):
    """Der Grund, warum die Groesse mitunterschrieben wird.

    Ohne sie holt sich jemand eine Marke fuer eine kleine Datei und legt damit
    drei Gigabyte ab. Der Dienst kann das nicht merken — er sieht nur eine
    gueltige Unterschrift.
    """
    verzeichnis, _ = lager
    echte_groesse = 5 * 1024**2
    # Marke fuer 100 Byte, angesagt werden 5 MB.
    ablauf = int(time.time()) + 300
    kopfzeilen = {
        "X-Bitdm-Size": str(echte_groesse),
        "X-Bitdm-Expires": str(ablauf),
        "X-Bitdm-Token": marke(KENNUNG, 100, ablauf),
    }

    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 100, headers=kopfzeilen)

    assert antwort.status_code == 403
    assert not (verzeichnis / KENNUNG).exists()


def test_DIE_KENNUNG_STECKT_IN_DER_MARKE(client, lager):
    """Sonst liesse sich eine Marke beliebig oft fuer neue Dateien benutzen."""
    verzeichnis, _ = lager
    andere = "b" * 52
    inhalt = b"x" * 10

    antwort = client.put(
        f"/ablegen/{andere}", content=inhalt, headers=kopf(KENNUNG, len(inhalt))
    )

    assert antwort.status_code == 403
    assert not (verzeichnis / andere).exists()


def test_abgelaufene_marke(client):
    inhalt = b"x" * 10
    antwort = client.put(
        f"/ablegen/{KENNUNG}",
        content=inhalt,
        headers=kopf(KENNUNG, len(inhalt), ablauf=int(time.time()) - 1),
    )
    assert antwort.status_code == 403


def test_ablauf_laesst_sich_nicht_nachtraeglich_verlaengern(client):
    """Der Ablauf steht mit in der Unterschrift.

    Stuende er nur in der Kopfzeile, koennte der Client eine alte Marke mit
    einem neuen Datum weiterbenutzen — und die Frist waere keine.
    """
    inhalt = b"x" * 10
    alt = int(time.time()) - 1
    kopfzeilen = {
        "X-Bitdm-Size": str(len(inhalt)),
        "X-Bitdm-Expires": str(int(time.time()) + 3600),  # geschoben
        "X-Bitdm-Token": marke(KENNUNG, len(inhalt), alt),  # fuer das alte
    }

    assert client.put(f"/ablegen/{KENNUNG}", content=inhalt, headers=kopfzeilen).status_code == 403


# --------------------------------------------------------------------------- #
#  Die angesagte Groesse ist eine Behauptung
# --------------------------------------------------------------------------- #

def test_MEHR_DATEN_ALS_ANGESAGT_wird_beim_schreiben_gestoppt(client, lager):
    verzeichnis, _ = lager
    ablauf = int(time.time()) + 300
    kopfzeilen = {
        "X-Bitdm-Size": "100",
        "X-Bitdm-Expires": str(ablauf),
        "X-Bitdm-Token": marke(KENNUNG, 100, ablauf),
    }

    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 5000, headers=kopfzeilen)

    assert antwort.status_code == 413
    assert not (verzeichnis / KENNUNG).exists()
    assert list(verzeichnis.glob(".*")) == [], "auch das Bruchstueck muss weg"


def test_weniger_daten_als_angesagt(client, lager):
    verzeichnis, _ = lager
    ablauf = int(time.time()) + 300
    kopfzeilen = {
        "X-Bitdm-Size": "5000",
        "X-Bitdm-Expires": str(ablauf),
        "X-Bitdm-Token": marke(KENNUNG, 5000, ablauf),
    }

    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 100, headers=kopfzeilen)

    assert antwort.status_code == 400
    assert not (verzeichnis / KENNUNG).exists()
    assert list(verzeichnis.glob(".*")) == []


def test_ueber_der_hoechstgroesse(client, lager):
    _, blob_server = lager
    zu_gross = blob_server.MAX_BYTES + 1
    ablauf = int(time.time()) + 300

    antwort = client.put(
        f"/ablegen/{KENNUNG}",
        content=b"",
        headers={
            "X-Bitdm-Size": str(zu_gross),
            "X-Bitdm-Expires": str(ablauf),
            "X-Bitdm-Token": marke(KENNUNG, zu_gross, ablauf),
        },
    )

    # Die Grenze zieht der Dienst, nicht die Marke: eine gueltige Marke fuer
    # 10 GB darf nicht 10 GB ablegen duerfen.
    assert antwort.status_code == 413


def test_groesse_null(client):
    ablauf = int(time.time()) + 300
    antwort = client.put(
        f"/ablegen/{KENNUNG}",
        content=b"",
        headers={
            "X-Bitdm-Size": "0",
            "X-Bitdm-Expires": str(ablauf),
            "X-Bitdm-Token": marke(KENNUNG, 0, ablauf),
        },
    )
    assert antwort.status_code == 413


# --------------------------------------------------------------------------- #
#  Kennungen
# --------------------------------------------------------------------------- #

@pytest.mark.parametrize(
    "schlecht",
    [
        "a" * 51,             # zu kurz
        "a" * 53,             # zu lang
        "A" * 52,             # Grossbuchstaben
        "a" * 51 + "1",       # 1 und 8 gibt es in Base32 nicht
        "../etc/passwd",      # der eigentliche Grund fuer das Muster
        "a" * 51 + "/",
    ],
)
def test_kennungen_ausserhalb_des_musters(client, schlecht):
    antwort = client.put(
        f"/ablegen/{schlecht}", content=b"x", headers=kopf(schlecht, 1)
    )
    # 400 vom Muster, 404 wenn der Pfad gar nicht erst zur Route passt — beides
    # heisst: nichts abgelegt.
    assert antwort.status_code in (400, 404)


def test_eine_vorhandene_datei_wird_nicht_ueberschrieben(client, lager):
    verzeichnis, _ = lager
    (verzeichnis / KENNUNG).write_bytes(b"gehoert jemand anderem")
    inhalt = b"x" * 10

    antwort = client.put(
        f"/ablegen/{KENNUNG}", content=inhalt, headers=kopf(KENNUNG, len(inhalt))
    )

    assert antwort.status_code == 409
    assert (verzeichnis / KENNUNG).read_bytes() == b"gehoert jemand anderem"


def test_loeschen_prueft_die_kennung_auch(client):
    assert client.delete("/wegwerfen/../etc/passwd").status_code in (400, 404)


# --------------------------------------------------------------------------- #
#  Die Kehrmaschine
# --------------------------------------------------------------------------- #

@pytest.fixture()
def kehrmaschine(tmp_path, monkeypatch):
    monkeypatch.setenv("BITDM_BLOB_DIR", str(tmp_path))
    import blob_kehrmaschine

    importlib.reload(blob_kehrmaschine)
    return tmp_path, blob_kehrmaschine


def altere(pfad, sekunden):
    """Setzt die Aenderungszeit zurueck."""
    alt = time.time() - sekunden
    os.utime(pfad, (alt, alt))


def test_alte_bloecke_verschwinden_frische_bleiben(kehrmaschine):
    verzeichnis, k = kehrmaschine
    alt = verzeichnis / ("a" * 52)
    frisch = verzeichnis / ("b" * 52)
    alt.write_bytes(b"x")
    frisch.write_bytes(b"x")
    altere(alt, k.TTL_SEKUNDEN + 60)

    k.kehre()

    assert not alt.exists()
    assert frisch.exists()


def test_LIEGENGEBLIEBENE_BRUCHSTUECKE_gehen_frueher(kehrmaschine):
    """Der Punkt, den man beim Bauen vergisst.

    Ein abgebrochener Upload hinterlaesst eine .teil-Datei. Der Dienst raeumt
    sie weg, wenn er den Abbruch mitbekommt — bei einem Absturz nicht. Ohne die
    kuerzere Frist laege ein halbes Gigabyte zwei Wochen herum, obwohl es
    niemand je anfordern kann.
    """
    verzeichnis, k = kehrmaschine
    bruch = verzeichnis / f".{'a' * 52}.teil"
    bruch.write_bytes(b"halb")
    altere(bruch, k.TEIL_TTL_SEKUNDEN + 60)

    assert k.TEIL_TTL_SEKUNDEN < k.TTL_SEKUNDEN
    k.kehre()
    assert not bruch.exists()


def test_ein_laufender_upload_wird_nicht_weggeraeumt(kehrmaschine):
    verzeichnis, k = kehrmaschine
    laufend = verzeichnis / f".{'a' * 52}.teil"
    laufend.write_bytes(b"gerade unterwegs")

    k.kehre()

    assert laufend.exists(), "sonst reisst die Kehrmaschine laufende Uploads ab"


def test_UNBEKANNTES_BLEIBT_LIEGEN(kehrmaschine):
    """Ein Aufraeumer, der alles loescht, was er nicht kennt, ist eine Waffe.

    Zeigt er versehentlich auf das falsche Verzeichnis, ist der Unterschied
    zwischen "meldet 0" und "loescht alles" genau diese Zeile.
    """
    verzeichnis, k = kehrmaschine
    fremd = verzeichnis / "wichtige-sicherung.tar"
    fremd.write_bytes(b"x")
    altere(fremd, k.TTL_SEKUNDEN * 10)

    uebrig = k.kehre()

    assert fremd.exists()
    assert uebrig == 1, "und es wird gemeldet, statt still uebergangen zu werden"


def test_verzeichnisse_werden_nicht_angefasst(kehrmaschine):
    verzeichnis, k = kehrmaschine
    unter = verzeichnis / ("a" * 52)
    unter.mkdir()
    altere(unter, k.TTL_SEKUNDEN * 10)

    k.kehre()

    assert unter.is_dir()


# --------------------------------------------------------------------------- #
#  Audit vom 25.09.2026
# --------------------------------------------------------------------------- #

def test_die_stueckgrenze_steht_ab_werk_bei_33_mib(tmp_path, monkeypatch):
    """Die 5 GiB waren die Dateigrenze der App und erlaubten einem einzelnen
    PUT, 5 GiB am Stueck zu schreiben. Die App laedt Stuecke zu 32 MiB."""
    monkeypatch.setenv("BITDM_BLOB_DIR", str(tmp_path))
    monkeypatch.setenv("BITDM_BLOB_SECRET", GEHEIMNIS)
    monkeypatch.delenv("BITDM_BLOB_MAX", raising=False)
    import blob_server

    importlib.reload(blob_server)
    assert blob_server.MAX_BYTES == 33 * 1024**2
    assert blob_server.MAX_BYTES > 32 * 1024**2 + 16, "ein echtes Stueck muss durchpassen"


def test_eine_marke_mit_fremden_zeichen_ist_403_und_kein_absturz(client):
    """compare_digest nimmt nur ASCII-str; "\\xe9" in der Kopfzeile warf
    TypeError, also 500 (proof_blob.py)."""
    ablauf = int(time.time()) + 300
    antwort = client.put(
        f"/ablegen/{KENNUNG}", content=b"x",
        headers={"X-Bitdm-Size": "1", "X-Bitdm-Expires": str(ablauf),
                 "X-Bitdm-Token": "\xe9".encode("latin-1")},
    )
    assert antwort.status_code == 403


def test_eine_kennung_mit_zeilenumbruch_ist_keine(client, lager):
    """`^...$` mit .match() nahm "<52 Zeichen>\\n" an — `$` passt vor einem
    letzten Zeilenumbruch."""
    verzeichnis, _ = lager
    mit_umbruch = KENNUNG + "\n"
    antwort = client.put(f"/ablegen/{KENNUNG}%0A", content=b"y",
                         headers=kopf(mit_umbruch, 1))
    assert antwort.status_code in (400, 404)
    assert list(verzeichnis.iterdir()) == []
    assert client.delete(f"/wegwerfen/{KENNUNG}%0A").status_code in (400, 404)


def test_eine_marke_gilt_nur_einmal(client, lager):
    """Ablegen, wegwerfen, mit derselben Marke noch einmal ablegen — das ging
    zwoelf Stunden lang beliebig oft."""
    verzeichnis, _ = lager
    kopfzeilen = kopf(KENNUNG, 3)
    assert client.put(f"/ablegen/{KENNUNG}", content=b"AAA", headers=kopfzeilen).status_code == 200
    assert client.delete(f"/wegwerfen/{KENNUNG}").status_code == 200
    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"BBB", headers=kopfzeilen)
    assert antwort.status_code == 409
    assert not (verzeichnis / KENNUNG).exists()


def test_ein_abgebrochener_upload_verbraucht_die_marke_nicht(client, lager):
    """Die Gegenprobe: wer wegen eines Funklochs neu ansetzt, darf das mit
    derselben Marke."""
    kopfzeilen = kopf(KENNUNG, 5000)
    assert client.put(f"/ablegen/{KENNUNG}", content=b"x" * 100,
                      headers=kopfzeilen).status_code == 400
    assert client.put(f"/ablegen/{KENNUNG}", content=b"x" * 5000,
                      headers=kopfzeilen).status_code == 200


def test_der_letzte_schritt_ueberschreibt_nie(lager):
    """Zwei gleichzeitige PUTs derselben Kennung schrieben frueher in DIESELBE
    Nebendatei, und die zweite Umbenennung ueberschrieb die erste Datei."""
    verzeichnis, blob_server = lager
    ziel = verzeichnis / KENNUNG
    ziel.write_bytes(b"der erste war schneller")
    nebendatei = verzeichnis / f".{KENNUNG}.0123456789abcdef.teil"
    nebendatei.write_bytes(b"der zweite")
    with pytest.raises(FileExistsError):
        blob_server._lege_endgueltig_ab(nebendatei, ziel)
    assert ziel.read_bytes() == b"der erste war schneller"


def test_jeder_upload_hat_seine_eigene_nebendatei(client, lager, monkeypatch):
    verzeichnis, blob_server = lager
    gesehen = []
    echt = blob_server._schreibe

    def merke(fd, stueck):
        gesehen.extend(p.name for p in verzeichnis.glob(".*.teil"))
        echt(fd, stueck)

    monkeypatch.setattr(blob_server, "_schreibe", merke)
    for kennung in ("c" * 52, "d" * 52):
        assert client.put(f"/ablegen/{kennung}", content=b"x" * 10,
                          headers=kopf(kennung, 10)).status_code == 200
    assert len(set(gesehen)) == 2
    assert all(re.fullmatch(r"\.[a-z2-7]{52}\.[0-9a-f]{16}\.teil", n) for n in gesehen)


def test_geschrieben_wird_im_thread_und_nicht_auf_dem_loop(client, monkeypatch, lager):
    _, blob_server = lager
    threads = []
    echt = blob_server._schreibe

    def merke(fd, stueck):
        threads.append(threading.current_thread().name)
        echt(fd, stueck)

    monkeypatch.setattr(blob_server, "_schreibe", merke)
    assert client.put(f"/ablegen/{KENNUNG}", content=b"x" * 10,
                      headers=kopf(KENNUNG, 10)).status_code == 200
    assert threads and all("AnyIO worker" in t for t in threads), threads


def test_laufende_uploads_zaehlen_beim_platz_mit(client, lager, monkeypatch):
    """freier_platz() sieht nur, was schon auf der Platte liegt. Gleichzeitige
    Uploads zaehlten denselben Platz jeder fuer sich."""
    _, blob_server = lager
    monkeypatch.setattr(blob_server, "MIN_FREI_BYTES", 1000)
    monkeypatch.setattr(blob_server, "freier_platz", lambda: 1000 + 100)
    monkeypatch.setattr(blob_server, "_reserviert", 50)   # ein anderer laeuft gerade
    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 60,
                         headers=kopf(KENNUNG, 60))
    assert antwort.status_code == 507

    monkeypatch.setattr(blob_server, "_reserviert", 0)
    antwort = client.put(f"/ablegen/{KENNUNG}", content=b"x" * 60,
                         headers=kopf(KENNUNG, 60))
    assert antwort.status_code == 200
    assert blob_server._reserviert == 0, "die Reservierung wurde nicht zurueckgegeben"


def test_die_reservierung_faellt_auch_beim_abbruch_zurueck(client, lager):
    _, blob_server = lager
    client.put(f"/ablegen/{KENNUNG}", content=b"x" * 5000, headers=kopf(KENNUNG, 100))
    client.put(f"/ablegen/{KENNUNG}", content=b"x" * 10, headers=kopf(KENNUNG, 100))
    assert blob_server._reserviert == 0


def test_pfade_bleiben_im_lager(lager):
    _, blob_server = lager
    for boese in ("../ausbruch", "..", "unter/ordner"):
        with pytest.raises(blob_server.HTTPException):
            blob_server.pfad_im_lager(boese)


def test_die_kehrmaschine_kennt_beide_namensformen_der_bruchstuecke(kehrmaschine):
    verzeichnis, k = kehrmaschine
    alt = verzeichnis / f".{'a' * 52}.teil"
    neu = verzeichnis / f".{'b' * 52}.0123456789abcdef.teil"
    for p in (alt, neu):
        p.write_bytes(b"halb")
        altere(p, k.TEIL_TTL_SEKUNDEN + 60)
    assert k.kehre() == 0
    assert not alt.exists() and not neu.exists()
    assert not k.KENNUNG_MUSTER.fullmatch("a" * 52 + "\n")
