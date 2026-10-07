-- ============================================================================
-- SALA CON MONITOR · 01 — Osservazione e nota di sala su righe separate
-- Data: 2026-10-07 · Preparata per Marco · APPLICATA 2026-10-07 (12:25, prove DOPO passate)
-- Da eseguire PRIMA di 02_compensi_per_turno.sql (02 lo controlla).
--
-- IL PROBLEMA
--   osservazioni_allievo ha UNIQUE (persona_id, istruttore_user_id, data).
--   salva_osservazione (osservazione dell'istruttore) e monitor_segna (nota di
--   sala) fanno entrambe ON CONFLICT su quella chiave. Un istruttore che lo
--   stesso giorno, sullo stesso allievo, fa tutte e due le cose:
--     · prima la nota di sala, poi l'osservazione -> salva_osservazione
--       sovrascrive contesto e note: la nota di sala sparisce, e sparisce anche
--       dai compensi (che contano contesto='sala_monitor');
--     · prima l'osservazione, poi la nota di sala -> monitor_segna accoda la riga
--       oraria dentro l'osservazione, che resta con il contesto del corso: la
--       sala non si vede e non si conta.
--   oggi.html v2.18 blocca i due casi in pagina; questo file li toglie alla radice.
--
-- LA CORREZIONE
--   Al posto del vincolo unico, due indici unici parziali sulla stessa chiave:
--   uno per le osservazioni (contesto diverso da 'sala_monitor'), uno per la sala.
--   Le due RPC dichiarano su quale dei due fanno ON CONFLICT.
--   salva_osservazione rifiuta contesto='sala_monitor': la sala si scrive solo
--   con monitor_segna.
--   Tabella vuota al 7 ott (0 righe): nessun dato da sistemare.
--   CREATE OR REPLACE conserva i GRANT delle funzioni.
-- ============================================================================


-- ─── PRIMA · stato attuale ──────────────────────────────────────────────────
-- Atteso: una riga, il vincolo osservazioni_allievo_persona_id_istruttore_user_id_data_key.
SELECT conname, pg_get_constraintdef(oid) AS definizione
FROM pg_constraint
WHERE conrelid = 'public.osservazioni_allievo'::regclass AND contype = 'u';

-- Righe gia' mescolate (osservazione con dentro righe orarie di sala). Atteso: 0.
SELECT id, persona_id, istruttore_user_id, data, contesto, note
FROM public.osservazioni_allievo
WHERE contesto IS DISTINCT FROM 'sala_monitor'
  AND note ~ '(^|\n)\d{1,2}:\d{2} — ';


-- ─── CORREZIONE ─────────────────────────────────────────────────────────────
BEGIN;

ALTER TABLE public.osservazioni_allievo
  DROP CONSTRAINT osservazioni_allievo_persona_id_istruttore_user_id_data_key;

CREATE UNIQUE INDEX osservazioni_allievo_oss_giorno_key
  ON public.osservazioni_allievo (persona_id, istruttore_user_id, data)
  WHERE contesto IS DISTINCT FROM 'sala_monitor';

CREATE UNIQUE INDEX osservazioni_allievo_sala_giorno_key
  ON public.osservazioni_allievo (persona_id, istruttore_user_id, data)
  WHERE contesto = 'sala_monitor';

CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE);
BEGIN
  IF NOT is_mio_allievo(p_persona_id) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  IF p->>'contesto' = 'sala_monitor' THEN RAISE EXCEPTION 'La Sala con Monitor si annota con monitor_segna'; END IF;
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, obiettivo, interesse, aree_miglioramento,
    socializzazione, socializzazione_nota, fiducia, fiducia_nota, autostima, autostima_nota,
    concentrazione, concentrazione_nota, gestione_paura, gestione_paura_nota, note)
  VALUES (p_persona_id, auth.uid(), v_data, p->>'contesto', p->>'obiettivo', p->>'interesse', p->>'aree_miglioramento',
    (p->>'socializzazione')::smallint, p->>'socializzazione_nota', (p->>'fiducia')::smallint, p->>'fiducia_nota',
    (p->>'autostima')::smallint, p->>'autostima_nota', (p->>'concentrazione')::smallint, p->>'concentrazione_nota',
    (p->>'gestione_paura')::smallint, p->>'gestione_paura_nota', p->>'note')
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto IS DISTINCT FROM 'sala_monitor' DO UPDATE SET
    contesto=EXCLUDED.contesto, obiettivo=EXCLUDED.obiettivo, interesse=EXCLUDED.interesse, aree_miglioramento=EXCLUDED.aree_miglioramento,
    socializzazione=EXCLUDED.socializzazione, socializzazione_nota=EXCLUDED.socializzazione_nota,
    fiducia=EXCLUDED.fiducia, fiducia_nota=EXCLUDED.fiducia_nota, autostima=EXCLUDED.autostima, autostima_nota=EXCLUDED.autostima_nota,
    concentrazione=EXCLUDED.concentrazione, concentrazione_nota=EXCLUDED.concentrazione_nota,
    gestione_paura=EXCLUDED.gestione_paura, gestione_paura_nota=EXCLUDED.gestione_paura_nota, note=EXCLUDED.note, updated_at=now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'data',v_data);
