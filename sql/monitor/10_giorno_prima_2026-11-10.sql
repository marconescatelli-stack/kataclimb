-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/10 · TURNI MONITOR: GIORNO PRIMA, GIORNO STESSO, A POSTERIORI E AVVISI SCOPERTI (consegna v1, 10 nov 2026)
-- MIGRAZIONE. Si applica dopo la 08/08b/08c/09 (già applicate), dopo il deploy del worker notifiche v3.2,
-- solo dopo il "vai" di Marco. Prova: 10_giorno_prima_PROVA.sql (BEGIN → questo corpo → verifiche → ROLLBACK).
--
-- Regole di Marco (10 nov 2026):
--  1. turno DICHIARATO = segnato entro il giorno prima (fino alle 23:59 ora di Roma). È il buon uso.
--  2. GIORNO STESSO: se l'ora è libera vale e si paga normalmente, ma resta marcato "segnato il giorno stesso".
--     Se l'ora è di un collega, il giorno stesso si passa solo dalla sostituzione (proponi / accetta).
--  3. A POSTERIORI: chi era in sala senza essersi segnato si mette nel turno da solo, dopo, senza scadenza.
--     Resta "da rivedere dalla segreteria" e non si paga finché la segreteria non lo conferma (o lo respinge, con nota).
--     Se l'ora era già di un altro, da solo non si segna: decide la segreteria.
--  4. Avviso ogni giorno alle 10 delle ore monitor scoperte di domani e dopodomani (domenica esclusa).
--  5. Restano le regole di prima: ore intere, fascia 19–22 (sabato 14–18, domenica chiuso), un monitor per ora
--     salvo doppio turno, report liberi e separati dal pagamento.
--
-- Cosa cambia:
--  0. impegni_staff: origine ('dichiarato' | 'giorno_stesso' | 'a_posteriori', solo per i turni monitor), revisione_*
--     (esito, chi, quando, nota) e lo stato nuovo 'da_confermare'. Turni esistenti: dal 9/11 origine calcolata da
--     created_at (chi ha preso un turno con un cambio accettato eredita l'origine del turno ceduto); prima del 9/11 vuota.
--  1. _monitor_origine(data, ora_inizio, quando): la regola in un posto solo.
--  2. monitor_dichiara_turno: niente più blocco sui turni iniziati. Iniziato = a_posteriori, stato 'da_confermare',
--     legato a un turno della Sala (quello della persona di quel giorno o uno nuovo, chiuso) perché il conteggio lo veda;
--     i report già scritti quel giorno (anche "fuori turno") diventano persone seguite di quel turno. Avviso
--     turno.a_posteriori alla segreteria. Se lo segna Marco o la segreteria, è già confermato.
--     Giorni prima del 9/11: si accetta solo se quel giorno la persona non ha già un turno (si contava col sistema di prima)
--     e se nessun altro era in sala in quelle ore.
--  3. monitor_rivedi_turno(impegno, conferma, nota): conferma o respinge (nota obbligatoria). Respinto = stato 'ritirato'
--     con la nota, 0 €, mai cancellato; da solo non si ripropone.
--  4. Compensi: v_compenso_turni_monitor conta solo le ore previsto/presente (come prima): le ore 'da_confermare' restano
--     fuori finché la segreteria non conferma. Colonne nuove in fondo: in_revisione, ore_da_rivedere; regola 'da_rivedere'.
--     Un turno prima del 9/11 nato a posteriori segue la regola nuova (non lo storico). get_compenso_monitor di conseguenza.
--  5. Completare un turno da rivedere: il monitor può aggiungere persone e report finché è da rivedere
--     (_sala_puo_scrivere, monitor_turni_elenco, monitor_turno_dettaglio), anche oltre le 12 del giorno dopo.
--  6. monitor_rispondi_cambio e monitor_doppio_turno scrivono l'origine.
--  7. Avvisi (worker v3.2): turno.a_posteriori (subito, quiete 22–08) e turni.scoperti (blocco 11 nel cron, tra le 10 e
--     le 12 ora di Roma, una volta al giorno con dedup_key; domeniche e giorni_chiusi esclusi). canale push, user_id NULL.
--  _monitor_impegno_adesso / apertura turno: nessun cambiamento (giorno_stesso si apre come prima; 'da_confermare' no).
--  12. REPORT SEMPRE LEGGIBILI (Marco, 10 nov): i report contano a prescindere da turni e pagamento. Le note di sala restano
--     una riga per persona, istruttore e giorno (l'unicità la usano turno, Da annotare, sposta nota), ma ogni report
--     accodato diventa UNA riga che comincia con l'ora in cui è scritto (_sala_riga): gli a capo dentro il testo non
--     spezzano più il report in righe senza ora. monitor_segna (anche fuori turno), salva_osservazione, monitor_nota_turno
--     passano tutti da qui. Lo storico già scritto non si tocca. Nessun report dipende dallo stato del turno.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. colonne, stato nuovo ─────────────────────────────────────────────────────────────────────
ALTER TABLE public.impegni_staff
  ADD COLUMN IF NOT EXISTS origine         text,
  ADD COLUMN IF NOT EXISTS revisione_esito text,
  ADD COLUMN IF NOT EXISTS revisione_da    uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS revisione_il    timestamptz,
  ADD COLUMN IF NOT EXISTS revisione_nota  text;
ALTER TABLE public.impegni_staff DROP CONSTRAINT IF EXISTS impegni_staff_origine_chk;
ALTER TABLE public.impegni_staff ADD CONSTRAINT impegni_staff_origine_chk
  CHECK (origine IS NULL OR (tipo = 'monitor' AND origine IN ('dichiarato','giorno_stesso','a_posteriori')));
ALTER TABLE public.impegni_staff DROP CONSTRAINT IF EXISTS impegni_staff_revisione_chk;
ALTER TABLE public.impegni_staff ADD CONSTRAINT impegni_staff_revisione_chk
  CHECK (revisione_esito IS NULL OR revisione_esito IN ('confermato','respinto'));
ALTER TABLE public.impegni_staff DROP CONSTRAINT impegni_staff_stato_check;
ALTER TABLE public.impegni_staff ADD CONSTRAINT impegni_staff_stato_check
  CHECK (stato IN ('previsto','presente','assente','ritirato','non_svolta','da_confermare'));
COMMENT ON COLUMN public.impegni_staff.origine IS
  'Turni monitor (dal 9/11/2026): dichiarato = segnato entro il giorno prima; giorno_stesso = segnato il giorno stesso prima dell''inizio (vale, ma non è buon uso); a_posteriori = segnato a turno iniziato o passato (da rivedere dalla segreteria).';
COMMENT ON COLUMN public.impegni_staff.revisione_esito IS 'Turno a posteriori: confermato o respinto da Marco o dalla segreteria (revisione_da, revisione_il, revisione_nota).';

-- ── 1. la regola dell'origine ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._monitor_origine(p_data date, p_ora_inizio time, p_quando timestamptz DEFAULT now())
 RETURNS text LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT CASE WHEN _ts_roma(p_data, p_ora_inizio) <= p_quando                 THEN 'a_posteriori'
              WHEN (p_quando AT TIME ZONE 'Europe/Rome')::date < p_data        THEN 'dichiarato'
              ELSE 'giorno_stesso' END
$$;

-- turni esistenti: dal 9/11 da created_at; chi ha preso un turno con un cambio accettato eredita l'origine del turno ceduto
UPDATE public.impegni_staff SET origine = _monitor_origine(data, ora_inizio, created_at)
 WHERE tipo = 'monitor' AND data >= monitor_regola_dal() AND origine IS NULL;
UPDATE public.impegni_staff n SET origine = o.origine
  FROM public.cambi_turno_monitor c JOIN public.impegni_staff o ON o.id = c.impegno_id
 WHERE n.id = c.nuovo_impegno_id AND c.stato = 'accettata' AND o.origine IS NOT NULL;
UPDATE public.impegni_staff SET origine = 'giorno_stesso'      -- doppio turno creato dalla segreteria a sala iniziata
 WHERE tipo = 'monitor' AND doppio_motivo IS NOT NULL AND origine = 'a_posteriori';

-- ── 2. un turno è da rivedere? (serve a completarlo anche oltre le 12 del giorno dopo) ─────────
CREATE OR REPLACE FUNCTION public.monitor_turno_in_revisione(p_turno_id uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = p_turno_id AND i.tipo = 'monitor' AND i.stato = 'da_confermare') $$;

-- ── 3. avviso turno.a_posteriori (worker v3.2) ──────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._monitor_avvisa_a_posteriori(p_impegno_id uuid)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE i impegni_staff; v_ora int; v_oggi date := (now() AT TIME ZONE 'Europe/Rome')::date; v_quando timestamptz;
BEGIN
  SELECT * INTO i FROM impegni_staff WHERE id = p_impegno_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  v_ora := date_part('hour', now() AT TIME ZONE 'Europe/Rome')::int;   -- quiete 22–08, come i lead
  IF v_ora >= 22 THEN    v_quando := (v_oggi + 1 + time '08:00') AT TIME ZONE 'Europe/Rome';
  ELSIF v_ora < 8 THEN   v_quando := (v_oggi + time '08:00') AT TIME ZONE 'Europe/Rome';
  ELSE                   v_quando := now();
  END IF;
  RETURN registra_evento_notifica('turno.a_posteriori', NULL, 'push',
    jsonb_build_object('impegno_id', i.id, 'chi', _nome_staff(i.user_id), 'data', to_char(i.data, 'YYYY-MM-DD'),
                       'ora_inizio', to_char(i.ora_inizio, 'HH24:MI'), 'ora_fine', to_char(i.ora_fine, 'HH24:MI')),
    v_quando, 'turno-a-posteriori-' || i.id);
END $function$;

-- ── 4. lega il turno a posteriori a un turno della Sala (perché conteggio e report lo vedano) ──
--    Un turno chiuso, nel passato, per una persona sola: lo stesso blocco per persona di _monitor_apri_turno.
--    (_monitor_apri_turno resta l'unica porta per APRIRE un turno adesso; qui si registra solo un turno già passato.)
CREATE OR REPLACE FUNCTION public._monitor_lega_turno(p_impegno_id uuid)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE i impegni_staff; v_turno uuid; v_ini timestamptz; v_fin timestamptz;
BEGIN
  SELECT * INTO i FROM impegni_staff WHERE id = p_impegno_id FOR UPDATE;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('monitor_apri_' || i.user_id::text));
  v_ini := _ts_roma(i.data, i.ora_inizio);
  v_fin := LEAST(_ts_roma(i.data, i.ora_fine), now());
  -- un turno della persona quel giorno: prima quello che tocca le ore, il più lungo; altrimenti l'ultimo
  SELECT t.id INTO v_turno FROM turni_monitor t
   WHERE t.monitor_user_id = i.user_id AND t.data = i.data
   ORDER BY (t.inizio < _ts_roma(i.data, i.ora_fine) AND coalesce(t.fine, now()) > v_ini) DESC,
            (coalesce(t.fine, now()) - t.inizio) DESC, t.inizio DESC
   LIMIT 1;
  IF v_turno IS NULL THEN
    INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine, note)
    VALUES (i.user_id, i.data, v_ini, GREATEST(v_fin, v_ini),
            '[segnato a posteriori il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI') || ']')
    RETURNING id INTO v_turno;
  END IF;
  -- i report già scritti quel giorno (anche "fuori turno") contano come persone seguite in questo turno
  INSERT INTO turni_monitor_seguiti (turno_id, persona_id, primo_alle, ultimo_alle)
  SELECT v_turno, o.persona_id, o.created_at, coalesce(o.updated_at, o.created_at)
    FROM osservazioni_allievo o
   WHERE o.istruttore_user_id = i.user_id AND o.data = i.data AND o.contesto = 'sala_monitor'
  ON CONFLICT (turno_id, persona_id) DO NOTHING;
  UPDATE impegni_staff SET turno_monitor_id = v_turno, updated_at = now() WHERE id = i.id;
  RETURN v_turno;
