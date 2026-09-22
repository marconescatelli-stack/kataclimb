# DEBITO-191 · Passo 3 — Classificazione e proposta

Stato: **nessun file applicato**. Qui c'è cosa propongo di fare e perché. I comandi stanno nei
file `03`, `04a/b/c` e `05`, e li applica Marco.

## I totali

**153 SECURITY DEFINER · 114 eseguibili da anon · 51 in priorità 1 · 63 in priorità 2 · 39 ristrette.**

Delle 114 aperte ad anon, 19 sono funzioni di trigger e non si possono invocare. Le altre 95 sono
porte vere. Su queste 95, più due di priorità 3 con lo stesso difetto, la classificazione è:

| classe | funzioni | cosa significa |
|---|---|---|
| **A · REVOKE da anon** | **44** | La guardia interna regge. Basta togliere il privilegio a chi non deve chiamarla. |
| **B · guardia da correggere o aggiungere** | **31** | Il controllo interno non c'è, o c'è e non funziona. |
| **C · legittimamente pubblica** | **20** | Deve restare chiamabile. Dieci servono il flusso anonimo, dieci sono helper booleani delle policy RLS. |
| **D · morta** | **2** | Nessun chiamante da nessuna parte. Decide Marco. |

A e B non si escludono. Per le 31 della classe B il `REVOKE` da `anon` è il cerotto che ferma
l'emorragia il giorno stesso; la guardia corretta è la sutura, e serve comunque, perché una guardia
sbagliata resta una trappola per chi la legge domani. Le B compaiono quindi anche nel file `03`.

---

## Il difetto comune: una guardia che non scatta

Le tre falle di settembre sembravano tre casi. Sono un caso solo, ripetuto venticinque volte.

Quasi tutte le guardie di questo database confrontano `auth.uid()` con qualcosa. Quando la chiamata
arriva da un anonimo, `auth.uid()` vale NULL, e in SQL un confronto con NULL non è falso: è NULL.
In PL/pgSQL un `IF` che riceve NULL si comporta come un `IF` falso, quindi **non esegue il ramo**,
quindi non solleva l'eccezione, quindi lascia passare.

Le due forme in circolazione, entrambe bucate:

```sql
-- forma 1, usata da 8 funzioni
IF auth.uid() IS NOT NULL                      -- anon: FALSE -> l'AND si ferma qui
   AND auth.uid() <> '<uuid di Marco>'::uuid
   AND NOT EXISTS (SELECT 1 FROM profile_data WHERE user_id = auth.uid() AND staff_role IN (…))
THEN RAISE EXCEPTION 'non autorizzato';
END IF;

-- forma 2, usata da 12 funzioni
IF NOT (
     auth.uid() = '<uuid di Marco>'::uuid      -- anon: NULL
     OR EXISTS (SELECT 1 FROM profile_data WHERE user_id = auth.uid() AND staff_role IN (…))
   )                                           -- NULL OR FALSE = NULL -> NOT NULL = NULL
THEN RAISE EXCEPTION 'non autorizzato';
END IF;
```

La forma 1 è esplicita: *se non sei loggato, non ti controllo*. La forma 2 ci arriva per la strada
della logica a tre valori. Il risultato è identico.

La stessa cosa succede con `<>` fra due UUID di cui uno è NULL, ed è il caso di `prenota_corso`
e `disdici_corso`:

```sql
IF p_user_id <> auth.uid() AND NOT is_staff() THEN   -- anon: NULL AND TRUE = NULL
```

### La terza forma: il ruolo che vale NULL

C'è una variante che non riguarda gli anonimi ma chiunque abbia un account. Due funzioni leggono
lo `staff_role` del chiamante e lo confrontano così:

```sql
SELECT staff_role INTO v_caller_role FROM profile_data WHERE user_id = v_caller_id;
IF v_caller_role NOT IN ('staff_creator', 'staff_segreteria', …) THEN
  RAISE EXCEPTION 'Permesso negato: serve staff';
END IF;
```

