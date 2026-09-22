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
--   Marco ha verificato il 22 set: 0 chiamate nel Worker (v3.78), 0 in
--   portale/agenda/oggi/profilo/commerciale. Si elimina.
DROP FUNCTION IF EXISTS public.prenota_open(uuid, uuid, date);


-- ============================================================================
-- PARTE 3 · GLI ACCREDITI — la lista dei danni
-- Aggiunta il 2026-09-22.
-- ============================================================================
--
-- COSA FANNO OGGI, TUTTI, NELLO STESSO ORDINE
--   1. validano i parametri e trovano persona_id
--   2. creano o aggiornano la riga in iscrizioni_corso (importi, validità,
--      lezioni_totali, status, stato_pagamento, note)
--   3. UPDATE profile_data: corso_attivo, i flag *_paid, la frequenza, la
--      scadenza di consumo... E I CONTATORI
--   4. lead_data.funnel_stage, pagamenti_manuali, nota in crm_follow_ups
--
-- COSA CAMBIA: sparisce SOLO la parte di contatori del punto 3. Tutto il
-- resto — iscrizione, importi, flag, funnel, pagamento, nota — resta identico.
--
-- ============================================================================
-- LA LISTA DEI DANNI — accrediti che scrivevano sulla colonna di un altro corso
-- ============================================================================
-- Verificata leggendo i corpi, non solo cercando i nomi delle colonne.
--
--   SETTE accrediti di corsi NON-Open scrivono anche lezioni_residue, che e'
--   la colonna del Corso Open:
--     accredita_advance_mese1     advance_lezioni_residue=4, lezioni_residue=4
--     accredita_advance_mese2     advance_lezioni_residue+4, lezioni_residue+4
--     accredita_advance_2xsett    advance_lezioni_residue,   lezioni_residue
--     accredita_intro_mese1       intro_lezioni_residue,     lezioni_residue
--     accredita_intro_mese2       intro_lezioni_residue+4,   lezioni_residue+4
--     accredita_evo_mese1         evo_lezioni_residue,       lezioni_residue
--     accredita_evo_mese2         evo_lezioni_residue+4,     lezioni_residue+4
--
--   Non e' il solo accredita_intro_mese2 che la consegna citava: e' sistematico
--   su tutta la famiglia mese1/mese2/2xsett. Chi ha comprato Intro o Advance si
--   e' visto accreditare le stesse lezioni DUE volte, una sulla colonna giusta
--   e una su quella del Corso Open.
--
--   IPOTESI, da confermare in Fase D: e' la spiegazione piu' probabile dei
--   "crediti orfani" Open trovati dalla sezione 2 della 02 — Borini 6, D'Uva 4,
--   Guidi 4, Meli 4, Rasoira 4, Puppini 2. Da verificare caso per caso contro
--   pagamenti_manuali prima di azzerarli: non la do per buona qui.
--
--   I TRE "intero" sono INNOCENTI: accredita_advance_intero,
--   accredita_intro_intero e accredita_evo_intero non scrivono nessun
--   contatore, chiamano mese1 + mese2 e compongono il risultato. La stringa
--   'lezioni_residue' compare solo come chiave del jsonb di ritorno.
--   (Una ricerca per nome di colonna li segnalava come colpevoli: falso
--   positivo, corretto dopo aver letto i corpi.)
--
--   I SETTE accrediti Open scrivono lezioni_residue legittimamente, ma
--   duplicano il valore su lezioni_iniziali_residue e resettano a mano
--   no_show_count e spostamenti_open_residui — tre colonne che spariscono
--   tutte in Fase D.
--
-- ⚠ LE FUNZIONI RISCRITTE ARRIVANO NEL PROSSIMO BLOCCO DI QUESTO FILE.
--   Fin qui c'e' il rilievo, non ancora il codice.


-- ─── accredita_advance_mese1 ────────────────────────────────────────────────
-- DANNO: scriveva advance_lezioni_residue=4 E lezioni_residue=4 — la seconda
--        e' la colonna del Corso Open. Quattro lezioni Advance finivano anche
--        nel credito Open. Azzerava pure advance_no_show_count.
-- DOPO:  l'iscrizione, gli importi, la validita', il flag advance_paid, il
--        funnel, il pagamento e la nota restano identici. Via i tre contatori.
CREATE OR REPLACE FUNCTION public.accredita_advance_mese1(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisionare prima l''allievo via kc-inserisci-contatto.', p_user_id;
  END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id=p_user_id AND tipo_corso='advance' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Advance attiva già presente per user_id=%. Usa accredita_advance_mese2 per il pagamento del secondo mese.', p_user_id;
  END IF;
  v_data_fine := p_data_inizio + INTERVAL '40 days';
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, stato_pagamento,
    importo_concordato, importo_pagato, note
  ) VALUES (
    p_user_id, 'advance', p_data_inizio, p_data_inizio, v_data_fine,
    8, 0, 'attiva', 'acconto', 280, 140,
    '1° mese pagato (140€). Manca 2° mese (140€) per saldare 280€ totali. Lezioni accreditate al mese 1: 4 su 8.'
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: qui c'erano advance_lezioni_residue=4, lezioni_residue=4 e
  -- advance_no_show_count=0. Le 4 lezioni del mese 1 sono gia' scritte
  -- nell'iscrizione (lezioni_totali=8 con importo_pagato < concordato: la view
  -- fa lezioni_totali/2). Il no-show e' un COUNT, non si azzera.
  UPDATE profile_data
    SET corso_attivo='advance', advance_paid=true, updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_advance', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_advance', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'advance_mese1', p_metodo, auth.uid(),
          COALESCE(p_note, 'Advance mese 1 (1x/sett std) — 140€ (corso 50 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Advance mese 1 il %s, metodo %s. Lezioni residue 4 su 8. Importo residuo 140€.', p_data_inizio::text, p_metodo),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione_id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','advance','funnel_stage','iscritto_advance','mese_accreditato',1,
    'lezioni_residue',4,'lezioni_totali',8,'importo_pagato',140,'importo_residuo',140,
    'data_inizio_validita',p_data_inizio,'data_fine_validita',v_data_fine,
    'message','Advance mese 1 accreditato: 4 lezioni residue, importo da saldare 140€.');
END; $function$;