END $function$;

-- ── 5. dichiarare: entro il giorno prima, il giorno stesso, a posteriori ────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_dichiara_turno(p_data date, p_ora_inizio time without time zone, p_ora_fine time without time zone, p_user_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_user uuid := coalesce(p_user_id, auth.uid()); v_ini time; v_fin time; v_id uuid; v_chi text; v_note text;
        v_seg boolean; v_origine text; v_stato text; v_turno uuid;
        v_quando text := to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI');
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  v_seg := is_segreteria();
  IF v_user IS DISTINCT FROM auth.uid() AND NOT v_seg THEN
    RAISE EXCEPTION 'Il turno monitor lo dichiari tu, per te. Per conto di un collega lo fa solo la segreteria, nei casi eccezionali.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profile_data WHERE user_id = v_user AND staff_role IS NOT NULL) THEN
    RAISE EXCEPTION 'Questa persona non è nello staff.';
  END IF;
  IF p_data IS NULL OR p_ora_inizio IS NULL OR p_ora_fine IS NULL THEN RAISE EXCEPTION 'Scegli il giorno e le ore del turno.'; END IF;
  SELECT f.ini, f.fin INTO v_ini, v_fin FROM monitor_fascia(p_data) f;
  IF v_ini IS NULL THEN RAISE EXCEPTION 'La domenica la Sala con Monitor è chiusa: scegli un giorno da lunedì a sabato.'; END IF;
  IF date_part('minute', p_ora_inizio) <> 0 OR date_part('second', p_ora_inizio) <> 0
     OR date_part('minute', p_ora_fine) <> 0 OR date_part('second', p_ora_fine) <> 0 THEN
    RAISE EXCEPTION 'Il turno si dichiara a ore intere (per esempio dalle 19:00 alle 21:00).';
  END IF;
  IF p_ora_fine <= p_ora_inizio THEN RAISE EXCEPTION 'L''ora di fine viene dopo quella di inizio.'; END IF;
  IF p_ora_inizio < v_ini OR p_ora_fine > v_fin THEN
    RAISE EXCEPTION 'Quel giorno la Sala con Monitor va dalle % alle %: scegli ore dentro questa fascia.',
      to_char(v_ini,'HH24:MI'), to_char(v_fin,'HH24:MI');
  END IF;
  v_origine := _monitor_origine(p_data, p_ora_inizio);    -- 10/11: niente più blocco sui turni iniziati
  IF v_origine <> 'a_posteriori' AND staff_indisponibile(v_user, p_data, p_ora_inizio, p_ora_fine) THEN
    RAISE EXCEPTION 'Il %/% è segnato "non ci sono": se adesso puoi esserci, prima togli il "non ci sono".',
      extract(day FROM p_data)::int, extract(month FROM p_data)::int;
  END IF;
  IF v_origine = 'a_posteriori' AND NOT v_seg AND EXISTS (
       SELECT 1 FROM impegni_staff i WHERE i.user_id = v_user AND i.tipo = 'monitor' AND i.data = p_data
          AND i.revisione_esito = 'respinto' AND i.ora_inizio < p_ora_fine AND i.ora_fine > p_ora_inizio) THEN
    RAISE EXCEPTION 'La segreteria ha già respinto un tuo turno in quelle ore: se c''è un errore, parlane con lei.';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('monitor_dichiara_' || p_data::text));
  -- un monitor per ora: vale anche a posteriori (le ore da rivedere di un altro contano come prese)
  SELECT string_agg(_nome_staff(i.user_id) || ' ' || to_char(i.ora_inizio,'HH24:MI') || '–' || to_char(i.ora_fine,'HH24:MI'), ', ' ORDER BY i.ora_inizio)
    INTO v_chi
    FROM impegni_staff i
   WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente','da_confermare')
     AND i.ora_inizio < p_ora_fine AND i.ora_fine > p_ora_inizio;
  -- prima del 9/11 non c'erano turni dichiarati: conta chi era in sala davvero (turni_monitor)
  IF v_chi IS NULL AND v_origine = 'a_posteriori' AND p_data < monitor_regola_dal() THEN
    IF EXISTS (SELECT 1 FROM turni_monitor t WHERE t.monitor_user_id = v_user AND t.data = p_data
                  AND NOT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = t.id AND i.origine = 'a_posteriori')) THEN
      RAISE EXCEPTION 'Il %/% hai già un turno registrato: quel giorno si conta col sistema di prima del %. Per correggerlo chiedi alla segreteria.',
        extract(day FROM p_data)::int, extract(month FROM p_data)::int, to_char(monitor_regola_dal(),'DD/MM');
    END IF;
    SELECT string_agg(DISTINCT _nome_staff(t.monitor_user_id), ', ') INTO v_chi
      FROM turni_monitor t
     WHERE t.monitor_user_id <> v_user AND t.data = p_data AND coalesce(t.fine, now()) > t.inizio
       AND t.inizio < _ts_roma(p_data, p_ora_fine) AND coalesce(t.fine, now()) > _ts_roma(p_data, p_ora_inizio);
  END IF;
  IF v_chi IS NOT NULL THEN
    IF v_origine = 'a_posteriori' THEN
      RAISE EXCEPTION 'In quelle ore il turno era già di un altro monitor (%): da solo non ti puoi segnare. Se c''eri anche tu, decide la segreteria.', v_chi;
    END IF;
    RAISE EXCEPTION 'In quelle ore c''è già un monitor dichiarato (%). In sala c''è un monitor alla volta: scegli le ore libere, oppure chiedi a chi ha il turno di proportelo (PROPONI, su Turni).', v_chi;
  END IF;
  v_stato := CASE WHEN v_origine <> 'a_posteriori' THEN 'previsto'
                  WHEN v_seg THEN 'presente'              -- lo segna Marco o la segreteria: già confermato
                  ELSE 'da_confermare' END;
  v_note := nullif(trim(coalesce(p_note,'')), '');
  IF v_origine = 'a_posteriori' THEN
    v_note := concat_ws(' · ', 'segnato a posteriori il ' || v_quando
      || CASE WHEN v_seg THEN ', confermato da ' || _nome_staff(auth.uid()) ELSE '' END, v_note);
  END IF;
  IF v_user <> auth.uid() THEN
    v_note := concat_ws(' · ', 'dichiarato da ' || _nome_staff(auth.uid()) || ' il ' || v_quando, v_note);
  END IF;
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, origine,
                             revisione_esito, revisione_da, revisione_il)
  VALUES (v_user, 'monitor', NULL, p_data, p_ora_inizio, p_ora_fine, 'monitor', v_stato, auth.uid(), v_note, v_origine,
          CASE WHEN v_origine = 'a_posteriori' AND v_seg THEN 'confermato' END,
          CASE WHEN v_origine = 'a_posteriori' AND v_seg THEN auth.uid() END,
          CASE WHEN v_origine = 'a_posteriori' AND v_seg THEN now() END)
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = excluded.stato, ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, origine = excluded.origine,
                revisione_esito = excluded.revisione_esito, revisione_da = excluded.revisione_da, revisione_il = excluded.revisione_il,
                revisione_nota = NULL, presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, 'dichiarato di nuovo il ' || v_quando, excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;
  IF v_origine = 'a_posteriori' THEN
    v_turno := _monitor_lega_turno(v_id);
    IF v_stato = 'da_confermare' THEN
      BEGIN
        PERFORM _monitor_avvisa_a_posteriori(v_id);
      EXCEPTION WHEN OTHERS THEN NULL;   -- l'avviso non deve mai bloccare il turno
      END;
    END IF;
  END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'data', p_data, 'ora_inizio', p_ora_inizio, 'ora_fine', p_ora_fine,
                            'origine', v_origine, 'stato', v_stato, 'turno_id', v_turno);