Un allievo ha `staff_role` NULL. `NULL NOT IN (…)` vale NULL, l'IF non scatta, l'allievo passa.
Succede in `marca_presenza_prima_lezione`, che respinge correttamente gli anonimi ma lascia passare
**qualunque utente registrato**, e nella firma a tre argomenti di `sposta_prima_lezione`.
Le funzioni sorelle scrivono `IF v_role IS NULL OR v_role NOT IN (…)` e sono a posto: è la stessa
riga, con quattro parole in più.

`prenota_corso_admin` ha la stessa forma ma non è vulnerabile, perché più in alto c'è un
`IF NOT is_staff()` che respinge già chi non ha un ruolo.

Accanto, cinque funzioni che scrivono e non hanno **nessun** controllo: `annulla_freeze`,
`dichiara_freeze_forzato`, `registra_tesseramento`, `aggiorna_data_iscrizione` e `get_tesseramenti`.
Il controllo sta nel fatto che il bottone si vede solo in portale.html.

### La forma che regge

Due funzioni fanno la stessa cosa e la fanno bene, `cancella_open` e `dichiara_freeze`:

```sql
IF auth.uid() IS DISTINCT FROM p_user_id AND NOT COALESCE(is_staff(), false) THEN
```

`IS DISTINCT FROM` non torna mai NULL, `is_staff()` non torna mai NULL perché è un `EXISTS`.
È la forma che i file `04` adottano ovunque.

## La prova, non il sospetto

Il 22 settembre, in sola lettura, impersonando `anon` senza alcun token:

```sql
SET ROLE anon;
SELECT count(*) FROM get_leads_da_contattare();   -- 410
```

**410 righe.** Quella funzione restituisce nome, cognome, telefono, email, fonte, note e stato del
funnel di ogni contatto dell'Accademia. La chiave `anon` che serve per arrivarci sta in chiaro
dentro ogni pagina del sito, perché è fatta per stare lì.

Nella stessa sessione hanno risposto ad `anon`, senza sollevare eccezione, anche `conta_code_lead`,
`get_timeline_persona`, `get_qualifica_lead`, `get_famiglia` e `get_cruscotto_percorsi`. Le ultime
tre le ho interrogate con UUID inventati, per non tirare fuori dati di persone vere: hanno risposto
vuoto perché l'UUID non esisteva, non perché la guardia le abbia fermate.

Le funzioni che **scrivono** non le ho provate: la consegna dice sola lettura e la lettura del
codice basta, visto che la guardia è la stessa riga.

---

## A · REVOKE da anon — 44 funzioni

Hanno una guardia che regge. Il privilegio ad `anon` è solo un default di Supabase che nessuno ha
mai tolto. Sono raggruppate per famiglia nel file `03`.

**Le sole chiamate da staff loggato** perdono `anon` e tengono `authenticated`: `marca_presenza_corso`,
`rimarca_presenza_corso`, `materializza_prima_lezione_mancante`,
`prenota_corso_admin`, `disdici_corso_admin`, `sposta_corso`, `cancella_open`, `dichiara_freeze`,
`iscrivi_minore`, `iscrivi_minore_da_lead`, `imposta_status_iscrizione_minore`, `get_iscritti_minori`,
`registra_pagamento_manuale_admin`, `ricalcola_cache_tutti`, `staff_chiudi_giorno`,
`staff_riapri_giorno`, `certifica_kata`, `rifiuta_kata`, `sposta_kata`, `crea_evento`,
`invia_push_test`, `upsert_push_subscription`, `delete_push_subscription`, `miei_figli`.

**Le interne e quelle da cron o Worker** perdono anche `authenticated`, perché girano come `postgres`
o come `service_role` e nessun browser deve poterle chiamare: le cinque di `pg_cron`
(`auto_marca_presenze_scadute`, `auto_marca_presenze_prima_lezione_scadute`,
`libera_prenotazioni_scadute`, `cron_accoda_offerta_open`, `popola_feste_comandate`),
`cron_genera_eventi_mattutini`, `smista_commerciale_scaduti`, `conferma_partecipazione_camp`,
`riattiva_freeze_se_scaduto`, `garantisci_persona`, `applica_no_show`, `ricalcola_cache_contatori`,
`registra_evento_notifica`, `riconosci_pregresso`, `calendario_accademia_prossime`,
`_chiudi_corso_se_finito`, `_snapshot_contabile`, `_ruolo_attore`, `_referente_notifica`,
`_get_lezioni_residue`.

