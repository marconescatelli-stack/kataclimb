-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/09 · REPORT DEL MONITOR QUANDO SERVE, NON SUBITO (consegna v2, 10 nov 2026)
-- MIGRAZIONE. Si applica dopo la 08/08b/08c (già applicate il 9/11), solo dopo il "vai" di Marco.
-- Prova: 09_report_quando_serve_PROVA.sql (BEGIN → questo corpo → verifiche → ROLLBACK).
--
-- Regole di Marco:
--  · i report sono liberi: chiunque dello staff, a chiunque, quando vuole, anche fuori turno; restano nella scheda;
--  · report e pagamento sono separati: si paga solo il turno dichiarato (08 invariata). Un report fuori turno resta ma non paga;
--  · il report non è legato all'orario: si scrive anche dopo; l'orario di scrittura resta visibile;
--  · un solo monitor pagato per ora; il secondo solo con DOPPIO TURNO creato da Marco o dalla segreteria con il motivo.
--
-- Cosa cambia:
--  1. monitor_aggiungi_seguiti: aggiungere una persona al turno senza report → lista "Da annotare".
--  2. monitor_segna: (a) con un turno dichiarato che copre adesso apre il turno come prima; (b) altrimenti il report va
--     sull'ultimo turno di oggi della persona, anche se chiuso (caso Bognanni 9/11: alle 22:00 il turno si chiudeva e il
--     report finiva in errore "la Sala di oggi è finita"); (c) senza nessun turno oggi il report si salva lo stesso nella
--     scheda, "fuori turno", senza turno e quindi senza compenso.
--  3. Completare dopo: monitor_completa_entro(data) = fino alle 12:00 del giorno dopo (costante leggibile, la cambia Marco).
--     _sala_puo_scrivere usa questa finestra al posto dei 7 giorni e accetta anche il turno ancora aperto
--     (il 9/11 il turno risultava "in corso" e la voce per completarlo non c'era). Dopo la finestra: solo la segreteria.
--  4. monitor_da_annotare(): le persone dei propri turni ancora da annotare, con la scadenza (per il promemoria su Oggi).
--  5. Doppio turno giustificato: impegni_staff.doppio_motivo + monitor_doppio_turno (solo creator/segreteria, motivo
--     obbligatorio). chiudi_altri_turni_aperti non chiude più il turno di chi ha un turno dichiarato che copre adesso.
--  Turni doppi aperti nello stesso istante: già chiusi dalla 08 (_monitor_apri_turno con pg_advisory_xact_lock per persona
--  e ricontrollo del turno aperto dentro il lock; è l'unica funzione che inserisce in turni_monitor). Nessuna modifica qui.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. finestra per completare un turno ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_completa_entro(p_data date)
 RETURNS timestamptz LANGUAGE sql IMMUTABLE
AS $$ SELECT ((p_data + 1) + time '12:00') AT TIME ZONE 'Europe/Rome' $$;  -- Marco 10 nov 2026: fino alle 12 del giorno dopo
COMMENT ON FUNCTION public.monitor_completa_entro(date) IS
  'Fino a quando il monitor completa da solo il suo turno (persone e report): le 12:00 del giorno dopo. Poi solo la segreteria.';

-- ── 1. chi può scrivere su un turno (già usata da monitor_nota_turno e monitor_sposta_nota) ─────
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
  IF is_segreteria_piena() OR is_segreteria() THEN RETURN t; END IF;
  IF t.monitor_user_id <> auth.uid() THEN RAISE EXCEPTION 'Puoi completare solo i tuoi turni. Per gli altri chiedi alla segreteria.'; END IF;
  -- 10 nov 2026: niente più 7 giorni né "turno ancora aperto": si completa fino alle 12 del giorno dopo
  IF now() > monitor_completa_entro(t.data) THEN
    RAISE EXCEPTION 'Il turno del % si poteva completare fino alle 12:00 del giorno dopo: adesso lo sistema la segreteria.', to_char(t.data,'DD/MM');
  END IF;
  RETURN t;
END $function$;

-- il turno ancora aperto non ha la fine: la riga lo dice
CREATE OR REPLACE FUNCTION public.monitor_nota_turno(p_turno_id uuid, p_persona_id uuid, p_su_cosa text, p_note text, p_per_allievo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; v_id uuid; v_riga text; v_quando timestamptz; v_pa text; v_scritto boolean := false;
BEGIN
  t := _sala_puo_scrivere(p_turno_id);
  IF length(trim(coalesce(p_su_cosa,''))) < 10 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  IF length(trim(coalesce(p_note,''))) < 10 THEN RAISE EXCEPTION 'Scrivi com''è andata'; END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  v_quando := t.inizio;
  v_riga := 'turno ' || to_char(t.inizio AT TIME ZONE 'Europe/Rome','HH24:MI') || '–' || coalesce(to_char(t.fine AT TIME ZONE 'Europe/Rome','HH24:MI'), 'in corso')
            || ' — ' || trim(p_su_cosa) || ' (' || trim(p_note) || ') · scritta il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM "alle" HH24:MI')
            || _sala_firma(t.monitor_user_id);
  v_id := _sala_annota(t.id, p_persona_id, v_quando, v_riga);
  v_pa := nullif(trim(coalesce(p_per_allievo,'')),'');
  IF v_pa IS NOT NULL AND t.monitor_user_id = auth.uid() THEN
    PERFORM quadro_aggiungi(p_persona_id, 'sala_monitor', jsonb_build_array(jsonb_build_object('tipo','per_te','testo',v_pa)));
    v_scritto := true;
  END IF;
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',t.id,'data',t.data,'per_allievo',v_scritto);
END $function$;

-- ── 2. aggiungere senza report: "Da annotare" ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_aggiungi_seguiti(p_persona_ids uuid[], p_turno_id uuid DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_turno uuid; t turni_monitor%ROWTYPE; pid uuid; n int := 0; k int;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF p_persona_ids IS NULL OR cardinality(p_persona_ids) = 0 THEN RAISE EXCEPTION 'Scegli almeno una persona'; END IF;
  IF p_turno_id IS NOT NULL THEN
    t := _sala_puo_scrivere(p_turno_id); v_turno := t.id;
  ELSE
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id = auth.uid() AND data = CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
    IF v_turno IS NULL THEN   -- turno di oggi già chiuso (alle 22, o a fine del mio turno dichiarato): va lì
      SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id = auth.uid() AND data = CURRENT_DATE ORDER BY inizio DESC LIMIT 1;
    END IF;
    IF v_turno IS NULL THEN
      RAISE EXCEPTION 'Non sei in turno adesso: la persona si aggiunge a un turno aperto. Il report puoi scriverlo lo stesso nella sua scheda.';
    END IF;
  END IF;
  FOREACH pid IN ARRAY p_persona_ids LOOP
    IF NOT EXISTS (SELECT 1 FROM persone WHERE id = pid) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
    INSERT INTO turni_monitor_seguiti (turno_id, persona_id, primo_alle, ultimo_alle)
    VALUES (v_turno, pid, now(), now()) ON CONFLICT (turno_id, persona_id) DO NOTHING;
    GET DIAGNOSTICS k = ROW_COUNT; n := n + k;
  END LOOP;
  RETURN jsonb_build_object('ok', true, 'turno_id', v_turno, 'aggiunte', n);
END $$;

-- ── 3. il report: a sala finita sul turno di stasera, senza turno "fuori turno" ─────────────────
CREATE OR REPLACE FUNCTION public.monitor_segna(p_persona_id uuid, p_su_cosa text, p_note text DEFAULT NULL::text, p_per_allievo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_turno uuid; v_id uuid; v_riga text; v_pa text; v_fuori boolean := false;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF length(trim(coalesce(p_su_cosa,''))) < 10 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  IF length(trim(coalesce(p_note,''))) < 10 THEN RAISE EXCEPTION 'Scrivi com''è andata'; END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  -- turno dichiarato che copre adesso e sala non finita: il report apre (o riapre) il turno, vale come presenza
  IF v_turno IS NULL AND now() < _sala_fine_oggi()
     AND (CURRENT_DATE < monitor_regola_dal() OR (_monitor_impegno_adesso(auth.uid())).id IS NOT NULL) THEN
    v_turno := _monitor_apri_turno();
  END IF;
  -- 10 nov: altrimenti va sul mio ultimo turno di oggi, anche se già chiuso (la chiusura delle 22 non fa perdere niente;
  -- Claudia 19–20 che scrive alle 20:30 lo scrive sul suo turno)
  IF v_turno IS NULL THEN
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE ORDER BY inizio DESC LIMIT 1;
  END IF;
  -- nessun turno oggi: report libero, resta nella scheda, nessun compenso
  v_fuori := v_turno IS NULL;
  v_riga := to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI')||' — '||trim(p_su_cosa)||' ('||trim(p_note)||')';
  IF v_fuori THEN
    INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, note, created_at)
    VALUES (p_persona_id, auth.uid(), CURRENT_DATE, 'sala_monitor', v_riga || ' · fuori turno', now())
    ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto = 'sala_monitor' DO UPDATE
      SET note = COALESCE(nullif(osservazioni_allievo.note,'') || E'\n','') || v_riga || ' · fuori turno', updated_at = now()
    RETURNING id INTO v_id;
  ELSE
    v_id := _sala_annota(v_turno, p_persona_id, now(), v_riga);
  END IF;
  v_pa := nullif(trim(coalesce(p_per_allievo,'')),'');
  IF v_pa IS NOT NULL THEN
    PERFORM quadro_aggiungi(p_persona_id, 'sala_monitor', jsonb_build_array(jsonb_build_object('tipo','per_te','testo',v_pa)));
  END IF;
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',v_turno,'fuori_turno',v_fuori,'per_allievo',v_pa IS NOT NULL);
END $function$;

-- ── 4. promemoria: chi resta da annotare nei miei turni, finché si può ──────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_da_annotare()
 RETURNS TABLE(turno_id uuid, data date, inizio timestamptz, fine timestamptz, persona_id uuid, nome text, cognome text, foto_path text, entro timestamptz)
 LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT t.id, t.data, t.inizio, t.fine, s.persona_id, pe.nome, pe.cognome, pe.foto_riconoscimento_path, monitor_completa_entro(t.data)
    FROM turni_monitor t
    JOIN turni_monitor_seguiti s ON s.turno_id = t.id
    JOIN persone pe ON pe.id = s.persona_id
   WHERE auth.uid() IS NOT NULL AND is_staff() AND t.monitor_user_id = auth.uid()
     AND t.data >= CURRENT_DATE - 1 AND now() <= monitor_completa_entro(t.data)
     AND NOT EXISTS (SELECT 1 FROM osservazioni_allievo o
                      WHERE o.persona_id = s.persona_id AND o.istruttore_user_id = t.monitor_user_id
                        AND o.data = t.data AND o.contesto = 'sala_monitor' AND coalesce(o.note,'') <> '')
   ORDER BY t.inizio, s.primo_alle;
$$;

-- ── 5. elenco e dettaglio dei turni: "modificabile" con la finestra nuova, anche se ancora aperto ─
CREATE OR REPLACE FUNCTION public.monitor_turni_elenco(p_giorni integer DEFAULT 30, p_tutti boolean DEFAULT false)
 RETURNS TABLE(turno_id uuid, monitor_user_id uuid, monitor text, data date, inizio timestamp with time zone, fine timestamp with time zone, ore numeric, persone integer, note_turno text, modificabile boolean)
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
         (v_seg OR (t.monitor_user_id = auth.uid() AND now() <= monitor_completa_entro(t.data)))
    FROM turni_monitor t LEFT JOIN profiles pr ON pr.user_id = t.monitor_user_id
   WHERE t.data >= CURRENT_DATE - GREATEST(1, LEAST(coalesce(p_giorni,30), 366))
     AND (t.monitor_user_id = auth.uid() OR (p_tutti AND v_seg))
   ORDER BY t.data DESC, t.inizio DESC;
END $function$;

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
       'modificabile',(v_seg OR (t.monitor_user_id = auth.uid() AND now() <= monitor_completa_entro(t.data))),
       'entro', monitor_completa_entro(t.data)),
    'seguiti', (SELECT coalesce(jsonb_agg(jsonb_build_object('persona_id',s.persona_id,
                   'nome',trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),'primo_alle',s.primo_alle,
                   'note',o.note, 'scritta_alle', o.updated_at)
                 ORDER BY s.primo_alle),'[]'::jsonb)
                FROM turni_monitor_seguiti s JOIN persone pe ON pe.id = s.persona_id
                LEFT JOIN osservazioni_allievo o ON o.persona_id = s.persona_id AND o.istruttore_user_id = t.monitor_user_id
                     AND o.data = t.data AND o.contesto = 'sala_monitor'
               WHERE s.turno_id = t.id));