END $function$;

-- ── 6. la segreteria conferma o respinge un turno a posteriori ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_rivedi_turno(p_impegno_id uuid, p_conferma boolean, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE r impegni_staff; v_nota text := nullif(trim(coalesce(p_nota,'')), ''); v_firma text;
BEGIN
  IF auth.uid() IS NULL OR NOT is_segreteria() THEN
    RAISE EXCEPTION 'I turni segnati a posteriori li conferma o li respinge Marco o la segreteria.';
  END IF;
  IF p_conferma IS NULL THEN RAISE EXCEPTION 'Confermi o respingi?'; END IF;
  IF NOT p_conferma AND length(coalesce(v_nota,'')) < 3 THEN
    RAISE EXCEPTION 'Scrivi perché lo respingi: la nota resta nello storico e la vede chi si è segnato.';
  END IF;
  SELECT * INTO r FROM impegni_staff WHERE id = p_impegno_id FOR UPDATE;
  IF NOT FOUND OR r.tipo <> 'monitor' THEN RAISE EXCEPTION 'Turno monitor non trovato.'; END IF;
  IF r.stato <> 'da_confermare' THEN RAISE EXCEPTION 'Questo turno non è più da rivedere: è già stato deciso.'; END IF;
  v_firma := _nome_staff(auth.uid()) || ' il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI');
  UPDATE impegni_staff
     SET stato = CASE WHEN p_conferma THEN 'presente' ELSE 'ritirato' END,
         revisione_esito = CASE WHEN p_conferma THEN 'confermato' ELSE 'respinto' END,
         revisione_da = auth.uid(), revisione_il = now(), revisione_nota = v_nota, updated_at = now(),
         note = concat_ws(' · ', note, CASE WHEN p_conferma THEN 'confermato da ' ELSE 'respinto da ' END || v_firma || coalesce(': ' || v_nota, ''))
   WHERE id = r.id;
  RETURN jsonb_build_object('ok', true, 'esito', CASE WHEN p_conferma THEN 'confermato' ELSE 'respinto' END);