Più le 19 funzioni di trigger, in una sezione a parte del file `03` perché si possono applicare o
saltare senza conseguenze.

## B · guardia da correggere o aggiungere — 31 funzioni

Nei file `04a`, `04b`, `04c`. Un `CREATE OR REPLACE` per funzione, **corpo riletto da
`pg_get_functiondef` e lasciato identico**, cambia solo il blocco di guardia.

- **04a · le 18 del CRM** — `aggiungi_nota_lead`, `allega_documento_consenso`, `avanza_sequenza_wa`,
  `conta_code_lead`, `crea_figlio_lead`, `get_consensi_minore`, `get_famiglia`,
  `get_leads_da_contattare`, `get_qualifica_lead`, `get_richieste_lead`, `get_timeline_persona`,
  `imposta_coda_fascia`, `imposta_consenso_minore`, `inserisci_minore_con_referente`,
  `salva_qualifica_lead`, `segna_link_inviato`, `segna_memo_wa`, `segna_recensione_inviata`,
  `segna_recensione_inviata_persona`, `segna_step_messaggio`. Sono venti nomi perché
  `get_leads_da_contattare` e `conta_code_lead` stanno nello stesso gruppo delle altre diciotto.
- **04b · le cinque senza guardia** — `annulla_freeze`, `dichiara_freeze_forzato`,
  `registra_tesseramento`, `aggiorna_data_iscrizione`, `get_tesseramenti`.
- **04c · prenotazioni e presenze** — `prenota_corso`, `disdici_corso`, `riconosci_figlio`,
  `marca_presenza_prima_lezione` e `sposta_prima_lezione` nella sola firma a tre argomenti.
  La firma a quattro argomenti di `sposta_prima_lezione` è già scritta bene e non si tocca.
- **05 · `get_cruscotto_percorsi`**, da solo, perché lì la decisione su chi deve vedere è di Marco.

## C · legittimamente pubblica — 20 funzioni

Dieci servono il flusso prima del login e non restituiscono dati di terzi:
`conteggi_prima_lezione`, `slot_disponibilita`, `slot_open_disponibilita`,
`get_persona_per_completamento`, `completa_contatti_persona`, `get_questionario_prima_context`,
`salva_questionario_prima`, `listino_gate`, e con riserva `get_eventi_calendario` e
`get_evento_pubblico`.

Dieci sono helper booleani che le policy RLS chiamano a ogni query: `is_staff`, `assert_staff`,
`is_admin`, `is_certificatore`, `is_didattico`, `is_tutore_di`, `can_assign_badges`,
`_puo_leggere_questionari`, `persona_visibile_community`, `is_veterano`. Con un chiamante anonimo
tornano `false` o vuoto. Togliere loro `EXECUTE` spegnerebbe le policy che le usano, `is_staff` da
sola ne serve trentacinque.

### Le tre riserve, una per una

**`get_eventi_calendario` e `get_evento_pubblico`** restituiscono nome e iniziale del cognome dei
primi cinque iscritti e degli interessati a ogni evento. Serve alla pagina pubblica, che mostra la
cordata. Ma fra gli iscritti alle uscite ci sono minori, e `persona_visibile_community` — la funzione
che esiste apposta per non mostrare un minore senza consenso — qui non viene chiamata. È il filtro
che DEBITO-187-B ha messo sulla Comunità e che sulle pagine evento non è mai arrivato.
**Decide Marco**: o si applica lo stesso filtro, e allora è un intervento a parte, o si accetta.

**`completa_contatti_persona` e `salva_questionario_prima`** sono due scritture eseguibili da un
anonimo. Il segreto è l'UUID nel link inviato per email, e tutte e due si lasciano toccare una volta
sola: la prima solo finché `email IS NULL`, la seconda per un vincolo di unicità sulla prenotazione.
Vanno bene così. Se un giorno si vorrà un link che scade, serve un token, non una guardia.

