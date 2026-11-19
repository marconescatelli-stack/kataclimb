-- ════════════════════════════════════════════════════════════════════
-- sql/giovani/01_giovani_prenotano_2026-11-19.sql
-- I Giovani prenotano la lezione della settimana su Open o Giovani (consegna v1, Marco 19 nov 2026)
--
-- Regola: il Corso Giovani KataClimb (18–24) è un abbonamento mensile (iscrizioni_minori,
-- tipo_abbonamento 'giovani') che comprende UNA lezione a settimana (lun–dom), prenotata
-- dall'agenda sugli orari del Corso Open KataClimb o il giovedì del Corso Giovani; al posto
-- dell'Open il Corso Advance KataClimb quando lo staff lo abilita persona per persona.
--
-- 1. Struttura: prenotazioni_corso.abbonamento_id (NULL per tutte le righe di oggi), tipo
--    'giovani' ammesso, riga 'giovani' in tipi_corso_config, interruttore Advance
--    sull'abbonamento.
-- 2. prenota_con_abbonamento (nuova): allievo per sé, staff per chiunque.
-- 3. Protezioni: le righe dell'abbonamento non toccano crediti, scadenze, corso_attivo,
--    promemoria. Le funzioni esistenti cambiano SOLO nella riga indicata (patch con controllo:
--    il testo da sostituire deve esserci una volta sola, altrimenti tutto si ferma).
-- 4. registra_abbonamento: per 'giovani' niente più giorno fisso obbligatorio.
-- 5. imposta_advance_giovani (staff) e mio_abbonamento_giovani (allievo loggato).
-- prenota_corso NON cambia.
-- ════════════════════════════════════════════════════════════════════

