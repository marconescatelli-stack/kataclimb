-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08c · VERIFICHE degli avvisi (solo dentro 08c_avvisi_cambio_turno_PROVA.sql, che finisce con ROLLBACK)
-- Claudia 64a7b65e…, Mattia bc680f11…
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;
CREATE FUNCTION pg_temp.ev(p_cambio uuid, p_tipo text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(format('%s → %s · %s · payload %s · alle %s', e.tipo_evento, _nome_staff(e.user_id), e.canale, e.payload::text,
                           to_char(e.schedulato_per AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI')), ' | ')
    FROM eventi_notifica e WHERE e.dedup_key = 'turno-' || p_tipo || '-' || p_cambio $$;
CREATE FUNCTION pg_temp.quanti(p_cambio uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM eventi_notifica e WHERE e.dedup_key LIKE 'turno-%-' || p_cambio $$;

DO $$ DECLARE v_imp uuid; v_c uuid; e jsonb; r record; BEGIN
  -- 1. Claudia propone a Mattia → turno.cambio.proposto per Mattia
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-20', '19:00', '22:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'ho un esame')->>'id')::uuid;
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-proposto-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '1 proposto → Mattia, both, payload giusto',
    r.user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND r.canale = 'both' AND r.stato = 'da_mandare'
      AND r.payload->>'proposta_id' = v_c::text AND r.payload->>'da_nome' = 'Claudia' AND r.payload->>'a_nome' = 'Mattia'
      AND r.payload->>'data' = '2026-11-20' AND r.payload->>'ora_inizio' = '19:00' AND r.payload->>'ora_fine' = '22:00'
      AND r.payload->>'nota' = 'ho un esame',
    pg_temp.ev(v_c, 'proposto'));
  -- 2. Mattia accetta → turno.cambio.accettato per Claudia; secondo clic → nessuna riga in più
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  PERFORM monitor_rispondi_cambio(v_c, true, NULL);
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-accettato-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '2 accettato → Claudia, both, nota null',
    r.user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND r.canale = 'both' AND r.payload->'nota' = 'null'::jsonb
      AND r.payload->>'a_nome' = 'Mattia', pg_temp.ev(v_c, 'accettato'));
  BEGIN PERFORM monitor_rispondi_cambio(v_c, true, NULL);
  EXCEPTION WHEN OTHERS THEN NULL; END;
  INSERT INTO esiti VALUES (DEFAULT, '2 secondo clic su accetta: nessuna riga in più', pg_temp.quanti(v_c) = 2, pg_temp.quanti(v_c) || ' righe per questa proposta');

  -- 3. rifiuto con nota → turno.cambio.rifiutato per Claudia con la nota di Mattia
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-21', '14:00', '16:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36')->>'id')::uuid;
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  PERFORM monitor_rispondi_cambio(v_c, false, 'quel sabato non posso');
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-rifiutato-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '3 rifiutato → Claudia, con la nota di chi rifiuta',
    r.user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND r.canale = 'both' AND r.payload->>'nota' = 'quel sabato non posso',
    pg_temp.ev(v_c, 'rifiutato'));

  -- 4. Claudia ritira la proposta → turno.cambio.ritirato per Mattia, solo push
  PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
  v_imp := (monitor_dichiara_turno('2026-11-21', '16:00', '18:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36')->>'id')::uuid;
  PERFORM monitor_ritira_cambio(v_c);
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-ritirato-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '4 ritirato → Mattia, push',
    r.user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND r.canale = 'push', pg_temp.ev(v_c, 'ritirato'));

  -- 5. la proposta si chiude da sola perché Claudia si toglie → ritirato per Mattia
  v_imp := (monitor_dichiara_turno('2026-11-24', '19:00', '20:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36')->>'id')::uuid;
  PERFORM impegno_mi_tolgo(v_imp);
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-ritirato-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '5 Claudia si toglie: ritirato → Mattia',
    r.user_id = 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36' AND r.canale = 'push', pg_temp.ev(v_c, 'ritirato'));

  -- 6. proposta a tutti: nessun destinatario Y → nessun avviso proposto
  v_imp := (monitor_dichiara_turno('2026-11-25', '19:00', '20:00')->>'id')::uuid;
  v_c := (monitor_proponi_cambio(v_imp, NULL, 'chi lo prende?')->>'id')::uuid;
  INSERT INTO esiti VALUES (DEFAULT, '6 proposta a tutti: nessun avviso (resta su Oggi e Turni)', pg_temp.quanti(v_c) = 0, pg_temp.quanti(v_c) || ' righe');
  PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
  PERFORM monitor_rispondi_cambio(v_c, true, NULL);
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-accettato-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '6 a tutti, Mattia accetta: accettato → Claudia con a_nome Mattia',
    r.user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND r.payload->>'a_nome' = 'Mattia', pg_temp.ev(v_c, 'accettato'));
