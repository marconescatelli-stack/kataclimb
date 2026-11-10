-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/10 · VERIFICHE (solo dentro 10_giorno_prima_PROVA.sql, che finisce con ROLLBACK)
-- Claudia 64a7b65e…, Mattia bc680f11…, Giammarco 77335928…, Roberta (segreteria) 1425639b…, Marco (creator) 27b04151…
-- Le foto foto_turni / foto_comp sono prese PRIMA del corpo della 10 (in testa alla PROVA).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- 7. compensi di ottobre e dei turni già passati identici (subito dopo il corpo, prima delle prove)
DO $$ DECLARE k1 int; k2 int; s1 numeric; s2 numeric; BEGIN
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
  INSERT INTO esiti VALUES (DEFAULT, '7 compensi identici: tutti i turni della vista e get_compenso_monitor ott–nov', k1 = 0 AND k2 = 0 AND s1 = s2,
    'righe diverse vista ' || k1 || ' · get_compenso ' || k2 || ' · ottobre ' || s1 || ' → ' || s2);
  INSERT INTO esiti SELECT DEFAULT, '7b turni esistenti: origine dal 9/11 da created_at (stasera Giammarco, segnato oggi alle 12:04)',
    origine = 'giorno_stesso', _nome_staff(user_id) || ' ' || data || ' ' || ora_inizio || ' → ' || coalesce(origine,'—')
    FROM impegni_staff WHERE id = '35d6e673-e3ee-4e54-8b11-56ec18b29e59';
  INSERT INTO esiti SELECT DEFAULT, '7c prima del 9/11 origine vuota', count(*) = 0, count(*) || ' righe con origine'
    FROM impegni_staff WHERE tipo = 'monitor' AND data < '2026-11-09' AND origine IS NOT NULL;
END $$;

