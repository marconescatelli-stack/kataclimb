# DEBITO-191 · Passo 2 — Chi chiama queste funzioni

Una riga per funzione, per le 95 di priorità 1 e 2 che si possono davvero invocare, più due di
priorità 3 tirate dentro perché hanno lo stesso difetto di guardia.
Le 19 funzioni di trigger sono in fondo, separate: Postgres rifiuta di eseguirle come chiamata
diretta e PostgREST non le espone, quindi non sono una porta.

## Come è stata fatta la ricerca

Sul repo, branch `dev`, escluso `_archivio`:

```
grep -rnoE "rpc\(\s*['\"][a-z_0-9]+['\"]|rest/v1/rpc/[a-z_0-9]+" --include=*.html --include=*.js .
```

78 punti di chiamata, 55 nomi distinti. Due forme convivono: il client Supabase con `sb.rpc(...)`
e la fetch diretta su `/rest/v1/rpc/<nome>` che usano questionario-prima, completa-contatti,
orari, eventi e la pagina del KataCamp.

**Limite da dichiarare.** I Worker non stanno in questo repo. Le pagine ne nominano sette:
stripe-worker, kc-lead, kc-eventi, kataclimb-forms, kc-inserisci-contatto, noshow-bridge e
kataclimb-stream-bridge. Le funzioni che risultano senza chiamanti possono essere chiamate da
lì con `service_role`. Per questo la lista D è corta e nessuna funzione che scrive ci finisce.

A DB ho letto anche chi altro dipende da ciascuna funzione: altre funzioni, le policy RLS e le
viste. Una funzione senza chiamanti nel repo ma usata da una policy non è morta.

## Il contesto delle pagine

| contesto | pagine |
|---|---|
| **anon vero**, nessun login possibile | inizia, inizia-dopo, inizia-famiglia, inizia-giovani, sumisura, proposta-open, proposta-advance, questionario-prima, completa-contatti, evento, eventi, orari, 73_KataCamp, i due listini per minori |
| **dopo il login** | portale, agenda, oggi, commerciale, profilo, monitor, valida, listini, listino-veterani, sw-register.js |

I due listini per minori sono un caso doppio: se c'è una sessione entrano subito, altrimenti
aprono con `?u=<persona_id>` e chiamano `listino_gate` da anonimi. Vale il caso anonimo.

## La mappa

Colonna `da dove`: `anon` = la chiamata parte prima di qualunque login. `login` = dopo.
`cron` = la fa girare pg_cron. `interna` = la chiama solo un'altra funzione o un trigger.
`Worker` = nessun chiamante nel repo, ma l'endpoint del Worker esiste.

