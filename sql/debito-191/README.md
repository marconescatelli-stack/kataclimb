# DEBITO-191 · Sicurezza delle funzioni SECURITY DEFINER

## Stato

**`03a_urgente.sql` è stato applicato in produzione il 22 settembre 2026 alle 19:47**, da Marco,
dal SQL Editor di Supabase. Le tre verifiche sono passate:

- `V-ACL`: tredici righe `authenticated + service_role`, nessuna ancora aperta ad `anon` e nessuna
  con `PUBLIC`;
- `V-ANON`: `get_leads_da_contattare()` chiamata da `anon` risponde `42501 permission denied`,
  dove prima rispondeva 410 righe;
- flusso pubblico e `orari.html` funzionanti.

I dati personali e quelli dei minori non sono più leggibili da un anonimo.

**Tutti gli altri file restano non applicati**: `03`, `04a`, `04b`, `04c`, `05`, `06`. Il database,
per il resto, è stato solo letto.

Il cantiere nasce da tre falle trovate per caso il 22 settembre, tutte della stessa forma:
`SECURITY DEFINER` più `EXECUTE` ad `anon` più una protezione che sta solo nell'interfaccia.
Il censimento dice che non erano tre casi.

## I numeri

**153 SECURITY DEFINER · 114 aperte ad anon · 51 in priorità 1 · 63 in priorità 2 · 39 ristrette.**