-- Patch puntuale di una funzione esistente: sostituisce p_vecchio con p_nuovo nel corpo vivo
-- (pg_get_functiondef) e la ricrea. Se p_vecchio non c'è esattamente una volta, errore.
CREATE OR REPLACE FUNCTION pg_temp._patch_funzione(p_firma text, p_vecchio text, p_nuovo text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_def text; v_n int;
BEGIN
  v_def := pg_get_functiondef(p_firma::regprocedure);
  v_n := (length(v_def) - length(replace(v_def, p_vecchio, ''))) / length(p_vecchio);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'patch % : testo da sostituire trovato % volte (atteso 1)', p_firma, v_n;
  END IF;
  EXECUTE replace(v_def, p_vecchio, p_nuovo);
END $$;

-- ── 1. STRUTTURA ─────────────────────────────────────────────────────

ALTER TABLE public.prenotazioni_corso
  ADD COLUMN abbonamento_id uuid REFERENCES public.iscrizioni_minori(id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.prenotazioni_corso.abbonamento_id IS
  'Prenotazione fatta con un abbonamento (Corso Giovani KataClimb): non consuma lezioni di nessun corso a pacchetto. NULL = prenotazione di un corso a lezioni.';
CREATE INDEX prenotazioni_corso_abbonamento_idx ON public.prenotazioni_corso (abbonamento_id, data_lezione)
  WHERE abbonamento_id IS NOT NULL;

ALTER TABLE public.prenotazioni_corso DROP CONSTRAINT prenotazioni_corso_tipo_corso_check;
ALTER TABLE public.prenotazioni_corso ADD CONSTRAINT prenotazioni_corso_tipo_corso_check
  CHECK (tipo_corso = ANY (ARRAY['open'::text, 'advance'::text, 'intro_corda'::text, 'evo_corda'::text, 'giovani'::text]));

ALTER TABLE public.tipi_corso_config DROP CONSTRAINT tipi_corso_config_tipo_corso_check;
ALTER TABLE public.tipi_corso_config ADD CONSTRAINT tipi_corso_config_tipo_corso_check
  CHECK (tipo_corso = ANY (ARRAY['open'::text, 'advance'::text, 'intro_corda'::text, 'evo_corda'::text, 'giovani'::text]));
INSERT INTO public.tipi_corso_config (tipo_corso, label, capienza_max, capienza_target, finestra_prenotazione_ore,
  finestra_disdetta_ore, cutoff_marcatura_ore, noshow_soglia_penalita, attivo, apertura_prenotazione_giorni, n_lezioni_pacchetto)
VALUES ('giovani', 'Corso Giovani KataClimb (18–24)', 15, 10, 4, 8, 12, 2, true, 7, NULL);

ALTER TABLE public.iscrizioni_minori
  ADD COLUMN advance_abilitato    boolean NOT NULL DEFAULT false,
  ADD COLUMN advance_abilitato_da uuid,
  ADD COLUMN advance_abilitato_il timestamptz;
COMMENT ON COLUMN public.iscrizioni_minori.advance_abilitato IS
  'Corso Giovani: lo staff ha abilitato la persona a prenotare il Corso Advance KataClimb al posto del Corso Open KataClimb.';

-- ── 2. PRENOTAZIONE CON L'ABBONAMENTO ────────────────────────────────

CREATE OR REPLACE FUNCTION public.prenota_con_abbonamento(p_user_id uuid, p_slot_id uuid, p_data_lezione date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_persona   uuid;
  v_abb       record;
  v_ultimo    record;
  v_slot      record;
  v_config    record;
  v_dt_inizio timestamptz;
  v_capienza  int;
  v_gia       record;
  v_id        uuid;
  v_lun       date;
  v_giorni    text[] := ARRAY['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
BEGIN
  IF auth.uid() IS NULL OR (p_user_id IS DISTINCT FROM auth.uid() AND NOT is_staff()) THEN
    RAISE EXCEPTION 'Puoi prenotare solo per te: entra nel portale con il tuo account.' USING ERRCODE = '42501';
  END IF;
  IF p_data_lezione IS NULL OR p_slot_id IS NULL THEN
    RAISE EXCEPTION 'Scegli la lezione da prenotare.' USING ERRCODE = '23514';
  END IF;

  SELECT persona_id INTO v_persona FROM profile_data WHERE user_id = p_user_id;
  IF v_persona IS NULL THEN
    RAISE EXCEPTION 'Il tuo profilo non risulta completo: scrivi a Marco su WhatsApp.' USING ERRCODE = 'P0002';
  END IF;

  -- abbonamento Giovani che copre la data
  SELECT * INTO v_abb FROM iscrizioni_minori
   WHERE persona_id = v_persona AND tipo_abbonamento = 'giovani' AND status = 'attiva'
     AND data_inizio <= p_data_lezione AND (data_fine IS NULL OR data_fine >= p_data_lezione)
   ORDER BY data_fine DESC NULLS FIRST LIMIT 1;
  IF NOT FOUND THEN
    SELECT * INTO v_ultimo FROM iscrizioni_minori
     WHERE persona_id = v_persona AND tipo_abbonamento = 'giovani' AND status = 'attiva'
     ORDER BY data_fine DESC NULLS FIRST LIMIT 1;
    IF FOUND AND v_ultimo.data_fine IS NOT NULL AND v_ultimo.data_fine < p_data_lezione THEN
      RAISE EXCEPTION 'Il tuo abbonamento vale fino al %: rinnovalo per prenotare questa data.',
        to_char(v_ultimo.data_fine, 'DD/MM') USING ERRCODE = '23514';
    ELSIF FOUND AND v_ultimo.data_inizio > p_data_lezione THEN
      RAISE EXCEPTION 'Il tuo abbonamento parte dal %: scegli una lezione da quel giorno.',
        to_char(v_ultimo.data_inizio, 'DD/MM') USING ERRCODE = '23514';
    END IF;
    RAISE EXCEPTION 'Non hai un Corso Giovani KataClimb (18–24) attivo: paga l''abbonamento dal tuo link per prenotare.'
      USING ERRCODE = '23514';
  END IF;

  -- slot ammessi: giovani + open, oppure giovani + advance se abilitato
  SELECT id, giorno_settimana, ora_inizio, ora_fine, tipo_corso, status
    INTO v_slot FROM corsi_attivi_settimanali WHERE id = p_slot_id;
  IF NOT FOUND OR v_slot.status <> 'attivo' THEN
    RAISE EXCEPTION 'Questa lezione non è più in calendario: scegline un''altra.' USING ERRCODE = 'P0002';
  END IF;
  IF v_slot.tipo_corso = 'open' AND v_abb.advance_abilitato THEN
    RAISE EXCEPTION 'Sei passato al Corso Advance KataClimb: prenota sugli orari del Corso Advance KataClimb o il giovedì del Corso Giovani KataClimb (18–24).'
      USING ERRCODE = '23514';
  ELSIF v_slot.tipo_corso = 'advance' AND NOT v_abb.advance_abilitato THEN
    RAISE EXCEPTION 'Il Corso Advance KataClimb si apre quando gli istruttori ti abilitano: per ora prenota sugli orari del Corso Open KataClimb o il giovedì del Corso Giovani KataClimb (18–24).'
      USING ERRCODE = '23514';
  ELSIF v_slot.tipo_corso NOT IN ('giovani', 'open', 'advance') THEN
    RAISE EXCEPTION 'Con il Corso Giovani KataClimb (18–24) prenoti sugli orari del Corso Open KataClimb o il giovedì del Corso Giovani.'
      USING ERRCODE = '23514';
  END IF;

  -- stesse guardie di prenota_corso: giorno, calendario, chiusura, capienza, doppione
  IF ((EXTRACT(DOW FROM p_data_lezione)::int + 6) % 7) + 1 <> v_slot.giorno_settimana THEN
    RAISE EXCEPTION 'La data scelta non è il giorno di questa lezione: ricarica l''agenda e riprova.' USING ERRCODE = '23514';
  END IF;

  SELECT capienza_max, finestra_prenotazione_ore INTO v_config
    FROM tipi_corso_config WHERE tipo_corso = v_slot.tipo_corso AND attivo = true;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Questa lezione non è prenotabile online: scrivi a Marco su WhatsApp.' USING ERRCODE = 'P0002';
  END IF;

  IF p_data_lezione > (SELECT max(d) FROM calendario_accademia_prossime()) THEN
    RAISE EXCEPTION 'Le prenotazioni per il % non sono ancora aperte: riprova nei prossimi giorni.',
      to_char(p_data_lezione, 'DD/MM') USING ERRCODE = '23514';
  END IF;

  v_dt_inizio := (p_data_lezione + v_slot.ora_inizio) AT TIME ZONE 'Europe/Rome';
  IF v_dt_inizio - now() < make_interval(hours => v_config.finestra_prenotazione_ore) THEN
    RAISE EXCEPTION 'Troppo tardi: la prenotazione chiude % ore prima della lezione. Scegline un''altra.',
      v_config.finestra_prenotazione_ore USING ERRCODE = '23514';
  END IF;

  -- giorni e lezioni chiusi: lo bloccano anche i trigger, qui con un messaggio chiaro
  IF EXISTS (SELECT 1 FROM giorni_chiusi WHERE data = p_data_lezione) THEN
    RAISE EXCEPTION 'L''Accademia è chiusa il %: scegli un''altra lezione.', to_char(p_data_lezione, 'DD/MM') USING ERRCODE = '23514';
  END IF;
  IF EXISTS (SELECT 1 FROM slot_chiusure WHERE slot_id = p_slot_id AND data = p_data_lezione) THEN
    RAISE EXCEPTION 'Il % questa lezione non c''è: scegline un''altra.', to_char(p_data_lezione, 'DD/MM') USING ERRCODE = '23514';
  END IF;

  -- una lezione a settimana (lunedì–domenica): la cancellazione in tempo libera la settimana
  v_lun := date_trunc('week', p_data_lezione)::date;
  SELECT p.data_lezione, s.ora_inizio INTO v_gia
    FROM prenotazioni_corso p JOIN corsi_attivi_settimanali s ON s.id = p.slot_id
   WHERE p.user_id = p_user_id AND p.abbonamento_id IS NOT NULL
     AND p.data_lezione BETWEEN v_lun AND v_lun + 6
     AND p.stato IN ('prenotato', 'presente', 'assente', 'cancellato_tardi')
   ORDER BY p.data_lezione LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Hai già la lezione di questa settimana (% %, %). Per cambiarla, prima disdici quella.',
      v_giorni[EXTRACT(ISODOW FROM v_gia.data_lezione)::int], to_char(v_gia.data_lezione, 'DD/MM'),
      to_char(v_gia.ora_inizio, 'HH24:MI') USING ERRCODE = '23505';
  END IF;

  SELECT count(*) INTO v_capienza FROM prenotazioni_corso
   WHERE slot_id = p_slot_id AND data_lezione = p_data_lezione AND stato IN ('prenotato', 'presente');
  IF v_capienza >= v_config.capienza_max THEN
    RAISE EXCEPTION 'Questa lezione è piena (%/%): scegline un''altra.', v_capienza, v_config.capienza_max
      USING ERRCODE = '23505';
  END IF;

  IF EXISTS (SELECT 1 FROM prenotazioni_corso WHERE user_id = p_user_id AND slot_id = p_slot_id
               AND data_lezione = p_data_lezione AND stato IN ('prenotato', 'presente')) THEN
    RAISE EXCEPTION 'Sei già prenotato a questa lezione.' USING ERRCODE = '23505';
  END IF;

  INSERT INTO prenotazioni_corso (user_id, slot_id, tipo_corso, data_lezione, stato, created_by, created_ruolo, abbonamento_id)
  VALUES (p_user_id, p_slot_id, v_slot.tipo_corso, p_data_lezione, 'prenotato', auth.uid(),
          _ruolo_attore(p_user_id, 'prenota_con_abbonamento'), v_abb.id)
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$function$;
REVOKE ALL ON FUNCTION public.prenota_con_abbonamento(uuid, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.prenota_con_abbonamento(uuid, uuid, date) TO authenticated;

-- ── 3. PROTEZIONI SULLE RIGHE DELL'ABBONAMENTO ───────────────────────

-- contatori_corso: le righe dell'abbonamento non entrano nei conteggi dei corsi a lezioni.
DO $$
DECLARE v_def text; v_old text := E'FROM prenotazioni_corso p\n          GROUP BY p.user_id, p.tipo_corso';
BEGIN
  v_def := pg_get_viewdef('public.contatori_corso'::regclass, true);
  IF (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old) <> 1 THEN
    RAISE EXCEPTION 'patch contatori_corso: testo da sostituire non trovato una volta sola';
  END IF;
  -- security_invoker=true come oggi (reloptions della vista viva)
  EXECUTE 'CREATE OR REPLACE VIEW public.contatori_corso WITH (security_invoker=true) AS ' ||
    replace(v_def, v_old, E'FROM prenotazioni_corso p\n          WHERE p.abbonamento_id IS NULL\n          GROUP BY p.user_id, p.tipo_corso');
END $$;

-- presenza su Open: niente Corso Open creato in automatico per chi prenota con l'abbonamento
SELECT pg_temp._patch_funzione('public._trg_open_presenza_garantisce_corso()',
  E'  IF NEW.tipo_corso <> ''open'' THEN RETURN NEW; END IF;',
  E'  IF NEW.tipo_corso <> ''open'' THEN RETURN NEW; END IF;\n  IF NEW.abbonamento_id IS NOT NULL THEN RETURN NEW; END IF; -- 2026-11-19 Corso Giovani');

-- prima presenza: non sposta le date di un'iscrizione a pacchetto
SELECT pg_temp._patch_funzione('public._tg_prima_presenza_fissa_scadenza()',
  E'  IF NEW.stato IS DISTINCT FROM ''presente'' THEN RETURN NEW; END IF;',
  E'  IF NEW.stato IS DISTINCT FROM ''presente'' THEN RETURN NEW; END IF;\n  IF NEW.abbonamento_id IS NOT NULL THEN RETURN NEW; END IF; -- 2026-11-19 Corso Giovani');

-- onboarding: la prenotazione con l'abbonamento non spegne il promemoria di un corso a pacchetto
SELECT pg_temp._patch_funzione('public.tg_onboarding_spegni_su_prenotazione()',
  E'     AND NEW.stato = ''prenotato'' THEN',
  E'     AND NEW.stato = ''prenotato''\n     AND NEW.abbonamento_id IS NULL THEN -- 2026-11-19 Corso Giovani');

-- appello: le presenze con l'abbonamento non entrano in lezioni_completate di un pacchetto
SELECT pg_temp._patch_funzione('public.marca_presenza_corso(uuid,boolean)',
  E'            AND pc.stato = ''presente''\n        ),',
  E'            AND pc.stato = ''presente''\n            AND pc.abbonamento_id IS NULL -- 2026-11-19 Corso Giovani\n        ),');

-- disdetta: sotto abbonamento nessun limite di disdette in tempo (la disdetta libera la settimana)
SELECT pg_temp._patch_funzione('public.disdici_corso(uuid,text)',
  E'  SELECT id, user_id, slot_id, tipo_corso, data_lezione, stato\n    INTO v_prenot FROM prenotazioni_corso WHERE id = p_prenotazione_id FOR UPDATE;',
  E'  SELECT id, user_id, slot_id, tipo_corso, data_lezione, stato, abbonamento_id\n    INTO v_prenot FROM prenotazioni_corso WHERE id = p_prenotazione_id FOR UPDATE;');
SELECT pg_temp._patch_funzione('public.disdici_corso(uuid,text)',
  E'    IF v_is_allievo THEN\n      -- DEBITO-190',
  E'    IF v_is_allievo AND v_prenot.abbonamento_id IS NULL THEN -- 2026-11-19 Corso Giovani: nessun limite\n      -- DEBITO-190');

-- spostamento diretto: con l'abbonamento si disdice e si riprenota (vale la regola della settimana)
SELECT pg_temp._patch_funzione('public.sposta_corso(uuid,uuid,date)',
  E'  SELECT id, user_id, slot_id, data_lezione, tipo_corso, stato\n    INTO v_prenot',
  E'  SELECT id, user_id, slot_id, data_lezione, tipo_corso, stato, abbonamento_id\n    INTO v_prenot');
SELECT pg_temp._patch_funzione('public.sposta_corso(uuid,uuid,date)',
  E'  IF NOT FOUND THEN RAISE EXCEPTION ''Prenotazione non trovata''; END IF;\n  IF v_prenot.stato NOT IN',
  E'  IF NOT FOUND THEN RAISE EXCEPTION ''Prenotazione non trovata''; END IF;\n  IF v_prenot.abbonamento_id IS NOT NULL THEN -- 2026-11-19 Corso Giovani\n    RAISE EXCEPTION ''Lezione del Corso Giovani KataClimb (18–24): disdici questa e prenota l''''altra dall''''agenda (una lezione a settimana).'' USING ERRCODE = ''23514'';\n  END IF;\n  IF v_prenot.stato NOT IN');

-- prenota_corso_admin: a un Giovane senza corso attivo non si crea un pacchetto in automatico
SELECT pg_temp._patch_funzione('public.prenota_corso_admin(uuid,uuid,date,boolean,text)',
  E'  -- ═══ Auto-setup-corso ═══\n  IF v_profile.corso_attivo IS NULL THEN',
  E'  -- 2026-11-19 Corso Giovani: chi ha l''abbonamento Giovani prenota con prenota_con_abbonamento\n  IF v_profile.corso_attivo IS NULL AND EXISTS (\n       SELECT 1 FROM iscrizioni_minori im JOIN profile_data pd ON pd.persona_id = im.persona_id\n        WHERE pd.user_id = p_user_id AND im.tipo_abbonamento = ''giovani'' AND im.status = ''attiva''\n          AND im.data_inizio <= p_data_lezione AND (im.data_fine IS NULL OR im.data_fine >= p_data_lezione)) THEN\n    RAISE EXCEPTION ''Allievo del Corso Giovani KataClimb (18–24): prenotalo con il suo abbonamento (una lezione a settimana), non con un pacchetto.'' USING ERRCODE = ''23514'';\n  END IF;\n\n  -- ═══ Auto-setup-corso ═══\n  IF v_profile.corso_attivo IS NULL THEN');

-- ── 4. REGISTRA_ABBONAMENTO: GIOVANI SENZA GIORNO FISSO ──────────────
SELECT pg_temp._patch_funzione('public.registra_abbonamento(uuid,text,uuid[],date,date,numeric,text,text)',
  E'  IF NOT v_rinnovo AND coalesce(array_length(t.slot_ammessi,1),0) > 0 AND',
  E'  IF NOT v_rinnovo AND p_tipo <> ''giovani'' AND coalesce(array_length(t.slot_ammessi,1),0) > 0 AND');
SELECT pg_temp._patch_funzione('public.registra_abbonamento(uuid,text,uuid[],date,date,numeric,text,text)',
  E'    INSERT INTO iscrizioni_minori_slot (iscrizione_id, slot_id) SELECT v_id, unnest(p_slot_ids);\n  END IF;\n\n  -- regola Marco 8 ott',
  E'    IF p_slot_ids IS NOT NULL THEN\n      INSERT INTO iscrizioni_minori_slot (iscrizione_id, slot_id) SELECT v_id, unnest(p_slot_ids);\n    END IF;\n  END IF;\n\n  -- regola Marco 8 ott');

-- ── 5. INTERRUTTORE ADVANCE E LETTURA PER L'ALLIEVO ─────────────────

CREATE OR REPLACE FUNCTION public.imposta_advance_giovani(p_iscrizione_id uuid, p_attivo boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_abb record;
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN
    RAISE EXCEPTION 'Solo lo staff abilita il Corso Advance KataClimb.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_abb FROM iscrizioni_minori WHERE id = p_iscrizione_id FOR UPDATE;
  IF NOT FOUND OR v_abb.tipo_abbonamento <> 'giovani' THEN
    RAISE EXCEPTION 'Abbonamento del Corso Giovani KataClimb (18–24) non trovato.' USING ERRCODE = 'P0002';
  END IF;
  UPDATE iscrizioni_minori
     SET advance_abilitato = coalesce(p_attivo, false),
         advance_abilitato_da = auth.uid(),
         advance_abilitato_il = now(),
         note = concat_ws(E'\n', note, format('%s: Corso Advance KataClimb %s.', to_char(now() AT TIME ZONE 'Europe/Rome', 'DD/MM/YYYY'),
                CASE WHEN coalesce(p_attivo, false) THEN 'abilitato' ELSE 'tolto, torna il Corso Open KataClimb' END))
   WHERE id = p_iscrizione_id;
  RETURN jsonb_build_object('ok', true, 'iscrizione_id', p_iscrizione_id, 'advance_abilitato', coalesce(p_attivo, false),
    'da', auth.uid(), 'il', now());
END;
$function$;
REVOKE ALL ON FUNCTION public.imposta_advance_giovani(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.imposta_advance_giovani(uuid, boolean) TO authenticated;

-- Stato dell'allievo loggato (oggi l'allievo non legge iscrizioni_minori: legge solo i suoi dati).
CREATE OR REPLACE FUNCTION public.mio_abbonamento_giovani()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_persona uuid; v_abb record; v_oggi date := (now() AT TIME ZONE 'Europe/Rome')::date; v_lez record;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('attivo', false); END IF;
  SELECT persona_id INTO v_persona FROM profile_data WHERE user_id = auth.uid();
  SELECT * INTO v_abb FROM iscrizioni_minori
   WHERE persona_id = v_persona AND tipo_abbonamento = 'giovani' AND status = 'attiva'
     AND data_inizio <= v_oggi AND (data_fine IS NULL OR data_fine >= v_oggi)
   ORDER BY data_fine DESC NULLS FIRST LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('attivo', false, 'persona_id', v_persona);
  END IF;
  SELECT p.id, p.data_lezione, p.tipo_corso, p.slot_id, s.ora_inizio INTO v_lez
    FROM prenotazioni_corso p JOIN corsi_attivi_settimanali s ON s.id = p.slot_id
   WHERE p.user_id = auth.uid() AND p.abbonamento_id IS NOT NULL
     AND p.data_lezione BETWEEN date_trunc('week', v_oggi)::date AND date_trunc('week', v_oggi)::date + 6
     AND p.stato IN ('prenotato', 'presente', 'assente', 'cancellato_tardi')
   ORDER BY p.data_lezione LIMIT 1;
  RETURN jsonb_build_object(
    'attivo', true, 'persona_id', v_persona, 'iscrizione_id', v_abb.id,
    'dal', v_abb.data_inizio, 'al', v_abb.data_fine, 'advance', v_abb.advance_abilitato,
    'lezione_settimana', CASE WHEN v_lez.id IS NULL THEN NULL ELSE jsonb_build_object(
      'prenotazione_id', v_lez.id, 'data', v_lez.data_lezione, 'ora', to_char(v_lez.ora_inizio, 'HH24:MI'),
      'tipo_corso', v_lez.tipo_corso, 'slot_id', v_lez.slot_id) END);
END;
$function$;
REVOKE ALL ON FUNCTION public.mio_abbonamento_giovani() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mio_abbonamento_giovani() TO authenticated;