END $function$;

-- ── 7. compensi: le ore da rivedere non si pagano finché non c'è la conferma ───────────────────
CREATE OR REPLACE VIEW public.v_compenso_turni_monitor AS
 WITH d AS (
         SELECT i.turno_monitor_id AS turno_id,
            (array_agg(i.id ORDER BY i.ora_inizio))[1] AS impegno_id,
            min(i.ora_inizio) AS ora_ini,
            max(i.ora_fine) AS ora_fin,
            bool_or(i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AS attivo,
            COALESCE(sum(EXTRACT(epoch FROM (i.ora_fine - i.ora_inizio)) / 3600.0) FILTER (WHERE i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])), 0::numeric) AS ore_dich,
            bool_or(i.stato = 'da_confermare') AS in_rev,
            COALESCE(sum(EXTRACT(epoch FROM (i.ora_fine - i.ora_inizio)) / 3600.0) FILTER (WHERE i.stato = 'da_confermare'), 0::numeric) AS ore_rev,
            bool_or(i.origine = 'a_posteriori') AS ha_post
           FROM impegni_staff i
          WHERE i.tipo = 'monitor'::text AND i.turno_monitor_id IS NOT NULL
          GROUP BY i.turno_monitor_id
        ), t AS (
         SELECT tm.id AS turno_id,
            tm.monitor_user_id AS user_id,
            tm.data,
            tm.inizio,
            tm.fine,
            tm.fine IS NULL AS aperto,
                CASE
                    WHEN tm.data < monitor_regola_dal() AND NOT COALESCE(d.ha_post, false) THEN
                    CASE
                        WHEN tm.fine IS NULL AND tm.data < CURRENT_DATE THEN 0::numeric
                        ELSE round(EXTRACT(epoch FROM (COALESCE(tm.fine, now()) - tm.inizio)) / 3600.0 * 4::numeric) / 4::numeric
                    END
                    WHEN COALESCE(d.attivo, false) THEN d.ore_dich
                    ELSE 0::numeric
                END AS ore,
            tm.data < monitor_regola_dal() AND NOT COALESCE(d.ha_post, false) AND tm.fine IS NULL AND tm.data < CURRENT_DATE AS da_chiudere,
                CASE
                    WHEN tm.data < monitor_regola_dal() AND NOT COALESCE(d.ha_post, false) THEN 'storico'::text
                    WHEN d.turno_id IS NULL THEN 'non_dichiarato'::text
                    WHEN NOT d.attivo AND d.in_rev THEN 'da_rivedere'::text
                    WHEN NOT d.attivo THEN 'annullato'::text
                    ELSE 'dichiarato'::text
                END AS regola,
            d.impegno_id,
            d.ora_ini,
            d.ora_fin,
            COALESCE(d.in_rev, false) AS in_rev,
            COALESCE(d.ore_rev, 0::numeric) AS ore_rev
           FROM turni_monitor tm
             LEFT JOIN d ON d.turno_id = tm.id
        ), s AS (
         SELECT ts.turno_id,
            count(DISTINCT ts.persona_id) FILTER (WHERE NOT monitor_seguito_a_5(ts.persona_id, tm2.data)) AS persone,
            count(DISTINCT ts.persona_id) FILTER (WHERE monitor_seguito_a_5(ts.persona_id, tm2.data)) AS veterani,
            count(DISTINCT ts.persona_id) FILTER (WHERE NOT monitor_seguito_a_5(ts.persona_id, tm2.data) AND (EXISTS ( SELECT 1
                   FROM osservazioni_allievo o
                  WHERE o.persona_id = ts.persona_id AND o.istruttore_user_id = tm2.monitor_user_id AND o.data = tm2.data AND o.contesto = 'sala_monitor'::text AND COALESCE(o.note, ''::text) <> ''::text))) AS persone_annotate
           FROM turni_monitor_seguiti ts
             JOIN turni_monitor tm2 ON tm2.id = ts.turno_id
          GROUP BY ts.turno_id
        ), x AS (
         SELECT t.turno_id,
            t.user_id,
            t.data,
            t.inizio,
            t.fine,
            t.aperto,
            t.ore,
            t.da_chiudere,
            t.regola,
            t.impegno_id,
            t.ora_ini,
            t.ora_fin,
                CASE
                    WHEN t.regola = 'storico'::text THEN COALESCE(s.persone, 0::bigint)
                    ELSE COALESCE(s.persone_annotate, 0::bigint)
                END AS p,
            COALESCE(s.veterani, 0::bigint) AS vet,
            t.in_rev,
            t.ore_rev
           FROM t
             LEFT JOIN s ON s.turno_id = t.turno_id
        )
 SELECT x.turno_id,
    x.user_id,
    (pe.nome || ' '::text) || COALESCE(pe.cognome, ''::text) AS monitor,
    x.data,
    x.inizio,
    x.fine,
    x.aperto,
    x.ore,
    x.p AS persone_seguite,
    LEAST(x.p::numeric, x.ore) AS ore_a_8,
    GREATEST(x.ore - LEAST(x.p::numeric, x.ore), 0::numeric) AS ore_a_5,
    (LEAST(x.p::numeric, x.ore) * 8::numeric + GREATEST(x.ore - LEAST(x.p::numeric, x.ore), 0::numeric) * 5::numeric)::numeric(8,2) AS compenso_eur,
    x.da_chiudere,
    x.vet AS veterani_seguiti,
    x.regola,
    x.impegno_id,
    x.ora_ini AS ora_inizio_dichiarata,
    x.ora_fin AS ora_fine_dichiarata,
    x.regola = 'non_dichiarato'::text AS da_controllare,
    x.in_rev AS in_revisione,
    x.ore_rev AS ore_da_rivedere
   FROM x
     LEFT JOIN profile_data pd ON pd.user_id = x.user_id
     LEFT JOIN persone pe ON pe.id = pd.persona_id
  WHERE is_segreteria() OR x.user_id = auth.uid();

