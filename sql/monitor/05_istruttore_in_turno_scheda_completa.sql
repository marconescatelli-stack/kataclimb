-- ============================================================================
-- SALA CON MONITOR · 05 — L'istruttore in turno vede la scheda COMPLETA di tutti
--                         e scrive osservazioni su chiunque
-- Data: 2026-10-07 · Decisioni di Marco dopo la v2.19 · APPLICATA 2026-10-07
--   (get_scheda_allievo e salva_osservazione aggiornate sul DB di produzione
--    alle 12:52 e alle 13:52, direttamente da Marco).
--
-- Questo file NON e' stato scritto prima di applicare: e' la registrazione di
-- quello che c'e' sul DB, copiato da pg_get_functiondef il 7 ott dopo le 13:52.
-- Rieseguirlo non cambia niente (CREATE OR REPLACE con le stesse definizioni).
--
-- COSA CAMBIA RISPETTO A 03 e 04
--   · get_scheda_allievo: guardia invariata (is_mio_allievo OR is_monitor OR
--     staff in turno aperto). La riduzione (ridotta:true, niente telefono, email,
--     data di nascita, lead, diario, modulo, prime, contatori) resta SOLO per
--     is_monitor() sulle persone non sue. L'istruttore in turno sala vede la
--     scheda completa di tutti.
--   · salva_osservazione: passa con is_mio_allievo OR (is_staff AND NOT is_monitor
--     AND in_turno_sala). L'istruttore in turno scrive osservazioni su chiunque;
--     il monitor no.
--   · istruttore_azione_lead: invariata (is_mio_allievo, come da 04).
-- ============================================================================


-- ─── PRIMA ──────────────────────────────────────────────────────────────────
-- Stato di partenza = 04 applicato: guardia e riduzione senza is_monitor().
-- Atteso: riduzione_solo_monitor = false, salva_istruttore_in_turno = false.
SELECT
  (SELECT prosrc ILIKE '%IF is_monitor() AND NOT is_segreteria_piena()%' FROM pg_proc WHERE proname = 'get_scheda_allievo') AS riduzione_solo_monitor,
  (SELECT prosrc ILIKE '%NOT is_monitor() AND in_turno_sala()%'           FROM pg_proc WHERE proname = 'salva_osservazione') AS salva_istruttore_in_turno;


-- ─── DEFINIZIONI LIVE ───────────────────────────────────────────────────────
BEGIN;

