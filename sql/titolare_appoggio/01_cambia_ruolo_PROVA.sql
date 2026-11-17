-- sql/titolare_appoggio/01 · PROVA: BEGIN → foto dei compensi → corpo della 01 → verifiche → ROLLBACK.
-- Non lascia niente nel DB. Claudia 64a7b65e…, Mattia bc680f11…, assistente 74e18cc7…, Roberta (segreteria) 1425639b….
-- Lezioni: giovedì 12/11 Corso Ragazzi 18:00 (Claudia 770d40e7…, Mattia ebe8ad8f…, entrambi conduce);
-- lunedì 9/11 Corso Bambini 17:00 (Mattia 09a56241…, oltre i 7 giorni dal 17/11). Ogni caso si annulla da solo.
BEGIN;
CREATE TEMP TABLE foto_comp AS SELECT * FROM v_compenso_lezioni;
CREATE TEMP TABLE esiti (n serial, prova text, ok boolean, dettaglio text);
CREATE FUNCTION pg_temp.come(u uuid) RETURNS void LANGUAGE sql AS
  $$ SELECT set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true) $$;

-- ↓↓↓ corpo di 01_cambia_ruolo_2026-11-17.sql (copiato senza commenti)
CREATE OR REPLACE FUNCTION public.impegno_cambia_ruolo(p_impegno_id uuid, p_ruolo text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  i public.impegni_staff;
  v_tipo_corso text;
  v_oggi date := (now() at time zone 'Europe/Rome')::date;
begin
  if auth.uid() is null or not public.is_staff() then raise exception 'solo staff'; end if;
  if p_ruolo is null or p_ruolo not in ('conduce','supporto') then
    raise exception 'ruolo non valido: conduce (titolare) o supporto (d''appoggio)';
  end if;
  select * into i from public.impegni_staff where id = p_impegno_id for update;
  if not found then raise exception 'impegno non trovato'; end if;
  if i.tipo <> 'lezione' then raise exception 'il ruolo si cambia solo sulle lezioni dei corsi'; end if;
  if i.stato = 'ritirato' then raise exception 'questo impegno è stato ritirato'; end if;
  if not public.is_segreteria() then
    if i.user_id is distinct from auth.uid() then raise exception 'puoi cambiare solo il tuo ruolo'; end if;
    if not exists (select 1 from public.profile_data where user_id = auth.uid() and staff_role like 'staff_istruttore%') then
      raise exception 'titolare o d''appoggio vale solo per gli istruttori';
    end if;
    select tipo_corso into v_tipo_corso from public.corsi_attivi_settimanali where id = i.slot_id;
    if v_tipo_corso is null or v_tipo_corso not in ('bambini','evo_ragazzi') or i.data < date '2026-11-01' then
      raise exception 'in questo corso non c''è titolare o d''appoggio';
    end if;
    if i.data < v_oggi - 7 then
      raise exception 'il ruolo si cambia fino a 7 giorni indietro: per le lezioni più vecchie chiedi alla segreteria';
    end if;
  end if;
  if i.ruolo is distinct from p_ruolo then
    update public.impegni_staff set ruolo = p_ruolo, updated_at = now() where id = i.id;
  end if;
  return jsonb_build_object('ok', true, 'id', i.id, 'data', i.data, 'ruolo', p_ruolo, 'ruolo_prima', i.ruolo,
                            'd_appoggio', public._istruttore_da_assistente(i.id));
end $function$;
REVOKE ALL ON FUNCTION public.impegno_cambia_ruolo(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.impegno_cambia_ruolo(uuid, text) TO authenticated, service_role;
-- ↑↑↑ fine corpo

-- 0. la sola creazione della funzione non cambia nessun compenso
INSERT INTO esiti(prova, ok, dettaglio)
SELECT '0 compensi invariati', count(*) = 0, count(*) || ' righe diverse'
  FROM ((SELECT * FROM foto_comp EXCEPT ALL SELECT * FROM v_compenso_lezioni)
        UNION ALL (SELECT * FROM v_compenso_lezioni EXCEPT ALL SELECT * FROM foto_comp)) d;

-- 1. Mattia si mette d'appoggio sul Corso Ragazzi del 12/11 (5 giorni fa): passa, Claudia resta titolare
DO $$ DECLARE r jsonb; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.come('bc680f11-8f0f-4d4f-bc46-1bec466f4d36');
    r := impegno_cambia_ruolo('ebe8ad8f-b4ad-486c-9b01-36b900356d4c', 'supporto');
    ok := (SELECT ruolo FROM impegni_staff WHERE id = 'ebe8ad8f-b4ad-486c-9b01-36b900356d4c') = 'supporto'
      AND _istruttore_da_assistente('ebe8ad8f-b4ad-486c-9b01-36b900356d4c')
      AND NOT _istruttore_da_assistente('770d40e7-a6ed-4558-8649-2cc57accf46f')
      AND (SELECT stato || compenso_tipo FROM impegni_staff WHERE id = 'ebe8ad8f-b4ad-486c-9b01-36b900356d4c') = 'presentelezione';
    det := r::text;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := SQLERRM; END IF; END;
  INSERT INTO esiti(prova, ok, dettaglio) VALUES ('1 Mattia d''appoggio il 12/11', ok, det);
END $$;

-- 2. Claudia si mette d'appoggio sul 12/11 e Mattia resta titolare: ora il d'appoggio è lei
DO $$ DECLARE r jsonb; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.come('64a7b65e-dd7f-4012-a120-47e8ea486a42');
    r := impegno_cambia_ruolo('770d40e7-a6ed-4558-8649-2cc57accf46f', 'supporto');
    ok := _istruttore_da_assistente('770d40e7-a6ed-4558-8649-2cc57accf46f')
      AND NOT _istruttore_da_assistente('ebe8ad8f-b4ad-486c-9b01-36b900356d4c');
    det := r::text;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := SQLERRM; END IF; END;
  INSERT INTO esiti(prova, ok, dettaglio) VALUES ('2 Claudia d''appoggio il 12/11', ok, det);
END $$;

-- 3-7. casi rifiutati: devono dare errore e non cambiare niente
CREATE FUNCTION pg_temp.rifiuto(prova text, chi uuid, imp uuid, ruolo text, atteso text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE prima text; dopo text; msg text := null; BEGIN
  SELECT ruolo INTO prima FROM impegni_staff WHERE id = imp;
  BEGIN
    IF chi IS NULL THEN PERFORM set_config('request.jwt.claims', '', true); ELSE PERFORM pg_temp.come(chi); END IF;
    PERFORM impegno_cambia_ruolo(imp, ruolo);
  EXCEPTION WHEN raise_exception THEN msg := SQLERRM; END;
  SELECT ruolo INTO dopo FROM impegni_staff WHERE id = imp;
  INSERT INTO esiti(prova, ok, dettaglio)
  VALUES (prova, msg IS NOT NULL AND msg LIKE '%' || atteso || '%' AND prima IS NOT DISTINCT FROM dopo, coalesce(msg, 'NESSUN ERRORE'));
END $$;
SELECT pg_temp.rifiuto('3 Mattia sul ruolo di Claudia', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', '770d40e7-a6ed-4558-8649-2cc57accf46f', 'supporto', 'solo il tuo ruolo');
SELECT pg_temp.rifiuto('4 Mattia il 9/11 (8 giorni fa)', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', '09a56241-c84d-4945-85a2-e9100cd320ae', 'supporto', '7 giorni');
SELECT pg_temp.rifiuto('5 assistente sul proprio impegno', '74e18cc7-7fa5-4e09-88c9-9687f43b7298', '34c3084e-b3a6-4081-add1-d2e2dc74e082', 'conduce', 'solo per gli istruttori');
SELECT pg_temp.rifiuto('6 ruolo non valido', 'bc680f11-8f0f-4d4f-bc46-1bec466f4d36', 'ebe8ad8f-b4ad-486c-9b01-36b900356d4c', 'assistente', 'ruolo non valido');
SELECT pg_temp.rifiuto('7 senza login', NULL, 'ebe8ad8f-b4ad-486c-9b01-36b900356d4c', 'supporto', 'solo staff');
SELECT pg_temp.rifiuto('8 impegno ritirato (Giammarco 12/11)', '77335928-3073-42ae-a327-fc2774d1d966', '7ddbba69-5b18-480e-9666-89a9d5a3ca3e', 'supporto', 'ritirato');

-- 9. la segreteria cambia anche il 9/11, oltre i 7 giorni
DO $$ DECLARE r jsonb; ok boolean; det text; BEGIN
  BEGIN
    PERFORM pg_temp.come('1425639b-da30-4a1a-af18-e1853c3bb286');
    r := impegno_cambia_ruolo('09a56241-c84d-4945-85a2-e9100cd320ae', 'supporto');
    ok := (SELECT ruolo FROM impegni_staff WHERE id = '09a56241-c84d-4945-85a2-e9100cd320ae') = 'supporto';
    det := r::text;
    RAISE EXCEPTION 'kc_annulla';
  EXCEPTION WHEN raise_exception THEN IF SQLERRM <> 'kc_annulla' THEN ok := false; det := SQLERRM; END IF; END;
  INSERT INTO esiti(prova, ok, dettaglio) VALUES ('9 segreteria il 9/11', ok, det);
END $$;

-- 10. permessi: anon non può chiamarla
INSERT INTO esiti(prova, ok, dettaglio)
SELECT '10 anon senza permesso', NOT has_function_privilege('anon', 'public.impegno_cambia_ruolo(uuid,text)', 'EXECUTE')
       AND has_function_privilege('authenticated', 'public.impegno_cambia_ruolo(uuid,text)', 'EXECUTE'), '';

SELECT n, prova, ok, dettaglio FROM esiti ORDER BY n;
ROLLBACK;
