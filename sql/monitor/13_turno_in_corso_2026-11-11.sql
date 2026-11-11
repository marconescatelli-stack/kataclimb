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
