-- ════════════════════════════════════════════════════════════════════
-- CORSO MANOVRA IN SOSTA KATACLIMB — correzioni 26 ott 2026 (decisioni Marco 26 ott)
-- Da lanciare DOPO manovra_sosta_2026-10-25.sql e PRIMA di stripe-worker v3.90.
-- Solo CREATE OR REPLACE di due funzioni: stessa firma, stessi permessi (le GRANT restano).
--
-- a. crea_slot_manovra: messaggi d'errore con il nome completo "Corso Manovra in Sosta KataClimb".
-- b. puo_iscriversi_manovra: risponde solo per l'utente collegato (auth.uid()), per lo staff
--    (is_staff()) e per le chiamate server: service_role (stripe-worker v3.90 la chiama con la
--    service key, dove auth.uid() e' vuoto) e SQL Editor (nessun JWT: auth.role() nullo).
--    Chiunque altro: errore. Controllo a prova di NULL: nel dubbio nega (anonimo compreso).
-- c. crea_slot_manovra: prima di creare lo slot ricontrolla che l'ora sia ancora libera
--    nell'agenda di Mello, con le stesse regole di proponi_slot_manovra; se no, dice quale
--    e' il problema e cosa fare. Un lucchetto di transazione mette in fila due "Crea lo slot"
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
DECLARE v_slot uuid; v_n int; v_fine time; v_dow int; v_conflitto text;
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
  SELECT 'dalle ' || to_char(c.ora_inizio, 'HH24:MI') || ' alle ' || to_char(c.ora_fine, 'HH24:MI') INTO v_conflitto
    FROM corsi_attivi_settimanali c
   WHERE c.istruttore_id = p_istruttore AND c.status = 'attivo'
     AND ((c.data_evento IS NULL AND c.giorno_settimana = v_dow) OR c.data_evento = p_data)
     AND c.ora_inizio < v_fine AND c.ora_fine > p_ora_inizio
     AND NOT EXISTS (SELECT 1 FROM slot_chiusure sc WHERE sc.slot_id = c.id AND sc.data = p_data)
   LIMIT 1;
  IF v_conflitto IS NOT NULL THEN
    RAISE EXCEPTION 'Il % alle % l''istruttore ha già una lezione %: l''ora non è più libera. Ricarica le ore libere in Segreteria e scegline un''altra.', to_char(p_data, 'DD/MM'), to_char(p_ora_inizio, 'HH24:MI'), v_conflitto;
  END IF;
  SELECT 'dalle ' || to_char(s.ora_inizio, 'HH24:MI') || ' alle ' || to_char(s.ora_fine, 'HH24:MI') INTO v_conflitto
    FROM impegni_staff s JOIN istruttori i ON i.user_id = s.user_id
   WHERE i.id = p_istruttore AND s.data = p_data AND s.stato <> 'ritirato'
     AND s.ora_inizio < v_fine AND s.ora_fine > p_ora_inizio
   LIMIT 1;
  IF v_conflitto IS NOT NULL THEN
    RAISE EXCEPTION 'Il % alle % l''istruttore ha già un impegno in agenda %: l''ora non è più libera. Ricarica le ore libere in Segreteria e scegline un''altra.', to_char(p_data, 'DD/MM'), to_char(p_ora_inizio, 'HH24:MI'), v_conflitto;
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
