-- =====================================================================
-- DOPPIA SCADENZA — LA SALA SI SCRIVE DA SOLA (Marco, 19-20 nov 2026)
-- Master v4.50 §1 · Regola_Scadenze_Corsi_v2 §2
--
-- Corso Advance, Intro Corda, Evo Corda KataClimb hanno la Sala con Monitor
-- inclusa, con una scadenza sua:
--   una rata / Advance 2 volte a settimana : 30 giorni dalla prima presenza
--   seconda rata                           : 30 giorni dal pagamento
--   tutto insieme                          : 60 giorni dalla prima presenza
-- Formula unica:  senza seconda rata  -> P + 30
--                 con seconda rata    -> il piu' lontano tra P + 60 e D + 30
--   P = prima presenza al corso, D = giorno del pagamento della seconda rata.
-- Una riga per iscrizione in sala_coperture (fonte = 'corso').
-- Non tocca le scadenze delle lezioni.
-- APPLICATO il 20 nov 2026 (migrazione sala_corso_doppia_scadenza_2026_11_20).
-- =====================================================================

ALTER TABLE public.sala_coperture ADD COLUMN IF NOT EXISTS iscrizione_id uuid REFERENCES public.iscrizioni_corso(id);
ALTER TABLE public.sala_coperture ADD COLUMN IF NOT EXISTS rata2_dal date;
ALTER TABLE public.sala_coperture ADD COLUMN IF NOT EXISTS aggiornato_at timestamptz;
CREATE UNIQUE INDEX IF NOT EXISTS sala_coperture_iscrizione_uq ON public.sala_coperture(iscrizione_id) WHERE iscrizione_id IS NOT NULL;

COMMENT ON COLUMN public.sala_coperture.iscrizione_id IS 'Iscrizione al corso che include questa sala (solo fonte = corso).';
COMMENT ON COLUMN public.sala_coperture.rata2_dal IS 'Giorno del pagamento della seconda rata, se pagata.';

-- Le 9 righe scritte a mano il 20 nov: collegate alla loro iscrizione.
UPDATE public.sala_coperture sc
   SET iscrizione_id = x.id,
       rata2_dal = CASE WHEN x.rata2 THEN sc.dal END
  FROM (
    SELECT DISTINCT ON (pd.persona_id, i.tipo_corso) pd.persona_id, i.tipo_corso, i.id,
           (i.importo_concordato > 0 AND i.importo_pagato >= i.importo_concordato AND i.importo_concordato <> 190) AS rata2
      FROM public.iscrizioni_corso i JOIN public.profile_data pd ON pd.user_id = i.user_id
     WHERE i.tipo_corso IN ('advance','intro_corda','evo_corda') AND i.status IN ('attiva','terminata')
     ORDER BY pd.persona_id, i.tipo_corso, i.data_iscrizione DESC
  ) x
 WHERE sc.fonte = 'corso' AND sc.iscrizione_id IS NULL AND sc.persona_id = x.persona_id
   AND sc.tipo = 'Sala inclusa · Corso ' || CASE x.tipo_corso WHEN 'advance' THEN 'Advance' WHEN 'intro_corda' THEN 'Intro Corda' ELSE 'Evo Corda' END || ' KataClimb';

CREATE OR REPLACE FUNCTION public.sala_corso_aggiorna(p_iscrizione_id uuid, p_data_rata2 date DEFAULT NULL)
 RETURNS date
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  i iscrizioni_corso%ROWTYPE;
  v_persona uuid; v_p date; v_d date; v_al date;
  v_2x boolean; v_saldato boolean;
  v_old sala_coperture%ROWTYPE; v_tipo text;