**`is_veterano(p_user_id)`** accetta l'UUID di un altro, quindi un anonimo con un UUID valido può
sapere se quella persona è veterana. È un booleano e serve come helper. La lascio, segnalandola.

## D · morta — 2 funzioni

| funzione | scrive | perché |
|---|---|---|
| `get_voce_breakdown(p_voce_id text)` | no | Nessuna pagina, nessuna funzione, nessuna policy, nessun job. |
| `_get_spostamenti_residui(p_user_id uuid, p_corso text)` | no | Il gemello `_get_lezioni_residue` lo usa il cron mattutino. Questo non lo usa nessuno. |

Sono candidate a `DROP`, **non c'è nessun DROP nei file**. Tutte e due leggono soltanto, quindi la
revoca del privilegio le mette comunque in sicurezza: la rimozione si può decidere con calma.

Non ho messo in D nessuna funzione che scrive, anche quando il repo non mostra chiamanti: i Worker
non stanno qui. `smista_commerciale_scaduti`, `riattiva_freeze_se_scaduto`,
`conferma_partecipazione_camp`, `allega_documento_consenso` e `avanza_sequenza_wa` sono in A o in B
con la nota "nessun chiamante nel repo", e vanno verificate contro il codice dei Worker.

---

## Le guardie che citano ruoli che non esistono

I soli valori ammessi dal CHECK `profile_data_staff_role_check`:

```
staff_creator · staff_segreteria · staff_istruttore_tutor · staff_istruttore_sr
staff_istruttore_jr · staff_assistente · staff_monitor
```

Diciotto funzioni confrontano `staff_role` con `creator`, `admin`, `segreteria` e `istruttore_senior`.
Nessuno di questi quattro esiste. L'unico valore vero nella lista è `staff_istruttore_sr`.

`get_cruscotto_percorsi` non è l'eccezione: è la regola, ed è solo quella che si è notata.

Contando le persone a DB il 22 settembre: 11 hanno uno `staff_role`, e di queste le diciotto
funzioni ne ammettono 3, gli `staff_istruttore_sr`. Le 2 persone di segreteria sono respinte da
tutte e diciotto. Marco passa lo stesso, ma per l'UUID scritto a mano nel corpo, non per il ruolo.

Una guardia che cita ruoli inesistenti non protegge di più. Protegge di meno, perché respinge chi
deve passare e fa credere a chi la legge che un controllo esista.

### L'UUID nel corpo

`27b04151-93a7-4ecc-824c-fe337cc631a6` compare in 21 funzioni come scorciatoia. È l'utenza di Marco,
e a DB ha già `staff_role = 'staff_creator'` e `role = 'creator'`. Appena `staff_creator` entra nella
lista dei ruoli ammessi, quella riga non serve più a niente e resta solo come cosa da spiegare.
I file `04` la tolgono. **Se Marco preferisce tenerla, si scommenta una riga**, è segnalato nel file.

Restano fuori da questo intervento altri UUID scritti a mano, che non sono guardie e non tocco:
quattro in `riconosci_pregresso`, uno in `conferma_partecipazione_camp` che a DB non esiste più,
e i due `00000000-…` di `garantisci_profilo` e `provisiona_figlio`, che sono sentinelle.

## In che ordine applicare

1. **`03_revoke.sql`** per primo. Chiude le porte senza toccare una riga di logica, e si annulla con
   un `GRANT`. Dopo il 03, `get_leads_da_contattare` chiamata da un anonimo deve rispondere
   *permission denied*, e il sito pubblico deve continuare a funzionare.
2. **`04a`, `04b`, `04c`** uno alla volta, verificando dopo ciascuno.
3. **`05_cruscotto_percorsi.sql`** solo dopo che Marco ha deciso chi vede il cruscotto.

Il `03` da solo chiude l'esposizione ad `anon`, che è tutto il danno misurabile di oggi. I `04`
servono perché la prossima volta che qualcuno legge quelle righe ci trovi un controllo vero.
