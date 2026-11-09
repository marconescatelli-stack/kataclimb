-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08 · VERIFICHE della migrazione (si usano solo dentro 08_turni_dichiarati_PROVA.sql, che finisce con ROLLBACK)
-- Persone: Claudia 64a7b65e…, Mattia bc680f11…, Giammarco 77335928…, Roberta (segreteria) 1425639b…, Marco (creator) 27b04151…
-- now() è fermo all'inizio della transazione: le date "future" sono dal 10/11 in poi.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- 6. Ottobre e tutto il passato identici: confronto turno per turno con la fotografia presa prima della migrazione
SELECT pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '6 passato identico (turno per turno)', count(*) = 0, count(*) || ' turni diversi'
  FROM (SELECT turno_id, ore, persone_seguite, ore_a_8, ore_a_5, compenso_eur, da_chiudere FROM foto_turni
        EXCEPT
        SELECT turno_id, ore, persone_seguite, ore_a_8, ore_a_5, compenso_eur, da_chiudere FROM v_compenso_turni_monitor) d;
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '6 ottobre identico (mese)', count(*) = 0, count(*) || ' righe diverse'
  FROM (SELECT user_id, mese, turni, ore, ore_a_8, ore_a_5, compenso_eur FROM foto_mesi
        EXCEPT
        SELECT user_id, mese, turni, ore, ore_a_8, ore_a_5, compenso_eur FROM v_compenso_monitor_mese) d;
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '6 ottobre totale', true, string_agg(monitor || ' ' || compenso_eur, ' · ' ORDER BY monitor)
  FROM v_compenso_monitor_mese WHERE mese = '2026-10-01';

-- da qui la regola nuova vale già da oggi, solo per provarla (si annulla col ROLLBACK)
CREATE OR REPLACE FUNCTION public.monitor_regola_dal() RETURNS date LANGUAGE sql IMMUTABLE AS $$ SELECT date '2026-11-09' $$;

-- 1. senza turno dichiarato non si apre (né da INIZIO TURNO né segnando una persona)
DO $$ BEGIN
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  BEGIN
    PERFORM monitor_turno('inizio', NULL);
    INSERT INTO esiti (prova, ok, dettaglio) VALUES ('1 apertura senza turno', false, 'si è aperto!');
  EXCEPTION WHEN OTHERS THEN
    -- dopo le 22 la risposta giusta è "la Sala di oggi è finita": va bene lo stesso, non si apre
    INSERT INTO esiti (prova, ok, dettaglio) VALUES ('1 apertura senza turno', SQLERRM LIKE 'Non hai un turno monitor dichiarato%' OR SQLERRM LIKE 'La Sala con Monitor di oggi è finita%', SQLERRM);
  END;
  BEGIN
    PERFORM monitor_segna('00ca571f-1f8f-43b5-abc3-b549dc325a70', 'prova prova prova', 'prova prova prova', NULL);
    INSERT INTO esiti (prova, ok, dettaglio) VALUES ('1 monitor_segna senza turno', false, 'ha aperto un turno!');
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO esiti (prova, ok, dettaglio) VALUES ('1 monitor_segna senza turno', SQLERRM LIKE 'Non hai un turno monitor dichiarato%' OR SQLERRM LIKE 'La Sala con Monitor di oggi è finita%', SQLERRM);
  END;
END $$;

