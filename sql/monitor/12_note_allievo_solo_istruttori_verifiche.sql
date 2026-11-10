-- sql/monitor/12 · VERIFICHE (solo dentro 12_note_allievo_solo_istruttori_PROVA.sql, che finisce con ROLLBACK)
-- Davide (assistente) 74e18cc7…, Roberta (segreteria) 1425639b…, Claudia (istruttore jr) 64a7b65e…, Marco (creator) 27b04151…,
-- Bognanni dfed419c… (login 1036fea7…). foto_quadro e foto_oss sono prese PRIMA del corpo.
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- 0. chi può scrivere all'allievo
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '0 istruttori: Claudia, Mattia, Giammarco, Mellozzini, i due account di Marco sì; Davide, Simone, Roberta no',
  puo_scrivere_allievo('64a7b65e-dd7f-4012-a120-47e8ea486a42') AND puo_scrivere_allievo('bc680f11-8f0f-4d4f-bc46-1bec466f4d36')
  AND puo_scrivere_allievo('77335928-3073-42ae-a327-fc2774d1d966') AND puo_scrivere_allievo('e4841ae2-aeef-4007-839d-7837d197195b')
  AND puo_scrivere_allievo('27b04151-93a7-4ecc-824c-fe337cc631a6') AND puo_scrivere_allievo('1fe625c1-343c-40f3-a3d2-101ad2b5386f')
  AND NOT puo_scrivere_allievo('74e18cc7-7fa5-4e09-88c9-9687f43b7298') AND NOT puo_scrivere_allievo('b7967e09-7257-4d55-ae6e-1044952f4f0b')
  AND NOT puo_scrivere_allievo('1425639b-da30-4a1a-af18-e1853c3bb286') AND NOT puo_scrivere_allievo('22cbbb0b-87e7-4c09-b78e-ef3313d8e421'),
  'ok';

-- 4. punto 4: niente di già scritto da non istruttori è cambiato (0 e 0), e le voci di prima sono identiche
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '4 storico: voci del quadro e osservazioni di prima identiche, visibilità compresa',
  (SELECT count(*) FROM foto_quadro f LEFT JOIN quadro_allievo_voci q ON q.id = f.id
     WHERE q.id IS NULL OR q.visibile_allievo IS DISTINCT FROM f.visibile_allievo OR q.testo IS DISTINCT FROM f.testo OR q.solo_staff) = 0
  AND (SELECT count(*) FROM foto_oss f LEFT JOIN osservazioni_allievo o ON o.id = f.id WHERE o.id IS NULL OR md5(o::text) <> f.impronta) = 0,
  (SELECT count(*) FROM foto_quadro) || ' voci e ' || (SELECT count(*) FROM foto_oss) || ' osservazioni controllate, '
    || (SELECT count(*) FROM foto_quadro WHERE visibile_allievo) || ' voci visibili all''allievo come prima';

-- 1. Davide (assistente) e Roberta (segreteria): osservazione "visibile all'allievo" → rifiutata dal DB
DO $$ DECLARE b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; BEGIN
  PERFORM pg_temp.come('74e18cc7-7fa5-4e09-88c9-9687f43b7298');
  BEGIN
    PERFORM salva_osservazione(b, '{"contesto":"open","per_allievo":"Bravo oggi","visibile_allievo":true}'::jsonb);
    INSERT INTO esiti VALUES (DEFAULT, '1a assistente: nota visibile all''allievo → rifiutata', false, 'salvata!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '1a assistente: nota visibile all''allievo → rifiutata', SQLERRM LIKE '%solo gli istruttori%', SQLERRM); END;
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  BEGIN
    PERFORM salva_osservazione(b, '{"contesto":"open","note":"Nota di segreteria","visibile_allievo":true}'::jsonb);
    INSERT INTO esiti VALUES (DEFAULT, '1b segreteria: nota visibile all''allievo → rifiutata', false, 'salvata!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '1b segreteria: nota visibile all''allievo → rifiutata', SQLERRM LIKE '%solo gli istruttori%', SQLERRM); END;
END $$;

-- 2. Davide scrive un report di sala fuori turno con il "per l'allievo" e una voce del quadro "Per te":
--    il report resta nella scheda, le voci si salvano SOLO PER LO STAFF, Bognanni non le vede
DO $$ DECLARE r jsonb; q jsonb; k int; b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; BEGIN
  PERFORM pg_temp.come('74e18cc7-7fa5-4e09-88c9-9687f43b7298');
  r := monitor_segna(b, 'Assistente in sala: piedi su P2', 'Bene, da riprendere', 'Per te dall''assistente');
  q := quadro_aggiungi(b, 'open', '[{"tipo":"per_te","testo":"Messaggio dell''assistente"},{"tipo":"punti_deboli","testo":"Nota per lo staff"}]'::jsonb);
  SELECT count(*) INTO k FROM quadro_allievo_voci WHERE persona_id = b AND autore_user_id = '74e18cc7-7fa5-4e09-88c9-9687f43b7298'
     AND solo_staff AND NOT visibile_allievo;
  INSERT INTO esiti VALUES (DEFAULT, '2a assistente: report salvato, le sue voci restano solo per lo staff',
    (r->>'ok')::boolean AND (q->>'solo_staff')::boolean AND (q->>'visibili_allievo')::int = 0 AND k = 3,
    'report ' || r::text || ' · quadro ' || q::text || ' · voci solo staff ' || k);
  PERFORM pg_temp.come('1036fea7-26b2-4fd1-878a-0957403c43c9');
  SELECT count(*) INTO k FROM v_mio_quadro WHERE testo IN ('Per te dall''assistente','Messaggio dell''assistente','Nota per lo staff');
  INSERT INTO esiti VALUES (DEFAULT, '2b Bognanni non vede le voci dell''assistente', k = 0, k || ' voci viste');
END $$;

-- 3. Claudia (istruttore) e Marco (creator): le loro note arrivano all'allievo come prima
DO $$ DECLARE q jsonb; o jsonb; k int; d int; b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  q := quadro_aggiungi(b, 'open', '[{"tipo":"per_te","testo":"Per te da Claudia, prova 12"}]'::jsonb);
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  o := salva_osservazione(b, '{"contesto":"open","per_allievo":"Per te da Marco, prova 12","visibile_allievo":true}'::jsonb);
  PERFORM pg_temp.come('1036fea7-26b2-4fd1-878a-0957403c43c9');
  SELECT count(*) INTO k FROM v_mio_quadro WHERE testo = 'Per te da Claudia, prova 12';
  SELECT count(*) INTO d FROM v_mio_diario_didattico WHERE per_allievo = 'Per te da Marco, prova 12';
  INSERT INTO esiti VALUES (DEFAULT, '3 istruttore e creator: l''allievo vede la voce di Claudia e la nota di Marco',
    NOT (q->>'solo_staff')::boolean AND k = 1 AND d = 1, 'quadro ' || k || ' · diario ' || d);
END $$;

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