| funzione | chi la chiama | da dove | scrive | chi altro dipende | classe |
|---|---|---|---|---|---|
| `aggiorna_data_iscrizione` | `portale.html:5357` | login | sì | — | **B** |
| `aggiungi_nota_lead` | `commerciale.html:328` | login | sì | — | **B** |
| `allega_documento_consenso` | nessuno nel repo | Worker? | sì | — | **B** |
| `annulla_freeze` | `portale.html:9976` | login | sì | — | **B** |
| `avanza_sequenza_wa` | nessuno nel repo | Worker? | sì | — | **B** |
| `conta_code_lead` | `oggi.html:778` | login | no | — | **B** |
| `crea_figlio_lead` | `commerciale.html:364` | login | sì | inserisci_minore_con_referente, riconosci_figlio | **B** |
| `dichiara_freeze_forzato` | `portale.html:9929` | login | sì | — | **B** |
| `disdici_corso` | `agenda.html:2040` | login | sì | — | **B** |
| `get_consensi_minore` | `portale.html:5103` | login | no | — | **B** |
| `get_cruscotto_percorsi` | `commerciale.html:780` | login | no | — | **B** |
| `get_famiglia` | `portale.html:5091` | login | no | — | **B** |
| `get_leads_da_contattare` | `commerciale.html:775`, `portale.html:4497` | login | no | — | **B** |
| `get_qualifica_lead` | `portale.html:4794` | login | no | — | **B** |
| `get_richieste_lead` | `portale.html:5388` | login | no | — | **B** |
| `get_tesseramenti` | `portale.html:5080` | login | no | — | **B** |
| `get_timeline_persona` | nessuno nel repo | Worker? | no | — | **B** |
| `imposta_coda_fascia` | `commerciale.html:340`, `commerciale.html:347`, `portale.html:4698`, `portale.html:4704` … | login | sì | — | **B** |
| `imposta_consenso_minore` | `portale.html:5115` | login | sì | — | **B** |
| `inserisci_minore_con_referente` | `agenda.html:2399`, `portale.html:4173` | login | sì | — | **B** |
| `marca_presenza_prima_lezione` | `agenda.html:2114` | login | sì | — | **B** |
| `prenota_corso` | `agenda.html:1932` | login | sì | prenota_corso_admin | **B** |
| `registra_tesseramento` | `portale.html:5061` | login | sì | — | **B** |
| `riconosci_figlio` | nessuno nel repo | Worker? | sì | — | **B** |
| `salva_qualifica_lead` | `portale.html:4804` | login | sì | — | **B** |
| `segna_link_inviato` | `commerciale.html:265` | login | sì | — | **B** |
| `segna_memo_wa` | `commerciale.html:301` | login | sì | — | **B** |
| `segna_recensione_inviata` | `commerciale.html:314` | login | sì | — | **B** |
| `segna_recensione_inviata_persona` | `commerciale.html:725` | login | sì | — | **B** |
| `segna_step_messaggio` | `commerciale.html:273` | login | sì | — | **B** |
| `sposta_prima_lezione` | nessuno nel repo | Worker? | sì | — | **B** |
| `_puo_leggere_questionari` | — | interna | no | get_questionari_persona | **C** |
| `assert_staff` | — | interna | no | accredita_acconto_open, accredita_pagamento_manuale, accredita_saldo_open_intero, attiva_essence, essence_inserisci | **C** |
| `can_assign_badges` | — | interna | no | 1 policy RLS su profile_data | **C** |
| `completa_contatti_persona` | `completa-contatti.html:120` | anon | sì | — | **C** |
| `conteggi_prima_lezione` | `inizia.html:901`, `sumisura.html:915`, `inizia-giovani.html:920`, `inizia-famiglia.html:603` … | anon | no | — | **C** |
| `get_eventi_calendario` | `eventi.html:222`, `oggi.html:794`, `orari.html:386`, `agenda.html:1301` … | anon/login | no | — | **C** |
| `get_evento_pubblico` | `evento.html:120`, `73_KataCamp.html:618` | anon | no | — | **C** |
| `get_persona_per_completamento` | `completa-contatti.html:99` | anon | no | — | **C** |
| `get_questionario_prima_context` | `questionario-prima.html:169` | anon | no | — | **C** |
| `is_admin` | — | interna | no | 15 policy RLS | **C** |
| `is_certificatore` | — | interna | no | 1 policy RLS | **C** |
| `is_didattico` | — | interna | no | 2 policy RLS | **C** |
| `is_staff` | — | interna | no | 18 funzioni + 35 policy RLS | **C** |
| `is_tutore_di` | — | interna | no | 17 policy RLS | **C** |
| `is_veterano` | `listino-veterani.html:158`, `listini.html:131` | login | no | — | **C** |
| `listino_gate` | `listino-corsi-ragazzi.html:192`, `listino-corsi-bambini.html:182` | anon | no | — | **C** |
| `persona_visibile_community` | — | interna | no | vista profiles_community | **C** |
| `salva_questionario_prima` | `questionario-prima.html:191` | anon | sì | — | **C** |
| `slot_disponibilita` | `proposta-advance.html:242` | anon | no | slot_open_disponibilita | **C** |
| `slot_open_disponibilita` | `proposta-open.html:281` | anon | no | — | **C** |
| `_chiudi_corso_se_finito` | — | interna | sì | auto_marca_presenze_scadute, disdici_corso, marca_presenza_corso, rimarca_presenza_corso | **A** |
| `_get_lezioni_residue` | — | interna | no | cron_genera_eventi_mattutini | **A** |
| `_referente_notifica` | — | interna | no | cron_genera_eventi_mattutini, tg_prima_lezione_spostata | **A** |
| `_ruolo_attore` | — | interna | no | _snapshot_contabile, prenota_corso, prenota_corso_admin | **A** |
| `_snapshot_contabile` | — | interna | no | disdici_corso, marca_presenza_corso, rimarca_presenza_corso | **A** |
| `applica_no_show` | — | interna | no | cancella_open, marca_presenza_corso, rimarca_presenza_corso | **A** |
| `auto_marca_presenze_prima_lezione_scadute` | pg_cron job 3, ogni ora | cron | sì | — | **A** |
| `auto_marca_presenze_scadute` | pg_cron job 1, ogni ora | cron | sì | — | **A** |
| `calendario_accademia_prossime` | — | interna | no | prenota_corso, slot_disponibilita | **A** |
| `cancella_open` | nessuno nel repo | Worker? | sì | — | **A** |
| `certifica_kata` | `valida.html:339`, `portale.html:3218` | login | sì | — | **A** |
| `conferma_partecipazione_camp` | nessuno nel repo | Worker? | sì | — | **A** |
| `crea_evento` | `portale.html:10058` | login | sì | — | **A** |
| `cron_accoda_offerta_open` | pg_cron job 5, ogni ora | cron | sì | — | **A** |
| `cron_genera_eventi_mattutini` | nessuno nel repo | Worker? | sì | — | **A** |
| `delete_push_subscription` | `sw-register.js:184` | login | sì | — | **A** |
| `dichiara_freeze` | nessuno nel repo | Worker? | sì | — | **A** |
| `disdici_corso_admin` | `agenda.html:2701` | login | sì | — | **A** |
| `garantisci_persona` | — | interna | sì | crea_figlio_lead, crea_prenotazioni_gruppo, find_or_create_persona_e_richiesta, handle_new_user, inserisci_minore_con_referente, tg_crm_leads_insert | **A** |
| `get_iscritti_minori` | `agenda.html:1355` | login | no | — | **A** |
| `imposta_status_iscrizione_minore` | `agenda.html:1858` | login | sì | — | **A** |
| `invia_push_test` | `portale.html:7273` | login | no | — | **A** |
| `iscrivi_minore` | — | interna | sì | iscrivi_minore_da_lead | **A** |
| `iscrivi_minore_da_lead` | `agenda.html:2435` | login | no | — | **A** |
| `libera_prenotazioni_scadute` | pg_cron job 4, ogni 5 minuti | cron | sì | — | **A** |
| `marca_presenza_corso` | `agenda.html:2121` | login | sì | — | **A** |
| `materializza_prima_lezione_mancante` | nessuno nel repo | Worker? | sì | — | **A** |
| `miei_figli` | nessuno nel repo | Worker? | no | — | **A** |
| `popola_feste_comandate` | pg_cron job 6, annuale | cron | sì | — | **A** |
| `prenota_corso_admin` | `agenda.html:2612` | login | sì | — | **A** |
| `registra_evento_notifica` | — | interna | sì | cron_genera_eventi_mattutini, tg_prima_lezione_spostata | **A** |
| `registra_pagamento_manuale_admin` | nessuno nel repo | Worker? | sì | — | **A** |
| `riattiva_freeze_se_scaduto` | nessuno nel repo | Worker? | sì | — | **A** |
| `ricalcola_cache_contatori` | — | interna | sì | ricalcola_cache_tutti, tg_ricalcola_cache_contatori | **A** |
| `ricalcola_cache_tutti` | nessuno nel repo | Worker? | no | — | **A** |
| `riconosci_pregresso` | — | interna | sì | conferma_partecipazione_camp | **A** |
| `rifiuta_kata` | `valida.html:357` | login | sì | — | **A** |
| `rimarca_presenza_corso` | `agenda.html:2176`, `portale.html:6652`, `portale.html:6673` | login | sì | — | **A** |
| `smista_commerciale_scaduti` | nessuno nel repo | Worker? | sì | — | **A** |
| `sposta_corso` | `agenda.html:2677` | login | sì | — | **A** |
| `sposta_kata` | nessuno nel repo | Worker? | sì | — | **A** |
| `staff_chiudi_giorno` | nessuno nel repo | Worker? | sì | — | **A** |
| `staff_riapri_giorno` | nessuno nel repo | Worker? | sì | — | **A** |
| `upsert_push_subscription` | `sw-register.js:153` | login | sì | — | **A** |
| `_get_spostamenti_residui` | nessuno nel repo | Worker? | no | — | **D** |
| `get_voce_breakdown` | nessuno nel repo | Worker? | no | — | **D** |

