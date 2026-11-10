-- sql/monitor/12 · PROVA: BEGIN → foto → 12 → verifiche → ROLLBACK
BEGIN;
CREATE TEMP TABLE foto_quadro AS SELECT id, visibile_allievo, testo FROM quadro_allievo_voci;
CREATE TEMP TABLE foto_oss AS SELECT o.id, md5(o::text) AS impronta FROM osservazioni_allievo o;
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/12 · NOTE PER L'ALLIEVO SOLO DAGLI ISTRUTTORI (Marco, 10 nov 2026)
-- MIGRAZIONE. Dopo la 11. Prova: 12_note_allievo_solo_istruttori_PROVA.sql (BEGIN → corpo → verifiche → ROLLBACK),
-- COMMIT col "vai" di Marco.
--
-- Regole di Marco:
--  1. solo chi è ISTRUTTORE scrive note visibili all'allievo. Istruttori confermati da Marco il 10/11: i ruoli
--     staff_istruttore_jr / _sr (Claudia, Mattia, Giammarco, Mellozzini, il secondo account di Marco), staff_istruttore_tutor
--     (oggi nessuno) e staff_creator (l'account principale di Marco);
--  2. la segreteria scrive solo note di segreteria, mai visibili all'allievo;
--  3. chi non è istruttore (assistenti, monitor) scrive note e report: restano nella scheda per lo staff e contano per il turno
--     (8 € invariati), l'allievo non li vede. Il DB lo impone, non solo la pagina:
--       · osservazione con "visibile all'allievo" da un non istruttore → rifiutata con un messaggio chiaro;
--       · voci del quadro (anche il "per l'allievo" del report di sala) da un non istruttore → salvate SOLO PER LO STAFF
--         (decisione di Marco: "solo staff", non rifiutate);
--  4. note già scritte da non istruttori e visibili all'allievo: tolte dalla sua vista, mai cancellate.
--     Conteggio del 10/11 prima della migrazione: 0 osservazioni, 0 voci del quadro (le 23 voci visibili sono tutte di istruttori).
--
-- Come:
--  · puo_scrivere_allievo(user): la regola in un posto solo;
--  · quadro_allievo_voci.solo_staff (default false) e visibile_allievo (colonna calcolata) = tipo da allievo AND NOT solo_staff:
--    le voci esistenti restano identiche (solo_staff false);
--  · quadro_aggiungi e quadro_aggiungi_da_report scrivono solo_staff = non è istruttore;
--  · salva_osservazione rifiuta visibile_allievo a chi non è istruttore (prima di ogni altro controllo);
--  · la decisione si prende quando la nota è scritta: se un istruttore un giorno cambia ruolo, le sue note restano nel
--    percorso dell'allievo.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.puo_scrivere_allievo(p_user uuid)
 RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM profile_data WHERE user_id = p_user
                     AND staff_role IN ('staff_creator','staff_istruttore_tutor','staff_istruttore_sr','staff_istruttore_jr')) $$;
COMMENT ON FUNCTION public.puo_scrivere_allievo(uuid) IS
  'Marco 10/11/2026: le note visibili all''allievo le scrivono solo gli istruttori (jr, sr, tutor) e il creator. Assistenti, monitor e segreteria scrivono solo per lo staff.';

ALTER TABLE public.quadro_allievo_voci ADD COLUMN IF NOT EXISTS solo_staff boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.quadro_allievo_voci.solo_staff IS 'Voce scritta da chi non è istruttore: resta per lo staff, l''allievo non la vede (Marco 10/11/2026).';
ALTER TABLE public.quadro_allievo_voci ALTER COLUMN visibile_allievo
  SET EXPRESSION AS (tipo = ANY (ARRAY['punti_forza'::text, 'abitudini_da_trasformare'::text, 'kata_da_migliorare'::text, 'per_te'::text]) AND NOT solo_staff);

-- punto 4: quello che un non istruttore avesse già reso visibile esce dalla vista dell'allievo (il 10/11: 0 e 0)
UPDATE public.quadro_allievo_voci SET solo_staff = true
 WHERE NOT solo_staff AND tipo IN ('punti_forza','abitudini_da_trasformare','kata_da_migliorare','per_te')
   AND NOT puo_scrivere_allievo(autore_user_id);
UPDATE public.osservazioni_allievo SET visibile_allievo = false
 WHERE visibile_allievo AND NOT puo_scrivere_allievo(istruttore_user_id);

