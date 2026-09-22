# DEBITO-191 · Passo 1 — Censimento delle funzioni SECURITY DEFINER

Eseguito il **22 settembre 2026**, ore 18:40 (Europe/Rome), su Supabase `wbtougychlhnlcnonqge` (produzione),
in sola lettura, con `SELECT set_config('app.origine','claude',false)` in testa a ogni sessione.
Fonte: le due SELECT di `sql/audit-security-definer.sql`, senza modifiche.

> **Questa è una fotografia, e il database si è mosso dopo.** Alle 21:16 dello stesso giorno la
> migration `sposta_prima_lezione_unifica_overload` ha eliminato la firma a tre argomenti di
> `sposta_prima_lezione`, che qui sotto compare ancora. Da allora quel nome ha una firma sola,
> quella a quattro. Il resto del censimento non è toccato.

## I numeri

| grandezza | valore |
|---|---|
| funzioni SECURITY DEFINER nello schema `public` | **153** |
| eseguibili da `anon` (e quindi da chiunque abbia la chiave pubblica) | **114** |
| priorità 1 · aperte ad anon senza guardia visibile | **51** |
| di cui funzioni di trigger, non invocabili via PostgREST | **19** |
| priorità 1 reali, invocabili e senza guardia | **32** |
| priorità 2 · aperte ad anon, una guardia ce l'hanno | **63** |
| priorità 3 · ristrette (authenticated o service_role) | **39** |
| guardie che citano ruoli inesistenti nel CHECK | **22** |

Il totale è **153**, non 117: la stima della consegna era prudente.
Tutte e 153 hanno per proprietario `postgres`, quindi girano con i privilegi più alti del progetto.

## Come leggere la colonna `guardia`

La colonna dice quale *forma* di controllo compare nel corpo, non se quel controllo funziona.
Il Passo 3 verifica se funziona, e per 25 funzioni la risposta è no.

## Sezione 1 · Tutte le SECURITY DEFINER, per esposizione

### Priorità 1 · da guardare subito — 51 funzioni

