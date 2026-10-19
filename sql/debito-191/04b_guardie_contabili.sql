-- ==========================================================================
-- DEBITO-191 · 04b · Le cinque senza guardia — contabilita' e anagrafica
-- Preparato il 22 settembre 2026 · NON APPLICATO
--
-- Queste cinque non avevano nessun controllo sul chiamante, e quattro di loro
-- scrivono. Prendono un p_user_id come parametro, quindi agivano su chiunque.
-- Qui la guardia si aggiunge, non si sostituisce: il corpo resta identico e la
-- guardia entra come primo atto dopo il BEGIN.
-- 
-- Ogni corpo e' stato riletto da pg_get_functiondef il 22 set e lasciato
-- identico: cambia solo il blocco di guardia, segnato da un commento DEBITO-191.
-- Nessuna firma cambia, quindi nessun DROP FUNCTION serve.
-- ==========================================================================

BEGIN;

-- ─── annulla_freeze ────────────────────────────────────────────
-- chiamanti: portale.html:9976
-- annullava il congelamento di qualunque utente e riscriveva le scadenze.
-- guardia AGGIUNTA dopo il BEGIN, corpo invariato.
CREATE OR REPLACE FUNCTION public.annulla_freeze(p_user_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_inizio           timestamptz;
  v_fine             timestamptz;
  v_scadenza         timestamptz;
  v_now              timestamptz := now();
  v_giorni_intervallo int;
  v_giorni_sottratti int;
  v_scenario         text;
  v_decr_giorni_tot  int;
BEGIN
  -- DEBITO-191 · guardia aggiunta: prima non ce n'era nessuna.
  -- La funzione accetta un p_user_id qualsiasi e scrive. Senza questo controllo
  -- chiunque, anche senza sessione, poteva usarla su chiunque: l'unica cosa che
  -- la proteggeva era che il bottone si vede solo in portale.html.
  -- is_staff() e' un EXISTS, quindi non vale mai NULL: respinge anche gli anonimi.
  IF NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  -- Lock + lettura stato corrente
  SELECT freeze_inizio, freeze_fine, scadenza_consumo_open
    INTO v_inizio, v_fine, v_scadenza
    FROM profile_data
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROFILO_NON_TROVATO';
  END IF;

  IF v_inizio IS NULL OR v_fine IS NULL THEN
    RAISE EXCEPTION 'NESSUN_FREEZE_ATTIVO';
  END IF;

  IF v_fine <= v_now THEN
    RAISE EXCEPTION 'FREEZE_GIA_CONCLUSO';
  END IF;

  -- Calcolo giorni
  v_giorni_intervallo := CEIL(EXTRACT(EPOCH FROM (v_fine - v_inizio)) / 86400)::int;

  -- Scenario A: freeze pianificato (non iniziato)
  -- → sottrai tutto, come se non fosse mai esistito
  -- Scenario B: freeze in corso (parzialmente consumato)
  -- → sottrai solo i giorni residui (fine - now)
  -- → freeze_giorni_totali INVARIATO (i giorni già trascorsi sono stati usati)
  IF v_inizio > v_now THEN
    v_scenario := 'pianificato';
    v_giorni_sottratti := v_giorni_intervallo;
    v_decr_giorni_tot  := v_giorni_intervallo;
  ELSE
    v_scenario := 'in_corso';
    v_giorni_sottratti := CEIL(EXTRACT(EPOCH FROM (v_fine - v_now)) / 86400)::int;
    v_decr_giorni_tot  := 0;
  END IF;

  -- Reset freeze + ripristino scadenza + log
  UPDATE profile_data
    SET freeze_inizio        = NULL,
        freeze_fine          = NULL,
        freeze_count         = GREATEST(COALESCE(freeze_count, 1) - 1, 0),
        freeze_giorni_totali = GREATEST(COALESCE(freeze_giorni_totali, 0) - v_decr_giorni_tot, 0),
        scadenza_consumo_open = COALESCE(v_scadenza, now()) - (v_giorni_sottratti || ' days')::interval,
        freeze_log = COALESCE(freeze_log, '[]'::jsonb) || jsonb_build_object(
          'azione',                    'annulla',
          'motivo',                    p_motivo,
          'eseguito_da',               auth.uid(),
          'eseguito_il',               v_now,
          'scenario',                  v_scenario,
          'freeze_inizio_originale',   v_inizio,
          'freeze_fine_originale',     v_fine,
          'giorni_sottratti_scadenza', v_giorni_sottratti
        )
    WHERE user_id = p_user_id;

  RETURN jsonb_build_object(
    'ok',               true,
    'giorni_sottratti', v_giorni_sottratti,
    'scenario',         v_scenario
  );
END;
$function$;

-- ─── dichiara_freeze_forzato ───────────────────────────────────
-- chiamanti: portale.html:9929
-- congelava qualunque utente, senza passare dal conteggio dei freeze.
-- guardia AGGIUNTA dopo il BEGIN, corpo invariato.
CREATE OR REPLACE FUNCTION public.dichiara_freeze_forzato(p_user_id uuid, p_inizio timestamp with time zone, p_fine timestamp with time zone, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count          int;
  v_scadenza       timestamptz;
  v_freeze_inizio  timestamptz;
  v_freeze_fine    timestamptz;
  v_giorni         int;
BEGIN
  -- DEBITO-191 · guardia aggiunta: prima non ce n'era nessuna.
  -- La funzione accetta un p_user_id qualsiasi e scrive. Senza questo controllo
  -- chiunque, anche senza sessione, poteva usarla su chiunque: l'unica cosa che
  -- la proteggeva era che il bottone si vede solo in portale.html.
  -- is_staff() e' un EXISTS, quindi non vale mai NULL: respinge anche gli anonimi.
  IF NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  -- Lock + lettura stato corrente
  SELECT freeze_count, scadenza_consumo_open, freeze_inizio, freeze_fine
    INTO v_count, v_scadenza, v_freeze_inizio, v_freeze_fine
    FROM profile_data
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'PROFILO_NON_TROVATO';
  END IF;

  -- Validazione date
  IF p_inizio >= p_fine THEN
    RAISE EXCEPTION 'DATE_INVALIDE';
  END IF;

  IF p_fine <= now() THEN
    RAISE EXCEPTION 'DATE_NEL_PASSATO';
  END IF;

  -- Sovrapposizione: esiste già un freeze (attivo o pianificato)
  -- che si sovrappone con il nuovo intervallo?
  IF v_freeze_inizio IS NOT NULL AND v_freeze_fine IS NOT NULL THEN
    IF p_inizio < v_freeze_fine AND p_fine > v_freeze_inizio THEN
      RAISE EXCEPTION 'SOVRAPPOSIZIONE';
    END IF;
  END IF;

  -- Calcolo giorni
  v_giorni := CEIL(EXTRACT(EPOCH FROM (p_fine - p_inizio)) / 86400)::int;

  -- Applica freeze + estende scadenza + log
  UPDATE profile_data
    SET freeze_inizio        = p_inizio,
        freeze_fine          = p_fine,
        freeze_count         = COALESCE(freeze_count, 0) + 1,
        freeze_giorni_totali = COALESCE(freeze_giorni_totali, 0) + v_giorni,
        scadenza_consumo_open = COALESCE(v_scadenza, now()) + (v_giorni || ' days')::interval,
        freeze_log = COALESCE(freeze_log, '[]'::jsonb) || jsonb_build_object(
          'azione',          'imposta_forzato',
          'motivo',          p_motivo,
          'eseguito_da',     auth.uid(),
          'eseguito_il',     now(),
          'inizio',          p_inizio,
          'fine',            p_fine,
          'giorni_aggiunti', v_giorni,
          'count_pre',       COALESCE(v_count, 0)
        )
    WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'giorni_aggiunti', v_giorni);
END;
$function$;

-- ─── registra_tesseramento ─────────────────────────────────────
-- chiamanti: portale.html:5061
-- scriveva un tesseramento per qualunque persona.
-- guardia AGGIUNTA dopo il BEGIN, corpo invariato.
CREATE OR REPLACE FUNCTION public.registra_tesseramento(p_user_id uuid, p_anno integer DEFAULT NULL::integer, p_data_inizio date DEFAULT NULL::date, p_assicurazione boolean DEFAULT true, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
  v_anno    int  := COALESCE(p_anno, EXTRACT(YEAR FROM CURRENT_DATE)::int);
  v_inizio  date := COALESCE(p_data_inizio, CURRENT_DATE);
  v_scad    date := make_date(v_anno, 12, 31);
BEGIN
  -- DEBITO-191 · guardia aggiunta: prima non ce n'era nessuna.
  -- La funzione accetta un p_user_id qualsiasi e scrive. Senza questo controllo
  -- chiunque, anche senza sessione, poteva usarla su chiunque: l'unica cosa che
  -- la proteggeva era che il bottone si vede solo in portale.html.
  -- is_staff() e' un EXISTS, quindi non vale mai NULL: respinge anche gli anonimi.
  IF NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  SELECT persona_id INTO v_persona FROM profile_data WHERE user_id = p_user_id;
  IF v_persona IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'msg', 'persona non trovata per questo utente');
  END IF;

  INSERT INTO tesseramenti(persona_id, anno, data_inizio, data_scadenza, stato, assicurazione, note, created_by)
  VALUES (v_persona, v_anno, v_inizio, v_scad, 'attivo', p_assicurazione, p_note, auth.uid())
  ON CONFLICT (persona_id, anno) DO UPDATE
    SET data_inizio   = EXCLUDED.data_inizio,
        data_scadenza = EXCLUDED.data_scadenza,
        stato         = 'attivo',
        assicurazione = EXCLUDED.assicurazione,
        note          = COALESCE(EXCLUDED.note, tesseramenti.note),
        updated_at    = now();

  -- mantieni la cache profile_data coerente (flag + anno corrente)
  UPDATE profile_data SET iscrizione_paid = true, iscrizione_anno = v_anno
   WHERE user_id = p_user_id;

  RETURN jsonb_build_object('ok', true, 'persona_id', v_persona, 'anno', v_anno, 'scadenza', v_scad);
END;
$function$;

-- ─── aggiorna_data_iscrizione ──────────────────────────────────
-- chiamanti: portale.html:5357
-- spostava la data di iscrizione di chiunque, e con essa la validita'.
-- guardia AGGIUNTA dopo il BEGIN, corpo invariato.
CREATE OR REPLACE FUNCTION public.aggiorna_data_iscrizione(p_user_id uuid, p_tipo_corso text, p_data date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- DEBITO-191 · guardia aggiunta: prima non ce n'era nessuna.
  -- La funzione accetta un p_user_id qualsiasi e scrive. Senza questo controllo
  -- chiunque, anche senza sessione, poteva usarla su chiunque: l'unica cosa che
  -- la proteggeva era che il bottone si vede solo in portale.html.
  -- is_staff() e' un EXISTS, quindi non vale mai NULL: respinge anche gli anonimi.
  IF NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  UPDATE iscrizioni_corso
     SET data_iscrizione      = p_data,
         data_inizio_validita = p_data,
         updated_at           = now()
   WHERE user_id = p_user_id AND tipo_corso = p_tipo_corso;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'msg', 'iscrizione non trovata', 'tipo_corso', p_tipo_corso);
  END IF;

  RETURN jsonb_build_object('ok', true, 'tipo_corso', p_tipo_corso, 'data', p_data);
END;
$function$;

-- ─── get_tesseramenti ──────────────────────────────────────────
-- chiamanti: portale.html:5080
-- sola lettura, ma su un user_id arbitrario.
-- qui la guardia lascia passare anche l'interessato su se stesso.
-- guardia AGGIUNTA dopo il BEGIN, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_tesseramenti(p_user_id uuid)
 RETURNS TABLE(anno integer, data_inizio date, data_scadenza date, stato text, assicurazione boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_persona uuid;
BEGIN
  -- DEBITO-191 · guardia aggiunta: prima non ce n'era nessuna.
  -- Legge i tesseramenti di un user_id qualsiasi. Ora passano lo staff e
  -- l'interessato su se stesso. IS DISTINCT FROM non vale mai NULL, quindi
  -- un chiamante senza sessione viene respinto invece di passare.
  IF auth.uid() IS DISTINCT FROM p_user_id AND NOT COALESCE(is_staff(), false) THEN
    RAISE EXCEPTION 'Permesso negato' USING ERRCODE = '42501';
  END IF;

  SELECT persona_id INTO v_persona FROM profile_data WHERE user_id = p_user_id;
  IF v_persona IS NULL THEN RETURN; END IF;
  RETURN QUERY
    SELECT t.anno, t.data_inizio, t.data_scadenza,
           CASE WHEN t.stato = 'annullato' THEN 'annullato'
                WHEN t.data_scadenza < CURRENT_DATE THEN 'scaduto'
                ELSE 'attivo' END AS stato,
           t.assicurazione
    FROM tesseramenti t
    WHERE t.persona_id = v_persona
    ORDER BY t.anno DESC;
END;
$function$;

COMMIT;

-- ==========================================================================
-- V-firme · atteso 0 righe
-- ==========================================================================
SELECT p.proname, count(*) AS firme
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('annulla_freeze','dichiara_freeze_forzato',
      'registra_tesseramento','aggiorna_data_iscrizione','get_tesseramenti')
GROUP BY p.proname HAVING count(*) > 1;

-- V-portale · dopo il 04b, dal portale come staff: congelare e scongelare un
-- profilo di prova deve funzionare come prima. Come allievo, la stessa chiamata
-- deve rispondere 'Permesso negato: serve staff'.