CREATE OR REPLACE FUNCTION public.quadro_aggiungi(p_persona_id uuid, p_contesto text, p_voci jsonb, p_fine_corso boolean DEFAULT false, p_iscrizione_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE a record; v jsonb; n int := 0; vis int := 0; v_tipo text; v_testo text; v_solo_staff boolean;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  IF p_voci IS NULL OR jsonb_typeof(p_voci) <> 'array' OR jsonb_array_length(p_voci) = 0 THEN
    RAISE EXCEPTION 'Scrivi almeno una voce';
  END IF;
  SELECT * INTO a FROM _quadro_autore(p_contesto);
  v_solo_staff := NOT puo_scrivere_allievo(auth.uid());   -- 10/11: chi non è istruttore scrive solo per lo staff
  FOR v IN SELECT * FROM jsonb_array_elements(p_voci) LOOP
    v_tipo := v->>'tipo'; v_testo := trim(coalesce(v->>'testo',''));
    CONTINUE WHEN v_testo = '';
    INSERT INTO quadro_allievo_voci (persona_id, autore_user_id, autore_nome, ruolo, contesto, iscrizione_id, fine_corso, tipo, kata_num, testo, solo_staff)
    VALUES (p_persona_id, auth.uid(), a.nome, a.ruolo, p_contesto, p_iscrizione_id, coalesce(p_fine_corso,false),
            v_tipo, nullif(v->>'kata_num','')::int, v_testo, v_solo_staff);
    n := n + 1;
    IF v_tipo IN ('punti_forza','abitudini_da_trasformare','kata_da_migliorare','per_te') AND NOT v_solo_staff THEN vis := vis + 1; END IF;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'Scrivi almeno una voce'; END IF;
  RETURN jsonb_build_object('ok',true,'voci',n,'visibili_allievo',vis,'autore',a.nome,'ruolo',a.ruolo,'solo_staff',v_solo_staff);
END $function$;

CREATE OR REPLACE FUNCTION public.quadro_aggiungi_da_report(p_autore_user_id uuid, p_persona_id uuid, p_contesto text, p_voci jsonb, p_report_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v jsonb; n int := 0; vis int := 0; v_tipo text; v_testo text; v_nome text; v_ruolo text; v_sr text; v_solo_staff boolean;
BEGIN
  IF current_user NOT IN ('postgres','service_role') THEN RAISE EXCEPTION 'Solo il sistema'; END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN RAISE EXCEPTION 'Persona non trovata'; END IF;
  SELECT staff_role INTO v_sr FROM profile_data WHERE user_id = p_autore_user_id LIMIT 1;
  IF v_sr IS NULL OR v_sr NOT IN ('staff_creator','staff_istruttore_tutor','staff_istruttore_sr','staff_istruttore_jr','staff_monitor','staff_assistente') THEN
    RAISE EXCEPTION 'Autore non è staff';
  END IF;
  v_ruolo := CASE WHEN v_sr = 'staff_creator' THEN 'maestro' WHEN v_sr = 'staff_monitor' THEN 'monitor' ELSE 'istruttore' END;
  v_solo_staff := NOT puo_scrivere_allievo(p_autore_user_id);   -- 10/11
  SELECT i.nome INTO v_nome FROM istruttori i WHERE i.user_id = p_autore_user_id ORDER BY i.attivo DESC NULLS LAST LIMIT 1;
  IF v_nome IS NULL THEN
    SELECT trim(coalesce(p.nome,'')||' '||coalesce(p.cognome,'')) INTO v_nome
      FROM profile_data pd JOIN persone p ON p.id = pd.persona_id WHERE pd.user_id = p_autore_user_id LIMIT 1;
  END IF;
  v_nome := coalesce(nullif(v_nome,''),'Staff');
  IF p_voci IS NULL OR jsonb_typeof(p_voci) <> 'array' OR jsonb_array_length(p_voci) = 0 THEN RAISE EXCEPTION 'Nessuna voce'; END IF;
  FOR v IN SELECT * FROM jsonb_array_elements(p_voci) LOOP
    v_tipo := v->>'tipo'; v_testo := trim(coalesce(v->>'testo',''));
    CONTINUE WHEN length(v_testo) < 3;
    INSERT INTO quadro_allievo_voci (persona_id, autore_user_id, autore_nome, ruolo, contesto, tipo, kata_num, testo, solo_staff)
    VALUES (p_persona_id, p_autore_user_id, v_nome, v_ruolo, p_contesto, v_tipo, nullif(v->>'kata_num','')::int, v_testo, v_solo_staff);
    n := n + 1;
    IF v_tipo IN ('punti_forza','abitudini_da_trasformare','kata_da_migliorare','per_te') AND NOT v_solo_staff THEN vis := vis + 1; END IF;
  END LOOP;
  IF n = 0 THEN RAISE EXCEPTION 'Nessuna voce'; END IF;
  RETURN jsonb_build_object('ok',true,'voci',n,'visibili_allievo',vis,'autore',v_nome,'ruolo',v_ruolo,'report_id',p_report_id,'solo_staff',v_solo_staff);
END $function$;

CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE); v_turno uuid; v_testo text; v_prima int;
BEGIN
  -- 10/11 (sql/monitor/12): le note visibili all'allievo le scrivono solo gli istruttori; la segreteria mai
  IF coalesce((p->>'visibile_allievo')::boolean, false) AND (auth.uid() IS NULL OR NOT puo_scrivere_allievo(auth.uid())) THEN
    RAISE EXCEPTION 'Le note visibili all''allievo le scrivono solo gli istruttori: salvala senza "Mostra all''allievo", resta per lo staff.';
  END IF;
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
  -- 10 nov 2026 (11): ogni salvataggio è una riga nuova, quella di prima dello stesso giorno resta com'è
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

REVOKE ALL ON FUNCTION public.puo_scrivere_allievo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.puo_scrivere_allievo(uuid) TO authenticated;

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

ROLLBACK;