-- 6. avviso turni.scoperti: domani e dopodomani scoperti → una riga sola, anche_staff true; il secondo giro non aggiunge niente
DO $$ DECLARE k int; e eventi_notifica; n0 int; BEGIN
  n0 := _turni_scoperti_avvisa();   -- adesso sono le 16–17: fuori dalla finestra delle 10 non accoda niente
  INSERT INTO esiti VALUES (DEFAULT, '6a fuori dalle 10–12 non accoda', n0 = 0 AND NOT EXISTS (SELECT 1 FROM eventi_notifica WHERE tipo_evento = 'turni.scoperti'), 'ritorno ' || n0);
  PERFORM _turni_scoperti_avvisa(true);
  PERFORM _turni_scoperti_avvisa(true);
  SELECT count(*) INTO k FROM eventi_notifica WHERE tipo_evento = 'turni.scoperti';
  SELECT * INTO e FROM eventi_notifica WHERE tipo_evento = 'turni.scoperti';
  INSERT INTO esiti VALUES (DEFAULT, '6 domani e dopodomani scoperti: una riga, anche_staff true, alle 10, push, user_id NULL',
    k = 1 AND (e.payload->>'anche_staff')::boolean AND jsonb_array_length(e.payload->'elenco') = 2 AND e.canale = 'push' AND e.user_id IS NULL
      AND e.dedup_key = 'turni-scoperti-' || (now() AT TIME ZONE 'Europe/Rome')::date
      AND to_char(e.schedulato_per AT TIME ZONE 'Europe/Rome','HH24:MI') = '10:00',
    k || ' righe · ' || e.payload::text || ' · ' || to_char(e.schedulato_per AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI'));
  DELETE FROM eventi_notifica WHERE id = e.id;   -- riga di prova (siamo dentro il ROLLBACK): serve per il 6b
END $$;

-- 1. Claudia si segna oggi per domani 19–22 → dichiarato
DO $$ DECLARE r jsonb; BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  r := monitor_dichiara_turno(CURRENT_DATE + 1, '19:00', '22:00');
  INSERT INTO esiti VALUES (DEFAULT, '1 Claudia per domani 19–22 → dichiarato, previsto', r->>'origine' = 'dichiarato' AND r->>'stato' = 'previsto', r::text);
END $$;

-- 6b. con domani coperto e Mattia 19–20 dopodomani: elenco solo dopodomani 20–22, anche_staff false (intervalli continui)
DO $$ DECLARE e eventi_notifica; BEGIN
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  PERFORM monitor_dichiara_turno(CURRENT_DATE + 2, '19:00', '20:00');
  PERFORM _turni_scoperti_avvisa(true);
  SELECT * INTO e FROM eventi_notifica WHERE tipo_evento = 'turni.scoperti';
  INSERT INTO esiti VALUES (DEFAULT, '6b domani coperto, dopodomani 19–20 coperto → solo dopodomani 20–22, anche_staff false',
    NOT (e.payload->>'anche_staff')::boolean AND jsonb_array_length(e.payload->'elenco') = 1
      AND e.payload->'elenco'->0->>'ora_inizio' = '20:00' AND e.payload->'elenco'->0->>'ora_fine' = '22:00', e.payload::text);
END $$;

-- 3. stasera: Claudia prende 19–20 (giorno stesso); Mattia prova 19–22 → bloccato, gli dice di chiedere la sostituzione
--    (il turno vero di Giammarco di stasera è tolto solo dentro la prova, per avere la sera libera)
DO $$ DECLARE r jsonb; BEGIN
  UPDATE impegni_staff SET stato = 'ritirato' WHERE id = '35d6e673-e3ee-4e54-8b11-56ec18b29e59';
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  r := monitor_dichiara_turno(CURRENT_DATE, '19:00', '20:00');
  INSERT INTO esiti VALUES (DEFAULT, '3a Claudia stasera 19–20 alle 16–17 → giorno_stesso', r->>'origine' = 'giorno_stesso' AND r->>'stato' = 'previsto', r::text);
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  BEGIN
    PERFORM monitor_dichiara_turno(CURRENT_DATE, '19:00', '22:00');
    INSERT INTO esiti VALUES (DEFAULT, '3 Mattia stasera 19–22 con 19–20 di Claudia → bloccato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO esiti VALUES (DEFAULT, '3 Mattia stasera 19–22 con 19–20 di Claudia → bloccato, propone la sostituzione',
      SQLERRM LIKE '%Claudia%' AND SQLERRM LIKE '%PROPONI%', SQLERRM);
  END;
END $$;

-- 2. Mattia stasera 20–22 libero → vale, giorno_stesso, compenso normale (turno aperto simulato come fa _monitor_apri_turno)
DO $$ DECLARE r jsonb; t uuid; v record; BEGIN
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  r := monitor_dichiara_turno(CURRENT_DATE, '20:00', '22:00');
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('bc680f11-8f0f-4d4f-bc46-1bec466f4d36', CURRENT_DATE,
    _ts_roma(CURRENT_DATE, '19:55'), _ts_roma(CURRENT_DATE, '22:00')) RETURNING id INTO t;
  UPDATE impegni_staff SET turno_monitor_id = t, stato = 'presente' WHERE id = (r->>'id')::uuid;
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t;
  INSERT INTO esiti VALUES (DEFAULT, '2 Mattia stasera 20–22 → giorno_stesso, pagato come un turno normale (2 ore, 10 €)',
    r->>'origine' = 'giorno_stesso' AND v.regola = 'dichiarato' AND v.ore = 2 AND v.compenso_eur = 10 AND NOT v.in_revisione,
    r::text || ' · ' || v.regola || ' ' || v.ore || ' h ' || v.compenso_eur || ' €');
END $$;

-- 4. Giammarco "domattina" si segna per ieri sera 19–22 (9/11, libero) → a_posteriori, da rivedere, 0 €, avviso in coda;
--    completa il turno anche oltre le 12; Roberta conferma → si paga
DO $$ DECLARE r jsonb; v record; e eventi_notifica; k int; p1 uuid := '00ca571f-1f8f-43b5-abc3-b549dc325a70'; BEGIN
  PERFORM pg_temp.come('77335928-3073-42ae-a327-fc2774d1d966');
  r := monitor_dichiara_turno(CURRENT_DATE - 1, '19:00', '22:00');
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = (r->>'turno_id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '4a ieri sera 19–22 → a_posteriori, da_confermare, legato al turno vero del 9/11 (9acb288b), 0 €',
    r->>'origine' = 'a_posteriori' AND r->>'stato' = 'da_confermare' AND r->>'turno_id' = '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83'
      AND v.regola = 'da_rivedere' AND v.compenso_eur = 0 AND v.in_revisione AND v.ore_da_rivedere = 3,
    r::text || ' · ' || v.regola || ' ' || v.compenso_eur || ' € · da rivedere ' || v.ore_da_rivedere || ' h');
  SELECT * INTO e FROM eventi_notifica WHERE dedup_key = 'turno-a-posteriori-' || (r->>'id');
  INSERT INTO esiti VALUES (DEFAULT, '4b riga turno.a_posteriori in coda (push, user_id NULL, payload)',
    e.tipo_evento = 'turno.a_posteriori' AND e.canale = 'push' AND e.user_id IS NULL AND e.payload->>'chi' = 'Giammarco Rinauro'
      AND e.payload->>'ora_inizio' = '19:00' AND e.payload->>'ora_fine' = '22:00' AND e.payload->>'data' = to_char(CURRENT_DATE - 1,'YYYY-MM-DD'),
    coalesce(e.payload::text, 'nessuna riga'));
  -- oltre le 12 del giorno dopo, ma da rivedere: Giammarco può ancora aggiungere persone
  r := r || jsonb_build_object('agg', monitor_aggiungi_seguiti(ARRAY[p1], '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83'));
  INSERT INTO esiti VALUES (DEFAULT, '4c turno da rivedere: il monitor lo completa anche dopo le 12 del giorno dopo',
    (r->'agg'->>'ok')::boolean AND (SELECT modificabile FROM monitor_turni_elenco(30,false) WHERE turno_id = '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83')
      AND (SELECT revisione FROM monitor_turni_elenco(30,false) WHERE turno_id = '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83') = 'da_rivedere', (r->'agg')::text);
  -- Mattia a posteriori sulle stesse ore → no (un monitor per ora); Mattia non può confermare
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  BEGIN
    PERFORM monitor_dichiara_turno(CURRENT_DATE - 1, '20:00', '21:00');
    INSERT INTO esiti VALUES (DEFAULT, '4d a posteriori su un''ora già presa → bloccato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4d a posteriori su un''ora già presa → bloccato', SQLERRM LIKE '%già di un altro%Giammarco%', SQLERRM); END;
  BEGIN
    PERFORM monitor_rivedi_turno((r->>'id')::uuid, true, NULL);
    INSERT INTO esiti VALUES (DEFAULT, '4e Mattia non conferma', false, 'confermato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4e solo segreteria e creator confermano', true, SQLERRM); END;
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  BEGIN
    PERFORM monitor_rivedi_turno((r->>'id')::uuid, false, '');
    INSERT INTO esiti VALUES (DEFAULT, '4f respingere senza nota → no', false, 'respinto!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4f respingere senza nota → no', SQLERRM LIKE '%perché%', SQLERRM); END;
  PERFORM monitor_rivedi_turno((r->>'id')::uuid, true, NULL);
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = '9acb288b-d7d1-4ac2-ab2a-7f6c90358f83';
  INSERT INTO esiti VALUES (DEFAULT, '4 Roberta conferma → presente, si paga (3 ore)',
    v.regola = 'dichiarato' AND v.ore = 3 AND v.compenso_eur > 0 AND NOT v.in_revisione
      AND (SELECT revisione_esito = 'confermato' AND stato = 'presente' AND note LIKE '%confermato da Roberta%' FROM impegni_staff WHERE id = (r->>'id')::uuid),
    v.regola || ' ' || v.ore || ' h · ' || v.persone_seguite || ' persone · ' || v.compenso_eur || ' €');
END $$;

-- 5. Giammarco si segna "a fine mese" per un giorno prima del 9/11
DO $$ DECLARE r jsonb; v record; k int; BEGIN
  PERFORM pg_temp.come('77335928-3073-42ae-a327-fc2774d1d966');
  BEGIN   -- il 3/11 in sala c'era Claudia (18:57–22:01)
    PERFORM monitor_dichiara_turno('2026-11-03', '19:00', '22:00');
    INSERT INTO esiti VALUES (DEFAULT, '5a 3/11: c''era Claudia → bloccato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '5a 3/11 19–22: in sala c''era Claudia → da solo no, decide la segreteria', SQLERRM LIKE '%Claudia%', SQLERRM); END;
  BEGIN   -- il 6/11 Giammarco ha già un turno, contato col sistema di prima
    PERFORM monitor_dichiara_turno('2026-11-06', '19:00', '22:00');
    INSERT INTO esiti VALUES (DEFAULT, '5b 6/11: turno già registrato → bloccato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '5b 6/11: aveva già un turno (sistema di prima) → bloccato', SQLERRM LIKE '%sistema di prima%', SQLERRM); END;
  r := monitor_dichiara_turno('2026-11-07', '14:00', '18:00');   -- sabato 7/11, nessuno in sala
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = (r->>'turno_id')::uuid;
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  SELECT count(*) INTO k FROM get_compenso_monitor('2026-11-01','2026-11-30') g WHERE g.data = '2026-11-07' AND g.monitor_user_id = '77335928-3073-42ae-a327-fc2774d1d966' AND g.importo = 0;
  INSERT INTO esiti VALUES (DEFAULT, '5 sabato 7/11 14–18 → accettato, a_posteriori, da rivedere, 0 € nel conteggio di novembre (non lo storico)',
    r->>'origine' = 'a_posteriori' AND r->>'stato' = 'da_confermare' AND v.regola = 'da_rivedere' AND v.compenso_eur = 0 AND k = 1,
    r::text || ' · ' || v.regola || ' · get_compenso righe a 0 € ' || k);
  -- Roberta respinge con la nota → 0 €, resta; Giammarco non lo ripropone da solo
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  PERFORM monitor_rivedi_turno((r->>'id')::uuid, false, 'quel sabato la sala era chiusa');
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = (r->>'turno_id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '5c respinto → ritirato con la nota, 0 €, la riga resta',
    v.compenso_eur = 0 AND v.regola = 'annullato' AND (SELECT stato = 'ritirato' AND revisione_esito = 'respinto' AND note LIKE '%respinto da Roberta%sala era chiusa%' FROM impegni_staff WHERE id = (r->>'id')::uuid),
    (SELECT note FROM impegni_staff WHERE id = (r->>'id')::uuid));
  PERFORM pg_temp.come('77335928-3073-42ae-a327-fc2774d1d966');
  BEGIN
    PERFORM monitor_dichiara_turno('2026-11-07', '14:00', '18:00');
    INSERT INTO esiti VALUES (DEFAULT, '5d respinto non si ripropone da solo', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '5d respinto non si ripropone da solo', SQLERRM LIKE '%respinto%', SQLERRM); END;
  SELECT revisione INTO r FROM (SELECT to_jsonb(revisione) revisione FROM monitor_turni_elenco(30,false) WHERE data = '2026-11-07') z;
  INSERT INTO esiti VALUES (DEFAULT, '5e I miei turni: il turno respinto si vede come respinto', r = to_jsonb('respinto'::text), coalesce(r::text,'—'));
END $$;

-- 8. la segreteria segna a posteriori per un collega → già confermato, nessun avviso
DO $$ DECLARE r jsonb; BEGIN
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  r := monitor_dichiara_turno('2026-11-02', '19:00', '20:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'era in sala, me l''ha detto');
  INSERT INTO esiti VALUES (DEFAULT, '8 segreteria a posteriori per Mattia (2/11) → presente, confermato, nessun avviso',
    r->>'stato' = 'presente' AND NOT EXISTS (SELECT 1 FROM eventi_notifica WHERE dedup_key = 'turno-a-posteriori-' || (r->>'id'))
      AND (SELECT revisione_esito FROM impegni_staff WHERE id = (r->>'id')::uuid) = 'confermato', r::text);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO esiti VALUES (DEFAULT, '8 segreteria a posteriori per Mattia (2/11)', SQLERRM LIKE '%già%', 'bloccato (2/11 occupato o già suo): ' || SQLERRM);
END $$;

-- 9. impianto: blocco 11 nel cron, permessi
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '9 cron: blocco 11 presente una volta, il 10 resta',
  (length(d) - length(replace(d, '_turni_scoperti_avvisa()', ''))) / length('_turni_scoperti_avvisa()') = 1 AND position('_cambi_turno_scaduti()' IN d) > 0, 'ok'
  FROM (SELECT pg_get_functiondef('public.cron_genera_eventi_mattutini()'::regprocedure) d) z;
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '9b permessi: anon fuori, funzioni interne chiuse anche agli utenti',
  NOT has_function_privilege('anon', 'public.monitor_rivedi_turno(uuid,boolean,text)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.monitor_turni_elenco(integer,boolean)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.monitor_turni_elenco(integer,boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public._monitor_lega_turno(uuid)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public._turni_scoperti_avvisa(boolean)', 'EXECUTE')
  AND NOT has_function_privilege('authenticated', 'public._monitor_avvisa_a_posteriori(uuid)', 'EXECUTE'), 'ok';

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
