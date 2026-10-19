-- ==========================================================================
-- DEBITO-191 · 04a · Guardie del CRM — 20 funzioni
-- Preparato il 22 settembre 2026 · NON APPLICATO
--
-- Tutte e venti avevano la stessa guardia, e la stessa guardia non funzionava:
-- verso un chiamante anonimo non scattava, e verso lo staff citava quattro ruoli
-- che nel CHECK a DB non esistono, respingendo la segreteria.
-- Provato il 22 set: get_leads_da_contattare rispondeva 410 righe a un anonimo.
-- 
-- Ogni corpo e' stato riletto da pg_get_functiondef il 22 set e lasciato
-- identico: cambia solo il blocco di guardia, segnato da un commento DEBITO-191.
-- Nessuna firma cambia, quindi nessun DROP FUNCTION serve.
-- ==========================================================================

BEGIN;

-- ─── aggiungi_nota_lead ────────────────────────────────────────
-- chiamanti: commerciale.html:328
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.aggiungi_nota_lead(p_lead_id uuid, p_testo text, p_tipo text DEFAULT 'nota'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  IF p_testo IS NULL OR length(trim(p_testo)) = 0 THEN
    RAISE EXCEPTION 'nota vuota';
  END IF;

  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by, avvenuto_il)
  VALUES (p_lead_id, COALESCE(NULLIF(trim(p_tipo),''),'nota'), trim(p_testo), auth.uid(), now())
  RETURNING id INTO v_id;

  UPDATE lead_data
     SET ultima_interazione = now()
   WHERE id = p_lead_id;

  RETURN v_id;
END;
$function$;

-- ─── allega_documento_consenso ─────────────────────────────────
-- chiamanti: nessuno nel repo, verificare i Worker
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.allega_documento_consenso(p_lead_id uuid, p_path text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
  v_n int;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  IF coalesce(trim(p_path),'') = '' THEN
    RAISE EXCEPTION 'percorso documento mancante';
  END IF;

  SELECT persona_id INTO v_persona FROM lead_data WHERE id = p_lead_id;
  IF v_persona IS NULL THEN
    RAISE EXCEPTION 'lead non trovato o senza persona';
  END IF;

  UPDATE consensi_minori SET documento_url = p_path
  WHERE persona_id = v_persona;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n = 0 THEN
    RAISE EXCEPTION 'nessun consenso registrato per questo minore: registra prima i consensi dal foglio, poi allega la foto';
  END IF;

  RETURN jsonb_build_object('ok', true, 'persona_id', v_persona, 'righe_aggiornate', v_n, 'documento', p_path);
END;
$function$;

-- ─── avanza_sequenza_wa ────────────────────────────────────────
-- chiamanti: nessuno nel repo, verificare i Worker
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.avanza_sequenza_wa(p_lead_id uuid, p_step integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_new int;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET wa_seq_step = GREATEST(COALESCE(wa_seq_step,0), p_step),
         memo_wa_at = now(),
         ultima_interazione = now()
   WHERE id = p_lead_id
   RETURNING wa_seq_step INTO v_new;

  RETURN v_new;
END;
$function$;

-- ─── conta_code_lead ───────────────────────────────────────────
-- chiamanti: oggi.html:778
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.conta_code_lead()
 RETURNS TABLE(commerciale bigint, riacciuffo bigint, vecchi bigint, segreteria bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      CASE
        WHEN ld.coda <> 'commerciale' THEN ld.coda
        WHEN ld.funnel_stage IN ('prenotato_prima_lezione','fatta_prima_lezione') THEN 'commerciale'
        WHEN ld.prossima_azione_il IS NOT NULL
             AND ld.prossima_azione_il::date > CURRENT_DATE THEN 'commerciale'
        WHEN ld.created_at < now() - interval '60 days' THEN 'vecchi'
        WHEN ld.created_at < now() - interval '30 days' THEN 'riacciuffo'
        ELSE 'commerciale'
      END AS coda_eff
    FROM lead_data ld
    WHERE ld.funnel_stage NOT IN ('perso','ibernato')
  )
  SELECT
    count(*) FILTER (WHERE coda_eff = 'commerciale'),
    count(*) FILTER (WHERE coda_eff = 'riacciuffo'),
    count(*) FILTER (WHERE coda_eff = 'vecchi'),
    count(*) FILTER (WHERE coda_eff = 'segreteria')
  FROM base;
END;
$function$;

-- ─── crea_figlio_lead ──────────────────────────────────────────
-- chiamanti: commerciale.html:364
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.crea_figlio_lead(p_genitore_lead_id uuid, p_nome text, p_cognome text, p_fascia text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
  v_lead uuid;
BEGIN
  -- guard: staff loggato OPPURE service_role (Worker webhook Stripe)
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

  IF p_fascia NOT IN ('bambino','ragazzo') THEN
    RAISE EXCEPTION 'fascia non valida: %', p_fascia;
  END IF;
  IF p_nome IS NULL OR length(trim(p_nome)) = 0 THEN
    RAISE EXCEPTION 'nome obbligatorio';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM lead_data WHERE id = p_genitore_lead_id) THEN
    RAISE EXCEPTION 'genitore non trovato';
  END IF;

  -- 1) anagrafica minore via cancello unico (nessun contatto: telefono/email
  --    vivono sul referente -> INSERT pulito, mai dedup/fusione)
  v_persona := garantisci_persona(
    p_email    := NULL,
    p_nome     := p_nome,
    p_cognome  := p_cognome,
    p_telefono := NULL
  );

  -- 2) lead della figlia: segreteria + fascia, stato di partenza 'nuovo'
  INSERT INTO lead_data (persona_id, coda, fascia, funnel_stage)
  VALUES (v_persona, 'segreteria', p_fascia, 'nuovo')
  RETURNING id INTO v_lead;

  -- 3) relazione col genitore (lui pagante)
  INSERT INTO crm_relazioni (lead_genitore_id, lead_figlio_id, tipo_relazione, pagante)
  VALUES (p_genitore_lead_id, v_lead, 'genitore_figlio', true);

  RETURN v_lead;
