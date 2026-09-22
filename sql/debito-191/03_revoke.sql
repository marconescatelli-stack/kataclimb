-- ============================================================================
-- DEBITO-191 · 03 · REVOKE — chiudere le porte lasciate aperte dal default
-- Preparato il 22 settembre 2026 · NON APPLICATO
--
-- Questo file non cambia una riga di logica: toglie privilegi, e si annulla
-- con un GRANT. E' il primo da applicare e da solo chiude l'esposizione ad anon.
--
-- ATTENZIONE, LA COSA PIU' IMPORTANTE DI QUESTO FILE
--   113 di queste funzioni hanno EXECUTE su PUBLIC, non solo su anon:
--       =X/postgres postgres=X/postgres anon=X/postgres authenticated=X/postgres ...
--   la prima voce, quella senza nome a sinistra dell'uguale, e' PUBLIC.
--   Un REVOKE ... FROM anon da solo NON chiude niente: anon continua a eseguire
--   per via di PUBLIC. Per questo ogni riga qui sotto revoca da PUBLIC e da anon.
--
-- E SUBITO DOPO, IL GRANT
--   Dopo aver tolto PUBLIC si rida' EXECUTE, per nome, a chi deve restare.
--   A DB authenticated ha gia' un GRANT esplicito su tutte queste funzioni, quindi
--   il GRANT qui sotto conferma cio' che c'e' gia' e non cambia lo stato: serve a
--   rendere il file autosufficiente e ripetibile, e a non dover ricordare a memoria
--   chi aveva cosa. Idem per service_role.
--
-- CHI NON PERDE NIENTE, VERIFICATO IL 22 SET
--   · postgres  — proprietario di tutte e 153 le funzioni, EXECUTE esplicito.
--   · i 5 job di pg_cron — cron.job.username e' 'postgres' per tutti e cinque,
--     quindi girano come il proprietario e non passano da PUBLIC.
--   · service_role — GRANT esplicito, i Worker continuano a chiamare.
--   · i trigger — il privilegio EXECUTE su una funzione di trigger si controlla
--     quando il trigger viene creato, non a ogni scatto. La sezione 4 resta
--     comunque separata e facoltativa.
-- ============================================================================

BEGIN;

-- ─── 1 · Staff loggato — perdono anon, tengono authenticated ─────
-- La guardia interna regge gia': respinge un chiamante senza sessione.
-- Qui si toglie solo il privilegio che non e' mai servito a nessuno.

-- chiamanti: agenda.html:2121
REVOKE EXECUTE ON FUNCTION public.marca_presenza_corso(p_prenotazione_id uuid, p_presente boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_corso(p_prenotazione_id uuid, p_presente boolean) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_corso(p_prenotazione_id uuid, p_presente boolean) TO service_role;

-- chiamanti: agenda.html:2114
REVOKE EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) TO service_role;

