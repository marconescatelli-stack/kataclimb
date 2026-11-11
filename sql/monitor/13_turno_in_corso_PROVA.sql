-- sql/monitor/13 · PROVA: BEGIN → foto dei compensi → 13 → verifiche → ROLLBACK. Generato da 13_turno_in_corso_2026-11-11.sql + 13_turno_in_corso_verifiche.sql
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub', '27b04151-93a7-4ecc-824c-fe337cc631a6', 'role', 'authenticated')::text, true);
CREATE TEMP TABLE foto_turni AS SELECT * FROM v_compenso_turni_monitor;
CREATE TEMP TABLE foto_comp AS SELECT * FROM get_compenso_monitor('2026-10-01','2026-11-30');
CREATE TEMP TABLE foto_mattia AS SELECT * FROM impegni_staff WHERE id = '523e079a-658c-4c30-836f-25766d95bac9';
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/13 · TURNO MONITOR SEGNATO MENTRE È GIÀ INIZIATO (consegna v1, 11 nov 2026)
-- MIGRAZIONE. Si applica dopo la 08 → 12 (già applicate), solo dopo il "vai" di Marco.
-- Prova: 13_turno_in_corso_PROVA.sql (BEGIN → questo corpo → verifiche → ROLLBACK).
--
-- Cosa è successo (11/11/2026): nessuno aveva il turno; Mattia Seghezzi si è segnato per 19–22 alle 19:02
-- (impegno 523e079a…). _monitor_origine guardava solo l'ora di inizio (19:00 ≤ 19:02) → a_posteriori, stato
-- da_confermare, turno della Sala già chiuso 19:00–19:02 (42ece3ba…). INIZIA TURNO rispondeva "non hai un turno
-- dichiarato", su Turni l'ora era già sua: nessuna uscita. Un turno segnato MENTRE è in corso veniva trattato come PASSATO.
--
-- Regola di Marco (11 nov 2026):
--  1. un turno di oggi segnato mentre la fascia è ancora in corso vale come GIORNO STESSO: previsto, si apre subito,
--     si paga con le regole normali, resta marcato "giorno stesso";
--  2. vale dall'ora in corso in avanti; le ore intere già finite restano A POSTERIORI (da rivedere dalla segreteria).
--     Alle 20:10 chiedo 19–22 → 19–20 a posteriori, 20–22 giorno stesso. Alle 19:02 chiedo 19–22 → tutto giorno stesso;
--  3. a posteriori vero = il turno è finito (ora di fine passata, o giorno passato): invariato;
--  4. restano le altre regole (ore intere, un monitor per ora, sostituzione, "non ci sono", doppio turno).
--
-- Cosa cambia:
--  0. _monitor_adesso(): l'ora "adesso" delle funzioni del turno (= now()). Serve solo perché la prova possa fingere
--     le 19:02 / 20:10 / 22:05 dentro il ROLLBACK; in produzione è now() e basta.
--  1. _monitor_origine(data, ora_inizio, ORA_FINE, quando): funzione nuova accanto a quella di prima (stesso nome,
--     un argomento in più). A posteriori solo se l'ora di FINE è passata. Quella di prima (data, ora_inizio, quando)
--     resta com'è: la usano monitor_rispondi_cambio (solo su turni non iniziati) e monitor_doppio_turno (che comunque
--     trasforma a_posteriori in giorno_stesso): per loro il risultato non cambia, quindi non si toccano.
--  2. monitor_dichiara_turno: oggi e in corso → si spezza sull'ora intera corrente. Parte finita: impegno a_posteriori /
--     da_confermare (o confermato se lo segna la segreteria), _monitor_lega_turno e avviso alla segreteria, come prima.
--     Parte dall'ora corrente: impegno giorno_stesso / previsto, senza _monitor_lega_turno (il turno lo apre lui).
--     "Non ci sono" e "c'è già un monitor" si controllano sulla parte che vale subito con le regole del giorno stesso
--     (sostituzione), sulla parte finita con quelle del turno a posteriori. Il JSON dice cosa è stato creato:
--     subito {id, ora_inizio, ora_fine, apribile_adesso} e a_posteriori {id, ora_inizio, ora_fine, stato, turno_id},
--     più i campi di prima (id, origine, stato, turno_id, ora_inizio, ora_fine) riferiti alla parte che vale subito
--     quando c'è, altrimenti a quella a posteriori: le pagine di prima continuano a funzionare.
--  3. _monitor_msg_non_dichiarato: con un turno di oggi da_confermare non dice più "non hai un turno dichiarato":
--     dice che è segnato a posteriori, che lo conferma la segreteria, che per questo non si apre e che i report si
--     scrivono lo stesso.
--  4. _monitor_impegno_adesso: stessa regola, legge l'ora da _monitor_adesso() (e la data di Roma da lì).
--  Compensi: nessuna modifica alle viste. Impegno di Mattia dell'11/11 (523e079a…): non si tocca, resta da rivedere.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. l'ora "adesso" del turno ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._monitor_adesso()
 RETURNS timestamptz LANGUAGE sql STABLE