END $function$;

-- ── 6. doppio turno giustificato (solo Marco e la segreteria, con il motivo) ────────────────────
ALTER TABLE public.impegni_staff ADD COLUMN IF NOT EXISTS doppio_motivo text;
COMMENT ON COLUMN public.impegni_staff.doppio_motivo IS
  'Turno monitor in più nella stessa ora di un altro, creato da creator/segreteria con il motivo (monitor_doppio_turno). Pagato come ogni turno dichiarato.';

CREATE OR REPLACE FUNCTION public.monitor_doppio_turno(p_data date, p_ora_inizio time, p_ora_fine time, p_user_id uuid, p_motivo text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_ini time; v_fin time; v_id uuid; v_mot text := nullif(trim(coalesce(p_motivo,'')),'');
BEGIN
  IF auth.uid() IS NULL OR NOT is_segreteria() THEN RAISE EXCEPTION 'Il doppio turno lo crea solo Marco o la segreteria.'; END IF;
  IF v_mot IS NULL OR length(v_mot) < 5 THEN RAISE EXCEPTION 'Scrivi il motivo del doppio turno (per esempio "sala piena, serve un secondo monitor").'; END IF;
  IF p_user_id IS NULL OR NOT EXISTS (SELECT 1 FROM profile_data WHERE user_id = p_user_id AND staff_role IS NOT NULL) THEN
    RAISE EXCEPTION 'Scegli una persona dello staff.';
  END IF;
  IF p_data IS NULL OR p_ora_inizio IS NULL OR p_ora_fine IS NULL THEN RAISE EXCEPTION 'Scegli il giorno e le ore.'; END IF;
  IF p_data < CURRENT_DATE THEN RAISE EXCEPTION 'Il doppio turno si crea per oggi o per i prossimi giorni.'; END IF;
  SELECT f.ini, f.fin INTO v_ini, v_fin FROM monitor_fascia(p_data) f;
  IF v_ini IS NULL THEN RAISE EXCEPTION 'La domenica la Sala con Monitor è chiusa.'; END IF;
  IF date_part('minute', p_ora_inizio) <> 0 OR date_part('minute', p_ora_fine) <> 0 OR p_ora_fine <= p_ora_inizio
     OR p_ora_inizio < v_ini OR p_ora_fine > v_fin THEN
    RAISE EXCEPTION 'Ore intere dentro la fascia (dalle % alle %).', to_char(v_ini,'HH24:MI'), to_char(v_fin,'HH24:MI');
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('monitor_dichiara_' || p_data::text));
  IF NOT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente')
                   AND i.user_id <> p_user_id AND i.ora_inizio < p_ora_fine AND i.ora_fine > p_ora_inizio) THEN
    RAISE EXCEPTION 'In quelle ore non c''è un altro monitor: non serve il doppio turno, basta dichiarare il turno normale.';
  END IF;
  IF EXISTS (SELECT 1 FROM impegni_staff i WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente')
               AND i.user_id = p_user_id AND i.ora_inizio < p_ora_fine AND i.ora_fine > p_ora_inizio) THEN
    RAISE EXCEPTION '% ha già un turno in quelle ore.', _nome_staff(p_user_id);
  END IF;
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, doppio_motivo)
  VALUES (p_user_id, 'monitor', NULL, p_data, p_ora_inizio, p_ora_fine, 'monitor', 'previsto', auth.uid(),
          'doppio turno creato da ' || _nome_staff(auth.uid()) || ' il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI') || ': ' || v_mot, v_mot)
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = 'previsto', ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, doppio_motivo = excluded.doppio_motivo,
                presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION '% ha già un turno che inizia a quell''ora.', _nome_staff(p_user_id); END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