-- get_compenso_monitor: un turno prima del 9/11 nato a posteriori va con la regola nuova (dalla vista), non con lo storico
CREATE OR REPLACE FUNCTION public.get_compenso_monitor(p_da date, p_a date, p_monitor_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(monitor text, monitor_user_id uuid, data date, inizio timestamp with time zone, fine timestamp with time zone, ore numeric, persone integer, ore_8 integer, ore_5 numeric, importo numeric, aperto boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH t AS (
    SELECT tm.*, COALESCE(pr.nome||' '||pr.cognome,'—') AS nome,
      ROUND(EXTRACT(EPOCH FROM (COALESCE(tm.fine, tm.inizio) - tm.inizio))/3600.0 * 2) / 2 AS ore_calc,
      (SELECT count(*) FROM turni_monitor_seguiti s
        WHERE s.turno_id=tm.id AND NOT monitor_seguito_a_5(s.persona_id, tm.data))::int AS n_pers
    FROM turni_monitor tm LEFT JOIN profiles pr ON pr.user_id=tm.monitor_user_id
    WHERE is_segreteria_piena() AND tm.data BETWEEN p_da AND p_a AND (p_monitor_user_id IS NULL OR tm.monitor_user_id=p_monitor_user_id)
      AND tm.data < monitor_regola_dal()
      AND NOT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = tm.id AND i.origine = 'a_posteriori')
  )
  SELECT * FROM (
    SELECT nome, monitor_user_id, data, inizio, fine, ore_calc, n_pers,
           LEAST(n_pers, FLOOR(ore_calc))::int, ore_calc - LEAST(n_pers, FLOOR(ore_calc)),
           LEAST(n_pers, FLOOR(ore_calc))*8 + (ore_calc - LEAST(n_pers, FLOOR(ore_calc)))*5, fine IS NULL
    FROM t
    UNION ALL
    SELECT COALESCE(v.monitor,'—'), v.user_id, v.data, v.inizio, v.fine, v.ore, v.persone_seguite::int,
           v.ore_a_8::int, v.ore_a_5, v.compenso_eur::numeric, v.aperto
      FROM v_compenso_turni_monitor v
     WHERE is_segreteria_piena() AND v.data BETWEEN p_da AND p_a AND (v.data >= monitor_regola_dal() OR v.regola <> 'storico')
       AND (p_monitor_user_id IS NULL OR v.user_id = p_monitor_user_id)
  ) z
  ORDER BY 3 DESC, 4 DESC;
$function$;

-- ── 8. completare un turno da rivedere anche oltre le 12 del giorno dopo ────────────────────────
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
  IF now() > monitor_completa_entro(t.data) AND NOT monitor_turno_in_revisione(t.id) THEN   -- 10/11: da rivedere = ancora completabile
    RAISE EXCEPTION 'Il turno del % si poteva completare fino alle 12:00 del giorno dopo: adesso lo sistema la segreteria.', to_char(t.data,'DD/MM');
  END IF;
  RETURN t;
END $function$;

DROP FUNCTION IF EXISTS public.monitor_turni_elenco(integer, boolean);
CREATE FUNCTION public.monitor_turni_elenco(p_giorni integer DEFAULT 30, p_tutti boolean DEFAULT false)
 RETURNS TABLE(turno_id uuid, monitor_user_id uuid, monitor text, data date, inizio timestamp with time zone, fine timestamp with time zone, ore numeric, persone integer, note_turno text, modificabile boolean, revisione text)
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
         (v_seg OR (t.monitor_user_id = auth.uid() AND (now() <= monitor_completa_entro(t.data) OR monitor_turno_in_revisione(t.id)))),
         CASE WHEN monitor_turno_in_revisione(t.id) THEN 'da_rivedere'
              WHEN EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = t.id AND i.revisione_esito = 'respinto')
                   AND NOT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = t.id AND i.stato IN ('previsto','presente')) THEN 'respinto'
         END
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
DECLARE t turni_monitor%ROWTYPE; v_seg boolean := is_segreteria_piena(); v_rev boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT * INTO t FROM turni_monitor WHERE id = p_turno_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato'; END IF;
  IF t.monitor_user_id <> auth.uid() AND NOT v_seg THEN RAISE EXCEPTION 'Puoi vedere solo i tuoi turni'; END IF;
  v_rev := monitor_turno_in_revisione(t.id);
  RETURN jsonb_build_object(
    'turno', jsonb_build_object('id',t.id,'data',t.data,'inizio',t.inizio,'fine',t.fine,'note',t.note,'monitor_user_id',t.monitor_user_id,
       'monitor',(SELECT nullif(trim(coalesce(nome,'')||' '||coalesce(cognome,'')),'') FROM profiles WHERE user_id = t.monitor_user_id),
       'modificabile',(v_seg OR (t.monitor_user_id = auth.uid() AND (now() <= monitor_completa_entro(t.data) OR v_rev))),
       'entro', monitor_completa_entro(t.data),
       'in_revisione', v_rev),
    'seguiti', (SELECT coalesce(jsonb_agg(jsonb_build_object('persona_id',s.persona_id,
                   'nome',trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),'primo_alle',s.primo_alle,
                   'note',o.note, 'scritta_alle', o.updated_at)
                 ORDER BY s.primo_alle),'[]'::jsonb)
                FROM turni_monitor_seguiti s JOIN persone pe ON pe.id = s.persona_id
                LEFT JOIN osservazioni_allievo o ON o.persona_id = s.persona_id AND o.istruttore_user_id = t.monitor_user_id
                     AND o.data = t.data AND o.contesto = 'sala_monitor'
               WHERE s.turno_id = t.id));