AS $$ SELECT now() $$;
COMMENT ON FUNCTION public._monitor_adesso() IS
  'Ora corrente per le funzioni del turno monitor (= now()). Esiste solo perché le prove possano fingere un''ora dentro il ROLLBACK (sql/monitor/13).';
REVOKE ALL ON FUNCTION public._monitor_adesso() FROM PUBLIC, anon, authenticated;

-- ── 1. l'origine guarda anche l'ora di fine ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public._monitor_origine(p_data date, p_ora_inizio time, p_ora_fine time, p_quando timestamptz DEFAULT now())
 RETURNS text LANGUAGE sql STABLE SET search_path TO 'public'
AS $$
  SELECT CASE WHEN _ts_roma(p_data, coalesce(p_ora_fine, p_ora_inizio)) <= p_quando THEN 'a_posteriori'
              WHEN (p_quando AT TIME ZONE 'Europe/Rome')::date < p_data             THEN 'dichiarato'
              ELSE 'giorno_stesso' END
$$;
COMMENT ON FUNCTION public._monitor_origine(date, time, time, timestamptz) IS
  'Marco 11/11/2026: a_posteriori solo se il turno è FINITO (ora di fine passata); entro il giorno prima = dichiarato; altrimenti giorno_stesso (anche se già iniziato). La parte già finita di un turno in corso la separa monitor_dichiara_turno.';
REVOKE ALL ON FUNCTION public._monitor_origine(date, time, time, timestamptz) FROM PUBLIC, anon, authenticated;

-- ── 4. il turno che copre adesso (regola invariata, ora da _monitor_adesso) ─────────────────────
CREATE OR REPLACE FUNCTION public._monitor_impegno_adesso(p_user uuid)
 RETURNS impegni_staff
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT i.* FROM impegni_staff i
   WHERE i.user_id = p_user AND i.tipo = 'monitor' AND i.data = (_monitor_adesso() AT TIME ZONE 'Europe/Rome')::date
     AND i.stato IN ('previsto','presente')
     AND _monitor_adesso() >= _ts_roma(i.data, i.ora_inizio) - interval '15 minutes'
     AND _monitor_adesso() <  _ts_roma(i.data, i.ora_fine)
   ORDER BY i.ora_inizio LIMIT 1
$function$;

