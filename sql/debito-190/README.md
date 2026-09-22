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
| 03b | `03b_omaggio.sql` | sì, aggiunge 4 colonne a `prenotazioni_corso` | **prima** del 03, e prima di ri-applicare il 01 |
| 01 bis | `01_view_contatori_corso.sql` (di nuovo) | no | subito dopo il 03b: la view legge le colonne nuove |
| 03 | `03_rpc_senza_contatori.sql` | sì, riscrive 40 funzioni | Fase B, dopo che il 02 torna pulito |
| 04 | `04_bonifica.sql` | sì, sistema i dati storti | Fase D |
| 05 | `05_drop_colonne.sql` | sì, ritira le colonne | Fase D, **non prima di una settimana** di Fase C in produzione senza incidenti |

Stato oggi: **01 e 02 applicati e verificati**. Il **03 è a metà**: contiene la parte che non dipende dal nodo aperto sul no-show (vedi sotto), e non va applicato finché non è completo.

### La regola del no-show (chiusa il 22 set)

Resta la regola del Modello Open: **servono N ghostate perché ne venga scalata una lezione**, dove
N è `tipi_corso_config.noshow_soglia_penalita` (oggi 2 su tutti e quattro i corsi). Mai un 2 scritto
a mano: se domani la penale cambia, cambia lì.

| ghostate | lezioni scalate |
|---|---|
| 1 | 0 |
| 2 | 1 |
| 3 | 1 |
| 4 | 2 |

Da cui: `consumate = presente + cancellato_tardi + (assente / soglia)`, divisione intera. Nessun
contatore da azzerare: il numero è sempre ricavato dal COUNT. Nella tabella degli stati qui sopra,
`assente` **non consuma da solo**.

### Dopo il 01 — cosa verificare
In fondo al file ci sono tre query pronte, `V1`, `V2`, `V3`.

- **V1** — i numeri della view quadrano fra loro. Atteso: `restano_incoerenti`,
  `prenotabili_incoerenti` e `senza_persona_id` a **0**. `restano_negativi` può essere maggiore
  di zero: sono i dati storti, li elenca il 02.
- **V2** — il conteggio degli spostamenti non è filtrato sulla finestra di validità, perché il
  21 set le due cose davano lo stesso numero. Atteso: **0**. Se un giorno diventa maggiore di
  zero, il conteggio va scopato alla finestra e la view va corretta.
- **V3** — `get_contatori` risponde: `[]` per un utente inesistente, un array per uno reale.

### Dopo il 03 — `V-firme`, la verifica che non va saltata

`CREATE OR REPLACE FUNCTION` sostituisce **solo a parità di firma**. Se la firma cambia, Postgres
crea una funzione nuova e **lascia in piedi la vecchia**: da quel momento ogni chiamata che potrebbe
risolvere su entrambe fallisce con `function ... is not unique`.

Non è un rischio teorico: è già successo a `staff_attiva_corso`, che a DB ha `(uuid,text)` e
`(uuid,text,boolean DEFAULT)`, e per cui **oggi una chiamata a due argomenti dà errore**.

Tre funzioni del 03 cambiano firma, e ognuna ha il suo `DROP FUNCTION IF EXISTS` subito prima del
`CREATE` — verificato confrontando una per una le 29 firme del file con `pg_proc`:

| Funzione | Prima | Dopo |
|---|---|---|
| `applica_no_show` | `(uuid)` | `(uuid, text)` |
| `prenota_corso_admin` | 4 argomenti | 5 (`p_omaggio_motivo`) |
| `staff_attiva_corso` | **due** firme | una sola, quella a 3 argomenti |

In fondo al 03 c'è la query `V-firme`: dopo l'applicazione ogni nome deve avere **un solo** overload,
e le quattro funzioni eliminate non devono comparire affatto. Nessun overload doppio è voluto.

### Dopo il 02 — cosa verificare
Il file produce quattro elenchi, tutti in righe leggibili senza conoscere il DB.

- **Sezione 1 · iscrizioni attive.** Atteso il 21 set: **18 righe esaminate, 16 a posto, 2 fuori posto** —
  Baldina Yulia Intro Corda `+4`, Baldassarini Chiara Intro Corda `−2`.
  **Se compaiono righe diverse da queste due, fermarsi**: vuol dire che la view non descrive il
  modello che abbiamo in testa, e la Fase B partirebbe da una base sbagliata.