END $function$;

-- ── 9. cambio turno e doppio turno scrivono l'origine ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_rispondi_cambio(p_cambio_id uuid, p_accetta boolean, p_nota text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c cambi_turno_monitor; r impegni_staff; v_new uuid; v_quando text; v_nota text;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF p_accetta IS NULL THEN RAISE EXCEPTION 'Accetti o no?'; END IF;
  SELECT * INTO c FROM cambi_turno_monitor WHERE id = p_cambio_id FOR UPDATE;
  IF NOT FOUND OR c.stato <> 'proposta' THEN RAISE EXCEPTION 'Questa proposta non è più aperta.'; END IF;
  IF c.da_user_id = auth.uid() THEN RAISE EXCEPTION 'È il tuo turno: per toglierla usa RITIRA LA PROPOSTA.'; END IF;
  IF c.a_user_id IS NOT NULL AND c.a_user_id <> auth.uid() THEN RAISE EXCEPTION 'Questa proposta è per un altro collega.'; END IF;
  IF c.a_user_id IS NULL AND NOT p_accetta THEN RAISE EXCEPTION 'Le proposte a tutti non si rifiutano: se non puoi, lasciala lì.'; END IF;
  SELECT * INTO r FROM impegni_staff WHERE id = c.impegno_id FOR UPDATE;
  IF r.stato <> 'previsto' OR r.user_id <> c.da_user_id THEN RAISE EXCEPTION 'Il turno non è più di chi te l''ha proposto.'; END IF;
  IF _ts_roma(r.data, r.ora_inizio) <= now() THEN
    RAISE EXCEPTION 'Il turno è già iniziato: il cambio non si fa più da qui, decide la segreteria.';
  END IF;
  v_nota := nullif(trim(coalesce(p_nota,'')),'');
  IF NOT p_accetta THEN
    UPDATE cambi_turno_monitor SET stato = 'rifiutata', risposto_il = now(), risposto_da = auth.uid(), nota_risposta = v_nota WHERE id = c.id;
    RETURN jsonb_build_object('ok', true, 'accettata', false);
  END IF;
  IF staff_indisponibile(auth.uid(), r.data, r.ora_inizio, r.ora_fine) THEN
    RAISE EXCEPTION 'Quel giorno hai segnato "non ci sono": se adesso puoi esserci, prima togli il "non ci sono".';
  END IF;
  v_quando := to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI');
  UPDATE cambi_turno_monitor SET stato = 'accettata', risposto_il = now(), risposto_da = auth.uid(), nota_risposta = v_nota WHERE id = c.id;
  UPDATE impegni_staff SET stato = 'ritirato', updated_at = now(),
         note = concat_ws(' · ', note, 'ceduto a ' || _nome_staff(auth.uid()) || ', accettato il ' || v_quando)
   WHERE id = r.id;
  -- 10/11: la sostituzione è la strada giusta anche il giorno stesso: il turno preso eredita l'origine di quello ceduto
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, origine)
  VALUES (auth.uid(), 'monitor', NULL, r.data, r.ora_inizio, r.ora_fine, 'monitor', 'previsto', auth.uid(),
          'preso da ' || _nome_staff(c.da_user_id) || ' (cambio accettato il ' || v_quando || ')',
          coalesce(r.origine, _monitor_origine(r.data, r.ora_inizio)))
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = 'previsto', ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, origine = excluded.origine,
                revisione_esito = NULL, revisione_da = NULL, revisione_il = NULL, revisione_nota = NULL,
                presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_new;
  IF v_new IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;
  UPDATE cambi_turno_monitor SET nuovo_impegno_id = v_new WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'accettata', true, 'nuovo_impegno_id', v_new);
