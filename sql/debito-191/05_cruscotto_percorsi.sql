-- ==========================================================================
-- DEBITO-191 · 05 · get_cruscotto_percorsi — la guardia
-- Preparato il 22 settembre 2026 · NON APPLICATO · decide Marco
--
-- Questa e' la funzione da cui e' partito tutto il cantiere. Si credeva un caso
-- isolato: e' la regola. Stessa guardia, stessi quattro ruoli inesistenti, in
-- altre diciannove funzioni (file 04a e 04c).
--
-- ATTENZIONE · QUESTA FUNZIONE HA UN SECONDO GUASTO, INDIPENDENTE DALLA GUARDIA
--   Oggi get_cruscotto_percorsi NON FUNZIONA PER NESSUNO, nemmeno per Marco.
--   Provata il 22 set, l'errore e':
--     ERROR 42804: structure of query does not match function result type
--     DETAIL: Returned type bigint does not match expected type integer in column 9
--   La colonna 9 e' residue_open. Dopo DEBITO-190 i residui arrivano dalla vista
--   contatori_corso, dove prenotabili e' bigint, mentre la funzione dichiara
--   integer. Lo stesso vale per residue_advance, residue_intro e residue_evo.
--   La correzione non e' una guardia, quindi non l'ho messa nel corpo qui sotto:
--   sta in fondo al file, spiegata, e la decide Marco.
--   Applicare solo questo file corregge chi puo' entrare, ma il cruscotto
--   continuera' a dare errore finche' non si sistema anche il tipo.
-- ==========================================================================

BEGIN;

