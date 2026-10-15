# Notizzettel

Native Notizen-App für iPhone und iPad mit SwiftUI und PencilKit. Diese zur Veröffentlichung vorbereitete Variante enthält keine KI-Chat-Funktion.

## Funktionen

- Mehrseitige handschriftliche Notizen mit Stiften, Radierer, Rückgängig/Wiederholen und Galerievorschau; automatische lokale Speicherung.
- Lokale Handschrifterkennung mit Apple Vision und Suche nach Handschrift, Aufgabentexten, Kunden und gespeicherten Termintiteln. Suchtreffer öffnen die passende Seite.
- Kästchen und handschriftliche Aufgaben erkennen, Texte korrigieren, Fälligkeit und optionale Alarme setzen. Erkennungsergebnisse können Fehler enthalten und lassen sich prüfen.
- Aufgaben nach Bestätigung oder optional automatisch an Apple Erinnerungen übertragen. Handschriftliches Abhaken und Ausradieren gleichen den Erledigt-Status ab. Wird ein verknüpftes Kästchen entfernt, wird die Erinnerung gelöscht; ein wiederhergestelltes Kästchen kann sie wiederherstellen. Beim Löschen einer ganzen Notiz bleiben Erinnerungen erhalten.
- Kundenordner mit Kalender- und Erinnerungslisten-Zuordnung. Optional neue Notizen anhand laufender oder in den nächsten 15 Minuten beginnender Termine zuordnen; gespeicherter Terminkontext bleibt ein historischer Stand.
- Optional aktivierbarer CloudKit-Abgleich von Notizen und Kundenorganisation zwischen Geräten mit demselben iCloud-Konto und App-Container.
- Export als mehrseitiges PDF und Markdown mit erkannten Texten in einen ausgewählten Obsidian- oder Archivordner.

## Voraussetzungen und Start

Das Deployment Target ist iOS/iPadOS 17. Das Projekt verwendet einen nativen `.icon`-App-Icon-Katalog; dafür ist Xcode 26 oder neuer erforderlich. Es gibt keine externen Paketabhängigkeiten. Das gemeinsame Scheme heißt **Notizen**.

1. `Notizen.xcodeproj` öffnen und Scheme **Notizen** auswählen.
2. Einen installierten iPhone- oder iPad-Simulator wählen und mit **⌘R** starten.
3. Für ein echtes Gerät eine eigene Signierung einrichten. CloudKit ist standardmäßig ausgeschaltet und kann nach Einrichtung eines eigenen Containers aktiviert werden.

### Eigene Signierung und CloudKit

`Config/Public.xcconfig` enthält generische Platzhalter und schaltet CloudKit mit `NOTIZEN_CLOUD_SYNC_ENABLED = NO` aus. Die App funktioniert damit lokal; für den Simulator ist keine persönliche Konfiguration nötig. Die öffentliche Variante verwendet keinen vorhandenen privaten CloudKit-Dienst. Persönliche Einstellungen kommen in eine ignorierte Datei:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

In `Config/Local.xcconfig` setzen:

```xcconfig
NOTIZEN_CLOUD_SYNC_ENABLED = YES
NOTIZEN_DEVELOPMENT_TEAM = YOUR_TEAM_ID
NOTIZEN_BUNDLE_IDENTIFIER = com.yourdomain.notizzettel
NOTIZEN_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.yourdomain.notizzettel
```

Zum Aktivieren von CloudKit im eigenen Apple-Developer-Team eine passende App-ID und einen CloudKit-Container registrieren und der App zuordnen. Erst nach diesem Setup `NOTIZEN_CLOUD_SYNC_ENABLED = YES` setzen; für rein lokale Builds bleibt der Wert `NO`. Die App benötigt iCloud/CloudKit und Push Notifications in ihrem Provisioning Profile. Xcode verwendet automatische Signierung. Die Test-Bundle-ID wird aus der App-ID mit dem Suffix `.Tests` abgeleitet. Alternativ lassen sich diese Variablen beim `xcodebuild`-Aufruf überschreiben.

Die Entitlements übernehmen den konfigurierten Container. CloudKit verwendet dessen private Datenbank und die Zone `Notizen`; die Datensätze heißen `Organization`, `Note` und `Page`. Für Entwicklung und Produktion existieren getrennte CloudKit-Umgebungen; welche verwendet wird, bestimmt die Signierung/Provisionierung. Vor einer Release-Verteilung muss das erzeugte CloudKit-Schema aus der Entwicklungsumgebung in die Produktionsumgebung übernommen werden.

Nur bei aktivierter Build-Option wird CloudKit beim App-Start und beim Aktivieren der App angesprochen. Mit den Platzhaltern ist kein funktionierender Cloud-Abgleich eingerichtet. Lokale Notizen werden unabhängig von einem erfolgreichen iCloud-Abgleich gespeichert; Synchronisierungsfehler erscheinen in der App. Simulator-Builds benötigen keine persönliche Signierung, prüfen aber keinen funktionierenden geräteübergreifenden Abgleich.

