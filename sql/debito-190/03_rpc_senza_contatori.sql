-- ============================================================================
-- DEBITO-190 · Fase B · 03 — Le funzioni smettono di fare aritmetica
-- Data: 2026-09-22 · Decisioni: Marco
--
-- ⚠ FILE INCOMPLETO — PARTE 1 DI 2. NON APPLICARE ANCORA.
--   Qui dentro c'e' solo cio' che NON dipende dalla decisione aperta sul
--   no-show (vedi "NODO APERTO" qui sotto). Le funzioni che la toccano
--   — applica_no_show, disdici_corso, rimarca_presenza_corso e gli accrediti —
--   arrivano nella parte 2, dopo la risposta di Marco.
--
-- REGOLA
--   Ogni funzione scrive SOLO lo stato della riga in prenotazioni_corso (o
--   crea/aggiorna iscrizioni_corso per gli accrediti). Nessuna tocca piu'
--   le colonne *_residue / *_no_show_count / *_spostamenti_residui.
--   Ogni guardia legge da contatori_corso.
--
-- ORDINE DI APPLICAZIONE DENTRO QUESTO FILE
--   1. helper di lettura   2. trigger da togliere   3. trigger che resta
--   4. funzioni di servizio                        5. funzioni morte
--   L'ordine conta: gli helper vanno prima di chi li chiama.
--
-- ============================================================================
-- NODO APERTO — la penale del no-show cambia di significato
-- ============================================================================
--   Codice live: applica_no_show NON toglie una lezione al primo no-show.
--   Incrementa no_show_count e solo al raggiungimento della soglia
--   (tipi_corso_config.noshow_soglia_penalita = 2 su tutti i corsi) azzera il
--   contatore E toglie una lezione. In pratica: DUE no-show = UNA lezione persa.
--
--   Modello nuovo (tabella degli stati ratificata da Marco): 'assente' consuma
--   la lezione, sempre. In pratica: UN no-show = UNA lezione persa.
--
--   E' un raddoppio della penale, ed e' una regola di business, non un
--   dettaglio tecnico. Non la cambio di mia iniziativa.
--   Impatto sui dati di oggi: 1 sola riga 'assente' a DB (Corso Open) e
--   1 solo profilo con no_show_count = 1. Qualunque scelta, oggi non fa danni.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1 · HELPER DI LETTURA
-- ---------------------------------------------------------------------------

-- _col_lezioni_residue / _col_spostamenti_residui: NON si toccano qui.
-- Restano a mappare nome-corso → nome-colonna finche' le colonne esistono.
-- Spariscono in Fase D insieme alle colonne (file 05).

-- ---------------------------------------------------------------------------
-- _get_lezioni_residue
--   PRIMA: leggeva la colonna salvata (lezioni_residue, advance_…, ecc.) con
--          EXECUTE format su profile_data.
--   DOPO:  legge "prenotabili ora" da contatori_corso. Stessa semantica del
--          contatore vecchio, che scalava alla prenotazione, quindi ogni
--          chiamante che non abbiamo ancora riscritto continua a funzionare —
--          ma legge la verita' invece di un numero ritoccato a mano.
--   EFFETTO COLLATERALE VOLUTO: se non c'e' un'iscrizione attiva a quel corso
--   la funzione torna NULL, e chi la chiama (prenota_corso) rifiuta. I
--   "crediti orfani" trovati dalla 02 — 12 righe su 10 allievi, fra cui 6
--   lezioni Open su chi non ha mai avuto un'iscrizione Open — smettono da
--   soli di essere prenotabili, senza aspettare la bonifica della Fase D.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._get_lezioni_residue(p_user_id uuid, p_corso text)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT c.prenotabili
  FROM public.contatori_corso c
  WHERE c.user_id = p_user_id AND c.tipo_corso = p_corso;
$function$;

COMMENT ON FUNCTION public._get_lezioni_residue(uuid, text) IS
  'DEBITO-190: non legge piu'' il contatore salvato ma "prenotabili ora" da '
  'contatori_corso. NULL = nessuna iscrizione attiva a quel corso.';

-- ---------------------------------------------------------------------------
-- _get_spostamenti_residui
--   PRIMA: leggeva la colonna salvata *_spostamenti_residui.
--   DOPO:  budget (iscrizioni_corso.disdette_no_show_max) meno gli spostamenti
--          gia' usati (COUNT delle righe 'cancellato_in_tempo').
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._get_spostamenti_residui(p_user_id uuid, p_corso text)
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT c.spostamenti_residui
  FROM public.contatori_corso c
  WHERE c.user_id = p_user_id AND c.tipo_corso = p_corso;