END;
$function$;

-- ─── get_consensi_minore ───────────────────────────────────────
-- chiamanti: portale.html:5103
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_consensi_minore(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
  v_out jsonb;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  SELECT persona_id INTO v_persona FROM lead_data WHERE id = p_lead_id;
  IF v_persona IS NULL THEN
    RETURN jsonb_build_object('persona_id', NULL, 'consensi', '[]'::jsonb);
  END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'tipo', c.tipo,
           'concesso', c.concesso,
           'concesso_at', c.concesso_at,
           'revocato_at', c.revocato_at,
           'documento_url', c.documento_url,
           'note', c.note
         ) ORDER BY c.tipo), '[]'::jsonb)
  INTO v_out
  FROM consensi_minori c
  WHERE c.persona_id = v_persona;

  RETURN jsonb_build_object('persona_id', v_persona, 'consensi', v_out);
END;
$function$;

-- ─── get_famiglia ──────────────────────────────────────────────
-- chiamanti: portale.html:5091
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_famiglia(p_persona_id uuid DEFAULT NULL::uuid, p_lead_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_leads_ingresso uuid[];
  v_genitori       uuid[];
  v_membri         jsonb;
BEGIN
  -- guard staff (pattern standard)
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  -- lead di partenza: da lead diretto o da tutti i lead della persona
  IF p_lead_id IS NOT NULL THEN
    v_leads_ingresso := ARRAY[p_lead_id];
  ELSIF p_persona_id IS NOT NULL THEN
    SELECT coalesce(array_agg(id), '{}') INTO v_leads_ingresso
    FROM lead_data WHERE persona_id = p_persona_id;
  ELSE
    RAISE EXCEPTION 'serve p_persona_id o p_lead_id';
  END IF;

  -- genitori del nucleo: se l'ingresso è un figlio → i suoi genitori;
  -- se è un genitore → lui stesso
  SELECT coalesce(array_agg(DISTINCT g), '{}') INTO v_genitori
  FROM (
    SELECT r.lead_genitore_id AS g FROM crm_relazioni r
      WHERE r.lead_figlio_id = ANY(v_leads_ingresso)
    UNION
    SELECT r.lead_genitore_id FROM crm_relazioni r
      WHERE r.lead_genitore_id = ANY(v_leads_ingresso)
  ) x;

  IF array_length(v_genitori, 1) IS NULL THEN
    RETURN jsonb_build_object('membri', '[]'::jsonb);
  END IF;

  -- membri: tutti i referenti + tutti i figli agganciati a quei referenti
  SELECT jsonb_agg(m ORDER BY (m->>'ruolo') DESC, m->>'cognome', m->>'nome') INTO v_membri
  FROM (
    SELECT DISTINCT ON (ld.id) jsonb_build_object(
      'ruolo',        'referente',
      'lead_id',      ld.id,
      'persona_id',   pe.id,
      'nome',         pe.nome,
      'cognome',      pe.cognome,
      'email',        pe.email,
      'telefono',     pe.telefono,
      'fascia',       ld.fascia,
      'data_nascita', pe.data_nascita,
      'pagante',      true
    ) AS m
    FROM lead_data ld JOIN persone pe ON pe.id = ld.persona_id
    WHERE ld.id = ANY(v_genitori)
    UNION ALL
    SELECT DISTINCT ON (ld.id) jsonb_build_object(
      'ruolo',        'allievo',
      'lead_id',      ld.id,
      'persona_id',   pe.id,
      'nome',         pe.nome,
      'cognome',      pe.cognome,
      'email',        pe.email,
      'telefono',     pe.telefono,
      'fascia',       ld.fascia,
      'data_nascita', pe.data_nascita,
      'pagante',      coalesce(r.pagante, false) IS FALSE
    ) AS m
    FROM crm_relazioni r
    JOIN lead_data ld ON ld.id = r.lead_figlio_id
    JOIN persone   pe ON pe.id = ld.persona_id
    WHERE r.lead_genitore_id = ANY(v_genitori)
  ) membri(m);

  RETURN jsonb_build_object('membri', coalesce(v_membri, '[]'::jsonb));
END;
$function$;

-- ─── get_leads_da_contattare ───────────────────────────────────
-- chiamanti: commerciale.html:775, portale.html:4497
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_leads_da_contattare()
 RETURNS TABLE(id uuid, persona_id uuid, nome text, cognome text, telefono text, email text, fonte text, funnel_stage text, stato_gestione text, coda text, fascia text, prossima_azione_il text, lead_creato_il timestamp with time zone, ultima_canale text, ultima_campagna text, ultimo_ingresso timestamp with time zone, n_richieste bigint, ultima_nota text, link_inviato_at timestamp with time zone, memo_wa_at timestamp with time zone, ultima_interazione timestamp with time zone, profilo_caratteriale text, ricordo1_inviato_at timestamp with time zone, ricordo2_inviato_at timestamp with time zone, motivazionale_inviato_at timestamp with time zone, recensione_inviata_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
  SELECT
    ld.id, ld.persona_id, p.nome, p.cognome, p.telefono, p.email,
    ld.fonte, ld.funnel_stage, ld.stato_gestione, ld.coda, ld.fascia,
    ld.prossima_azione_il::text, ld.created_at,
    lr.canale, lr.campagna, COALESCE(lr.created_at, ld.created_at), COALESCE(rc.n,0),
    COALESCE(ld.note, ln.note),
    ld.link_inviato_at, ld.memo_wa_at, ld.ultima_interazione, ld.profilo_caratteriale,
    ld.ricordo1_inviato_at, ld.ricordo2_inviato_at, ld.motivazionale_inviato_at,
    ld.recensione_inviata_at
  FROM lead_data ld
  JOIN persone p ON p.id = ld.persona_id
  LEFT JOIN LATERAL (
    SELECT r.canale, r.campagna, r.created_at
    FROM lead_richieste r WHERE r.persona_id = ld.persona_id
    ORDER BY r.created_at DESC LIMIT 1
  ) lr ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS n FROM lead_richieste r2 WHERE r2.persona_id = ld.persona_id
  ) rc ON true
  LEFT JOIN LATERAL (
    SELECT r3.note
    FROM lead_richieste r3
    WHERE r3.persona_id = ld.persona_id AND r3.note IS NOT NULL
    ORDER BY r3.created_at DESC LIMIT 1
  ) ln ON true
  WHERE ld.funnel_stage NOT IN ('perso','ibernato')
  ORDER BY (ld.stato_gestione = 'da_richiamare') DESC,
           COALESCE(lr.created_at, ld.created_at) DESC;
END;
$function$;

-- ─── get_qualifica_lead ────────────────────────────────────────
-- chiamanti: portale.html:4794
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_qualifica_lead(p_lead_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  SELECT jsonb_build_object(
    'lavoro', lavoro,
    'esperienza_sport', esperienza_sport,
    'motivo_ora', motivo_ora,
    'freno', freno,
    'tentativi_contatto', tentativi_contatto
  ) INTO v FROM lead_data WHERE id = p_lead_id;

  RETURN COALESCE(v, '{}'::jsonb);
END $function$;

-- ─── get_richieste_lead ────────────────────────────────────────
-- chiamanti: portale.html:5388
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_richieste_lead(p_lead_id uuid)
 RETURNS TABLE(note text, canale text, campagna text, pagina text, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  SELECT ld.persona_id INTO v_persona FROM lead_data ld WHERE ld.id = p_lead_id;
  IF v_persona IS NULL THEN RETURN; END IF;

  RETURN QUERY
  SELECT r.note, r.canale, r.campagna, r.pagina, r.created_at
  FROM lead_richieste r
  WHERE r.persona_id = v_persona
  ORDER BY r.created_at DESC;
END;
$function$;

-- ─── get_timeline_persona ──────────────────────────────────────
-- chiamanti: nessuno nel repo, verificare i Worker
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.get_timeline_persona(p_persona_id uuid)
 RETURNS TABLE(quando timestamp with time zone, tipo text, titolo text, dettaglio text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
  SELECT r.created_at, 'richiesta'::text,
         'Richiesta · '||COALESCE(r.canale,'?'),
         NULLIF(COALESCE(r.campagna,'')||CASE WHEN r.note IS NOT NULL THEN ' · '||r.note ELSE '' END,'')
  FROM lead_richieste r
  WHERE r.persona_id = p_persona_id

  UNION ALL
  SELECT f.created_at, 'contatto'::text,
         COALESCE(f.tipo,'contatto')||COALESCE(' · '||f.esito,''),
         f.testo
  FROM crm_follow_ups f
  JOIN lead_data ld ON ld.id = f.lead_id
  WHERE ld.persona_id = p_persona_id

  UNION ALL
  SELECT m.ts, 'messaggio'::text, m.lbl, NULL::text
  FROM lead_data ld,
  LATERAL (VALUES
    (ld.link_inviato_at,          'Link prenotazione inviato'),
    (ld.memo_wa_at,               'Messaggio WhatsApp'),
    (ld.ricordo1_inviato_at,      'Ricordo 1 inviato'),
    (ld.ricordo2_inviato_at,      'Ricordo 2 inviato'),
    (ld.motivazionale_inviato_at, 'Motivazionale inviato'),
    (ld.recensione_inviata_at,    'Richiesta recensione Google')
  ) AS m(ts,lbl)
  WHERE ld.persona_id = p_persona_id AND m.ts IS NOT NULL

  UNION ALL
  SELECT COALESCE(en.inviato_at, en.created_at), 'email'::text,
         'Email · '||en.tipo_evento||CASE WHEN en.stato<>'mandato' THEN ' ('||en.stato||')' ELSE '' END,
         NULLIF(en.ultimo_errore,'')
  FROM eventi_notifica en
  WHERE en.user_id IN (SELECT pd.user_id FROM profile_data pd WHERE pd.persona_id = p_persona_id AND pd.user_id IS NOT NULL)
     OR en.payload->>'persona_id' = p_persona_id::text

  UNION ALL
  SELECT ppl.created_at, 'prenotazione'::text,
         'Prima Lezione prenotata · '||to_char(ppl.data_lezione,'DD/MM'),
         ppl.stato
  FROM prenotazioni_prima_lezione ppl
  JOIN lead_data ld2 ON ld2.id = ppl.lead_id
  WHERE ld2.persona_id = p_persona_id

  UNION ALL
  SELECT (ppl.data_lezione::timestamptz + interval '12 hours'), 'presenza'::text,
         CASE WHEN ppl.presente THEN 'Prima Lezione · PRESENTE' ELSE 'Prima Lezione · assente' END,
         ppl.note_post
  FROM prenotazioni_prima_lezione ppl
  JOIN lead_data ld3 ON ld3.id = ppl.lead_id
  WHERE ld3.persona_id = p_persona_id AND ppl.presente IS NOT NULL

  UNION ALL
  SELECT (pc.data_lezione::timestamptz + interval '12 hours'),
         CASE pc.stato WHEN 'presente' THEN 'presenza' WHEN 'assente' THEN 'assenza' ELSE 'prenotazione' END,
         initcap(replace(pc.tipo_corso,'_',' '))||' · '||pc.stato||' · '||to_char(pc.data_lezione,'DD/MM'),
         NULL::text
  FROM prenotazioni_corso pc
  WHERE pc.user_id IN (SELECT pd2.user_id FROM profile_data pd2 WHERE pd2.persona_id = p_persona_id AND pd2.user_id IS NOT NULL)
    AND pc.stato <> 'cancellato_in_tempo'

  ORDER BY 1 DESC
  LIMIT 200;
END;
$function$;

-- ─── imposta_coda_fascia ───────────────────────────────────────
-- chiamanti: commerciale.html:340, commerciale.html:347, portale.html:4698
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.imposta_coda_fascia(p_lead_id uuid, p_coda text DEFAULT NULL::text, p_fascia text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE public.lead_data
  SET coda       = COALESCE(p_coda,   coda),
      fascia     = COALESCE(p_fascia, fascia),
      updated_at = now()
  WHERE id = p_lead_id;
END;
$function$;

-- ─── imposta_consenso_minore ───────────────────────────────────
-- chiamanti: portale.html:5115
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.imposta_consenso_minore(p_lead_id uuid, p_tipo text, p_concesso boolean, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_persona uuid;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  IF p_tipo NOT IN ('accesso_portale','visibilita_community','utilizzo_immagini') THEN
    RAISE EXCEPTION 'tipo consenso non valido: %', p_tipo;
  END IF;

  SELECT persona_id INTO v_persona FROM lead_data WHERE id = p_lead_id;
  IF v_persona IS NULL THEN
    RAISE EXCEPTION 'lead non trovato o senza persona';
  END IF;

  -- concesso_at = timestamp dell'atto di registrazione (NOT NULL a schema);
  -- lo stato negativo/revocato vive in concesso=false + revocato_at.
  INSERT INTO consensi_minori (persona_id, tipo, concesso, concesso_at, revocato_at, note, registrato_da)
  VALUES (v_persona, p_tipo, p_concesso, now(),
          CASE WHEN p_concesso THEN NULL ELSE now() END,
          p_note, auth.uid())
  ON CONFLICT (persona_id, tipo) DO UPDATE SET
    concesso    = EXCLUDED.concesso,
    concesso_at = CASE WHEN EXCLUDED.concesso THEN now() ELSE consensi_minori.concesso_at END,
    revocato_at = CASE WHEN EXCLUDED.concesso THEN NULL  ELSE now() END,
    note        = coalesce(EXCLUDED.note, consensi_minori.note),
    registrato_da = EXCLUDED.registrato_da;

  RETURN jsonb_build_object('ok', true, 'persona_id', v_persona, 'tipo', p_tipo, 'concesso', p_concesso);
END;
$function$;

-- ─── inserisci_minore_con_referente ────────────────────────────
-- chiamanti: agenda.html:2399, portale.html:4173
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.inserisci_minore_con_referente(p_figlio_nome text, p_figlio_cognome text, p_fascia text, p_gen_nome text, p_gen_cognome text, p_gen_email text DEFAULT NULL::text, p_gen_telefono text DEFAULT NULL::text, p_figlio_nascita date DEFAULT NULL::date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_gen_persona    uuid;
  v_gen_lead       uuid;
  v_gen_riusato    boolean := false;
  v_figlio_lead    uuid;
  v_figlio_persona uuid;
  v_figlio_riusato boolean := false;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  IF p_fascia NOT IN ('bambino','ragazzo') THEN
    RAISE EXCEPTION 'fascia non valida: %', p_fascia;
  END IF;
  IF coalesce(trim(p_figlio_nome),'') = '' OR coalesce(trim(p_figlio_cognome),'') = '' THEN
    RAISE EXCEPTION 'nome e cognome del minore obbligatori';
  END IF;
  IF coalesce(trim(p_gen_nome),'') = '' OR coalesce(trim(p_gen_cognome),'') = '' THEN
    RAISE EXCEPTION 'nome e cognome del referente obbligatori';
  END IF;
  IF coalesce(trim(p_gen_email),'') = '' AND coalesce(trim(p_gen_telefono),'') = '' THEN
    RAISE EXCEPTION 'serve almeno un recapito del referente (email o telefono)';
  END IF;

  v_gen_persona := garantisci_persona(
    p_email    := nullif(trim(p_gen_email), ''),
    p_nome     := trim(p_gen_nome),
    p_cognome  := trim(p_gen_cognome),
    p_telefono := nullif(trim(p_gen_telefono), '')
  );

  SELECT id INTO v_gen_lead
  FROM lead_data WHERE persona_id = v_gen_persona
  ORDER BY created_at DESC LIMIT 1;

  IF v_gen_lead IS NOT NULL THEN
    v_gen_riusato := true;
  ELSE
    INSERT INTO lead_data (persona_id, coda, fascia, funnel_stage, fonte, note)
    VALUES (v_gen_persona, 'segreteria', 'adulto', 'contattato',
            'manuale', 'Referente minore (inserimento manuale segreteria)')
    RETURNING id INTO v_gen_lead;
  END IF;

  SELECT ld.id, ld.persona_id INTO v_figlio_lead, v_figlio_persona
  FROM crm_relazioni r
  JOIN lead_data ld ON ld.id = r.lead_figlio_id
  JOIN persone   pe ON pe.id = ld.persona_id
  WHERE r.lead_genitore_id = v_gen_lead
    AND r.tipo_relazione   = 'genitore_figlio'
    AND lower(trim(pe.nome))    = lower(trim(p_figlio_nome))
    AND lower(trim(pe.cognome)) = lower(trim(p_figlio_cognome))
  LIMIT 1;

  IF v_figlio_lead IS NOT NULL THEN
    v_figlio_riusato := true;
  ELSE
    v_figlio_lead := crea_figlio_lead(
      p_genitore_lead_id := v_gen_lead,
      p_nome             := trim(p_figlio_nome),
      p_cognome          := trim(p_figlio_cognome),
      p_fascia           := p_fascia
    );
    SELECT persona_id INTO v_figlio_persona FROM lead_data WHERE id = v_figlio_lead;
  END IF;

  IF p_figlio_nascita IS NOT NULL THEN
    UPDATE persone SET data_nascita = p_figlio_nascita
    WHERE id = v_figlio_persona AND data_nascita IS NULL;
  END IF;

  IF coalesce(trim(p_note),'') <> '' THEN
    UPDATE lead_data SET note = p_note
    WHERE id = v_figlio_lead AND coalesce(note,'') = '';
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'figlio_lead_id',      v_figlio_lead,
    'figlio_persona_id',   v_figlio_persona,
    'figlio_riusato',      v_figlio_riusato,
    'genitore_lead_id',    v_gen_lead,
    'genitore_persona_id', v_gen_persona,
    'genitore_riusato',    v_gen_riusato
  );
END;
$function$;

-- ─── salva_qualifica_lead ──────────────────────────────────────
-- chiamanti: portale.html:4804
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.salva_qualifica_lead(p_lead_id uuid, p_lavoro text DEFAULT NULL::text, p_esperienza_sport text DEFAULT NULL::text, p_motivo_ora text DEFAULT NULL::text, p_freno text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data SET
    lavoro           = COALESCE(p_lavoro, lavoro),
    esperienza_sport = COALESCE(p_esperienza_sport, esperienza_sport),
    motivo_ora       = COALESCE(p_motivo_ora, motivo_ora),
    freno            = COALESCE(p_freno, freno),
    updated_at       = now()
  WHERE id = p_lead_id;

  RETURN jsonb_build_object('ok', true, 'lead_id', p_lead_id);
END $function$;

-- ─── segna_link_inviato ────────────────────────────────────────
-- chiamanti: commerciale.html:265
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.segna_link_inviato(p_lead_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET link_inviato_at = now(),
         ultima_interazione = now()
   WHERE id = p_lead_id;
END;
$function$;

-- ─── segna_memo_wa ─────────────────────────────────────────────
-- chiamanti: commerciale.html:301
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.segna_memo_wa(p_lead_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET memo_wa_at = now(),
         ultima_interazione = now()
   WHERE id = p_lead_id;
END;
$function$;

-- ─── segna_recensione_inviata ──────────────────────────────────
-- chiamanti: commerciale.html:314
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.segna_recensione_inviata(p_lead_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET recensione_inviata_at = now(),
         ultima_interazione    = now()
   WHERE id = p_lead_id;
END;
$function$;

-- ─── segna_recensione_inviata_persona ──────────────────────────
-- chiamanti: commerciale.html:725
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.segna_recensione_inviata_persona(p_persona_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET recensione_inviata_at = now(),
         ultima_interazione    = now()
   WHERE persona_id = p_persona_id;
END;
$function$;

-- ─── segna_step_messaggio ──────────────────────────────────────
-- chiamanti: commerciale.html:273
-- guardia sostituita, corpo invariato.
CREATE OR REPLACE FUNCTION public.segna_step_messaggio(p_lead_id uuid, p_step text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF p_step NOT IN ('ricordo1','ricordo2','motivazionale') THEN
    RAISE EXCEPTION 'step "%" non valido (ammessi: ricordo1, ricordo2, motivazionale)', p_step;
  END IF;
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
  IF NOT EXISTS (
    SELECT 1 FROM profile_data
    WHERE user_id = auth.uid()
      AND staff_role IN (
        -- RUOLI AMMESSI: proposta, da confermare con Marco
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  UPDATE lead_data
     SET ricordo1_inviato_at      = CASE WHEN p_step='ricordo1'      THEN now() ELSE ricordo1_inviato_at END,
         ricordo2_inviato_at      = CASE WHEN p_step='ricordo2'      THEN now() ELSE ricordo2_inviato_at END,
         motivazionale_inviato_at = CASE WHEN p_step='motivazionale' THEN now() ELSE motivazionale_inviato_at END,
         ultima_interazione       = now()
   WHERE id = p_lead_id;
END;
$function$;

COMMIT;

-- ==========================================================================
-- V-firme · nessun nome con piu' di una firma dopo l'applicazione
-- Atteso: 0 righe. Se ne esce una, un CREATE OR REPLACE ha creato un gemello
-- invece di sostituire, e ogni chiamata a quel nome fallira' con 'is not unique'.
-- ==========================================================================
SELECT p.proname, count(*) AS firme,
       string_agg(pg_get_function_identity_arguments(p.oid), ' § ') AS quali
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('aggiungi_nota_lead', 'allega_documento_consenso', 'avanza_sequenza_wa', 'conta_code_lead', 'crea_figlio_lead', 'get_consensi_minore', 'get_famiglia',
                    'get_leads_da_contattare', 'get_qualifica_lead', 'get_richieste_lead', 'get_timeline_persona', 'imposta_coda_fascia', 'imposta_consenso_minore', 'inserisci_minore_con_referente',
                    'salva_qualifica_lead', 'segna_link_inviato', 'segna_memo_wa', 'segna_recensione_inviata', 'segna_recensione_inviata_persona', 'segna_step_messaggio')
GROUP BY p.proname HAVING count(*) > 1;

-- V-anon · dopo il 04a, da una sessione a parte:
--   SET ROLE anon; SELECT count(*) FROM get_leads_da_contattare();  -- atteso: errore
--   RESET ROLE;
