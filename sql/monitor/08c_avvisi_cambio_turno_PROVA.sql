-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08c · PROVA: BEGIN → 08 (turni dichiarati, non ancora applicata) → 08c (avvisi) → verifiche → ROLLBACK
-- Generato da: 08_turni_dichiarati_2026-11-09.sql + 08c_avvisi_cambio_turno_2026-11-09.sql + 08c_avvisi_cambio_turno_verifiche.sql
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;
-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08 · TURNI MONITOR DICHIARATI PRIMA + CAMBIO TURNO CON ACCETTAZIONE (consegna v1, 9 nov 2026)
-- MIGRAZIONE. Da applicare SOLO dopo il "vai" di Marco (apply_migration "monitor_turni_dichiarati").
-- La prova (BEGIN → questo corpo → verifiche → ROLLBACK) è in 08_turni_dichiarati_PROVA.sql.
--
-- Regole di Marco (9 nov 2026):
--  1. il turno monitor si dichiara PRIMA, a ore intere: lun–ven dentro 19–22, sabato dentro 14–18;
--  2. aprire il turno sul portale vale solo come presenza: senza turno dichiarato non si apre e non si paga;
--  3. Marco e la segreteria vedono i turni dichiarati e li annullano (stato ritirato + nota, mai DELETE);
--  4. compenso: ore del turno DICHIARATO a 5 €; diventano 8 € tante ore quante le persone diverse seguite
--     e annotate (mai più delle ore del turno). Veterani/Expert/Sala Veterani a 5 € (monitor_seguito_a_5).
--     L'orario di chiusura non conta più;
--  5. cambio turno: chi lascia propone, chi prende accetta; finché non accetta il turno resta del primo;
--  6. un solo monitor alla volta: i passaggi a metà sera sono due turni dichiarati di seguito.
--
-- DATA DI ATTIVAZIONE: monitor_regola_dal(). Prima di quella data resta TUTTO come prima (apertura libera,
-- ore dai minuti, compensi identici: per il passato vale il foglio cartaceo della segreteria).
-- >>> Mettere il giorno DOPO il COMMIT, così gli istruttori hanno il tempo di dichiarare. <<<
--
-- Scelta "o equivalente" per il turno ceduto: l'impegno originale passa a stato 'ritirato' con la nota
-- "ceduto a X, accettato il …" e il passaggio completo resta in cambi_turno_monitor. Uno stato nuovo
-- 'ceduto' avrebbe obbligato a cambiare tutti i filtri "stato <> 'ritirato'" di pagine e funzioni.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 0. Costante leggibile: da quando vale la regola nuova ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_regola_dal()
 RETURNS date LANGUAGE sql IMMUTABLE
AS $$ SELECT date '2026-11-11' $$;  -- giorno dopo il COMMIT (decisione Marco 9 nov 2026)
COMMENT ON FUNCTION public.monitor_regola_dal() IS
  'Da questa data i turni monitor si pagano solo se dichiarati prima (consegna 9 nov 2026). Prima: regola vecchia, compensi invariati.';

-- ── 1. Aiuti ─────────────────────────────────────────────────────────────────────────────────────
-- fascia della Sala con Monitor per giorno: lun–ven 19–22, sabato 14–18, domenica nulla
CREATE OR REPLACE FUNCTION public.monitor_fascia(p_data date, OUT ini time, OUT fin time)
 LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN extract(isodow FROM p_data) BETWEEN 1 AND 5 THEN time '19:00'
              WHEN extract(isodow FROM p_data) = 6 THEN time '14:00' END,
         CASE WHEN extract(isodow FROM p_data) BETWEEN 1 AND 5 THEN time '22:00'
              WHEN extract(isodow FROM p_data) = 6 THEN time '18:00' END
$$;

CREATE OR REPLACE FUNCTION public._ts_roma(p_data date, p_ora time)
 RETURNS timestamptz LANGUAGE sql IMMUTABLE
AS $$ SELECT (p_data + p_ora) AT TIME ZONE 'Europe/Rome' $$;

CREATE OR REPLACE FUNCTION public._nome_staff(p_user uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT COALESCE((SELECT NULLIF(trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),'')
                     FROM profile_data pd LEFT JOIN persone pe ON pe.id = pd.persona_id
                    WHERE pd.user_id = p_user LIMIT 1), 'collega')
$$;

-- l'impegno monitor dichiarato che copre adesso (apribile fino a 15 minuti prima dell'inizio)
CREATE OR REPLACE FUNCTION public._monitor_impegno_adesso(p_user uuid)
 RETURNS public.impegni_staff LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT i.* FROM impegni_staff i
   WHERE i.user_id = p_user AND i.tipo = 'monitor' AND i.data = CURRENT_DATE
     AND i.stato IN ('previsto','presente')
     AND now() >= _ts_roma(i.data, i.ora_inizio) - interval '15 minutes'
     AND now() <  _ts_roma(i.data, i.ora_fine)
   ORDER BY i.ora_inizio LIMIT 1
$$;

-- il messaggio per chi prova ad aprire senza turno dichiarato: dice cosa fare, non solo che non si può
CREATE OR REPLACE FUNCTION public._monitor_msg_non_dichiarato(p_user uuid)
 RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT COALESCE(
    (SELECT 'Il tuo turno monitor di oggi è dalle ' || to_char(i.ora_inizio,'HH24:MI') || ' alle ' || to_char(i.ora_fine,'HH24:MI')
            || ': lo apri da 15 minuti prima dell''inizio.'
       FROM impegni_staff i
      WHERE i.user_id = p_user AND i.tipo = 'monitor' AND i.data = CURRENT_DATE AND i.stato IN ('previsto','presente')
        AND _ts_roma(i.data, i.ora_inizio) - interval '15 minutes' > now()
      ORDER BY i.ora_inizio LIMIT 1),
    'Non hai un turno monitor dichiarato adesso. I turni si dichiarano prima, nella pagina Turni (Turni monitor): scegli il giorno e le ore. Se sei in sala per un imprevisto, avvisa la segreteria.')
$$;