- **Sezione 2 · crediti orfani.** Lezioni che il DB dice ancora disponibili su percorsi chiusi o
  mai aperti. Atteso: **12 righe su 10 allievi**. Non è il caso isolato di Baldina: sono crediti che
  nessuna iscrizione attiva giustifica e che nessun controllo vede oggi. Si azzerano in Fase D.
- **Sezione 3 · iscrizioni attive con 0 lezioni pagate.** Atteso: **3 righe**, tutte di tipi che
  non hanno prenotazioni a calendario (Fly, Lezioni Speciali). Se ne comparisse una di Open,
  Advance, Intro Corda o Evo Corda, la riga lo dice a voce alta: va guardata per prima.
- **Sezione 4 · promemoria.** `lezioni_iniziali_residue` è valorizzata su 19 profili e non
  appartiene a nessuno dei 4 corsi: va censita prima del drop nel file 05.

### La lezione omaggio

Fino al 22 settembre la lezione regalata viveva in una spunta dell'interfaccia: `agenda.html` mandava
`p_scala_credito: false` e la prenotazione, pur valida, non scalava il contatore. **Non restava traccia
di niente** — né di chi l'aveva concessa, né del perché.

Con i contatori derivati quella spunta non può più funzionare, perché la riga *è* il consumo. Quindi
l'omaggio smette di essere un comportamento e diventa un fatto scritto sulla riga: `omaggio`,
`omaggio_concesso_da`, `omaggio_motivo`, con un CHECK che impedisce un omaggio senza motivo.

Una riga omaggio **occupa il posto** nello slot e compare in agenda come le altre, ma non erode il
pacchetto in nessuno stato. Resta dentro `fatte` — il fascicolo dice «8 fatte, di cui 1 omaggio» — e
fuori da `consumate`. Nemmeno `prenotabili` la conta: un omaggio già in agenda non riduce quante
lezioni pagate restano da prenotare.

**Attenzione alla sequenza:** finché la Fase C non aggiunge il campo motivo in `agenda.html`,
togliere la spunta darà un errore leggibile invece di regalare la lezione. È voluto: meglio un no
chiaro che un omaggio senza storia. In Fase C la spunta si rinomina «Lezione omaggio» e apre il campo.

### Intro Corda sono 8 lezioni

`staff_attiva_corso` e `prenota_corso_admin` usavano **6** lezioni per Intro Corda, mentre
`accredita_intro_mese1` e `riconosci_percorso_pregresso` ne usano **8**. Il Listino v1.4 dice 8
(4 al mese 1 + 4 al mese 2): il 6 era un errore, corretto in tutti e tre i punti.

Vale la pena notare perché è emerso solo adesso: finché il numero viveva in una cache che nessuno
confrontava con nient'altro, due funzioni potevano dire cose diverse per mesi senza che si vedesse.
Da adesso è `lezioni_totali` sull'iscrizione, cioè la base di `restano`: una differenza del genere
salterebbe fuori al primo allievo.

### Chi ha mosso una riga, e a che titolo

`created_by` dice *chi*: un uuid, che fra sei mesi non racconta più niente. Da DEBITO-190 ogni
fotografia in `effetto_contabile` porta anche **`funzione`**, **`attore`** e **`ruolo_attore`**, e
`prenotazioni_corso` ha una colonna **`created_ruolo`** valorizzata dalle RPC di prenotazione.

`_ruolo_attore()` decide in quest'ordine, perché più condizioni possono essere vere insieme — il
Worker gira come `service_role` *e* senza `auth.uid()`:

1. il marcatore `app.origine = 'claude'` → **`claude`**
2. la funzione chiamante comincia per `cron_` → **`cron`**
3. `current_user = 'service_role'` → **`worker`**
4. nessun utente autenticato e `current_user = 'postgres'` → **`sql_manuale`**
5. l'utente autenticato è l'intestatario della riga → **`allievo`**
6. altrimenti lo `staff_role` dell'attore
7. nient'altro → **`sconosciuto`**, che è meglio di una bugia