-- ── 3. il messaggio quando INIZIA TURNO non trova un turno ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public._monitor_msg_non_dichiarato(p_user uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH a AS (SELECT _monitor_adesso() AS t, (_monitor_adesso() AT TIME ZONE 'Europe/Rome')::date AS oggi)
  SELECT COALESCE(
    (SELECT 'Il tuo turno monitor di oggi è dalle ' || to_char(i.ora_inizio,'HH24:MI') || ' alle ' || to_char(i.ora_fine,'HH24:MI')
            || ': lo apri da 15 minuti prima dell''inizio.'
       FROM impegni_staff i, a
      WHERE i.user_id = p_user AND i.tipo = 'monitor' AND i.data = a.oggi AND i.stato IN ('previsto','presente')
        AND _ts_roma(i.data, i.ora_inizio) - interval '15 minutes' > a.t
      ORDER BY i.ora_inizio LIMIT 1),
    -- 11 nov 2026: chi oggi ha solo un turno segnato a posteriori non deve leggere "non hai un turno"
    (SELECT 'Il tuo turno di oggi (' || string_agg(to_char(i.ora_inizio,'HH24:MI') || '–' || to_char(i.ora_fine,'HH24:MI'), ', ' ORDER BY i.ora_inizio)
            || ') è segnato a posteriori: lo conferma la segreteria, e per questo da qui non si apre. '
            || 'I report li scrivi lo stesso, dalla scheda della persona o da I miei turni.'
       FROM impegni_staff i, a
      WHERE i.user_id = p_user AND i.tipo = 'monitor' AND i.data = a.oggi AND i.stato = 'da_confermare'
     HAVING count(*) > 0),
    'Non hai un turno monitor dichiarato adesso. I turni si dichiarano prima, nella pagina Turni (Turni monitor): scegli il giorno e le ore. Se sei in sala per un imprevisto, avvisa la segreteria.')
$function$;

-- ── 2. dichiarare il turno: il turno in corso si spezza sull'ora corrente ───────────────────────
CREATE OR REPLACE FUNCTION public.monitor_dichiara_turno(p_data date, p_ora_inizio time without time zone, p_ora_fine time without time zone, p_user_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_user uuid := coalesce(p_user_id, auth.uid()); v_ini time; v_fin time; v_chi text; v_note text; v_seg boolean;
        v_adesso timestamptz := _monitor_adesso();
        v_oggi date := (_monitor_adesso() AT TIME ZONE 'Europe/Rome')::date;
        v_ora_h time := date_trunc('hour', _monitor_adesso() AT TIME ZONE 'Europe/Rome')::time;
        v_quando text := to_char(_monitor_adesso() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI');
        v_origine text;
        -- parte finita (a posteriori) e parte che vale subito; NULL se non c'è
        post_ini time; post_fin time; s_ini time; s_fin time;
        v_pid uuid; v_pstato text; v_pturno uuid; v_sid uuid; v_apribile boolean := false;
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

  -- 11 nov 2026: a posteriori solo se il turno è finito; in corso = giorno stesso dall'ora corrente, prima a posteriori
  v_origine := _monitor_origine(p_data, p_ora_inizio, p_ora_fine, v_adesso);
  IF v_origine = 'a_posteriori' THEN
    post_ini := p_ora_inizio; post_fin := p_ora_fine;
  ELSIF p_data = v_oggi AND p_ora_inizio < v_ora_h THEN
    post_ini := p_ora_inizio; post_fin := v_ora_h; s_ini := v_ora_h; s_fin := p_ora_fine;
  ELSE
    s_ini := p_ora_inizio; s_fin := p_ora_fine;
  END IF;

  IF s_ini IS NOT NULL AND staff_indisponibile(v_user, p_data, s_ini, s_fin) THEN
    RAISE EXCEPTION 'Il %/% è segnato "non ci sono": se adesso puoi esserci, prima togli il "non ci sono".',
      extract(day FROM p_data)::int, extract(month FROM p_data)::int;
  END IF;
  IF post_ini IS NOT NULL AND NOT v_seg AND EXISTS (
       SELECT 1 FROM impegni_staff i WHERE i.user_id = v_user AND i.tipo = 'monitor' AND i.data = p_data
          AND i.revisione_esito = 'respinto' AND i.ora_inizio < post_fin AND i.ora_fine > post_ini) THEN
    RAISE EXCEPTION 'La segreteria ha già respinto un tuo turno in quelle ore: se c''è un errore, parlane con lei.';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('monitor_dichiara_' || p_data::text));

  -- un monitor per ora: sulla parte che vale subito si passa dalla sostituzione
  IF s_ini IS NOT NULL THEN
    SELECT string_agg(_nome_staff(i.user_id) || ' ' || to_char(i.ora_inizio,'HH24:MI') || '–' || to_char(i.ora_fine,'HH24:MI'), ', ' ORDER BY i.ora_inizio)
      INTO v_chi
      FROM impegni_staff i
     WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente','da_confermare')
       AND i.ora_inizio < s_fin AND i.ora_fine > s_ini;
    IF v_chi IS NOT NULL THEN
      RAISE EXCEPTION 'In quelle ore c''è già un monitor dichiarato (%). In sala c''è un monitor alla volta: scegli le ore libere, oppure chiedi a chi ha il turno di proportelo (PROPONI, su Turni).', v_chi;
    END IF;
  END IF;
  -- sulla parte finita decide la segreteria
  IF post_ini IS NOT NULL THEN
    SELECT string_agg(_nome_staff(i.user_id) || ' ' || to_char(i.ora_inizio,'HH24:MI') || '–' || to_char(i.ora_fine,'HH24:MI'), ', ' ORDER BY i.ora_inizio)
      INTO v_chi
      FROM impegni_staff i
     WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente','da_confermare')
       AND i.ora_inizio < post_fin AND i.ora_fine > post_ini;
    IF v_chi IS NULL AND p_data < monitor_regola_dal() THEN
      IF EXISTS (SELECT 1 FROM turni_monitor t WHERE t.monitor_user_id = v_user AND t.data = p_data
                    AND NOT EXISTS (SELECT 1 FROM impegni_staff i WHERE i.turno_monitor_id = t.id AND i.origine = 'a_posteriori')) THEN
        RAISE EXCEPTION 'Il %/% hai già un turno registrato: quel giorno si conta col sistema di prima del %. Per correggerlo chiedi alla segreteria.',
          extract(day FROM p_data)::int, extract(month FROM p_data)::int, to_char(monitor_regola_dal(),'DD/MM');
      END IF;
      SELECT string_agg(DISTINCT _nome_staff(t.monitor_user_id), ', ') INTO v_chi
        FROM turni_monitor t
       WHERE t.monitor_user_id <> v_user AND t.data = p_data AND coalesce(t.fine, now()) > t.inizio
         AND t.inizio < _ts_roma(p_data, post_fin) AND coalesce(t.fine, now()) > _ts_roma(p_data, post_ini);
    END IF;
    IF v_chi IS NOT NULL THEN
      RAISE EXCEPTION 'In quelle ore il turno era già di un altro monitor (%): da solo non ti puoi segnare. Se c''eri anche tu, decide la segreteria.', v_chi;
    END IF;
  END IF;

  -- parte finita: a posteriori, come prima
  IF post_ini IS NOT NULL THEN
    v_pstato := CASE WHEN v_seg THEN 'presente' ELSE 'da_confermare' END;
    v_note := concat_ws(' · ', 'segnato a posteriori il ' || v_quando
      || CASE WHEN v_seg THEN ', confermato da ' || _nome_staff(auth.uid()) ELSE '' END
      || CASE WHEN s_ini IS NOT NULL THEN ' (dalle ' || to_char(s_ini,'HH24:MI') || ' vale come giorno stesso)' ELSE '' END,
      nullif(trim(coalesce(p_note,'')), ''));
    IF v_user <> auth.uid() THEN
      v_note := concat_ws(' · ', 'dichiarato da ' || _nome_staff(auth.uid()) || ' il ' || v_quando, v_note);
    END IF;
    INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, origine,
                               revisione_esito, revisione_da, revisione_il)
    VALUES (v_user, 'monitor', NULL, p_data, post_ini, post_fin, 'monitor', v_pstato, auth.uid(), v_note, 'a_posteriori',
            CASE WHEN v_seg THEN 'confermato' END, CASE WHEN v_seg THEN auth.uid() END, CASE WHEN v_seg THEN now() END)
    ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
    DO UPDATE SET stato = excluded.stato, ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, origine = excluded.origine,
                  revisione_esito = excluded.revisione_esito, revisione_da = excluded.revisione_da, revisione_il = excluded.revisione_il,
                  revisione_nota = NULL, presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                  note = concat_ws(' · ', impegni_staff.note, 'dichiarato di nuovo il ' || v_quando, excluded.note)
     WHERE impegni_staff.stato = 'ritirato'
    RETURNING id INTO v_pid;
    IF v_pid IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;
    v_pturno := _monitor_lega_turno(v_pid);
    IF v_pstato = 'da_confermare' THEN
      BEGIN
        PERFORM _monitor_avvisa_a_posteriori(v_pid);
      EXCEPTION WHEN OTHERS THEN NULL;
      END;
    END IF;
  END IF;

  -- parte che vale subito: dichiarato o giorno stesso, previsto; il turno lo apre lui (niente _monitor_lega_turno)
  IF s_ini IS NOT NULL THEN
    v_origine := CASE WHEN v_origine = 'dichiarato' THEN 'dichiarato' ELSE 'giorno_stesso' END;
    v_note := nullif(trim(coalesce(p_note,'')), '');
    IF post_ini IS NOT NULL THEN
      v_note := concat_ws(' · ', 'segnato il ' || v_quando || ' a turno iniziato: '
        || to_char(post_ini,'HH24:MI') || '–' || to_char(post_fin,'HH24:MI') || ' a posteriori', v_note);
    END IF;
    IF v_user <> auth.uid() THEN
      v_note := concat_ws(' · ', 'dichiarato da ' || _nome_staff(auth.uid()) || ' il ' || v_quando, v_note);
    END IF;
    INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note, origine)
    VALUES (v_user, 'monitor', NULL, p_data, s_ini, s_fin, 'monitor', 'previsto', auth.uid(), v_note, v_origine)
    ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
    DO UPDATE SET stato = excluded.stato, ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da, origine = excluded.origine,
                  revisione_esito = NULL, revisione_da = NULL, revisione_il = NULL,
                  revisione_nota = NULL, presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                  note = concat_ws(' · ', impegni_staff.note, 'dichiarato di nuovo il ' || v_quando, excluded.note)
     WHERE impegni_staff.stato = 'ritirato'
    RETURNING id INTO v_sid;
    IF v_sid IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;
    v_apribile := p_data = v_oggi AND v_adesso >= _ts_roma(p_data, s_ini) - interval '15 minutes' AND v_adesso < _ts_roma(p_data, s_fin);
  END IF;

  RETURN jsonb_build_object('ok', true, 'data', p_data,
    -- campi di prima: la parte che vale subito, se c'è; altrimenti quella a posteriori
    'id',         coalesce(v_sid, v_pid),
    'ora_inizio', coalesce(s_ini, post_ini),
    'ora_fine',   coalesce(s_fin, post_fin),
    'origine',    CASE WHEN v_sid IS NOT NULL THEN v_origine ELSE 'a_posteriori' END,
    'stato',      CASE WHEN v_sid IS NOT NULL THEN 'previsto' ELSE v_pstato END,
    'turno_id',   CASE WHEN v_sid IS NOT NULL THEN NULL ELSE v_pturno END,
    -- 11 nov 2026: cosa è stato creato, per la pagina
    'subito',      CASE WHEN v_sid IS NOT NULL THEN jsonb_build_object('id', v_sid, 'origine', v_origine,
                     'ora_inizio', s_ini, 'ora_fine', s_fin, 'apribile_adesso', v_apribile) END,
    'a_posteriori', CASE WHEN v_pid IS NOT NULL THEN jsonb_build_object('id', v_pid, 'stato', v_pstato,
                     'ora_inizio', post_ini, 'ora_fine', post_fin, 'turno_id', v_pturno) END);