-- ─── accredita_advance_mese2 ────────────────────────────────────────────────
-- DANNO: advance_lezioni_residue + 4 E lezioni_residue + 4 — altre quattro
--        lezioni Advance sul credito Open.
-- DOPO:  saldare il mese 2 significa solo importo_pagato = importo_concordato
--        sull'iscrizione: da li' la view smette di dimezzare e le lezioni
--        passano da 4 a 8 da sole. Il numero nella nota CRM e nel jsonb ora
--        viene letto dalla view invece che dalla RETURNING sul contatore.
CREATE OR REPLACE FUNCTION public.accredita_advance_mese2(p_user_id uuid, p_data_pagamento date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione iscrizioni_corso%ROWTYPE; v_lead_id uuid; v_pagamento_id uuid;
  v_nuove_residue integer; v_nuova_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_pagamento IS NULL THEN p_data_pagamento := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  SELECT * INTO v_iscrizione FROM iscrizioni_corso
  WHERE user_id=p_user_id AND tipo_corso='advance' AND status='attiva'
  ORDER BY data_iscrizione DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Nessuna iscrizione Advance attiva per user_id=%. Prima eseguire accredita_advance_mese1.', p_user_id; END IF;
  IF v_iscrizione.importo_pagato >= v_iscrizione.importo_concordato THEN
    RAISE EXCEPTION 'Iscrizione Advance già saldata per user_id=% (importo_pagato=%, importo_concordato=%).', p_user_id, v_iscrizione.importo_pagato, v_iscrizione.importo_concordato;
  END IF;
  IF v_iscrizione.importo_pagato != 140 THEN
    RAISE EXCEPTION 'Stato pagamenti anomalo iscrizione Advance user_id=%: atteso importo_pagato=140, trovato %.', p_user_id, v_iscrizione.importo_pagato;
  END IF;
  v_nuova_fine := GREATEST((v_iscrizione.data_inizio_validita + INTERVAL '75 days')::date, (p_data_pagamento + INTERVAL '30 days')::date);
  UPDATE iscrizioni_corso
    SET importo_pagato = importo_concordato, stato_pagamento = 'saldato',
        pagamento_completato_at = now(), data_fine_validita = v_nuova_fine,
        note = COALESCE(note || E'\n','') || format('Saldato il %s con accredita_advance_mese2. 8 lezioni accreditate totali.', p_data_pagamento::text),
        updated_at = now()
    WHERE id = v_iscrizione.id;

  -- DEBITO-190: qui c'erano advance_lezioni_residue + 4 e lezioni_residue + 4.
  -- Il saldo appena scritto sull'iscrizione basta: la view non dimezza piu'.
  UPDATE profile_data
    SET advance_mese2_paid = true, updated_at = now()
    WHERE user_id = p_user_id;

  SELECT prenotabili INTO v_nuove_residue
    FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'advance';

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_advance', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_advance', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'advance_mese2', p_metodo, auth.uid(),
          COALESCE(p_note, 'Advance mese 2 (saldo) — 140€ (corso 50 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: saldato Advance mese 2 il %s, metodo %s. Iscrizione completata 8/8 lezioni, residue=%s.', p_data_pagamento::text, p_metodo, v_nuove_residue),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione.id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','advance','funnel_stage','iscritto_advance','mese_accreditato',2,
    'lezioni_residue',v_nuove_residue,'lezioni_totali',v_iscrizione.lezioni_totali,
    'importo_pagato',v_iscrizione.importo_concordato,'importo_residuo',0,
    'data_fine_validita',v_nuova_fine,'saldato',true,
    'message',format('Advance mese 2 accreditato: +4 lezioni (totale residue=%s), iscrizione saldata.', v_nuove_residue));
END; $function$;

-- ─── accredita_advance_2xsett ───────────────────────────────────────────────
-- DANNO: advance_lezioni_residue=8 E lezioni_residue=8 — otto lezioni Advance
--        anche sul credito Open. Azzerava advance_no_show_count.
-- DOPO:  l'iscrizione nasce gia' saldata con lezioni_totali=8, quindi la view
--        dice 8 senza che nessuno le scriva.
CREATE OR REPLACE FUNCTION public.accredita_advance_2xsett(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id=p_user_id AND tipo_corso='advance' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Advance attiva già presente per user_id=%. Concludere o annullare l''esistente prima.', p_user_id;
  END IF;
  v_data_fine := p_data_inizio + INTERVAL '45 days';
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, stato_pagamento,
    importo_concordato, importo_pagato, pagamento_completato_at, note
  ) VALUES (
    p_user_id, 'advance', p_data_inizio, p_data_inizio, v_data_fine,
    8, 0, 'attiva', 'saldato', 190, 190, now(),
    'Advance modalità ECCEZIONE 2x/sett: 8 lezioni in ~1 mese, pagamento unico 190€ (corso 100 + sala 90).'
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: via advance_lezioni_residue=8, lezioni_residue=8 e
  -- advance_no_show_count=0.
  UPDATE profile_data
    SET corso_attivo='advance', advance_paid=true, updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_advance', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_advance', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'advance_2xsett', p_metodo, auth.uid(),
          COALESCE(p_note, 'Advance 2x/sett intensivo — 190€ saldato (corso 100 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Advance 2x/sett intensivo il %s, metodo %s. 8 lezioni residue, saldato 190€.', p_data_inizio::text, p_metodo),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione_id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','advance','funnel_stage','iscritto_advance','modalita','2xsett_intensivo',
    'lezioni_residue',8,'lezioni_totali',8,'importo_pagato',190,'importo_residuo',0,'saldato',true,
    'data_inizio_validita',p_data_inizio,'data_fine_validita',v_data_fine,
    'message','Advance 2x/sett intensivo accreditato: 8 lezioni residue, saldato 190€.');
END; $function$;