Gli `staff_role` sono i **sette veri** del CHECK di `profile_data`, letti dal database:
`staff_creator`, `staff_segreteria`, `staff_istruttore_tutor`, `staff_istruttore_sr`,
`staff_istruttore_jr`, `staff_assistente`, `staff_monitor`.

#### La regola del marcatore

**Chi scrive sul database da SQL a nome di Claude esegue prima:**

```sql
SELECT set_config('app.origine', 'claude', false);
```

Va eseguito **nella stessa sessione**, prima delle scritture. Senza, quelle righe risultano
`sql_manuale` e diventano indistinguibili da un intervento fatto a mano in segreteria. Il `false`
finale significa "per tutta la sessione, non solo per la transazione corrente".

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

## ⚠ Falla di sicurezza trovata durante la Fase B — è LIVE adesso

`staff_attiva_corso(p_user_id, p_corso, p_skip_staff_check)` è `SECURITY DEFINER`, di proprietà di
`postgres`, e ha `EXECUTE` concesso a **`anon`** e `authenticated`. La guardia era:

```sql
IF NOT p_skip_staff_check AND NOT is_staff() THEN RAISE EXCEPTION ...
```

Il bypass dipende da un booleano che arriva dal chiamante. Con la chiave anon — quella scritta in
chiaro in ogni pagina pubblica del sito — una sola chiamata `rpc/staff_attiva_corso` con
`p_skip_staff_check: true` attiva un corso a pagamento a qualunque utente, senza nessuna
autenticazione.

**Non è stata introdotta da questo cantiere: è così sul database di produzione oggi.** Il file 03 la
chiude (il bypass vale solo se il ruolo Postgres è già `postgres` o `service_role`, che un client
PostgREST non può avere) e toglie `EXECUTE` ad `anon` su entrambi gli overload. Nessuna pagina del
repo chiama questa funzione, quindi la revoca non rompe niente.

DEBITO-190 la rende anche più dannosa: prima la chiamata scriveva un contatore di cache, dopo crea
una riga vera in `iscrizioni_corso`, cioè lezioni realmente prenotabili. Vale la pena applicare
almeno questa parte **prima** del resto, o a mano subito.

## ⚠ Seconda falla, stessa famiglia: `riconosci_percorso_pregresso`

Trovata mentre si scriveva la Fase B. È `SECURITY DEFINER` con `EXECUTE` ad `anon` e `authenticated`,
ed era **l'unica delle quattro funzioni admin senza guardia staff** — le altre tre
(`prenota_corso_admin`, `disdici_corso_admin`, `registra_pagamento_manuale_admin`) ce l'hanno tutte.

Il controllo esisteva **solo nell'interfaccia**: `portale.html` riga 5749 mostra il bottone
«🎓 Riconosci pregresso» con `isStaff() ? … : ''`. Un controllo lato pagina non è un controllo: con la
chiave anon si chiama la RPC direttamente e si riscrive il percorso di qualunque allievo — iscrizioni
pregresse, flag pagato, funnel, e un'iscrizione **attiva da 8 lezioni**, che col modello derivato
sono lezioni davvero prenotabili.

`EXECUTE` ad `anon` è già stato revocato a mano in produzione il 22 settembre. Il file 03 tiene
comunque la guardia `is_staff()`, così è corretto anche applicato da solo su un database che non
avesse ricevuto la revoca. Il solo chiamante è il portale, dove l'utente è staff autenticato: non
cambia niente per chi la usa davvero.

## Cosa resta fuori da questa cartella

- Il Worker `stripe-worker` è un repo separato: censito, mai toccato.
- La tabella `presenze_corso` è **vuota** ma ha ancora attaccato il trigger
  `tg_presenze_lezioni_residue`. Si eliminano entrambi nel file 05, dopo il grep nel repo.
- Il trigger `trg_open_presenza_garantisce_corso` **resta**: in Fase B va riscritto togliendo le
  scritture sui contatori, deve solo garantire l'iscrizione al Corso Open.
- Le pagine da aggiornare in Fase C sono cinque: `portale.html`, `agenda.html`, `oggi.html`,
  `profilo.html` (il fascicolo) e `commerciale.html` (che chiama `get_cruscotto_percorsi`).
  `segreteria.html`, `fascicolo.html` e `cruscotto.html` non esistono come file.
