-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/09 · VERIFICHE (solo dentro 09_report_quando_serve_PROVA.sql, che finisce con ROLLBACK)
-- Claudia 64a7b65e…, Mattia bc680f11…, Roberta (segreteria) 1425639b…
-- I turni "di stasera" sono dati di prova scritti direttamente (now() è fermo, la sala non è aperta adesso).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

DO $$ DECLARE t uuid; ty uuid; tv uuid; r jsonb; k int; s text; ok boolean;
  p1 uuid := '00ca571f-1f8f-43b5-abc3-b549dc325a70'; p2 uuid := '21848ae7-671e-49af-9ca3-b2728fb819c4';
  p3 uuid := '96f6869b-3f05-4489-b2d7-bbbc47a2d406'; p4 uuid := '21e9cdf8-8617-4309-8dd4-4ba235ba66d9';
  p5 uuid := 'f92429e0-8cdf-4b17-96e3-ae5a7dcaf596';
BEGIN
  -- turno di Claudia aperto "stasera" (dati di prova)
  INSERT INTO turni_monitor (monitor_user_id, data, inizio) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', CURRENT_DATE, now() - interval '1 hour') RETURNING id INTO t;
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');

  -- 1. aggiungo 3 persone senza scrivere niente → Da annotare, il turno continua
  r := monitor_aggiungi_seguiti(ARRAY[p1,p2,p3]);
  SELECT count(*) INTO k FROM monitor_da_annotare() WHERE turno_id = t;
  INSERT INTO esiti VALUES (DEFAULT, '1 tre persone aggiunte senza report → 3 da annotare, turno aperto',
    (r->>'aggiunte')::int = 3 AND k = 3 AND (SELECT fine IS NULL FROM turni_monitor WHERE id = t), r::text || ' · da annotare ' || k);

  -- 2. report della prima a metà turno
  r := monitor_segna(p1, 'Kata 3 sul totem, tre vie', 'Bene, più sciolta del solito', NULL);
  SELECT count(*) INTO k FROM monitor_da_annotare() WHERE turno_id = t;
  INSERT INTO esiti VALUES (DEFAULT, '2 report della prima a metà turno → restano 2', (r->>'turno_id')::uuid = t AND k = 2, 'da annotare ' || k);

  -- 3. alle 22 il turno si chiude da solo (simulato); i report scritti dopo vanno sul turno di stasera
  UPDATE turni_monitor SET fine = now() WHERE id = t;
  r := monitor_segna(p2, 'Cadute controllate, 4 prove', 'Paura in calo, ripetere', NULL);
  INSERT INTO esiti VALUES (DEFAULT, '3 turno chiuso mentre scrivo: il report va sul turno di stasera', (r->>'turno_id')::uuid = t AND NOT (r->>'fuori_turno')::boolean, r::text);
  r := monitor_segna(p3, 'Lettura della via e piedi', 'Piedi più precisi a fine serata', NULL);
  SELECT count(*) INTO k FROM monitor_da_annotare() WHERE turno_id = t;
  INSERT INTO esiti VALUES (DEFAULT, '2-3 tutti e tre salvati, nessun turno nuovo aperto',
    k = 0 AND (SELECT count(*) FROM turni_monitor_seguiti WHERE turno_id = t) = 3
      AND (SELECT count(*) FROM turni_monitor WHERE monitor_user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND data = CURRENT_DATE) = 1,
    'da annotare ' || k || ' · seguiti ' || (SELECT count(*) FROM turni_monitor_seguiti WHERE turno_id = t));

  -- 4. completare dopo: turno di "ieri" (CURRENT_DATE-1) e di stasera, finestra fino alle 12 del giorno dopo
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', CURRENT_DATE - 1,
    _ts_roma(CURRENT_DATE - 1, '19:00'), _ts_roma(CURRENT_DATE - 1, '22:00')) RETURNING id INTO ty;
  ok := now() <= monitor_completa_entro(CURRENT_DATE);
  BEGIN
    PERFORM monitor_aggiungi_seguiti(ARRAY[p4], t);
    INSERT INTO esiti VALUES (DEFAULT, '4 persona dimenticata sul turno di stasera (entro le 12 di domani)', ok, 'aggiunta · finestra fino a ' || to_char(monitor_completa_entro(CURRENT_DATE) AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI'));
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4 persona dimenticata sul turno di stasera (entro le 12 di domani)', NOT ok, SQLERRM); END;
  ok := now() <= monitor_completa_entro(CURRENT_DATE - 1);
  BEGIN
    PERFORM monitor_aggiungi_seguiti(ARRAY[p4], ty);
    INSERT INTO esiti VALUES (DEFAULT, '4 turno di ieri: oltre le 12 non si completa più', ok, 'aggiunta (finestra ancora aperta)');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4 turno di ieri: oltre le 12 non si completa più', NOT ok, SQLERRM); END;
  BEGIN
    PERFORM monitor_nota_turno(ty, p4, 'Prova report tardivo', 'Prova report tardivo', NULL);
    INSERT INTO esiti VALUES (DEFAULT, '4 report tardivo sul turno di ieri (istruttore)', ok, 'scritto');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4 report tardivo sul turno di ieri (istruttore)', NOT ok, SQLERRM); END;
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  r := monitor_aggiungi_seguiti(ARRAY[p4], ty);
  INSERT INTO esiti VALUES (DEFAULT, '4 la segreteria completa anche dopo', (r->>'ok')::boolean, r::text);
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  -- report su un turno ancora aperto da I miei turni: prima non si poteva ("il turno è ancora aperto")
  INSERT INTO turni_monitor (monitor_user_id, data, inizio) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', CURRENT_DATE, now() - interval '10 minutes') RETURNING id INTO tv;
  r := monitor_nota_turno(tv, p5, 'Report da I miei turni', 'Turno ancora aperto, si scrive', NULL);
  SELECT note INTO s FROM osservazioni_allievo WHERE persona_id = p5 AND istruttore_user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND data = CURRENT_DATE AND contesto = 'sala_monitor';
  INSERT INTO esiti VALUES (DEFAULT, '4 report da I miei turni su turno aperto, con l''ora di scrittura', s LIKE '%in corso%scritta il%alle%', s);
END $$;

-- 6. Mattia scrive un report fuori turno → resta nella scheda, nessun turno, nessun compenso
DO $$ DECLARE r jsonb; s text; p uuid := 'fcd4de50-e4d5-4f00-92e7-5d7ee7b0c2ae'; BEGIN
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  r := monitor_segna(p, 'Visto in sala, consigli sui piedi', 'Gli ho detto di guardare i piedi', NULL);
  SELECT note INTO s FROM osservazioni_allievo WHERE persona_id = p AND istruttore_user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND data = CURRENT_DATE AND contesto = 'sala_monitor';
  INSERT INTO esiti VALUES (DEFAULT, '6 report fuori turno: salvato nella scheda, nessun turno aperto',
    (r->>'fuori_turno')::boolean AND r->'turno_id' = 'null'::jsonb AND s LIKE '%fuori turno%'
      AND NOT EXISTS (SELECT 1 FROM turni_monitor WHERE monitor_user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND data = CURRENT_DATE),
    r::text || ' · ' || s);
END $$;

-- 7. un monitor alla volta; il doppio turno lo crea solo la segreteria con il motivo, e si pagano tutti e due
DO $$ DECLARE r jsonb; ic uuid; im uuid; tc uuid; tm uuid; v1 numeric; v2 numeric; BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  ic := (monitor_dichiara_turno('2026-11-12', '19:00', '22:00')->>'id')::uuid;
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  BEGIN PERFORM monitor_dichiara_turno('2026-11-12', '19:00', '22:00');
    INSERT INTO esiti VALUES (DEFAULT, '7 Mattia dichiara la stessa ora: bloccato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '7 Mattia dichiara la stessa ora: bloccato', true, SQLERRM); END;
  BEGIN PERFORM monitor_doppio_turno('2026-11-12', '19:00', '22:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'sala piena');
    INSERT INTO esiti VALUES (DEFAULT, '7 l''istruttore non crea il doppio turno', false, 'creato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '7 l''istruttore non crea il doppio turno', true, SQLERRM); END;
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  BEGIN PERFORM monitor_doppio_turno('2026-11-12', '19:00', '22:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', '');
    INSERT INTO esiti VALUES (DEFAULT, '7 doppio turno senza motivo: rifiutato', false, 'creato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '7 doppio turno senza motivo: rifiutato', true, SQLERRM); END;
  r := monitor_doppio_turno('2026-11-12', '19:00', '22:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'sala piena, serve un secondo monitor');
  im := (r->>'id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '7 la segreteria crea il doppio turno con il motivo', (SELECT doppio_motivo FROM impegni_staff WHERE id = im) LIKE 'sala piena%',
    (SELECT note FROM impegni_staff WHERE id = im));
  -- presenza di tutti e due (dati di prova): turni aperti e collegati
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', '2026-11-12', _ts_roma('2026-11-12','19:00'), _ts_roma('2026-11-12','22:00')) RETURNING id INTO tc;
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('bc680f11-8f0f-4d4f-bc46-1bec466f4d36', '2026-11-12', _ts_roma('2026-11-12','19:05'), _ts_roma('2026-11-12','22:00')) RETURNING id INTO tm;
  UPDATE impegni_staff SET turno_monitor_id = tc, stato = 'presente' WHERE id = ic;
  UPDATE impegni_staff SET turno_monitor_id = tm, stato = 'presente' WHERE id = im;
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  SELECT compenso_eur INTO v1 FROM v_compenso_turni_monitor WHERE turno_id = tc;
  SELECT compenso_eur INTO v2 FROM v_compenso_turni_monitor WHERE turno_id = tm;
  INSERT INTO esiti VALUES (DEFAULT, '7 doppio turno: pagati tutti e due', v1 = 15 AND v2 = 15, 'Claudia ' || v1 || ' € · Mattia ' || v2 || ' €');
END $$;

-- 5. due tocchi su INIZIO TURNO: la porta unica con il blocco per persona (08) è ancora lì
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '5 un solo turno aperto per persona: blocco in _monitor_apri_turno',
       position('pg_advisory_xact_lock(hashtext(''monitor_apri_''' IN pg_get_functiondef('public._monitor_apri_turno()'::regprocedure)) > 0
       AND NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                        WHERE n.nspname = 'public' AND p.proname <> '_monitor_apri_turno'
                          AND pg_get_functiondef(p.oid) ~* 'insert\s+into\s+(public\.)?turni_monitor\s*\('),
       'nessun''altra funzione inserisce in turni_monitor';

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
