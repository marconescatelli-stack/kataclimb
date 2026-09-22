-- ==========================================================================
-- DEBITO-191 · 04c · Prenotazioni, presenze e famiglia — 4 funzioni
-- Preparato il 22 settembre 2026 · aggiornato il 22 set dopo la migration
-- sposta_prima_lezione_unifica_overload · NON APPLICATO
--
-- Tre difetti diversi, tutti della stessa famiglia: un confronto che con un NULL
-- non e' falso ma NULL, e un IF che quindi non scatta.
--   · prenota_corso e disdici_corso usano <> contro auth.uid();
--   · marca_presenza_prima_lezione usa NOT IN su un ruolo che per un allievo
--     e' NULL, quindi un utente qualsiasi passava;
--   · riconosci_figlio ha la guardia del CRM, con gli stessi ruoli inesistenti.
--
-- sposta_prima_lezione era la quinta. Non lo e' piu': vedi il riquadro in fondo.
-- 
-- Ogni corpo e' stato riletto da pg_get_functiondef il 22 set e lasciato
-- identico: cambia solo il blocco di guardia, segnato da un commento DEBITO-191.
-- Nessuna firma cambia, quindi nessun DROP FUNCTION serve.
-- ==========================================================================

BEGIN;

-- ─── prenota_corso ─────────────────────────────────────────────
-- chiamanti: agenda.html:1932
-- solo la riga della guardia cambia, corpo invariato.
CREATE OR REPLACE FUNCTION public.prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_slot        record;
  v_config      record;
  v_profile     record;
  v_now         timestamptz := now();
  v_dt_inizio   timestamptz;
  v_capienza    int;
  v_prenot_id   uuid;
  v_dow_iso     int;
  v_prenotabili int;
  v_iscrizione  record;
