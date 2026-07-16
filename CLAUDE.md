# CLAUDE.md — Regole di lavoro per il repo kataclimb

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

## Stack (non proporre alternative esterne)

Cloudflare Pages/Workers/R2 + Supabase + Brevo (email transazionali) + Stripe + PayPal + Google Workspace + Namecheap. Se serve qualcosa fuori stack, fermarsi e spiegare perché lo stack non basta.

## Database (Supabase, progetto wbtougychlhnlcnonqge)

- MAI inventare nomi di colonne o tabelle: verificare sempre contro il codice live o chiedere. In caso di dubbio, fermarsi.
- Trappola nota: la vista `crm_leads` NON espone le colonne `coda`/`fascia` — le scritture passano dalla RPC `imposta_coda_fascia`.
- Modello funnel canonico: ogni corso ha esattamente 3 stati: `prenotato_X` / `iscritto_X` / `concluso_X`.
- Prenotazioni: tabella canonica `prenotazioni_prima_lezione` (NON la vecchia `crm_prime_lezioni`). Capienza slot: max 6.
- VIETATO scrivere sul database o modificare la logica di scrittura (prenotazioni, iscrizioni, pagamenti) senza istruzione esplicita nel task. Il DB collegato è quello di PRODUZIONE, con dati reali.

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
