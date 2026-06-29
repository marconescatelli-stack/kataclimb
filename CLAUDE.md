# Regole di progetto — KataClimb

Istruzioni per Claude quando lavora su questo repository. Leggile prima di toccare un file.

## Identità (non negoziabile)
- KataClimb è un'**Accademia**, non una "palestra". Nei contenuti rivolti all'utente si dice
  sempre **Accademia**. "Palestra" è ammesso **solo** in SEO tecnico (meta description, alt text),
  mai nel testo visibile.

## Cosa c'è (e cosa NON c'è) qui
- Questo repo = **solo frontend** (GitHub Pages → kataclimb.com).
- **Worker** (Cloudflare) e **database** (Supabase) **non** sono in questo repo:
  non cercare qui la logica dei pagamenti, delle notifiche o le RPC.

## Ordine di deploy (sempre, mai invertire)
**SQL (Supabase) → Worker (Cloudflare) → Pages (questo repo).**

## Regole sui file
- Il sito live è la fonte di verità. Prima di modificare una pagina, **parti dalla versione live/`main`**,
  non da una copia vecchia (trappola storica: lavorare su file stale → si ricarica il vecchio).
- In VS Code: **aggiorna la cartella (git pull) prima di editare**. Sempre.
- Consegna/commit di **file completi e funzionanti**, non frammenti.
- Modifiche chirurgiche su un'ancora **unica** nel file; se l'ancora compare più volte, fermati.
- Valida il JS prima del commit (es. blocchi `<script type="module">`).

## Dati — una fonte, uno stato (P-VERITÀ-UNICA)
Anche se le RPC/DB non stanno qui, le pagine li leggono. Tieni presente:
- `persone` = anagrafica (nome/cognome/email/telefono). **L'anagrafica sta qui, non in `profile_data`.**
- `profile_data` = stato operativo (chiave `user_id`).
- `profiles` = VIEW che unisce `profile_data` + `persone`.
- `lead_data` = lead; `crm_leads` = VIEW su `lead_data`.
- Se due viste dicono cose diverse sulla stessa persona, è un bug strutturale, non un caso.

## Trappole note
- **Stale**: non lavorare su copie vecchie; allinea sempre al live.
- **Date in UTC**: `Date.toISOString()` converte in UTC e rompe i match di data; usare
  `getFullYear/getMonth/getDate`.
- **Anagrafica**: sta in `persone`, non in `profile_data`.
- **Nomi colonna**: mai inventarli; verificare lo schema reale prima di scrivere SQL.

## Come lavorare con Marco
- Italiano, diretto, senza fronzoli. Proposte concrete da correggere, non domande aperte.
- **Una cosa alla volta.** Niente bundle di modifiche o query.
- Davanti a un'incoerenza: non diagnosticare a memoria, chiedi secco "questo non torna, è giusto?".
- Marco non è sviluppatore: preferenza web > editor > terminale.
