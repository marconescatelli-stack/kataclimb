# DEBITO-190 · Contatori derivati

Oggi ogni lezione vive in tre numeri che si contraddicono: `iscrizioni_corso.lezioni_completate`,
i contatori salvati in `profile_data` (`*_lezioni_residue`, `*_no_show_count`, `*_spostamenti_residui`)
e le prenotazioni future. I contatori salvati sono ritoccati con `+4` / `−1` da 40 funzioni e da
due trigger: basta un pagamento registrato dopo le lezioni e restano storti.

Il 14 luglio `lezioni_completate` è diventato un COUNT assoluto e da allora non si è più rotto.
Qui si fa lo stesso a residui, no-show e spostamenti: **una tabella sola, `prenotazioni_corso`,
e tutto il resto è un COUNT. Nessuna funzione scrive mai un contatore.**

## Come si leggono i cinque stati

La tabella `prenotazioni_corso` ha cinque stati reali e **non si normalizzano**: la mappatura
vive solo dentro la view.

| stato a DB | significato | consuma la lezione? | conta nel budget spostamenti? |
|---|---|---|---|
| `presente` | fatta | sì | no |
| `assente` | ghostata (no-show) | sì | no |
| `cancellato_tardi` | disdetta fuori tempo | sì | no |
| `cancellato_in_tempo` | spostata in tempo | no | sì |
| `prenotato` | in agenda (futura) | non ancora | no |

Da cui: `consumate = presente + assente + cancellato_tardi` · `restano = pagate − consumate` ·
`prenotabili ora = restano − già in agenda`.

## Ordine di applicazione

I file si applicano **uno alla volta**, verificando dopo ciascuno. Nessuno di questi file va
eseguito da Claude Code: li applica Marco da chat dopo revisione.

| # | File | Scrive dati? | Quando |
|---|---|---|---|
| 01 | `01_view_contatori_corso.sql` | no — crea view + funzione | subito |
| 02 | `02_audit_scarti.sql` | no — sole SELECT | subito dopo il 01 |
| 03 | `03_rpc_senza_contatori.sql` | sì, riscrive 40 funzioni | Fase B, dopo che il 02 torna pulito |
| 04 | `04_bonifica.sql` | sì, sistema i dati storti | Fase D |
| 05 | `05_drop_colonne.sql` | sì, ritira le colonne | Fase D, **non prima di una settimana** di Fase C in produzione senza incidenti |

Stato oggi: **01 e 02 pronti**. Dal 03 in poi non ancora scritti.

### Dopo il 01 — cosa verificare
In fondo al file ci sono tre query pronte, `V1`, `V2`, `V3`.

- **V1** — i numeri della view quadrano fra loro. Atteso: `restano_incoerenti`,
  `prenotabili_incoerenti` e `senza_persona_id` a **0**. `restano_negativi` può essere maggiore
  di zero: sono i dati storti, li elenca il 02.
- **V2** — il conteggio degli spostamenti non è filtrato sulla finestra di validità, perché il
  21 set le due cose davano lo stesso numero. Atteso: **0**. Se un giorno diventa maggiore di
  zero, il conteggio va scopato alla finestra e la view va corretta.
- **V3** — `get_contatori` risponde: `[]` per un utente inesistente, un array per uno reale.

### Dopo il 02 — cosa verificare
Il file produce quattro elenchi, tutti in righe leggibili senza conoscere il DB.

- **Sezione 1 · iscrizioni attive.** Atteso il 21 set: **18 righe esaminate, 16 a posto, 2 fuori posto** —
  Baldina Yulia Intro Corda `+4`, Baldassarini Chiara Intro Corda `−2`.
  **Se compaiono righe diverse da queste due, fermarsi**: vuol dire che la view non descrive il
  modello che abbiamo in testa, e la Fase B partirebbe da una base sbagliata.
- **Sezione 2 · crediti orfani.** Lezioni che il DB dice ancora disponibili su percorsi chiusi o
  mai aperti. Atteso: **11 righe, 10 allievi**. Non è il caso isolato di Baldina: sono crediti che
  nessuna iscrizione attiva giustifica e che nessun controllo vede oggi. Si azzerano in Fase D.
- **Sezione 3 · iscrizioni attive con 0 lezioni pagate.** Atteso: **3 righe**, tutte di tipi che
  non hanno prenotazioni a calendario (Fly, Lezioni Speciali). Se ne comparisse una di Open,
  Advance, Intro Corda o Evo Corda, la riga lo dice a voce alta: va guardata per prima.
- **Sezione 4 · promemoria.** `lezioni_iniziali_residue` è valorizzata su 19 profili e non
  appartiene a nessuno dei 4 corsi: va censita prima del drop nel file 05.

## Decisioni prese, per non ridiscuterle

- **Si scala quando la lezione è fatta, non quando è prenotata.** Il contatore vecchio scalava
  alla prenotazione: per questo l'audit confronta il salvato con *prenotabili ora* e non con
  *restano*, altrimenti chiunque abbia una prenotazione aperta risulterebbe storto senza esserlo.
- **Mese 1 non saldato** → metà pacchetto, ma solo per Corso Advance, Intro Corda ed Evo Corda e
  solo quando `importo_concordato` è valorizzato. `importo_concordato` nullo si tratta come
  saldato: sono righe pregresse, si riempiono in Fase D. Il Corso Open non si tocca mai.
- **Le presenze si contano per (allievo, corso) senza filtro di data**, perché le iscrizioni
  retroattive hanno presenze precedenti alla data di inizio validità.
- **`restano` e `prenotabili` possono andare negativi** di proposito: limitarli a zero
  nasconderebbe all'audit proprio i dati che deve trovare. Le guardie delle RPC useranno
  `prenotabili > 0`.
- **Budget spostamenti** = `iscrizioni_corso.disdette_no_show_max` (2 di default), e conta solo
  `cancellato_in_tempo`. `tipi_corso_config.noshow_soglia_penalita` è un'altra cosa e resta dov'è.

## Cosa resta fuori da questa cartella

- Il Worker `stripe-worker` è un repo separato: censito, mai toccato.
- La tabella `presenze_corso` è **vuota** ma ha ancora attaccato il trigger
  `tg_presenze_lezioni_residue`. Si eliminano entrambi nel file 05, dopo il grep nel repo.
- Il trigger `trg_open_presenza_garantisce_corso` **resta**: in Fase B va riscritto togliendo le
  scritture sui contatori, deve solo garantire l'iscrizione al Corso Open.
- Le pagine da aggiornare in Fase C sono cinque: `portale.html`, `agenda.html`, `oggi.html`,
  `profilo.html` (il fascicolo) e `commerciale.html` (che chiama `get_cruscotto_percorsi`).
  `segreteria.html`, `fascicolo.html` e `cruscotto.html` non esistono come file.
