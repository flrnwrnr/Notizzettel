# Notizzettel

**Handschrift festhalten. Aufgaben erkennen. In Apple Erinnerungen weiterarbeiten.**

Notizzettel ist eine native Notizen-App für iPhone und iPad. Mehrseitige Zeichenflächen verbinden handschriftliche Notizen mit erkannten Aufgaben, Fälligkeiten und Kundenordnern. SwiftUI, PencilKit, Apple Vision und EventKit bilden die Grundlage; Handschrifterkennung und Suche laufen auf dem Gerät.

## Funktionen

- **Handschriftliche Notizen:** mehrere Seiten, Stifte, Radierer, Rückgängig/Wiederholen, Galerievorschau und automatische lokale Speicherung.
- **Aufgaben aus Handschrift:** Kästchen und Aufgabentexte erkennen, Ergebnisse prüfen und korrigieren sowie Fälligkeiten und optionale Alarme setzen.
- **Apple Erinnerungen:** Aufgaben nach Bestätigung oder optional automatisch übertragen; handschriftliches Abhaken und Ausradieren gleichen den Erledigt-Status ab.
- **Suche:** Handschrift, Aufgaben, Kunden und gespeicherte Termintitel durchsuchen; Treffer öffnen die passende Notizseite.
- **Kunden und Termine:** Ordner mit Kalendern und Erinnerungslisten verknüpfen und neue Notizen optional anhand passender Termine zuordnen.
- **Export und Synchronisierung:** mehrseitige PDFs und Markdown für Obsidian oder einen Archivordner; optionaler CloudKit-Abgleich zwischen eigenen Geräten.

## Schnellstart

Die App setzt **iOS/iPadOS 17** voraus. Build und Simulator-Tests wurden mit **Xcode 27.1** geprüft. Das Projekt verwendet einen nativen `.icon`-App-Icon-Katalog und hat keine externen Paketabhängigkeiten; das gemeinsame Scheme heißt **Notizen**.

1. `Notizen.xcodeproj` in Xcode öffnen.
2. Scheme **Notizen** und einen installierten iPhone- oder iPad-Simulator auswählen.
3. Mit **⌘R** starten.

Die [öffentliche Konfiguration](Config/Public.xcconfig) deaktiviert CloudKit. Für den Simulator ist keine persönliche Konfiguration nötig. Falls bereits eine `Config/Local.xcconfig` existiert, dort für den Simulator `NOTIZEN_CLOUD_SYNC_ENABLED = NO` setzen. Die untenstehenden CLI-Befehle überschreiben diese Option ausdrücklich.

## Integrationen einrichten

### Apple Erinnerungen

Unter **Einstellungen → Erinnerungen** Zugriff erlauben und eine beschreibbare Liste auswählen. Kunden können eigene Standardlisten besitzen; einzelne Notizen können diese Auswahl überschreiben. Bereits verknüpfte Erinnerungen behalten ihre Liste.

Wird ein verknüpftes Kästchen entfernt, löscht die App die Erinnerung; ein wiederhergestelltes Kästchen kann sie wiederherstellen. Beim Löschen einer ganzen Notiz bleiben ihre Erinnerungen erhalten. Die weitere Synchronisierung bestimmt das Konto der gewählten Erinnerungsliste.

### Kalender und Kunden

Unter **Einstellungen → Kalender** Zugriff erlauben und unter **Kunden → Kunden verwalten** Kalender zuordnen. Die App liest Kalender, verändert sie aber nicht; iOS verlangt dafür Kalender-Vollzugriff.

Die optionale automatische Zuordnung berücksichtigt laufende Termine und, wenn kein passender Termin läuft, Termine mit Beginn innerhalb der nächsten **15 Minuten**. Ganztagstermine und Titel mit **„Blocker“** sind ausgeschlossen. Gespeicherter Terminkontext bleibt ein historischer Stand.

### Obsidian und Archiv

Unter **Einstellungen → Obsidian** einen über die Dateien-App erreichbaren Ordner wählen. Der Export erzeugt pro Notiz ein PDF und eine Markdown-Datei mit erkannten Texten.

Die Ablage folgt `<Kunde>/<ISO-Jahr>/KW NN`, ohne Kundenzuordnung `<ISO-Jahr>/KW NN`. Maßgeblich ist das Erstellungsdatum in **Europe/Berlin**. Aktualisierungen ersetzen das generierte Dateipaar und überschreiben manuelle Änderungen am Markdown. Beim Löschen einer Notiz bleiben bereits exportierte Dateien erhalten. Der gewählte Dateianbieter bestimmt deren weitere Synchronisierung.

### Eigene Signierung und CloudKit

Für Gerätebuilds eigene Kennungen und Signierung einrichten. Persönliche Werte gehören ausschließlich in die ignorierte lokale Konfiguration:

```sh
cp -n Config/Local.xcconfig.example Config/Local.xcconfig
```

```xcconfig
NOTIZEN_CLOUD_SYNC_ENABLED = NO
NOTIZEN_DEVELOPMENT_TEAM = YOUR_TEAM_ID
NOTIZEN_BUNDLE_IDENTIFIER = com.yourdomain.notizzettel
NOTIZEN_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.yourdomain.notizzettel
```