-- ─── accredita_evo_mese1 ────────────────────────────────────────────────────
-- DANNO: evo_lezioni_residue=4 E lezioni_residue=4 — quattro lezioni Evo
--        anche sul credito Open. Azzerava evo_no_show_count.
CREATE OR REPLACE FUNCTION public.accredita_evo_mese1(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id=p_user_id AND tipo_corso='evo_corda' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Evo Corda attiva già presente per user_id=%. Usa accredita_evo_mese2 per il pagamento del secondo mese.', p_user_id;
  END IF;
  v_data_fine := p_data_inizio + INTERVAL '40 days';
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, stato_pagamento,
    importo_concordato, importo_pagato, note
  ) VALUES (
    p_user_id, 'evo_corda', p_data_inizio, p_data_inizio, v_data_fine,
    8, 0, 'attiva', 'acconto', 320, 160,
    '1° mese pagato (160€). Manca 2° mese (160€) per saldare 320€ totali. Lezioni accreditate al mese 1: 4 su 8.'
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: via evo_lezioni_residue=4, lezioni_residue=4, evo_no_show_count=0.
  UPDATE profile_data
    SET corso_attivo='evo_corda', evo_paid=true, updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_evo', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_evo', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'evo_mese1', p_metodo, auth.uid(),
          COALESCE(p_note, 'Evo Corda mese 1 — 160€ (corso 70 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Evo Corda mese 1 il %s, metodo %s. Lezioni residue 4 su 8. Importo residuo 160€.', p_data_inizio::text, p_metodo),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione_id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','evo_corda','funnel_stage','iscritto_evo','mese_accreditato',1,
    'lezioni_residue',4,'lezioni_totali',8,'importo_pagato',160,'importo_residuo',160,
    'data_inizio_validita',p_data_inizio,'data_fine_validita',v_data_fine,
    'message','Evo Corda mese 1 accreditato: 4 lezioni residue, importo da saldare 160€.');
END; $function$;

-- ─── accredita_evo_mese2 ────────────────────────────────────────────────────
-- DANNO: evo_lezioni_residue + 4 E lezioni_residue + 4.
CREATE OR REPLACE FUNCTION public.accredita_evo_mese2(p_user_id uuid, p_data_pagamento date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione iscrizioni_corso%ROWTYPE; v_lead_id uuid; v_pagamento_id uuid;
  v_nuove_residue integer; v_nuova_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_pagamento IS NULL THEN p_data_pagamento := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  SELECT * INTO v_iscrizione FROM iscrizioni_corso
  WHERE user_id=p_user_id AND tipo_corso='evo_corda' AND status='attiva'
  ORDER BY data_iscrizione DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Nessuna iscrizione Evo Corda attiva per user_id=%. Prima eseguire accredita_evo_mese1.', p_user_id; END IF;
  IF v_iscrizione.importo_pagato >= v_iscrizione.importo_concordato THEN
    RAISE EXCEPTION 'Iscrizione Evo Corda già saldata per user_id=% (importo_pagato=%, importo_concordato=%).', p_user_id, v_iscrizione.importo_pagato, v_iscrizione.importo_concordato;
  END IF;
  IF v_iscrizione.importo_pagato != 160 THEN
    RAISE EXCEPTION 'Stato pagamenti anomalo iscrizione Evo Corda user_id=%: atteso importo_pagato=160, trovato %.', p_user_id, v_iscrizione.importo_pagato;
  END IF;
  v_nuova_fine := GREATEST((v_iscrizione.data_inizio_validita + INTERVAL '75 days')::date, (p_data_pagamento + INTERVAL '30 days')::date);
  UPDATE iscrizioni_corso
    SET importo_pagato = importo_concordato, stato_pagamento = 'saldato',
        pagamento_completato_at = now(), data_fine_validita = v_nuova_fine,
        note = COALESCE(note || E'\n','') || format('Saldato il %s con accredita_evo_mese2. 8 lezioni accreditate totali.', p_data_pagamento::text),
        updated_at = now()
    WHERE id = v_iscrizione.id;

  -- DEBITO-190: via evo_lezioni_residue + 4 e lezioni_residue + 4.
  UPDATE profile_data SET evo_mese2_paid = true, updated_at = now() WHERE user_id = p_user_id;

  SELECT prenotabili INTO v_nuove_residue
    FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'evo_corda';

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_evo', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_evo', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'evo_mese2', p_metodo, auth.uid(),
          COALESCE(p_note, 'Evo Corda mese 2 (saldo) — 160€ (corso 70 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: saldato Evo Corda mese 2 il %s, metodo %s. Iscrizione completata 8/8 lezioni, residue=%s.', p_data_pagamento::text, p_metodo, v_nuove_residue),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione.id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','evo_corda','funnel_stage','iscritto_evo','mese_accreditato',2,
    'lezioni_residue',v_nuove_residue,'lezioni_totali',v_iscrizione.lezioni_totali,
    'importo_pagato',v_iscrizione.importo_concordato,'importo_residuo',0,
    'data_fine_validita',v_nuova_fine,'saldato',true,
    'message',format('Evo Corda mese 2 accreditato: +4 lezioni (totale residue=%s), iscrizione saldata.', v_nuove_residue));
END; $function$;

-- ─── accredita_advance_intero · accredita_evo_intero · accredita_intro_intero
-- NESSUN DANNO, NESSUNA RISCRITTURA. Letti per intero: non toccano nessun
-- contatore. Chiamano mese1 + mese2 e compongono il jsonb. La chiave
-- 'lezioni_residue' che contengono e' solo un campo del risultato, non una
-- scrittura. Restano esattamente come sono.


-- ─── accredita_intro_mese1 ──────────────────────────────────────────────────
-- DANNO: intro_lezioni_residue=4 E lezioni_residue=4 (colonna Open), piu'
--        intro_no_show_count=0.
CREATE OR REPLACE FUNCTION public.accredita_intro_mese1(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id=p_user_id AND tipo_corso='intro_corda' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Intro Corda attiva già presente per user_id=%. Usa accredita_intro_mese2 per il pagamento del secondo mese.', p_user_id;
  END IF;
  v_data_fine := p_data_inizio + INTERVAL '40 days';
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, stato_pagamento,
    importo_concordato, importo_pagato, note
  ) VALUES (
    p_user_id, 'intro_corda', p_data_inizio, p_data_inizio, v_data_fine,
    8, 0, 'attiva', 'acconto', 300, 150,
    '1° mese pagato (150€). Manca 2° mese (150€) per saldare 300€ totali. Lezioni accreditate al mese 1: 4 su 8.'
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: via intro_lezioni_residue=4, lezioni_residue=4, intro_no_show_count=0.
  UPDATE profile_data
    SET corso_attivo='intro_corda', intro_paid=true, updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_intro', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_intro', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'intro_mese1', p_metodo, auth.uid(),
          COALESCE(p_note, 'Intro Corda mese 1 — 150€ (corso 60 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Intro Corda mese 1 il %s, metodo %s. Lezioni residue 4 su 8. Importo residuo 150€.', p_data_inizio::text, p_metodo),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione_id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','intro_corda','funnel_stage','iscritto_intro','mese_accreditato',1,
    'lezioni_residue',4,'lezioni_totali',8,'importo_pagato',150,'importo_residuo',150,
    'data_inizio_validita',p_data_inizio,'data_fine_validita',v_data_fine,
    'message','Intro Corda mese 1 accreditato: 4 lezioni residue, importo da saldare 150€.');
