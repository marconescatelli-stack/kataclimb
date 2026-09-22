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
--   Proposta: DROP. Non la elimino di mia iniziativa perche' potrebbe essere
--   chiamata dal Worker (repo separato, non ispezionato).
--   Da decidere prima della parte 2:
-- DROP FUNCTION IF EXISTS public.marca_presenza_open(uuid, boolean);