Delle 114 aperte ad `anon`, 19 sono funzioni di trigger e non si possono invocare. Restano
**95 porte vere**, così classificate: **44 A** (basta togliere il privilegio), **31 B** (la guardia
non c'è o non funziona), **20 C** (devono restare pubbliche), **2 D** (nessun chiamante).

## Il fatto che conta

Il 22 settembre, in sola lettura, senza alcun token, impersonando `anon`:

```sql
SET ROLE anon;
SELECT count(*) FROM get_leads_da_contattare();   -- 410
```

**410 righe** con nome, cognome, telefono, email e note di ogni contatto dell'Accademia,
leggibili da chiunque abbia la chiave `anon`, che sta in chiaro in ogni pagina del sito.
La guardia c'era. Non è scattata, perché confrontava `auth.uid()` con un UUID e per un anonimo
quel confronto non vale falso, vale NULL, e un `IF` che riceve NULL non esegue il ramo.

Il ragionamento completo, con le tre forme del difetto, è in `02_piano.md`.

## I file

| # | file | cosa fa | scrive dati? |
|---|---|---|---|
| 00 | `00_censimento.md` | le 153 funzioni con ACL, guardia e priorità | no, è un documento |
| 01 | `01_mappa_chiamanti.md` | chi chiama cosa, e se prima o dopo il login | no, è un documento |
| 02 | `02_piano.md` | la classificazione A/B/C/D e il perché | no, è un documento |
| 03a | `03a_urgente.sql` | le 13 funzioni con dati personali o di minori · **APPLICATO il 22 set, 19:47** | no, solo privilegi |
| 03 | `03_revoke.sql` | toglie i privilegi a chi non deve chiamare, tutte le altre | no, solo privilegi |
| 04a | `04a_guardie_crm.sql` | corregge la guardia di 20 funzioni del CRM | no, solo `CREATE OR REPLACE` |
| 04b | `04b_guardie_contabili.sql` | aggiunge la guardia a 5 funzioni che non ne avevano | no, solo `CREATE OR REPLACE` |
| 04c | `04c_guardie_prenotazioni.sql` | corregge 5 funzioni di prenotazione e presenza | no, solo `CREATE OR REPLACE` |
| 05 | `05_cruscotto_percorsi.sql` | la guardia di `get_cruscotto_percorsi` | no, solo `CREATE OR REPLACE` |
| 06 | `06_default_privileges.sql` | impedisce che le funzioni future nascano aperte | no, solo privilegi di default |
| 07 | `07_log_chiamate_anon.md` | le query sui log, e la risposta a "è mai stata usata?" | no, è un documento |

Nessuno di questi file tocca una riga di dati. Il `03` e il `06` si annullano con un `GRANT`.
I `04` e il `05` sostituiscono funzioni: per tornare indietro serve la versione di prima, che si
rilegge in qualunque momento con `pg_get_functiondef`.

Tutti i corpi sono stati riletti da `pg_get_functiondef` il 22 settembre e lasciati identici:
cambia solo il blocco di guardia, marcato con un commento `DEBITO-191`. Nessuna firma cambia,
quindi nessun `DROP FUNCTION` è necessario. Il file più grande è `04a`, 48 KB.

## In che ordine, e cosa guardare dopo ciascuno

### 0. `03a_urgente.sql` — fatto il 22 settembre alle 19:47

Sottoinsieme del `03`: tredici funzioni, quelle che espongono dati personali o di minori e che
nessuna pagina pubblica chiama. Applicato, verificato, niente da rifare.

In testa al file resta l'elenco delle funzioni che **non** sono state revocate, con scritto cosa
si sarebbe rotto: `get_eventi_calendario`, `get_evento_pubblico`, le due del questionario, le due
di completa-contatti e `listino_gate`. Quelle vanno chiuse con un filtro sul contenuto, e la
decisione è ancora aperta.

Per tornare indietro su una singola funzione basta ridarle il privilegio:
`GRANT EXECUTE ON FUNCTION <firma> TO anon;`

### 1. `03_revoke.sql` — il prossimo

**Le tredici del `03a` sono anche qui dentro.** Non è un problema: `REVOKE` e `GRANT` sugli stessi
ruoli lasciano lo stesso stato, quindi riapplicarle non cambia niente e non serve toglierle dal
file. Il `03` aggiunge le altre ottantatré.

È quello che ferma il danno. Non cambia logica, toglie privilegi.

**Attenzione al motivo per cui non basta revocare ad `anon`.** 113 funzioni su 114 hanno `EXECUTE`
su `PUBLIC`, non solo su `anon`: nell'ACL è l'entry senza nome a sinistra dell'uguale, `=X/postgres`.
Finché `PUBLIC` ha il privilegio, `anon` continua a eseguire anche dopo un `REVOKE ... FROM anon`.
Per questo ogni riga revoca da `PUBLIC` **e** da `anon`, e subito dopo rida `EXECUTE` per nome a chi
deve restare. A DB `authenticated` e `service_role` hanno già un `GRANT` esplicito su tutte, quindi
quei `GRANT` confermano ciò che c'è e non cambiano lo stato: servono a rendere il file ripetibile.

Chi non perde niente, verificato: `postgres` è proprietario di tutte e 153; i cinque job di
`pg_cron` hanno `username = 'postgres'`, quindi girano come il proprietario; `service_role` ha il
suo `GRANT`; per i trigger il privilegio si controlla alla creazione del trigger, non a ogni scatto.

**Dopo il 03, verificare:**
- la query `V-ACL` in fondo al file non deve trovare nessuna funzione toccata ancora aperta ad `anon`;
- da `anon`, `get_leads_da_contattare()` deve rispondere *permission denied*;
- da `anon`, `conteggi_prima_lezione(...)` e `get_eventi_calendario()` devono continuare a rispondere;
- sull'anteprima: aprire `inizia.html` e vedere che le date piene risultino piene, aprire
  `proposta-open.html` e vedere gli slot, aprire un link di `questionario-prima.html`;
- da loggato: portale, agenda e console Oggi come sempre.

La sezione 4 del file, le 19 funzioni di trigger, è facoltativa e si può saltare senza conseguenze.

### 2. `04a`, poi `04b`, poi `04c` — uno alla volta

**Dopo ciascuno** la query `V-firme` in fondo al file: deve dire che nessun nome ha più di una firma.
L'unica eccezione attesa è `sposta_prima_lezione`, che ha due firme legittime e nel `04c` ne viene
toccata una sola, quella a tre argomenti.

- **dopo `04a`**: da `commerciale.html` la coda chiamate si carica, il fascicolo lead si apre, una
  nota si salva. **Soprattutto**: farlo provare a chi è `staff_segreteria`, perché fino a oggi quelle
  venti funzioni la respingevano e ora dovrebbe entrare.
- **dopo `04b`**: da portale, congelare e scongelare un profilo di prova. Da un utente allievo, la
  stessa chiamata deve rispondere *Permesso negato: serve staff*.
- **dopo `04c`**: da agenda, prenotare, disdire, spostare e marcare una presenza. Da un allievo,
  marcare una presenza deve essere rifiutato, cosa che oggi non succede.

### 3. `05_cruscotto_percorsi.sql` — solo dopo la decisione sui ruoli

### 4. `06_default_privileges.sql` — quando si vuole, è indipendente

Non tocca le funzioni esistenti, vale solo per quelle create dopo.

---

## Le decisioni che spettano a Marco

### 1. Chi vede il cruscotto

Nel file `05` c'è il segnaposto `-- RUOLI AMMESSI: [da decidere]`. La proposta è
`staff_creator`, `staff_segreteria`, `staff_istruttore_sr`, `staff_istruttore_tutor`.
Restano fuori `staff_istruttore_jr`, `staff_assistente`, `staff_monitor`.
Il cruscotto mostra nome, cognome, telefono, email, lezioni residue e scadenze di ogni allievo:
è la lista di chi va richiamato. La stessa lista è usata anche nei file `04a` e `04c`.

Per orientarsi, le persone a DB il 22 settembre:

| staff_role | persone |
|---|---|
| (nessuno) | 177 |
| staff_istruttore_sr | 3 |
| staff_assistente | 2 |
| staff_istruttore_jr | 2 |
| staff_segreteria | 2 |
| staff_creator | 1 |
| staff_monitor | 1 |

### 2. L'UUID scritto a mano

`27b04151-93a7-4ecc-824c-fe337cc631a6` compare in 21 funzioni come scorciatoia personale. Quell'utenza
a DB ha già `staff_role = 'staff_creator'`, quindi appena `staff_creator` entra nella lista dei ruoli
ammessi la scorciatoia non serve più. **I file `04` e `05` la tolgono.** Per rimetterla c'è una riga
commentata in ogni funzione. Se preferisci tenerla, va scommentata prima di applicare.

### 3. La lista D, le due funzioni morte

| funzione | scrive | cosa propongo |
|---|---|---|
| `get_voce_breakdown(p_voce_id text)` | no | `DROP`, dopo conferma |
| `_get_spostamenti_residui(p_user_id uuid, p_corso text)` | no | `DROP`, dopo conferma |

**Non c'è nessun `DROP` nei file.** Tutte e due leggono soltanto e il `03` le mette comunque in
sicurezza, quindi si può decidere con calma. Il gemello `_get_lezioni_residue` invece è vivo, lo usa
il cron mattutino: attenzione a non confonderli.

Non ho messo in D nessuna funzione che scrive, anche dove il repo non mostra chiamanti, perché
**i Worker non stanno in questo repo**. Queste cinque vanno verificate contro il codice dei Worker
prima di considerarle morte: `smista_commerciale_scaduti`, `riattiva_freeze_se_scaduto`,
`conferma_partecipazione_camp`, `allega_documento_consenso`, `avanza_sequenza_wa`.
Due domande precise: `cron_genera_eventi_mattutini` non è in `pg_cron` e nessuna pagina la chiama,
quindi la sveglia il Worker delle notifiche, giusto? E `conferma_partecipazione_camp` la chiama
`kc-eventi` sul percorso `/conferma`, giusto?

### 4. La lista C, e la riserva sui minori

Delle 20 funzioni che restano pubbliche, due meritano una decisione a parte.

`get_eventi_calendario` e `get_evento_pubblico` restituiscono nome e iniziale del cognome dei primi
cinque iscritti e degli interessati a ogni evento, a chiunque, senza login. Serve alla pagina
pubblica per mostrare la cordata. Ma fra gli iscritti alle uscite ci sono minori, e
`persona_visibile_community` — la funzione che esiste apposta per non mostrare un minore senza
consenso, messa con DEBITO-187-B — sulle pagine evento non viene chiamata.

Non l'ho toccato: è un intervento sul contenuto, non sulla guardia, e va deciso. Se la risposta è
"si applica lo stesso filtro", diventa un task a parte.

Le altre due riserve, minori: `completa_contatti_persona` e `salva_questionario_prima` sono due
scritture eseguibili da un anonimo, protette dal fatto che l'UUID sta in un link mandato per email e
che tutte e due si lasciano toccare una volta sola. Vanno bene così. `is_veterano(p_user_id)` accetta
l'UUID di un altro, quindi un anonimo con un UUID valido sa se quella persona è veterana: è un
booleano, la lascio.

---

## Trovato per strada

Cose viste lavorando, **non toccate**, che non appartengono a questo cantiere.

### `get_cruscotto_percorsi` oggi non funziona per nessuno

Non è la guardia. Provata il 22 settembre, risponde:

```
ERROR 42804: structure of query does not match function result type
DETAIL: Returned type bigint does not match expected type integer in column 9
```

La colonna 9 è `residue_open`. Dopo DEBITO-190 i residui arrivano dalla vista `contatori_corso`,
dove `prenotabili` è `bigint`, mentre la funzione dichiara `integer`. Stessa cosa per
`residue_advance`, `residue_intro` e `residue_evo`. La correzione è un `::int` su quattro righe,
non è una guardia, ed è spiegata in fondo a `05_cruscotto_percorsi.sql` senza essere applicata.
Applicando solo il `05`, si corregge chi può entrare ma il cruscotto continua a dare errore.

In coda a quel file c'è anche una query che elenca le altre funzioni con lo stesso rischio, cioè
quelle che leggono `contatori_corso` e dichiarano `integer`.

### Validazioni di parametro che un NULL attraversa

Una dozzina di funzioni validano i parametri con `IF p_qualcosa NOT IN (...) THEN RAISE`, che con un
parametro NULL non scatta: `p_metodo` nelle dieci `accredita_*`, `p_fascia` in `crea_figlio_lead`,
`inserisci_minore_con_referente` e `riconosci_figlio`, `p_step` in `segna_step_messaggio`, `p_tipo`
in `imposta_consenso_minore`, `p_status` in `imposta_status_iscrizione_minore`, `p_formula` in
`essence_inserisci`, `p_corso` in `staff_attiva_corso`.

Non sono buchi di sicurezza: sono validazioni che lasciano entrare un NULL dove ci si aspetta un
valore. Vale la pena sistemarle, ma è un altro giro.

### La seconda SELECT dell'audit torna vuota

`sql/audit-security-definer.sql`, sezione 2, cerca i valori nella forma `'valore'::text`, mentre nei
corpi i confronti sono scritti `staff_role IN ('creator','admin',…)` senza cast. Così com'è non
trova niente. Rieseguita sui corpi restituiti da `pg_get_functiondef` trova **18 funzioni**, non una.
La sezione 2 di `00_censimento.md` riporta il risultato vero. Se quel file resta come strumento,
conviene correggergli la regex.

### `disdici_corso`, una riga lasciata com'è

Dopo la guardia c'è `v_is_allievo := (v_prenot.user_id = v_caller AND NOT v_is_staff)`, che con un
chiamante senza sessione varrebbe NULL. Con la guardia corretta del `04c` quel caso non si presenta
più, quindi la riga non è stata toccata: il mandato era di non riscrivere corpi oltre la guardia.

---

## Le funzioni future

Il `06` esiste perché senza di lui questo lavoro si disfa da solo.

In PostgreSQL una funzione appena creata concede `EXECUTE` a `PUBLIC`. Non è una stranezza di
Supabase: è il comportamento normale, e vale per ogni `CREATE FUNCTION` scritto dal SQL Editor, da
una migration o dettato in una chat. Su Supabase ci si somma che `anon` è un ruolo vero e che la sua
chiave sta in chiaro in ogni pagina. Ogni nuova RPC nasce quindi chiamabile da chiunque e resta tale
finché qualcuno non se ne accorge, che è esattamente come sono nate le 114 funzioni censite qui.

Lo stato letto il 22 settembre da `pg_default_acl`, per le funzioni di `public`, è
`postgres=X anon=X authenticated=X service_role=X`: `PUBLIC` non compare più nel default, ma il
`GRANT` automatico ad `anon` sì, e da solo basta a riaprire la porta. Il `06` toglie dal default sia
`PUBLIC` sia `anon`, e tiene `authenticated`, perché quasi tutte le RPC di questo progetto servono
il portale e una regola che costa troppo è la prima che si salta.

Il file contiene anche la prova da fare prima e dopo, con una funzione usa e getta da creare e
cancellare. **Non l'ho eseguita**, perché sarebbe una scrittura.

Cosa cambia dopo: una RPC che deve servire una pagina pubblica non funziona finché non le si concede
`EXECUTE` con un `GRANT` esplicito. È il punto di tutto il cantiere. Oggi una funzione è pubblica per
distrazione. Dopo, lo diventa per scelta, e la scelta lascia una riga scritta.

---

## Dopo il 03a, da rifare sui log

Le due query di `07_log_chiamate_anon.md`, un giorno dopo l'applicazione. La seconda deve
continuare a mostrare solo `get_eventi_calendario` e `conteggi_prima_lezione` fra le RPC chiamate
da `anon`. Se compare un 401 o un 403 su una funzione del flusso pubblico, una revoca è andata
oltre il bersaglio: in fondo a quel file c'è la query che li elenca.

## La falla è mai stata usata?

Nelle 24 ore coperte dai log, no. Le uniche RPC chiamate da `anon` sono `get_eventi_calendario`
(60 volte) e `conteggi_prima_lezione` (14), tutte e due pubbliche a ragione. Nessuna delle 31
funzioni con la guardia rotta è stata chiamata da un anonimo.

I log però tengono **24 ore**, dal 21 settembre alle 17:00 al 22 alle 16:56. Sul passato non
dicono niente, e queste funzioni sono aperte da quando sono nate. Query, risultati e limiti in
`07_log_chiamate_anon.md`.

## Come è stato fatto il lavoro

Database **in sola lettura**. Ogni sessione si è aperta con
`SELECT set_config('app.origine','claude',false)`, come chiede la consegna.

Le uniche esecuzioni di funzioni sono state letture, fatte con `SET ROLE anon` per dimostrare la
falla: `get_leads_da_contattare`, `conta_code_lead`, `get_timeline_persona`, `get_qualifica_lead`,
`get_famiglia` e `get_cruscotto_percorsi`. Le ultime tre con UUID inventati, per non tirare fuori
dati di persone vere. **Nessuna funzione che scrive è stata eseguita**, nemmeno per prova: per
quelle vale la lettura del codice, visto che la guardia è la stessa riga.

Nessun `REVOKE`, `GRANT`, `CREATE`, `ALTER` o `DROP` è stato eseguito. Le pagine HTML non sono state
toccate, e `sql/debito-190/` nemmeno.