END $$;

-- 7. proposta lasciata aperta su un turno già iniziato (oggi alle 19) → al giro del cron scaduta + turno.cambio.scaduto
DO $$ DECLARE v_imp uuid; v_c uuid; j jsonb; s text; r record; BEGIN
  INSERT INTO impegni_staff (user_id, tipo, data, ora_inizio, ora_fine, ruolo, stato)
  VALUES ('64a7b65e-dd7f-4012-a120-47e8ea486a42', 'monitor', CURRENT_DATE, '19:00', '22:00', 'monitor', 'previsto') RETURNING id INTO v_imp;
  INSERT INTO cambi_turno_monitor (impegno_id, da_user_id, a_user_id, nota)
  VALUES (v_imp, '64a7b65e-dd7f-4012-a120-47e8ea486a42', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'prova scadenza') RETURNING id INTO v_c;
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-proposto-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '7 turno di oggi: proposto schedulato subito, anche di sera',
    r.schedulato_per <= now() + interval '1 second', pg_temp.ev(v_c, 'proposto'));
  j := cron_genera_eventi_mattutini();
  SELECT stato || ' · ' || nota_risposta INTO s FROM cambi_turno_monitor WHERE id = v_c;
  SELECT * INTO r FROM eventi_notifica WHERE dedup_key = 'turno-scaduto-' || v_c;
  INSERT INTO esiti VALUES (DEFAULT, '7 cron: proposta scaduta + scaduto → Claudia, both',
    s LIKE 'scaduta%' AND r.user_id = '64a7b65e-dd7f-4012-a120-47e8ea486a42' AND r.canale = 'both' AND (j->>'cambi_turno_scaduti')::int >= 1,
    s || ' | cron cambi_turno_scaduti=' || (j->>'cambi_turno_scaduti') || ' | ' || pg_temp.ev(v_c, 'scaduto'));
  j := cron_genera_eventi_mattutini();
  INSERT INTO esiti VALUES (DEFAULT, '7 secondo giro del cron: niente di nuovo', pg_temp.quanti(v_c) = 2 AND (j->>'cambi_turno_scaduti')::int = 0,
    pg_temp.quanti(v_c) || ' righe · cambi_turno_scaduti=' || (j->>'cambi_turno_scaduti'));
END $$;

-- 8. il cron ha ancora tutti i suoi blocchi (1–9) e il 10 nuovo
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '8 cron intatto + blocco 10',
       position('-- 9) PROMEMORIA LEZIONE PRIVATA BAMBINI' IN d) > 0 AND position('-- 1) LEZIONI DI OGGI' IN d) > 0
       AND position('_cambi_turno_scaduti()' IN d) > 0 AND position('''cambi_turno_scaduti'', v_cambi_scaduti' IN d) > 0,
       length(d) || ' caratteri'
  FROM (SELECT pg_get_functiondef('public.cron_genera_eventi_mattutini()'::regprocedure) d) x;

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;
