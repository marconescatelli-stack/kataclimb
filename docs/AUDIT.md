# AUDIT del repository kataclimb — sola lettura

> Audit statico di tutti i file del repo. Nessun file è stato modificato: questo documento contiene **solo proposte di fix**, non correzioni applicate. Verifiche fatte contro i file su disco (asset, link, ancore, sintassi JS). Le note su nomi di tabelle/RPC vanno confermate sul DB di produzione prima di qualunque intervento.

## Sintesi

- **Rotto: 5** · **Incoerente: 18** · **Regole UI: 14 (sistemico, sotto-13px quasi ovunque)** · **Qualità: 14**.
- Nessun asset (immagini/PDF/CSS/JS), link `.html` interno o precache del service worker risulta mancante, con **una** eccezione: il logo JSON-LD in `index.html`.
- I 3 più urgenti:
  1. `informativa-staff.html` — manca `<div class="profile-box">`: la pagina staff live perde stile e layout (div sbilanciati 33/34).
  2. Conflitti di modello prodotto tra pagine pubbliche (slot video **5 vs 2**, durata **12s vs 20s**, corsi **5 vs 4**, fasi **6 vs 5**): il cliente legge numeri diversi su pagine diverse.
  3. `provisiona_stasera.html` — pagina one-shot datata (30 apr 2026) pubblica su kataclimb.com con **UUID lead di produzione** hardcoded e trigger provisioning + email Brevo su persone reali.

---

## 1. ROTTO

