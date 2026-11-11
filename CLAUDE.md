# CLAUDE.md — Regole di lavoro per il repo kataclimb

## 🔒 REGOLA PRIMARIA — TRACCIA E ARCHIVIO (Marco, 18 ott 2026 — vale prima di tutte le altre)

Noi rappresentiamo lo storico: tutto quello che facciamo deve lasciare traccia.

1. **Esperienze date alle persone — si tengono sempre.** Pagine di edizioni, eventi e corsi già pubblicati, con una storia o persone dentro, NON si modificano e NON si sostituiscono: sono un riferimento per quelle persone, per Marco e per Claude. Il nuovo si AGGIUNGE accanto (nuova edizione = pagina nuova con la data nel nome, es. `essence-novembre-2026.html`); il vecchio resta online com'è.
2. **Sviluppo del progetto — memoria selettiva.** Scelte, passaggi decisivi ed errori vanno lasciati in memoria (commit chiari, documenti di registro) per orientarsi in futuro e non ricadere negli stessi problemi.
3. **Prima di cancellare o sostituire qualsiasi file o contenuto serve l'approvazione esplicita di Marco.** Si decide insieme cosa tenere e cosa no, e la decisione si mette a registro. Nel dubbio: chiedere, non procedere.

## ⚠️ PRIMA DI TUTTO

- **Il database collegato è quello di PRODUZIONE, con dati reali.** VIETATO scrivere sul database o modificare la logica di scrittura (prenotazioni, iscrizioni, pagamenti) senza istruzione esplicita nel task.
- **NON lavorare mai direttamente su `main`** (= produzione, kataclimb.com).
- **Terminologia vietata nei contenuti rivolti all'utente:**
  - Si dice sempre **"Accademia"**, mai "palestra". "Palestra" è ammesso SOLO per SEO esterno (meta description, alt text per Google), mai nel corpo dei contenuti.
  - **MAI la parola "boulder"**, in nessun copy, scheda, descrizione o alt text: è l'opposto del metodo. Le attività su parete bassa si descrivono come "esercizi e circuiti su parete con materassi paracadute".
  - **MAI nomi accorciati o generici per corsi e lezioni**, in nessuna UI, agenda, griglia, badge, email o documento. Sempre denominazione completa con fascia — "Prima Lezione Bambini (6–11)", "Prima Lezione Ragazzi (12–17)", "Prima Lezione Adulti" — e la dicitura KataClimb sui corsi del metodo. Se manca spazio si riduce il font o si va a capo, NON si accorcia il nome.

Rispondi e commenta sempre in italiano. Stile diretto, senza preamboli.

## Contesto

Questo repo contiene il sito pubblico kataclimb.com e il portale allievi (`portale.html`).
Quattro entità da tenere sempre separate, mai confonderle nei testi:
- **KataClimb** = metodo/sistema internazionale (33 Kata in 6 soglie). Non eroga corsi.
- **Accademia RCC** (Roma, Via Cassia 1634) = struttura che eroga i corsi.
- **Syncrolink Ltd** = veicolo commerciale (intensivi per professionisti).
- **Marco Nescatelli** = la persona, fondatore.

## Branch e deploy

- `main` = produzione (kataclimb.com, servito da GitHub Pages). NON lavorare mai direttamente su main.
- `dev` = sviluppo. Tutto il lavoro avviene qui. Anteprima automatica su kataclimb-dev.pages.dev (Cloudflare Pages).
- Ogni task si chiude con una pull request verso `dev` (o da `dev` verso `main` solo su richiesta esplicita di Marco).
- Il merge in produzione lo decide solo Marco, dopo verifica sull'anteprima.
- **Allineamento automatico, senza interrompere Marco.** Prima della prima modifica a un file: `git checkout dev` se non ci si è già, poi `git pull --rebase origin dev` in silenzio. Non chiedere conferma, non annunciarlo. Parlarne solo se il pull fallisce per un conflitto: in quel caso fermarsi, dire quale file e aspettare Marco.
- **Se il push viene rifiutato** perché su origin ci sono commit nuovi: `git pull --rebase`, poi push normale. Mai `--force`.
- **"Fine sessione"**: quando Marco lo dice, (1) verificare che non ci siano modifiche non committate, (2) se c'è un commit non pushato o una PR non aperta ricordarglielo e aspettare il suo ok, (3) `git pull --rebase` su dev e `git fetch` di main, (4) rispondere con una riga: branch, ultimo commit, PR aperte, allineato sì/no.