## Le 19 funzioni di trigger

Hanno `EXECUTE` ad anon come tutte le altre, ma non sono invocabili: Postgres risponde
*trigger functions can only be called as triggers* e PostgREST non le pubblica. Restano in elenco
perché la revoca è igiene a costo zero, e perché il privilegio viene controllato quando si crea il
trigger, non a ogni scatto: revocarlo non spegne nulla.

| funzione | tabella su cui scatta |
|---|---|
| `_provisiona_da_prenotazione_prima` | prenotazioni_prima_lezione |
| `_sync_prima_done` | prenotazioni_prima_lezione |
| `_trg_open_presenza_garantisce_corso` | prenotazioni_corso |
| `enforce_slot_capacity` | prenotazioni_prima_lezione |
| `handle_new_user` | auth.users |
| `tg_crm_leads_delete` | crm_leads |
| `tg_crm_leads_insert` | crm_leads |
| `tg_crm_leads_update` | crm_leads |
| `tg_email_eventi_persona` | email_eventi |
| `tg_lead_data_fonte_autoregistra` | lead_data |
| `tg_lead_richieste_derive_fonte` | lead_richieste |
| `tg_lead_richieste_notifica` | lead_richieste |
| `tg_onboarding_spegni_su_prenotazione` | prenotazioni_corso |
| `tg_prima_lezione_spostata` | prenotazioni_prima_lezione |
| `tg_profiles_delete` | profiles |
| `tg_profiles_update` | profiles |
| `tg_ricalcola_cache_contatori` | iscrizioni_corso e prenotazioni_corso |
| `tg_set_data_scadenza_open` | presenze_corso |
| `tg_tesseramento_da_iscrizione` | profile_data |