- **`informativa-staff.html` righe 164-170** — Manca il tag di apertura `<div class="profile-box">`: il box "Arricchite il vostro profilo" perde tutto lo stile (selettori discendenti `.profile-box …`) e il `</div>` di riga 170 chiude in anticipo `.wrap`, spingendo `.punch` e `.footer` fuori da `.sheet` (conteggio div: 33 aperti / 34 chiusi). — Fix: inserire `<div class="profile-box">` subito dopo il `.divider` di riga 164.
- **`index.html` riga 44** — Il JSON-LD `Organization.logo` punta a `https://kataclimb.com/Logo_Bianco_KataClimb.png`, file **non presente** nel repo (l'unico logo su disco è `logo-rcc.png` / `kataclimb-logo.svg`). — Fix: puntare a un file logo esistente o aggiungere `Logo_Bianco_KataClimb.png`.
- **`guida.html` riga 140** — `<a href="/portale">` usa un clean URL (unico caso nel sito, tutto il resto linka `portale.html`); su GitHub Pages può dare 404. — Fix: usare `portale.html`.
- **`evento.html` righe 161 e 164** — Il blocco "Ritrovo" viene renderizzato due volte con implementazioni divergenti (la var inline `ritrovo` costruita alle righe 152-157 + `ritrovoHTML(e)` righe 210-218): se lo slot ha `punto_incontro`/`ora_partenza` l'utente vede due box Ritrovo. — Fix: eliminare una delle due implementazioni (tenere `ritrovoHTML`).
- **`commerciale.html` riga 581** — La tessera "Da prenotare" conta la fase `'prenotare'`, che la funzione `phase()` (righe 185-202) non restituisce mai: mostra sempre 0 e al clic filtra su un valore inesistente producendo elenco vuoto. — Fix: rimuovere la tessera o mapparla a una fase reale.

---

## 2. INCOERENTE

### Conflitti di modello prodotto tra pagine pubbliche
- **`index.html` riga 2076 · `guida.html` righe 418-419 vs `kata.html` riga 208** — "5 slot/video per Kata" (index, guida) contro modello a **2 slot** (Memoria/Validazione) effettivamente implementato in `kata.html`. — Fix: allineare index e guida al modello live a 2 slot.
- **`guida.html` riga 419 vs `kata.html` riga 365** — Durata massima video "12 secondi" (guida, coerente anche con `monitor.html`) contro `KATA_MAX_DURATION = 20` in `kata.html`. — Fix: allineare `kata.html` a 12s.
- **`index.html` riga 1633 vs `guida.html`/`kata.html`** — "5 Corsi" contro i **4 corsi** reali (Open, Advance, Intro Corda, Evo Corda). — Fix: correggere a "4 Corsi".
- **`index.html` riga 8 (meta) vs riga 1984 (body) · `orari.html` riga 269** — Numero fasi discordante: meta "33 Kata in 6 fasi" (canonico), body "5 fasi progressive", `orari.html` "33 Kata in 5 soglie". — Fix: uniformare a "6 fasi" (o al termine deciso da Marco).
- **`index.html` riga 2064** — Teaser "Il portale sta arrivando" (coming soon) mentre `portale.html` è già live e linkato in nav/footer. — Fix: aggiornare il testo, il portale è online.

### Uso delle entità (KataClimb ≠ erogatore di corsi, li eroga Accademia RCC)
- **`pro.html` righe 30-36** — JSON-LD `Course.provider` = "KataClimb": attribuisce l'erogazione del corso al metodo. — Fix: valutare provider corretto (Accademia RCC) o rivedere la dicitura. *(bassa confidenza: il percorso istruttori potrebbe essere gestito direttamente da Marco — da confermare.)*
- **`proposta-advance.html` righe 9/155 · `proposta-open.html` riga 9** — "Il percorso Advance/Open di KataClimb": corso attribuito al metodo anziché ad Accademia RCC. — Fix: "percorso … in Accademia RCC".
- **`inizia.html` / `inizia-dopo.html` (testi CTA)** — "prima lezione di KataClimb" tratta il metodo come erogatore. — Fix: "prima lezione col metodo KataClimb, in Accademia RCC".

### Pagine duplicate / versioni vecchie
- **`inizia-dopo.html` vs `inizia.html`** — Title e meta description identici; è una variante viva (finestra 2 settimane) ma rimasta indietro rispetto a `inizia.html` v8: manca il filtro `.eq('fascia','adulti')` (riga 813 vs 830), manca la logica `giorni_chiusi` (righe 801-811 vs 766-773), i fetch checkout non inviano `consent` (righe 1012/1078 vs 1032/1098), il form-info invia `pagina:'inizia.html'` (riga 1199) e i minori vanno a WhatsApp invece che a `/inizia-minori.html` (righe 642-644). — Fix: allineare `inizia-dopo.html` alla v8 o deprecarla.
- **`provisiona_stasera.html`** — Pagina one-shot datata "30 apr 2026" (title riga 6, oggi è 15 lug 2026) lasciata pubblica: UUID lead di produzione hardcoded (righe 78/87/110-111), nome sospetto "Federica 23 23", nota interna "Master §1.5…§3ter" (riga 101), endpoint provisioning + email Brevo raggiungibile senza auth (solo `noindex`). — Fix: rimuovere dal repo pubblico o proteggere l'endpoint.

### Dati/tracking
- **`grazie.html` riga 222** — Evento `Purchase` hardcoded `value:25, content_name:'Prima Lezione'`, ma la pagina di ritorno è condivisa da adulti (25€), gruppi (N×25€) e minori (10€/15€): il valore inviato a Meta è errato per gruppi e minori. — Fix: leggere importo/prodotto dai query param passati dal worker sul redirect.
- **`inizia-minori.html` righe 22-31** — Il Meta Pixel parte subito (init+PageView) senza il gate di consenso GDPR presente in tutte le altre pagine funnel, e manca il banner consenso. — Fix: uniformare al gate consenso usato dalle altre pagine.

### Naming tabelle/RPC e ruoli (da confermare sul DB prima di toccare)
- **RPC coda/fascia** — Il codice usa `imposta_coda_fascia` (`commerciale.html` 339/346, `portale.html` 4493/4499/5612), CLAUDE.md cita `imposta_queue_fascia`. Il codice è internamente coerente, quindi è probabilmente la nota di CLAUDE.md a essere imprecisa. — Fix: verificare il nome reale su Supabase e allineare la documentazione (non il codice, se è quello live).
- **Vocabolario ruoli istruttore divergente** — `oggi.html` decide su `profile_data.staff_role` con valori `staff_istruttore_jr/sr/tutor`; `monitor.html` (riga 210) e `portale.html` (riga 3470) usano `role` con `istruttore_jr/istruttore_senior/istruttore_tutor`; `profilo.html` (riga 227) usa `staff_istruttore_sr/tutor`. — Fix: verificare colonne/valori sul DB e uniformare le label tra le viste staff.

### Proposte Open/Advance
- **`proposta-advance.html` riga 242 vs `proposta-open.html` riga 281** — Pattern RPC disponibilità divergenti: `slot_disponibilita({p_tipo_corso:'advance'})` vs `slot_open_disponibilita` senza parametri. — Fix: uniformare a una sola RPC parametrizzata (verificare che esista sul DB).
- **`proposta-open.html` riga 15 vs riga 143** — `og:image` = `arrampicata_kalymnos_rcc.jpg` ma l'hero reale è `hero-photo.jpg` (advance è invece coerente). — Fix: allineare `og:image` all'hero.
- **`proposta-advance.html` righe 173/177** — 8 lezioni a 280€ (1 volta/sett) contro 8 lezioni a 190€ (2 volte/sett): la modalità più intensiva costa 90€ in meno. — Fix: confermare con Marco che l'incentivo è voluto, altrimenti correggere.

### KataCamp
- **`73_KataCamp.html` riga ~471 vs riga 565** — Separatore decimale acconto aspiranti incoerente: card "187,50€" (virgola) vs `recalc()` JS "187.50€" (`toFixed(2)`, punto). — Fix: uniformare a virgola.
- **`73_KataCamp.html` riga 505** — Fineprint dev residuo visibile al pubblico: "Per agganciare la futura agenda… imposta `ACCADEMIA_AGENDA`…", ma la costante è già impostata a `/eventi.html` e il bottone appare già. — Fix: rimuovere o riscrivere come stato attuale.
- **`73_KataCamp.html` (scadenze)** — Acconto "entro il 14 giugno" e saldo "entro il 10 luglio 2026" sono entrambe passate rispetto a oggi (15 lug 2026) per un camp del 15-22 ago. — Fix: aggiornare le scadenze o confermare che la pagina è congelata.

### Refusi
- **`agenda.html` righe 345 e 1650** — Refuso "decrement**enr**ato" / "decremen**r**ato" in testo visibile all'utente. — Fix: correggere in "decrementato".

---

## 3. REGOLE UI VIOLATE

Violazione **sistemica** dei 13px minimi su testi (spesso su dati operativi) in quasi tutte le pagine; sotto i casi più gravi (dati operativi + eventuale `var(--text3)`/`--ink3`). Fix generale: rivedere la scala tipografica portando a ≥13px i testi che veicolano dati operativi.

- **`kata.html` riga 62** — `.kcount` conteggio video `present/2`: `font-size:12px` **e** `color:var(--text3)` su dato operativo (doppia violazione). Riga 80 `.kcorr-d`: 10px + `var(--text3)` sulla data del feedback maestro. — Fix: `var(--text2)`/`--text` e ≥13px.
- **`monitor.html` riga 430** — Badge inline conteggio video: `color:var(--text3)` + 10px (doppia). Riga 75 `.kn`: `var(--text3)` a 11px sull'identificativo Kata. Righe 32/62/77/79: nome staff, riga telefono/ruolo, badge, redo-btn sotto 13px. — Fix: colori leggibili e ≥13px.
- **`provisiona_stasera.html` riga 34** — `.card .id`: `color:var(--text3)` + 11px sull'UUID lead (dato operativo, doppia violazione). — Fix: `--text2`/`--text` e ≥13px, o nascondere l'UUID.
- **`profilo.html`** — Numeri dei 33 Kata `.fn` `.5rem` = 8px (riga 108, dato operativo puro); comandi `.cmd` `.56rem` ≈ 9px (57); nav `.bar a` ≈ 9.9px (163). — Fix: minimo 13px sui contenuti operativi.
- **`oggi.html` righe 134-139 e 61** — Orario slot, conteggio prenotati, tag corso e data odierna tra 8px e 12.8px (dati operativi). — Fix: ≥13px.
- **`agenda.html` righe 123 e 157** — `.prenot` (lista nomi iscritti) ~10px; `.pa-btn` (bottoni Presente/Assente) 10px. — Fix: ≥13px.
- **`portale.html`** — ~223 dichiarazioni `font-size` tra 10 e 12.5px; su dati operativi es. riga 1647 `.dc-meta` 12px + `var(--text3)` (coda "Da contattare"), righe 4354/4479/4487 pref/hint/valore 11.5-12.5px. — Fix: alzare a 13px i testi con dati operativi.
- **`inizia.html` / `inizia-dopo.html` righe 228 e 231** — `.slot-info .ist` (nome istruttore) 11px + `color:var(--ink3)` (grigio chiaro su dato operativo); `.slot-badge` (posti/disponibilità) 11px. — Fix: `--ink2` e ≥13px.
- **`inizia-minori.html` righe 75 e 129** — Suffisso prezzo `.prezzo small` con `var(--ink3)`; `.privacy-note` 12px. — Fix: `--ink2` e ≥13px sui dati.
- **`eventi.html` riga 74** — `.evcard .meta` 12px su data/orario partenza/luogo (dati operativi); chip conteggi 10.8px. — Fix: ≥13px.
- **`orari.html` righe 101 e 110** — `.blocco .nota` 11.5px e `.card-ev .tipo` 12px su dati corso. — Fix: ≥13px.
- **`commerciale.html` righe 71 e 74** — `.chip`/`.fermo` 10.5px su fonte/stato/campagna/"fermo da Nh" (CRM denso ma dati operativi). — Fix: ≥13px.
- **`73_KataCamp.html` righe 550, 616, 625/627, 177/261** — Footer con scadenza pagamento 10.2px; chip nomi cordata 12px; "In cordata · N/8" 11px; intestazioni programma e importi acconto 10.2px. — Fix: ≥13px sui dati operativi.
- **`guida.html` riga 123** — `.footer` legale a 8.5px; contenuti `.lead`/`.rule-box`/`.price-card` 10.5-12.5px alle viewport base. — Fix: ≥13px.
- **`proposta-advance.html` / `proposta-open.html`** — Nome istruttore `.ist` 11px e `.slot-badge` posti 12px (dati operativi). — Fix: ≥13px.

*Nota bottoni primari:* nessun bottone di azione primaria è grigio. `inizia*.html`/`inizia_lead.html` usano una primaria **blu** (`var(--sky)`), non "scura" come da regola ma non grigia — da valutare, non una violazione stretta.

---

## 4. QUALITÀ

- **`73_KataCamp.html`** — File da ~1 MB, di cui ~95% (11 immagini JPEG in **base64 inline**). — Fix: esternalizzare le immagini (repo/R2) con `<img loading="lazy">`; la pagina scende sotto ~50 KB e diventa cacheabile.
- **`73_KataCamp.html` righe ~517-531** — Blocco di commenti di configurazione (WHATSAPP/FORM_ENDPOINT/ACCADEMIA_AGENDA) lasciato nell'HTML servito. — Fix: spostare in `/docs`.
- **`monitor.html` righe 182 e 230-233** — Ramo placeholder morto `if (CFG.SUPABASE_URL.startsWith('PLACEHOLDER'))` con valori già reali + commento "sostituire prima del deploy" fuorviante. — Fix: rimuovere il ramo e il commento.
- **`evento.html` riga 144** — `t.color.replace('#16130d','#fff')` è codice morto (nessun colore in `TIPO` vale quel valore). — Fix: rimuovere o correggere la logica colore.
- **`evento.html`** — Manca `<link rel="canonical">` (presente in `eventi.html` e `orari.html`). — Fix: aggiungere canonical.
- **`proposta-open.html` (righe 175/185/194)** — Aperta senza parametri `?u/?saldo/?mezza` il blocco pagamento resta nascosto e non c'è alcuna CTA di fallback (advance ha sempre WhatsApp): utente in vicolo cieco. — Fix: aggiungere contatto WhatsApp/segreteria di fallback.
- **`proposta-advance.html` / `proposta-open.html`** — CSS e JS calendario (badge posti, `caricaDisponibilita`, `fmtData`) duplicati riga per riga: doppia manutenzione, già divergono su og:image e RPC. — Fix: estrarre un partial/JS condiviso.
- **Meta description mancante** — Assente su pagine pubbliche/semipubbliche: `grazie.html`, `kata.html`; e su pagine applicative `agenda.html`, `commerciale.html`, `monitor.html`, `oggi.html`, `profilo.html`, `valida.html`, `imposta-password.html`, `impostazioni-profilo.html`, `informativa-staff.html`, `73_KataCamp_partecipanti.html`, `provisiona_stasera.html`. — Fix: aggiungere description alle pubbliche; per le riservate è accettabile ma vanno rese `noindex` se indicizzabili.
- **`commerciale.html`** — CRM servito su `kataclimb.com/commerciale.html`, gated solo via JS ma HTML pubblico/indicizzabile senza `noindex`. — Fix: aggiungere `<meta name="robots" content="noindex,nofollow">`.
- **Caricamento Supabase disomogeneo** — Alcune pagine importano via ESM (`esm.sh`, es. `inizia*`), altre via CDN `cdn.jsdelivr.net` (`valida.html`, `profilo.html`, `73_KataCamp_partecipanti.html`). — Fix: uniformare la strategia di caricamento.
- **`monitor.html` riga 7** — `user-scalable=no` disabilita lo zoom (accessibilità). — Fix: valutare la rimozione.
- **`index.html` (righe 5-9) / `kata.html` (righe 5-9 vs 395)** — Commenti di versione incoerenti tra loro (v2.12/v3.91 vs v3.79): commenti stantii. — Fix: allineare i riferimenti di versione.
- **`_archivio/agenda_test_v3_1.html` e `_archivio/home_oggi_console_v08.html`** — Privi di `noindex` (gli altri due prototipi ce l'hanno); `agenda_test_v3_1.html` contiene `SUPABASE_URL` di produzione hardcoded (residuo). — Fix: aggiungere `noindex` se restano serviti (nessuna pagina viva li linka, coerente col README).
- **`73_KataCamp.html` (nota generale)** — Insieme all'esternalizzazione delle immagini, valutare `loading="lazy"` e conversione a formati moderni per il peso complessivo. — Fix: pipeline immagini standard.

---

## File analizzati

**Pagine HTML pubbliche/funnel:** `index.html`, `kata.html`, `guida.html`, `libro.html`, `pro.html`, `inizia.html`, `inizia-dopo.html`, `inizia-minori.html`, `inizia_lead.html`, `grazie.html`, `valida.html`, `commerciale.html`, `proposta-advance.html`, `proposta-open.html`, `provisiona_stasera.html`, `eventi.html`, `evento.html`, `orari.html`, `agenda.html`, `73_KataCamp.html`, `73_KataCamp_partecipanti.html`.

**Portale e area riservata:** `portale.html`, `profilo.html`, `impostazioni-profilo.html`, `imposta-password.html`, `informativa-staff.html`, `oggi.html`, `monitor.html`.

**Infrastruttura / config:** `sw.js`, `sw-register.js`, `site.webmanifest`, `sitemap.xml`, `robots.txt`, `CNAME`, `google01f1fc9df7ce8ed5.html`.

**Archivio (non pubblico, non linkato):** `_archivio/agenda_test_v3_1.html`, `_archivio/home_oggi_console_v08.html`, `_archivio/oggi_prototipo.html`, `_archivio/profilo_proto.html`.

**Documentazione:** `README.md`, `CLAUDE.md`.

**Asset (verifica esistenza dei riferimenti, non ispezione binaria):** favicon/icone, badge SVG, immagini `.jpg/.jpeg/.png`, PDF (`Termini_Prima_Lezione.pdf`, `Modulo_Consensi_Minori_KataClimb.pdf`) — tutti presenti tranne il `Logo_Bianco_KataClimb.png` referenziato in `index.html`.