| funzione | proprietario | chi può chiamarla | guardia | priorità |
|---|---|---|---|---|
| `_get_lezioni_residue(p_user_id uuid, p_corso text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `_get_spostamenti_residui(p_user_id uuid, p_corso text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `_provisiona_da_prenotazione_prima()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `_referente_notifica(p_persona_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `_sync_prima_done()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `_trg_open_presenza_garantisce_corso()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `aggiorna_data_iscrizione(p_user_id uuid, p_tipo_corso text, p_data date)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `applica_no_show(p_user_id uuid, p_tipo_corso text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `auto_marca_presenze_prima_lezione_scadute()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `auto_marca_presenze_scadute()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `calendario_accademia_prossime(n integer)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `completa_contatti_persona(p_persona_id uuid, p_email text, p_telefono text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `conferma_partecipazione_camp(p_part_id uuid, p_user_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `conteggi_prima_lezione(p_dal date, p_al date)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `cron_accoda_offerta_open()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `cron_genera_eventi_mattutini()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `enforce_slot_capacity()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `garantisci_persona(p_email text, p_nome text, p_cognome text, p_telefono text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_eventi_calendario()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_evento_pubblico(p_slug text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_persona_per_completamento(p_persona_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_questionario_prima_context(p_prenotazione_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_tesseramenti(p_user_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `get_voce_breakdown(p_voce_id text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `handle_new_user()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `libera_prenotazioni_scadute()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `listino_gate(p_u uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `persona_visibile_community(p_persona_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `popola_feste_comandate(p_anni integer)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `registra_evento_notifica(p_tipo text, p_user_id uuid, p_canale text, p_payload jsonb, p_schedulato_per timestamp with time zone, p_dedup_key text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `riattiva_freeze_se_scaduto(p_user_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `ricalcola_cache_contatori(p_user_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `riconosci_pregresso(p_user_id uuid)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `salva_questionario_prima(p_prenotazione_id uuid, p_risposte jsonb, p_vuole_proposta boolean, p_consenso boolean)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `slot_disponibilita(p_tipo_corso text)` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `slot_open_disponibilita()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `smista_commerciale_scaduti()` | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_crm_leads_delete()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_crm_leads_insert()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_crm_leads_update()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_email_eventi_persona()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_lead_data_fonte_autoregistra()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_lead_richieste_derive_fonte()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_lead_richieste_notifica()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_onboarding_spegni_su_prenotazione()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_prima_lezione_spostata()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_profiles_delete()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_profiles_update()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_ricalcola_cache_contatori()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_set_data_scadenza_open()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |
| `tg_tesseramento_da_iscrizione()` · *funzione di trigger* | postgres | anon + authenticated | NESSUNA GUARDIA VISIBILE | 1 |

### Priorità 2 · aperte ad anon, con una guardia — 63 funzioni

| funzione | proprietario | chi può chiamarla | guardia | priorità |
|---|---|---|---|---|
| `_chiudi_corso_se_finito(p_user_id uuid)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `_puo_leggere_questionari(p_persona_id uuid)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `_ruolo_attore(p_user_id uuid, p_funzione text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `_snapshot_contabile(p_user_id uuid, p_tipo_corso text, p_funzione text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `aggiungi_nota_lead(p_lead_id uuid, p_testo text, p_tipo text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `allega_documento_consenso(p_lead_id uuid, p_path text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `annulla_freeze(p_user_id uuid, p_motivo text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `assert_staff()` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `avanza_sequenza_wa(p_lead_id uuid, p_step integer)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `can_assign_badges()` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `cancella_open(p_prenotazione_id uuid, p_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `certifica_kata(p_user_id uuid, p_kata_num integer)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `conta_code_lead()` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `crea_evento(p_nome text, p_tipo text, p_data_inizio date, p_data_fine date, p_luogo text, p_requisito text, p_descrizione text, p_punto_incontro text, p_punto_incontro_url text, p_ora_partenza time without time zone, p_ora_rientro time without time zone, p_tema text, p_corso_richiesto text, p_grado_min text, p_grado_max text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `crea_figlio_lead(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `delete_push_subscription(p_endpoint text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `dichiara_freeze(p_user_id uuid, p_inizio date, p_fine date, p_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `dichiara_freeze_forzato(p_user_id uuid, p_inizio timestamp with time zone, p_fine timestamp with time zone, p_motivo text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `disdici_corso(p_prenotazione_id uuid, p_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `disdici_corso_admin(p_prenotazione_id uuid, p_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `get_consensi_minore(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_cruscotto_percorsi()` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_famiglia(p_persona_id uuid, p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_iscritti_minori()` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `get_leads_da_contattare()` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_qualifica_lead(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_richieste_lead(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `get_timeline_persona(p_persona_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `imposta_coda_fascia(p_lead_id uuid, p_coda text, p_fascia text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `imposta_consenso_minore(p_lead_id uuid, p_tipo text, p_concesso boolean, p_note text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `imposta_status_iscrizione_minore(p_iscrizione_id uuid, p_status text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `inserisci_minore_con_referente(p_figlio_nome text, p_figlio_cognome text, p_fascia text, p_gen_nome text, p_gen_cognome text, p_gen_email text, p_gen_telefono text, p_figlio_nascita date, p_note text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `invia_push_test(p_title text, p_body text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `is_admin()` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `is_certificatore()` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `is_didattico()` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `is_staff()` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `is_tutore_di(p_user uuid)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `is_veterano(p_user_id uuid)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `iscrivi_minore(p_persona_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `iscrivi_minore_da_lead(p_lead_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `marca_presenza_corso(p_prenotazione_id uuid, p_presente boolean)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `materializza_prima_lezione_mancante(p_user_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `miei_figli()` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `prenota_corso_admin(p_user_id uuid, p_slot_id uuid, p_data_lezione date, p_scala_credito boolean, p_omaggio_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `registra_pagamento_manuale_admin(p_user_id uuid, p_prodotto text, p_data_pagamento date, p_metodo text, p_note text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `registra_tesseramento(p_user_id uuid, p_anno integer, p_data_inizio date, p_assicurazione boolean, p_note text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `ricalcola_cache_tutti()` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `rifiuta_kata(p_user_id uuid, p_kata_num integer, p_feedback text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `rimarca_presenza_corso(p_prenotazione_id uuid, p_nuovo_stato text, p_motivo text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `salva_qualifica_lead(p_lead_id uuid, p_lavoro text, p_esperienza_sport text, p_motivo_ora text, p_freno text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `segna_link_inviato(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `segna_memo_wa(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `segna_recensione_inviata(p_lead_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `segna_recensione_inviata_persona(p_persona_id uuid)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `segna_step_messaggio(p_lead_id uuid, p_step text)` | postgres | anon + authenticated | controlla staff_role a mano | 2 |
| `sposta_corso(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `sposta_kata(p_user_id uuid, p_kata_da integer, p_kata_a integer)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |
| `staff_chiudi_giorno(p_data date, p_motivo text)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `staff_riapri_giorno(p_data date)` | postgres | anon + authenticated | is_staff / assert_staff | 2 |
| `upsert_push_subscription(p_endpoint text, p_p256dh_key text, p_auth_key text, p_user_agent text, p_device_label text)` | postgres | anon + authenticated | usa auth.uid(), da leggere | 2 |

### Priorità 3 · ristrette — 39 funzioni

| funzione | proprietario | chi può chiamarla | guardia | priorità |
|---|---|---|---|---|
| `accredita_acconto_open(p_user_id uuid, p_data_inizio date, p_metodo text, p_lezioni integer, p_note text)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `accredita_advance(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_advance_2xsett(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_advance_intero(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_advance_mese1(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_advance_mese2(p_user_id uuid, p_data_pagamento date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_evo(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_evo_intero(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_evo_mese1(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_evo_mese2(p_user_id uuid, p_data_pagamento date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_intro(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_intro_intero(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_intro_mese1(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_intro_mese2(p_user_id uuid, p_data_pagamento date, p_metodo text, p_note text)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_iscrizione(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_iscrizione_meta_open(p_user_id uuid)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_mezza1_open(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_mezza2_open(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_pacchetto_meta_open(p_user_id uuid)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_pacchetto_open(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_pacchetto_open_intero(p_user_id uuid)` | postgres | solo service_role | usa auth.uid(), da leggere | 3 |
| `accredita_pagamento_manuale(p_persona_id uuid, p_voce text, p_metodo text, p_note text, p_data_inizio date)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `accredita_prima_lezione(p_user_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `accredita_saldo_open_intero(p_user_id uuid, p_data_inizio date, p_metodo text, p_note text)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `approva_testimonianza(p_questionario_id uuid, p_estratto text, p_approvata boolean)` | postgres | authenticated | usa auth.uid(), da leggere | 3 |
| `attiva_essence(p_email text, p_edizione text, p_nota text)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `crea_prenotazioni_gruppo(p_partecipanti jsonb, p_slot_id uuid, p_data_lezione date, p_stripe_session_id text)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `cron_accoda_listino_minori(p_dry_run boolean)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `essence_inserisci(p_nome text, p_cognome text, p_email text, p_telefono text, p_formula text, p_edizione text, p_nota text)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `find_or_create_persona_e_richiesta(p_email text, p_nome text, p_cognome text, p_telefono text, p_canale text, p_campagna text, p_utm_source text, p_utm_medium text, p_utm_campaign text, p_utm_content text, p_utm_term text, p_fbclid text, p_pagina text, p_note text)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `garantisci_profilo(p_persona_id uuid)` | postgres | authenticated | NESSUNA GUARDIA VISIBILE | 3 |
| `get_questionari_persona(p_persona_id uuid)` | postgres | authenticated | NESSUNA GUARDIA VISIBILE | 3 |
| `listino_destinatari(p_persona_id uuid)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `provisiona_figlio(p_persona_id uuid, p_tutore_user_id uuid, p_data_prima_lezione date)` | postgres | solo service_role | NESSUNA GUARDIA VISIBILE | 3 |
| `riconosci_figlio(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text, p_nascita date)` | postgres | authenticated | controlla staff_role a mano | 3 |
| `riconosci_percorso_pregresso(p_user_id uuid, p_completato_fino_a text, p_corso_attuale text, p_attuale_paid boolean, p_data date)` | postgres | authenticated | is_staff / assert_staff | 3 |
| `sposta_prima_lezione(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date)` ⚠️ *eliminata alle 21:16 dello stesso giorno* | postgres | authenticated | controlla staff_role a mano | 3 |
| `sposta_prima_lezione(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date, p_tutto_il_gruppo boolean)` | postgres | authenticated | controlla staff_role a mano | 3 |
| `staff_attiva_corso(p_user_id uuid, p_corso text, p_skip_staff_check boolean)` | postgres | solo service_role | is_staff / assert_staff | 3 |

## Sezione 2 · Guardie che confrontano `staff_role` con valori che non esistono

La seconda SELECT dell'audit, per come è scritta, torna **vuota**: cerca i valori nella forma
`'valore'::text`, mentre nei corpi i confronti sono scritti `staff_role IN ('creator','admin',…)`,
senza cast esplicito. L'ho quindi rieseguita sui corpi restituiti da `pg_get_functiondef`.
Il risultato non è una funzione sola: sono **18**.

I soli valori ammessi dal CHECK a DB (`profile_data_staff_role_check`, riletto il 22 set) sono:

```
staff_creator · staff_segreteria · staff_istruttore_tutor · staff_istruttore_sr
staff_istruttore_jr · staff_assistente · staff_monitor
```

| funzione | valori citati che non esistono |
|---|---|
| `aggiungi_nota_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `allega_documento_consenso` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `avanza_sequenza_wa` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `conta_code_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `crea_figlio_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_consensi_minore` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_cruscotto_percorsi` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_famiglia` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_leads_da_contattare` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_qualifica_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_richieste_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `get_timeline_persona` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `imposta_coda_fascia` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `imposta_consenso_minore` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `inserisci_minore_con_referente` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `riconosci_figlio` | `segreteria` |
| `salva_qualifica_lead` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `segna_link_inviato` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `segna_memo_wa` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `segna_recensione_inviata` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `segna_recensione_inviata_persona` | `admin`, `creator`, `istruttore_senior`, `segreteria` |
| `segna_step_messaggio` | `admin`, `creator`, `istruttore_senior`, `segreteria` |

Le prime 18 confrontano tutte la stessa lista: `creator`, `admin`, `segreteria`, `istruttore_senior`,
più l'unico valore vero `staff_istruttore_sr`. `invia_push_test` cita `staff_creator`, che esiste: sta in
tabella solo perché la ricerca include chi nomina `staff_role`.

Effetto pratico, contando le persone a DB il 22 set: **11 persone hanno uno `staff_role`**.
Di queste, le 18 funzioni del CRM ne ammettono **3** (gli `staff_istruttore_sr`), più Marco che passa
da un UUID scritto a mano nel corpo. Le **2 persone di segreteria** sono respinte da tutte e 18.

## Conteggi per ACL e per forma di guardia

**chi può chiamarla**

| valore | funzioni |
|---|---|
| anon + authenticated | 114 |
| solo service_role | 27 |
| authenticated | 12 |

**guardia dichiarata**

| valore | funzioni |
|---|---|
| NESSUNA GUARDIA VISIBILE | 69 |
| usa auth.uid(), da leggere | 30 |
| controlla staff_role a mano | 30 |
| is_staff / assert_staff | 24 |

