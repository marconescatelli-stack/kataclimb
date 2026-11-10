-- sql/monitor/11 · PROVA: BEGIN → foto delle osservazioni → 11 → verifiche → ROLLBACK
BEGIN;
CREATE TEMP TABLE foto_oss AS SELECT o.id, md5(o::text) AS impronta FROM osservazioni_allievo o;
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/11 · OSSERVAZIONI DI CORSO: OGNI RISCRITTURA RESTA (Marco, 10 nov 2026)
-- MIGRAZIONE. Dopo la 10. Prova: 11_osservazioni_storico_PROVA.sql (BEGIN → corpo → verifiche → ROLLBACK), COMMIT col "vai".
--
-- Regola di Marco: le osservazioni non perdono mai il testo di prima. Ogni riscrittura dello stesso giorno resta separata,
-- con la sua ora e l'istruttore, come i report di sala. Lo storico già scritto non si tocca.
--
-- Prima: indice unico (persona, istruttore, giorno) per le osservazioni non di sala, e salva_osservazione faceva
-- ON CONFLICT … DO UPDATE: la seconda osservazione dello stesso giorno sovrascriveva la prima.
-- Adesso:
--  1. via l'indice unico (resta un indice normale per le letture); nessuna riga esistente cambia;
--  2. salva_osservazione inserisce sempre una riga nuova (created_at = ora in cui è scritta); il ramo Sala con Monitor
--     è quello della 10, invariato (lì l'unicità per giorno resta e ogni report è una riga con l'ora);
--  3. v_mio_diario_didattico (quello che l'allievo legge) dà anche scritta_alle, in fondo, e ordina per giorno e ora.
-- Nessun altro punto del DB contava su "una al giorno" (controllato: solo salva_osservazione usava quell'indice).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

DROP INDEX IF EXISTS public.osservazioni_allievo_oss_giorno_key;
CREATE INDEX IF NOT EXISTS osservazioni_allievo_autore_giorno_idx ON public.osservazioni_allievo (persona_id, istruttore_user_id, data);

CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE); v_turno uuid; v_testo text; v_prima int;
BEGIN
  -- 30 ott: 'monitor' e 'sala_monitor' sono la Sala con Monitor: nota e persona seguita insieme, nel turno aperto.
  -- Stesso permesso di monitor_segna (staff); viene prima del controllo "tuo allievo" perche' senza turno l'errore giusto e' sul turno.
  IF p->>'contesto' IN ('monitor','sala_monitor') THEN
    IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
    IF v_turno IS NULL THEN
      RAISE EXCEPTION 'Questa è una nota della Sala con Monitor ma il tuo turno non è aperto: non l''ho salvata. Apri il turno, oppure aggiungila da I miei turni.';
    END IF;
    v_testo := concat_ws(' · ', nullif(trim(p->>'temi_affrontati'),''), nullif(trim(p->>'trasformazione'),''), nullif(trim(p->>'note'),''),
                 nullif(trim(p->>'obiettivo'),''), nullif(trim(p->>'criticita'),''), nullif(trim(p->>'da_implementare'),''));
    IF coalesce(v_testo,'') = '' THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato e com''è andata'; END IF;
    v_id := _sala_annota(v_turno, p_persona_id, now(), to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI') || ' — ' || v_testo);
    RETURN jsonb_build_object('ok',true,'id',v_id,'data',CURRENT_DATE,'sala',true,'turno_id',v_turno);
  END IF;
  IF NOT (is_mio_allievo(p_persona_id) OR (is_staff() AND NOT is_monitor() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  -- 10 nov 2026: ogni salvataggio è una riga nuova, quella di prima dello stesso giorno resta com'è
  SELECT count(*) INTO v_prima FROM osservazioni_allievo
   WHERE persona_id = p_persona_id AND istruttore_user_id = auth.uid() AND data = v_data AND contesto IS DISTINCT FROM 'sala_monitor';
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, obiettivo, interesse, aree_miglioramento,
    socializzazione, socializzazione_nota, fiducia, fiducia_nota, autostima, autostima_nota,
    concentrazione, concentrazione_nota, gestione_paura, gestione_paura_nota, note,
    temi_affrontati, criticita, trasformazione, da_implementare, per_allievo, visibile_allievo)
  VALUES (p_persona_id, auth.uid(), v_data, p->>'contesto', p->>'obiettivo', p->>'interesse', p->>'aree_miglioramento',
    (p->>'socializzazione')::smallint, p->>'socializzazione_nota', (p->>'fiducia')::smallint, p->>'fiducia_nota',
    (p->>'autostima')::smallint, p->>'autostima_nota', (p->>'concentrazione')::smallint, p->>'concentrazione_nota',
    (p->>'gestione_paura')::smallint, p->>'gestione_paura_nota', p->>'note',
    p->>'temi_affrontati', p->>'criticita', p->>'trasformazione', p->>'da_implementare', p->>'per_allievo',
    coalesce((p->>'visibile_allievo')::boolean, false))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'data',v_data,'precedenti_oggi',v_prima);
END $function$;

CREATE OR REPLACE VIEW public.v_mio_diario_didattico AS
 SELECT o.id,
    o.data,
    o.contesto,
    o.temi_affrontati,
    o.trasformazione,
    o.per_allievo,
    COALESCE(i.nome, 'Istruttore'::text) AS istruttore,
    o.created_at AS scritta_alle
   FROM osservazioni_allievo o
     JOIN profile_data pd ON pd.persona_id = o.persona_id
     LEFT JOIN istruttori i ON i.user_id = o.istruttore_user_id
  WHERE pd.user_id = auth.uid() AND o.visibile_allievo = true AND o.contesto IS DISTINCT FROM 'sala_monitor'::text
  ORDER BY o.data DESC, o.created_at DESC;

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

-- 6. l'allievo (Bognanni ha un login) nel suo diario riceve tutte le versioni visibili dello stesso giorno, con ora e istruttore:
--    la pagina mostra l'ultima e, toccandola, lo storico dalla prima all'ultima
DO $$ DECLARE k int; b uuid := 'dfed419c-0a19-4cd6-a18e-bdb702a6c5da'; BEGIN
  PERFORM pg_temp.come('27b04151-93a7-4ecc-824c-fe337cc631a6');
  PERFORM salva_osservazione(b, '{"contesto":"open","temi_affrontati":"Kata 3","per_allievo":"Prima stesura per te","visibile_allievo":true}'::jsonb);
  PERFORM salva_osservazione(b, '{"contesto":"open","temi_affrontati":"Kata 3 e 4","per_allievo":"Seconda stesura per te","visibile_allievo":true}'::jsonb);
  PERFORM pg_temp.come('1036fea7-26b2-4fd1-878a-0957403c43c9');
  SELECT count(*) INTO k FROM v_mio_diario_didattico WHERE data = CURRENT_DATE AND scritta_alle IS NOT NULL AND istruttore IS NOT NULL
     AND per_allievo IN ('Prima stesura per te','Seconda stesura per te');
  INSERT INTO esiti VALUES (DEFAULT, '6 diario dell''allievo: le due versioni visibili, con ora e istruttore', k = 2, k || ' versioni lette da Bognanni');
END $$;

-- 5. impianto: indice unico non di sala tolto, quello di sala resta; il diario dell'allievo ha l'ora
INSERT INTO esiti (prova, ok, dettaglio)
SELECT '5 indici e diario dell''allievo',
  NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'osservazioni_allievo_oss_giorno_key')
  AND EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'osservazioni_allievo_sala_giorno_key')
  AND EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'v_mio_diario_didattico' AND column_name = 'scritta_alle'),
  'ok';

SELECT n, prova, CASE WHEN ok THEN 'OK' ELSE 'NO' END AS esito, dettaglio FROM esiti ORDER BY n;

ROLLBACK;