-- ── 2. Stato del turno ceduto e tabella dei cambi ────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.cambi_turno_monitor (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  impegno_id       uuid NOT NULL REFERENCES public.impegni_staff(id),
  da_user_id       uuid NOT NULL REFERENCES auth.users(id),
  a_user_id        uuid REFERENCES auth.users(id),          -- NULL = proposto a chiunque dello staff
  stato            text NOT NULL DEFAULT 'proposta' CHECK (stato IN ('proposta','accettata','rifiutata','ritirata')),
  nota             text,
  creato_il        timestamptz NOT NULL DEFAULT now(),
  risposto_il      timestamptz,
  risposto_da      uuid REFERENCES auth.users(id),
  nota_risposta    text,
  nuovo_impegno_id uuid REFERENCES public.impegni_staff(id)
);
CREATE UNIQUE INDEX IF NOT EXISTS cambi_turno_monitor_una_aperta ON public.cambi_turno_monitor (impegno_id) WHERE stato = 'proposta';
CREATE INDEX IF NOT EXISTS cambi_turno_monitor_a_idx ON public.cambi_turno_monitor (a_user_id) WHERE stato = 'proposta';
ALTER TABLE public.cambi_turno_monitor ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cambi_turno_monitor_staff_legge ON public.cambi_turno_monitor;
CREATE POLICY cambi_turno_monitor_staff_legge ON public.cambi_turno_monitor FOR SELECT TO authenticated USING (is_staff());
REVOKE ALL ON public.cambi_turno_monitor FROM anon;
COMMENT ON TABLE public.cambi_turno_monitor IS 'Proposte di cambio turno monitor: chi lascia propone, chi prende accetta (consegna 9 nov 2026). Si scrive solo via RPC.';

-- se il turno viene tolto, annullato o segnato assente, le proposte aperte si chiudono da sole
CREATE OR REPLACE FUNCTION public._cambi_chiudi_se_tolto()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF NEW.tipo = 'monitor' AND NEW.stato IN ('ritirato','assente') AND OLD.stato IS DISTINCT FROM NEW.stato THEN
    UPDATE cambi_turno_monitor SET stato = 'ritirata', risposto_il = now(),
           nota_risposta = coalesce(nota_risposta || ' · ', '') || 'turno tolto o annullato'
     WHERE impegno_id = NEW.id AND stato = 'proposta';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_cambi_chiudi_se_tolto ON public.impegni_staff;
CREATE TRIGGER trg_cambi_chiudi_se_tolto AFTER UPDATE OF stato ON public.impegni_staff
  FOR EACH ROW EXECUTE FUNCTION public._cambi_chiudi_se_tolto();

-- ── 3. I turni monitor si scrivono SOLO dalle RPC (prima ognuno poteva inserire o allungare la propria riga) ──
DROP POLICY IF EXISTS impegni_staff_insert_self ON public.impegni_staff;
CREATE POLICY impegni_staff_insert_self ON public.impegni_staff FOR INSERT TO authenticated
  WITH CHECK (is_staff() AND user_id = auth.uid() AND tipo <> 'monitor');
DROP POLICY IF EXISTS impegni_staff_update_self ON public.impegni_staff;
CREATE POLICY impegni_staff_update_self ON public.impegni_staff FOR UPDATE TO authenticated
  USING (is_staff() AND user_id = auth.uid() AND tipo <> 'monitor')
  WITH CHECK (user_id = auth.uid() AND tipo <> 'monitor');
DROP POLICY IF EXISTS impegni_staff_delete_self ON public.impegni_staff;
CREATE POLICY impegni_staff_delete_self ON public.impegni_staff FOR DELETE TO authenticated
  USING (is_staff() AND user_id = auth.uid() AND stato = 'previsto' AND tipo <> 'monitor');

-- ── 4. A. Dichiarare il turno ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_dichiara_turno(p_data date, p_ora_inizio time, p_ora_fine time,
                                                         p_user_id uuid DEFAULT NULL, p_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE v_user uuid := coalesce(p_user_id, auth.uid()); v_ini time; v_fin time; v_id uuid; v_chi text; v_note text;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF v_user IS DISTINCT FROM auth.uid() AND NOT is_segreteria() THEN
    RAISE EXCEPTION 'Il turno monitor lo dichiari tu, per te. Per conto di un collega lo fa solo la segreteria, nei casi eccezionali.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profile_data WHERE user_id = v_user AND staff_role IS NOT NULL) THEN
    RAISE EXCEPTION 'Questa persona non è nello staff.';
  END IF;
  IF p_data IS NULL OR p_ora_inizio IS NULL OR p_ora_fine IS NULL THEN RAISE EXCEPTION 'Scegli il giorno e le ore del turno.'; END IF;
  SELECT f.ini, f.fin INTO v_ini, v_fin FROM monitor_fascia(p_data) f;
  IF v_ini IS NULL THEN RAISE EXCEPTION 'La domenica la Sala con Monitor è chiusa: scegli un giorno da lunedì a sabato.'; END IF;
  IF date_part('minute', p_ora_inizio) <> 0 OR date_part('second', p_ora_inizio) <> 0
     OR date_part('minute', p_ora_fine) <> 0 OR date_part('second', p_ora_fine) <> 0 THEN
    RAISE EXCEPTION 'Il turno si dichiara a ore intere (per esempio dalle 19:00 alle 21:00).';
  END IF;
  IF p_ora_fine <= p_ora_inizio THEN RAISE EXCEPTION 'L''ora di fine viene dopo quella di inizio.'; END IF;
  IF p_ora_inizio < v_ini OR p_ora_fine > v_fin THEN
    RAISE EXCEPTION 'Quel giorno la Sala con Monitor va dalle % alle %: scegli ore dentro questa fascia.',
      to_char(v_ini,'HH24:MI'), to_char(v_fin,'HH24:MI');
  END IF;
  IF _ts_roma(p_data, p_ora_inizio) <= now() THEN
    RAISE EXCEPTION 'Il turno si dichiara prima che inizi: il %/% alle % è già passato. Se sei in sala adesso senza turno, avvisa la segreteria.',
      extract(day FROM p_data)::int, extract(month FROM p_data)::int, to_char(p_ora_inizio,'HH24:MI');
  END IF;
  IF staff_indisponibile(v_user, p_data, p_ora_inizio, p_ora_fine) THEN
    RAISE EXCEPTION 'Il %/% è segnato "non ci sono": se adesso puoi esserci, prima togli il "non ci sono".',
      extract(day FROM p_data)::int, extract(month FROM p_data)::int;
  END IF;
  -- un solo monitor alla volta: nessuna sovrapposizione con un turno già dichiarato (di chiunque)
  PERFORM pg_advisory_xact_lock(hashtext('monitor_dichiara_' || p_data::text));
  SELECT string_agg(_nome_staff(i.user_id) || ' ' || to_char(i.ora_inizio,'HH24:MI') || '–' || to_char(i.ora_fine,'HH24:MI'), ', ' ORDER BY i.ora_inizio)
    INTO v_chi
    FROM impegni_staff i
   WHERE i.tipo = 'monitor' AND i.data = p_data AND i.stato IN ('previsto','presente')
     AND i.ora_inizio < p_ora_fine AND i.ora_fine > p_ora_inizio;
  IF v_chi IS NOT NULL THEN
    RAISE EXCEPTION 'In quelle ore c''è già un monitor dichiarato (%). In sala c''è un monitor alla volta: scegli le ore libere, oppure chiedi a chi ha il turno di proportelo.', v_chi;
  END IF;

  v_note := nullif(trim(coalesce(p_note,'')), '');
  IF v_user <> auth.uid() THEN
    v_note := concat_ws(' · ', 'dichiarato da ' || _nome_staff(auth.uid()) || ' il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI'), v_note);
  END IF;

  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note)
  VALUES (v_user, 'monitor', NULL, p_data, p_ora_inizio, p_ora_fine, 'monitor', 'previsto', auth.uid(), v_note)
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = 'previsto', ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da,
                presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, 'dichiarato di nuovo il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI'), excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'data', p_data, 'ora_inizio', p_ora_inizio, 'ora_fine', p_ora_fine);
