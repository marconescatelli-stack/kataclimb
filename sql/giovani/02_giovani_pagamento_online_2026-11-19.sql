-- ════════════════════════════════════════════════════════════════════
-- sql/giovani/02_giovani_pagamento_online_2026-11-19.sql
-- Corso Giovani KataClimb (18–24): paga, entra, prenota (Marco 19 nov 2026)
--
-- Due funzioni SOLO per il Worker pagamenti (service role, mai dalla pagina):
--   giovani_preventivo(persona)  → cosa paga adesso: periodo, quota, iscrizione annuale, totale.
--   attiva_giovani_online(...)   → al pagamento: abbonamento + pagamento (metodo stripe, origine
--                                  online) + iscrizione annuale; idempotente sulla sessione Stripe.
-- Regole (Marco 19 nov):
--   - nessun abbonamento che copre oggi: dal = oggi, al = ultimo giorno del mese;
--     quota 110 € se oggi è dal 1 al 15, 55 € dal 16 a fine mese;
--   - abbonamento che copre oggi: il mese dopo la sua scadenza, intero, 110 €;
--   - iscrizione annuale 40 € se non c'è un tesseramento attivo che copre l'inizio del periodo;
--     scadenza come stripe-worker (scadenzaIscrizione): 31/12 dell'anno, o dell'anno dopo a dicembre;
--   - età 18–24 dalla data di nascita (persone.data_nascita), come prima_lezione_giovani.
-- La creazione dell'account (auth) resta al Worker: serve l'API admin di Supabase.
-- Richiede 01_giovani_prenotano_2026-11-19.sql.
-- ════════════════════════════════════════════════════════════════════

-- pagamenti online degli abbonamenti: origine 'online' e un pagamento Stripe registrato una volta sola
ALTER TABLE public.abbonamenti_pagamenti DROP CONSTRAINT abbonamenti_pagamenti_origine_check;
ALTER TABLE public.abbonamenti_pagamenti ADD CONSTRAINT abbonamenti_pagamenti_origine_check
  CHECK (origine = ANY (ARRAY['segreteria'::text, 'import_foglio_segreteria'::text, 'online'::text]));
ALTER TABLE public.abbonamenti_pagamenti ADD COLUMN stripe_session_id text;
CREATE UNIQUE INDEX abbonamenti_pagamenti_stripe_session_uniq ON public.abbonamenti_pagamenti (stripe_session_id)
  WHERE stripe_session_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.giovani_preventivo(p_persona_id uuid, p_oggi date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_oggi  date := coalesce(p_oggi, (now() AT TIME ZONE 'Europe/Rome')::date);
  v_p     record;
  v_abb   record;
  v_eta   int;
  v_dal   date;
  v_al    date;
  v_quota int;
  v_iscr  int := 0;
  v_iscr_fino date;
  v_rinnovo boolean := false;
BEGIN
  SELECT id, nome, cognome, email, data_nascita INTO v_p FROM persone WHERE id = p_persona_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'errore', 'persona'); END IF;

  IF v_p.data_nascita IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'errore', 'nascita', 'nome', v_p.nome);
  END IF;
  v_eta := extract(year FROM age(v_oggi, v_p.data_nascita))::int;
  IF v_eta < 18 THEN RETURN jsonb_build_object('ok', false, 'errore', 'eta_bassa', 'nome', v_p.nome, 'eta', v_eta); END IF;
  IF v_eta > 24 THEN RETURN jsonb_build_object('ok', false, 'errore', 'eta_alta', 'nome', v_p.nome, 'eta', v_eta); END IF;
  IF nullif(trim(coalesce(v_p.email, '')), '') IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'errore', 'email', 'nome', v_p.nome);
  END IF;

  SELECT * INTO v_abb FROM iscrizioni_minori
   WHERE persona_id = p_persona_id AND tipo_abbonamento = 'giovani' AND status = 'attiva'
     AND data_inizio <= v_oggi AND data_fine >= v_oggi
   ORDER BY data_fine DESC LIMIT 1;
  IF FOUND THEN
    v_rinnovo := true;
    v_dal := v_abb.data_fine + 1;
    v_al  := (date_trunc('month', v_dal) + interval '1 month - 1 day')::date;
    v_quota := 110;
  ELSE
    v_dal := v_oggi;
    v_al  := (date_trunc('month', v_oggi) + interval '1 month - 1 day')::date;
    v_quota := CASE WHEN extract(day FROM v_oggi) <= 15 THEN 110 ELSE 55 END;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM tesseramenti WHERE persona_id = p_persona_id AND stato = 'attivo' AND data_scadenza >= v_dal) THEN
    v_iscr := 40;
    v_iscr_fino := make_date(CASE WHEN extract(month FROM v_oggi) = 12 THEN extract(year FROM v_oggi)::int + 1
                                  ELSE extract(year FROM v_oggi)::int END, 12, 31);
  END IF;

  RETURN jsonb_build_object('ok', true, 'nome', v_p.nome, 'cognome', v_p.cognome, 'email', lower(trim(v_p.email)),
    'eta', v_eta, 'rinnovo', v_rinnovo, 'dal', v_dal, 'al', v_al, 'quota', v_quota,
    'mezzo_mese', (NOT v_rinnovo AND v_quota = 55),
    'iscrizione', v_iscr, 'iscrizione_valida_fino', v_iscr_fino, 'totale', v_quota + v_iscr);