## Integrationen und Daten

**Apple Erinnerungen:** Unter **Einstellungen → Erinnerungen** Zugriff erlauben und eine beschreibbare Liste auswählen. Kunden können eigene Standardlisten besitzen; eine Notiz kann diese Auswahl überschreiben. Bereits verknüpfte Erinnerungen behalten ihre Liste. Die Integration schreibt und löscht Erinnerungen entsprechend den Aufgabenaktionen; das Konto der ausgewählten Liste bestimmt deren weitere Synchronisierung.

**Kalender:** Unter **Einstellungen → Kalender** Zugriff erlauben und unter **Kunden → Kunden verwalten** Kalender zuordnen. Die App liest Kalender, verändert sie aber nicht. iOS verlangt dafür Kalender-Vollzugriff. Die automatische Zuordnung ist optional.

**Obsidian/Archiv:** Unter **Einstellungen → Obsidian** einen über die Dateien-App erreichbaren Ordner wählen. Exporte liegen unter `<Kunde>/<ISO-Jahr>/KW NN` beziehungsweise ohne Kunden direkt unter `<ISO-Jahr>/KW NN`. Maßgeblich ist das Erstellungsdatum in der Zeitzone `Europe/Berlin`. Änderungen ersetzen das generierte PDF-/Markdown-Dateipaar; manuelle Änderungen am generierten Markdown werden überschrieben. Bereits exportierte Dateien bleiben beim Löschen der Notiz erhalten. Der ausgewählte Dateianbieter bestimmt, ob und wohin diese Dateien synchronisiert werden.

**Lokale Daten und Datenschutz:** Zeichnungen, Vorschaubilder, erkannte Aufgaben und Kundenorganisation liegen in `Application Support/Notizen` im App-Container. Der lokale Suchindex heißt `SearchIndex.json`. Handschrifterkennung und Suche laufen auf dem Gerät. Wenn aktiviert, überträgt CloudKit Zeichnungen, Aufgabeninformationen und Organisation in den konfigurierten iCloud-Container; Erinnerungsverknüpfungen und ausstehende EventKit-Aufträge bleiben gerätebezogen. Die App bindet keinen externen KI-Dienst ein. Vor einer Deinstallation wichtige Daten exportieren: iOS entfernt dabei die lokalen App-Daten.

## Bauen und testen

Aus dem Repository-Verzeichnis, mit ausgewählter Xcode-Installation:

```sh
xcodebuild -project Notizen.xcodeproj -scheme Notizen \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build

xcrun simctl list devices available
```

Für Tests eine dort angezeigte Simulator-UDID einsetzen:

```sh
xcodebuild -project Notizen.xcodeproj -scheme Notizen \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO test
```

Alternativ in Xcode **Product → Test (⌘U)**. Die Tests decken unter anderem Erkennung, Persistenz, Suche, Aufgaben-/Erinnerungsabgleich, Kalenderzuordnung und Export ab. EventKit-Integrationstests laufen nur im Simulator und werden ohne erteilten Zugriff beziehungsweise ohne lokale EventKit-Quelle übersprungen. Sie erzeugen temporäre Kalender/Erinnerungslisten und räumen sie anschließend auf. Ein erfolgreicher Testlauf mit übersprungenen Integrationstests bestätigt diese Integration nicht.

## Aufbau

- `Notizen/NotizenApp.swift`: App-Einstieg und gemeinsame Services.
- `Notizen/GalleryView.swift`, `NoteEditorView.swift`, `SettingsView.swift`: Übersicht, Zeichenfläche und Einstellungen.
- `Notizen/NoteStore.swift`: lokale Notizen, Seiten, Organisation und Suchindex.
- `Notizen/CloudSyncCoordinator.swift`: CloudKit-Abgleich.
- `Notizen/ReminderService.swift`, `CalendarService.swift`: EventKit-Integrationen.
- `Notizen/ObsidianExportService.swift`: PDF-/Markdown-Archiv.
- `NotizenTests/`: automatisierte Tests und Erkennungs-Fixtures.

Beiträge sollten bestehende Datenformate und Erinnerungsverknüpfungen erhalten. Persönliche Signierungsdateien, echte Notizinhalte und Build-Artefakte gehören nicht ins Repository. Hinweise zum Arbeitsablauf stehen in `AGENTS.md`.

## Veröffentlichung vorbereiten

Die Lizenzentscheidung ist noch offen; eine Open-Source-Lizenz ist noch nicht erteilt. Vor Veröffentlichung muss das SF-Symbol-basierte App-Icon durch eine eigenständige Grafik ersetzt werden: [Apples Richtlinien zu SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols) untersagen deren Verwendung in App-Icons. Die Gestaltung des Ersatzes steht noch aus. Die Handschrift-Fixtures wurden am 15. Oktober 2026 visuell geprüft und enthalten harmlose Testinhalte.