END $function$;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/13 · VERIFICHE (solo dentro 13_turno_in_corso_PROVA.sql, che finisce con ROLLBACK)
-- Claudia 64a7b65e…, Mattia bc680f11…, Giammarco 77335928…, Roberta (segreteria) 1425639b…, Marco (creator) 27b04151…
-- Giorno di prova: giovedì 12/11/2026 (nessun turno monitor segnato). L'ora la finge pg_temp.alle(), che dentro
-- la prova riscrive _monitor_adesso(); ogni caso gira in un blocco che alla fine si annulla da solo (eccezione 'kc_annulla'),
-- così i casi non si pestano i piedi. Le foto foto_turni / foto_comp / foto_mattia sono prese PRIMA del corpo della 13.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
CREATE FUNCTION pg_temp.alle(ts text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN
  EXECUTE format('CREATE OR REPLACE FUNCTION public._monitor_adesso() RETURNS timestamptz LANGUAGE sql STABLE AS %L',
                 format('SELECT %L::timestamptz', ts || ' Europe/Rome'));
END $$;

-- 1. alle 19:02 Mattia si segna per oggi 19–22 libero → un impegno giorno_stesso / previsto, INIZIA TURNO lo trova
DO $$ DECLARE r jsonb; i impegni_staff; a uuid; nt int; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-12 19:02'); PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    r := monitor_dichiara_turno('2026-11-12', '19:00', '22:00');
    SELECT * INTO i FROM impegni_staff WHERE id = (r->>'id')::uuid;
    a := (_monitor_impegno_adesso('bc680f11-8f0f-4d4f-bc46-1bec466f4d36')).id;
    SELECT count(*) INTO nt FROM turni_monitor WHERE monitor_user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND data = '2026-11-12';
    ok := i.origine = 'giorno_stesso' AND i.stato = 'previsto' AND i.ora_inizio = '19:00' AND i.ora_fine = '22:00'
          AND r->'a_posteriori' = 'null'::jsonb AND (r->'subito'->>'apribile_adesso')::boolean AND a = i.id AND nt = 0
          AND (SELECT count(*) FROM impegni_staff WHERE user_id = i.user_id AND data = '2026-11-12' AND tipo = 'monitor') = 1;
    det := r::text || ' · impegno_adesso ' || coalesce(a::text,'—') || ' · turni_monitor ' || nt;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '1 alle 19:02, 19–22 libero → giorno stesso, previsto, si apre', ok, det);
