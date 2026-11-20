-- =====================================================================
-- DOPPIA SCADENZA — DATE VISIBILI E BLOCCO SALA CON MONITOR
-- Marco, 20 nov 2026 · segue sala_corso_doppia_scadenza_2026_11_20
--
-- Regola: sala scaduta con lezioni ancora da fare -> le lezioni si fanno,
-- la Sala con Monitor no finche' non si paga la seconda rata o il mese di sala.
--
-- Il blocco e' STRETTO, apposta: scatta solo se
--   1) la persona ha un Corso Advance / Intro Corda / Evo Corda KataClimb attivo
--   2) la sala inclusa in quel corso e' scaduta
--   3) NON ha nessun'altra copertura valida oggi: abbonamento o pacchetto attivo,
--      un'altra riga di sala valida, un ingresso segnato oggi, veterano, staff.
-- Chi non ha un corso con sala inclusa non viene toccato.
-- APPLICATO il 20 nov 2026 (migrazione sala_corso_blocco_e_date_2026_11_20).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.sala_corso_blocco(p_persona_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE s record; v_nome text;
BEGIN
  SELECT sc.al, ic.tipo_corso INTO s
    FROM sala_coperture sc JOIN iscrizioni_corso ic ON ic.id = sc.iscrizione_id
   WHERE sc.persona_id = p_persona_id AND sc.fonte = 'corso' AND ic.status = 'attiva'
   ORDER BY sc.al DESC LIMIT 1;
  IF NOT FOUND OR s.al >= CURRENT_DATE THEN RETURN NULL; END IF;

  IF EXISTS (SELECT 1 FROM persone WHERE id = p_persona_id AND COALESCE(veterano, false)) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM profile_data WHERE persona_id = p_persona_id AND (role = 'creator' OR staff_role IS NOT NULL)) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM sala_coperture WHERE persona_id = p_persona_id AND al >= CURRENT_DATE AND (dal IS NULL OR dal <= CURRENT_DATE)) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_minori WHERE persona_id = p_persona_id AND status = 'attiva' AND (data_fine IS NULL OR data_fine >= CURRENT_DATE)) THEN RETURN NULL; END IF;
  IF EXISTS (SELECT 1 FROM ingressi_sala WHERE persona_id = p_persona_id AND data = CURRENT_DATE AND annullato_at IS NULL) THEN RETURN NULL; END IF;

  SELECT trim(COALESCE(nome,'') || ' ' || COALESCE(cognome,'')) INTO v_nome FROM persone WHERE id = p_persona_id;
  RETURN format('%s: la Sala con Monitor inclusa nel %s è scaduta il %s. Le lezioni del corso si fanno. Per la Sala con Monitor serve la seconda rata del corso o il mese di sala (90 €): si registra in segreteria e l''allievo rientra subito.',
    v_nome,
    CASE s.tipo_corso WHEN 'advance' THEN 'Corso Advance KataClimb' WHEN 'intro_corda' THEN 'Corso Intro Corda KataClimb' ELSE 'Corso Evo Corda KataClimb' END,
    to_char(s.al, 'DD/MM/YYYY'));
END $function$;

REVOKE ALL ON FUNCTION public.sala_corso_blocco(uuid) FROM PUBLIC, anon, authenticated;

-- Elenco per lo staff: chi oggi ha la sala del corso scaduta (per segnarlo nelle liste).
CREATE OR REPLACE FUNCTION public.sala_corso_scadute()
 RETURNS TABLE(persona_id uuid, sala_fino_al date, messaggio text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  RETURN QUERY
  SELECT x.persona_id, x.al, sala_corso_blocco(x.persona_id)
    FROM (SELECT sc.persona_id, max(sc.al) AS al
            FROM sala_coperture sc JOIN iscrizioni_corso ic ON ic.id = sc.iscrizione_id
           WHERE sc.fonte = 'corso' AND ic.status = 'attiva'
           GROUP BY sc.persona_id HAVING max(sc.al) < CURRENT_DATE) x
   WHERE sala_corso_blocco(x.persona_id) IS NOT NULL;
END $function$;

REVOKE ALL ON FUNCTION public.sala_corso_scadute() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.sala_corso_scadute() TO authenticated;

-- Per l'allievo: le sue due date (lezioni e sala) dei corsi in corso.
CREATE OR REPLACE FUNCTION public.mie_scadenze_corso()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Serve il login'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'tipo_corso', ic.tipo_corso,
             'lezioni_fino_al', ic.data_fine_validita,
             'parte_alla_prima_presenza', COALESCE(ic.inizio_da_prima_presenza, false),
             'sala_inclusa', true,
             'sala_dal', sc.dal,
             'sala_fino_al', sc.al) ORDER BY ic.data_iscrizione DESC)
      FROM iscrizioni_corso ic
      LEFT JOIN sala_coperture sc ON sc.iscrizione_id = ic.id
     WHERE ic.user_id = auth.uid() AND ic.status = 'attiva'
       AND ic.tipo_corso IN ('advance','intro_corda','evo_corda')), '[]'::jsonb);
END $function$;

REVOKE ALL ON FUNCTION public.mie_scadenze_corso() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mie_scadenze_corso() TO authenticated;

-- Il blocco dentro le due funzioni con cui il monitor mette una persona nel turno.
DO $$
DECLARE f text; d text; n int;
  v_old text := 'IF NOT EXISTS (SELECT 1 FROM persone WHERE id = pid) THEN RAISE EXCEPTION ''Persona non trovata''; END IF;';
  v_new text := 'IF NOT EXISTS (SELECT 1 FROM persone WHERE id = pid) THEN RAISE EXCEPTION ''Persona non trovata''; END IF;' || E'\n'
             || '    IF sala_corso_blocco(pid) IS NOT NULL THEN RAISE EXCEPTION ''%'', sala_corso_blocco(pid); END IF;  -- 20 nov 2026: sala del corso scaduta';
BEGIN
  FOREACH f IN ARRAY ARRAY['public.monitor_scegli_seguiti(uuid[])','public.monitor_aggiungi_seguiti(uuid[],uuid)'] LOOP
    d := pg_get_functiondef(f::regprocedure);
    IF position('sala_corso_blocco' IN d) > 0 THEN CONTINUE; END IF;
    n := (length(d) - length(replace(d, v_old, ''))) / length(v_old);
    IF n <> 1 THEN RAISE EXCEPTION '%: punto di aggancio non trovato (%)', f, n; END IF;
    EXECUTE replace(d, v_old, v_new);
  END LOOP;
END $$;
