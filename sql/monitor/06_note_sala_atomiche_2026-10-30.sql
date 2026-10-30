-- ═══ SALA CON MONITOR: NOTA E PERSONA SEGUITA SEMPRE INSIEME, CHIUSURA AUTOMATICA CHE NON TAGLIA (consegna 30 ott 2026, punto 2) ═══
-- Caso del 28/10 (istruttore in turno di sala, nota scritta alle 20:30): la nota e' passata da SALVA OSSERVAZIONE della scheda
-- allievo (salva_osservazione) con il contesto precompilato dal tipo dell'allievo, 'monitor'. salva_osservazione rifiutava solo
-- 'sala_monitor', non 'monitor': la riga e' nata con contesto 'monitor' e senza turni_monitor_seguiti (turno "senza persone").
-- Poi il turno, senza impegno monitor in agenda, si e' chiuso da solo alle 22:00; alle 22:10 INIZIO TURNO ne ha aperto un secondo
-- che il cron ha chiuso subito con fine = inizio (la fine prevista era gia' passata): turno vuoto.
-- Questa migration:
--   (a) _sala_annota(): UNA funzione interna scrive insieme la riga di osservazioni_allievo (contesto 'sala_monitor') e la riga
--       di turni_monitor_seguiti. La usano monitor_segna, salva_osservazione e le RPC delle note retroattive (punto 3).
--       Non e' chiamabile dal portale (revoke): le RPC pubbliche controllano i permessi prima di chiamarla.
--   (b) salva_osservazione: 'monitor' e 'sala_monitor' sono la Sala con Monitor. Con il turno aperto la nota va in _sala_annota
--       (stessa riga del giorno, persona seguita nel turno); senza turno aperto: errore chiaro, niente salvataggio a meta'.
--       Tutti gli altri contesti come prima.
--   (c) monitor_segna e monitor_turno('inizio'): dopo la fine prevista della sala di oggi non aprono un turno nuovo (niente turni
--       vuoti a fine serata). Errore chiaro: la nota si aggiunge da "I miei turni".
--   (d) chiudi_turni_monitor_automatico: non chiude un turno se nell'ultimo quarto d'ora il monitor ha segnato qualcuno (aspetta il
--       giro dopo), ma la fine e' SEMPRE la fine prevista (decisione di Marco 30/10): le ore in piu' le corregge solo la segreteria.
--       Se ha segnato qualcuno dopo la fine prevista, la nota del turno lo dice.
-- Da applicare PRIMA del deploy di oggi.html v2.34. Provata con dry-run (ESITO_TEST) il 30/10, nessuna scrittura.

-- (a) ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sala_annota(p_turno_id uuid, p_persona_id uuid, p_quando timestamptz, p_riga text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; v_id uuid;
BEGIN
  SELECT * INTO t FROM turni_monitor WHERE id = p_turno_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato'; END IF;
  IF p_persona_id IS NULL THEN RAISE EXCEPTION 'Scegli la persona che hai seguito'; END IF;
  IF coalesce(trim(p_riga),'') = '' THEN RAISE EXCEPTION 'La nota e'' vuota'; END IF;
  -- la riga e' del monitor del turno e del giorno del turno (anche quando la scrive la segreteria)
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, note, created_at)
  VALUES (p_persona_id, t.monitor_user_id, t.data, 'sala_monitor', p_riga, p_quando)
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto = 'sala_monitor' DO UPDATE
    SET note = COALESCE(nullif(osservazioni_allievo.note,'') || E'\n','') || p_riga, updated_at = now()
  RETURNING id INTO v_id;
  INSERT INTO turni_monitor_seguiti (turno_id, persona_id, primo_alle, ultimo_alle)
  VALUES (p_turno_id, p_persona_id, p_quando, p_quando)
  ON CONFLICT (turno_id, persona_id) DO UPDATE
    SET primo_alle = LEAST(turni_monitor_seguiti.primo_alle, EXCLUDED.primo_alle),
        ultimo_alle = GREATEST(turni_monitor_seguiti.ultimo_alle, EXCLUDED.ultimo_alle);
  RETURN v_id;
END $function$;
REVOKE ALL ON FUNCTION public._sala_annota(uuid, uuid, timestamptz, text) FROM PUBLIC, anon, authenticated;

-- fine della sala di oggi per chi chiama: l'impegno monitor che finisce piu' tardi, altrimenti 22:00 (sabato 18:00)
CREATE OR REPLACE FUNCTION public._sala_fine_oggi()
 RETURNS timestamptz
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT GREATEST(fine_turno_prevista(CURRENT_DATE),
    (SELECT (CURRENT_DATE + MAX(i.ora_fine)) AT TIME ZONE 'Europe/Rome' FROM impegni_staff i
      WHERE i.user_id = auth.uid() AND i.data = CURRENT_DATE AND i.tipo = 'monitor' AND i.stato <> 'ritirato' AND i.ora_fine IS NOT NULL));
$function$;
REVOKE ALL ON FUNCTION public._sala_fine_oggi() FROM PUBLIC, anon, authenticated;

-- (c) monitor_segna ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_segna(p_persona_id uuid, p_su_cosa text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_turno uuid; v_id uuid; v_riga text; v_fine timestamptz;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF length(trim(coalesce(p_su_cosa,''))) < 10 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  IF length(trim(coalesce(p_note,''))) < 10 THEN RAISE EXCEPTION 'Scrivi com''è andata'; END IF;
  SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF v_turno IS NULL THEN
    v_fine := _sala_fine_oggi();
    IF now() >= v_fine THEN
      RAISE EXCEPTION 'La Sala con Monitor di oggi è finita alle %: non apro un turno nuovo. Aggiungi la nota da I miei turni, sul turno di stasera.',
        to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI');
    END IF;
    PERFORM chiudi_altri_turni_aperti();
    INSERT INTO turni_monitor (monitor_user_id) VALUES (auth.uid()) RETURNING id INTO v_turno;
  END IF;
  v_riga := to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI')||' — '||trim(p_su_cosa)||' ('||trim(p_note)||')';
  v_id := _sala_annota(v_turno, p_persona_id, now(), v_riga);
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',v_turno);
END $function$;

-- (c) monitor_turno ─────────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_turno(p_azione text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_fine timestamptz;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT id INTO v_id FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF p_azione='inizio' THEN
    IF v_id IS NOT NULL THEN RETURN jsonb_build_object('ok',true,'turno_id',v_id,'gia_aperto',true); END IF;
    v_fine := _sala_fine_oggi();
    IF now() >= v_fine THEN
      RAISE EXCEPTION 'La Sala con Monitor di oggi è finita alle %: il turno non si apre. Se devi aggiungere una nota, usa I miei turni.',
        to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI');
    END IF;
    PERFORM chiudi_altri_turni_aperti();
    INSERT INTO turni_monitor (monitor_user_id) VALUES (auth.uid()) RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok',true,'turno_id',v_id);
  ELSIF p_azione='fine' THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Nessun turno aperto oggi'; END IF;
    UPDATE turni_monitor SET fine=now(), note=COALESCE(p_note,note) WHERE id=v_id;
    RETURN jsonb_build_object('ok',true,'turno_id',v_id,'chiuso',true);
  ELSE RAISE EXCEPTION 'Azione non valida'; END IF;
END $function$;

-- (b) salva_osservazione ────────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE); v_turno uuid; v_testo text;
BEGIN
  -- 30 ott: 'monitor' e 'sala_monitor' sono la Sala con Monitor: nota e persona seguita insieme, nel turno aperto.
  -- Stesso permesso di monitor_segna (staff); viene prima del controllo "tuo allievo" perche' senza turno l'errore giusto e' sul turno.
  IF p->>'contesto' IN ('monitor','sala_monitor') THEN
    IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
    IF v_turno IS NULL THEN
      RAISE EXCEPTION 'Questa è una nota della Sala con Monitor ma il tuo turno non è aperto: non l''ho salvata. Apri il turno, oppure aggiungila da I miei turni.';
    END IF;
    v_testo := concat_ws(' · ', nullif(trim(p->>'temi_affrontati'),''), nullif(trim(p->>'trasformazione'),''), nullif(trim(p->>'note'),''),
                 nullif(trim(p->>'obiettivo'),''), nullif(trim(p->>'criticita'),''), nullif(trim(p->>'da_implementare'),''));
    IF coalesce(v_testo,'') = '' THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato e com''è andata'; END IF;
    v_id := _sala_annota(v_turno, p_persona_id, now(), to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI') || ' — ' || v_testo);
    RETURN jsonb_build_object('ok',true,'id',v_id,'data',CURRENT_DATE,'sala',true,'turno_id',v_turno);
  END IF;
  IF NOT (is_mio_allievo(p_persona_id) OR (is_staff() AND NOT is_monitor() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, obiettivo, interesse, aree_miglioramento,
    socializzazione, socializzazione_nota, fiducia, fiducia_nota, autostima, autostima_nota,
    concentrazione, concentrazione_nota, gestione_paura, gestione_paura_nota, note,
    temi_affrontati, criticita, trasformazione, da_implementare, per_allievo, visibile_allievo)
  VALUES (p_persona_id, auth.uid(), v_data, p->>'contesto', p->>'obiettivo', p->>'interesse', p->>'aree_miglioramento',
    (p->>'socializzazione')::smallint, p->>'socializzazione_nota', (p->>'fiducia')::smallint, p->>'fiducia_nota',
    (p->>'autostima')::smallint, p->>'autostima_nota', (p->>'concentrazione')::smallint, p->>'concentrazione_nota',
    (p->>'gestione_paura')::smallint, p->>'gestione_paura_nota', p->>'note',
    p->>'temi_affrontati', p->>'criticita', p->>'trasformazione', p->>'da_implementare', p->>'per_allievo',
    coalesce((p->>'visibile_allievo')::boolean, false))
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto IS DISTINCT FROM 'sala_monitor' DO UPDATE SET
    contesto=EXCLUDED.contesto, obiettivo=EXCLUDED.obiettivo, interesse=EXCLUDED.interesse, aree_miglioramento=EXCLUDED.aree_miglioramento,
    socializzazione=EXCLUDED.socializzazione, socializzazione_nota=EXCLUDED.socializzazione_nota,
    fiducia=EXCLUDED.fiducia, fiducia_nota=EXCLUDED.fiducia_nota, autostima=EXCLUDED.autostima, autostima_nota=EXCLUDED.autostima_nota,
    concentrazione=EXCLUDED.concentrazione, concentrazione_nota=EXCLUDED.concentrazione_nota,
    gestione_paura=EXCLUDED.gestione_paura, gestione_paura_nota=EXCLUDED.gestione_paura_nota, note=EXCLUDED.note,
    temi_affrontati=EXCLUDED.temi_affrontati, criticita=EXCLUDED.criticita, trasformazione=EXCLUDED.trasformazione,
    da_implementare=EXCLUDED.da_implementare, per_allievo=EXCLUDED.per_allievo, visibile_allievo=EXCLUDED.visibile_allievo,
    updated_at=now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'data',v_data);
END $function$;

-- (d) chiusura automatica ───────────────────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.chiudi_turni_monitor_automatico()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE n integer;
BEGIN
  WITH da AS (
    SELECT t.id, t.inizio, fine_turno_prevista_turno(t.id) AS prevista,
           (SELECT max(s.ultimo_alle) FROM turni_monitor_seguiti s WHERE s.turno_id = t.id) AS ultima
      FROM turni_monitor t WHERE t.fine IS NULL
  ), chiusi AS (
    UPDATE turni_monitor t
       -- 30 ott, decisione di Marco: la fine e' sempre quella prevista; le ore in piu' le corregge solo la segreteria
       SET fine = GREATEST(t.inizio, da.prevista),
           note = CASE WHEN t.note IS NULL OR t.note = '' THEN '' ELSE t.note || E'\n' END
                  || CASE WHEN da.ultima > da.prevista
                          THEN '[chiuso in automatico alla fine prevista; ultima persona segnata alle ' || to_char(da.ultima AT TIME ZONE 'Europe/Rome','HH24:MI') || ': le ore in più le corregge la segreteria]'
                          ELSE '[chiuso in automatico]' END
      FROM da
     WHERE t.id = da.id AND now() >= da.prevista
       -- 30 ott: se nell'ultimo quarto d'ora ha segnato qualcuno sta ancora lavorando: si riprova al giro dopo
       AND (da.ultima IS NULL OR da.ultima < now() - interval '15 minutes')
    RETURNING t.id, t.fine
  )
  UPDATE impegni_staff i SET presenza_fine = c.fine
    FROM chiusi c
   WHERE i.turno_monitor_id = c.id AND i.presenza_fine IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