## Stack (non proporre alternative esterne)

Cloudflare Pages/Workers/R2 + Supabase + Brevo (email transazionali) + Stripe + PayPal + Google Workspace + Namecheap. Se serve qualcosa fuori stack, fermarsi e spiegare perché lo stack non basta.

## Database (Supabase, progetto wbtougychlhnlcnonqge)

- MAI inventare nomi di colonne o tabelle: verificare sempre contro il codice live o chiedere. In caso di dubbio, fermarsi.
- Trappola nota: la vista `crm_leads` NON espone le colonne `coda`/`fascia` — le scritture passano dalla RPC `imposta_coda_fascia`.
- Modello funnel canonico: ogni corso ha esattamente 3 stati: `prenotato_X` / `iscritto_X` / `concluso_X`.
- Prenotazioni: tabella canonica `prenotazioni_prima_lezione` (NON la vecchia `crm_prime_lezioni`). Capienza slot: max 6.
- VIETATO scrivere sul database o modificare la logica di scrittura (prenotazioni, iscrizioni, pagamenti) senza istruzione esplicita nel task. Il DB collegato è quello di PRODUZIONE, con dati reali.
- RPC PUBBLICHE (sicurezza, 6 nov 2026 — Master v4.23): le funzioni nuove nascono CHIUSE a chi non ha login. Se una pagina senza login (inizia*, orari, eventi, evento, proposta-*, questionario-prima, completa-contatti, arrampichi-gia, listino-corsi-*, sumisura, prima-lezione-privata) chiama una RPC nuova, l'SQL della consegna deve contenere `GRANT EXECUTE ON FUNCTION public.<nome>(<argomenti>) TO anon;`. Senza quella riga la pagina riceve 401. Non aprire mai al pubblico funzioni che scrivono dati di persone già registrate.
- GUARDIA D'IDENTITÀ (trappola T-UID-NULL): nelle funzioni SECURITY DEFINER il controllo si scrive `IF auth.uid() IS NULL OR …` (oppure `IS DISTINCT FROM`), mai solo `IF p_user_id <> auth.uid()`: senza login quel confronto vale NULL e non blocca.

## Turni monitor, report e note (Marco, 9–11 nov 2026 — dettaglio in `sql/monitor/08`–`12`)

Regola attiva dal 9/11/2026 (`monitor_regola_dal()`); prima vale lo storico (foglio cartaceo della segreteria). Ore intere, fascia lun–ven 19–22, sabato 14–18, domenica chiuso.

**Quando si dichiara il turno** (`impegni_staff.origine`, `_monitor_origine`):
- **Dichiarato** = segnato entro il giorno prima (fino alle 23:59 ora di Roma). È il buon uso.
- **Giorno stesso**: se l'ora è libera vale e si paga, ma resta marcato `giorno_stesso`. Se l'ora è di un collega si passa solo dalla sostituzione (proponi / accetta).
- **A posteriori**: senza scadenza. Stato `da_confermare` ("da rivedere"), non si paga finché la segreteria non conferma (`monitor_rivedi_turno`; respinto = `ritirato` con nota, mai cancellato). Se l'ora era già di un altro decide la segreteria. Se lo segna Marco o la segreteria è già confermato.

