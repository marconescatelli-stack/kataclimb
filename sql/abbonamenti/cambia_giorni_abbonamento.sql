-- cambia_giorni_abbonamento — definizione letta dal DB di produzione il 16/10/2026 (pg_get_functiondef).
-- Guardia: is_segreteria_piena() (creator, admin, segreteria). Usata da portale.html v3.132 (📅 Cambia giorni).
-- Grant: EXECUTE a authenticated, postgres, service_role.

CREATE OR REPLACE FUNCTION public.cambia_giorni_abbonamento(p_iscrizione_id uuid, p_slot_ids uuid[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_isc iscrizioni_minori; t abbonamenti_tipi;
  v_sid uuid; v_slot record; v_occ int;
  v_vecchi uuid[]; v_nuovi uuid[];
  v_txt_vecchi text; v_txt_nuovi text; v_riga text;
  g text[] := ARRAY['lun','mar','mer','gio','ven','sab','dom'];
BEGIN
  IF NOT is_segreteria_piena() THEN RAISE EXCEPTION 'Permesso negato: solo segreteria'; END IF;

  SELECT * INTO v_isc FROM iscrizioni_minori WHERE id = p_iscrizione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento % non trovato', p_iscrizione_id; END IF;
  IF v_isc.status <> 'attiva' THEN RAISE EXCEPTION 'L''abbonamento non è attivo: non si possono cambiare i giorni'; END IF;

  SELECT * INTO t FROM abbonamenti_tipi WHERE tipo = v_isc.tipo_abbonamento;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento senza tipo: sistemalo con "Abbonamento o corso"'; END IF;
  IF coalesce(array_length(t.slot_ammessi,1),0) = 0 THEN RAISE EXCEPTION '% non ha giorni da cambiare', t.label; END IF;

  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO v_nuovi FROM unnest(p_slot_ids) x WHERE x IS NOT NULL;
  IF coalesce(array_length(v_nuovi,1),0) = 0 THEN RAISE EXCEPTION 'Scegli almeno un giorno'; END IF;

  SELECT coalesce(array_agg(slot_id), '{}') INTO v_vecchi FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;

  IF v_nuovi @> v_vecchi AND v_vecchi @> v_nuovi THEN RAISE EXCEPTION 'I giorni sono già questi: nessun cambio'; END IF;
  IF coalesce(array_length(v_vecchi,1),0) > 0 AND array_length(v_nuovi,1) <> array_length(v_vecchi,1) THEN
    RAISE EXCEPTION 'Da % a % giorni a settimana cambia il prezzo: usa "Abbonamento o corso"',
      array_length(v_vecchi,1), array_length(v_nuovi,1);
  END IF;

  FOREACH v_sid IN ARRAY v_nuovi LOOP
    SELECT id, tipo_corso, fascia, status, capienza_max, giorno_settimana, ora_inizio INTO v_slot
      FROM corsi_attivi_settimanali WHERE id = v_sid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Giorno/slot % non trovato', v_sid; END IF;
    IF v_slot.status <> 'attivo' THEN RAISE EXCEPTION 'Il giorno % ore % non è attivo', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'); END IF;
    IF NOT (v_slot.tipo_corso||'/'||v_slot.fascia = ANY(t.slot_ammessi) OR v_slot.tipo_corso||'/*' = ANY(t.slot_ammessi)) THEN
      RAISE EXCEPTION 'Il giorno % ore % non fa parte di %', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'), t.label;
    END IF;
    IF v_slot.capienza_max IS NOT NULL AND NOT (v_sid = ANY(v_vecchi)) THEN
      SELECT count(*) INTO v_occ FROM iscrizioni_minori_slot ims JOIN iscrizioni_minori im ON im.id = ims.iscrizione_id
       WHERE ims.slot_id = v_sid AND im.status = 'attiva' AND im.id <> p_iscrizione_id;
      IF v_occ >= v_slot.capienza_max THEN
        RAISE EXCEPTION 'Pieno (%/%): % ore %', v_occ, v_slot.capienza_max, g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI');
      END IF;
    END IF;
  END LOOP;

  SELECT coalesce(string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio), 'nessuno')
    INTO v_txt_vecchi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_vecchi);
  SELECT string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio)
    INTO v_txt_nuovi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_nuovi);

  -- tipo fermo PRIMA di toccare gli slot (il trigger su INSERT ricalcola solo se tipo_da_slot)
  UPDATE iscrizioni_minori SET tipo_da_slot = false WHERE id = p_iscrizione_id;

  DELETE FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;
  INSERT INTO iscrizioni_minori_slot (iscrizione_id, slot_id) SELECT p_iscrizione_id, unnest(v_nuovi);

  v_riga := '['||to_char(CURRENT_DATE,'DD/MM/YYYY')||' giorni cambiati: '||v_txt_vecchi||' → '||v_txt_nuovi
            ||CASE WHEN nullif(trim(p_note),'') IS NOT NULL THEN ' · '||trim(p_note) ELSE '' END||']';
  UPDATE iscrizioni_minori SET note = concat_ws(E'\n', note, v_riga) WHERE id = p_iscrizione_id;

  RETURN jsonb_build_object('success', true, 'iscrizione_id', p_iscrizione_id, 'tipo', t.tipo, 'label', t.label,
    'prima', v_txt_vecchi, 'dopo', v_txt_nuovi, 'scadenza', v_isc.data_fine);
END $function$
;
