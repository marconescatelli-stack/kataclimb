-- GIÀ APPLICATO IN PRODUZIONE il 15/10/2026 alle 13:43 (da chat). NON RILANCIARE: il punto 2 fallirebbe di proposito. File di sola documentazione.

-- FIX OPEN MEZZA1 · 15 ott 2026
-- Problema: a 4/4 di Mezza1 il sistema chiudeva l'Open (concluso_open) e il cron mandava
-- "ultima lezione" + offerta Advance. Mezza1 non e' la fine dell'Open: mancano le 3 di Mezza2.
-- Regola: Open attivo con lezioni_totali < 7 = Open a meta', NON concluso.

-- 1) _chiudi_corso_se_finito: Open a meta' non si chiude, lascia nota "incassare Mezza2"
CREATE OR REPLACE FUNCTION public._chiudi_corso_se_finito(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_corso      text;
  v_persona_id uuid;
  v_funnel_key text;
  v_lead_id    uuid;
  v_finito     boolean;
BEGIN
  SELECT corso_attivo, persona_id INTO v_corso, v_persona_id
    FROM profile_data WHERE user_id = p_user_id;

  IF v_corso IS NULL THEN
    RETURN;
  END IF;

  SELECT coalesce(bool_and(restano <= 0 AND in_agenda = 0), true)
    INTO v_finito
    FROM contatori_corso
    WHERE user_id = p_user_id AND tipo_corso = v_corso;

  IF NOT v_finito THEN
    RETURN;
  END IF;

  -- FIX 15 ott 2026 (caso Brilli/Lorenzetti): Open pagato solo Mezza1 (lezioni_totali < 7)
  -- NON e' concluso. Resta iscritto_open, corso_attivo resta 'open'. Nota per la segreteria.
  IF v_corso = 'open' AND EXISTS (
       SELECT 1 FROM iscrizioni_corso
        WHERE user_id = p_user_id AND tipo_corso = 'open'
          AND status = 'attiva' AND lezioni_totali < 7) THEN
    SELECT id INTO v_lead_id FROM lead_data WHERE persona_id = v_persona_id LIMIT 1;
    IF v_lead_id IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM crm_follow_ups
          WHERE lead_id = v_lead_id AND testo LIKE '🔔 Sistema: MEZZA1 FINITA%') THEN
      BEGIN
        INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
        VALUES (v_lead_id, 'nota',
          format('🔔 Sistema: MEZZA1 FINITA il %s (prime 4 lezioni Open fatte). Da incassare Mezza2 (3 lezioni) per completare l''Open. NON proporre Advance.', CURRENT_DATE::text),
          auth.uid());
      EXCEPTION WHEN OTHERS THEN
        RAISE LOG '_chiudi_corso_se_finito: nota Mezza1 fallita per user %: %', p_user_id, SQLERRM;
      END;
    END IF;
    RETURN;
  END IF;

  UPDATE profile_data SET corso_attivo = NULL WHERE user_id = p_user_id;

  v_funnel_key := replace(v_corso, '_corda', '');
  IF v_persona_id IS NOT NULL
     AND v_funnel_key IN ('open','advance','intro','evo') THEN
    UPDATE lead_data
      SET funnel_stage = 'concluso_' || v_funnel_key
      WHERE persona_id = v_persona_id
      RETURNING id INTO v_lead_id;

    IF v_lead_id IS NOT NULL THEN
      BEGIN
        INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
        VALUES (
          v_lead_id, 'nota',
          format('🔔 Sistema: PERCORSO %s CONCLUSO il %s (lezioni esaurite). Da ricontattare per rinnovo/proposta corso successivo.',
                 upper(v_funnel_key), CURRENT_DATE::text),
          auth.uid()
        );
      EXCEPTION WHEN OTHERS THEN
        RAISE LOG '_chiudi_corso_se_finito: nota follow-up fallita per user %: %', p_user_id, SQLERRM;
      END;
    END IF;
  END IF;
END;
$function$;

-- 2) cron_genera_eventi_mattutini: niente mail "ultima lezione" all'allievo a fine Mezza1.
--    (patch chirurgica: si aggiunge una condizione, il resto della funzione resta identico)
DO $$
DECLARE
  d   text := pg_get_functiondef('public.cron_genera_eventi_mattutini'::regproc);
  old text := E'          AND data_lezione > v_oggi\n      )\n    );';
  new text := E'          AND data_lezione > v_oggi\n      )\n      -- FIX 15 ott 2026: fine Mezza1 non e'' l''ultima lezione dell''Open\n      AND NOT EXISTS (\n        SELECT 1 FROM iscrizioni_corso ic\n        WHERE ic.user_id = rec.user_id AND ic.tipo_corso = ''open''\n          AND ic.status = ''attiva'' AND ic.lezioni_totali < 7\n          AND rec.corso = ''open''\n      )\n    );';
BEGIN
  IF (length(d) - length(replace(d, old, ''))) / length(old) <> 1 THEN
    RAISE EXCEPTION 'cron: blocco da sostituire non trovato esattamente 1 volta';
  END IF;
  EXECUTE replace(d, old, new);
END $$;

-- 3) Riparazione di tutti gli Open a metà chiusi per errore (Open a meta', non concluso)
UPDATE profile_data SET corso_attivo = 'open', updated_at = now()
 WHERE user_id IN (
   SELECT i.user_id FROM iscrizioni_corso i
    WHERE i.tipo_corso='open' AND i.status='attiva' AND i.lezioni_totali < 7)
   AND corso_attivo IS NULL;

UPDATE lead_data ld SET funnel_stage = 'iscritto_open'
  FROM profile_data pd
 WHERE pd.persona_id = ld.persona_id
   AND ld.funnel_stage = 'concluso_open'
   AND EXISTS (SELECT 1 FROM iscrizioni_corso i WHERE i.user_id = pd.user_id
               AND i.tipo_corso='open' AND i.status='attiva' AND i.lezioni_totali < 7);

-- 4) Valerio Brilli: Open lunedi' 19/10 ore 20:00 (slot Mello). Mezza2 la paga lunedi' in segreteria.
INSERT INTO prenotazioni_corso (user_id, slot_id, tipo_corso, data_lezione, stato, created_ruolo)
SELECT 'fd5916c4-499b-412e-9d75-4a1eeac07a77', '6fbf053d-bcfd-45db-af34-03ef462ba212', 'open', DATE '2026-10-19', 'prenotato', 'segreteria'
WHERE NOT EXISTS (SELECT 1 FROM prenotazioni_corso
  WHERE user_id='fd5916c4-499b-412e-9d75-4a1eeac07a77' AND data_lezione='2026-10-19' AND stato IN ('prenotato','presente'));