-- 2. Claudia dichiara 19–22 domani; i controlli; la segreteria lo vede e lo annulla
DO $$ DECLARE r jsonb; v_id uuid; s text; n text; BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  r := monitor_dichiara_turno('2026-11-10', '19:00', '22:00', NULL, NULL);
  v_id := (r->>'id')::uuid;
  INSERT INTO esiti (prova, ok, dettaglio) VALUES ('2 dichiara 19–22 domani', (r->>'ok')::boolean, r::text);
  BEGIN PERFORM monitor_dichiara_turno('2026-11-12', '19:30', '21:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 mezz''ora rifiutata', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 mezz''ora rifiutata', true, SQLERRM); END;
  BEGIN PERFORM monitor_dichiara_turno('2026-11-12', '18:00', '20:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 fuori fascia rifiutato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 fuori fascia rifiutato', true, SQLERRM); END;
  BEGIN PERFORM monitor_dichiara_turno('2026-11-14', '18:00', '19:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 sabato dopo le 18 rifiutato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 sabato dopo le 18 rifiutato', true, SQLERRM); END;
  BEGIN PERFORM monitor_dichiara_turno('2026-11-15', '19:00', '20:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 domenica rifiutata', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 domenica rifiutata', true, SQLERRM); END;
  BEGIN PERFORM monitor_dichiara_turno(CURRENT_DATE, '19:00', '20:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 turno già iniziato rifiutato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 turno già iniziato rifiutato', true, SQLERRM); END;
  BEGIN PERFORM monitor_dichiara_turno('2026-11-12', '19:00', '20:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    INSERT INTO esiti VALUES (DEFAULT, '2 istruttore per un altro rifiutato', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 istruttore per un altro rifiutato', true, SQLERRM); END;

  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  BEGIN PERFORM impegno_mi_segno('monitor', NULL, '2026-11-10', '21:00', '22:00');
    INSERT INTO esiti VALUES (DEFAULT, '2 sovrapposizione rifiutata (via impegno_mi_segno)', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 sovrapposizione rifiutata (via impegno_mi_segno)', true, SQLERRM); END;

  -- la segreteria vede il turno (lettura di impegni_staff come authenticated, sotto) e lo annulla
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  BEGIN PERFORM monitor_annulla_turno(v_id, 'prova');
    INSERT INTO esiti VALUES (DEFAULT, '2 l''istruttore non annulla', false, 'annullato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 l''istruttore non annulla', true, SQLERRM); END;
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  BEGIN PERFORM monitor_annulla_turno(v_id, '');
    INSERT INTO esiti VALUES (DEFAULT, '2 annullo senza nota rifiutato', false, 'annullato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '2 annullo senza nota rifiutato', true, SQLERRM); END;
  PERFORM monitor_annulla_turno(v_id, 'Claudia quel giorno è in trasferta');
  SELECT stato, note INTO s, n FROM impegni_staff WHERE id = v_id;
  INSERT INTO esiti VALUES (DEFAULT, '2 annullato dalla segreteria', s = 'ritirato' AND n LIKE '%annullato da Roberta%trasferta%', s || ' · ' || n);
  -- caso eccezionale: la segreteria dichiara per Mattia, resta scritto chi
  r := monitor_dichiara_turno('2026-11-11', '19:00', '20:00', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'ha chiamato in Accademia');
  SELECT note || ' · segnato_da=' || _nome_staff(segnato_da) INTO n FROM impegni_staff WHERE id = (r->>'id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '2 segreteria per conto di Mattia', n LIKE 'dichiarato da Roberta%' AND n LIKE '%segnato_da=Roberta%', n);
END $$;

-- 2b. lettura come utente vero (RLS): la segreteria vede i turni dichiarati; un istruttore non scrive più righe monitor a mano
DO $$ DECLARE k int; BEGIN
  PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO k FROM impegni_staff WHERE tipo = 'monitor' AND data BETWEEN '2026-11-10' AND '2026-11-11';
  EXECUTE 'RESET ROLE';
  INSERT INTO esiti VALUES (DEFAULT, '2 la segreteria li vede in elenco (lettura con RLS)', k >= 2, k || ' turni 10–11/11');
END $$;
DO $$ BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    INSERT INTO impegni_staff (user_id, tipo, data, ora_inizio, ora_fine, ruolo) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', 'monitor', '2026-11-13', '19:00', '22:00', 'monitor');
    EXECUTE 'RESET ROLE';
    INSERT INTO esiti VALUES (DEFAULT, '7 riga monitor scritta a mano bloccata', false, 'inserita!');
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    INSERT INTO esiti VALUES (DEFAULT, '7 riga monitor scritta a mano bloccata', true, SQLERRM);
  END;
END $$;
RESET ROLE;

-- 3 e 4. compenso: dati di prova scritti direttamente (turni aperti in passato non si possono simulare con now() fermo)
DO $$ DECLARE t1 uuid; t2 uuid; t3 uuid; i1 uuid; i2 uuid; p uuid; v record; n int := 0;
  pers uuid[] := ARRAY['00ca571f-1f8f-43b5-abc3-b549dc325a70','21848ae7-671e-49af-9ca3-b2728fb819c4','96f6869b-3f05-4489-b2d7-bbbc47a2d406',
                       '21e9cdf8-8617-4309-8dd4-4ba235ba66d9','f92429e0-8cdf-4b17-96e3-ae5a7dcaf596','034ef4b5-42b1-46bf-b648-a11224080fbb',
                       'fcd4de50-e4d5-4f00-92e7-5d7ee7b0c2ae','ba15500c-0ced-437a-b415-11be30dec558','ad418c80-a462-44f4-8b4e-e46534835e1e',
                       'e5785a59-4378-4828-849b-3696dbfad27a']::uuid[];
BEGIN
  -- 3. Claudia: turno dichiarato 19–22, aperto alle 19:10, chiuso alle 21:30, 1 persona seguita e annotata
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', '2026-11-17',
    _ts_roma('2026-11-17','19:10'), _ts_roma('2026-11-17','21:30')) RETURNING id INTO t1;
  INSERT INTO impegni_staff (user_id, tipo, data, ora_inizio, ora_fine, ruolo, stato, presenza_inizio, turno_monitor_id)
  VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', 'monitor', '2026-11-17', '19:00', '22:00', 'monitor', 'presente', _ts_roma('2026-11-17','19:10'), t1) RETURNING id INTO i1;
  PERFORM _sala_annota(t1, pers[1], _ts_roma('2026-11-17','19:30'), 'prova verifica 3');
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t1;
  INSERT INTO esiti VALUES (DEFAULT, '3 19–22 aperto 19:10, 1 persona → 1×8 + 2×5 = 18 €',
    v.ore = 3 AND v.ore_a_8 = 1 AND v.ore_a_5 = 2 AND v.compenso_eur = 18 AND v.regola = 'dichiarato',
    format('ore %s · a 8 %s · a 5 %s · %s € · %s', v.ore, v.ore_a_8, v.ore_a_5, v.compenso_eur, v.regola));
  UPDATE turni_monitor SET fine = _ts_roma('2026-11-17','20:05') WHERE id = t1;
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t1;
  INSERT INTO esiti VALUES (DEFAULT, '3 chiuso alle 20:05: sempre 18 €', v.compenso_eur = 18, v.compenso_eur || ' €');

  -- 4. Mattia: 3 ore dichiarate, 10 persone seguite e annotate → 3 ore a 8 €
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('bc680f11-8f0f-4d4f-bc46-1bec466f4d36', '2026-11-18',
    _ts_roma('2026-11-18','19:00'), _ts_roma('2026-11-18','22:00')) RETURNING id INTO t2;
  INSERT INTO impegni_staff (user_id, tipo, data, ora_inizio, ora_fine, ruolo, stato, turno_monitor_id)
  VALUES ('bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'monitor', '2026-11-18', '19:00', '22:00', 'monitor', 'presente', t2) RETURNING id INTO i2;
  FOREACH p IN ARRAY pers LOOP n := n + 1; PERFORM _sala_annota(t2, p, _ts_roma('2026-11-18','19:00') + n * interval '5 minutes', 'prova verifica 4'); END LOOP;
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t2;
  INSERT INTO esiti VALUES (DEFAULT, '4 3 ore, 10 persone → 3×8 = 24 €',
    v.ore = 3 AND v.ore_a_8 = 3 AND v.ore_a_5 = 0 AND v.compenso_eur = 24 AND v.persone_seguite = 10,
    format('ore %s · persone %s · a 8 %s · a 5 %s · %s €', v.ore, v.persone_seguite, v.ore_a_8, v.ore_a_5, v.compenso_eur));

  -- turno aperto senza dichiarazione (es. prima delle regole nuove nel DB) → 0 € e da controllare
  INSERT INTO turni_monitor (monitor_user_id, data, inizio, fine) VALUES ('77335928-3073-42ae-a327-fc2774d1d966', '2026-11-19',
    _ts_roma('2026-11-19','19:00'), _ts_roma('2026-11-19','22:00')) RETURNING id INTO t3;
  PERFORM _sala_annota(t3, pers[2], _ts_roma('2026-11-19','19:30'), 'prova verifica non dichiarato');
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t3;
  INSERT INTO esiti VALUES (DEFAULT, 'C turno non dichiarato → 0 € e da controllare',
    v.compenso_eur = 0 AND v.da_controllare AND v.regola = 'non_dichiarato', format('%s € · %s · da_controllare %s', v.compenso_eur, v.regola, v.da_controllare));

  -- turno annullato dalla segreteria dopo la presenza → 0 €
  UPDATE impegni_staff SET stato = 'ritirato' WHERE id = i2;
  SELECT * INTO v FROM v_compenso_turni_monitor WHERE turno_id = t2;
  INSERT INTO esiti VALUES (DEFAULT, 'C turno annullato → 0 €', v.compenso_eur = 0 AND v.regola = 'annullato', v.compenso_eur || ' € · ' || v.regola);
END $$;

-- 5. cambio turno: Claudia propone a Mattia; prima dell'accettazione è di Claudia; dopo è di Mattia con lo storico
DO $$ DECLARE r jsonb; v_imp uuid; v_c uuid; s text; u uuid; n text; v_new uuid; BEGIN
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-20', '19:00', '22:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'ho un esame')->>'id')::uuid;
  SELECT stato, user_id INTO s, u FROM impegni_staff WHERE id = v_imp;
  INSERT INTO esiti VALUES (DEFAULT, '5 proposta fatta: il turno è ancora di Claudia', s = 'previsto' AND u = '64a7b65e-dd7f-4012-a120-47e8ea486a42', s || ' · ' || _nome_staff(u));
  BEGIN PERFORM monitor_proponi_cambio(v_imp, '77335928-3073-42ae-a327-fc2774d1d966');
    INSERT INTO esiti VALUES (DEFAULT, '5 seconda proposta sullo stesso turno rifiutata', false, 'accettata!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '5 seconda proposta sullo stesso turno rifiutata', true, SQLERRM); END;
  PERFORM pg_temp.come('77335928-3073-42ae-a327-fc2774d1d966');
  BEGIN PERFORM monitor_rispondi_cambio(v_c, true);
    INSERT INTO esiti VALUES (DEFAULT, '5 un altro collega non può accettare', false, 'accettato!');
  EXCEPTION WHEN OTHERS THEN INSERT INTO esiti VALUES (DEFAULT, '5 un altro collega non può accettare', true, SQLERRM); END;
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  r := monitor_rispondi_cambio(v_c, true, NULL);
  v_new := (r->>'nuovo_impegno_id')::uuid;
  SELECT stato || ' · ' || note INTO n FROM impegni_staff WHERE id = v_imp;
  INSERT INTO esiti VALUES (DEFAULT, '5 dopo l''accettazione: quello di Claudia è ceduto', n LIKE 'ritirato%ceduto a Mattia Seghezzi, accettato il%', n);
  SELECT stato || ' · ' || _nome_staff(user_id) || ' · ' || note INTO n FROM impegni_staff WHERE id = v_new;
  INSERT INTO esiti VALUES (DEFAULT, '5 nuovo impegno di Mattia', n LIKE 'previsto · Mattia Seghezzi · preso da Claudia Rinauro%', n);
  SELECT stato || ' · risposto da ' || _nome_staff(risposto_da) || ' · nuovo=' || (nuovo_impegno_id = v_new) INTO n FROM cambi_turno_monitor WHERE id = v_c;
  INSERT INTO esiti VALUES (DEFAULT, '5 storico del passaggio', n = 'accettata · risposto da Mattia Seghezzi · nuovo=true', n);

  -- rifiuto: resta di Claudia
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-21', '14:00', '16:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36')->>'id')::uuid;
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  PERFORM monitor_rispondi_cambio(v_c, false, 'quel sabato non posso');
  SELECT i.stato || ' · ' || _nome_staff(i.user_id) || ' · proposta ' || c.stato INTO n FROM impegni_staff i JOIN cambi_turno_monitor c ON c.impegno_id = i.id WHERE c.id = v_c;
  INSERT INTO esiti VALUES (DEFAULT, '5 rifiutata: resta di Claudia', n = 'previsto · Claudia Rinauro · proposta rifiutata', n);

  -- proposta a chiunque, poi Claudia si toglie: la proposta si chiude da sola
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-21', '16:00', '18:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, NULL, 'chi lo prende?')->>'id')::uuid;
  PERFORM impegno_mi_tolgo(v_imp);
  SELECT stato INTO s FROM cambi_turno_monitor WHERE id = v_c;
  INSERT INTO esiti VALUES (DEFAULT, '5 turno tolto: la proposta si chiude', s = 'ritirata', s);
END $$;

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