END $function$;

CREATE OR REPLACE FUNCTION public.monitor_doppio_turno(p_data date, p_ora_inizio time without time zone, p_ora_fine time without time zone, p_user_id uuid, p_motivo text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_ini time; v_fin time; v_id uuid; v_mot text := nullif(trim(coalesce(p_motivo,'')),''); v_origine text;
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
  -- 10/11: deciso dalla segreteria; se la sala è già iniziata resta "giorno stesso", non "a posteriori"
  v_origine := _monitor_origine(p_data, p_ora_inizio);
  IF v_origine = 'a_posteriori' THEN v_origine := 'giorno_stesso'; END IF;
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, doppio_motivo, origine)
  VALUES (p_user_id, 'monitor', NULL, p_data, p_ora_inizio, p_ora_fine, 'monitor', 'previsto', auth.uid(),
          'doppio turno creato da ' || _nome_staff(auth.uid()) || ' il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI') || ': ' || v_mot, v_mot, v_origine)
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = 'previsto', ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, doppio_motivo = excluded.doppio_motivo,
                origine = excluded.origine, revisione_esito = NULL, revisione_da = NULL, revisione_il = NULL, revisione_nota = NULL,
                presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION '% ha già un turno che inizia a quell''ora.', _nome_staff(p_user_id); END IF;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $function$;

-- ── 10. avviso turni.scoperti (worker v3.2): domani e dopodomani, ore della fascia senza monitor ─
--     Una volta al giorno tra le 10 e le 12 ora di Roma (il cron gira ogni ~10 minuti; la dedup_key tiene una riga sola).
--     Fuori da quella finestra non accoda niente: un avviso "delle 10" non parte alle 17. p_forza solo per le prove.
CREATE OR REPLACE FUNCTION public._turni_scoperti_avvisa(p_forza boolean DEFAULT false)
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_adesso timestamp := now() AT TIME ZONE 'Europe/Rome'; v_oggi date := (now() AT TIME ZONE 'Europe/Rome')::date;
        v_giorno date; v_fi time; v_ff time; h int; a time; b time; v_ci time; v_cf time;
        v_el jsonb := '[]'::jsonb; v_domani boolean := false; n int := 0;
BEGIN
  IF NOT p_forza AND (v_adesso::time < time '10:00' OR v_adesso::time >= time '12:00') THEN RETURN 0; END IF;
  IF EXISTS (SELECT 1 FROM eventi_notifica WHERE dedup_key = 'turni-scoperti-' || v_oggi) THEN RETURN 0; END IF;
  FOREACH v_giorno IN ARRAY ARRAY[v_oggi + 1, v_oggi + 2] LOOP
    SELECT f.ini, f.fin INTO v_fi, v_ff FROM monitor_fascia(v_giorno) f;
    CONTINUE WHEN v_fi IS NULL;                                                   -- domenica
    CONTINUE WHEN EXISTS (SELECT 1 FROM giorni_chiusi g WHERE g.data = v_giorno);  -- Accademia chiusa
    v_ci := NULL;
    FOR h IN extract(hour FROM v_fi)::int .. extract(hour FROM v_ff)::int - 1 LOOP
      a := make_time(h, 0, 0); b := make_time(h + 1, 0, 0);
      IF EXISTS (SELECT 1 FROM impegni_staff i WHERE i.tipo = 'monitor' AND i.data = v_giorno
                    AND i.stato IN ('previsto','presente','da_confermare') AND i.ora_inizio < b AND i.ora_fine > a) THEN
        IF v_ci IS NOT NULL THEN
          v_el := v_el || jsonb_build_array(jsonb_build_object('data', to_char(v_giorno,'YYYY-MM-DD'), 'ora_inizio', to_char(v_ci,'HH24:MI'), 'ora_fine', to_char(v_cf,'HH24:MI')));
          v_ci := NULL;
        END IF;
      ELSE
        IF v_ci IS NULL THEN v_ci := a; END IF;
        v_cf := b; n := n + 1;
        IF v_giorno = v_oggi + 1 THEN v_domani := true; END IF;
      END IF;
    END LOOP;
    IF v_ci IS NOT NULL THEN
      v_el := v_el || jsonb_build_array(jsonb_build_object('data', to_char(v_giorno,'YYYY-MM-DD'), 'ora_inizio', to_char(v_ci,'HH24:MI'), 'ora_fine', to_char(v_cf,'HH24:MI')));
    END IF;
  END LOOP;
  IF jsonb_array_length(v_el) = 0 THEN RETURN 0; END IF;
  PERFORM registra_evento_notifica('turni.scoperti', NULL, 'push',
    jsonb_build_object('elenco', v_el, 'anche_staff', v_domani),
    (v_oggi + time '10:00') AT TIME ZONE 'Europe/Rome', 'turni-scoperti-' || v_oggi);
  RETURN n;