Xcode verwendet automatische Signierung; die Test-Bundle-ID erhält das Suffix `.Tests`. Die Geräte-Entitlements enthalten **iCloud/CloudKit und Push Notifications auch bei deaktiviertem Cloud-Abgleich**. Das Provisioning Profile muss diese Capabilities unterstützen.

Für Synchronisierung eine passende App-ID und einen eigenen CloudKit-Container im Apple-Developer-Team registrieren und zuordnen. Anschließend `NOTIZEN_CLOUD_SYNC_ENABLED = YES` setzen. Die App verwendet die private Datenbank, die Zone `Notizen` und die Record-Typen `Organization`, `Note` und `Page`. Vor einer Release-Verteilung das CloudKit-Schema aus der Entwicklungs- in die Produktionsumgebung übernehmen; die verwendete Umgebung bestimmt die Signierung/Provisionierung.

Der Abgleich wird beim App-Start und beim Aktivieren der App angestoßen. Lokale Speicherung funktioniert unabhängig davon; Synchronisierungsfehler erscheinen in der App. Ein Simulator-Build bestätigt keinen geräteübergreifenden Cloud-Abgleich.

## Daten und Erkennung

Zeichnungen, Vorschaubilder, erkannte Aufgaben und Kundenorganisation liegen unter `Application Support/Notizen` im App-Container; der Suchindex heißt `SearchIndex.json`. Die App bindet keinen externen KI-Dienst ein. Bei aktiviertem CloudKit-Abgleich werden Zeichnungen, Aufgabeninformationen und Organisation im eigenen iCloud-Container synchronisiert. Erinnerungsverknüpfungen und ausstehende EventKit-Aufträge bleiben gerätebezogen.

Die Oberfläche und die Erkennung natürlicher Fälligkeitsangaben sind auf Deutsch ausgerichtet. Apple Vision verwendet Deutsch und Englisch für die Texterkennung. Erkennungsergebnisse können fehlerhaft sein und lassen sich prüfen und korrigieren. Vor einer Deinstallation wichtige Notizen exportieren: iOS entfernt dabei die lokalen App-Daten.

## Bauen und testen

Im Repository-Verzeichnis mit ausgewählter Xcode-Installation:

```sh
xcodebuild -project Notizen.xcodeproj -scheme Notizen \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO NOTIZEN_CLOUD_SYNC_ENABLED=NO build
```

Verfügbare Simulatoren mit `xcrun simctl list devices available` anzeigen und eine UDID für den Testlauf einsetzen:

```sh
xcodebuild -project Notizen.xcodeproj -scheme Notizen \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UDID' \
  -derivedDataPath build/DerivedData -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO NOTIZEN_CLOUD_SYNC_ENABLED=NO test
```

Alternativ in Xcode **Product → Test (⌘U)** ausführen. Die Tests umfassen Erkennung, Persistenz, Suche, Aufgaben-/Erinnerungsabgleich, Kalenderzuordnung und Export. EventKit-Integrationstests laufen im Simulator, erzeugen temporäre Kalender und Erinnerungslisten und räumen sie anschließend auf. Ohne Berechtigung oder lokale EventKit-Quelle werden sie übersprungen; ein solcher Lauf bestätigt die Integration nicht.

## Projektstruktur

| Bereich | Einstieg |
| --- | --- |
| App und Oberfläche | [NotizenApp.swift](Notizen/NotizenApp.swift), [GalleryView.swift](Notizen/GalleryView.swift), [NoteEditorView.swift](Notizen/NoteEditorView.swift) |
| Speicherung und Suche | [NoteStore.swift](Notizen/NoteStore.swift), [NoteSearchIndex.swift](Notizen/NoteSearchIndex.swift) |
| Handschrift und Aufgaben | [TaskRecognitionEngine.swift](Notizen/TaskRecognitionEngine.swift), [TaskRecognitionSession.swift](Notizen/TaskRecognitionSession.swift) |
| Erinnerungen und Kalender | [ReminderService.swift](Notizen/ReminderService.swift), [CalendarService.swift](Notizen/CalendarService.swift) |
| CloudKit und Export | [CloudSyncCoordinator.swift](Notizen/CloudSyncCoordinator.swift), [ObsidianExportService.swift](Notizen/ObsidianExportService.swift) |
| Tests | [NotizenTests/](NotizenTests/) |

## Beiträge

Fehlerberichte sollten die Schritte zur Reproduktion und die verwendeten iOS-/Xcode-Versionen enthalten. Änderungen an Speicherung, Erkennung oder Synchronisierung mit gezielten Regressionstests absichern und bestehende Datenformate sowie Erinnerungsverknüpfungen erhalten. Persönliche Signierungsdateien, echte Notizinhalte und Build-Artefakte gehören nicht ins Repository. Weitere Hinweise stehen in [AGENTS.md](AGENTS.md).

## Lizenz

Die Lizenz wird vor Veröffentlichung festgelegt. Bis dahin ist keine Open-Source-Lizenz erteilt.