END; $function$;

-- ─── accredita_intro_mese2 ──────────────────────────────────────────────────
-- DANNO: intro_lezioni_residue + 4 E lezioni_residue + 4. E' il caso citato
--        nella consegna, ma come si e' visto non era isolato.
CREATE OR REPLACE FUNCTION public.accredita_intro_mese2(p_user_id uuid, p_data_pagamento date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione iscrizioni_corso%ROWTYPE; v_lead_id uuid; v_pagamento_id uuid;
  v_nuove_residue integer; v_nuova_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_pagamento IS NULL THEN p_data_pagamento := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %. Ammessi: contanti, bonifico, pos.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN RAISE EXCEPTION 'profile_data non trovato per user_id=%.', p_user_id; END IF;
  SELECT * INTO v_iscrizione FROM iscrizioni_corso
  WHERE user_id=p_user_id AND tipo_corso='intro_corda' AND status='attiva'
  ORDER BY data_iscrizione DESC LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'Nessuna iscrizione Intro Corda attiva per user_id=%. Prima eseguire accredita_intro_mese1.', p_user_id; END IF;
  IF v_iscrizione.importo_pagato >= v_iscrizione.importo_concordato THEN
    RAISE EXCEPTION 'Iscrizione Intro Corda già saldata per user_id=% (importo_pagato=%, importo_concordato=%).', p_user_id, v_iscrizione.importo_pagato, v_iscrizione.importo_concordato;
  END IF;
  IF v_iscrizione.importo_pagato != 150 THEN
    RAISE EXCEPTION 'Stato pagamenti anomalo iscrizione Intro Corda user_id=%: atteso importo_pagato=150, trovato %.', p_user_id, v_iscrizione.importo_pagato;
  END IF;
  v_nuova_fine := GREATEST((v_iscrizione.data_inizio_validita + INTERVAL '75 days')::date, (p_data_pagamento + INTERVAL '30 days')::date);
  UPDATE iscrizioni_corso
    SET importo_pagato = importo_concordato, stato_pagamento = 'saldato',
        pagamento_completato_at = now(), data_fine_validita = v_nuova_fine,
        note = COALESCE(note || E'\n','') || format('Saldato il %s con accredita_intro_mese2. 8 lezioni accreditate totali.', p_data_pagamento::text),
        updated_at = now()
    WHERE id = v_iscrizione.id;

  -- DEBITO-190: via intro_lezioni_residue + 4 e lezioni_residue + 4.
  UPDATE profile_data SET intro_mese2_paid = true, updated_at = now() WHERE user_id = p_user_id;

  SELECT prenotabili INTO v_nuove_residue
    FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'intro_corda';

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_intro', now(), now())
  ON CONFLICT (persona_id) DO UPDATE SET funnel_stage='iscritto_intro', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'intro_mese2', p_metodo, auth.uid(),
          COALESCE(p_note, 'Intro Corda mese 2 (saldo) — 150€ (corso 60 + sala 90)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: saldato Intro Corda mese 2 il %s, metodo %s. Iscrizione completata 8/8 lezioni, residue=%s.', p_data_pagamento::text, p_metodo, v_nuove_residue),
    auth.uid());
  RETURN jsonb_build_object('success',true,'iscrizione_id',v_iscrizione.id,'pagamento_id',v_pagamento_id,
    'lead_data_id',v_lead_id,'tipo_corso','intro_corda','funnel_stage','iscritto_intro','mese_accreditato',2,
    'lezioni_residue',v_nuove_residue,'lezioni_totali',v_iscrizione.lezioni_totali,
    'importo_pagato',v_iscrizione.importo_concordato,'importo_residuo',0,
    'data_fine_validita',v_nuova_fine,'saldato',true,
    'message',format('Intro Corda mese 2 accreditato: +4 lezioni (totale residue=%s), iscrizione saldata.', v_nuove_residue));
END; $function$;


-- ============================================================================
-- I SETTE ACCREDITI DEL CORSO OPEN
-- Nessun danno di colonna sbagliata: lezioni_residue E' la loro colonna.
-- Il problema qui e' un altro: duplicavano il valore su lezioni_iniziali_residue
-- e resettavano a mano no_show_count e spostamenti_open_residui — tre colonne
-- che spariscono in Fase D. Restano scadenza_consumo_open e frequenza_open,
-- che non sono contatori ma regole del pacchetto.
-- ============================================================================

-- ─── accredita_mezza1_open ──────────────────────────────────────────────────
-- ⚠ ATTENZIONE, QUI NON E' SOLO UNA RIMOZIONE.
--   Questa funzione NON creava nessuna riga in iscrizioni_corso: scriveva solo
--   i contatori in profile_data. Era l'unica dei sette a fare cosi'. Tolti i
--   contatori resterebbe senza nessuna fonte: corso_attivo='open' ma nessuna
--   iscrizione attiva, quindi contatori_corso vuota e prenota_corso che
--   rifiuta con "Nessuna iscrizione attiva".
--   Percio' QUI SI AGGIUNGE l'INSERT in iscrizioni_corso, copiato da
--   accredita_iscrizione_meta_open, che vende lo stesso prodotto (½ Open,
--   4 lezioni, scadenza 'mezza1'). E' idempotente come le sorelle.
CREATE OR REPLACE FUNCTION public.accredita_mezza1_open(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_data_inizio date := CURRENT_DATE;
BEGIN
  -- Modello Open — Modalità C prima rata: 4 lezioni, scadenza 40gg dal pagamento.
  -- DEBITO-190: la fonte e' l'iscrizione, non piu' il contatore.
  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status, stato_pagamento, note
    ) VALUES (
      p_user_id, 'open', v_data_inizio, v_data_inizio,
      (_calcola_scadenza_open('mezza1'))::date,
      4, 0, 'attiva', 'saldato',
      '½ Open prima rata (Modalità C). 4 lezioni.'
    );
  END IF;

  -- Restano scadenza e frequenza: sono regole del pacchetto, non contatori.
  -- Via lezioni_iniziali_residue=4, lezioni_residue=4, no_show_count=0,
  -- spostamenti_open_residui=2.
  UPDATE profile_data
    SET iscrizione_paid        = true,
        meta_open_paid         = true,
        corso_attivo           = 'open',
        frequenza_open         = 'monosett',
        scadenza_consumo_open  = now() + interval '40 days',
        mezza2_paid            = false,
        updated_at             = now()
    WHERE user_id = p_user_id;
