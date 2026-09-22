-- ============================================================================
-- DEBITO-190 · Fase B · 03c — La cache transitoria
-- Data: 2026-09-22 · Decisione: Marco
--
-- IL PROBLEMA CHE RISOLVE
--   Dopo il 03 nessuna funzione scrive piu' le colonne *_residue, *_no_show_count
--   e *_spostamenti_residui. Ma le pagine le leggono ancora — portale, agenda,
--   oggi, profilo — e la Fase C non e' live. Senza questo file, dal momento in
--   cui si applica il 03 fino alla Fase C quelle colonne restano congelate
--   all'ultimo valore scritto: l'allievo prenota e il portale continua a
--   mostrargli il numero di ieri.
--
-- COSA FA
--   Un trigger su prenotazioni_corso e iscrizioni_corso ricalcola da
--   contatori_corso e riscrive le vecchie colonne per l'allievo toccato.
--   Da qui in poi quelle colonne NON sono piu' un dato: sono una copia.
--   Una sola cosa le scrive, e le scrive derivandole. E' la stessa idea del
--   DEBITO-190, applicata al periodo di transizione.
--
--   ⚠ NON e' un ritorno indietro: nessuna guardia, nessuna RPC e nessun
--     conteggio legge piu' da queste colonne. Le leggono solo le pagine, che
--     in Fase C passeranno a get_contatori. Poi il file 05 le ritira, e questo
--     trigger se ne va con loro.
--
-- ORDINE:  03b → 01 → 03 → 03c → SELECT ricalcola_cache_tutti();
--
-- PREREQUISITI: 01 (la view) e 03 (le RPC che non scrivono piu').
-- ============================================================================

-- ---------------------------------------------------------------------------
-- Il ricalcolo per un singolo allievo.
-- I corsi senza iscrizione attiva vanno a 0: e' il modo in cui i "crediti
-- orfani" trovati dalla sezione 2 della 02 — 12 righe su 10 allievi, fra cui
-- 6 lezioni Open su chi non ha mai avuto un'iscrizione Open — si spengono da
-- soli, senza aspettare la bonifica della Fase D.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ricalcola_cache_contatori(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  o record; a record; i record; e record;
BEGIN
  IF p_user_id IS NULL THEN RETURN; END IF;

  SELECT * INTO o FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'open';
  SELECT * INTO a FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'advance';
  SELECT * INTO i FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'intro_corda';
  SELECT * INTO e FROM contatori_corso WHERE user_id = p_user_id AND tipo_corso = 'evo_corda';

  UPDATE profile_data SET
    -- prenotabili, non "restano": e' la semantica che il contatore vecchio ha
    -- sempre avuto, scalare alla prenotazione. Vedi il metro della 02.
    lezioni_residue             = coalesce(o.prenotabili, 0),
    advance_lezioni_residue     = coalesce(a.prenotabili, 0),
    intro_lezioni_residue       = coalesce(i.prenotabili, 0),
    evo_lezioni_residue         = coalesce(e.prenotabili, 0),
    no_show_count               = coalesce(o.ghostate, 0),
    advance_no_show_count       = coalesce(a.ghostate, 0),
    intro_no_show_count         = coalesce(i.ghostate, 0),
    evo_no_show_count           = coalesce(e.ghostate, 0),
    spostamenti_open_residui    = coalesce(o.spostamenti_residui, 0),
    advance_spostamenti_residui = coalesce(a.spostamenti_residui, 0),
    intro_spostamenti_residui   = coalesce(i.spostamenti_residui, 0),
    evo_spostamenti_residui     = coalesce(e.spostamenti_residui, 0),
    updated_at                  = now()
  WHERE user_id = p_user_id;
END;
$function$;

COMMENT ON FUNCTION public.ricalcola_cache_contatori(uuid) IS
  'DEBITO-190 transitorio: riscrive le vecchie colonne di profile_data leggendo '
  'contatori_corso. Unica cosa che le scrive fino alla Fase D. Corso senza '
  'iscrizione attiva = 0.';

-- ---------------------------------------------------------------------------
-- Il trigger. AFTER, perche' deve vedere la riga gia' scritta: la view conta
-- le righe, quindi prima che il COMMIT della riga sia visibile non c'e' niente
-- da contare. Nessuna ricorsione: scrive profile_data, che non ha trigger
-- verso queste due tabelle.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tg_ricalcola_cache_contatori()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Su UPDATE l'intestatario potrebbe cambiare (non succede, ma costa niente
  -- coprirlo): si ricalcola per entrambi.
  IF TG_OP = 'DELETE' THEN
    PERFORM ricalcola_cache_contatori(OLD.user_id);
  ELSE
    PERFORM ricalcola_cache_contatori(NEW.user_id);
    IF TG_OP = 'UPDATE' AND OLD.user_id IS DISTINCT FROM NEW.user_id THEN
      PERFORM ricalcola_cache_contatori(OLD.user_id);
    END IF;
  END IF;
  RETURN NULL;   -- AFTER trigger: il valore di ritorno non viene usato
END;
$function$;

DROP TRIGGER IF EXISTS tg_cache_contatori_prenotazioni ON public.prenotazioni_corso;
CREATE TRIGGER tg_cache_contatori_prenotazioni
  AFTER INSERT OR UPDATE OR DELETE ON public.prenotazioni_corso
  FOR EACH ROW EXECUTE FUNCTION public.tg_ricalcola_cache_contatori();

DROP TRIGGER IF EXISTS tg_cache_contatori_iscrizioni ON public.iscrizioni_corso;
CREATE TRIGGER tg_cache_contatori_iscrizioni
  AFTER INSERT OR UPDATE OR DELETE ON public.iscrizioni_corso
  FOR EACH ROW EXECUTE FUNCTION public.tg_ricalcola_cache_contatori();

-- ---------------------------------------------------------------------------
-- Il ricalcolo di tutti, da lanciare UNA VOLTA subito dopo aver applicato
-- questo file. Allinea in un colpo i profili attivi e spegne i crediti orfani.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ricalcola_cache_tutti()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_profili int := 0;
  v_prima   int;
  v_dopo    int;
  u record;
BEGIN
  IF NOT is_staff() AND current_user NOT IN ('postgres','service_role') THEN
    RAISE EXCEPTION 'Permesso negato: serve staff' USING ERRCODE = '42501';
  END IF;

  -- quanti profili avevano almeno un contatore diverso da zero, prima
  SELECT count(*) INTO v_prima FROM profile_data
   WHERE coalesce(lezioni_residue,0) + coalesce(advance_lezioni_residue,0)
       + coalesce(intro_lezioni_residue,0) + coalesce(evo_lezioni_residue,0) > 0;

  FOR u IN SELECT user_id FROM profile_data LOOP
    PERFORM ricalcola_cache_contatori(u.user_id);
    v_profili := v_profili + 1;
  END LOOP;

  SELECT count(*) INTO v_dopo FROM profile_data
   WHERE coalesce(lezioni_residue,0) + coalesce(advance_lezioni_residue,0)
       + coalesce(intro_lezioni_residue,0) + coalesce(evo_lezioni_residue,0) > 0;

  RETURN jsonb_build_object(
    'profili_ricalcolati',           v_profili,
    'con_credito_prima',             v_prima,
    'con_credito_dopo',              v_dopo,
    'crediti_orfani_spenti',         v_prima - v_dopo,
    'messaggio', format('Ricalcolati %s profili. Avevano un credito in %s, ora in %s: %s percorsi senza iscrizione attiva sono stati azzerati.',
                        v_profili, v_prima, v_dopo, v_prima - v_dopo));
END;
$function$;

COMMENT ON FUNCTION public.ricalcola_cache_tutti() IS
  'DEBITO-190 transitorio: riallinea la cache di tutti i profili. Da lanciare '
  'una volta dopo il 03c. Torna un riepilogo leggibile.';

-- ============================================================================
-- VERIFICA DOPO L'APPLICAZIONE
-- ============================================================================
-- V1 · Il ricalcolo di tutti, una volta sola:
--   SELECT public.ricalcola_cache_tutti();
--   Atteso: profili_ricalcolati ≈ 187, e crediti_orfani_spenti > 0 — sono i
--   percorsi chiusi che avevano ancora un credito appeso (12 righe su 10
--   allievi il 22 set, fra cui 6 lezioni Open a chi non ha mai avuto un Open).
--
-- V2 · La sezione 1 della 02 ora deve essere TUTTA a posto:
--   (rilanciare 02_audit_scarti.sql, sezione 1)
--   Atteso: 18 righe, 18 "a posto", ZERO "FUORI POSTO".
--   Anche Baldina e Baldassarini: il contatore non e' piu' un dato separato che
--   puo' divergere, e' una copia riscritta dalla view a ogni movimento.
--   Se qualcuno resta fuori posto, il trigger non sta girando: controllare
--   che i due trigger esistano con
--     SELECT tgname, tgrelid::regclass FROM pg_trigger
--     WHERE tgname LIKE 'tg_cache_contatori%' AND NOT tgisinternal;
--
-- V3 · Il trigger si sveglia davvero (prova non distruttiva):
--   BEGIN;
--     UPDATE public.prenotazioni_corso SET updated_at = now()
--      WHERE id = (SELECT id FROM public.prenotazioni_corso LIMIT 1);
--     -- atteso: nessun errore, e profile_data di quell'allievo riscritto
--   ROLLBACK;