-- all'apertura non si chiude il turno di chi ha un turno dichiarato che copre adesso (doppio turno, o passaggio 19–20/20–22
-- aperto nei 15 minuti di anticipo: il turno di chi esce lo chiude la chiusura automatica alla sua ora)
CREATE OR REPLACE FUNCTION public.chiudi_altri_turni_aperti()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_chi text; v_fine timestamptz := now(); n integer;
BEGIN
  IF CURRENT_DATE >= monitor_regola_dal() AND (_monitor_impegno_adesso(auth.uid())).id IS NULL THEN
    RAISE EXCEPTION 'Chiudi il turno di un collega solo quando inizia il tuo turno dichiarato (per esempio lui 19–20, tu 20–22).';
  END IF;
  SELECT COALESCE(NULLIF(trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),''),'collega') INTO v_chi
    FROM profile_data pd LEFT JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = auth.uid();
  WITH chiusi AS (
    UPDATE turni_monitor t
       SET fine = v_fine,
           note = CASE WHEN t.note IS NULL OR t.note = '' THEN '' ELSE t.note || E'\n' END
                  || '[cambio: chiuso da ' || COALESCE(v_chi,'collega') || ' alle ' || to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI') || ']'
     WHERE t.fine IS NULL AND t.data = CURRENT_DATE AND t.monitor_user_id <> auth.uid()
       AND NOT (CURRENT_DATE >= monitor_regola_dal() AND EXISTS (
             SELECT 1 FROM impegni_staff i WHERE i.user_id = t.monitor_user_id AND i.tipo = 'monitor' AND i.data = CURRENT_DATE
                AND i.stato IN ('previsto','presente')
                AND now() >= _ts_roma(i.data, i.ora_inizio) AND now() < _ts_roma(i.data, i.ora_fine)))
    RETURNING t.id
  )
  UPDATE impegni_staff i SET presenza_fine = v_fine FROM chiusi c
   WHERE i.turno_monitor_id = c.id AND i.presenza_fine IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

-- ── 7. permessi ──────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.monitor_completa_entro(date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_aggiungi_seguiti(uuid[], uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_da_annotare() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_doppio_turno(date, time, time, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_completa_entro(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_aggiungi_seguiti(uuid[], uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_da_annotare() TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_doppio_turno(date, time, time, uuid, text) TO authenticated;