CREATE OR REPLACE FUNCTION public.get_scheda_allievo(p_persona_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb; v_user uuid; v_lead uuid;
BEGIN
  IF NOT (is_mio_allievo(p_persona_id) OR is_monitor() OR (is_staff() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  SELECT p.user_id INTO v_user FROM profile_data p WHERE p.persona_id=p_persona_id ORDER BY p.created_at LIMIT 1;
  SELECT l.id INTO v_lead FROM lead_data l WHERE l.persona_id=p_persona_id ORDER BY l.created_at DESC LIMIT 1;
  SELECT jsonb_build_object(
    'persona', (SELECT jsonb_build_object('id',pe.id,'nome',pe.nome,'cognome',pe.cognome,'telefono',pe.telefono,'email',pe.email,'data_nascita',pe.data_nascita,'foto_path',pe.foto_riconoscimento_path) FROM persone pe WHERE pe.id=p_persona_id),
    'user_id', v_user,
    'riga', (SELECT to_jsonb(a) FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id),
    'lead', (SELECT jsonb_build_object('id',l.id,'funnel_stage',l.funnel_stage,'fonte',l.fonte,'esito_prima_lezione',l.esito_prima_lezione,'nota_istruttore',l.nota_istruttore,'note',l.note,'note_crm',l.note_crm,'lavoro',l.lavoro,'esperienza_sport',l.esperienza_sport,'motivo_ora',l.motivo_ora,'freno',l.freno,'profilo_caratteriale',l.profilo_caratteriale,'prossima_azione_il',l.prossima_azione_il,'ultima_interazione',l.ultima_interazione,'tentativi_contatto',l.tentativi_contatto) FROM lead_data l WHERE l.id=v_lead),
    'modulo', (SELECT coalesce(jsonb_agg(jsonb_build_object('data',r.created_at,'canale',r.canale,'note',r.note) ORDER BY r.created_at DESC),'[]') FROM lead_richieste r WHERE r.persona_id=p_persona_id AND r.note IS NOT NULL),
    'diario', (SELECT coalesce(jsonb_agg(jsonb_build_object('id',f.id,'tipo',f.tipo,'esito',f.esito,'testo',f.testo,'data',coalesce(f.avvenuto_il,f.created_at),'autore',coalesce(pr.nome||' '||pr.cognome,'—'),'mia',f.created_by=auth.uid()) ORDER BY coalesce(f.avvenuto_il,f.created_at) DESC),'[]') FROM crm_follow_ups f LEFT JOIN profiles pr ON pr.user_id=f.created_by WHERE f.lead_id=v_lead),
    'prime', (SELECT coalesce(jsonb_agg(jsonb_build_object('data',ppl.data_lezione,'tipo',c.tipo_corso,'stato',ppl.stato,'presente',ppl.presente,'istruttore',i.nome) ORDER BY ppl.data_lezione DESC),'[]') FROM prenotazioni_prima_lezione ppl JOIN lead_data l ON l.id=ppl.lead_id LEFT JOIN corsi_attivi_settimanali c ON c.id=ppl.slot_id LEFT JOIN istruttori i ON i.id=c.istruttore_id WHERE l.persona_id=p_persona_id),
    'iscrizioni', (SELECT coalesce(jsonb_agg(jsonb_build_object('tipo_corso',ic.tipo_corso,'status',ic.status,'data_iscrizione',ic.data_iscrizione,'inizio',ic.data_inizio_validita,'fine',ic.data_fine_validita,'lezioni_totali',ic.lezioni_totali,'stato_pagamento',ic.stato_pagamento) ORDER BY ic.data_iscrizione DESC),'[]') FROM iscrizioni_corso ic WHERE ic.user_id=v_user),
    'contatori', CASE WHEN v_user IS NULL THEN '[]'::jsonb ELSE get_contatori(v_user) END,
    'osservazioni', (SELECT coalesce(jsonb_agg((to_jsonb(o) - 'istruttore_user_id') || jsonb_build_object('autore',coalesce(pr.nome||' '||pr.cognome,'—'),'ruolo',CASE WHEN o.contesto='sala_monitor' THEN 'monitor' ELSE 'istruttore' END,'mia',o.istruttore_user_id=auth.uid()) ORDER BY o.data DESC, o.created_at DESC),'[]') FROM osservazioni_allievo o LEFT JOIN profiles pr ON pr.user_id=o.istruttore_user_id WHERE o.persona_id=p_persona_id),
    'prossimo_corso', (SELECT CASE a.corso_attivo WHEN 'open' THEN 'advance' WHEN 'advance' THEN 'intro_corda' WHEN 'intro_corda' THEN 'evo_corda' WHEN 'evo_corda' THEN 'fly' ELSE CASE WHEN a.funnel_stage='fatta_prima_lezione' THEN 'open' END END FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id)
  ) INTO v;
  -- ridotta SOLO per il monitor (staff_monitor) sulle persone non sue.
  -- Decisione Marco 7 ott: l'istruttore in turno sala vede la scheda completa di tutti.
  IF is_monitor() AND NOT is_segreteria_piena() AND NOT EXISTS(SELECT 1 FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id) THEN
    v := (v - 'lead' - 'diario' - 'modulo' - 'prime' - 'contatori') || jsonb_build_object('persona', (v->'persona') - 'telefono' - 'email' - 'data_nascita', 'ridotta', true);
  END IF;
  RETURN v;
END $function$;

CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE);
BEGIN
  -- Decisione Marco 7 ott: l'istruttore con turno sala aperto scrive osservazioni su chiunque. Il monitor (staff_monitor) no.
  IF NOT (is_mio_allievo(p_persona_id) OR (is_staff() AND NOT is_monitor() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  IF p->>'contesto' = 'sala_monitor' THEN RAISE EXCEPTION 'La Sala con Monitor si annota con monitor_segna'; END IF;
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, obiettivo, interesse, aree_miglioramento,
    socializzazione, socializzazione_nota, fiducia, fiducia_nota, autostima, autostima_nota,
    concentrazione, concentrazione_nota, gestione_paura, gestione_paura_nota, note)
  VALUES (p_persona_id, auth.uid(), v_data, p->>'contesto', p->>'obiettivo', p->>'interesse', p->>'aree_miglioramento',
    (p->>'socializzazione')::smallint, p->>'socializzazione_nota', (p->>'fiducia')::smallint, p->>'fiducia_nota',
    (p->>'autostima')::smallint, p->>'autostima_nota', (p->>'concentrazione')::smallint, p->>'concentrazione_nota',
    (p->>'gestione_paura')::smallint, p->>'gestione_paura_nota', p->>'note')
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto IS DISTINCT FROM 'sala_monitor' DO UPDATE SET
    contesto=EXCLUDED.contesto, obiettivo=EXCLUDED.obiettivo, interesse=EXCLUDED.interesse, aree_miglioramento=EXCLUDED.aree_miglioramento,
    socializzazione=EXCLUDED.socializzazione, socializzazione_nota=EXCLUDED.socializzazione_nota,
    fiducia=EXCLUDED.fiducia, fiducia_nota=EXCLUDED.fiducia_nota, autostima=EXCLUDED.autostima, autostima_nota=EXCLUDED.autostima_nota,
    concentrazione=EXCLUDED.concentrazione, concentrazione_nota=EXCLUDED.concentrazione_nota,
    gestione_paura=EXCLUDED.gestione_paura, gestione_paura_nota=EXCLUDED.gestione_paura_nota, note=EXCLUDED.note, updated_at=now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'data',v_data);
END $function$;

COMMIT;


-- ─── DOPO ───────────────────────────────────────────────────────────────────
-- Atteso: riduzione_solo_monitor = true, salva_istruttore_in_turno = true.
SELECT
  (SELECT prosrc ILIKE '%IF is_monitor() AND NOT is_segreteria_piena()%' FROM pg_proc WHERE proname = 'get_scheda_allievo') AS riduzione_solo_monitor,
  (SELECT prosrc ILIKE '%NOT is_monitor() AND in_turno_sala()%'           FROM pg_proc WHERE proname = 'salva_osservazione') AS salva_istruttore_in_turno;
