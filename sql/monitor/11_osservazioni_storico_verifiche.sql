-- sql/monitor/11 · VERIFICHE (solo dentro 11_osservazioni_storico_PROVA.sql, che finisce con ROLLBACK)
-- Marco (creator) 27b04151…, Roberta (segreteria) 1425639b…, Mattia bc680f11…, Bognanni dfed419c…
-- foto_oss è presa PRIMA del corpo (in testa alla PROVA).
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- 1. due osservazioni di corso dello stesso istruttore, stessa persona, stesso giorno → due righe, la prima intatta
DO $$ DECLARE r1 jsonb; r2 jsonb; k int; t1 text; b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; m uuid := '27b04151-93a7-4ecc-824c-fe337cc631a6'; BEGIN
  PERFORM pg_temp.come(m);
  r1 := salva_osservazione(b, '{"contesto":"open","note":"Prima versione: piedi precisi","temi_affrontati":"Kata 3"}'::jsonb);
  r2 := salva_osservazione(b, '{"contesto":"open","note":"Seconda versione: aggiungo la lettura della via","temi_affrontati":"Kata 3 e 4"}'::jsonb);
  SELECT count(*) INTO k FROM osservazioni_allievo WHERE persona_id = b AND istruttore_user_id = m AND data = CURRENT_DATE AND contesto IS DISTINCT FROM 'sala_monitor';
  SELECT note INTO t1 FROM osservazioni_allievo WHERE id = (r1->>'id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '1 riscrittura dello stesso giorno: due righe, la prima resta com''era',
    k = 2 AND r1->>'id' <> r2->>'id' AND t1 = 'Prima versione: piedi precisi' AND (r2->>'precedenti_oggi')::int = 1,
    'righe ' || k || ' · prima: ' || t1 || ' · ' || r2::text);
  -- 2. nella scheda (letta dalla segreteria) ci sono tutte e due, con l'ora in cui sono scritte e chi le ha scritte
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  SELECT count(*) INTO k FROM jsonb_array_elements(get_scheda_allievo(b)->'osservazioni') x
   WHERE x->>'contesto' = 'open' AND (x->>'data')::date = CURRENT_DATE AND x->>'autore' IS NOT NULL AND x->>'autore' <> '—' AND x->>'created_at' IS NOT NULL;
  INSERT INTO esiti VALUES (DEFAULT, '2 nella scheda: due osservazioni con ora e autore', k = 2, k || ' osservazioni di oggi con autore e ora');
END $$;

-- 3. lo storico già scritto non cambia di una virgola
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '3 storico intatto: tutte le righe di prima identiche',
  (SELECT count(*) FROM foto_oss f LEFT JOIN osservazioni_allievo o ON o.id = f.id WHERE o.id IS NULL OR md5(o::text) <> f.impronta) = 0,
  (SELECT count(*) FROM foto_oss) || ' righe controllate';

-- 4. la Sala con Monitor resta com'è (unicità per giorno sulla sua riga, ogni report con l'ora)
DO $$ DECLARE r jsonb; n text; b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; BEGIN
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  r := monitor_segna(b, 'Prova sala dopo la 11', 'Il report di sala va ancora', NULL);
  r := monitor_segna(b, 'Seconda prova sala', 'Stessa riga, riga nuova con l''ora', NULL);
  SELECT note INTO n FROM osservazioni_allievo WHERE persona_id = b AND istruttore_user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND data = CURRENT_DATE AND contesto = 'sala_monitor';
  INSERT INTO esiti VALUES (DEFAULT, '4 report di sala: una riga per giorno, ogni report con l''ora', cardinality(string_to_array(n, E'\n')) >= 2 AND n ~ '^[0-9]{2}:[0-9]{2} — ', n);
EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '4 report di sala', false, SQLERRM);
END $$;

-- 5. impianto: indice unico non di sala tolto, quello di sala resta; il diario dell'allievo ha l'ora
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '5 indici e diario dell''allievo',
  NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'osservazioni_allievo_oss_giorno_key')
  AND EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'osservazioni_allievo_sala_giorno_key')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'v_mio_diario_didattico' AND column_name = 'scritta_alle'),
  'ok';

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