$function$;

COMMENT ON FUNCTION public._get_spostamenti_residui(uuid, text) IS
  'DEBITO-190: budget disdette_no_show_max meno i cancellato_in_tempo contati. '
  'NULL = nessuna iscrizione attiva a quel corso.';

-- ---------------------------------------------------------------------------
-- _snapshot_contabile (DEBITO-178)
--   PRIMA: fotografava i contatori SALVATI (no_show_count, colonne *_residue,
--          *_spostamenti_residui) piu' corso_attivo e funnel_stage.
--   DOPO:  fotografa i valori DERIVATI della view. Le chiavi vecchie restano
--          nel jsonb con lo stesso nome, cosi' l'effetto_contabile gia'
--          registrato sulle righe storiche resta confrontabile; si aggiungono
--          le voci nuove (fatte, consumate, in_agenda, prenotabili).
--   NOTA: 'no_show_count' ora e' il COUNT delle righe 'assente' di QUEL corso,
--          non piu' il contatore a soglia globale del profilo.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._snapshot_contabile(p_user_id uuid, p_tipo_corso text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_c          record;
  v_corso_att  text;
  v_persona_id uuid;
  v_funnel     text;
BEGIN
  SELECT corso_attivo, persona_id
    INTO v_corso_att, v_persona_id
    FROM profile_data WHERE user_id = p_user_id;

  SELECT * INTO v_c
    FROM contatori_corso
    WHERE user_id = p_user_id AND tipo_corso = p_tipo_corso;

  IF v_persona_id IS NOT NULL THEN
    SELECT funnel_stage INTO v_funnel FROM lead_data WHERE persona_id = v_persona_id;
  END IF;

  RETURN jsonb_build_object(
    -- chiavi storiche, stesso nome di prima
    'no_show_count',   v_c.ghostate,
    'corso_attivo',    v_corso_att,
    'col_lezioni',     _col_lezioni_residue(p_tipo_corso),
    'lezioni',         v_c.prenotabili,
    'col_spostamenti', _col_spostamenti_residui(p_tipo_corso),
    'spostamenti',     v_c.spostamenti_residui,
    'funnel_stage',    v_funnel,
    -- voci nuove, derivate
    'totali',          v_c.totali,
    'fatte',           v_c.fatte,
    'ghostate',        v_c.ghostate,
    'disdette_tardi',  v_c.disdette_tardi,
    'consumate',       v_c.consumate,
    'restano',         v_c.restano,
    'in_agenda',       v_c.in_agenda,
    'prenotabili',     v_c.prenotabili,
    'fonte',           'contatori_corso'
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- _chiudi_corso_se_finito
--   PRIMA: leggeva _get_lezioni_residue (contatore salvato) e contava a parte
--          le prenotazioni future, poi decideva con "lezioni <= 0 AND 0 future".
--   DOPO:  decide con restano = 0 AND in_agenda = 0, letti dalla view.
--          Il resto — azzerare corso_attivo, spostare il funnel a concluso_*,
--          lasciare la nota nel fascicolo — e' invariato.
-- ---------------------------------------------------------------------------
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

  -- DEBITO-190: la decisione viene dalla view, non da contatori salvati.
  -- Nessuna riga nella view (iscrizione non piu' attiva) = corso finito.
  SELECT coalesce(bool_and(restano <= 0 AND in_agenda = 0), true)
    INTO v_finito
    FROM contatori_corso
    WHERE user_id = p_user_id AND tipo_corso = v_corso;

  IF NOT v_finito THEN
    RETURN;
  END IF;

  UPDATE profile_data SET corso_attivo = NULL WHERE user_id = p_user_id;

  -- v3.89: mapping corretto anche per i corsi corda (intro_corda→intro, evo_corda→evo)
  v_funnel_key := replace(v_corso, '_corda', '');
  IF v_persona_id IS NOT NULL
     AND v_funnel_key IN ('open','advance','intro','evo') THEN
    UPDATE lead_data
      SET funnel_stage = 'concluso_' || v_funnel_key
      WHERE persona_id = v_persona_id
      RETURNING id INTO v_lead_id;

    -- DEBITO-177 segnale minimo: nota visibile nel fascicolo. Mai bloccante.
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


-- ---------------------------------------------------------------------------
-- 2 · I DUE TRIGGER CHE SE NE VANNO
-- ---------------------------------------------------------------------------

-- tg_update_lezioni_residue — era attaccato a presenze_corso (non a
-- prenotazioni_corso) e scriveva iscrizioni_corso.lezioni_residue, una colonna
-- che NON ESISTE su quella tabella: se fosse mai scattato avrebbe dato errore.
-- Non e' mai scattato perche' presenze_corso e' vuota. Codice morto e rotto.
-- La tabella presenze_corso si elimina in Fase D (file 05), dopo il grep.
DROP TRIGGER IF EXISTS tg_presenze_lezioni_residue ON public.presenze_corso;
DROP FUNCTION IF EXISTS public.tg_update_lezioni_residue();

-- trg_riaccredita_su_delete_prenotazione — restituiva il credito quando una
-- riga di prenotazioni_corso veniva cancellata, e provava a "disfare" il
-- no-show. Con i contatori derivati non serve piu' niente: se la riga sparisce,
-- sparisce dal COUNT. Era anche l'unico punto che scriveva no_show_count
-- all'indietro, con una logica di rimborso della penale difficile da seguire.
DROP TRIGGER IF EXISTS trg_riaccredita_delete ON public.prenotazioni_corso;
DROP FUNCTION IF EXISTS public.trg_riaccredita_su_delete_prenotazione();


-- ---------------------------------------------------------------------------
-- 3 · IL TRIGGER CHE RESTA
-- ---------------------------------------------------------------------------
-- _trg_open_presenza_garantisce_corso
--   PRIMA: faceva due cose. (a) se il profilo non aveva corso_attivo, auto-iscriveva
--          al pacchetto Open intero; (b) su INSERT diretto scalava lezioni_residue - 1,
--          perche' l'inserimento bulk dal portale non passava dalla RPC.
--   DOPO:  resta solo (a). Il punto (b) non ha piu' ragione di esistere: la
--          presenza e' la riga stessa, e il COUNT la vede appena inserita,
--          che arrivi da RPC o da INSERT bulk.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._trg_open_presenza_garantisce_corso()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_corso_attuale text;
BEGIN
  IF NEW.tipo_corso <> 'open' THEN RETURN NEW; END IF;
  IF NEW.stato <> 'presente' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE' AND OLD.stato = 'presente' THEN RETURN NEW; END IF;

  -- Auto-iscrizione se il profilo non ha un corso attivo: la falla Open
  -- si chiude alla radice, come da Schema v1.8.
  SELECT corso_attivo INTO v_corso_attuale
    FROM profile_data WHERE user_id = NEW.user_id;

  IF v_corso_attuale IS NULL THEN
    PERFORM public.accredita_pacchetto_open_intero(NEW.user_id);
    RAISE NOTICE '[trg_open_presenza] Auto-iscritto user_id=% al Corso Open', NEW.user_id;
  ELSIF v_corso_attuale <> 'open' THEN
    RAISE WARNING '[trg_open_presenza] user_id=% ha corso_attivo=%, presenza Open segnata. Da verificare.',
      NEW.user_id, v_corso_attuale;
  END IF;

  -- DEBITO-190: qui prima c'era "UPDATE profile_data SET lezioni_residue = ... - 1"
  -- su INSERT. Tolto: la presenza e' la riga, il COUNT la vede da solo.

  RETURN NEW;
END;
$function$;


-- ---------------------------------------------------------------------------
-- 4 · FUNZIONI DI SERVIZIO
-- ---------------------------------------------------------------------------
-- disdici_corso_admin
--   PRIMA: metteva lo stato a 'cancellato_in_tempo' e poi faceva
--          "lezioni_residue + 1" — sempre sulla colonna Open, QUALUNQUE fosse
--          il tipo di corso. Su una prenotazione Advance riaccreditava una
--          lezione Open: difetto reale, sparisce da solo qui.
--   DOPO:  scrive solo lo stato. 'cancellato_in_tempo' non consuma, quindi il
--          credito torna da se' nel COUNT.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.disdici_corso_admin(p_prenotazione_id uuid, p_motivo text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_prenot record;
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  SELECT id, user_id, slot_id, tipo_corso, data_lezione, stato
    INTO v_prenot
    FROM prenotazioni_corso
    WHERE id = p_prenotazione_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Prenotazione non trovata';
  END IF;

  IF v_prenot.stato IN ('cancellato_in_tempo','cancellato_tardi') THEN
    RAISE EXCEPTION 'Prenotazione già cancellata (stato=%)', v_prenot.stato;
  END IF;

  -- staff = sempre "in tempo": lo stato scelto non consuma la lezione,
  -- quindi il credito rientra nel COUNT senza aritmetica.
  UPDATE prenotazioni_corso
    SET stato = 'cancellato_in_tempo',
        cancelled_at = now(),
        cancellation_reason = p_motivo
    WHERE id = p_prenotazione_id;

  RETURN jsonb_build_object(
    'ok', true,
    'prenotazione_id', p_prenotazione_id,
    'user_id', v_prenot.user_id,
    'stato_precedente', v_prenot.stato,
    'riaccreditato', (v_prenot.stato IN ('prenotato','presente'))
  );
END;
$function$;


-- ---------------------------------------------------------------------------
-- 5 · FUNZIONE MORTA E ROTTA — decisione di Marco richiesta
-- ---------------------------------------------------------------------------
-- marca_presenza_open(p_prenotazione_id uuid, p_presente boolean)
--   Legge e scrive la tabella "prenotazioni_open", che NON ESISTE nel database:
--   le sole tabelle prenotazioni_* sono prenotazioni_corso,
--   prenotazioni_prima_lezione (+ un backup) e la view prenotazioni_unificate.
--   Qualunque chiamata fallirebbe con "relation does not exist".
--   Nessuna pagina del repo la chiama.
--
--   Marco ha verificato il 22 set: 0 chiamate nel Worker (v3.78), 0 nelle pagine.
--   Si elimina.
DROP FUNCTION IF EXISTS public.marca_presenza_open(uuid, boolean);


-- ============================================================================
-- PARTE 2 · I VERBI — prenotare, disdire, marcare
-- Aggiunta il 2026-09-22, dopo la decisione di Marco sul no-show.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- applica_no_show
--   PRIMA: teneva un contatore a soglia su profile_data.no_show_count.
--          Incrementava a ogni assenza; al raggiungimento della soglia azzerava
--          il contatore E toglieva una lezione con EXECUTE format sulla colonna
--          del corso, piu' un "mirror" su lezioni_residue se il corso non era Open.
--   DOPO:  non scrive piu' niente. La penale e' derivata: la view fa
--          ghostate / soglia, quindi la lezione si scala da se' quando il COUNT
--          delle assenze arriva a un multiplo della soglia.
--          Resta il solo compito di dire che e' successo: l'avviso
--          "ha accumulato N no-show: 1 lezione scalata" si emette quando il
--          COUNT passa per un multiplo esatto della soglia.
--   FIRMA: il secondo parametro e' nuovo ma ha un default, quindi ogni
--          chiamata a un argomento sola continua a funzionare. Senza
--          tipo_corso si usa profile_data.corso_attivo, come faceva prima.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.applica_no_show(p_user_id uuid, p_tipo_corso text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_corso    text := p_tipo_corso;
  v_ghostate int;
  v_soglia   int;
BEGIN
  IF v_corso IS NULL THEN
    SELECT corso_attivo INTO v_corso FROM profile_data WHERE user_id = p_user_id;
  END IF;
  IF v_corso IS NULL THEN
    RETURN;   -- nessun corso a cui imputare l'assenza: niente da dire
  END IF;

  SELECT GREATEST(coalesce(noshow_soglia_penalita, 2), 1)
    INTO v_soglia FROM tipi_corso_config WHERE tipo_corso = v_corso;
  IF v_soglia IS NULL THEN v_soglia := 2; END IF;

  SELECT count(*) INTO v_ghostate
    FROM prenotazioni_corso
    WHERE user_id = p_user_id AND tipo_corso = v_corso AND stato = 'assente';

  -- La lezione la scala la view. Qui si parla soltanto, e solo quando il
  -- conteggio tocca un multiplo esatto della soglia.
  IF v_ghostate > 0 AND v_ghostate % v_soglia = 0 THEN
    RAISE NOTICE '[no_show] user_id=% corso=%: ha accumulato % no-show, 1 lezione scalata (totale scalate: %)',
      p_user_id, v_corso, v_ghostate, v_ghostate / v_soglia;
  END IF;
END;
$function$;

COMMENT ON FUNCTION public.applica_no_show(uuid, text) IS
  'DEBITO-190: non scrive piu'' contatori. La penale e'' derivata dalla view '
  '(ghostate / noshow_soglia_penalita); qui resta solo l''avviso, emesso quando '
  'il COUNT delle assenze tocca un multiplo della soglia.';

-- ---------------------------------------------------------------------------
-- prenota_corso  ·  RPC PUBBLICA, nome e firma invariati
--   PRIMA: leggeva _get_lezioni_residue (contatore salvato) per la guardia
--          "hai ancora lezioni?", e in fondo faceva
--          "UPDATE profile_data SET <colonna del corso> = ... - 1".
--   DOPO:  la guardia legge prenotabili da contatori_corso e non scrive nulla:
--          la riga inserita in prenotazioni_corso E' il consumo.
--   Tutte le altre guardie — permessi, freeze, scadenza pacchetto, finestra di
--   validita', slot attivo e compatibile, giorno della settimana, calendario
--   Accademia, finestra oraria, capienza, doppia prenotazione — sono INVARIATE.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prenota_corso(p_user_id uuid, p_slot_id uuid, p_data_lezione date)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_slot        record;
  v_config      record;
  v_profile     record;
  v_now         timestamptz := now();
  v_dt_inizio   timestamptz;
  v_capienza    int;
  v_prenot_id   uuid;
  v_dow_iso     int;
  v_prenotabili int;
  v_iscrizione  record;
BEGIN
  IF p_user_id <> auth.uid() AND NOT is_staff() THEN
    RAISE EXCEPTION 'Permesso negato: puoi prenotare solo per te stesso';
  END IF;

  SELECT corso_attivo, freeze_inizio, freeze_fine, scadenza_consumo_open
    INTO v_profile
    FROM profile_data
    WHERE user_id = p_user_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profilo non trovato per user_id %', p_user_id;
  END IF;
  IF v_profile.corso_attivo IS NULL THEN
    RAISE EXCEPTION 'Nessun corso attivo: contatta la segreteria';
  END IF;

  -- DEBITO-190: la guardia legge la view. NULL = nessuna iscrizione attiva a
  -- quel corso, quindi anche i crediti orfani smettono di essere spendibili.
  SELECT prenotabili INTO v_prenotabili
    FROM contatori_corso
    WHERE user_id = p_user_id AND tipo_corso = v_profile.corso_attivo;

  IF v_prenotabili IS NULL THEN
    RAISE EXCEPTION 'Nessuna iscrizione attiva al corso %: contatta la segreteria', v_profile.corso_attivo;
  END IF;
  IF v_prenotabili <= 0 THEN
    RAISE EXCEPTION 'Nessuna lezione residua per il corso %: contatta la segreteria', v_profile.corso_attivo;
  END IF;

  IF v_profile.corso_attivo = 'open' THEN
    IF v_profile.scadenza_consumo_open IS NOT NULL
       AND v_profile.scadenza_consumo_open < v_now THEN
      RAISE EXCEPTION 'Pacchetto Open scaduto: contatta la segreteria';
    END IF;
  ELSE
    SELECT data_inizio_validita, data_fine_validita, status
      INTO v_iscrizione
      FROM iscrizioni_corso
      WHERE user_id = p_user_id
        AND tipo_corso = v_profile.corso_attivo
        AND status = 'attiva'
      ORDER BY data_iscrizione DESC
      LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Nessuna iscrizione attiva al corso %: contatta la segreteria', v_profile.corso_attivo;
    END IF;
    IF v_iscrizione.data_fine_validita IS NOT NULL
       AND p_data_lezione > v_iscrizione.data_fine_validita THEN
      RAISE EXCEPTION 'La data lezione % e'' oltre la fine validita'' del pacchetto (%)',
        p_data_lezione, v_iscrizione.data_fine_validita;
    END IF;
    IF v_iscrizione.data_inizio_validita IS NOT NULL
       AND p_data_lezione < v_iscrizione.data_inizio_validita THEN
      RAISE EXCEPTION 'La data lezione % e'' prima dell''inizio validita'' del pacchetto (%)',
        p_data_lezione, v_iscrizione.data_inizio_validita;
    END IF;
  END IF;

  IF v_profile.freeze_inizio IS NOT NULL
     AND v_profile.freeze_fine IS NOT NULL
     AND v_now BETWEEN v_profile.freeze_inizio AND v_profile.freeze_fine THEN
    RAISE EXCEPTION 'In pausa fino al %: riprendi dal portale dopo questa data',
      to_char(v_profile.freeze_fine, 'DD/MM/YYYY');
  END IF;

  SELECT id, giorno_settimana, ora_inizio, ora_fine, tipo_corso, status
    INTO v_slot FROM corsi_attivi_settimanali WHERE id = p_slot_id;

  IF NOT FOUND THEN RAISE EXCEPTION 'Slot non trovato'; END IF;
  IF v_slot.status <> 'attivo' THEN RAISE EXCEPTION 'Slot non attivo'; END IF;
  IF v_slot.tipo_corso <> v_profile.corso_attivo THEN
    RAISE EXCEPTION 'Slot di tipo % non compatibile con il tuo corso attivo (%)',
      v_slot.tipo_corso, v_profile.corso_attivo;
  END IF;

  v_dow_iso := ((EXTRACT(DOW FROM p_data_lezione)::int + 6) % 7) + 1;
  IF v_dow_iso <> v_slot.giorno_settimana THEN
    RAISE EXCEPTION 'La data % (giorno %) non corrisponde al giorno dello slot (%)',
      p_data_lezione, v_dow_iso, v_slot.giorno_settimana;
  END IF;

  SELECT capienza_max, finestra_prenotazione_ore, apertura_prenotazione_giorni
    INTO v_config
    FROM tipi_corso_config
    WHERE tipo_corso = v_slot.tipo_corso AND attivo = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Tipo corso % non configurato o non attivo', v_slot.tipo_corso;
  END IF;

  v_dt_inizio := (p_data_lezione + v_slot.ora_inizio)::timestamptz;

  IF p_data_lezione > (SELECT max(d) FROM calendario_accademia_prossime()) THEN
    RAISE EXCEPTION 'Troppo presto: la data % non rientra ancora nella finestra di prenotazione (calendario Accademia)',
      to_char(p_data_lezione, 'DD/MM/YYYY');
  END IF;

  IF v_dt_inizio - v_now < make_interval(hours => v_config.finestra_prenotazione_ore) THEN
    RAISE EXCEPTION 'Troppo tardi: la prenotazione chiude % h prima della lezione',
      v_config.finestra_prenotazione_ore;
  END IF;

  SELECT COUNT(*) INTO v_capienza
    FROM prenotazioni_corso
    WHERE slot_id = p_slot_id AND data_lezione = p_data_lezione AND stato = 'prenotato';

  IF v_capienza >= v_config.capienza_max THEN
    RAISE EXCEPTION 'Slot pieno (%/%): scegline un altro', v_capienza, v_config.capienza_max;
  END IF;

  IF EXISTS (
    SELECT 1 FROM prenotazioni_corso
    WHERE user_id = p_user_id AND slot_id = p_slot_id
      AND data_lezione = p_data_lezione AND stato = 'prenotato'
  ) THEN
    RAISE EXCEPTION 'Hai gia'' una prenotazione attiva per questo slot';
  END IF;

  INSERT INTO prenotazioni_corso (user_id, slot_id, tipo_corso, data_lezione, stato, created_by)
    VALUES (p_user_id, p_slot_id, v_slot.tipo_corso, p_data_lezione, 'prenotato', auth.uid())
    RETURNING id INTO v_prenot_id;

  -- DEBITO-190: qui prima c'era l'UPDATE che scalava la colonna del corso.
  -- La riga appena inserita E' il consumo: il COUNT la vede.

  RETURN v_prenot_id;
END;
$function$;

-- ---------------------------------------------------------------------------
-- disdici_corso  ·  RPC PUBBLICA, nome e firma invariati
--   PRIMA: oltre a cambiare stato, scriveva con EXECUTE format sia la colonna
--          delle lezioni (+1) sia quella degli spostamenti (-1), e per la
--          disdetta fuori tempo chiamava applica_no_show, che scalava ancora.
--   DOPO:  scrive SOLO lo stato della riga. 'cancellato_in_tempo' non consuma,
--          quindi il credito rientra da se'; 'cancellato_tardi' consuma, e il
--          COUNT lo vede. Il budget spostamenti e' un COUNT, non un decremento.
--   La guardia sulle disdette esaurite ora legge spostamenti_residui dalla view.
--   Snapshot DEBITO-178 prima/dopo: invariati, ma fotografano la view.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.disdici_corso(p_prenotazione_id uuid, p_motivo text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_prenot        record;
  v_slot          record;
  v_config        record;
  v_now           timestamptz := now();
  v_dt_inizio     timestamptz;
  v_in_tempo      boolean;
  v_caller        uuid := auth.uid();
  v_is_staff      boolean := is_staff();
  v_is_allievo    boolean;
  v_spost_res     int;
  v_prima         jsonb;
  v_dopo          jsonb;
  v_stato_finale  text;
  v_c             record;
BEGIN
  SELECT id, user_id, slot_id, tipo_corso, data_lezione, stato
    INTO v_prenot FROM prenotazioni_corso WHERE id = p_prenotazione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prenotazione non trovata'; END IF;
  IF v_prenot.user_id <> v_caller AND NOT v_is_staff THEN RAISE EXCEPTION 'Permesso negato'; END IF;
  v_is_allievo := (v_prenot.user_id = v_caller AND NOT v_is_staff);
  IF v_prenot.stato <> 'prenotato' THEN
    RAISE EXCEPTION 'Prenotazione già in stato "%", non disdicibile', v_prenot.stato;
  END IF;

  SELECT ora_inizio INTO v_slot FROM corsi_attivi_settimanali WHERE id = v_prenot.slot_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Slot non trovato (orfano?)'; END IF;
  SELECT finestra_disdetta_ore INTO v_config FROM tipi_corso_config WHERE tipo_corso = v_prenot.tipo_corso;
  IF NOT FOUND THEN RAISE EXCEPTION 'Config tipo_corso % mancante', v_prenot.tipo_corso; END IF;

  v_dt_inizio := (v_prenot.data_lezione + v_slot.ora_inizio)::timestamptz;
  v_in_tempo  := (v_dt_inizio - v_now) >= make_interval(hours => v_config.finestra_disdetta_ore);

  v_prima := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso);

  IF v_in_tempo THEN
    IF v_is_allievo THEN
      -- DEBITO-190: il budget arriva dalla view (max - COUNT cancellato_in_tempo)
      SELECT spostamenti_residui INTO v_spost_res
        FROM contatori_corso
        WHERE user_id = v_prenot.user_id AND tipo_corso = v_prenot.tipo_corso;
      IF v_spost_res IS NULL OR v_spost_res <= 0 THEN
        RAISE EXCEPTION 'Hai esaurito le disdette consentite per questo pacchetto. Per un imprevisto reale, contatta la segreteria.'
          USING ERRCODE = '23514';
      END IF;
    END IF;

    UPDATE prenotazioni_corso
      SET stato='cancellato_in_tempo', cancelled_at=v_now, cancellation_reason=p_motivo
      WHERE id=p_prenotazione_id;
    v_stato_finale := 'cancellato_in_tempo';
  ELSE
    UPDATE prenotazioni_corso
      SET stato='cancellato_tardi', cancelled_at=v_now, cancellation_reason=p_motivo
      WHERE id=p_prenotazione_id;
    v_stato_finale := 'cancellato_tardi';
  END IF;

  -- DEBITO-190: nessun UPDATE su profile_data. 'cancellato_in_tempo' non
  -- consuma e non decrementa nulla; 'cancellato_tardi' consuma, e lo dice
  -- il COUNT. applica_no_show non viene piu' chiamata qui: la disdetta fuori
  -- tempo non e' una ghostata, e' uno stato suo che consuma 1 a 1.

  PERFORM _chiudi_corso_se_finito(v_prenot.user_id);

  v_dopo := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso);
  UPDATE prenotazioni_corso
    SET effetto_contabile = jsonb_build_object(
          'azione', v_stato_finale, 'origine', 'disdici_corso',
          'in_tempo', v_in_tempo, 'prima', v_prima, 'dopo', v_dopo,
          'marcata_da', v_caller, 'marcata_at', v_now)
    WHERE id = p_prenotazione_id;

  SELECT * INTO v_c FROM contatori_corso
    WHERE user_id = v_prenot.user_id AND tipo_corso = v_prenot.tipo_corso;

  RETURN jsonb_build_object(
    'prenotazione_id',          p_prenotazione_id,
    'tipo_corso',               v_prenot.tipo_corso,
    'in_tempo',                 v_in_tempo,
    'stato_finale',             v_stato_finale,
    'spostamenti_residui_dopo', v_c.spostamenti_residui,
    'no_show_count_dopo',       v_c.ghostate,
    'lezioni_residue_dopo',     v_c.prenotabili
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- rimarca_presenza_corso  ·  RPC PUBBLICA, nome e firma invariati
--   PRIMA: calcolava un delta credito (+1 entrando in cancellato_in_tempo, -1
--          uscendone), provava a "disfare" il no-show leggendo no_show_count e
--          restituendo la penale, e scriveva colonna del corso + mirror Open.
--   DOPO:  cambia lo stato e basta. Ogni correzione, in qualunque direzione,
--          si riflette da sola nei COUNT: non c'e' piu' niente da disfare, e
--          sparisce tutta la logica "best-effort" di restituzione penale, che
--          era il punto piu' difficile da seguire di tutto il contabile.
--   Il jsonb di ritorno tiene le chiavi di prima; delta_credito e
--   penalita_restituita restano per compatibilita', calcolate dalla differenza
--   fra gli snapshot invece che decise a mano.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rimarca_presenza_corso(p_prenotazione_id uuid, p_nuovo_stato text, p_motivo text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_prenot  record;
  v_caller  uuid := auth.uid();
  v_role    text;
  v_vecchio text;
  v_prima   jsonb;
  v_dopo    jsonb;
  v_delta   int;
BEGIN
  SELECT staff_role INTO v_role FROM profile_data WHERE user_id = v_caller;
  IF v_role IS NULL OR v_role NOT IN ('staff_creator','staff_segreteria',
      'staff_istruttore_tutor','staff_istruttore_sr','staff_istruttore_jr') THEN
    RAISE EXCEPTION 'Permesso negato: solo istruttori e segreteria possono correggere presenze';
  END IF;

  IF p_nuovo_stato IS NULL OR p_nuovo_stato NOT IN
     ('prenotato','presente','assente','cancellato_in_tempo','cancellato_tardi') THEN
    RAISE EXCEPTION 'Stato non valido: %. Ammessi: prenotato, presente, assente, cancellato_in_tempo, cancellato_tardi', p_nuovo_stato;
  END IF;

  SELECT id, user_id, slot_id, tipo_corso, stato
    INTO v_prenot FROM prenotazioni_corso WHERE id = p_prenotazione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Prenotazione non trovata'; END IF;

  v_vecchio := v_prenot.stato;
  IF v_vecchio = p_nuovo_stato THEN
    RETURN jsonb_build_object('ok', true, 'noop', true, 'stato', v_vecchio,
      'message', 'La prenotazione è già in questo stato.');
  END IF;

  v_prima := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso);

  -- DEBITO-190: solo lo stato. Niente delta, niente mirror, niente undo penale.
  UPDATE prenotazioni_corso
    SET stato        = p_nuovo_stato,
        marcata_da   = v_caller,
        marcata_at   = now(),
        auto_marcata = false,
        updated_at   = now()
    WHERE id = p_prenotazione_id;

  -- L'avviso del no-show resta: lo emette applica_no_show leggendo il COUNT.
  IF p_nuovo_stato = 'assente' AND v_vecchio <> 'assente' THEN
    PERFORM applica_no_show(v_prenot.user_id, v_prenot.tipo_corso);
  END IF;

  PERFORM _chiudi_corso_se_finito(v_prenot.user_id);

  v_dopo  := _snapshot_contabile(v_prenot.user_id, v_prenot.tipo_corso);
  -- delta osservato, non deciso: differenza fra le due fotografie
  v_delta := coalesce((v_dopo->>'prenotabili')::int, 0) - coalesce((v_prima->>'prenotabili')::int, 0);

  UPDATE prenotazioni_corso
    SET effetto_contabile = jsonb_build_object(
          'azione','rimarca', 'origine','rimarca_presenza_corso',
          'da_stato', v_vecchio, 'a_stato', p_nuovo_stato, 'motivo', p_motivo,
          'delta_credito', v_delta, 'penalita_restituita', false,
          'prima', v_prima, 'dopo', v_dopo,
          'marcata_da', v_caller, 'marcata_at', now())
    WHERE id = p_prenotazione_id;

  RETURN jsonb_build_object(
    'ok', true, 'da_stato', v_vecchio, 'a_stato', p_nuovo_stato,
    'delta_credito', v_delta, 'penalita_restituita', false,
    'prima', v_prima, 'dopo', v_dopo,
    'message', format('Prenotazione corretta: %s → %s.', v_vecchio, p_nuovo_stato));
END;
$function$;

-- ---------------------------------------------------------------------------
-- prenota_open — TERZA FUNZIONE MORTA E ROTTA, decisione di Marco richiesta
--   Legge e scrive "prenotazioni_open", tabella che NON ESISTE, e legge
--   corsi_attivi_settimanali.capacita, colonna che non esiste (si chiama
--   capienza_max). Doppiamente rotta: qualunque chiamata fallirebbe.
--   Stessa situazione di marca_presenza_open, ma Marco ha verificato il Worker
--   solo per quella. Non la elimino da solo.
-- DROP FUNCTION IF EXISTS public.prenota_open(uuid, uuid, date);