BEGIN
  SELECT * INTO i FROM iscrizioni_corso WHERE id = p_iscrizione_id;
  IF NOT FOUND OR i.status <> 'attiva' OR i.tipo_corso NOT IN ('advance','intro_corda','evo_corda') THEN
    RETURN NULL;
  END IF;
  SELECT persona_id INTO v_persona FROM profile_data WHERE user_id = i.user_id;
  IF v_persona IS NULL THEN RETURN NULL; END IF;

  -- P: prima presenza al corso (anche se viene prima del pagamento).
  SELECT min(data_lezione) INTO v_p
    FROM prenotazioni_corso
   WHERE user_id = i.user_id AND tipo_corso = i.tipo_corso AND stato = 'presente'
     AND abbonamento_id IS NULL AND data_lezione >= i.data_iscrizione - 30;
  IF v_p IS NULL THEN RETURN NULL; END IF;   -- la sala parte alla prima presenza

  v_2x := i.tipo_corso = 'advance' AND i.importo_concordato = 190;
  v_saldato := i.importo_concordato > 0 AND i.importo_pagato >= i.importo_concordato;
  SELECT * INTO v_old FROM sala_coperture WHERE iscrizione_id = i.id;

  IF v_2x OR NOT v_saldato THEN
    v_d := NULL;
    v_al := v_p + 30;
  ELSE
    v_d := COALESCE(
      p_data_rata2,
      v_old.rata2_dal,
      (SELECT max((registrato_il AT TIME ZONE 'Europe/Rome')::date) FROM pagamenti_manuali
        WHERE user_id = i.user_id
          AND voce = CASE i.tipo_corso WHEN 'advance' THEN 'advance_mese2' WHEN 'intro_corda' THEN 'intro_mese2' ELSE 'evo_mese2' END
          AND registrato_il >= i.created_at - interval '1 day'),
      CURRENT_DATE);
    v_al := GREATEST(v_p + 60, v_d + 30);
  END IF;

  v_tipo := 'Sala inclusa · Corso ' || CASE i.tipo_corso WHEN 'advance' THEN 'Advance' WHEN 'intro_corda' THEN 'Intro Corda' ELSE 'Evo Corda' END || ' KataClimb';

  IF v_old.id IS NOT NULL THEN
    UPDATE sala_coperture
       SET dal = v_p, al = v_al, rata2_dal = v_d, aggiornato_at = now()
     WHERE id = v_old.id AND (dal, al, rata2_dal) IS DISTINCT FROM (v_p, v_al, v_d);
  ELSE
    INSERT INTO sala_coperture (persona_id, tipo, dal, al, fonte, iscrizione_id, rata2_dal, aggiornato_at)
    VALUES (v_persona, v_tipo, v_p, v_al, 'corso', i.id, v_d, now())
    ON CONFLICT (persona_id, tipo, al) DO UPDATE
      SET iscrizione_id = EXCLUDED.iscrizione_id, dal = EXCLUDED.dal, rata2_dal = EXCLUDED.rata2_dal,
          fonte = 'corso', aggiornato_at = now();
  END IF;
  RETURN v_al;
END $function$;

REVOKE ALL ON FUNCTION public.sala_corso_aggiorna(uuid, date) FROM PUBLIC, anon, authenticated;

-- 1) Alla presenza: la sala parte (o si ricalcola) dalla prima presenza.
CREATE OR REPLACE FUNCTION public._tg_sala_corso_da_presenza()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE r record;
BEGIN
  IF NEW.tipo_corso NOT IN ('advance','intro_corda','evo_corda') OR NEW.abbonamento_id IS NOT NULL THEN RETURN NEW; END IF;
  IF NEW.stato IS DISTINCT FROM 'presente' AND NOT (TG_OP = 'UPDATE' AND OLD.stato = 'presente') THEN RETURN NEW; END IF;
  FOR r IN SELECT id FROM iscrizioni_corso WHERE user_id = NEW.user_id AND tipo_corso = NEW.tipo_corso AND status = 'attiva' LOOP
    PERFORM sala_corso_aggiorna(r.id);
  END LOOP;
  RETURN NEW;
END $function$;

CREATE OR REPLACE TRIGGER trg_sala_corso_da_presenza
  AFTER INSERT OR UPDATE OF stato, data_lezione ON public.prenotazioni_corso
  FOR EACH ROW EXECUTE FUNCTION public._tg_sala_corso_da_presenza();

-- 2) All'iscrizione e a ogni pagamento registrato sull'iscrizione.
CREATE OR REPLACE FUNCTION public._tg_sala_corso_da_iscrizione()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = 'attiva' AND NEW.tipo_corso IN ('advance','intro_corda','evo_corda') THEN
    PERFORM sala_corso_aggiorna(NEW.id);
  END IF;
  RETURN NEW;
END $function$;

CREATE OR REPLACE TRIGGER trg_sala_corso_da_iscrizione
  AFTER INSERT OR UPDATE OF importo_pagato, importo_concordato, stato_pagamento, status ON public.iscrizioni_corso
  FOR EACH ROW EXECUTE FUNCTION public._tg_sala_corso_da_iscrizione();

-- 3) Seconda rata: il giorno del pagamento dichiarato dalla segreteria fa fede
--    (anche se registrato in ritardo).
DO $$
DECLARE f text; d text; n int;
  v_old text := '  RETURN jsonb_build_object(';
  v_new text := '  PERFORM sala_corso_aggiorna(v_iscrizione.id, p_data_pagamento);' || E'\n' || '  RETURN jsonb_build_object(';
BEGIN
  FOREACH f IN ARRAY ARRAY['public.accredita_advance_mese2(uuid,date,text,text)','public.accredita_intro_mese2(uuid,date,text,text)','public.accredita_evo_mese2(uuid,date,text,text)'] LOOP
    d := pg_get_functiondef(f::regprocedure);
    IF position('sala_corso_aggiorna' IN d) > 0 THEN CONTINUE; END IF;
    n := (length(d) - length(replace(d, v_old, ''))) / length(v_old);
    IF n <> 1 OR position('v_iscrizione.id' IN d) = 0 OR position('p_data_pagamento' IN d) = 0 THEN
      RAISE EXCEPTION '%: punto di aggancio non trovato (RETURN = %)', f, n;
    END IF;
    EXECUTE replace(d, v_old, v_new);
  END LOOP;
END $$;

-- 4) Allineamento di chi e' iscritto oggi.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM iscrizioni_corso WHERE status = 'attiva' AND tipo_corso IN ('advance','intro_corda','evo_corda') LOOP
    PERFORM sala_corso_aggiorna(r.id);
  END LOOP;
END $$;