-- chiamanti: agenda.html:2176, portale.html:6652, portale.html:6673
REVOKE EXECUTE ON FUNCTION public.rimarca_presenza_corso(p_prenotazione_id uuid, p_nuovo_stato text, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rimarca_presenza_corso(p_prenotazione_id uuid, p_nuovo_stato text, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rimarca_presenza_corso(p_prenotazione_id uuid, p_nuovo_stato text, p_motivo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia su staff_creator e staff_segreteria. Nessun chiamante nel repo.
REVOKE EXECUTE ON FUNCTION public.materializza_prima_lezione_mancante(p_user_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.materializza_prima_lezione_mancante(p_user_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.materializza_prima_lezione_mancante(p_user_id uuid) TO service_role;

-- chiamanti: agenda.html:2612
REVOKE EXECUTE ON FUNCTION public.prenota_corso_admin(p_user_id uuid, p_slot_id uuid, p_data_lezione date, p_scala_credito boolean, p_omaggio_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.prenota_corso_admin(p_user_id uuid, p_slot_id uuid, p_data_lezione date, p_scala_credito boolean, p_omaggio_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.prenota_corso_admin(p_user_id uuid, p_slot_id uuid, p_data_lezione date, p_scala_credito boolean, p_omaggio_motivo text) TO service_role;

-- chiamanti: agenda.html:2701
REVOKE EXECUTE ON FUNCTION public.disdici_corso_admin(p_prenotazione_id uuid, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.disdici_corso_admin(p_prenotazione_id uuid, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.disdici_corso_admin(p_prenotazione_id uuid, p_motivo text) TO service_role;

-- chiamanti: agenda.html:2677
REVOKE EXECUTE ON FUNCTION public.sposta_corso(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.sposta_corso(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.sposta_corso(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date) TO service_role;

-- chiamanti: nessuno nel repo · Guardia con IS DISTINCT FROM, che regge il NULL. Nessun chiamante nel repo.
REVOKE EXECUTE ON FUNCTION public.cancella_open(p_prenotazione_id uuid, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.cancella_open(p_prenotazione_id uuid, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.cancella_open(p_prenotazione_id uuid, p_motivo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia con IS DISTINCT FROM. Nessun chiamante nel repo.
REVOKE EXECUTE ON FUNCTION public.dichiara_freeze(p_user_id uuid, p_inizio date, p_fine date, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.dichiara_freeze(p_user_id uuid, p_inizio date, p_fine date, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.dichiara_freeze(p_user_id uuid, p_inizio date, p_fine date, p_motivo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia is_staff().
REVOKE EXECUTE ON FUNCTION public.iscrivi_minore(p_persona_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.iscrivi_minore(p_persona_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.iscrivi_minore(p_persona_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) TO service_role;

-- chiamanti: agenda.html:2435
REVOKE EXECUTE ON FUNCTION public.iscrivi_minore_da_lead(p_lead_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.iscrivi_minore_da_lead(p_lead_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.iscrivi_minore_da_lead(p_lead_id uuid, p_slot_ids uuid[], p_data_inizio date, p_data_fine date, p_paid boolean, p_note text) TO service_role;

-- chiamanti: agenda.html:1858
REVOKE EXECUTE ON FUNCTION public.imposta_status_iscrizione_minore(p_iscrizione_id uuid, p_status text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.imposta_status_iscrizione_minore(p_iscrizione_id uuid, p_status text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.imposta_status_iscrizione_minore(p_iscrizione_id uuid, p_status text) TO service_role;

-- chiamanti: agenda.html:1355
REVOKE EXECUTE ON FUNCTION public.get_iscritti_minori() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_iscritti_minori() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_iscritti_minori() TO service_role;

-- chiamanti: nessuno nel repo · Guardia is_staff(). Chiamata da portale.html.
REVOKE EXECUTE ON FUNCTION public.registra_pagamento_manuale_admin(p_user_id uuid, p_prodotto text, p_data_pagamento date, p_metodo text, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.registra_pagamento_manuale_admin(p_user_id uuid, p_prodotto text, p_data_pagamento date, p_metodo text, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.registra_pagamento_manuale_admin(p_user_id uuid, p_prodotto text, p_data_pagamento date, p_metodo text, p_note text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia is_staff() con deroga a postgres e service_role.
REVOKE EXECUTE ON FUNCTION public.ricalcola_cache_tutti() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.ricalcola_cache_tutti() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.ricalcola_cache_tutti() TO service_role;

-- chiamanti: nessuno nel repo · Guardia is_staff().
REVOKE EXECUTE ON FUNCTION public.staff_chiudi_giorno(p_data date, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.staff_chiudi_giorno(p_data date, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.staff_chiudi_giorno(p_data date, p_motivo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia is_staff().
REVOKE EXECUTE ON FUNCTION public.staff_riapri_giorno(p_data date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.staff_riapri_giorno(p_data date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.staff_riapri_giorno(p_data date) TO service_role;

-- chiamanti: valida.html:339, portale.html:3218
REVOKE EXECUTE ON FUNCTION public.certifica_kata(p_user_id uuid, p_kata_num integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.certifica_kata(p_user_id uuid, p_kata_num integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.certifica_kata(p_user_id uuid, p_kata_num integer) TO service_role;

-- chiamanti: valida.html:357
REVOKE EXECUTE ON FUNCTION public.rifiuta_kata(p_user_id uuid, p_kata_num integer, p_feedback text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.rifiuta_kata(p_user_id uuid, p_kata_num integer, p_feedback text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.rifiuta_kata(p_user_id uuid, p_kata_num integer, p_feedback text) TO service_role;

-- chiamanti: nessuno nel repo · Solo creator, respinge NULL.
REVOKE EXECUTE ON FUNCTION public.sposta_kata(p_user_id uuid, p_kata_da integer, p_kata_a integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.sposta_kata(p_user_id uuid, p_kata_da integer, p_kata_a integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.sposta_kata(p_user_id uuid, p_kata_da integer, p_kata_a integer) TO service_role;

-- chiamanti: portale.html:10058
REVOKE EXECUTE ON FUNCTION public.crea_evento(p_nome text, p_tipo text, p_data_inizio date, p_data_fine date, p_luogo text, p_requisito text, p_descrizione text, p_punto_incontro text, p_punto_incontro_url text, p_ora_partenza time without time zone, p_ora_rientro time without time zone, p_tema text, p_corso_richiesto text, p_grado_min text, p_grado_max text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.crea_evento(p_nome text, p_tipo text, p_data_inizio date, p_data_fine date, p_luogo text, p_requisito text, p_descrizione text, p_punto_incontro text, p_punto_incontro_url text, p_ora_partenza time without time zone, p_ora_rientro time without time zone, p_tema text, p_corso_richiesto text, p_grado_min text, p_grado_max text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.crea_evento(p_nome text, p_tipo text, p_data_inizio date, p_data_fine date, p_luogo text, p_requisito text, p_descrizione text, p_punto_incontro text, p_punto_incontro_url text, p_ora_partenza time without time zone, p_ora_rientro time without time zone, p_tema text, p_corso_richiesto text, p_grado_min text, p_grado_max text) TO service_role;

-- chiamanti: portale.html:7273
REVOKE EXECUTE ON FUNCTION public.invia_push_test(p_title text, p_body text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.invia_push_test(p_title text, p_body text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.invia_push_test(p_title text, p_body text) TO service_role;

-- chiamanti: sw-register.js:153
REVOKE EXECUTE ON FUNCTION public.upsert_push_subscription(p_endpoint text, p_p256dh_key text, p_auth_key text, p_user_agent text, p_device_label text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.upsert_push_subscription(p_endpoint text, p_p256dh_key text, p_auth_key text, p_user_agent text, p_device_label text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.upsert_push_subscription(p_endpoint text, p_p256dh_key text, p_auth_key text, p_user_agent text, p_device_label text) TO service_role;

-- chiamanti: sw-register.js:184
REVOKE EXECUTE ON FUNCTION public.delete_push_subscription(p_endpoint text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.delete_push_subscription(p_endpoint text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.delete_push_subscription(p_endpoint text) TO service_role;

-- chiamanti: nessuno nel repo · Filtra su auth.uid(): ad anon torna vuota. Revoca per igiene.
REVOKE EXECUTE ON FUNCTION public.miei_figli() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.miei_figli() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.miei_figli() TO service_role;

-- ─── 2 · Cron, interne e Worker — perdono anon e authenticated ───
-- Girano come postgres (pg_cron) o come service_role (Worker), oppure le chiama
-- un'altra funzione SECURITY DEFINER, che gira gia' come postgres.
-- Nessun browser deve poterle chiamare, ne' prima ne' dopo il login.

-- chiamanti: pg_cron job 1, ogni ora
REVOKE EXECUTE ON FUNCTION public.auto_marca_presenze_scadute() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auto_marca_presenze_scadute() TO service_role;

-- chiamanti: pg_cron job 3, ogni ora
REVOKE EXECUTE ON FUNCTION public.auto_marca_presenze_prima_lezione_scadute() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.auto_marca_presenze_prima_lezione_scadute() TO service_role;

-- chiamanti: pg_cron job 4, ogni 5 minuti
REVOKE EXECUTE ON FUNCTION public.libera_prenotazioni_scadute() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.libera_prenotazioni_scadute() TO service_role;

-- chiamanti: pg_cron job 5, ogni ora
REVOKE EXECUTE ON FUNCTION public.cron_accoda_offerta_open() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_accoda_offerta_open() TO service_role;

-- chiamanti: pg_cron job 6, annuale
REVOKE EXECUTE ON FUNCTION public.popola_feste_comandate(p_anni integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.popola_feste_comandate(p_anni integer) TO service_role;

-- chiamanti: nessuno nel repo · Non è in pg_cron e nessuna pagina la chiama: la sveglia il Worker delle notifiche, che usa
REVOKE EXECUTE ON FUNCTION public.cron_genera_eventi_mattutini() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.cron_genera_eventi_mattutini() TO service_role;

-- chiamanti: nessuno nel repo · Nessun chiamante nel repo e nessun job. Scrive: la revoca è prudente, la rimozione va deci
REVOKE EXECUTE ON FUNCTION public.smista_commerciale_scaduti() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.smista_commerciale_scaduti() TO service_role;

-- chiamanti: nessuno nel repo · Nessun chiamante nel repo: la chiama il Worker kc-eventi sul percorso /conferma. Da confer
REVOKE EXECUTE ON FUNCTION public.conferma_partecipazione_camp(p_part_id uuid, p_user_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.conferma_partecipazione_camp(p_part_id uuid, p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Nessun chiamante nel repo e nessun dipendente a DB. Scrive: revoca ora, rimozione da decid
REVOKE EXECUTE ON FUNCTION public.riattiva_freeze_se_scaduto(p_user_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.riattiva_freeze_se_scaduto(p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano sei funzioni, fra cui i trigger di crm_leads.
REVOKE EXECUTE ON FUNCTION public.garantisci_persona(p_email text, p_nome text, p_cognome text, p_telefono text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.garantisci_persona(p_email text, p_nome text, p_cognome text, p_telefono text) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano cancella_open e le due marca presenza.
REVOKE EXECUTE ON FUNCTION public.applica_no_show(p_user_id uuid, p_tipo_corso text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.applica_no_show(p_user_id uuid, p_tipo_corso text) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano ricalcola_cache_tutti e un trigger.
REVOKE EXECUTE ON FUNCTION public.ricalcola_cache_contatori(p_user_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.ricalcola_cache_contatori(p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano cron_genera_eventi_mattutini e un trigger. Nessun motivo per esporla.
REVOKE EXECUTE ON FUNCTION public.registra_evento_notifica(p_tipo text, p_user_id uuid, p_canale text, p_payload jsonb, p_schedulato_per timestamp with time zone, p_dedup_key text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.registra_evento_notifica(p_tipo text, p_user_id uuid, p_canale text, p_payload jsonb, p_schedulato_per timestamp with time zone, p_dedup_key text) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiama conferma_partecipazione_camp.
REVOKE EXECUTE ON FUNCTION public.riconosci_pregresso(p_user_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.riconosci_pregresso(p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano slot_disponibilita e prenota_corso, che girano come postgres.
REVOKE EXECUTE ON FUNCTION public.calendario_accademia_prossime(n integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.calendario_accademia_prossime(n integer) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano quattro funzioni di presenza e disdetta.
REVOKE EXECUTE ON FUNCTION public._chiudi_corso_se_finito(p_user_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._chiudi_corso_se_finito(p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano tre funzioni.
REVOKE EXECUTE ON FUNCTION public._snapshot_contabile(p_user_id uuid, p_tipo_corso text, p_funzione text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._snapshot_contabile(p_user_id uuid, p_tipo_corso text, p_funzione text) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano _snapshot_contabile e le due prenota_corso.
REVOKE EXECUTE ON FUNCTION public._ruolo_attore(p_user_id uuid, p_funzione text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._ruolo_attore(p_user_id uuid, p_funzione text) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiamano il cron mattutino e un trigger.
REVOKE EXECUTE ON FUNCTION public._referente_notifica(p_persona_id uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._referente_notifica(p_persona_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Interna: la chiama il cron mattutino.
REVOKE EXECUTE ON FUNCTION public._get_lezioni_residue(p_user_id uuid, p_corso text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._get_lezioni_residue(p_user_id uuid, p_corso text) TO service_role;

-- chiamanti: nessuno nel repo · Nessun chiamante nel repo, nessun dipendente a DB, nessun job. Sola lettura.
REVOKE EXECUTE ON FUNCTION public.get_voce_breakdown(p_voce_id text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_voce_breakdown(p_voce_id text) TO service_role;

-- chiamanti: nessuno nel repo · Nessun chiamante nel repo e nessun dipendente a DB: il gemello _get_lezioni_residue è usat
REVOKE EXECUTE ON FUNCTION public._get_spostamenti_residui(p_user_id uuid, p_corso text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public._get_spostamenti_residui(p_user_id uuid, p_corso text) TO service_role;

-- ─── 3 · Classe B — la fasciatura, in attesa dei file 04 ─────────
-- Queste hanno la guardia rotta o assente: vedi 02_piano.md.
-- Il REVOKE le mette in salvo da anon oggi stesso. Restano chiamabili da
-- authenticated, che e' esattamente il caso in cui la loro guardia funziona,
-- perche' con una sessione vera auth.uid() non e' piu' NULL.
-- I file 04a/04b/04c restano necessari: una guardia sbagliata va corretta comunque.

-- chiamanti: portale.html:5357
REVOKE EXECUTE ON FUNCTION public.aggiorna_data_iscrizione(p_user_id uuid, p_tipo_corso text, p_data date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.aggiorna_data_iscrizione(p_user_id uuid, p_tipo_corso text, p_data date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.aggiorna_data_iscrizione(p_user_id uuid, p_tipo_corso text, p_data date) TO service_role;

-- chiamanti: commerciale.html:328
REVOKE EXECUTE ON FUNCTION public.aggiungi_nota_lead(p_lead_id uuid, p_testo text, p_tipo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.aggiungi_nota_lead(p_lead_id uuid, p_testo text, p_tipo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.aggiungi_nota_lead(p_lead_id uuid, p_testo text, p_tipo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia inefficace verso anon. Scrive il percorso di un documento di consenso.
REVOKE EXECUTE ON FUNCTION public.allega_documento_consenso(p_lead_id uuid, p_path text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.allega_documento_consenso(p_lead_id uuid, p_path text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.allega_documento_consenso(p_lead_id uuid, p_path text) TO service_role;

-- chiamanti: portale.html:9976
REVOKE EXECUTE ON FUNCTION public.annulla_freeze(p_user_id uuid, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.annulla_freeze(p_user_id uuid, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.annulla_freeze(p_user_id uuid, p_motivo text) TO service_role;

-- chiamanti: nessuno nel repo · Guardia inefficace verso anon. Scrive lo stato della sequenza WhatsApp.
REVOKE EXECUTE ON FUNCTION public.avanza_sequenza_wa(p_lead_id uuid, p_step integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.avanza_sequenza_wa(p_lead_id uuid, p_step integer) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.avanza_sequenza_wa(p_lead_id uuid, p_step integer) TO service_role;

-- chiamanti: oggi.html:778
REVOKE EXECUTE ON FUNCTION public.conta_code_lead() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.conta_code_lead() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.conta_code_lead() TO service_role;

-- chiamanti: commerciale.html:364
REVOKE EXECUTE ON FUNCTION public.crea_figlio_lead(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.crea_figlio_lead(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.crea_figlio_lead(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text) TO service_role;

-- chiamanti: portale.html:9929
REVOKE EXECUTE ON FUNCTION public.dichiara_freeze_forzato(p_user_id uuid, p_inizio timestamp with time zone, p_fine timestamp with time zone, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.dichiara_freeze_forzato(p_user_id uuid, p_inizio timestamp with time zone, p_fine timestamp with time zone, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.dichiara_freeze_forzato(p_user_id uuid, p_inizio timestamp with time zone, p_fine timestamp with time zone, p_motivo text) TO service_role;

-- chiamanti: agenda.html:2040
REVOKE EXECUTE ON FUNCTION public.disdici_corso(p_prenotazione_id uuid, p_motivo text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.disdici_corso(p_prenotazione_id uuid, p_motivo text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.disdici_corso(p_prenotazione_id uuid, p_motivo text) TO service_role;

-- chiamanti: portale.html:5103
REVOKE EXECUTE ON FUNCTION public.get_consensi_minore(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_consensi_minore(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_consensi_minore(p_lead_id uuid) TO service_role;

-- chiamanti: commerciale.html:780
REVOKE EXECUTE ON FUNCTION public.get_cruscotto_percorsi() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_cruscotto_percorsi() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_cruscotto_percorsi() TO service_role;

-- chiamanti: portale.html:5091
REVOKE EXECUTE ON FUNCTION public.get_famiglia(p_persona_id uuid, p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_famiglia(p_persona_id uuid, p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_famiglia(p_persona_id uuid, p_lead_id uuid) TO service_role;

-- chiamanti: commerciale.html:775, portale.html:4497
REVOKE EXECUTE ON FUNCTION public.get_leads_da_contattare() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_leads_da_contattare() TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_leads_da_contattare() TO service_role;

-- chiamanti: portale.html:4794
REVOKE EXECUTE ON FUNCTION public.get_qualifica_lead(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_qualifica_lead(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_qualifica_lead(p_lead_id uuid) TO service_role;

-- chiamanti: portale.html:5388
REVOKE EXECUTE ON FUNCTION public.get_richieste_lead(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_richieste_lead(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_richieste_lead(p_lead_id uuid) TO service_role;

-- chiamanti: portale.html:5080
REVOKE EXECUTE ON FUNCTION public.get_tesseramenti(p_user_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_tesseramenti(p_user_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_tesseramenti(p_user_id uuid) TO service_role;

-- chiamanti: nessuno nel repo · Guardia inefficace verso anon. Restituisce la storia completa di una persona.
REVOKE EXECUTE ON FUNCTION public.get_timeline_persona(p_persona_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_timeline_persona(p_persona_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.get_timeline_persona(p_persona_id uuid) TO service_role;

-- chiamanti: commerciale.html:340, commerciale.html:347, portale.html:4698 …
REVOKE EXECUTE ON FUNCTION public.imposta_coda_fascia(p_lead_id uuid, p_coda text, p_fascia text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.imposta_coda_fascia(p_lead_id uuid, p_coda text, p_fascia text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.imposta_coda_fascia(p_lead_id uuid, p_coda text, p_fascia text) TO service_role;

-- chiamanti: portale.html:5115
REVOKE EXECUTE ON FUNCTION public.imposta_consenso_minore(p_lead_id uuid, p_tipo text, p_concesso boolean, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.imposta_consenso_minore(p_lead_id uuid, p_tipo text, p_concesso boolean, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.imposta_consenso_minore(p_lead_id uuid, p_tipo text, p_concesso boolean, p_note text) TO service_role;

-- chiamanti: agenda.html:2399, portale.html:4173
REVOKE EXECUTE ON FUNCTION public.inserisci_minore_con_referente(p_figlio_nome text, p_figlio_cognome text, p_fascia text, p_gen_nome text, p_gen_cognome text, p_gen_email text, p_gen_telefono text, p_figlio_nascita date, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.inserisci_minore_con_referente(p_figlio_nome text, p_figlio_cognome text, p_fascia text, p_gen_nome text, p_gen_cognome text, p_gen_email text, p_gen_telefono text, p_figlio_nascita date, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.inserisci_minore_con_referente(p_figlio_nome text, p_figlio_cognome text, p_fascia text, p_gen_nome text, p_gen_cognome text, p_gen_email text, p_gen_telefono text, p_figlio_nascita date, p_note text) TO service_role;

-- chiamanti: agenda.html:2114
REVOKE EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text) TO service_role;

-- chiamanti: agenda.html:1932
REVOKE EXECUTE ON FUNCTION public.prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date) TO service_role;

-- chiamanti: portale.html:5061
REVOKE EXECUTE ON FUNCTION public.registra_tesseramento(p_user_id uuid, p_anno integer, p_data_inizio date, p_assicurazione boolean, p_note text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.registra_tesseramento(p_user_id uuid, p_anno integer, p_data_inizio date, p_assicurazione boolean, p_note text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.registra_tesseramento(p_user_id uuid, p_anno integer, p_data_inizio date, p_assicurazione boolean, p_note text) TO service_role;

-- chiamanti: nessuno nel repo · Solo authenticated, quindi non esposta ad anon, ma la guardia ha la stessa forma fragile. 
REVOKE EXECUTE ON FUNCTION public.riconosci_figlio(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text, p_nascita date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.riconosci_figlio(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text, p_nascita date) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.riconosci_figlio(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text, p_nascita date) TO service_role;

-- chiamanti: portale.html:4804
REVOKE EXECUTE ON FUNCTION public.salva_qualifica_lead(p_lead_id uuid, p_lavoro text, p_esperienza_sport text, p_motivo_ora text, p_freno text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.salva_qualifica_lead(p_lead_id uuid, p_lavoro text, p_esperienza_sport text, p_motivo_ora text, p_freno text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.salva_qualifica_lead(p_lead_id uuid, p_lavoro text, p_esperienza_sport text, p_motivo_ora text, p_freno text) TO service_role;

-- chiamanti: commerciale.html:265
REVOKE EXECUTE ON FUNCTION public.segna_link_inviato(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.segna_link_inviato(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.segna_link_inviato(p_lead_id uuid) TO service_role;

-- chiamanti: commerciale.html:301
REVOKE EXECUTE ON FUNCTION public.segna_memo_wa(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.segna_memo_wa(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.segna_memo_wa(p_lead_id uuid) TO service_role;

-- chiamanti: commerciale.html:314
REVOKE EXECUTE ON FUNCTION public.segna_recensione_inviata(p_lead_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.segna_recensione_inviata(p_lead_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.segna_recensione_inviata(p_lead_id uuid) TO service_role;

-- chiamanti: commerciale.html:725
REVOKE EXECUTE ON FUNCTION public.segna_recensione_inviata_persona(p_persona_id uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.segna_recensione_inviata_persona(p_persona_id uuid) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.segna_recensione_inviata_persona(p_persona_id uuid) TO service_role;

-- chiamanti: commerciale.html:273
REVOKE EXECUTE ON FUNCTION public.segna_step_messaggio(p_lead_id uuid, p_step text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.segna_step_messaggio(p_lead_id uuid, p_step text) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.segna_step_messaggio(p_lead_id uuid, p_step text) TO service_role;

-- chiamanti: nessuno nel repo · una firma sola dal 22 set, ore 21:16 (vedi sotto)
-- NOTA: la firma a 3 argomenti (uuid, uuid, date) e' stata eliminata in produzione
-- dalla migration sposta_prima_lezione_unifica_overload. Il suo blocco REVOKE/GRANT
-- e' stato tolto da qui: questo file gira in una transazione sola, e un REVOKE su
-- una funzione inesistente lo farebbe fallire tutto.
REVOKE EXECUTE ON FUNCTION public.sposta_prima_lezione(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date, p_tutto_il_gruppo boolean) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.sposta_prima_lezione(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date, p_tutto_il_gruppo boolean) TO authenticated;
GRANT  EXECUTE ON FUNCTION public.sposta_prima_lezione(p_prenotazione_id uuid, p_nuovo_slot_id uuid, p_nuova_data date, p_tutto_il_gruppo boolean) TO service_role;

-- ─── 4 · Funzioni di trigger — facoltativa ────────────────────────────
-- Non sono invocabili: Postgres risponde 'trigger functions can only be called
-- as triggers' e PostgREST non le pubblica. Non sono una porta: questa sezione
-- e' igiene, non sicurezza.
-- Il privilegio EXECUTE su una funzione di trigger viene controllato alla
-- creazione del trigger, non a ogni scatto, quindi revocarlo non spegne niente.
-- Se preferisci non toccare i trigger di produzione, salta da qui al COMMIT:
-- il resto del file resta valido.

REVOKE EXECUTE ON FUNCTION public._provisiona_da_prenotazione_prima() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._sync_prima_done() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public._trg_open_presenza_garantisce_corso() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.enforce_slot_capacity() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.handle_new_user() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_crm_leads_delete() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_crm_leads_insert() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_crm_leads_update() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_email_eventi_persona() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_lead_data_fonte_autoregistra() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_lead_richieste_derive_fonte() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_lead_richieste_notifica() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_onboarding_spegni_su_prenotazione() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_prima_lezione_spostata() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_profiles_delete() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_profiles_update() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_ricalcola_cache_contatori() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_set_data_scadenza_open() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.tg_tesseramento_da_iscrizione() FROM PUBLIC, anon, authenticated;

COMMIT;

-- ============================================================================
-- V-ACL · verifica: rileggere i privilegi delle funzioni toccate
-- ============================================================================
-- Atteso dopo l'applicazione:
--   · 'aperta ad anon'        -> 0 righe fra quelle toccate
--   · le funzioni del blocco 1 e 3 -> 'authenticated'
--   · le funzioni del blocco 2 e 4 -> 'chiusa (solo postgres/service_role)'

SELECT
  p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS funzione,
  CASE
    WHEN p.proacl IS NULL THEN 'PUBLIC (ACL non impostata)'
    WHEN array_to_string(p.proacl,' ') ~ '(^| )=X/' THEN 'PUBLIC ha ancora EXECUTE'
    WHEN array_to_string(p.proacl,' ') LIKE '%anon=X%' THEN 'aperta ad anon'
    WHEN array_to_string(p.proacl,' ') LIKE '%authenticated=X%' THEN 'authenticated'
    ELSE 'chiusa (solo postgres/service_role)'
  END AS chi_puo_chiamarla,
  array_to_string(p.proacl,' ') AS acl_completa
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosecdef
  AND p.proname IN (
    '_chiudi_corso_se_finito', '_get_lezioni_residue', '_get_spostamenti_residui', '_provisiona_da_prenotazione_prima',
    '_referente_notifica', '_ruolo_attore', '_snapshot_contabile', '_sync_prima_done',
    '_trg_open_presenza_garantisce_corso', 'aggiorna_data_iscrizione', 'aggiungi_nota_lead', 'allega_documento_consenso',
    'annulla_freeze', 'applica_no_show', 'auto_marca_presenze_prima_lezione_scadute', 'auto_marca_presenze_scadute',
    'avanza_sequenza_wa', 'calendario_accademia_prossime', 'cancella_open', 'certifica_kata',
    'conferma_partecipazione_camp', 'conta_code_lead', 'crea_evento', 'crea_figlio_lead',
    'cron_accoda_offerta_open', 'cron_genera_eventi_mattutini', 'delete_push_subscription', 'dichiara_freeze',
    'dichiara_freeze_forzato', 'disdici_corso', 'disdici_corso_admin', 'enforce_slot_capacity',
    'garantisci_persona', 'get_consensi_minore', 'get_cruscotto_percorsi', 'get_famiglia',
    'get_iscritti_minori', 'get_leads_da_contattare', 'get_qualifica_lead', 'get_richieste_lead',
    'get_tesseramenti', 'get_timeline_persona', 'get_voce_breakdown', 'handle_new_user',
    'imposta_coda_fascia', 'imposta_consenso_minore', 'imposta_status_iscrizione_minore', 'inserisci_minore_con_referente',
    'invia_push_test', 'iscrivi_minore', 'iscrivi_minore_da_lead', 'libera_prenotazioni_scadute',
    'marca_presenza_corso', 'marca_presenza_prima_lezione', 'materializza_prima_lezione_mancante', 'miei_figli',
    'popola_feste_comandate', 'prenota_corso', 'prenota_corso_admin', 'registra_evento_notifica',
    'registra_pagamento_manuale_admin', 'registra_tesseramento', 'riattiva_freeze_se_scaduto', 'ricalcola_cache_contatori',
    'ricalcola_cache_tutti', 'riconosci_figlio', 'riconosci_pregresso', 'rifiuta_kata',
    'rimarca_presenza_corso', 'salva_qualifica_lead', 'segna_link_inviato', 'segna_memo_wa',
    'segna_recensione_inviata', 'segna_recensione_inviata_persona', 'segna_step_messaggio', 'smista_commerciale_scaduti',
    'sposta_corso', 'sposta_kata', 'sposta_prima_lezione', 'staff_chiudi_giorno',
    'staff_riapri_giorno', 'tg_crm_leads_delete', 'tg_crm_leads_insert', 'tg_crm_leads_update',
    'tg_email_eventi_persona', 'tg_lead_data_fonte_autoregistra', 'tg_lead_richieste_derive_fonte', 'tg_lead_richieste_notifica',
    'tg_onboarding_spegni_su_prenotazione', 'tg_prima_lezione_spostata', 'tg_profiles_delete', 'tg_profiles_update',
    'tg_ricalcola_cache_contatori', 'tg_set_data_scadenza_open', 'tg_tesseramento_da_iscrizione', 'upsert_push_subscription'
  )
ORDER BY chi_puo_chiamarla, funzione;

-- ============================================================================
-- V-ANON · la prova che il buco e' chiuso
-- ============================================================================
-- Prima del 03 questa risponde 410. Dopo, deve dare 'permission denied'.
-- Da lanciare in una sessione a parte, perche' fallisce apposta.
--
--   SET ROLE anon;
--   SELECT count(*) FROM get_leads_da_contattare();
--   RESET ROLE;
--
-- E il contrario, che deve continuare a funzionare (flusso pubblico):
--
--   SET ROLE anon;
--   SELECT count(*) FROM conteggi_prima_lezione(current_date, current_date + 30);
--   SELECT count(*) FROM get_eventi_calendario();
--   RESET ROLE;
