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