## Funzioni senza chiamanti nel repo

Da leggere come domande per Marco, non come condanne.

| funzione | scrive | ipotesi |
|---|---|---|
| `_get_spostamenti_residui` | no | Nessun chiamante nel repo e nessun dipendente a DB: il gemello _get_lezioni_residue è usato, questa no. Sola lettura. |
| `allega_documento_consenso` | sì | Guardia inefficace verso anon. Scrive il percorso di un documento di consenso. |
| `avanza_sequenza_wa` | sì | Guardia inefficace verso anon. Scrive lo stato della sequenza WhatsApp. |
| `cancella_open` | sì | Guardia con IS DISTINCT FROM, che regge il NULL. Nessun chiamante nel repo. |
| `conferma_partecipazione_camp` | sì | Nessun chiamante nel repo: la chiama il Worker kc-eventi sul percorso /conferma. Da confermare con Marco. |
| `cron_genera_eventi_mattutini` | sì | Non è in pg_cron e nessuna pagina la chiama: la sveglia il Worker delle notifiche, che usa service_role. Da confermare con Marco. |
| `dichiara_freeze` | sì | Guardia con IS DISTINCT FROM. Nessun chiamante nel repo. |
| `get_timeline_persona` | no | Guardia inefficace verso anon. Restituisce la storia completa di una persona. |
| `get_voce_breakdown` | no | Nessun chiamante nel repo, nessun dipendente a DB, nessun job. Sola lettura. |
| `materializza_prima_lezione_mancante` | sì | Guardia su staff_creator e staff_segreteria. Nessun chiamante nel repo. |
| `miei_figli` | no | Filtra su auth.uid(): ad anon torna vuota. Revoca per igiene. |
| `registra_pagamento_manuale_admin` | sì | Guardia is_staff(). Chiamata da portale.html. |
| `riattiva_freeze_se_scaduto` | sì | Nessun chiamante nel repo e nessun dipendente a DB. Scrive: revoca ora, rimozione da decidere. |
| `ricalcola_cache_tutti` | no | Guardia is_staff() con deroga a postgres e service_role. |
| `riconosci_figlio` | sì | Solo authenticated, quindi non esposta ad anon, ma la guardia ha la stessa forma fragile. Da sanare insieme alle altre. |
| `smista_commerciale_scaduti` | sì | Nessun chiamante nel repo e nessun job. Scrive: la revoca è prudente, la rimozione va decisa. |
| `sposta_kata` | sì | Solo creator, respinge NULL. |
| `sposta_prima_lezione` | sì | Due firme, solo authenticated. Quella a tre argomenti ha lo stesso difetto NULL NOT IN: un allievo loggato passa. Quella a quattro argomenti e gia corretta e non si tocca. |
| `staff_chiudi_giorno` | sì | Guardia is_staff(). |
| `staff_riapri_giorno` | sì | Guardia is_staff(). |

