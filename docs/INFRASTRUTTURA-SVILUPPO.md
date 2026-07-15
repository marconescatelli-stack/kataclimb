# Infrastruttura di sviluppo — stato al 15 luglio 2026

Documento di riferimento unico. Vale per le chat Claude (progetto portale) e per l'agente Claude Code (copia in `/docs` del repo kataclimb, branch dev).

## Architettura dei flussi

| Ambiente | Cosa | Fonte | URL |
|---|---|---|---|
| Produzione | Sito pubblico + portale | branch `main` (GitHub Pages) | kataclimb.com |
| Sviluppo | Clone di lavoro | branch `dev` (Cloudflare Pages, progetto `kataclimb-dev`) | kataclimb-dev.pages.dev |

- Ogni commit su `dev` aggiorna automaticamente l'anteprima. `main` non si tocca mai direttamente.
- Il passaggio in produzione avviene SOLO con merge `dev` → `main` fatto da Marco, dopo verifica sull'anteprima.
- Il progetto Cloudflare Pages `kataclimb-dev` è solo sviluppo: cancellarlo non tocca né sito né repo.

## Superfici di lavoro

1. **Chat Claude (questa)** — strategia, architettura, scrittura task, query Supabase via MCP, decisioni. Non esegue lavoro sui repo.
2. **Agente Claude Code cloud (claude.ai/code)** — esegue i task sul repo GitHub `kataclimb`, branch `dev`. Ogni task si chiude con una pull request. App GitHub "Claude" installata sull'account `marconescatelli-stack` con accesso a tutti i repo. Sessioni visibili da browser, app desktop (tab Code) e app mobile.
3. **Claude Code CLI (Mac)** — installato su MacBook Air M1 (v2.1.210+, installer nativo, login con abbonamento Max). Uso occasionale per lavoro locale; `claude --teleport` recupera sessioni cloud nel terminale.

## Regole per l'agente

- Il repo contiene `CLAUDE.md` nella radice (branch dev): regole di lavoro, stack, vincoli DB e UI, entità da non confondere. L'agente lo legge automaticamente a ogni sessione. Ogni modifica alle regole di lavoro va riportata lì.
- Task sempre piccoli e perimetrati: file da toccare, cosa verificare, cosa NON toccare. Mai "vai avanti con la roadmap".
- Task visivi (UI, testi, layout): via libera. Task che toccano scritture su DB o pagamenti: VIETATI finché non esiste un database di sviluppo separato (branching Supabase, da configurare quando servirà). L'anteprima parla con il Supabase di PRODUZIONE: i branch isolano il codice, non il database.

## Ciclo di lavoro standard

1. In chat (progetto portale): si definisce il prossimo pezzo e si scrive il task
2. Marco incolla il task su claude.ai/code (repo kataclimb, branch dev)
3. L'agente lavora e apre una PR verso dev
4. Marco verifica la PR e il risultato su kataclimb-dev.pages.dev
5. Merge su dev; quando un blocco è completo e verificato, merge dev → main (produzione)

## Primo task in corso

Audit completo del repo in sola lettura → output `AUDIT.md` via PR. Il report diventa la base della roadmap esecutiva: ogni voce = un task candidato.

## Promemoria aperti

- Login Google sul clone: aggiungere kataclimb-dev.pages.dev alle origini autorizzate OAuth (Google Cloud, client KataClimb Web) e ai redirect Supabase — da fare al primo task che richiede login sull'anteprima.
- Documentazione specializzata (DB, Frontend, Infra): da copiare progressivamente in `/docs` del repo quando i task la richiederanno.
- GitHub Action di review automatica delle PR: da valutare quando il flusso con l'agente sarà rodato.
- Report mattutino programmato (siti + lead + prenotazioni, ore 8): preparato in chat, attivazione a discrezione di Marco.
