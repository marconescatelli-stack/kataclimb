-- ═══ SALA CON MONITOR: NOTE RETROATTIVE E SPOSTAMENTO SULLA PERSONA GIUSTA (consegna 30 ott 2026, punto 3, approvata da Marco il 30/10) ═══
-- Richiede 06_note_sala_atomiche_2026-10-30.sql (_sala_annota).
-- Regole:
--   - Il monitor scrive solo sui PROPRI turni gia' chiusi, fino a 7 giorni indietro (data del turno >= oggi - 7).
--     Segreteria e creator (is_segreteria_piena: creator, admin, segreteria) su qualsiasi turno chiuso, senza limite.
--     I permessi stanno qui nelle RPC, non solo nella pagina.
--   - La nota prende il giorno del turno e l'ora del turno (prima persona segnata = inizio del turno): cade nel giorno giusto del
--     fascicolo e nei conteggi del monitor (la riga resta del monitor del turno anche se la scrive la segreteria).
--   - Traccia: ogni riga aggiunta dopo porta "aggiunta il GG/MM" (e "da Nome" se non l'ha scritta il monitor); ogni spostamento
--     aggiunge "spostata il GG/MM da <persona di prima>". Mai cancellare testo.
--   - Spostare = aggiornare insieme osservazioni_allievo.persona_id e turni_monitor_seguiti del turno. Se la persona giusta ha gia'
--     una nota di sala di quel monitor in quel giorno, il testo si aggiunge alla sua e la riga di prima resta con la sola traccia
--     dello spostamento (nessun testo perso).
-- Da applicare DOPO la 06 e PRIMA del deploy di oggi.html v2.34. Provata con dry-run (ESITO_TEST) il 30/10, nessuna scrittura.

CREATE OR REPLACE FUNCTION public._sala_puo_scrivere(p_turno_id uuid)
 RETURNS turni_monitor
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT * INTO t FROM turni_monitor WHERE id = p_turno_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato'; END IF;
  IF t.fine IS NULL THEN RAISE EXCEPTION 'Il turno è ancora aperto: segna dalla Sala con Monitor come sempre.'; END IF;
  IF is_segreteria_piena() THEN RETURN t; END IF;
  IF t.monitor_user_id <> auth.uid() THEN RAISE EXCEPTION 'Puoi scrivere solo sui tuoi turni. Per gli altri chiedi alla segreteria.'; END IF;
  IF t.data < CURRENT_DATE - 7 THEN
    RAISE EXCEPTION 'Il turno del % è di più di 7 giorni fa: da qui in poi lo sistema la segreteria.', to_char(t.data,'DD/MM');
  END IF;
  RETURN t;
END $function$;
REVOKE ALL ON FUNCTION public._sala_puo_scrivere(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public._sala_firma(p_monitor uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT CASE WHEN auth.uid() = p_monitor THEN ''
    ELSE ' da ' || COALESCE((SELECT nullif(trim(coalesce(nome,'')||' '||coalesce(cognome,'')),'') FROM profiles WHERE user_id = auth.uid()),'segreteria') END;
$function$;
REVOKE ALL ON FUNCTION public._sala_firma(uuid) FROM PUBLIC, anon, authenticated;

-- Elenco dei turni: i miei (monitor) oppure, per segreteria e creator, di tutti. modificabile = la RPC lo accetterebbe adesso.
CREATE OR REPLACE FUNCTION public.monitor_turni_elenco(p_giorni integer DEFAULT 30, p_tutti boolean DEFAULT false)
 RETURNS TABLE(turno_id uuid, monitor_user_id uuid, monitor text, data date, inizio timestamptz, fine timestamptz, ore numeric,
               persone integer, note_turno text, modificabile boolean)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_seg boolean := is_segreteria_piena();
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  RETURN QUERY
  SELECT t.id, t.monitor_user_id,
         COALESCE(nullif(trim(coalesce(pr.nome,'')||' '||coalesce(pr.cognome,'')),''),'—'),
         t.data, t.inizio, t.fine,
         ROUND(EXTRACT(EPOCH FROM (COALESCE(t.fine,t.inizio)-t.inizio))/3600.0*2)/2,
         (SELECT count(*)::int FROM turni_monitor_seguiti s WHERE s.turno_id = t.id),
         t.note,
         (t.fine IS NOT NULL AND (v_seg OR (t.monitor_user_id = auth.uid() AND t.data >= CURRENT_DATE - 7)))
    FROM turni_monitor t LEFT JOIN profiles pr ON pr.user_id = t.monitor_user_id
   WHERE t.data >= CURRENT_DATE - GREATEST(1, LEAST(coalesce(p_giorni,30), 366))
     AND (t.monitor_user_id = auth.uid() OR (p_tutti AND v_seg))
   ORDER BY t.data DESC, t.inizio DESC;
END $function$;

-- Dettaglio di un turno: chi e' stato seguito e le note di sala di quel monitor in quel giorno.
CREATE OR REPLACE FUNCTION public.monitor_turno_dettaglio(p_turno_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; v_seg boolean := is_segreteria_piena();
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT * INTO t FROM turni_monitor WHERE id = p_turno_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato'; END IF;
  IF t.monitor_user_id <> auth.uid() AND NOT v_seg THEN RAISE EXCEPTION 'Puoi vedere solo i tuoi turni'; END IF;
  RETURN jsonb_build_object(
    'turno', jsonb_build_object('id',t.id,'data',t.data,'inizio',t.inizio,'fine',t.fine,'note',t.note,'monitor_user_id',t.monitor_user_id,
       'monitor',(SELECT nullif(trim(coalesce(nome,'')||' '||coalesce(cognome,'')),'') FROM profiles WHERE user_id = t.monitor_user_id),
       'modificabile',(t.fine IS NOT NULL AND (v_seg OR (t.monitor_user_id = auth.uid() AND t.data >= CURRENT_DATE - 7)))),
    'seguiti', (SELECT coalesce(jsonb_agg(jsonb_build_object('persona_id',s.persona_id,
                   'nome',trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),'primo_alle',s.primo_alle,
                   'note',(SELECT o.note FROM osservazioni_allievo o WHERE o.persona_id = s.persona_id AND o.istruttore_user_id = t.monitor_user_id
                             AND o.data = t.data AND o.contesto = 'sala_monitor'))
                 ORDER BY s.primo_alle),'[]'::jsonb)
                FROM turni_monitor_seguiti s JOIN persone pe ON pe.id = s.persona_id WHERE s.turno_id = t.id));
END $function$;

-- Nota retroattiva: stesso modulo della sera (su cosa + com'e' andata), sul turno chiuso.
CREATE OR REPLACE FUNCTION public.monitor_nota_turno(p_turno_id uuid, p_persona_id uuid, p_su_cosa text, p_note text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; v_id uuid; v_riga text; v_quando timestamptz;
BEGIN
  t := _sala_puo_scrivere(p_turno_id);
  IF length(trim(coalesce(p_su_cosa,''))) < 10 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  IF length(trim(coalesce(p_note,''))) < 10 THEN RAISE EXCEPTION 'Scrivi com''è andata'; END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  v_quando := t.inizio;
  v_riga := 'turno ' || to_char(t.inizio AT TIME ZONE 'Europe/Rome','HH24:MI') || '–' || to_char(t.fine AT TIME ZONE 'Europe/Rome','HH24:MI')
            || ' — ' || trim(p_su_cosa) || ' (' || trim(p_note) || ') · aggiunta il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM')
            || _sala_firma(t.monitor_user_id);
  v_id := _sala_annota(t.id, p_persona_id, v_quando, v_riga);
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',t.id,'data',t.data);
END $function$;

-- Sposta la nota di sala di un turno da una persona all'altra (persona sbagliata, es. due nomi simili).
CREATE OR REPLACE FUNCTION public.monitor_sposta_nota(p_turno_id uuid, p_da_persona uuid, p_a_persona uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; s turni_monitor_seguiti%ROWTYPE; o_da osservazioni_allievo%ROWTYPE; o_a osservazioni_allievo%ROWTYPE;
        v_nome_da text; v_nome_a text; v_traccia text;
BEGIN
  t := _sala_puo_scrivere(p_turno_id);
  IF p_da_persona = p_a_persona THEN RAISE EXCEPTION 'È la stessa persona: scegli quella giusta'; END IF;
  SELECT * INTO s FROM turni_monitor_seguiti WHERE turno_id = t.id AND persona_id = p_da_persona;
  IF NOT FOUND THEN RAISE EXCEPTION 'Questa persona non risulta seguita in questo turno'; END IF;
  SELECT trim(coalesce(nome,'')||' '||coalesce(cognome,'')) INTO v_nome_da FROM persone WHERE id = p_da_persona;
  SELECT trim(coalesce(nome,'')||' '||coalesce(cognome,'')) INTO v_nome_a FROM persone WHERE id = p_a_persona;
  IF v_nome_a IS NULL THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  -- la riga di sala del giorno vale per tutti i turni di quel giorno: se la persona e' anche in un altro turno dello stesso
  -- monitor quel giorno, spostare la riga sposterebbe anche quello
  IF EXISTS (SELECT 1 FROM turni_monitor_seguiti x JOIN turni_monitor y ON y.id = x.turno_id
              WHERE x.persona_id = p_da_persona AND y.monitor_user_id = t.monitor_user_id AND y.data = t.data AND y.id <> t.id) THEN
    RAISE EXCEPTION '% è segnata anche in un altro turno dello stesso giorno: questo spostamento lo fa la segreteria a mano.', v_nome_da;
  END IF;
  v_traccia := '· spostata il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM') || ' da ' || coalesce(v_nome_da,'—') || _sala_firma(t.monitor_user_id);

  SELECT * INTO o_da FROM osservazioni_allievo
   WHERE persona_id = p_da_persona AND istruttore_user_id = t.monitor_user_id AND data = t.data AND contesto = 'sala_monitor' FOR UPDATE;
  SELECT * INTO o_a FROM osservazioni_allievo
   WHERE persona_id = p_a_persona AND istruttore_user_id = t.monitor_user_id AND data = t.data AND contesto = 'sala_monitor' FOR UPDATE;
  IF o_da.id IS NOT NULL THEN
    IF o_a.id IS NULL THEN
      UPDATE osservazioni_allievo SET persona_id = p_a_persona, note = coalesce(nullif(note,'') || E'\n','') || v_traccia, updated_at = now()
       WHERE id = o_da.id;
    ELSE
      UPDATE osservazioni_allievo SET note = coalesce(nullif(note,'') || E'\n','') || coalesce(o_da.note,'') || E'\n' || v_traccia, updated_at = now()
       WHERE id = o_a.id;
      -- il testo e' passato tutto sulla persona giusta: qui resta solo la traccia di dove e' andato
      UPDATE osservazioni_allievo SET note = '· nota spostata il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM')
             || ' su ' || v_nome_a || _sala_firma(t.monitor_user_id), updated_at = now()
       WHERE id = o_da.id;
    END IF;
  END IF;

  -- persona seguita nel turno: la riga passa alla persona giusta (se c'era gia', si tengono primo e ultimo orario)
  IF EXISTS (SELECT 1 FROM turni_monitor_seguiti WHERE turno_id = t.id AND persona_id = p_a_persona) THEN
    UPDATE turni_monitor_seguiti SET primo_alle = LEAST(primo_alle, s.primo_alle), ultimo_alle = GREATEST(ultimo_alle, s.ultimo_alle)
     WHERE turno_id = t.id AND persona_id = p_a_persona;
    DELETE FROM turni_monitor_seguiti WHERE turno_id = t.id AND persona_id = p_da_persona;
  ELSE
    UPDATE turni_monitor_seguiti SET persona_id = p_a_persona WHERE turno_id = t.id AND persona_id = p_da_persona;
  END IF;
  RETURN jsonb_build_object('ok',true,'turno_id',t.id,'da',v_nome_da,'a',v_nome_a);
END $function$;