END $$;

-- 2. alle 20:10 Mattia chiede 19–22 libero → 19–20 a posteriori da rivedere + avviso; 20–22 giorno stesso, apribile
DO $$ DECLARE r jsonb; p impegni_staff; s impegni_staff; a uuid; nav int; tm turni_monitor; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-12 20:10'); PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    r := monitor_dichiara_turno('2026-11-12', '19:00', '22:00');
    SELECT * INTO p FROM impegni_staff WHERE id = (r->'a_posteriori'->>'id')::uuid;
    SELECT * INTO s FROM impegni_staff WHERE id = (r->'subito'->>'id')::uuid;
    SELECT * INTO tm FROM turni_monitor WHERE id = p.turno_monitor_id;
    a := (_monitor_impegno_adesso('bc680f11-8f0f-4d4f-bc46-1bec466f4d36')).id;
    SELECT count(*) INTO nav FROM eventi_notifica WHERE dedup_key = 'turno-a-posteriori-' || p.id;
    ok := p.origine = 'a_posteriori' AND p.stato = 'da_confermare' AND p.ora_inizio = '19:00' AND p.ora_fine = '20:00' AND tm.id IS NOT NULL
          AND s.origine = 'giorno_stesso' AND s.stato = 'previsto' AND s.ora_inizio = '20:00' AND s.ora_fine = '22:00' AND s.turno_monitor_id IS NULL
          AND nav = 1 AND a = s.id AND (r->'subito'->>'apribile_adesso')::boolean
          AND r->>'id' = s.id::text AND r->>'origine' = 'giorno_stesso';
    det := r::text || ' · avvisi ' || nav || ' · turno a posteriori ' || coalesce(tm.id::text,'—') || ' · impegno_adesso ' || coalesce(a::text,'—')
           || ' · note: ' || coalesce(p.note,'') || ' | ' || coalesce(s.note,'');
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '2 alle 20:10, 19–22 libero → 19–20 a posteriori + avviso, 20–22 giorno stesso', ok, det);
END $$;