END $function$;

CREATE OR REPLACE FUNCTION public.monitor_segna(p_persona_id uuid, p_su_cosa text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_turno uuid; v_id uuid; v_riga text;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
  IF length(trim(coalesce(p_su_cosa,''))) < 3 THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato'; END IF;
  SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
  IF v_turno IS NULL THEN INSERT INTO turni_monitor (monitor_user_id) VALUES (auth.uid()) RETURNING id INTO v_turno; END IF;
  v_riga := to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI')||' — '||trim(p_su_cosa)||COALESCE(' ('||trim(p_note)||')','');
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, note)
  VALUES (p_persona_id, auth.uid(), CURRENT_DATE, 'sala_monitor', v_riga)
  ON CONFLICT (persona_id, istruttore_user_id, data) WHERE contesto = 'sala_monitor' DO UPDATE
    SET note = COALESCE(osservazioni_allievo.note,'')||E'\n'||v_riga, updated_at=now()
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',v_turno);
END $function$;

COMMIT;


-- ─── DOPO · 1 · indici al posto del vincolo ─────────────────────────────────
-- Atteso: 0 righe (il vincolo non c'e' piu').
SELECT conname FROM pg_constraint
WHERE conrelid = 'public.osservazioni_allievo'::regclass AND contype = 'u';
-- Atteso: 2 righe, oss_giorno_key (contesto IS DISTINCT FROM ...) e sala_giorno_key (contesto = ...).
SELECT indexrelid::regclass AS indice, pg_get_indexdef(indexrelid) AS definizione
FROM pg_index
WHERE indrelid = 'public.osservazioni_allievo'::regclass AND indisunique AND NOT indisprimary;

-- ─── DOPO · 2 · prova vera, annullata con ROLLBACK (nessuna riga resta) ──────
-- Eseguire il blocco intero in UNA sola chiamata. Si finge di essere Mello
-- (e4841ae2-…) su un suo allievo: osservazione, nota di sala, seconda osservazione.
-- Atteso nell'ultima SELECT: DUE righe dello stesso giorno —
--   contesto 'open', fiducia 5, note 'PROVA osservazione 2'
--   contesto 'sala_monitor', note 'HH:MM — PROVA sala'
-- Prima della correzione la seconda osservazione avrebbe cancellato la nota di sala.
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'e4841ae2-aeef-4007-839d-7837d197195b', true);
SELECT set_config('request.jwt.claims', '{"sub":"e4841ae2-aeef-4007-839d-7837d197195b","role":"authenticated"}', true);
CREATE TEMP TABLE _prova ON COMMIT DROP AS SELECT persona_id FROM public.get_miei_allievi() LIMIT 1;
SELECT public.salva_osservazione((SELECT persona_id FROM _prova), '{"contesto":"open","fiducia":4,"note":"PROVA osservazione"}');
SELECT public.monitor_segna((SELECT persona_id FROM _prova), 'PROVA sala', NULL);
SELECT public.salva_osservazione((SELECT persona_id FROM _prova), '{"contesto":"open","fiducia":5,"note":"PROVA osservazione 2"}');
SELECT contesto, fiducia, note FROM public.osservazioni_allievo
WHERE persona_id = (SELECT persona_id FROM _prova) AND data = CURRENT_DATE
  AND istruttore_user_id = 'e4841ae2-aeef-4007-839d-7837d197195b'
ORDER BY contesto;
ROLLBACK;