END;
$function$;

-- ─── accredita_mezza2_open ──────────────────────────────────────────────────
-- Questa era gia' quasi a posto: scriveva lezioni_totali + 3 sull'iscrizione,
-- cioe' sulla fonte. Via solo il doppione lezioni_residue + 3 sulla cache.
CREATE OR REPLACE FUNCTION public.accredita_mezza2_open(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  -- Modello Open — Modalità C seconda rata: +3 lezioni, scadenza +35 giorni.
  UPDATE iscrizioni_corso
    SET data_fine_validita = data_fine_validita + 35,
        lezioni_totali     = COALESCE(lezioni_totali, 0) + 3,
        updated_at         = now()
    WHERE user_id = p_user_id AND tipo_corso = 'open' AND status = 'attiva';

  -- DEBITO-190: via lezioni_residue + 3. Le 3 lezioni stanno gia' sull'iscrizione.
  UPDATE profile_data
    SET mezza2_paid           = true,
        scadenza_consumo_open = scadenza_consumo_open + interval '35 days',
        updated_at            = now()
    WHERE user_id = p_user_id;
END;
$function$;

-- ─── accredita_iscrizione_meta_open ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.accredita_iscrizione_meta_open(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_lead_id uuid; v_metodo text;
  v_data_inizio date := CURRENT_DATE; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisiona prima il profilo.', p_user_id;
  END IF;
  v_metodo := CASE WHEN auth.uid() IS NULL THEN 'stripe' ELSE 'pos' END;
  v_data_fine := (_calcola_scadenza_open('mezza1'))::date;

  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status,
      importo_concordato, importo_pagato, stato_pagamento,
      metodo_pagamento, pagamento_completato_at, note
    ) VALUES (
      p_user_id, 'open', v_data_inizio, v_data_inizio, v_data_fine,
      4, 0, 'attiva', NULL, NULL, 'saldato', v_metodo, now(),
      '½ Open + iscrizione ASD (Stripe). 4 lezioni.'
    );
  END IF;

  -- DEBITO-190: via lezioni_iniziali_residue, lezioni_residue, no_show_count,
  -- spostamenti_open_residui. Restano scadenza e frequenza.
  UPDATE profile_data
    SET iscrizione_paid       = true,
        meta_open_paid        = true,
        corso_attivo          = 'open',
        frequenza_open        = 'monosett',
        scadenza_consumo_open = _calcola_scadenza_open('mezza1'),
        updated_at            = now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, fonte, ultima_interazione)
  VALUES (v_persona_id, 'iscritto_open', 'stripe_iscrizione_meta_open', now())
  ON CONFLICT (persona_id) DO UPDATE
    SET funnel_stage='iscritto_open', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'mezza1_open', v_metodo, auth.uid(),
          '½ Open + iscrizione ASD saldato via Stripe');
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a ½ Open + iscrizione ASD il %s, metodo %s. 4 lezioni.', v_data_inizio::text, v_metodo),
    auth.uid());
END;
$function$;

-- ─── accredita_pacchetto_meta_open ──────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.accredita_pacchetto_meta_open(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_lead_id uuid; v_metodo text;
  v_data_inizio date := CURRENT_DATE; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisiona prima il profilo.', p_user_id;
  END IF;
  v_metodo := CASE WHEN auth.uid() IS NULL THEN 'stripe' ELSE 'pos' END;
  v_data_fine := (_calcola_scadenza_open('mezza1'))::date;

  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status,
      importo_concordato, importo_pagato, stato_pagamento,
      metodo_pagamento, pagamento_completato_at, note
    ) VALUES (
      p_user_id, 'open', v_data_inizio, v_data_inizio, v_data_fine,
      4, 0, 'attiva', NULL, NULL, 'saldato', v_metodo, now(),
      '½ Open + Prima (Stripe). 4 lezioni.'
    );
  END IF;

  -- DEBITO-190: via i quattro contatori. Restano scadenza e frequenza.
  UPDATE profile_data
    SET prima_paid            = true,
        iscrizione_paid       = true,
        meta_open_paid        = true,
        corso_attivo          = 'open',
        frequenza_open        = 'monosett',
        scadenza_consumo_open = _calcola_scadenza_open('mezza1'),
        updated_at            = now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_open', now(), now())
  ON CONFLICT (persona_id) DO UPDATE
    SET funnel_stage='iscritto_open', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'mezza1_open', v_metodo, auth.uid(),
          '½ Open + Prima saldato via Stripe');
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a ½ Open + Prima il %s, metodo %s. 4 lezioni.', v_data_inizio::text, v_metodo),
    auth.uid());
END;
$function$;

-- ─── accredita_pacchetto_open_intero ────────────────────────────────────────
-- Chiamata anche dal trigger _trg_open_presenza_garantisce_corso.
CREATE OR REPLACE FUNCTION public.accredita_pacchetto_open_intero(p_user_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_lead_id uuid;
  v_data_inizio date := CURRENT_DATE; v_data_fine date;
BEGIN
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisiona prima il profilo.', p_user_id;
  END IF;
  v_data_fine := (_calcola_scadenza_open('bisett'))::date;

  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status,
      importo_concordato, importo_pagato, stato_pagamento, note
    ) VALUES (
      p_user_id, 'open', v_data_inizio, v_data_inizio, v_data_fine,
      7, 0, 'attiva', NULL, NULL, 'saldato',
      'Open intero (Stripe). 7 lezioni.'
    );
  END IF;

  -- DEBITO-190: via i quattro contatori. Restano scadenza e frequenza.
  UPDATE profile_data
    SET prima_paid            = true,
        iscrizione_paid       = true,
        corso_attivo          = 'open',
        frequenza_open        = 'bisett',
        scadenza_consumo_open = _calcola_scadenza_open('bisett'),
        updated_at            = now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_open', now(), now())
  ON CONFLICT (persona_id) DO UPDATE
    SET funnel_stage='iscritto_open', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'open', 'pos', auth.uid(),
          'Open intero saldato via Stripe');
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota', 'Sistema: iscritto a Open intero (Stripe). 7 lezioni.', auth.uid());
END;
$function$;