END $function$;

-- blocco 11 nel cron che il worker chiama ogni ~10 minuti (aggiunto alla definizione live, come il 10 della 08c)
DO $do$
DECLARE d text; n0 int;
  a_decl text := E'  v_cambi_scaduti    int := 0;  -- 10) sql/monitor/08c\nBEGIN';
  a_ret  text := E'  RETURN jsonb_build_object(\n    ''eseguito_il'', now(),';
  a_fine text := E'''cambi_turno_scaduti'', v_cambi_scaduti\n  );';
BEGIN
  d := pg_get_functiondef('public.cron_genera_eventi_mattutini()'::regprocedure);
  IF position('_turni_scoperti_avvisa' IN d) > 0 THEN RAISE NOTICE 'blocco 11 già presente'; RETURN; END IF;
  FOREACH n0 IN ARRAY ARRAY[
      (length(d) - length(replace(d, a_decl, ''))) / length(a_decl),
      (length(d) - length(replace(d, a_ret,  ''))) / length(a_ret),
      (length(d) - length(replace(d, a_fine, ''))) / length(a_fine)] LOOP
    IF n0 <> 1 THEN RAISE EXCEPTION 'cron_genera_eventi_mattutini è cambiato: punto di aggancio non trovato una sola volta. Fermarsi e rileggere la funzione.'; END IF;
  END LOOP;
  d := replace(d, a_decl, E'  v_cambi_scaduti    int := 0;  -- 10) sql/monitor/08c\n  v_turni_scoperti   int := 0;  -- 11) sql/monitor/10\nBEGIN');
  d := replace(d, a_ret,
    E'  -- 11) ORE MONITOR SCOPERTE DI DOMANI E DOPODOMANI (sql/monitor/10, 10 nov 2026): una riga turni.scoperti al giorno,\n'
    || E'  --     tra le 10 e le 12 ora di Roma (dedup_key turni-scoperti-<giorno>). Se fallisce, gli altri avvisi partono lo stesso.\n'
    || E'  BEGIN\n    v_turni_scoperti := _turni_scoperti_avvisa();\n  EXCEPTION WHEN OTHERS THEN\n    v_turni_scoperti := -1;\n  END;\n\n'
    || a_ret);
  d := replace(d, a_fine, E'''cambi_turno_scaduti'', v_cambi_scaduti,\n    ''turni_scoperti'', v_turni_scoperti\n  );');
  EXECUTE d;
END $do$;

-- ── 12. report: ogni riga con l'ora in cui è scritto ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._sala_riga(p_riga text, p_quando timestamptz DEFAULT now())
 RETURNS text LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT CASE WHEN r ~ '^([0-9]{2}:[0-9]{2}|turno )' THEN r      -- ha già l'ora (o "turno HH:MI–HH:MI … scritta il …")
              ELSE to_char(p_quando AT TIME ZONE 'Europe/Rome','HH24:MI') || ' — ' || r END
    FROM (SELECT regexp_replace(trim(coalesce(p_riga,'')), '\s*\n\s*', ' / ', 'g') AS r) z
$$;

CREATE OR REPLACE FUNCTION public._sala_annota(p_turno_id uuid, p_persona_id uuid, p_quando timestamp with time zone, p_riga text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE t turni_monitor%ROWTYPE; v_id uuid; v_riga text;
BEGIN
  SELECT * INTO t FROM turni_monitor WHERE id = p_turno_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato'; END IF;
  IF p_persona_id IS NULL THEN RAISE EXCEPTION 'Scegli la persona che hai seguito'; END IF;
  IF coalesce(trim(p_riga),'') = '' THEN RAISE EXCEPTION 'La nota e'' vuota'; END IF;
  v_riga := _sala_riga(p_riga, now());   -- 10/11: un report = una riga con l'ora in cui è scritto
  -- la riga e' del monitor del turno e del giorno del turno (anche quando la scrive la segreteria)
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, note, created_at)
  VALUES (p_persona_id, t.monitor_user_id, t.data, 'sala_monitor', v_riga, p_quando)
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto = 'sala_monitor' DO UPDATE
    SET note = COALESCE(nullif(osservazioni_allievo.note,'') || E'\n','') || v_riga, updated_at = now()
  RETURNING id INTO v_id;
  INSERT INTO turni_monitor_seguiti (turno_id, persona_id, primo_alle, ultimo_alle)
  VALUES (p_turno_id, p_persona_id, p_quando, p_quando)
  ON CONFLICT (turno_id, persona_id) DO UPDATE
    SET primo_alle = LEAST(turni_monitor_seguiti.primo_alle, EXCLUDED.primo_alle),
        ultimo_alle = GREATEST(turni_monitor_seguiti.ultimo_alle, EXCLUDED.ultimo_alle);
  RETURN v_id;
END $function$;

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
  -- altrimenti va sul mio ultimo turno di oggi, anche se già chiuso (la chiusura delle 22 non fa perdere niente)
  IF v_turno IS NULL THEN
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE ORDER BY inizio DESC LIMIT 1;
  END IF;
  -- nessun turno oggi: report libero, resta nella scheda, nessun compenso
  v_fuori := v_turno IS NULL;
  v_riga := _sala_riga(trim(p_su_cosa)||' ('||trim(p_note)||')', now());   -- 10/11: una riga, con l'ora in testa
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

-- ── 11. permessi ────────────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public._monitor_origine(date, time, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._monitor_avvisa_a_posteriori(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._monitor_lega_turno(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._turni_scoperti_avvisa(boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._sala_riga(text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.monitor_turno_in_revisione(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_turno_in_revisione(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.monitor_rivedi_turno(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_rivedi_turno(uuid, boolean, text) TO authenticated;
REVOKE ALL ON FUNCTION public.monitor_turni_elenco(integer, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_turni_elenco(integer, boolean) TO authenticated, service_role;
