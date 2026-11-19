-- ════════════════════════════════════════════════════════════════════
-- questionario_arrampicatore_mail_2026-11-19.sql
-- Mail dopo il questionario "Arrampichi già" (consegna v1, decisione Marco 17 nov 2026)
--
-- Cambia SOLO invia_questionario_arrampicatore (stessa firma, stessi controlli, stesse
-- scritture). In più accoda gli eventi per le mail:
--   1. Marco, SEMPRE (canale both, con la finestra di quiete 22–08 di tg_lead_richieste_notifica):
--      - con quarto d'ora: l'evento di prima appuntamento_marco.staff, con in più nel payload
--        origine 'arrampichi-gia', email, grado, giorno, ora, righe (etichette di v_etich);
--      - con sola fascia: evento nuovo questionario_arrampicatore.staff,
--        dedup 'questionario_arrampicatore.staff:' || questionario_id.
--   2. La persona, solo se ha scritto l'email: evento nuovo questionario_arrampicatore.conferma,
--      user_id NULL (non ha un account), canale email, destinatario in payload.to (come gli
--      eventi listino.*), subito; dedup 'questionario_arrampicatore.conferma:' || questionario_id.
-- Ogni INSERT in eventi_notifica sta nel suo BEGIN … EXCEPTION: se la mail non parte, il
-- questionario vale lo stesso. Il ritorno "già inviato negli ultimi 10 minuti" esce prima
-- degli eventi: nessuna mail in più.
--
-- ORDINE: prima il deploy del Worker notifiche che conosce i due tipi nuovi e il ramo
-- origine 'arrampichi-gia', POI il COMMIT di questo file (senza Worker gli eventi nuovi vanno
-- in errore).
-- ════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.invia_questionario_arrampicatore(p_nome text, p_cognome text, p_telefono text, p_email text, p_risposte jsonb, p_pagina text DEFAULT 'arrampichi-gia.html'::text, p_slot timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_persona uuid;
  v_lead    uuid;
  v_gia     uuid;
  v_app     uuid;
  v_grado   text;
  v_nota    text;
  v_val     text;
  v_quando  text;
  v_marco   uuid := '27b04151-93a7-4ecc-824c-fe337cc631a6';
  v_email   text := NULLIF(lower(trim(COALESCE(p_email,''))), '');
  v_tel     text := btrim(p_telefono);
  r         record;
  v_etich   jsonb := '[
    ["da_quanto", "Da quanto arrampica"],
    ["dove",      "Dove arrampica"],
    ["ruolo",     "Da primo o da secondo"],
    ["grado",     "Grado a vista con tranquillità"],
    ["motivi",    "Cosa lo porta qui"],
    ["racconto",  "Con parole sue (quando non va)"],
    ["sei_mesi",  "Tra sei mesi vorrebbe"],
    ["frequenza", "Frequenza ideale indoor"],
    ["orario",    "Preferisce essere chiamato"]
  ]'::jsonb;
  -- v2026-11-19 — mail dopo il questionario
  v_righe    jsonb := '[]'::jsonb;
  v_giorno   text;
  v_ora      text;
  v_fascia   text;
  v_roma     timestamp;
  v_ora_roma int;
  v_schedula timestamptz;
  v_giorni   text[] := ARRAY['lunedì','martedì','mercoledì','giovedì','venerdì','sabato','domenica'];
  v_mesi     text[] := ARRAY['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto','settembre','ottobre','novembre','dicembre'];