-- ─── accredita_acconto_open ─────────────────────────────────────────────────
-- Nota: l'iscrizione nasce con importo_pagato 115 < concordato 215, ma il
-- dimezzamento del mese 1 NON si applica al Corso Open (regola di Marco):
-- le lezioni sono quelle scritte in lezioni_totali, cioe' p_lezioni.
CREATE OR REPLACE FUNCTION public.accredita_acconto_open(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_lezioni integer DEFAULT 4, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  PERFORM public.assert_staff();
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos') THEN
    RAISE EXCEPTION 'p_metodo non valido: %.', p_metodo;
  END IF;
  IF p_lezioni IS NULL OR p_lezioni < 1 OR p_lezioni > 7 THEN
    RAISE EXCEPTION 'p_lezioni deve essere 1-7 (ricevuto %).', p_lezioni;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisiona prima il profilo.', p_user_id;
  END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Open attiva già presente per user_id=%.', p_user_id;
  END IF;
  v_data_fine := (_calcola_scadenza_open('bisett'))::date;
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, importo_concordato, importo_pagato, note
  ) VALUES (
    p_user_id, 'open', p_data_inizio, p_data_inizio, v_data_fine,
    p_lezioni, 0, 'attiva', 215, 115,
    COALESCE(p_note, format('Open in ACCONTO: pagato 115€ di 215€ (voce mezza1_open). Credito %s lezioni. Residuo 100€.', p_lezioni))
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: via lezioni_iniziali_residue, lezioni_residue, no_show_count,
  -- spostamenti_open_residui. Restano scadenza e frequenza.
  UPDATE profile_data
    SET acconto_open_paid=true, acconto_open_data=now(), corso_attivo='open',
        frequenza_open='bisett', scadenza_consumo_open=_calcola_scadenza_open('bisett'),
        updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_open', now(), now())
  ON CONFLICT (persona_id) DO UPDATE
    SET funnel_stage='iscritto_open', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'mezza1_open', p_metodo, auth.uid(),
    COALESCE(p_note, format('Open acconto 115€ (mezza1_open) — credito %s lezioni', p_lezioni)))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Open in ACCONTO (115€ di 215€) il %s, metodo %s. Credito %s lezioni. Residuo 100€.',
           p_data_inizio::text, p_metodo, p_lezioni), auth.uid());
  RETURN jsonb_build_object(
    'success', true, 'iscrizione_id', v_iscrizione_id, 'pagamento_id', v_pagamento_id,
    'lead_data_id', v_lead_id, 'tipo_corso', 'open', 'funnel_stage', 'iscritto_open',
    'stato_pagamento', 'acconto', 'lezioni_residue', p_lezioni, 'lezioni_totali', p_lezioni,
    'importo_concordato', 215, 'importo_pagato', 115, 'importo_residuo', 100,
    'data_inizio_validita', p_data_inizio, 'data_fine_validita', v_data_fine,
    'message', format('Open acconto accreditato: %s lezioni, pagato 115€ di 215€.', p_lezioni));
END;
$function$;