**Pagamento:**
- Un solo monitor pagato per ora. Il secondo solo con doppio turno creato da Marco o dalla segreteria, con il motivo (`monitor_doppio_turno`).
- Il monitor si paga solo se segue persone: un turno senza persone seguite è Sala, non monitor.
- Nelle ore in cui si fa lezione non si è anche monitor.
- ⚠️ Al 11/11/2026 il DB NON impone ancora questi ultimi due punti: `v_compenso_turni_monitor` paga 5 €/ora le ore dichiarate anche senza persone (8 € per le persone annotate, mai più delle ore) e `monitor_dichiara_turno` non controlla le lezioni. Non dare per scontato che il DB li applichi: serve una migrazione nuova, col "vai" di Marco.

**Report e note:**
- I report sono liberi (chiunque dello staff, a chiunque, quando vuole, anche fuori turno) e **separati dal pagamento**: un report fuori turno resta nella scheda ma non paga. L'ora di scrittura resta visibile (`_sala_riga`).
- Note di corso con **storico**: ogni riscrittura è una riga nuova, mai sovrascritta (`salva_osservazione`, sql 11). L'allievo vede l'ultima versione e, al tocco, lo storico.
- **Solo gli istruttori** (`staff_istruttore_jr`/`_sr`/`_tutor` e `staff_creator`) scrivono note visibili all'allievo. **Lo impone il DB** (`puo_scrivere_allievo`, sql 12): osservazione visibile da un non istruttore → rifiutata; voci del quadro da un non istruttore → salvate solo per lo staff (`solo_staff`). La segreteria scrive solo note di segreteria.

**Avvisi — worker notifiche live v3.3** (tabella `eventi_notifica`):
- `turno.cambio.*` (proposto, accettato, rifiutato, ritirato, scaduto; proposta "a tutti" con `user_id` NULL) — sql 08c;
- `turni.scoperti`: ogni giorno tra le 10 e le 12, ore scoperte di domani e dopodomani (domenica e giorni chiusi esclusi) — sql 10;
- `turno.a_posteriori`: alla segreteria, subito (quiete 22–08) — sql 10;
- email allo staff.
- Gli SQL nel repo citano ancora v3.0–v3.2 (il contratto degli eventi è quello); la versione live è la v3.3.

## Regole di codice

- Consegnare file completi e deployabili, mai diff parziali da ricomporre a mano.
- Verificare la sintassi JS di ogni file toccato (equivalente di `node --check`).
- HTML statico, nessun build step: quello che sta nel repo è quello che va online.
- Non introdurre framework, bundler o dipendenze npm senza richiesta esplicita.

## Regole UI

- Testi mai sotto i 13px.
- Mai `var(--text3)` (grigio chiaro) su dati operativi.
- Bottoni di azione primaria scuri, mai grigi.
- Tono dei testi: diretto, caldo, mai da guru. Metafore verticali (volare, vetta, cordata) benvenute. Il cliente è l'eroe, mai promesse miracolose. Niente CTA basate su paura o scarsità.

## Come lavorare

- Un task alla volta, portato a termine. Se il task è ambiguo, fare la scelta più conservativa e segnalarla nella PR.
- Nella descrizione della PR: cosa è stato modificato, quali file, cosa verificare sull'anteprima.
- Non toccare file fuori dal perimetro del task.
- Documentazione di dettaglio (quando presente) in `/docs`: consultarla prima di lavorare su portale, DB o infrastruttura.

## Pagine che non si toccano

- inizia_lead.html è la landing ATTIVA della campagna Meta (form → Worker kc-lead → find_or_create_persona_e_richiesta). Nessuna pagina del sito la linka, ma riceve contatti ogni settimana. Mai spostarla, rinominarla o archiviarla.
- Prima di dichiarare un file "non usato": oltre al grep nel repo, chiedere a Marco di controllare da chat la tabella lead_richieste (colonna pagina) e le fonti esterne (Meta, Stripe, mail Brevo, QR, link su WhatsApp).
- Le pagine pubbliche restano nella radice; _archivio/ non è pubblicato da GitHub Pages.