BEGIN
  IF COALESCE(trim(p_nome),'') = '' OR COALESCE(v_tel,'') = '' THEN
    RAISE EXCEPTION 'Scrivi almeno il nome e il telefono: Marco ti chiama lì.' USING ERRCODE = '23514';
  END IF;
  IF length(regexp_replace(v_tel, '\D', '', 'g')) < 9 THEN
    RAISE EXCEPTION 'Il numero di telefono deve avere almeno 9 cifre.' USING ERRCODE = '23514';
  END IF;
  IF v_email IS NOT NULL AND position('@' IN v_email) = 0 THEN
    RAISE EXCEPTION 'L''email non sembra valida: controllala o lasciala vuota.' USING ERRCODE = '23514';
  END IF;
  IF length(p_nome) > 150 OR length(COALESCE(p_cognome,'')) > 150 OR length(v_tel) > 40
     OR length(COALESCE(p_email,'')) > 200 OR length(COALESCE(p_risposte::text,'')) > 6000 THEN
    RAISE EXCEPTION 'Testo troppo lungo.' USING ERRCODE = '23514';
  END IF;
  IF p_risposte IS NULL OR jsonb_typeof(p_risposte) <> 'object' THEN
    RAISE EXCEPTION 'Risposte mancanti.' USING ERRCODE = '23514';
  END IF;
  IF p_slot IS NOT NULL AND NOT EXISTS (SELECT 1 FROM slot_liberi_marco((p_slot AT TIME ZONE 'Europe/Rome')::date, (p_slot AT TIME ZONE 'Europe/Rome')::date) s WHERE s.inizio = p_slot) THEN
    RAISE EXCEPTION 'Questo quarto d''ora non è più libero: scegline un altro.' USING ERRCODE = '23505';
  END IF;

  v_persona := public.garantisci_persona(v_email, p_nome, p_cognome, v_tel);

  SELECT id INTO v_gia FROM public.questionari_arrampicatori
   WHERE persona_id = v_persona AND created_at > now() - interval '10 minutes'
   ORDER BY created_at DESC LIMIT 1;
  IF v_gia IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'questionario_id', v_gia, 'gia_inviato', true);
  END IF;

  INSERT INTO public.lead_data (persona_id, funnel_stage, stato_gestione, fonte, coda, fascia)
  VALUES (v_persona, 'nuovo', 'attivo', 'form_arrampicatori', 'arrampicatori', 'adulto')
  ON CONFLICT (persona_id) DO UPDATE
     SET coda       = 'arrampicatori',
         fascia     = COALESCE(public.lead_data.fascia, 'adulto'),
         fonte      = COALESCE(public.lead_data.fonte, 'form_arrampicatori'),
         updated_at = now();
  SELECT id INTO v_lead FROM public.lead_data WHERE persona_id = v_persona;

  v_nota := 'QUESTIONARIO ARRAMPICATORI';
  FOR r IN SELECT e->>0 AS key, e->>1 AS label FROM jsonb_array_elements(v_etich) WITH ORDINALITY AS t(e, n) ORDER BY n LOOP
    IF p_risposte ? r.key THEN
      v_val := CASE WHEN jsonb_typeof(p_risposte->r.key) = 'array'
                    THEN (SELECT string_agg(x, ', ') FROM jsonb_array_elements_text(p_risposte->r.key) x)
                    ELSE p_risposte->>r.key END;
      IF NULLIF(trim(COALESCE(v_val,'')),'') IS NOT NULL THEN
        v_nota := v_nota || E'\n' || r.label || ': ' || trim(v_val);
        v_righe := v_righe || jsonb_build_array(jsonb_build_object('etichetta', r.label, 'valore', trim(v_val)));
      END IF;
    END IF;
  END LOOP;
  v_grado := NULLIF(trim(COALESCE(p_risposte->>'grado','')), '');
  IF p_slot IS NOT NULL THEN
    v_quando := to_char(p_slot AT TIME ZONE 'Europe/Rome', 'DD/MM/YYYY "alle" HH24:MI');
    v_nota := v_nota || E'\n' || 'Telefonata prenotata: ' || v_quando;
    v_roma   := p_slot AT TIME ZONE 'Europe/Rome';
    v_giorno := v_giorni[extract(isodow FROM v_roma)::int] || ' ' || extract(day FROM v_roma)::int || ' ' || v_mesi[extract(month FROM v_roma)::int];
    v_ora    := to_char(v_roma, 'HH24:MI');
  ELSE
    v_fascia := NULLIF(trim(COALESCE(p_risposte->>'orario','')), '');
  END IF;

  INSERT INTO public.lead_richieste (persona_id, canale, campagna, pagina, note)
  VALUES (v_persona, 'form_arrampicatori', 'Per chi arrampica già', NULLIF(trim(p_pagina),''), v_nota);

  INSERT INTO public.crm_follow_ups (lead_id, tipo, testo, created_by, avvenuto_il)
  VALUES (v_lead, 'nota', v_nota, NULL, now());
  UPDATE public.lead_data SET ultima_interazione = now() WHERE id = v_lead;

  INSERT INTO public.questionari_arrampicatori (persona_id, lead_id, risposte, grado)
  VALUES (v_persona, v_lead, p_risposte, v_grado)
  RETURNING id INTO v_gia;

  -- Finestra di quiete per la mail a Marco (ora italiana), come tg_lead_richieste_notifica:
  -- 22:00–07:59 → alle 08:00.
  v_ora_roma := date_part('hour', now() AT TIME ZONE 'Europe/Rome')::int;
  IF v_ora_roma >= 22 THEN
    v_schedula := ((now() AT TIME ZONE 'Europe/Rome')::date + 1 + time '08:00') AT TIME ZONE 'Europe/Rome';
  ELSIF v_ora_roma < 8 THEN
    v_schedula := ((now() AT TIME ZONE 'Europe/Rome')::date + time '08:00') AT TIME ZONE 'Europe/Rome';
  ELSE
    v_schedula := now();
  END IF;

  IF p_slot IS NOT NULL THEN
    INSERT INTO public.appuntamenti_marco (user_id, persona_id, lead_id, inizio, fine, telefono, corsi_fatti, passo_successivo, risposte, origine)
    VALUES (NULL, v_persona, v_lead, p_slot, p_slot + interval '15 minutes', v_tel, '{}'::text[], '{}'::text[], p_risposte, 'arrampichi-gia')
    RETURNING id INTO v_app;
    UPDATE public.lead_data SET prossima_azione_il = p_slot WHERE id = v_lead;
    BEGIN
      PERFORM registra_evento_notifica('appuntamento_marco.staff', v_marco, 'both',
        jsonb_build_object('appuntamento_id', v_app, 'nome', trim(p_nome), 'cognome', COALESCE(trim(p_cognome),''), 'quando', v_quando, 'telefono', v_tel,
          'corsi_fatti', '[]'::jsonb, 'passo_successivo', to_jsonb(ARRAY['Chi arrampica già — questionario arrampichi-gia.html']), 'risposte', p_risposte,
          -- v2026-11-19 — per la mail "Arrampichi già" a Marco
          'origine', 'arrampichi-gia', 'questionario_id', v_gia, 'email', v_email, 'grado', v_grado,
          'giorno', v_giorno, 'ora', v_ora, 'righe', v_righe),
        v_schedula, 'appuntamento_marco.staff:' || v_app);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'notifica appuntamento non partita: %', sqlerrm;
    END;
  ELSE
    BEGIN
      PERFORM registra_evento_notifica('questionario_arrampicatore.staff', v_marco, 'both',
        jsonb_build_object('questionario_id', v_gia, 'persona_id', v_persona, 'nome', trim(p_nome), 'cognome', COALESCE(trim(p_cognome),''),
          'telefono', v_tel, 'email', v_email, 'grado', v_grado, 'fascia', v_fascia, 'righe', v_righe),
        v_schedula, 'questionario_arrampicatore.staff:' || v_gia);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'notifica questionario a Marco non partita: %', sqlerrm;
    END;
  END IF;

  IF v_email IS NOT NULL THEN
    BEGIN
      PERFORM registra_evento_notifica('questionario_arrampicatore.conferma', NULL, 'email',
        jsonb_build_object('questionario_id', v_gia, 'persona_id', v_persona, 'to', v_email, 'nome', trim(p_nome), 'cognome', COALESCE(trim(p_cognome),''),
          'telefono', v_tel, 'giorno', v_giorno, 'ora', v_ora, 'fascia', v_fascia),
        now(), 'questionario_arrampicatore.conferma:' || v_gia);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'conferma questionario alla persona non partita: %', sqlerrm;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'questionario_id', v_gia, 'appuntamento_id', v_app, 'quando', v_quando);
END;
$function$;

-- La pagina arrampichi-gia.html è senza login: la funzione resta aperta ad anon (CREATE OR
-- REPLACE tiene già i permessi; la riga è qui per non dipendere da quelli di prima).
GRANT EXECUTE ON FUNCTION public.invia_questionario_arrampicatore(text, text, text, text, jsonb, text, timestamp with time zone) TO anon;
