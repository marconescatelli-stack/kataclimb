-- ════════════════════════════════════════════════════════════════════
-- CORSO MANOVRA IN SOSTA KATACLIMB — correzioni 26 ott 2026 (decisioni Marco 26 ott)
-- Da lanciare DOPO manovra_sosta_2026-10-25.sql e PRIMA di stripe-worker v3.90.
-- APPLICATO il 26 ott 2026 ("vai" di Marco) come migrazione manovra_sosta_correzioni_2026_10_26
-- (versione 20261026180641). Corpo live verificato identico a questo file (md5 di prosrc).
-- Solo CREATE OR REPLACE di due funzioni: stessa firma, stessi permessi (le GRANT restano).
--
-- a. crea_slot_manovra: messaggi d'errore con il nome completo "Corso Manovra in Sosta KataClimb".
-- b. puo_iscriversi_manovra: risponde solo per l'utente collegato (auth.uid()), per lo staff
--    (is_staff()) e per le chiamate server: service_role (stripe-worker v3.90 la chiama con la
--    service key, dove auth.uid() e' vuoto) e SQL Editor (nessun JWT: auth.role() nullo).
--    Chiunque altro: errore. Controllo a prova di NULL: nel dubbio nega (anonimo compreso).
-- c. crea_slot_manovra: prima di creare lo slot ricontrolla che l'ora sia ancora libera
--    nell'agenda di Mello, con le stesse regole di proponi_slot_manovra; se no, dice quale
--    e' il problema e cosa fare. Se l'ora e' occupata il messaggio dice l'orario e il NOME
--    COMPLETO di cosa la occupa (Marco 26 ott), es. "Mello è già impegnato dalle 17:00 alle
--    18:00 nel Corso Intro Corda KataClimb: scegli un'altra ora libera." Nomi dalla stessa
--    mappa di oggi.html (NOME_CORSO) + agenda; mai la chiave tecnica. Un lucchetto di transazione mette in fila due "Crea lo slot"
--    premuti nello stesso momento (il secondo vede lo slot del primo e si ferma).
-- ════════════════════════════════════════════════════════════════════

BEGIN;

-- ── b. puo_iscriversi_manovra ──────────────────────────────────────
CREATE OR REPLACE FUNCTION public.puo_iscriversi_manovra(p_user uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- ogni termine e' true/false, mai NULL: un caso incerto (es. anonimo, auth.uid() vuoto) da' errore
  IF NOT (coalesce(p_user IS NOT NULL AND p_user = auth.uid(), false)
          OR coalesce(is_staff(), false)
          OR coalesce(auth.role() = 'service_role', false)
          OR auth.role() IS NULL) THEN
    RAISE EXCEPTION 'Puoi verificare solo la tua iscrizione al Corso Manovra in Sosta KataClimb';
  END IF;
  RETURN EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user AND tipo_corso = 'evo_corda'
                   AND status IN ('terminata','completata_pregressa'));
END $function$;

-- ── a + c. crea_slot_manovra ───────────────────────────────────────
CREATE OR REPLACE FUNCTION public.crea_slot_manovra(p_data date, p_ora_inizio time without time zone, p_istruttore uuid DEFAULT 'df805770-093b-453e-8e12-1659a1bdbc55'::uuid)
 RETURNS TABLE(slot_id uuid, prenotati integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_slot uuid; v_n int; v_fine time; v_dow int; v_conflitto text; v_ist text;
BEGIN
  IF NOT is_staff() THEN RAISE EXCEPTION 'Solo lo staff può creare lo slot del Corso Manovra in Sosta KataClimb'; END IF;
  IF p_data <= current_date THEN RAISE EXCEPTION 'La data deve essere da domani in poi'; END IF;

  -- un "Crea lo slot" alla volta: il secondo aspetta il primo e poi vede il suo slot
  PERFORM pg_advisory_xact_lock(hashtext('crea_slot_manovra'));

  IF NOT EXISTS (SELECT 1 FROM lista_manovra_sosta WHERE stato = 'in_lista') THEN
    RAISE EXCEPTION 'Nessuno in lista per il Corso Manovra in Sosta KataClimb';
  END IF;

  v_fine := p_ora_inizio + interval '1 hour';
  v_dow  := extract(dow FROM p_data)::int;

  -- c. l'ora e' ancora libera? stesse regole di proponi_slot_manovra, un motivo per volta
  IF EXISTS (SELECT 1 FROM giorni_chiusi gc WHERE gc.data = p_data) THEN
    RAISE EXCEPTION 'Il % l''Accademia è chiusa: ricarica le ore libere in Segreteria e scegli un altro giorno.', to_char(p_data, 'DD/MM');
  END IF;
  IF v_dow = 0
     OR (v_dow = 6 AND (p_ora_inizio < '14:00' OR v_fine > '18:00'))
     OR (v_dow BETWEEN 1 AND 5 AND (p_ora_inizio < '17:00' OR v_fine > '22:00')) THEN
    RAISE EXCEPTION 'Alle % del % l''Accademia non ha ore per il Corso Manovra in Sosta KataClimb (lun–ven 17–22, sab 14–18): ricarica le ore libere in Segreteria e scegline un''altra.', to_char(p_ora_inizio, 'HH24:MI'), to_char(p_data, 'DD/MM');
  END IF;
  -- chi e' l'istruttore: il soprannome tra parentesi se c'e' ("Marco Mellozzini (Mello)" -> Mello)
  SELECT coalesce(substring(i.nome FROM '\(([^)]+)\)'), i.nome, 'L''istruttore') INTO v_ist
    FROM istruttori i WHERE i.id = p_istruttore;
  v_ist := coalesce(v_ist, 'L''istruttore');

  -- cosa occupa l'ora: lezione dell'istruttore (slot settimanale o datato) oppure impegno in agenda staff
  WITH occupa AS (
    SELECT c.ora_inizio AS ora_i, c.ora_fine AS ora_f, c.tipo_corso AS tipo, c.fascia, false AS turno_monitor
      FROM corsi_attivi_settimanali c
     WHERE c.istruttore_id = p_istruttore AND c.status = 'attivo'
       AND ((c.data_evento IS NULL AND c.giorno_settimana = v_dow) OR c.data_evento = p_data)
       AND c.ora_inizio < v_fine AND c.ora_fine > p_ora_inizio
       AND NOT EXISTS (SELECT 1 FROM slot_chiusure sc WHERE sc.slot_id = c.id AND sc.data = p_data)
    UNION ALL
    SELECT s.ora_inizio, s.ora_fine, cs.tipo_corso, cs.fascia, (s.tipo = 'monitor')
      FROM impegni_staff s
      JOIN istruttori i ON i.user_id = s.user_id
      LEFT JOIN corsi_attivi_settimanali cs ON cs.id = s.slot_id
     WHERE i.id = p_istruttore AND s.data = p_data AND s.stato <> 'ritirato'
       AND s.ora_inizio < v_fine AND s.ora_fine > p_ora_inizio
  ), nominato AS (
    SELECT ora_i, ora_f,
           CASE
             WHEN turno_monitor THEN 'turno di Sala con Monitor'
             WHEN tipo = 'prima_lezione'          THEN 'Prima Lezione Adulti'
             WHEN tipo = 'prima_lezione_genitori' THEN 'Prima Lezione Genitori'
             WHEN tipo = 'prima_lezione_bambini'  THEN 'Prima Lezione Bambini (6–11)'
             WHEN tipo = 'prima_lezione_ragazzi'  THEN 'Prima Lezione Ragazzi (12–17)'
             WHEN tipo = 'prima_lezione_privata'  THEN 'Prima Lezione Privata Speciale'
             WHEN tipo = 'prima_lezione_scuola'   THEN 'Prima Lezione · Scuole'
             WHEN tipo = 'scuola_mini'            THEN 'Mini percorso · Scuole'
             WHEN tipo = 'open'        THEN 'Corso Open KataClimb'
             WHEN tipo = 'advance'     THEN 'Corso Advance KataClimb'
             WHEN tipo = 'intro_corda' THEN 'Corso Intro Corda KataClimb'
             WHEN tipo = 'evo_corda'   THEN 'Corso Evo Corda KataClimb'
             WHEN tipo = 'fly'         THEN 'Corso Fly KataClimb'
             WHEN tipo = 'bambini' AND fascia = 'bambini' THEN 'Corso Bambini (6–11)'
             WHEN tipo = 'bambini' AND fascia = 'ragazzi' THEN 'Corso Ragazzi (12–17)'
             WHEN tipo = 'bambini'     THEN 'Corso Bambini e Ragazzi'
             WHEN tipo = 'giovani'     THEN 'Corso Giovani KataClimb (18–24)'
             WHEN tipo = 'senior'      THEN 'Corso Senior KataClimb (over 60)'
             WHEN tipo = 'genitori'    THEN 'Corso Genitori KataClimb'
             WHEN tipo = 'evo_ragazzi' THEN 'Corso Evo Ragazzi'
             WHEN tipo = 'expert'      THEN 'Corso Expert'
             WHEN tipo = 'lab'         THEN 'Lab'
             WHEN tipo = 'monitor'     THEN 'Sala con Monitor'
             WHEN tipo = 'manovra_sosta' THEN 'Corso Manovra in Sosta KataClimb'
           END AS nome
      FROM occupa
  )
  SELECT 'dalle ' || to_char(ora_i, 'HH24:MI') || ' alle ' || to_char(ora_f, 'HH24:MI')
         || CASE WHEN nome IS NULL THEN ' con un altro impegno'
                 WHEN nome LIKE 'Prima %' OR nome LIKE 'Sala %' THEN ' nella ' || nome
                 ELSE ' nel ' || nome END
    INTO v_conflitto
    FROM nominato ORDER BY ora_i LIMIT 1;
  IF v_conflitto IS NOT NULL THEN
    RAISE EXCEPTION '% è già impegnato %: scegli un''altra ora libera (ricarica le ore libere in Segreteria).', v_ist, v_conflitto;
  END IF;

  INSERT INTO corsi_attivi_settimanali
    (tipo_corso, istruttore_id, giorno_settimana, ora_inizio, ora_fine, capienza_target, capienza_max,
     status, fascia, data_evento, note)
  VALUES ('manovra_sosta', p_istruttore, v_dow, p_ora_inizio, v_fine,
          2, 4, 'attivo', 'adulti', p_data, 'Corso Manovra in Sosta KataClimb — parte indoor. Decisione Marco 25 ott 2026')
  RETURNING id INTO v_slot;

  UPDATE lista_manovra_sosta SET stato = 'prenotato', slot_id = v_slot, data_lezione = p_data, updated_at = now()
  WHERE id IN (SELECT id FROM lista_manovra_sosta WHERE stato = 'in_lista' ORDER BY created_at LIMIT 4);
  GET DIAGNOSTICS v_n = ROW_COUNT;

  RETURN QUERY SELECT v_slot, v_n;
END $function$;

-- Prova: prima ROLLBACK, poi COMMIT.
ROLLBACK;
-- COMMIT;
