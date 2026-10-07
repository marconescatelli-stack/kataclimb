-- ============================================================================
-- SALA CON MONITOR · 03 — L'istruttore in turno apre la scheda (ridotta)
--                         anche di chi non e' suo allievo
-- Data: 2026-10-07 · Preparata per Marco · NON APPLICATA
-- Indipendente da 01 e 02.
--
-- IL PROBLEMA
--   Il monitor e' un turno, non un ruolo: anche gli istruttori fanno Sala con
--   Monitor. get_scheda_allievo pero' passa solo se is_mio_allievo(), che vale per
--   segreteria, per chi ha staff_role='staff_monitor' (is_monitor) e per gli
--   allievi propri dell'istruttore. Un istruttore in turno che cerca una persona
--   non sua riceve "Non è un tuo allievo". oggi.html v2.18 gli lascia solo nome +
--   campo Annota (monitor_segna non controlla l'appartenenza).
--
--   NOTA: non e' una policy RLS. get_scheda_allievo e' SECURITY DEFINER e salta
--   le policy delle tabelle: l'accesso lo decide la guardia dentro la funzione.
--   E' quella che si corregge qui.
--
-- LA CORREZIONE
--   · nuova in_turno_sala(): l'utente ha un turno APERTO oggi in turni_monitor;
--   · get_scheda_allievo passa anche per lo staff in turno aperto;
--   · la scheda e' RIDOTTA (niente telefono, email, data di nascita, lead, diario,
--     modulo, prime, contatori) per chiunque non sia segreteria e non abbia la
--     persona tra i propri allievi. Per il monitor non cambia niente (era gia'
--     ridotta); per l'istruttore sui suoi allievi resta completa.
--   is_mio_allievo NON si tocca: la usano anche salva_osservazione e
--   istruttore_azione_lead, che non devono aprirsi a chi e' solo in turno.
--   Il permesso finisce con il turno: a turno chiuso torna "Non è un tuo allievo".
-- ============================================================================


-- ─── PRIMA · stato attuale ──────────────────────────────────────────────────
-- Fingendo di essere Mello: is_mio_allievo su una persona che non e' sua.
-- Atteso: false (e' il motivo dell'errore). Annullato con ROLLBACK.
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'e4841ae2-aeef-4007-839d-7837d197195b', true);
SELECT set_config('request.jwt.claims', '{"sub":"e4841ae2-aeef-4007-839d-7837d197195b","role":"authenticated"}', true);
SELECT pe.id AS persona_non_sua, public.is_mio_allievo(pe.id) AS is_mio_allievo
FROM public.persone pe
WHERE NOT EXISTS (SELECT 1 FROM public.get_miei_allievi() a WHERE a.persona_id = pe.id)
LIMIT 1;
ROLLBACK;

-- La funzione in_turno_sala non esiste ancora. Atteso: NULL.
SELECT to_regprocedure('public.in_turno_sala()') AS in_turno_sala;


-- ─── CORREZIONE ─────────────────────────────────────────────────────────────
BEGIN;

CREATE OR REPLACE FUNCTION public.in_turno_sala()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT EXISTS(SELECT 1 FROM turni_monitor t
                WHERE t.monitor_user_id=auth.uid() AND t.data=CURRENT_DATE AND t.fine IS NULL);
$function$;
REVOKE EXECUTE ON FUNCTION public.in_turno_sala() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.in_turno_sala() TO authenticated;

-- get_scheda_allievo: cambiano solo la guardia (prima riga) e la condizione della
-- riduzione (ultimo IF). Il resto e' identico alla versione live del 7 ott.
CREATE OR REPLACE FUNCTION public.get_scheda_allievo(p_persona_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb; v_user uuid; v_lead uuid;
BEGIN
  IF NOT (is_mio_allievo(p_persona_id) OR (is_staff() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
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
  -- ridotta per chi non e' segreteria e non ha la persona tra i suoi allievi
  -- (monitor: come prima; istruttore in turno su persone non sue: nuovo)
  IF NOT is_segreteria_piena() AND NOT EXISTS(SELECT 1 FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id) THEN
    v := (v - 'lead' - 'diario' - 'modulo' - 'prime' - 'contatori') || jsonb_build_object('persona', (v->'persona') - 'telefono' - 'email' - 'data_nascita', 'ridotta', true);
  END IF;
  RETURN v;
END $function$;

COMMIT;


-- ─── DOPO · prova vera, annullata con ROLLBACK (nessuna riga resta) ──────────
-- Eseguire il blocco intero in UNA sola chiamata. Si finge di essere Mello,
-- si apre un turno e si chiedono due schede.
-- Atteso:
--   riga 'non sua': ridotta = true, ha_telefono = false, ha_lead = false
--   riga 'sua'    : ridotta = NULL, ha_lead = true se l'allievo ha un lead
--                   (scheda completa come prima)
-- Senza turno aperto la scheda della persona non sua darebbe ancora
-- "Non è un tuo allievo" (non provato qui: l'errore annullerebbe il blocco).
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'e4841ae2-aeef-4007-839d-7837d197195b', true);
SELECT set_config('request.jwt.claims', '{"sub":"e4841ae2-aeef-4007-839d-7837d197195b","role":"authenticated"}', true);
SELECT public.monitor_turno('inizio', NULL);
CREATE TEMP TABLE _prova ON COMMIT DROP AS
  SELECT 'non sua'::text AS caso, (SELECT pe.id FROM public.persone pe
     WHERE NOT EXISTS (SELECT 1 FROM public.get_miei_allievi() a WHERE a.persona_id = pe.id) LIMIT 1) AS pid
  UNION ALL
  SELECT 'sua', (SELECT persona_id FROM public.get_miei_allievi() LIMIT 1);
SELECT caso,
       s->>'ridotta'                 AS ridotta,
       (s->'persona') ? 'telefono'   AS ha_telefono,
       (s->'lead') IS NOT NULL AND s->'lead' <> 'null'::jsonb AS ha_lead
FROM (SELECT caso, public.get_scheda_allievo(pid) AS s FROM _prova) x;
ROLLBACK;