BEGIN
  -- DEBITO-191 · <> sostituito da IS DISTINCT FROM.
  -- Con un chiamante anonimo auth.uid() e' NULL, 'p_user_id <> NULL' vale NULL
  -- e l'IF non scattava: si poteva prenotare una lezione per conto di chiunque.
  IF p_user_id IS DISTINCT FROM auth.uid() AND NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato: puoi prenotare solo per te stesso';
  END IF;

  SELECT corso_attivo, freeze_inizio, freeze_fine, scadenza_consumo_open
    INTO v_profile
    FROM profile_data
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profilo non trovato per user_id %', p_user_id;
  END IF;
  IF v_profile.corso_attivo IS NULL THEN
    RAISE EXCEPTION 'Nessun corso attivo: contatta la segreteria';
  END IF;

  -- DEBITO-190: la guardia legge la view. NULL = nessuna iscrizione attiva a
  -- quel corso, quindi anche i crediti orfani smettono di essere spendibili.
  SELECT prenotabili INTO v_prenotabili
    FROM contatori_corso
    WHERE user_id = p_user_id AND tipo_corso = v_profile.corso_attivo;

  IF v_prenotabili IS NULL THEN
    RAISE EXCEPTION 'Nessuna iscrizione attiva al corso %: contatta la segreteria', v_profile.corso_attivo;
  END IF;
  IF v_prenotabili <= 0 THEN
    RAISE EXCEPTION 'Nessuna lezione residua per il corso %: contatta la segreteria', v_profile.corso_attivo;
  END IF;

  IF v_profile.corso_attivo = 'open' THEN
    IF v_profile.scadenza_consumo_open IS NOT NULL
       AND v_profile.scadenza_consumo_open < v_now THEN
      RAISE EXCEPTION 'Pacchetto Open scaduto: contatta la segreteria';
    END IF;
  ELSE
    SELECT data_inizio_validita, data_fine_validita, status
      INTO v_iscrizione
      FROM iscrizioni_corso
      WHERE user_id = p_user_id
        AND tipo_corso = v_profile.corso_attivo
        AND status = 'attiva'
      ORDER BY data_iscrizione DESC
      LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nessuna iscrizione attiva al corso %: contatta la segreteria', v_profile.corso_attivo;
    END IF;
    IF v_iscrizione.data_fine_validita IS NOT NULL
       AND p_data_lezione > v_iscrizione.data_fine_validita THEN
      RAISE EXCEPTION 'La data lezione % e'' oltre la fine validita'' del pacchetto (%)',
        p_data_lezione, v_iscrizione.data_fine_validita;
    END IF;
    IF v_iscrizione.data_inizio_validita IS NOT NULL
       AND p_data_lezione < v_iscrizione.data_inizio_validita THEN
      RAISE EXCEPTION 'La data lezione % e'' prima dell''inizio validita'' del pacchetto (%)',
        p_data_lezione, v_iscrizione.data_inizio_validita;
    END IF;
  END IF;

  IF v_profile.freeze_inizio IS NOT NULL
     AND v_profile.freeze_fine IS NOT NULL
     AND v_now BETWEEN v_profile.freeze_inizio AND v_profile.freeze_fine THEN
    RAISE EXCEPTION 'In pausa fino al %: riprendi dal portale dopo questa data',
      to_char(v_profile.freeze_fine, 'DD/MM/YYYY');
  END IF;

  SELECT id, giorno_settimana, ora_inizio, ora_fine, tipo_corso, status
    INTO v_slot FROM corsi_attivi_settimanali WHERE id = p_slot_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Slot non trovato'; END IF;
  IF v_slot.status <> 'attivo' THEN RAISE EXCEPTION 'Slot non attivo'; END IF;
  IF v_slot.tipo_corso <> v_profile.corso_attivo THEN
    RAISE EXCEPTION 'Slot di tipo % non compatibile con il tuo corso attivo (%)',
      v_slot.tipo_corso, v_profile.corso_attivo;
  END IF;

  v_dow_iso := ((EXTRACT(DOW FROM p_data_lezione)::int + 6) % 7) + 1;
  IF v_dow_iso <> v_slot.giorno_settimana THEN
    RAISE EXCEPTION 'La data % (giorno %) non corrisponde al giorno dello slot (%)',
      p_data_lezione, v_dow_iso, v_slot.giorno_settimana;
  END IF;

  SELECT capienza_max, finestra_prenotazione_ore, apertura_prenotazione_giorni
    INTO v_config
    FROM tipi_corso_config
    WHERE tipo_corso = v_slot.tipo_corso AND attivo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tipo corso % non configurato o non attivo', v_slot.tipo_corso;
  END IF;

  v_dt_inizio := (p_data_lezione + v_slot.ora_inizio)::timestamptz;

  IF p_data_lezione > (SELECT max(d) FROM calendario_accademia_prossime()) THEN
    RAISE EXCEPTION 'Troppo presto: la data % non rientra ancora nella finestra di prenotazione (calendario Accademia)',
      to_char(p_data_lezione, 'DD/MM/YYYY');
  END IF;

  IF v_dt_inizio - v_now < make_interval(hours => v_config.finestra_prenotazione_ore) THEN
    RAISE EXCEPTION 'Troppo tardi: la prenotazione chiude % h prima della lezione',
      v_config.finestra_prenotazione_ore;
  END IF;

  SELECT COUNT(*) INTO v_capienza
    FROM prenotazioni_corso
    WHERE slot_id = p_slot_id AND data_lezione = p_data_lezione AND stato = 'prenotato';

  IF v_capienza >= v_config.capienza_max THEN
    RAISE EXCEPTION 'Slot pieno (%/%): scegline un altro', v_capienza, v_config.capienza_max;
  END IF;

  IF EXISTS (
    SELECT 1 FROM prenotazioni_corso
    WHERE user_id = p_user_id AND slot_id = p_slot_id
      AND data_lezione = p_data_lezione AND stato = 'prenotato'
  ) THEN
    RAISE EXCEPTION 'Hai gia'' una prenotazione attiva per questo slot';
  END IF;

  INSERT INTO prenotazioni_corso (
    user_id, slot_id, tipo_corso, data_lezione, stato, created_by, created_ruolo)
    VALUES (
      p_user_id, p_slot_id, v_slot.tipo_corso, p_data_lezione, 'prenotato', auth.uid(),
      _ruolo_attore(p_user_id, 'prenota_corso'))
    RETURNING id INTO v_prenot_id;

  -- DEBITO-190: qui prima c'era l'UPDATE che scalava la colonna del corso.
  -- La riga appena inserita E' il consumo: il COUNT la vede.

  RETURN v_prenot_id;
