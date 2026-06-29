# KataClimb — sito Accademia RCC

Frontend pubblico e portale dell'**Accademia RCC** (KataClimb / Syncrolink Ltd).
Questo repository contiene **solo le pagine web**. Worker e database stanno altrove (vedi sotto).

## Hosting
- Servito da **GitHub Pages** dalla root del repo.
- Dominio: file `CNAME` → **kataclimb.com**.
- Ogni push sul branch `main` aggiorna il sito live in pochi minuti.

## Pagine principali
| File | A cosa serve |
|---|---|
| `index.html` | Home / sito brand |
| `inizia.html` | Funnel Prima Lezione (Meta Ads → checkout) |
| `grazie.html` | Conferma post-pagamento |
| `proposta-open.html` | Proposta Open (link corto `?u=<persona_id>`) |
| `proposta-advance.html` | Proposta Advance |
| `portale.html` | Portale allievo / fascicoli |
| `oggi.html` | Vista operativa del giorno |
| `agenda.html` | Agenda / prenotazioni |
| `commerciale.html` | CRM lead (Commerciali · Riacciuffo · Segreteria) |
| `kata.html` · `valida.html` | Sistema Kata e sala revisione |
| `eventi.html` · `evento.html` | Eventi / uscite |
| `monitor.html` · `pro.html` · `guida.html` · `libro.html` | Aree di supporto |

## Cartelle
- `_archivio/` — vecchie bozze e prototipi **non pubblici** (es. `*_proto`, `*_test`, `*_v08`).
  Conservati per storia, non linkati da nessuna pagina viva.

## Infrastruttura esterna (NON in questo repo)
- **Cloudflare Workers**: `stripe-worker`, `kataclimb-notifiche`, `kc-lead`, ecc.
  (funnel pagamenti, notifiche, lead). Deploy separato su Cloudflare.
- **Supabase** (`wbtougychlhnlcnonqge`): database, RPC, auth. Gestito via SQL/MCP.

## Ordine di deploy (sempre)
**SQL (Supabase) → Worker (Cloudflare) → Pages (questo repo).** Mai invertire.
