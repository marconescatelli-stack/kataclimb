-- ============================================================================
-- SALA CON MONITOR · 04 — Il monitor legge la scheda ridotta, ma non scrive
--                         osservazioni ne' azioni sui lead
-- Data: 2026-10-07 · Preparata per Marco · NON APPLICATA
-- Richiede 03_scheda_istruttore_in_turno.sql gia' applicato (il primo blocco lo
-- controlla): questo file ridefinisce di nuovo get_scheda_allievo partendo da li'.
--
-- IL PROBLEMA
--   is_mio_allievo(p) = segreteria OR is_monitor() OR persona tra i miei allievi.
--   La usano tre funzioni (verificato il 7 ott, nessuna policy la usa):
--     · get_scheda_allievo       -> lettura: per il monitor va bene (scheda ridotta);
--     · salva_osservazione       -> scrittura: osservazioni con le scale 1–5;
--     · istruttore_azione_lead   -> scrittura: crm_follow_ups + lead_data
--                                   (ultima_interazione, prossima_azione_il,
--                                   tentativi_contatto).
--   Quindi chi ha staff_role='staff_monitor', chiamando l'API con la sua sessione,
--   puo' scrivere osservazioni e registrare chiamate/richiami su QUALSIASI persona
--   o lead. oggi.html non gli mostra quei bottoni, ma l'interfaccia non e' un
--   controllo. Oggi c'e' un solo staff_monitor (Francesco Maria Perucatti).
--
-- LA CORREZIONE
--   · is_mio_allievo torna a "segreteria OR persona tra i miei allievi" (via is_monitor);
--   · get_scheda_allievo apre esplicitamente al monitor (sempre, ridotta come oggi)
--     e allo staff in turno aperto (come in 03). Riduzione invariata.
--   Effetto: per il monitor non cambia niente in pagina; salva_osservazione e
--   istruttore_azione_lead gli rispondono "Non è un tuo allievo".
--   monitor_segna non usa is_mio_allievo e resta com'e' (e' la sua scrittura).
-- ============================================================================


-- ─── PRIMA · stato attuale ──────────────────────────────────────────────────
-- Fingendo di essere Francesco (36a437f8-…, staff_monitor): is_mio_allievo su una
-- persona qualsiasi. Atteso: true (e' il buco). Annullato con ROLLBACK.
BEGIN;
SELECT set_config('request.jwt.claim.sub', '36a437f8-fc67-4941-8b22-9557b6df2ebc', true);
SELECT set_config('request.jwt.claims', '{"sub":"36a437f8-fc67-4941-8b22-9557b6df2ebc","role":"authenticated"}', true);
SELECT public.is_monitor() AS is_monitor,
       public.is_mio_allievo((SELECT id FROM public.persone LIMIT 1)) AS is_mio_allievo_su_chiunque;
ROLLBACK;


-- ─── CORREZIONE ─────────────────────────────────────────────────────────────
BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.in_turno_sala()') IS NULL THEN
    RAISE EXCEPTION 'Applica prima 03_scheda_istruttore_in_turno.sql';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION public.is_mio_allievo(p_persona_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT is_segreteria_piena()
      OR EXISTS(SELECT 1 FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id);
$function$;

-- get_scheda_allievo: identica a 03 tranne la guardia, che ora nomina il monitor.
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
  -- ridotta per chi non e' segreteria e non ha la persona tra i suoi allievi
  IF NOT is_segreteria_piena() AND NOT EXISTS(SELECT 1 FROM get_miei_allievi() a WHERE a.persona_id=p_persona_id) THEN
    v := (v - 'lead' - 'diario' - 'modulo' - 'prime' - 'contatori') || jsonb_build_object('persona', (v->'persona') - 'telefono' - 'email' - 'data_nascita', 'ridotta', true);
  END IF;
  RETURN v;
END $function$;

COMMIT;


-- ─── DOPO · prova vera, annullata con ROLLBACK (nessuna riga resta) ──────────
-- Eseguire il blocco intero in UNA sola chiamata. Si finge di essere Francesco
-- (staff_monitor) e si provano lettura e due scritture, catturando gli errori.
-- Atteso:
--   is_mio_allievo_su_chiunque = false
--   scheda                     = 'APERTA ridotta=true'
--   salva_osservazione         = 'RESPINTA: Non è un tuo allievo'
--   istruttore_azione_lead     = 'RESPINTA: Non è un tuo allievo'
BEGIN;
SELECT set_config('request.jwt.claim.sub', '36a437f8-fc67-4941-8b22-9557b6df2ebc', true);
SELECT set_config('request.jwt.claims', '{"sub":"36a437f8-fc67-4941-8b22-9557b6df2ebc","role":"authenticated"}', true);
CREATE TEMP TABLE _esito (prova text, risultato text) ON COMMIT DROP;
DO $$
DECLARE v_pid uuid; v_lead uuid; s jsonb;
BEGIN
  SELECT l.persona_id, l.id INTO v_pid, v_lead FROM public.lead_data l WHERE l.persona_id IS NOT NULL LIMIT 1;
  INSERT INTO _esito VALUES ('is_mio_allievo_su_chiunque', public.is_mio_allievo(v_pid)::text);
  BEGIN
    s := public.get_scheda_allievo(v_pid);
    INSERT INTO _esito VALUES ('scheda', 'APERTA ridotta='||coalesce(s->>'ridotta','no'));
  EXCEPTION WHEN others THEN INSERT INTO _esito VALUES ('scheda', 'RESPINTA: '||SQLERRM); END;
  BEGIN
    PERFORM public.salva_osservazione(v_pid, '{"contesto":"open","note":"PROVA monitor"}');
    INSERT INTO _esito VALUES ('salva_osservazione', 'PASSATA (male)');
  EXCEPTION WHEN others THEN INSERT INTO _esito VALUES ('salva_osservazione', 'RESPINTA: '||SQLERRM); END;
  BEGIN
    PERFORM public.istruttore_azione_lead(v_lead, 'nota', 'PROVA monitor', NULL);
    INSERT INTO _esito VALUES ('istruttore_azione_lead', 'PASSATA (male)');
  EXCEPTION WHEN others THEN INSERT INTO _esito VALUES ('istruttore_azione_lead', 'RESPINTA: '||SQLERRM); END;
END $$;
SELECT * FROM _esito;
ROLLBACK;