-- Corpo riletto da pg_get_functiondef il 22 set e lasciato identico.
-- Cambia solo il blocco di guardia, segnato dal commento DEBITO-191.
-- La firma non cambia, quindi nessun DROP FUNCTION serve.
CREATE OR REPLACE FUNCTION public.get_cruscotto_percorsi()
 RETURNS TABLE(persona_id uuid, user_id uuid, nome text, cognome text, telefono text, email text, bucket text, corso_attivo text, residue_open integer, residue_advance integer, residue_intro integer, residue_evo integer, scadenza_open timestamp with time zone, scadenza_advance timestamp with time zone, scadenza_intro timestamp with time zone, scadenza_evo timestamp with time zone, prenotazioni_future integer, alert_scaduto boolean, data_prima_lezione date, recensione_inviata_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- DEBITO-191 · guardia sostituita.
  --
  -- Com'era:
  --   IF auth.uid() IS NOT NULL AND auth.uid() <> '<uuid>' AND NOT EXISTS (... staff_role
  --   IN ('creator','admin','segreteria','staff_istruttore_sr','istruttore_senior')) THEN
  --
  -- Due difetti in quattro righe:
  --   1. cominciava con auth.uid() IS NOT NULL, cioe' "se non sei loggato non ti
  --      controllo". Provato il 22 set: da anon la funzione passava la guardia.
  --   2. dei cinque ruoli citati ne esiste uno solo, staff_istruttore_sr. Gli altri
  --      quattro non sono nel CHECK profile_data_staff_role_check, quindi segreteria
  --      e creator venivano respinti. Marco passava solo per l'UUID scritto a mano.
  --
  -- RUOLI AMMESSI: [da decidere]
  --   Proposta, in attesa della decisione di Marco:
  --     staff_creator, staff_segreteria, staff_istruttore_sr, staff_istruttore_tutor
  --   Il cruscotto mostra nome, cognome, telefono, email, lezioni residue e scadenze
  --   di ogni allievo: e' la lista di chi va richiamato. Gli altri tre ruoli
  --   (staff_istruttore_jr, staff_assistente, staff_monitor) restano fuori.
  --   Per cambiare, si tocca la sola lista qui sotto.
  IF NOT EXISTS (
    SELECT 1 FROM profile_data pd0
    WHERE pd0.user_id = auth.uid()
      AND pd0.staff_role IN (
        'staff_creator', 'staff_segreteria', 'staff_istruttore_sr', 'staff_istruttore_tutor'
      )
  ) THEN
    RAISE EXCEPTION 'non autorizzato';
  END IF;

  RETURN QUERY
  WITH base AS (
    SELECT
      pd.persona_id, pd.user_id, pe.nome, pe.cognome, pe.telefono, pe.email,
      pd.corso_attivo, pd.prima_done, pd.data_prima_lezione,
      pd.meta_open_paid, pd.acconto_open_paid, pd.advance_paid, pd.intro_paid, pd.evo_paid,
      -- DEBITO-190: prenotabili e in_agenda dalla view, non piu' dalle colonne salvate
      COALESCE(co.prenotabili, 0) AS r_open,   COALESCE(co.in_agenda, 0) AS f_open,
      COALESCE(ca.prenotabili, 0) AS r_adv,    COALESCE(ca.in_agenda, 0) AS f_adv,
      COALESCE(ci.prenotabili, 0) AS r_intro,  COALESCE(ci.in_agenda, 0) AS f_intro,
      COALESCE(ce.prenotabili, 0) AS r_evo,    COALESCE(ce.in_agenda, 0) AS f_evo,
      pd.scadenza_consumo_open, pd.scadenza_consumo_advance, pd.scadenza_consumo_intro, pd.scadenza_consumo_evo,
      EXISTS (
        SELECT 1 FROM iscrizioni_corso ic
        WHERE ic.user_id = pd.user_id AND ic.tipo_corso = 'open' AND ic.stato_pagamento = 'saldato'
      ) AS open_fonte,
      ldr.recensione_inviata_at AS rec_at
    FROM profile_data pd
    JOIN persone pe ON pe.id = pd.persona_id
    LEFT JOIN contatori_corso co ON co.user_id = pd.user_id AND co.tipo_corso = 'open'
    LEFT JOIN contatori_corso ca ON ca.user_id = pd.user_id AND ca.tipo_corso = 'advance'
    LEFT JOIN contatori_corso ci ON ci.user_id = pd.user_id AND ci.tipo_corso = 'intro_corda'
    LEFT JOIN contatori_corso ce ON ce.user_id = pd.user_id AND ce.tipo_corso = 'evo_corda'
    LEFT JOIN LATERAL (
      SELECT ld.recensione_inviata_at FROM lead_data ld
      WHERE ld.persona_id = pd.persona_id
      ORDER BY ld.recensione_inviata_at DESC NULLS LAST LIMIT 1
    ) ldr ON true
    WHERE pd.staff_role IS NULL
  ),
  calc AS (
    SELECT b.*,
      (COALESCE(b.meta_open_paid,false) OR COALESCE(b.acconto_open_paid,false) OR b.open_fonte) AS open_pagato,
      ((COALESCE(b.meta_open_paid,false) OR COALESCE(b.acconto_open_paid,false) OR b.open_fonte) AND b.r_open=0  AND b.f_open=0)  AS open_fin,
      (COALESCE(b.advance_paid,false) AND b.r_adv=0   AND b.f_adv=0)   AS adv_fin,
      (COALESCE(b.intro_paid,false)   AND b.r_intro=0 AND b.f_intro=0) AS intro_fin,
      (COALESCE(b.evo_paid,false)     AND b.r_evo=0   AND b.f_evo=0)   AS evo_fin,
      ( (b.r_open>0  AND b.scadenza_consumo_open    IS NOT NULL AND b.scadenza_consumo_open    < now())
     OR (b.r_adv>0   AND b.scadenza_consumo_advance IS NOT NULL AND b.scadenza_consumo_advance < now())
     OR (b.r_intro>0 AND b.scadenza_consumo_intro   IS NOT NULL AND b.scadenza_consumo_intro   < now())
     OR (b.r_evo>0   AND b.scadenza_consumo_evo     IS NOT NULL AND b.scadenza_consumo_evo     < now()) ) AS scaduto
    FROM base b
  )
  SELECT
    c.persona_id, c.user_id, c.nome, c.cognome, c.telefono, c.email,
    CASE
      WHEN c.evo_fin                                THEN 'evo_finito'
      WHEN c.corso_attivo='evo_corda'               THEN 'in_evo'
      WHEN c.intro_fin AND NOT COALESCE(c.evo_paid,false)     THEN 'intro_finito_no_evo'
      WHEN c.corso_attivo='intro_corda'             THEN 'in_intro'
      WHEN c.adv_fin AND NOT COALESCE(c.intro_paid,false)     THEN 'advance_finito_no_intro'
      WHEN c.corso_attivo='advance'                 THEN 'in_advance'
      WHEN c.open_fin AND NOT COALESCE(c.advance_paid,false)  THEN 'open_finito_no_advance'
      WHEN c.corso_attivo='open'                    THEN 'in_open'
      WHEN COALESCE(c.prima_done,false) AND c.corso_attivo IS NULL
           AND NOT c.open_pagato
           AND NOT COALESCE(c.advance_paid,false)
           AND NOT COALESCE(c.intro_paid,false)
           AND NOT COALESCE(c.evo_paid,false)       THEN 'prima_non_proseguita'
      ELSE NULL
    END AS bucket,
    c.corso_attivo,
    c.r_open, c.r_adv, c.r_intro, c.r_evo,
    c.scadenza_consumo_open, c.scadenza_consumo_advance, c.scadenza_consumo_intro, c.scadenza_consumo_evo,
    (c.f_open + c.f_adv + c.f_intro + c.f_evo)::int AS prenotazioni_future,
    c.scaduto AS alert_scaduto,
    c.data_prima_lezione,
    c.rec_at
  FROM calc c
  WHERE c.scaduto
     OR CASE
      WHEN c.evo_fin THEN true
      WHEN c.corso_attivo IS NOT NULL THEN true
      WHEN c.intro_fin AND NOT COALESCE(c.evo_paid,false) THEN true
      WHEN c.adv_fin AND NOT COALESCE(c.intro_paid,false) THEN true
      WHEN c.open_fin AND NOT COALESCE(c.advance_paid,false) THEN true
      WHEN COALESCE(c.prima_done,false) AND c.corso_attivo IS NULL
           AND NOT c.open_pagato AND NOT COALESCE(c.advance_paid,false)
           AND NOT COALESCE(c.intro_paid,false) AND NOT COALESCE(c.evo_paid,false) THEN true
      ELSE false
     END
  ORDER BY c.cognome NULLS LAST, c.nome;
END;
$function$;

COMMIT;

-- ==========================================================================
-- V-firme · atteso: una riga sola, firme = 1
-- ==========================================================================
SELECT p.proname, count(*) AS firme
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_cruscotto_percorsi'
GROUP BY p.proname;

-- ==========================================================================
-- V-accesso · chi entra e chi no
-- ==========================================================================
-- Da anon deve dare 'non autorizzato', non una tabella:
--   SET ROLE anon; SELECT count(*) FROM get_cruscotto_percorsi(); RESET ROLE;
--
-- Chi passera' la guardia, per ruolo (nessun dato personale, solo conteggi):
SELECT coalesce(staff_role,'(nessun ruolo)') AS staff_role, count(*) AS persone,
       CASE WHEN staff_role IN ('staff_creator','staff_segreteria',
                                'staff_istruttore_sr','staff_istruttore_tutor')
            THEN 'entra' ELSE 'respinto' END AS col_file_05
FROM profile_data GROUP BY 1 ORDER BY 3, 2 DESC;

-- ==========================================================================
-- IL SECONDO GUASTO · il cast che manca — NON incluso sopra, decide Marco
-- ==========================================================================
-- Serve a far tornare a funzionare il cruscotto. Non e' una guardia e non e'
-- questo cantiere: nasce da DEBITO-190, quando i residui sono passati dalle
-- colonne salvate alla vista contatori_corso.
--
-- Dentro il CTE base, quattro righe da cambiare:
--
--   COALESCE(co.prenotabili, 0) AS r_open     ->  COALESCE(co.prenotabili, 0)::int AS r_open
--   COALESCE(ca.prenotabili, 0) AS r_adv      ->  COALESCE(ca.prenotabili, 0)::int AS r_adv
--   COALESCE(ci.prenotabili, 0) AS r_intro    ->  COALESCE(ci.prenotabili, 0)::int AS r_intro
--   COALESCE(ce.prenotabili, 0) AS r_evo      ->  COALESCE(ce.prenotabili, 0)::int AS r_evo
--
-- In alternativa si cambia la firma a bigint, ma allora la firma cambia davvero e
-- serve un DROP FUNCTION prima del CREATE. Il cast e' piu' piccolo e non tocca la firma.
--
-- Per sapere quali altre funzioni hanno lo stesso rischio dopo DEBITO-190,
-- cioe' dichiarano integer e leggono una colonna bigint di contatori_corso:
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND pg_get_functiondef(p.oid) ~ 'contatori_corso'
  AND pg_get_functiondef(p.oid) ~ 'integer'
ORDER BY 1;