END;
$function$;

-- ─── disdici_corso ─────────────────────────────────────────────
-- chiamanti: agenda.html:2040
-- solo la riga della guardia cambia, corpo invariato.
-- NOTA per Marco: piu' sotto resta v_is_allievo := (v_prenot.user_id = v_caller AND
-- NOT v_is_staff), che con un chiamante senza sessione varrebbe NULL. Dopo questa
-- guardia quel caso non si presenta piu', quindi la riga non e' stata toccata.
CREATE OR REPLACE FUNCTION public.disdici_corso(p_prenotazione_id uuid, p_motivo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_prenot        record;
  v_slot          record;
  v_config        record;
  v_now           timestamptz := now();
  v_dt_inizio     timestamptz;
  v_in_tempo      boolean;
  v_caller        uuid := auth.uid();
  v_is_staff      boolean := is_staff();
  v_is_allievo    boolean;
  v_spost_res     int;
  v_prima         jsonb;
  v_dopo          jsonb;
  v_stato_finale  text;
  v_c             record;
BEGIN
  SELECT id, user_id, slot_id, tipo_corso, data_lezione, stato
    INTO v_prenot FROM prenotazioni_corso WHERE id = p_prenotazione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prenotazione non trovata'; END IF;
  -- DEBITO-191 · <> sostituito da IS DISTINCT FROM: v_caller e' auth.uid(), che
  -- per un anonimo e' NULL, e il confronto lasciava passare la disdetta altrui.
  IF v_prenot.user_id IS DISTINCT FROM v_caller AND NOT COALESCE(v_is_staff, false) THEN RAISE EXCEPTION 'Permesso negato'; END IF;
  v_is_allievo := (v_prenot.user_id = v_caller AND NOT v_is_staff);
  IF v_prenot.stato <> 'prenotato' THEN
    RAISE EXCEPTION 'Prenotazione già in stato "%", non disdicibile', v_prenot.stato;
  END IF;

  SELECT ora_inizio INTO v_slot FROM corsi_attivi_settimanali WHERE id = v_prenot.slot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Slot non trovato (orfano?)'; END IF;
  SELECT finestra_disdetta_ore INTO v_config FROM tipi_corso_config WHERE tipo_corso = v_prenot.tipo_corso;
  IF NOT FOUND THEN RAISE EXCEPTION 'Config tipo_corso % mancante', v_prenot.tipo_corso; END IF;

  v_dt_inizio := (v_prenot.data_lezione + v_slot.ora_inizio)::timestamptz;
  v_in_tempo  := (v_dt_inizio - v_now) >= make_interval(hours => v_config.finestra_disdetta_ore);

  v_prima := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso, 'disdici_corso');

  IF v_in_tempo THEN
    IF v_is_allievo THEN
      -- DEBITO-190: il budget arriva dalla view (max - COUNT cancellato_in_tempo)
      SELECT spostamenti_residui INTO v_spost_res
        FROM contatori_corso
        WHERE user_id = v_prenot.user_id AND tipo_corso = v_prenot.tipo_corso;
      IF v_spost_res IS NULL OR v_spost_res <= 0 THEN
        RAISE EXCEPTION 'Hai esaurito le disdette consentite per questo pacchetto. Per un imprevisto reale, contatta la segreteria.'
          USING ERRCODE = '23514';
      END IF;
    END IF;

    UPDATE prenotazioni_corso
      SET stato='cancellato_in_tempo', cancelled_at=v_now, cancellation_reason=p_motivo
      WHERE id=p_prenotazione_id;
    v_stato_finale := 'cancellato_in_tempo';
  ELSE
    UPDATE prenotazioni_corso
      SET stato='cancellato_tardi', cancelled_at=v_now, cancellation_reason=p_motivo
      WHERE id=p_prenotazione_id;
    v_stato_finale := 'cancellato_tardi';
  END IF;

  -- DEBITO-190: nessun UPDATE su profile_data. 'cancellato_in_tempo' non
  -- consuma e non decrementa nulla; 'cancellato_tardi' consuma, e lo dice
  -- il COUNT. applica_no_show non viene piu' chiamata qui: la disdetta fuori
  -- tempo non e' una ghostata, e' uno stato suo che consuma 1 a 1.

  PERFORM _chiudi_corso_se_finito(v_prenot.user_id);

  v_dopo := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso, 'disdici_corso');
  UPDATE prenotazioni_corso
    SET effetto_contabile = jsonb_build_object(
          'azione', v_stato_finale, 'origine', 'disdici_corso',
          'in_tempo', v_in_tempo, 'prima', v_prima, 'dopo', v_dopo,
          'marcata_da', v_caller, 'marcata_at', v_now)
    WHERE id = p_prenotazione_id;

  SELECT * INTO v_c FROM contatori_corso
    WHERE user_id = v_prenot.user_id AND tipo_corso = v_prenot.tipo_corso;

  RETURN jsonb_build_object(
    'prenotazione_id',          p_prenotazione_id,
    'tipo_corso',               v_prenot.tipo_corso,
    'in_tempo',                 v_in_tempo,
    'stato_finale',             v_stato_finale,
    'spostamenti_residui_dopo', v_c.spostamenti_residui,
    'no_show_count_dopo',       v_c.ghostate,
    'lezioni_residue_dopo',     v_c.prenotabili
  );