-- ─── accredita_saldo_open_intero ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.accredita_saldo_open_intero(p_user_id uuid, p_data_inizio date DEFAULT CURRENT_DATE, p_metodo text DEFAULT 'contanti'::text, p_note text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_persona_id uuid; v_iscrizione_id uuid; v_lead_id uuid; v_pagamento_id uuid; v_data_fine date;
BEGIN
  PERFORM public.assert_staff();
  IF p_user_id IS NULL THEN RAISE EXCEPTION 'p_user_id non puo essere NULL'; END IF;
  IF p_data_inizio IS NULL THEN p_data_inizio := CURRENT_DATE; END IF;
  IF auth.uid() IS NULL AND p_metodo = 'contanti' THEN p_metodo := 'stripe'; END IF;
  IF p_metodo NOT IN ('contanti','bonifico','pos','stripe') THEN
    RAISE EXCEPTION 'p_metodo non valido: %.', p_metodo;
  END IF;
  SELECT persona_id INTO v_persona_id FROM profile_data WHERE user_id = p_user_id;
  IF v_persona_id IS NULL THEN
    RAISE EXCEPTION 'profile_data non trovato per user_id=%. Provisiona prima il profilo.', p_user_id;
  END IF;
  IF EXISTS (SELECT 1 FROM iscrizioni_corso WHERE user_id = p_user_id AND tipo_corso='open' AND status='attiva') THEN
    RAISE EXCEPTION 'Iscrizione Open attiva già presente per user_id=%.', p_user_id;
  END IF;
  v_data_fine := (_calcola_scadenza_open('bisett'))::date;
  INSERT INTO iscrizioni_corso (
    user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
    lezioni_totali, lezioni_completate, status, stato_pagamento,
    metodo_pagamento, pagamento_completato_at, importo_concordato, importo_pagato, note
  ) VALUES (
    p_user_id, 'open', p_data_inizio, p_data_inizio, v_data_fine,
    7, 0, 'attiva', 'saldato', p_metodo, now(), 215, 215,
    COALESCE(p_note, 'Open saldato (215€ — corso + iscrizione ASD). 7 lezioni.')
  ) RETURNING id INTO v_iscrizione_id;

  -- DEBITO-190: via i quattro contatori. Restano scadenza e frequenza.
  UPDATE profile_data
    SET iscrizione_paid=true, corso_attivo='open',
        frequenza_open='bisett', scadenza_consumo_open=_calcola_scadenza_open('bisett'),
        updated_at=now()
    WHERE user_id = p_user_id;

  INSERT INTO lead_data (persona_id, funnel_stage, ultima_interazione, updated_at)
  VALUES (v_persona_id, 'iscritto_open', now(), now())
  ON CONFLICT (persona_id) DO UPDATE
    SET funnel_stage='iscritto_open', ultima_interazione=now(), updated_at=now()
  RETURNING id INTO v_lead_id;
  INSERT INTO pagamenti_manuali (persona_id, user_id, lead_data_id, voce, metodo, registrato_da, note)
  VALUES (v_persona_id, p_user_id, v_lead_id, 'open', p_metodo, auth.uid(),
    COALESCE(p_note, 'Open saldato 215€ (corso + iscrizione ASD)'))
  RETURNING id INTO v_pagamento_id;
  INSERT INTO crm_follow_ups (lead_id, tipo, testo, created_by)
  VALUES (v_lead_id, 'nota',
    format('Sistema: iscritto a Open (saldato 215€) il %s, metodo %s. 7 lezioni.', p_data_inizio::text, p_metodo),
    auth.uid());
  RETURN jsonb_build_object(
    'success', true, 'iscrizione_id', v_iscrizione_id, 'pagamento_id', v_pagamento_id,
    'lead_data_id', v_lead_id, 'tipo_corso', 'open', 'funnel_stage', 'iscritto_open',
    'stato_pagamento', 'saldato', 'lezioni_residue', 7, 'lezioni_totali', 7,
    'importo_concordato', 215, 'importo_pagato', 215,
    'data_inizio_validita', p_data_inizio, 'data_fine_validita', v_data_fine,
    'message', 'Open saldato accreditato: 7 lezioni, 215€.');
END;
$function$;


-- ============================================================================
-- PARTE 4 · LE FUNZIONI DI SEGRETERIA E I CRUSCOTTI
-- ============================================================================

-- ─── staff_attiva_corso · DUE OVERLOAD ──────────────────────────────────────
-- PRIMA: scriveva lezioni_residue e lezioni_iniziali_residue su profile_data,
--        e NON creava nessuna riga in iscrizioni_corso. Stesso buco di
--        accredita_mezza1_open: la fonte non esisteva, esisteva solo la cache.
-- DOPO:  crea l'iscrizione (la fonte) e lascia a profile_data solo
--        corso_attivo, iscrizione_paid, frequenza e scadenza Open.
--
-- ⚠ DOMANDA PER MARCO, non l'ho decisa io.
--   Questa funzione usa 6 lezioni per Intro Corda, mentre accredita_intro_mese1
--   crea l'iscrizione con 8 (4 al mese 1 + 4 al mese 2). Gli altri combaciano:
--   Open 7, Advance 8, Evo 8. Ho lasciato il 6 per non cambiare comportamento,
--   ma uno dei due numeri e' sbagliato. Da allineare prima di applicare.
--
-- Nota: l'INSERT e' condizionato come nelle sorelle, cosi' riattivare un corso
-- gia' attivo non crea doppioni. La validita' di 45 giorni per Open era gia'
-- quella scritta qui; per gli altri corsi non c'era una scadenza, quindi
-- l'iscrizione nasce senza data_fine_validita, che la view accetta.

CREATE OR REPLACE FUNCTION public.staff_attiva_corso(p_user_id uuid, p_corso text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_default_lezioni int; v_scadenza timestamptz; v_funnel_stage text;
  v_lead_id uuid; v_profile_exists boolean; v_freq text := NULL;
BEGIN
  IF NOT is_staff() THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;
  IF p_corso NOT IN ('open','advance','intro_corda','evo_corda') THEN
    RAISE EXCEPTION 'Corso non valido: %. Valori ammessi: open, advance, intro_corda, evo_corda', p_corso;
  END IF;
  SELECT EXISTS(SELECT 1 FROM profile_data WHERE user_id = p_user_id) INTO v_profile_exists;
  IF NOT v_profile_exists THEN RAISE EXCEPTION 'Profilo non trovato per user_id %', p_user_id; END IF;

  v_default_lezioni := CASE p_corso
    WHEN 'open' THEN 7 WHEN 'advance' THEN 8 WHEN 'intro_corda' THEN 6 WHEN 'evo_corda' THEN 8 END;
  v_funnel_stage := CASE p_corso
    WHEN 'open' THEN 'iscritto_open' WHEN 'advance' THEN 'iscritto_advance'
    WHEN 'intro_corda' THEN 'iscritto_intro' WHEN 'evo_corda' THEN 'iscritto_evo' END;
  IF p_corso = 'open' THEN v_freq := 'bisett'; v_scadenza := now() + interval '45 days'; END IF;

  -- DEBITO-190: la fonte. Prima non veniva creata: c'era solo il contatore.
  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso = p_corso AND status = 'attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status, stato_pagamento, note
    ) VALUES (
      p_user_id, p_corso, CURRENT_DATE, CURRENT_DATE,
      CASE WHEN p_corso = 'open' THEN v_scadenza::date ELSE NULL END,
      v_default_lezioni, 0, 'attiva', 'saldato',
      format('Attivato dalla segreteria (staff_attiva_corso): %s lezioni.', v_default_lezioni)
    );
  END IF;

  -- DEBITO-190: via lezioni_residue e lezioni_iniziali_residue.
  UPDATE profile_data
    SET corso_attivo          = p_corso,
        iscrizione_paid       = true,
        frequenza_open        = COALESCE(v_freq, frequenza_open),
        scadenza_consumo_open = CASE WHEN p_corso='open' THEN v_scadenza ELSE scadenza_consumo_open END,
        updated_at            = now()
    WHERE user_id = p_user_id;

  SELECT id INTO v_lead_id FROM crm_leads WHERE converted_profile_id = p_user_id LIMIT 1;
  IF v_lead_id IS NOT NULL THEN
    UPDATE crm_leads SET funnel_stage = v_funnel_stage, stato_gestione = 'attivo', updated_at = now()
      WHERE id = v_lead_id
        AND funnel_stage NOT IN ('concluso_lavorato','maestro_di_cordata','ibernato','perso');
    INSERT INTO crm_follow_ups (lead_id, tipo, esito, testo, created_by)
    VALUES (v_lead_id, 'altro', 'corso_attivato',
      format('Attivato corso %s (default: %s lezioni)', p_corso, v_default_lezioni), auth.uid());
  END IF;

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'corso', p_corso,
    'lezioni', v_default_lezioni, 'lead_id', v_lead_id, 'funnel_stage', v_funnel_stage);
END;
$function$;