-- 3. alle 22:05 Mattia chiede 19–22 → tutto a posteriori, come adesso
-- 5. (stesso blocco) con solo il turno da rivedere, INIZIA TURNO non trova niente e il messaggio è quello nuovo
DO $$ DECLARE r jsonb; p impegni_staff; a uuid; m text; ok boolean; ok5 boolean; det text; det5 text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-12 22:05'); PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    r := monitor_dichiara_turno('2026-11-12', '19:00', '22:00');
    SELECT * INTO p FROM impegni_staff WHERE id = (r->>'id')::uuid;
    ok := p.origine = 'a_posteriori' AND p.stato = 'da_confermare' AND p.ora_inizio = '19:00' AND p.ora_fine = '22:00'
          AND r->'subito' = 'null'::jsonb AND r->>'origine' = 'a_posteriori' AND r->>'stato' = 'da_confermare' AND (r->>'turno_id') IS NOT NULL;
    det := r::text;
    PERFORM pg_temp.alle('2026-11-12 21:00');   -- come se avesse premuto INIZIA TURNO in sala
    a := (_monitor_impegno_adesso('bc680f11-8f0f-4d4f-bc46-1bec466f4d36')).id;
    m := _monitor_msg_non_dichiarato('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    ok5 := a IS NULL AND m LIKE 'Il tuo turno di oggi (19:00–22:00) è segnato a posteriori%'
           AND m !~* 'turno monitor dichiarato|lo apri da 15 minuti|tuo turno dichiarato';   -- non deve far scattare "VAI AI TURNI" su Oggi
    det5 := coalesce(a::text,'nessun impegno adesso') || ' · ' || m;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; ok5 := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '3 alle 22:05, 19–22 → tutto a posteriori, invariato', ok, det);
  INSERT INTO esiti VALUES (DEFAULT, '5 solo turno da rivedere + INIZIA TURNO → messaggio nuovo', ok5, det5);