END;
$function$;

-- ─── marca_presenza_prima_lezione ──────────────────────────────
-- chiamanti: agenda.html:2114
-- respingeva gli anonimi ma non gli allievi: staff_role NULL passava il NOT IN.
-- aggiunto 'v_caller_role IS NULL OR', come nelle funzioni sorelle.
-- solo la riga della guardia cambia, corpo invariato.
CREATE OR REPLACE FUNCTION public.marca_presenza_prima_lezione(p_prenotazione_id uuid, p_nuovo_stato text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller_id     uuid := auth.uid();
  v_caller_role   text;
  v_stato_attuale text;
  v_lead_id       uuid;
  v_data_lezione  date;
  v_presente      boolean;
  v_profile_id    uuid;
  v_funnel_attuale text;
  v_funnel_nuovo  text := NULL;
BEGIN
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Non autenticato' USING ERRCODE = '28000';
  END IF;

  SELECT staff_role INTO v_caller_role
  FROM profile_data
  WHERE user_id = v_caller_id;

  -- DEBITO-191 · aggiunto il caso NULL: un allievo ha staff_role NULL e

  -- 'NULL NOT IN (...)' vale NULL, quindi l'IF non scattava e passava.

  IF v_caller_role IS NULL OR v_caller_role NOT IN ('staff_creator', 'staff_segreteria',
                           'staff_istruttore_tutor', 'staff_istruttore_sr', 'staff_istruttore_jr') THEN
    RAISE EXCEPTION 'Permesso negato: serve staff (segreteria o istruttore)'
      USING ERRCODE = '42501';
  END IF;

  IF p_nuovo_stato NOT IN ('fatto', 'no_show') THEN
    RAISE EXCEPTION 'Stato non valido: % (ammessi: fatto, no_show)', p_nuovo_stato
      USING ERRCODE = '22023';
  END IF;

  -- Prenotazione + lead + profilo collegato in un colpo
  SELECT pp.stato, pp.lead_id, pp.data_lezione, c.converted_profile_id, c.funnel_stage
    INTO v_stato_attuale, v_lead_id, v_data_lezione, v_profile_id, v_funnel_attuale
    FROM prenotazioni_prima_lezione pp
    JOIN crm_leads c ON c.id = pp.lead_id
    WHERE pp.id = p_prenotazione_id
    FOR UPDATE OF pp;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prenotazione % non trovata', p_prenotazione_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_stato_attuale IN ('cancellato_in_tempo', 'cancellato_tardi') THEN
    RAISE EXCEPTION 'Prenotazione già cancellata (stato=%)', v_stato_attuale
      USING ERRCODE = '22023';
  END IF;

  v_presente := (p_nuovo_stato = 'fatto');

  -- 1) prenotazione: stato + presente coerenti
  UPDATE prenotazioni_prima_lezione
     SET stato = p_nuovo_stato,
         presente = v_presente
   WHERE id = p_prenotazione_id;

  -- 2) profilo: se presente → prima_paid=true (chi fa la prima l'ha pagata; il "come" è della segreteria)
  --    Su no_show NON si tocca prima_paid (l'aveva pagata comunque).
  IF p_nuovo_stato = 'fatto' AND v_profile_id IS NOT NULL THEN
    UPDATE profile_data
       SET prima_paid = true, updated_at = now()
     WHERE user_id = v_profile_id;
  END IF;

  -- 3) funnel: presente da stato pre-lezione → fatta_prima_lezione
  IF p_nuovo_stato = 'fatto'
     AND v_funnel_attuale IN ('nuovo','contattato','prenotato_prima_lezione','da_riprogrammare') THEN
    UPDATE lead_data
       SET funnel_stage = 'fatta_prima_lezione', ultima_interazione = now(), updated_at = now()
     WHERE id = v_lead_id;
    v_funnel_nuovo := 'fatta_prima_lezione';
  END IF;

  RETURN jsonb_build_object(
    'ok',               true,
    'prenotazione_id',  p_prenotazione_id,
    'lead_id',          v_lead_id,
    'data_lezione',     v_data_lezione,
    'stato_precedente', v_stato_attuale,
    'stato_nuovo',      p_nuovo_stato,
    'presente',         v_presente,
    'prima_paid_set',   (p_nuovo_stato = 'fatto' AND v_profile_id IS NOT NULL),
    'funnel_nuovo',     v_funnel_nuovo
  );
END;
$function$;

-- ─── sposta_prima_lezione · TOLTA DA QUESTO FILE ──────────────
-- Qui c'era un CREATE OR REPLACE sulla firma a 3 argomenti
-- (uuid, uuid, date). Quella firma NON ESISTE PIU': il 22 settembre alle
-- 21:16 la migration sposta_prima_lezione_unifica_overload le ha fatto
-- DROP, lasciando la sola firma a 4 (p_tutto_il_gruppo boolean DEFAULT false).
-- Applicare quel blocco avrebbe RICREATO la firma a 3 e rimesso in piedi
-- l'overload appena smontato: due omonime con default rendono la chiamata
-- ambigua per PostgREST. Per questo e' stato rimosso invece che aggiornato.
--
-- LA FIRMA A 4 NON HA BISOGNO DI CORREZIONI. Verificato a DB il 22 set:
--
--   IF auth.role() <> 'service_role'
--      AND NOT EXISTS (SELECT 1 FROM profile_data
--                      WHERE user_id = auth.uid()
--                        AND staff_role IN ('staff_creator','staff_segreteria')) THEN
--     RAISE EXCEPTION 'non autorizzato: solo segreteria' USING ERRCODE = '42501';
--   END IF;
--
-- Non ha il difetto NULL NOT IN: usa EXISTS, che restituisce sempre true o
-- false e non vale mai NULL. Provata riga per riga con i quattro JWT possibili:
--
--   anon via PostgREST      auth.role()='anon'           -> RESPINTO
--   allievo loggato         auth.role()='authenticated'  -> RESPINTO
--   Worker service_role     auth.role()='service_role'   -> passa, come deve
--   sessione SQL senza JWT  auth.role()=NULL             -> passa
--
-- L'ultimo caso e' l'unico punto molle: senza JWT auth.role() e' NULL, il
-- primo membro vale NULL e l'IF non scatta. Non e' raggiungibile dal web,
-- perche' ogni richiesta che passa da PostgREST porta almeno la chiave anon
-- come JWT; ci arriva solo chi e' gia' dentro il database con un'utenza
-- propria. Per chiuderlo anche li' basterebbe
-- 'auth.role() IS DISTINCT FROM ...', ma e' una riscrittura di una funzione
-- appena rifatta da Marco e non la faccio di mia iniziativa.
--
-- Nota, non un difetto: questa guardia ammette staff_creator e
-- staff_segreteria, non staff_istruttore_sr ne' staff_istruttore_tutor.
-- E' piu' stretta della lista proposta per il CRM, ed e' coerente con la
-- funzione di prima. Se il cruscotto cambiera' lista, decidere se allinearla.
--
-- La funzione compare comunque nel 03_revoke.sql, sulla firma a 4.

-- ─── riconosci_figlio ──────────────────────────────────────────
-- chiamanti: nessuno nel repo, verificare i Worker
-- guardia del CRM, sostituita come nel 04a. La deroga a service_role resta.
-- e' solo authenticated, quindi non era esposta ad anon: si sana per coerenza.
CREATE OR REPLACE FUNCTION public.riconosci_figlio(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text, p_nascita date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_nome text := lower(trim(p_nome)); v_cogn text := lower(trim(coalesce(p_cognome,'')));
  v_gen_email text; v_gen_tel10 text;
  v_lead uuid; v_persona uuid; v_esito text; v_n int;
BEGIN
  -- DEBITO-191 · guardia sostituita.
  -- Prima confrontava auth.uid() con un UUID: con un chiamante senza sessione
  -- quel confronto vale NULL, l'IF non scattava e la funzione rispondeva a chiunque.
  -- EXISTS non vale mai NULL, quindi adesso respinge.
  -- I ruoli sono quelli del CHECK profile_data_staff_role_check: i quattro di prima
  -- (creator, admin, segreteria, istruttore_senior) non esistono a DB.
  -- La scorciatoia personale su un UUID scritto a mano e' stata tolta: quell'utenza
  -- ha gia' staff_role = 'staff_creator' e passa dalla porta normale. Per rimetterla,
  -- anteporre dentro l'IF, prima di NOT EXISTS:  auth.uid() IS DISTINCT FROM
  --   '27b04151-93a7-4ecc-824c-fe337cc631a6'::uuid AND
  IF auth.role() IS DISTINCT FROM 'service_role'
     AND NOT EXISTS (
       SELECT 1 FROM profile_data
       WHERE user_id = auth.uid()
         AND staff_role IN (
           -- RUOLI AMMESSI: proposta, da confermare con Marco
           'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
         )
     ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;
  IF p_fascia NOT IN ('bambino','ragazzo') THEN RAISE EXCEPTION 'fascia non valida: %', p_fascia; END IF;
  IF v_nome = '' THEN RAISE EXCEPTION 'nome obbligatorio'; END IF;

  SELECT lower(p.email), right(regexp_replace(coalesce(p.telefono,''), '\D', '', 'g'), 10)
    INTO v_gen_email, v_gen_tel10
  FROM lead_data ld JOIN persone p ON p.id = ld.persona_id WHERE ld.id = p_genitore_lead_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'genitore non trovato'; END IF;
  IF v_gen_tel10 = '' THEN v_gen_tel10 := NULL; END IF;

  -- 1) già relazionato
  SELECT ld.id, ld.persona_id INTO v_lead, v_persona
  FROM crm_relazioni r JOIN lead_data ld ON ld.id = r.lead_figlio_id JOIN persone p ON p.id = ld.persona_id
  WHERE r.lead_genitore_id = p_genitore_lead_id AND r.tipo_relazione = 'genitore_figlio'
    AND lower(trim(p.nome)) = v_nome AND lower(trim(coalesce(p.cognome,''))) = v_cogn
  LIMIT 1;
  IF v_lead IS NOT NULL THEN v_esito := 'relazionato'; END IF;

  -- 2) riconoscimento tra le persone senza contatti (minori)
  IF v_lead IS NULL THEN
    CREATE TEMP TABLE IF NOT EXISTS _cand (persona_id uuid, lead_id uuid, forte bool) ON COMMIT DROP;
    -- v2 (16 set 2026): WHERE true richiesto da safeupdate sul ruolo authenticator
    DELETE FROM _cand WHERE true;
    INSERT INTO _cand
    SELECT p.id, ld.id,
      (p_nascita IS NOT NULL AND p.data_nascita = p_nascita)
      OR (v_gen_email IS NOT NULL AND lower(coalesce(p.note_interne,'')||' '||coalesce(ld.note_crm,'')||' '||coalesce(ld.note,'')) LIKE '%'||v_gen_email||'%')
      OR (v_gen_tel10 IS NOT NULL AND regexp_replace(coalesce(p.note_interne,'')||' '||coalesce(ld.note_crm,'')||' '||coalesce(ld.note,''), '\D', '', 'g') LIKE '%'||v_gen_tel10||'%')
    FROM persone p LEFT JOIN lead_data ld ON ld.persona_id = p.id
    WHERE lower(trim(p.nome)) = v_nome AND lower(trim(coalesce(p.cognome,''))) = v_cogn
      AND p.email IS NULL AND p.telefono IS NULL
      AND (p_nascita IS NULL OR p.data_nascita IS NULL OR p.data_nascita = p_nascita)
      AND NOT EXISTS (SELECT 1 FROM crm_relazioni r WHERE r.lead_figlio_id = ld.id AND r.lead_genitore_id <> p_genitore_lead_id);
    SELECT count(*) INTO v_n FROM _cand WHERE forte;
    IF v_n = 0 THEN SELECT count(*) INTO v_n FROM _cand; END IF;
    IF v_n = 1 THEN
      SELECT persona_id, lead_id INTO v_persona, v_lead FROM _cand ORDER BY forte DESC LIMIT 1;
      IF v_lead IS NULL THEN
        INSERT INTO lead_data (persona_id, coda, fascia, funnel_stage) VALUES (v_persona, 'segreteria', p_fascia, 'nuovo') RETURNING id INTO v_lead;
      END IF;
      INSERT INTO crm_relazioni (lead_genitore_id, lead_figlio_id, tipo_relazione, pagante)
      VALUES (p_genitore_lead_id, v_lead, 'genitore_figlio', true);
      v_esito := 'riconosciuto';
    ELSIF v_n > 1 THEN
      v_esito := 'ambiguo';
    END IF;
  END IF;

  -- 3) creazione
  IF v_lead IS NULL THEN
    v_lead := crea_figlio_lead(p_genitore_lead_id, p_nome, p_cognome, p_fascia);
    SELECT persona_id INTO v_persona FROM lead_data WHERE id = v_lead;
    v_esito := coalesce(v_esito, 'creato');
  END IF;

  UPDATE lead_data SET fascia = p_fascia, funnel_stage = 'prenotato_prima_lezione', ultima_interazione = now(), updated_at = now(), coda = coalesce(coda,'segreteria')
  WHERE id = v_lead;
  IF p_nascita IS NOT NULL THEN
    UPDATE persone SET data_nascita = coalesce(data_nascita, p_nascita), updated_at = now() WHERE id = v_persona;
  END IF;

  RETURN jsonb_build_object('lead_id', v_lead, 'persona_id', v_persona, 'esito', v_esito);
END $function$;

COMMIT;

-- ==========================================================================
-- V-firme · atteso: ogni nome con firme = 1, sposta_prima_lezione compresa.
-- Dal 22 set alle 21:16 sposta_prima_lezione ha UNA firma sola, quella a 4
-- argomenti. Se ne compaiono due, qualcuno ha ricreato l'overload: e' proprio
-- cio' che la migration sposta_prima_lezione_unifica_overload ha smontato.
-- ==========================================================================
SELECT p.proname, count(*) AS firme,
       string_agg(pg_get_function_identity_arguments(p.oid), E'\n   § ') AS quali
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('prenota_corso','disdici_corso',
      'marca_presenza_prima_lezione','sposta_prima_lezione','riconosci_figlio')
GROUP BY p.proname ORDER BY p.proname;

-- V-agenda · dopo il 04c, da agenda.html come staff: prenotare, disdire e
-- marcare una presenza devono funzionare come prima. Come allievo, marcare una
-- presenza deve rispondere 'Permesso negato: serve staff (segreteria o istruttore)'.
