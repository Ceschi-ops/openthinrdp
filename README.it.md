# OpenThinRDP

Un sistema operativo per thin client Desktop remoto Windows, basato su Debian 13 e FreeRDP 3.

Trasforma piccoli PC o vecchi thin client in postazioni che si accendono direttamente sul form di accesso, si
collegano tramite il broker RDS al desktop dell'utente e si gestiscono da una cartella condivisa: stato di ogni
postazione, configurazione centrale, aggiornamenti firmati. Niente agenti, niente server di gestione, niente cloud.

È nato da una migrazione reale da un sistema thin client commerciale, su un parco di Dell OptiPlex 3000 Thin
Client collegati a una VDI Windows 11 su Hyper-V; il sistema da cui deriva è in produzione lì ogni giorno.

> **Stato: alfa (0.1).** Il codice viene da un sistema in produzione, ma questa versione generica è nuova:
> provatela su una postazione prima di estenderla.

## Cosa fa

- **Form di accesso, poi desktop remoto a schermo intero**, avvio in pochi secondi con il vostro logo.
  Tentativi, broker di riserva, messaggi chiari per rete assente, broker irraggiungibile, macchina virtuale che
  non parte, password sbagliata (mai ritentata, così l'account non si blocca).
- **Si riconnette da solo** dopo le cadute di rete e avvisa prima di prendersi una sessione aperta su un'altra
  postazione.
- **USB pensato per la VDI**: webcam con microfono, chiavette di firma, chiavi tachigrafo e altri dispositivi
  particolari vanno a Windows interi, anche collegati a sessione aperta. Tastiere, mouse, touch, hub e schede
  di rete restano locali; i lettori di smart card passano dal canale smart card.
- **Cartella di gestione (SMB)**: ogni postazione scrive stato e registro eventi; si leggono con il gestore
  Windows (`management/windows`) o in un CSV. La configurazione per tutte o per una postazione sono file nella
  stessa cartella. Gli aggiornamenti sono firmati con la vostra chiave e si installano da soli, mai durante una
  sessione.
- **Configurazione sulla postazione** (anche protetta da PIN), orari di accensione e spegnimento,
  Wake-on-LAN, aggiornamenti di sicurezza Debian (FreeRDP escluso), pulsante web con Chromium (app, browser o
  pagina kiosk).
- **Trasporto UDP sperimentale** con una build di FreeRDP che lo supporta.
- Interfaccia in italiano e inglese.

## Avvio rapido

```
cp -r image/site.example image/site      # poi modificare site.conf, build.conf, aggiungere il logo
image/build.sh                           # Linux con Docker o Podman -> out/openthinrdp-<versione>.iso
```

Scrivere la ISO su una chiavetta e avviare il thin client: l'installazione automatica **cancella il primo
disco senza chiedere**. Al primo avvio si apre la configurazione.

La documentazione è in inglese nella cartella [docs](docs/).

## Contribuire

Issue e pull request sono benvenute, anche in italiano. I problemi di sicurezza vanno segnalati in privato,
vedi [SECURITY.md](SECURITY.md).

**Cercasi logo.** Quello attuale è provvisorio. Se sapete disegnarne uno migliore (splash di avvio e versione
piccola per le finestre), aprite una issue o una pull request: vi ringrazieremo qui.

## Licenza

Apache License 2.0, vedi [LICENSE](LICENSE).