END $$;

-- 4. alle 19:02 Mattia chiede 19–22 ma 20–22 è di Claudia → bloccato come oggi (sostituzione)
DO $$ DECLARE r jsonb; ok boolean; det text; e text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-11 18:00'); PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
    r := monitor_dichiara_turno('2026-11-12', '20:00', '22:00');
    det := 'Claudia: ' || (r->>'origine') || ' · ';
    PERFORM pg_temp.alle('2026-11-12 19:02'); PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    BEGIN
      r := monitor_dichiara_turno('2026-11-12', '19:00', '22:00');
      e := 'PASSATO (non doveva)';
    EXCEPTION WHEN raise_exception THEN e := SQLERRM;
    END;
    ok := e LIKE 'In quelle ore c''è già un monitor dichiarato (%PROPONI%'
          AND NOT EXISTS (SELECT 1 FROM impegni_staff WHERE user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND data = '2026-11-12');
    det := det || e;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '4 alle 19:02, 20–22 di Claudia → bloccato, sostituzione', ok, det);
END $$;

-- 6. Giammarco il giorno dopo si segna per ieri → a posteriori, invariato
DO $$ DECLARE r jsonb; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-13 10:00'); PERFORM pg_temp.come('77335928-3073-42ae-a327-fc2774d1d966');
    r := monitor_dichiara_turno('2026-11-12', '19:00', '21:00');
    ok := r->>'origine' = 'a_posteriori' AND r->>'stato' = 'da_confermare' AND r->'subito' = 'null'::jsonb AND (r->>'turno_id') IS NOT NULL;
    det := r::text;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '6 Giammarco il giorno dopo per ieri → a posteriori, invariato', ok, det);
END $$;

-- 6b. la segreteria alle 20:10 segna Mattia 19–22 → 19–20 già confermato (presente), 20–22 giorno stesso; nessun avviso
DO $$ DECLARE r jsonb; p impegni_staff; s impegni_staff; nav int; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-12 20:10'); PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
    r := monitor_dichiara_turno('2026-11-12', '19:00', '22:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'ha chiamato in Accademia');
    SELECT * INTO p FROM impegni_staff WHERE id = (r->'a_posteriori'->>'id')::uuid;
    SELECT * INTO s FROM impegni_staff WHERE id = (r->'subito'->>'id')::uuid;
    SELECT count(*) INTO nav FROM eventi_notifica WHERE dedup_key = 'turno-a-posteriori-' || p.id;
    ok := p.stato = 'presente' AND p.revisione_esito = 'confermato' AND s.stato = 'previsto' AND s.origine = 'giorno_stesso' AND nav = 0
          AND p.user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND s.user_id = p.user_id;
    det := r::text || ' · note: ' || coalesce(p.note,'') || ' | ' || coalesce(s.note,'');
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '6b segreteria alle 20:10 per Mattia → 19–20 confermato, 20–22 giorno stesso', ok, det);
END $$;