END $$;

-- impegno_mi_segno: il ramo monitor passa dalle stesse verifiche (turni.html e portale lo chiamano già)
CREATE OR REPLACE FUNCTION public.impegno_mi_segno(p_tipo text, p_slot_id uuid DEFAULT NULL::uuid, p_data date DEFAULT NULL::date, p_ora_inizio time without time zone DEFAULT NULL::time without time zone, p_ora_fine time without time zone DEFAULT NULL::time without time zone, p_ruolo text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare v_user uuid := coalesce(p_user_id, auth.uid()); v_id uuid; v_data date; v_ini time; v_fin time; v_ruolo text; v_n int; v_comp text := 'lezione';
begin
  if not public.is_staff() then raise exception 'solo staff'; end if;
  if v_user <> auth.uid() and not public.is_segreteria() then raise exception 'solo la segreteria segna gli altri'; end if;
  if p_tipo = 'monitor' then
    -- 9 nov 2026: turno monitor = turno dichiarato prima, a ore intere, dentro la fascia, senza sovrapposizioni
    return public.monitor_dichiara_turno(p_data, p_ora_inizio, p_ora_fine, p_user_id, p_note);
  elsif p_tipo = 'lezione' then
    if p_slot_id is null then raise exception 'slot mancante'; end if;
    select coalesce(data_evento, p_data), ora_inizio, ora_fine into v_data, v_ini, v_fin from public.corsi_attivi_settimanali where id = p_slot_id;
    if v_data is null then raise exception 'slot senza data: indica p_data'; end if;
    v_ruolo := coalesce(p_ruolo, 'supporto');
    if v_ruolo = 'assistente' then v_ruolo := 'supporto'; v_comp := 'ora'; end if;
    if v_ruolo not in ('conduce','supporto') then raise exception 'ruolo non valido per una lezione'; end if;
    if exists (select 1 from public.profile_data where user_id = v_user and staff_role = 'staff_assistente') then v_comp := 'ora'; end if;
    if v_comp <> 'ora' then v_comp := public._compenso_tipo_staff(v_user, p_slot_id, v_comp); end if;
  else
    raise exception 'tipo non valido';
  end if;
  if v_data < current_date and not public.is_segreteria() then raise exception 'data nel passato'; end if;
  if public.staff_indisponibile(v_user, v_data, v_ini, v_fin) then
    raise exception 'Il %/% ha segnato che non è disponibile: se adesso può esserci, prima togli il "non ci sono".',
      extract(day from v_data)::int, extract(month from v_data)::int;
  end if;

  insert into public.impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, segnato_da, note, compenso_tipo)
  values (v_user, p_tipo, p_slot_id, v_data, v_ini, v_fin, v_ruolo, auth.uid(), p_note, v_comp)
  on conflict (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  do update set ruolo = excluded.ruolo, compenso_tipo = excluded.compenso_tipo, note = coalesce(excluded.note, impegni_staff.note),
                stato = case when impegni_staff.stato = 'ritirato' then 'previsto' else impegni_staff.stato end,
                segnato_da = excluded.segnato_da, updated_at = now()
  returning id into v_id;

  select count(*) into v_n from public.impegni_staff where data = v_data and ora_inizio = v_ini and stato <> 'ritirato'
    and coalesce(slot_id,'00000000-0000-0000-0000-000000000000'::uuid) = coalesce(p_slot_id,'00000000-0000-0000-0000-000000000000'::uuid);
  return jsonb_build_object('ok', true, 'id', v_id, 'data', v_data, 'ruolo', v_ruolo, 'compenso_tipo', v_comp, 'segnati', v_n);
end $function$;

-- impegno_mi_tolgo: un turno monitor ci si toglie solo prima che inizi (dopo decide la segreteria); resta la nota
CREATE OR REPLACE FUNCTION public.impegno_mi_tolgo(p_impegno_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare r public.impegni_staff;
begin
  select * into r from public.impegni_staff where id = p_impegno_id;
  if not found then raise exception 'impegno non trovato'; end if;
  if r.user_id <> auth.uid() and not public.is_segreteria() then raise exception 'non tuo'; end if;
  if r.stato not in ('previsto','ritirato') then raise exception 'presenza già registrata: non si cancella'; end if;
  if r.data < current_date then raise exception 'data passata'; end if;
  if r.tipo = 'monitor' then
    if not public.is_segreteria() and public._ts_roma(r.data, r.ora_inizio) <= now() then
      raise exception 'Il turno è già iniziato: da qui in poi decide la segreteria.';
    end if;
    update public.impegni_staff set stato = 'ritirato', updated_at = now(),
           note = concat_ws(' · ', note, 'tolto da ' || public._nome_staff(auth.uid()) || ' il ' || to_char(now() at time zone 'Europe/Rome','DD/MM HH24:MI'))
     where id = p_impegno_id and stato <> 'ritirato';
    return jsonb_build_object('ok', true);
  end if;
  update public.impegni_staff set stato = 'ritirato', updated_at = now() where id = p_impegno_id;
  return jsonb_build_object('ok', true);
end $function$;

-- Marco e la segreteria annullano un turno dichiarato: stato ritirato + nota obbligatoria, mai DELETE
CREATE OR REPLACE FUNCTION public.monitor_annulla_turno(p_impegno_id uuid, p_nota text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE r impegni_staff;
BEGIN
  IF auth.uid() IS NULL OR NOT is_segreteria() THEN RAISE EXCEPTION 'Annullare i turni dichiarati tocca a Marco e alla segreteria.'; END IF;
  IF length(trim(coalesce(p_nota,''))) < 3 THEN RAISE EXCEPTION 'Scrivi perché lo annulli: la nota resta nello storico.'; END IF;
  SELECT * INTO r FROM impegni_staff WHERE id = p_impegno_id FOR UPDATE;
  IF NOT FOUND OR r.tipo <> 'monitor' THEN RAISE EXCEPTION 'Turno monitor non trovato.'; END IF;
  IF r.stato = 'ritirato' THEN RAISE EXCEPTION 'Questo turno è già tolto o annullato.'; END IF;
  UPDATE impegni_staff SET stato = 'ritirato', updated_at = now(),
         note = concat_ws(' · ', note, 'annullato da ' || _nome_staff(auth.uid()) || ' il ' || to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI') || ': ' || trim(p_nota))
   WHERE id = p_impegno_id;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ── 5. B. Aprire il turno = presenza su un turno dichiarato ─────────────────────────────────────
-- Una sola funzione apre il turno: la usano monitor_turno('inizio') e monitor_segna.
CREATE OR REPLACE FUNCTION public._monitor_apri_turno()
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r impegni_staff; v_id uuid; v_fine timestamptz;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  -- 9 nov: stesso istante, più chiamate = un turno solo (stasera se n'erano aperti 7 insieme)
  PERFORM pg_advisory_xact_lock(hashtext('monitor_apri_' || auth.uid()::text));
  SELECT id INTO v_id FROM turni_monitor WHERE monitor_user_id = auth.uid() AND data = CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF v_id IS NOT NULL THEN RETURN v_id; END IF;
  v_fine := _sala_fine_oggi();
  IF now() >= v_fine THEN
    RAISE EXCEPTION 'La Sala con Monitor di oggi è finita alle %: il turno non si apre. Se devi aggiungere una nota, usa I miei turni.',
      to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI');
  END IF;
  IF CURRENT_DATE < monitor_regola_dal() THEN          -- regola vecchia fino all'attivazione
    PERFORM chiudi_altri_turni_aperti();
    INSERT INTO turni_monitor (monitor_user_id) VALUES (auth.uid()) RETURNING id INTO v_id;
    RETURN v_id;
  END IF;
  r := _monitor_impegno_adesso(auth.uid());
  IF r.id IS NULL THEN RAISE EXCEPTION '%', _monitor_msg_non_dichiarato(auth.uid()); END IF;
  PERFORM chiudi_altri_turni_aperti();
  -- chiuso per sbaglio e riaperto dentro lo stesso turno dichiarato: si riapre lo stesso, le persone seguite restano lì
  IF r.turno_monitor_id IS NOT NULL AND EXISTS (SELECT 1 FROM turni_monitor WHERE id = r.turno_monitor_id AND data = CURRENT_DATE) THEN
    UPDATE turni_monitor SET fine = NULL,
           note = CASE WHEN note IS NULL OR note = '' THEN '' ELSE note || E'\n' END || '[riaperto alle ' || to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI') || ']'
     WHERE id = r.turno_monitor_id;
    UPDATE impegni_staff SET presenza_fine = NULL, stato = 'presente', updated_at = now() WHERE id = r.id;
    RETURN r.turno_monitor_id;
  END IF;
  INSERT INTO turni_monitor (monitor_user_id) VALUES (auth.uid()) RETURNING id INTO v_id;
  UPDATE impegni_staff SET turno_monitor_id = v_id, stato = 'presente', presenza_inizio = coalesce(presenza_inizio, now()), updated_at = now()
   WHERE id = r.id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION public.monitor_turno(p_azione text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_imp uuid;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT id INTO v_id FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF p_azione='inizio' THEN
    IF v_id IS NOT NULL THEN RETURN jsonb_build_object('ok',true,'turno_id',v_id,'gia_aperto',true); END IF;
    v_id := _monitor_apri_turno();
    SELECT id INTO v_imp FROM impegni_staff WHERE turno_monitor_id = v_id ORDER BY ora_inizio LIMIT 1;
    RETURN jsonb_build_object('ok',true,'turno_id',v_id,'impegno_id',v_imp);
  ELSIF p_azione='fine' THEN
    IF v_id IS NULL THEN RAISE EXCEPTION 'Nessun turno aperto oggi'; END IF;
    UPDATE turni_monitor SET fine=now(), note=COALESCE(p_note,note) WHERE id=v_id;
    UPDATE impegni_staff SET presenza_fine = now(), updated_at = now() WHERE turno_monitor_id = v_id AND presenza_fine IS NULL;
    RETURN jsonb_build_object('ok',true,'turno_id',v_id,'chiuso',true);
  ELSE RAISE EXCEPTION 'Azione non valida'; END IF;
END $function$;

-- monitor_segna apriva un turno da solo se non c'era: ora passa dalla stessa porta (serve il turno dichiarato)
CREATE OR REPLACE FUNCTION public.monitor_segna(p_persona_id uuid, p_su_cosa text, p_note text DEFAULT NULL::text, p_per_allievo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_turno uuid; v_id uuid; v_riga text; v_pa text;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF length(trim(coalesce(p_su_cosa,''))) < 10 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  IF length(trim(coalesce(p_note,''))) < 10 THEN RAISE EXCEPTION 'Scrivi com''è andata'; END IF;
  SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF v_turno IS NULL THEN
    v_turno := _monitor_apri_turno();
  END IF;
  v_riga := to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI')||' — '||trim(p_su_cosa)||' ('||trim(p_note)||')';
  v_id := _sala_annota(v_turno, p_persona_id, now(), v_riga);
  v_pa := nullif(trim(coalesce(p_per_allievo,'')),'');
  IF v_pa IS NOT NULL THEN
    PERFORM quadro_aggiungi(p_persona_id, 'sala_monitor', jsonb_build_array(jsonb_build_object('tipo','per_te','testo',v_pa)));
  END IF;
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',v_turno,'per_allievo',v_pa IS NOT NULL);
END $function$;

-- chiudere il turno di un collega: solo chi ha un turno dichiarato che inizia adesso (es. lui 19–20, tu 20–22)
CREATE OR REPLACE FUNCTION public.chiudi_altri_turni_aperti()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_chi text; v_fine timestamptz := now(); n integer;
BEGIN
  IF CURRENT_DATE >= monitor_regola_dal() AND (_monitor_impegno_adesso(auth.uid())).id IS NULL THEN
    RAISE EXCEPTION 'Chiudi il turno di un collega solo quando inizia il tuo turno dichiarato (per esempio lui 19–20, tu 20–22).';
  END IF;
  SELECT COALESCE(NULLIF(trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),''),'collega') INTO v_chi
    FROM profile_data pd LEFT JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = auth.uid();
  WITH chiusi AS (
    UPDATE turni_monitor t
       SET fine = v_fine,
           note = CASE WHEN t.note IS NULL OR t.note = '' THEN '' ELSE t.note || E'\n' END
                  || '[cambio: chiuso da ' || COALESCE(v_chi,'collega') || ' alle ' || to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI') || ']'
     WHERE t.fine IS NULL AND t.data = CURRENT_DATE AND t.monitor_user_id <> auth.uid()
    RETURNING t.id
  )
  UPDATE impegni_staff i SET presenza_fine = v_fine FROM chiusi c
   WHERE i.turno_monitor_id = c.id AND i.presenza_fine IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

CREATE OR REPLACE FUNCTION public.monitor_cambio_turno(p_turno_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_chi text; v_fine timestamptz := now();
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF CURRENT_DATE >= monitor_regola_dal() AND (_monitor_impegno_adesso(auth.uid())).id IS NULL THEN
    RAISE EXCEPTION 'Chiudi il turno di un collega solo quando inizia il tuo turno dichiarato (per esempio lui 19–20, tu 20–22). Adesso non hai un turno dichiarato.';
  END IF;
  SELECT COALESCE(NULLIF(trim(coalesce(pe.nome,'')||' '||coalesce(pe.cognome,'')),''),'collega') INTO v_chi
    FROM profile_data pd LEFT JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = auth.uid();
  UPDATE turni_monitor t
     SET fine = v_fine,
         note = CASE WHEN t.note IS NULL OR t.note = '' THEN '' ELSE t.note || E'\n' END
                || '[cambio: chiuso da ' || COALESCE(v_chi,'collega') || ' alle ' || to_char(v_fine AT TIME ZONE 'Europe/Rome','HH24:MI') || ']'
   WHERE t.id = p_turno_id AND t.fine IS NULL AND t.data = CURRENT_DATE AND t.monitor_user_id <> auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'Turno non trovato o già chiuso'; END IF;
  UPDATE impegni_staff SET presenza_fine = v_fine WHERE turno_monitor_id = p_turno_id AND presenza_fine IS NULL;
  RETURN jsonb_build_object('ok', true, 'fine', v_fine);
END $function$;

-- ── 6. D. Cambio turno con accettazione ──────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.monitor_proponi_cambio(p_impegno_id uuid, p_a_user_id uuid DEFAULT NULL, p_nota text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE r impegni_staff; v_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  SELECT * INTO r FROM impegni_staff WHERE id = p_impegno_id FOR UPDATE;
  IF NOT FOUND OR r.tipo <> 'monitor' THEN RAISE EXCEPTION 'Turno monitor non trovato.'; END IF;
  IF r.user_id IS DISTINCT FROM auth.uid() THEN RAISE EXCEPTION 'Puoi proporre solo i tuoi turni.'; END IF;
  IF r.stato <> 'previsto' THEN RAISE EXCEPTION 'Questo turno non è più previsto: non si può proporre.'; END IF;
  IF _ts_roma(r.data, r.ora_inizio) <= now() THEN
    RAISE EXCEPTION 'Il turno è già iniziato: il cambio si fa prima. Da adesso decide la segreteria.';
  END IF;
  IF p_a_user_id IS NOT NULL THEN
    IF p_a_user_id = auth.uid() THEN RAISE EXCEPTION 'Scegli un collega, non te.'; END IF;
    IF NOT EXISTS (SELECT 1 FROM profile_data WHERE user_id = p_a_user_id AND staff_role IS NOT NULL) THEN
      RAISE EXCEPTION 'Questa persona non è nello staff.';
    END IF;
    IF staff_indisponibile(p_a_user_id, r.data, r.ora_inizio, r.ora_fine) THEN
      RAISE EXCEPTION '% ha segnato che quel giorno non c''è: scegli un altro collega.', _nome_staff(p_a_user_id);
    END IF;
  END IF;
  BEGIN
    INSERT INTO cambi_turno_monitor (impegno_id, da_user_id, a_user_id, nota)
    VALUES (r.id, auth.uid(), p_a_user_id, nullif(trim(coalesce(p_nota,'')),''))
    RETURNING id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Per questo turno c''è già una proposta aperta: ritirala prima di farne un''altra.';
  END;
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION public.monitor_rispondi_cambio(p_cambio_id uuid, p_accetta boolean, p_nota text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE c cambi_turno_monitor; r impegni_staff; v_new uuid; v_quando text; v_nota text;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF p_accetta IS NULL THEN RAISE EXCEPTION 'Accetti o no?'; END IF;
  SELECT * INTO c FROM cambi_turno_monitor WHERE id = p_cambio_id FOR UPDATE;
  IF NOT FOUND OR c.stato <> 'proposta' THEN RAISE EXCEPTION 'Questa proposta non è più aperta.'; END IF;
  IF c.da_user_id = auth.uid() THEN RAISE EXCEPTION 'È il tuo turno: per toglierla usa RITIRA LA PROPOSTA.'; END IF;
  IF c.a_user_id IS NOT NULL AND c.a_user_id <> auth.uid() THEN RAISE EXCEPTION 'Questa proposta è per un altro collega.'; END IF;
  IF c.a_user_id IS NULL AND NOT p_accetta THEN RAISE EXCEPTION 'Le proposte a tutti non si rifiutano: se non puoi, lasciala lì.'; END IF;
  SELECT * INTO r FROM impegni_staff WHERE id = c.impegno_id FOR UPDATE;
  IF r.stato <> 'previsto' OR r.user_id <> c.da_user_id THEN RAISE EXCEPTION 'Il turno non è più di chi te l''ha proposto.'; END IF;
  IF _ts_roma(r.data, r.ora_inizio) <= now() THEN
    RAISE EXCEPTION 'Il turno è già iniziato: il cambio non si fa più da qui, decide la segreteria.';
  END IF;
  v_nota := nullif(trim(coalesce(p_nota,'')),'');
  IF NOT p_accetta THEN
    UPDATE cambi_turno_monitor SET stato = 'rifiutata', risposto_il = now(), risposto_da = auth.uid(), nota_risposta = v_nota WHERE id = c.id;
    RETURN jsonb_build_object('ok', true, 'accettata', false);
  END IF;
  IF staff_indisponibile(auth.uid(), r.data, r.ora_inizio, r.ora_fine) THEN
    RAISE EXCEPTION 'Quel giorno hai segnato "non ci sono": se adesso puoi esserci, prima togli il "non ci sono".';
  END IF;
  v_quando := to_char(now() AT TIME ZONE 'Europe/Rome','DD/MM HH24:MI');
  -- prima la proposta (così il trigger del turno tolto non la segna "ritirata"), poi il turno
  UPDATE cambi_turno_monitor SET stato = 'accettata', risposto_il = now(), risposto_da = auth.uid(), nota_risposta = v_nota WHERE id = c.id;
  UPDATE impegni_staff SET stato = 'ritirato', updated_at = now(),
         note = concat_ws(' · ', note, 'ceduto a ' || _nome_staff(auth.uid()) || ', accettato il ' || v_quando)
   WHERE id = r.id;
  -- aggiungere, mai sostituire: un impegno nuovo per chi prende
  INSERT INTO impegni_staff (user_id, tipo, slot_id, data, ora_inizio, ora_fine, ruolo, stato, segnato_da, note)
  VALUES (auth.uid(), 'monitor', NULL, r.data, r.ora_inizio, r.ora_fine, 'monitor', 'previsto', auth.uid(),
          'preso da ' || _nome_staff(c.da_user_id) || ' (cambio accettato il ' || v_quando || ')')
  ON CONFLICT (user_id, data, ora_inizio, coalesce(slot_id, '00000000-0000-0000-0000-000000000000'::uuid))
  DO UPDATE SET stato = 'previsto', ora_fine = excluded.ora_fine, segnato_da = excluded.segnato_da,
                presenza_inizio = NULL, presenza_fine = NULL, turno_monitor_id = NULL, updated_at = now(),
                note = concat_ws(' · ', impegni_staff.note, excluded.note)
   WHERE impegni_staff.stato = 'ritirato'
  RETURNING id INTO v_new;
  IF v_new IS NULL THEN RAISE EXCEPTION 'Hai già un turno che inizia a quell''ora.'; END IF;
  UPDATE cambi_turno_monitor SET nuovo_impegno_id = v_new WHERE id = c.id;
  RETURN jsonb_build_object('ok', true, 'accettata', true, 'nuovo_impegno_id', v_new);
END $$;

CREATE OR REPLACE FUNCTION public.monitor_ritira_cambio(p_cambio_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE n int;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  UPDATE cambi_turno_monitor SET stato = 'ritirata', risposto_il = now(), risposto_da = auth.uid()
   WHERE id = p_cambio_id AND stato = 'proposta' AND (da_user_id = auth.uid() OR is_segreteria());
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'Proposta non trovata o già chiusa.'; END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- ── 7. C. Compenso ───────────────────────────────────────────────────────────────────────────────
-- Stesse colonne di prima, nello stesso ordine (v_compenso_monitor_mese, v_segreteria_da_sistemare e le pagine
-- le leggono così), più cinque colonne in fondo. Prima di monitor_regola_dal(): formula identica a prima.
CREATE OR REPLACE VIEW public.v_compenso_turni_monitor AS
 WITH d AS (
         SELECT i.turno_monitor_id AS turno_id,
            (array_agg(i.id ORDER BY i.ora_inizio))[1] AS impegno_id,
            min(i.ora_inizio) AS ora_ini,
            max(i.ora_fine) AS ora_fin,
            bool_or(i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])) AS attivo,
            COALESCE(sum(EXTRACT(epoch FROM i.ora_fine - i.ora_inizio) / 3600.0) FILTER (WHERE i.stato = ANY (ARRAY['previsto'::text, 'presente'::text])), 0::numeric) AS ore_dich
           FROM impegni_staff i
          WHERE i.tipo = 'monitor'::text AND i.turno_monitor_id IS NOT NULL
          GROUP BY i.turno_monitor_id
        ), t AS (
         SELECT tm.id AS turno_id,
            tm.monitor_user_id AS user_id,
            tm.data,
            tm.inizio,
            tm.fine,
            tm.fine IS NULL AS aperto,
                CASE
                    WHEN tm.data < monitor_regola_dal() THEN
                    CASE
                        WHEN tm.fine IS NULL AND tm.data < CURRENT_DATE THEN 0::numeric
                        ELSE round(EXTRACT(epoch FROM COALESCE(tm.fine, now()) - tm.inizio) / 3600.0 * 4::numeric) / 4::numeric
                    END
                    WHEN COALESCE(d.attivo, false) THEN d.ore_dich
                    ELSE 0::numeric
                END AS ore,
            tm.data < monitor_regola_dal() AND tm.fine IS NULL AND tm.data < CURRENT_DATE AS da_chiudere,
                CASE
                    WHEN tm.data < monitor_regola_dal() THEN 'storico'::text
                    WHEN d.turno_id IS NULL THEN 'non_dichiarato'::text
                    WHEN NOT d.attivo THEN 'annullato'::text
                    ELSE 'dichiarato'::text
                END AS regola,
            d.impegno_id,
            d.ora_ini,
            d.ora_fin
           FROM turni_monitor tm
             LEFT JOIN d ON d.turno_id = tm.id
        ), s AS (
         SELECT ts.turno_id,
            count(DISTINCT ts.persona_id) FILTER (WHERE NOT monitor_seguito_a_5(ts.persona_id, tm2.data)) AS persone,
            count(DISTINCT ts.persona_id) FILTER (WHERE monitor_seguito_a_5(ts.persona_id, tm2.data)) AS veterani,
            -- regola nuova: seguite E annotate (riga in osservazioni_allievo, contesto sala_monitor, quel giorno)
            count(DISTINCT ts.persona_id) FILTER (WHERE NOT monitor_seguito_a_5(ts.persona_id, tm2.data)
              AND (EXISTS ( SELECT 1 FROM osservazioni_allievo o
                     WHERE o.persona_id = ts.persona_id AND o.istruttore_user_id = tm2.monitor_user_id
                       AND o.data = tm2.data AND o.contesto = 'sala_monitor'::text AND COALESCE(o.note, ''::text) <> ''::text))) AS persone_annotate
           FROM turni_monitor_seguiti ts
             JOIN turni_monitor tm2 ON tm2.id = ts.turno_id
          GROUP BY ts.turno_id
        ), x AS (
         SELECT t.*,
                CASE WHEN t.regola = 'storico'::text THEN COALESCE(s.persone, 0::bigint)
                     ELSE COALESCE(s.persone_annotate, 0::bigint) END AS p,
            COALESCE(s.veterani, 0::bigint) AS vet
           FROM t
             LEFT JOIN s ON s.turno_id = t.turno_id
        )
 SELECT x.turno_id,
    x.user_id,
    (pe.nome || ' '::text) || COALESCE(pe.cognome, ''::text) AS monitor,
    x.data,
    x.inizio,
    x.fine,
    x.aperto,
    x.ore,
    x.p AS persone_seguite,
    LEAST(x.p::numeric, x.ore) AS ore_a_8,
    GREATEST(x.ore - LEAST(x.p::numeric, x.ore), 0::numeric) AS ore_a_5,
    (LEAST(x.p::numeric, x.ore) * 8::numeric + GREATEST(x.ore - LEAST(x.p::numeric, x.ore), 0::numeric) * 5::numeric)::numeric(8,2) AS compenso_eur,
    x.da_chiudere,
    x.vet AS veterani_seguiti,
    x.regola,
    x.impegno_id,
    x.ora_ini AS ora_inizio_dichiarata,
    x.ora_fin AS ora_fine_dichiarata,
    x.regola = 'non_dichiarato'::text AS da_controllare
   FROM x
     LEFT JOIN profile_data pd ON pd.user_id = x.user_id
     LEFT JOIN persone pe ON pe.id = pd.persona_id
  WHERE is_segreteria() OR x.user_id = auth.uid();

COMMENT ON VIEW public.v_compenso_turni_monitor IS
  'Compenso per turno monitor. regola: storico (prima di monitor_regola_dal, ore dai minuti), dichiarato (ore del turno dichiarato), annullato (0 €), non_dichiarato (0 €, da_controllare = segnalato a Marco).';

-- get_compenso_monitor (tessera Compensi di Oggi): prima dell'attivazione formula identica a prima, dopo legge la vista
CREATE OR REPLACE FUNCTION public.get_compenso_monitor(p_da date, p_a date, p_monitor_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(monitor text, monitor_user_id uuid, data date, inizio timestamp with time zone, fine timestamp with time zone, ore numeric, persone integer, ore_8 integer, ore_5 numeric, importo numeric, aperto boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH t AS (
    SELECT tm.*, COALESCE(pr.nome||' '||pr.cognome,'—') AS nome,
      ROUND(EXTRACT(EPOCH FROM (COALESCE(tm.fine, tm.inizio) - tm.inizio))/3600.0 * 2) / 2 AS ore_calc,
      (SELECT count(*) FROM turni_monitor_seguiti s
        WHERE s.turno_id=tm.id AND NOT monitor_seguito_a_5(s.persona_id, tm.data))::int AS n_pers
    FROM turni_monitor tm LEFT JOIN profiles pr ON pr.user_id=tm.monitor_user_id
    WHERE is_segreteria_piena() AND tm.data BETWEEN p_da AND p_a AND (p_monitor_user_id IS NULL OR tm.monitor_user_id=p_monitor_user_id)
      AND tm.data < monitor_regola_dal()
  )
  SELECT * FROM (
    SELECT nome, monitor_user_id, data, inizio, fine, ore_calc, n_pers,
           LEAST(n_pers, FLOOR(ore_calc))::int, ore_calc - LEAST(n_pers, FLOOR(ore_calc)),
           LEAST(n_pers, FLOOR(ore_calc))*8 + (ore_calc - LEAST(n_pers, FLOOR(ore_calc)))*5, fine IS NULL
    FROM t
    UNION ALL
    SELECT COALESCE(v.monitor,'—'), v.user_id, v.data, v.inizio, v.fine, v.ore, v.persone_seguite::int,
           v.ore_a_8::int, v.ore_a_5, v.compenso_eur::numeric, v.aperto
      FROM v_compenso_turni_monitor v
     WHERE is_segreteria_piena() AND v.data BETWEEN p_da AND p_a AND v.data >= monitor_regola_dal()
       AND (p_monitor_user_id IS NULL OR v.user_id = p_monitor_user_id)
  ) z
  ORDER BY 3 DESC, 4 DESC;
$function$;

-- ── 8. Permessi: niente anon sulle funzioni nuove ────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.monitor_regola_dal() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_fascia(date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._ts_roma(date, time) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._nome_staff(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._monitor_impegno_adesso(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._monitor_msg_non_dichiarato(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._monitor_apri_turno() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._cambi_chiudi_se_tolto() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_dichiara_turno(date, time, time, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_annulla_turno(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_proponi_cambio(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_rispondi_cambio(uuid, boolean, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.monitor_ritira_cambio(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.monitor_regola_dal() TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_fascia(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_dichiara_turno(date, time, time, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_annulla_turno(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_proponi_cambio(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_rispondi_cambio(uuid, boolean, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.monitor_ritira_cambio(uuid) TO authenticated;
GRANT SELECT ON public.cambi_turno_monitor TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08c · AVVISI PUSH/EMAIL DEI CAMBI TURNO MONITOR (consegna v1, 9 nov 2026)
-- MIGRAZIONE. Si applica DOPO la 08 (turni dichiarati) e DOPO il deploy del worker notifiche v3.0.
-- Ordine: worker v3.0 → 08 → 08c → merge delle pagine. Prova: 08c_avvisi_cambio_turno_PROVA.sql (finisce con ROLLBACK).
--
-- Contratto col worker v3.0 (eventi_notifica, stato di default 'da_mandare'):
--   turno.cambio.proposto  → a chi riceve la proposta (Y)        canale both
--   turno.cambio.accettato → a chi ha proposto (X)                canale both (il worker avvisa anche creator + segreteria)
--   turno.cambio.rifiutato → a chi ha proposto (X)                canale both
--   turno.cambio.ritirato  → a Y (anche quando si chiude da sola perché X si toglie o il turno viene annullato)  canale push
--   turno.cambio.scaduto   → a chi ha proposto (X): il turno è iniziato e nessuno ha accettato   canale both
--   payload: {proposta_id, da_nome, a_nome, data 'YYYY-MM-DD', ora_inizio 'HH:MM', ora_fine 'HH:MM', nota}
--   nota = quella di chi propone (proposto) o di chi rifiuta (rifiutato), altrimenti null. Nomi = persone.nome.
--   dedup_key = 'turno-<tipo>-<proposta_id>': un doppio clic non manda due avvisi.
--   schedulato_per = finestra di quiete di tg_lead_richieste_notifica (22:00–07:59 Roma → 08:00), ma subito se il turno è oggi.
--
-- Scelte (da dire a Marco):
--  · Un solo trigger su cambi_turno_monitor invece dell'insert copiato in ogni funzione: copre da solo proposta,
--    accetta, rifiuta, ritira, chiusura automatica (Claudia si toglie / turno annullato) e scadenza, e le funzioni
--    della 08 restano quelle già provate. Dentro BEGIN … EXCEPTION WHEN OTHERS THEN NULL: se l'avviso fallisce il cambio vale.
--  · Proposta "a chiunque" (a_user_id nullo): il contratto vuole un destinatario Y, quindi proposto e ritirato NON
--    partono (resta l'avviso su Oggi e Turni). Accettato/rifiutato/scaduto vanno a X come sempre, con a_nome = chi accetta.
--  · Scaduta: nuovo stato 'scaduta' in cambi_turno_monitor. Le proposte ancora aperte a turno iniziato le chiude
--    _cambi_turno_scaduti(), chiamata da un blocco nuovo (10) di cron_genera_eventi_mattutini. Il blocco si aggiunge alla
--    definizione LIVE del cron (sostituzione di testo controllata, sotto), senza ricopiare a mano i 9 blocchi esistenti.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. stato 'scaduta' ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.cambi_turno_monitor DROP CONSTRAINT IF EXISTS cambi_turno_monitor_stato_check;
ALTER TABLE public.cambi_turno_monitor ADD CONSTRAINT cambi_turno_monitor_stato_check
  CHECK (stato IN ('proposta','accettata','rifiutata','ritirata','scaduta'));

-- ── 2. l'avviso di un cambio, secondo il contratto del worker v3.0 ──────────────────────────────
CREATE OR REPLACE FUNCTION public._cambio_turno_avvisa(p_cambio_id uuid, p_tipo text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE c cambi_turno_monitor; i impegni_staff; v_dest uuid; v_canale text; v_a uuid; v_nota text;
        v_ora int; v_quando timestamptz; v_oggi date := (now() AT TIME ZONE 'Europe/Rome')::date;
BEGIN
  SELECT * INTO c FROM cambi_turno_monitor WHERE id = p_cambio_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO i FROM impegni_staff WHERE id = c.impegno_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- Y: il destinatario della proposta, oppure (proposta a tutti) chi ha risposto
  v_a := coalesce(c.a_user_id, c.risposto_da);
  CASE p_tipo
    WHEN 'proposto'  THEN v_dest := c.a_user_id;  v_canale := 'both'; v_nota := c.nota;
    WHEN 'accettato' THEN v_dest := c.da_user_id; v_canale := 'both';
    WHEN 'rifiutato' THEN v_dest := c.da_user_id; v_canale := 'both'; v_nota := c.nota_risposta;
    WHEN 'ritirato'  THEN v_dest := c.a_user_id;  v_canale := 'push';
    WHEN 'scaduto'   THEN v_dest := c.da_user_id; v_canale := 'both';
    ELSE RETURN NULL;
  END CASE;
  IF v_dest IS NULL THEN RETURN NULL; END IF;   -- proposta a tutti: niente proposto/ritirato (resta su Oggi e Turni)
  -- finestra di quiete come tg_lead_richieste_notifica, ma il turno di oggi si avvisa subito
  IF i.data = v_oggi THEN
    v_quando := now();
  ELSE
    v_ora := date_part('hour', now() AT TIME ZONE 'Europe/Rome')::int;
    IF v_ora >= 22 THEN    v_quando := (v_oggi + 1 + time '08:00') AT TIME ZONE 'Europe/Rome';
    ELSIF v_ora < 8 THEN   v_quando := (v_oggi + time '08:00') AT TIME ZONE 'Europe/Rome';
    ELSE                   v_quando := now();
    END IF;
  END IF;
  RETURN registra_evento_notifica(
    'turno.cambio.' || p_tipo, v_dest, v_canale,
    jsonb_build_object(
      'proposta_id', c.id,
      'da_nome',     (SELECT pe.nome FROM profile_data pd JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = c.da_user_id LIMIT 1),
      'a_nome',      (SELECT pe.nome FROM profile_data pd JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = v_a LIMIT 1),
      'data',        to_char(i.data, 'YYYY-MM-DD'),
      'ora_inizio',  to_char(i.ora_inizio, 'HH24:MI'),
      'ora_fine',    to_char(i.ora_fine, 'HH24:MI'),
      'nota',        v_nota),
    v_quando,
    'turno-' || p_tipo || '-' || c.id);
END $$;

-- ── 3. un trigger per tutti i passaggi della proposta ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_cambi_turno_notifica()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' AND NEW.stato = 'proposta' THEN
      PERFORM _cambio_turno_avvisa(NEW.id, 'proposto');
    ELSIF TG_OP = 'UPDATE' AND NEW.stato IS DISTINCT FROM OLD.stato AND OLD.stato = 'proposta' THEN
      PERFORM _cambio_turno_avvisa(NEW.id, CASE NEW.stato
        WHEN 'accettata' THEN 'accettato' WHEN 'rifiutata' THEN 'rifiutato'
        WHEN 'ritirata'  THEN 'ritirato'  WHEN 'scaduta'   THEN 'scaduto' END);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- l'avviso è un di più: se fallisce, il cambio turno vale lo stesso
  END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_cambi_turno_notifica ON public.cambi_turno_monitor;
CREATE TRIGGER trg_cambi_turno_notifica AFTER INSERT OR UPDATE OF stato ON public.cambi_turno_monitor
  FOR EACH ROW EXECUTE FUNCTION public.tg_cambi_turno_notifica();

-- ── 4. scadenza: proposta ancora aperta a turno iniziato → scaduta (il trigger accoda turno.cambio.scaduto) ──
CREATE OR REPLACE FUNCTION public._cambi_turno_scaduti()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE n int;
BEGIN
  UPDATE cambi_turno_monitor c
     SET stato = 'scaduta', risposto_il = now(),
         nota_risposta = coalesce(c.nota_risposta || ' · ', '') || 'scaduta: il turno è iniziato senza che nessuno accettasse'
    FROM impegni_staff i
   WHERE i.id = c.impegno_id AND c.stato = 'proposta'
     AND _ts_roma(i.data, i.ora_inizio) <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ── 5. blocco 10 nel cron che il worker chiama ogni ~10 minuti (aggiunto alla definizione live) ──
DO $do$
DECLARE d text; n0 int;
  a_decl text := E'  v_priv_istr_count  int := 0;\nBEGIN';
  a_ret  text := E'  RETURN jsonb_build_object(\n    ''eseguito_il'', now(),';
  a_fine text := E'''promemoria_privata_istruttore_processati'', v_priv_istr_count\n  );';
BEGIN
  d := pg_get_functiondef('public.cron_genera_eventi_mattutini()'::regprocedure);
  IF position('_cambi_turno_scaduti' IN d) > 0 THEN RAISE NOTICE 'blocco 10 già presente'; RETURN; END IF;
  FOREACH n0 IN ARRAY ARRAY[
      (length(d) - length(replace(d, a_decl, ''))) / length(a_decl),
      (length(d) - length(replace(d, a_ret,  ''))) / length(a_ret),
      (length(d) - length(replace(d, a_fine, ''))) / length(a_fine)] LOOP
    IF n0 <> 1 THEN RAISE EXCEPTION 'cron_genera_eventi_mattutini è cambiato: punto di aggancio non trovato una sola volta. Fermarsi e rileggere la funzione.'; END IF;
  END LOOP;
  d := replace(d, a_decl, E'  v_priv_istr_count  int := 0;\n  v_cambi_scaduti    int := 0;  -- 10) sql/monitor/08c\nBEGIN');
  d := replace(d, a_ret,
    E'  -- 10) CAMBI TURNO MONITOR SCADUTI (sql/monitor/08c, 9 nov 2026): proposta ancora aperta a turno iniziato\n'
    || E'  --     → scaduta, e il trigger di cambi_turno_monitor accoda turno.cambio.scaduto a chi proponeva (dedup_key).\n'
    || E'  --     Se fallisce, gli altri avvisi del giro partono lo stesso.\n'
    || E'  BEGIN\n    v_cambi_scaduti := _cambi_turno_scaduti();\n  EXCEPTION WHEN OTHERS THEN\n    v_cambi_scaduti := -1;\n  END;\n\n'
    || a_ret);
  d := replace(d, a_fine, E'''promemoria_privata_istruttore_processati'', v_priv_istr_count,\n    ''cambi_turno_scaduti'', v_cambi_scaduti\n  );');
  EXECUTE d;
END $do$;

-- ── 6. permessi: funzioni interne, niente anon né authenticated ─────────────────────────────────
REVOKE ALL ON FUNCTION public._cambio_turno_avvisa(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_cambi_turno_notifica() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cambi_turno_scaduti() FROM PUBLIC, anon, authenticated;

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

ROLLBACK;