END;
$function$;
REVOKE ALL ON FUNCTION public.giovani_preventivo(uuid, date) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.attiva_giovani_online(p_persona_id uuid, p_session_id text, p_dal date, p_al date,
  p_quota numeric, p_iscrizione numeric DEFAULT 0, p_payment_intent text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_gia   record;
  v_abb   record;
  v_id    uuid;
  v_pag   uuid;
  v_oggi  date := (now() AT TIME ZONE 'Europe/Rome')::date;
  v_anno  int;
  v_tess_fino date;
  v_tess  boolean := false;
  v_nota  text;
BEGIN
  IF p_persona_id IS NULL OR nullif(trim(coalesce(p_session_id, '')), '') IS NULL OR p_dal IS NULL OR p_al IS NULL OR p_al < p_dal THEN
    RAISE EXCEPTION 'attiva_giovani_online: dati mancanti (persona %, session %, % → %)', p_persona_id, p_session_id, p_dal, p_al;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id) THEN
    RAISE EXCEPTION 'attiva_giovani_online: persona % non trovata', p_persona_id;
  END IF;

  -- stesso pagamento arrivato due volte: niente doppioni
  SELECT iscrizione_id, dal, al INTO v_gia FROM abbonamenti_pagamenti WHERE stripe_session_id = p_session_id;
  IF FOUND THEN
    RETURN jsonb_build_object('ok', true, 'gia_registrato', true, 'iscrizione_id', v_gia.iscrizione_id, 'dal', v_gia.dal, 'al', v_gia.al);
  END IF;

  v_nota := format('Pagato online (Stripe %s): Corso Giovani KataClimb (18–24) dal %s al %s, %s €%s.', p_session_id,
    to_char(p_dal, 'DD/MM/YYYY'), to_char(p_al, 'DD/MM/YYYY'), p_quota,
    CASE WHEN coalesce(p_iscrizione, 0) > 0 THEN format(' + iscrizione annuale %s €', p_iscrizione) ELSE '' END);

  -- abbonamento: si allunga quello attivo se arriva fino al giorno prima del periodo (o oltre),
  -- altrimenti quello vecchio si chiude e ne nasce uno nuovo (resta la traccia di ogni periodo)
  SELECT * INTO v_abb FROM iscrizioni_minori
   WHERE persona_id = p_persona_id AND tipo_abbonamento = 'giovani' AND status = 'attiva'
   ORDER BY data_fine DESC NULLS FIRST LIMIT 1 FOR UPDATE;
  IF FOUND AND (v_abb.data_fine IS NULL OR v_abb.data_fine >= p_dal - 1) THEN
    v_id := v_abb.id;
    UPDATE iscrizioni_minori
       SET data_fine = CASE WHEN data_fine IS NULL THEN NULL ELSE greatest(data_fine, p_al) END,
           paid = true, note = concat_ws(E'\n', note, v_nota)
     WHERE id = v_id;
  ELSE
    IF FOUND THEN
      UPDATE iscrizioni_minori SET status = 'terminata',
             note = concat_ws(E'\n', note, format('%s: chiuso, nuovo periodo pagato online dal %s.', to_char(v_oggi, 'DD/MM/YYYY'), to_char(p_dal, 'DD/MM/YYYY')))
       WHERE id = v_abb.id;
    END IF;
    INSERT INTO iscrizioni_minori (persona_id, data_inizio, data_fine, status, paid, note, created_by, tipo_abbonamento, tipo_da_slot)
    VALUES (p_persona_id, p_dal, p_al, 'attiva', true, v_nota, NULL, 'giovani', false)
    RETURNING id INTO v_id;
  END IF;

  INSERT INTO abbonamenti_pagamenti (iscrizione_id, persona_id, tipo_abbonamento, dal, al, importo_eur, metodo, origine, note, registrato_da, stripe_session_id)
  VALUES (v_id, p_persona_id, 'giovani', p_dal, p_al, p_quota, 'stripe', 'online', v_nota, NULL, p_session_id)
  RETURNING id INTO v_pag;

  -- iscrizione annuale (stessa scrittura di stripe-worker registraIscrizionePrivata)
  IF coalesce(p_iscrizione, 0) > 0 THEN
    v_anno := extract(year FROM v_oggi)::int;
    INSERT INTO tesseramenti (persona_id, anno, data_inizio, data_scadenza, stato, assicurazione, note)
    VALUES (p_persona_id, v_anno, v_oggi, make_date(v_anno, 12, 31), 'attivo', true,
            format('Iscrizione online con il Corso Giovani KataClimb (18–24) (session %s)', p_session_id))
    ON CONFLICT (persona_id, anno) DO NOTHING;
    IF NOT FOUND THEN
      UPDATE tesseramenti SET stato = 'attivo', data_inizio = v_oggi, data_scadenza = make_date(v_anno, 12, 31), assicurazione = true,
             note = concat_ws(' | ', note, format('Iscrizione online con il Corso Giovani KataClimb (18–24) (session %s)', p_session_id)),
             updated_at = now()
       WHERE persona_id = p_persona_id AND anno = v_anno AND stato <> 'attivo';
    END IF;
    SELECT data_scadenza INTO v_tess_fino FROM tesseramenti WHERE persona_id = p_persona_id AND anno = v_anno;
    v_tess := v_tess_fino IS NOT NULL;
  END IF;

  RETURN jsonb_build_object('ok', true, 'gia_registrato', false, 'iscrizione_id', v_id, 'pagamento_id', v_pag,
    'dal', p_dal, 'al', (SELECT data_fine FROM iscrizioni_minori WHERE id = v_id),
    'tesseramento', v_tess, 'tesseramento_fino', v_tess_fino);
END;
$function$;
REVOKE ALL ON FUNCTION public.attiva_giovani_online(uuid, text, date, date, numeric, numeric, text) FROM PUBLIC, anon, authenticated;