-- 6c. domani per domani (dichiarato) e oggi prima che inizi (giorno stesso): invariati
DO $$ DECLARE r1 jsonb; r2 jsonb; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.alle('2026-11-11 15:00'); PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    r1 := monitor_dichiara_turno('2026-11-12', '19:00', '20:00');
    PERFORM pg_temp.alle('2026-11-12 15:00');
    r2 := monitor_dichiara_turno('2026-11-12', '20:00', '22:00');
    ok := r1->>'origine' = 'dichiarato' AND r1->>'stato' = 'previsto' AND r2->>'origine' = 'giorno_stesso' AND r2->>'stato' = 'previsto'
          AND NOT (r2->'subito'->>'apribile_adesso')::boolean;
    det := r1::text || ' · ' || r2::text;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := 'ERRORE: ' || SQLERRM; END IF;
  END;
  INSERT INTO esiti VALUES (DEFAULT, '6c giorno prima = dichiarato, giorno stesso prima dell''inizio = giorno stesso', ok, det);
END $$;

-- 7. compensi identici (tutta la vista e get_compenso_monitor ott–nov) · impegno di Mattia dell'11/11 non toccato
DO $$ DECLARE k1 int; k2 int; s1 numeric; s2 numeric; s3 numeric; s4 numeric; BEGIN
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  SELECT count(*) INTO k1 FROM (
    (SELECT turno_id, ore, persone_seguite, compenso_eur, regola FROM foto_turni
     EXCEPT SELECT turno_id, ore, persone_seguite, compenso_eur, regola FROM v_compenso_turni_monitor)
    UNION ALL
    (SELECT turno_id, ore, persone_seguite, compenso_eur, regola FROM v_compenso_turni_monitor
     EXCEPT SELECT turno_id, ore, persone_seguite, compenso_eur, regola FROM foto_turni)) z;
  SELECT count(*) INTO k2 FROM (
    (SELECT * FROM foto_comp EXCEPT SELECT * FROM get_compenso_monitor('2026-10-01','2026-11-30'))
    UNION ALL
    (SELECT * FROM get_compenso_monitor('2026-10-01','2026-11-30') EXCEPT SELECT * FROM foto_comp)) z;
  SELECT sum(importo) INTO s1 FROM foto_comp WHERE data < '2026-11-01';
  SELECT sum(importo) INTO s2 FROM get_compenso_monitor('2026-10-01','2026-10-31');
  SELECT sum(importo) INTO s3 FROM foto_comp WHERE data BETWEEN '2026-11-09' AND '2026-11-11';
  SELECT sum(importo) INTO s4 FROM get_compenso_monitor('2026-11-09','2026-11-11');
  INSERT INTO esiti VALUES (DEFAULT, '7 compensi identici: vista, get_compenso ott–nov, ottobre, 9–11/11', k1 = 0 AND k2 = 0 AND s1 = s2 AND s3 IS NOT DISTINCT FROM s4,
    'righe diverse vista ' || k1 || ' · get_compenso ' || k2 || ' · ottobre ' || s1 || ' → ' || s2 || ' · 9–11/11 ' || coalesce(s3::text,'—') || ' → ' || coalesce(s4::text,'—'));
  INSERT INTO esiti (prova, ok, dettaglio)
  SELECT '7b impegno di Mattia dell''11/11 (523e079a) non toccato', to_jsonb(i) = to_jsonb(f), i.stato || ' · ' || i.origine || ' · ' || i.ora_inizio || '–' || i.ora_fine
    FROM impegni_staff i, foto_mattia f WHERE i.id = '523e079a-658c-4c30-836f-25766d95bac9' AND f.id = i.id;
  INSERT INTO esiti VALUES (DEFAULT, '7c dopo le prove _monitor_adesso() è di nuovo now()', _monitor_adesso() = now(), _monitor_adesso()::text);
END $$;

SELECT n, ok, prova, dettaglio FROM esiti ORDER BY n;
ROLLBACK;