CREATE OR REPLACE FUNCTION public.staff_attiva_corso(p_user_id uuid, p_corso text, p_skip_staff_check boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_default_lezioni int; v_scadenza timestamptz; v_funnel_stage text;
  v_lead_id uuid; v_profile_exists boolean; v_freq text := NULL;
BEGIN
  -- SICUREZZA (DEBITO-190, trovato dalla review del 22 set): il bypass NON puo'
  -- dipendere da un booleano che arriva dal chiamante. Questa funzione e'
  -- SECURITY DEFINER con EXECUTE a anon e authenticated: con la guardia vecchia
  -- bastava passare p_skip_staff_check := true dalla chiave anon — quella
  -- pubblicata in ogni pagina del sito — per attivare un corso a pagamento a
  -- chiunque, senza nessuna autenticazione.
  -- Ora il bypass vale solo se il ruolo Postgres del chiamante e' gia' di per se'
  -- privilegiato: postgres (SQL editor) o service_role (Worker). Un client
  -- PostgREST arriva come anon o authenticated e non lo ottiene mai.
  IF NOT is_staff()
     AND NOT (p_skip_staff_check AND current_user IN ('postgres','service_role')) THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;
  IF p_corso NOT IN ('open','advance','intro_corda','evo_corda') THEN
    RAISE EXCEPTION 'Corso non valido: %. Valori ammessi: open, advance, intro_corda, evo_corda', p_corso;
  END IF;
  SELECT EXISTS(SELECT 1 FROM profile_data WHERE user_id = p_user_id) INTO v_profile_exists;
  IF NOT v_profile_exists THEN RAISE EXCEPTION 'Profilo non trovato per user_id %', p_user_id; END IF;

  v_default_lezioni := CASE p_corso
    WHEN 'open' THEN 7 WHEN 'advance' THEN 8 WHEN 'intro_corda' THEN 6 WHEN 'evo_corda' THEN 8 END;
  v_funnel_stage := CASE p_corso
    WHEN 'open' THEN 'iscritto_open' WHEN 'advance' THEN 'iscritto_advance'
    WHEN 'intro_corda' THEN 'iscritto_intro' WHEN 'evo_corda' THEN 'iscritto_evo' END;
  IF p_corso = 'open' THEN v_freq := 'bisett'; v_scadenza := now() + interval '45 days'; END IF;

  IF NOT EXISTS (SELECT 1 FROM iscrizioni_corso
                 WHERE user_id = p_user_id AND tipo_corso = p_corso AND status = 'attiva') THEN
    INSERT INTO iscrizioni_corso (
      user_id, tipo_corso, data_iscrizione, data_inizio_validita, data_fine_validita,
      lezioni_totali, lezioni_completate, status, stato_pagamento, note
    ) VALUES (
      p_user_id, p_corso, CURRENT_DATE, CURRENT_DATE,
      CASE WHEN p_corso = 'open' THEN v_scadenza::date ELSE NULL END,
      v_default_lezioni, 0, 'attiva', 'saldato',
      format('Backfill segreteria (staff_attiva_corso): %s lezioni.', v_default_lezioni)
    );
  END IF;

  UPDATE profile_data
    SET corso_attivo          = p_corso,
        iscrizione_paid       = true,
        frequenza_open        = COALESCE(v_freq, frequenza_open),
        scadenza_consumo_open = CASE WHEN p_corso='open' THEN v_scadenza ELSE scadenza_consumo_open END,
        updated_at            = now()
    WHERE user_id = p_user_id;

  SELECT id INTO v_lead_id FROM crm_leads WHERE converted_profile_id = p_user_id LIMIT 1;
  IF v_lead_id IS NOT NULL THEN
    UPDATE crm_leads SET funnel_stage = v_funnel_stage, stato_gestione = 'attivo', updated_at = now()
      WHERE id = v_lead_id
        AND funnel_stage NOT IN ('concluso_lavorato','maestro_di_cordata','ibernato','perso');
    INSERT INTO crm_follow_ups (lead_id, tipo, esito, testo, created_by)
    VALUES (v_lead_id, 'nota', 'appuntamento_preso',
      format('🎯 Attivato corso %s (default: %s lezioni) — backfill segreteria', p_corso, v_default_lezioni), auth.uid());
  END IF;

  RETURN jsonb_build_object('success', true, 'user_id', p_user_id, 'corso', p_corso,
    'lezioni', v_default_lezioni, 'lead_id', v_lead_id, 'funnel_stage', v_funnel_stage);
END;
$function$;

-- Cintura: attivare un corso non e' mai un'operazione da utente anonimo.
-- Nessuna pagina del repo chiama staff_attiva_corso (verificato il 22 set),
-- quindi togliere anon non rompe niente di quello che c'e' oggi.
REVOKE EXECUTE ON FUNCTION public.staff_attiva_corso(uuid, text) FROM anon;
REVOKE EXECUTE ON FUNCTION public.staff_attiva_corso(uuid, text, boolean) FROM anon;

-- ─── get_cruscotto_percorsi ─────────────────────────────────────────────────
-- PRIMA: leggeva le quattro colonne salvate (lezioni_residue,
--        advance_/intro_/evo_lezioni_residue) per decidere i bucket
--        "corso finito" e l'alert di scadenza, e contava a parte le
--        prenotazioni future.
-- DOPO:  legge tutto da contatori_corso. Nessuna scrittura, ne' prima ne' ora.
--        La firma e le colonne di ritorno restano IDENTICHE: commerciale.html
--        (riga 769) le usa per nome.
--        "residue_*" ora significa "prenotabili ora" per quel corso, cioe'
--        esattamente quello che il contatore salvato voleva dire.
--        Le prenotazioni future vengono da in_agenda, senza ricontarle.
CREATE OR REPLACE FUNCTION public.get_cruscotto_percorsi()
RETURNS TABLE(persona_id uuid, user_id uuid, nome text, cognome text, telefono text, email text, bucket text, corso_attivo text, residue_open integer, residue_advance integer, residue_intro integer, residue_evo integer, scadenza_open timestamp with time zone, scadenza_advance timestamp with time zone, scadenza_intro timestamp with time zone, scadenza_evo timestamp with time zone, prenotazioni_future integer, alert_scaduto boolean, data_prima_lezione date, recensione_inviata_at timestamp with time zone)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.uid() IS NOT NULL
     AND auth.uid() <> '27b04151-93a7-4ecc-824c-fe337cc631a6'::uuid
     AND NOT EXISTS (
       SELECT 1 FROM profile_data pd0
       WHERE pd0.user_id = auth.uid()
         AND pd0.staff_role IN ('creator','admin','segreteria','staff_istruttore_sr','istruttore_senior')
     )
  THEN
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
