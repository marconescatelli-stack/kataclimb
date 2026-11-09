-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/08c · AVVISI PUSH/EMAIL DEI CAMBI TURNO MONITOR (consegna v1, 9 nov 2026)
-- MIGRAZIONE. Si applica DOPO la 08 (turni dichiarati) e DOPO il deploy del worker notifiche v3.0.
-- Ordine: worker v3.0 → 08 → 08c → merge delle pagine. Prova: 08c_avvisi_cambio_turno_PROVA.sql (finisce con ROLLBACK).
--
-- Contratto col worker v3.0 (eventi_notifica, stato di default 'da_mandare'):
--   turno.cambio.proposto  → a chi riceve la proposta (Y)        canale both
--   turno.cambio.accettato → a chi ha proposto (X)                canale both (il worker avvisa anche creator + segreteria)
--   turno.cambio.rifiutato → a chi ha proposto (X)                canale both
--   turno.cambio.ritirato  → a Y (anche quando si chiude da sola perché X si toglie o il turno viene annullato)  canale push
--   turno.cambio.scaduto   → a chi ha proposto (X): il turno è iniziato e nessuno ha accettato   canale both
--   payload: {proposta_id, da_nome, a_nome, data 'YYYY-MM-DD', ora_inizio 'HH:MM', ora_fine 'HH:MM', nota}
--   nota = quella di chi propone (proposto) o di chi rifiuta (rifiutato), altrimenti null. Nomi = persone.nome.
--   dedup_key = 'turno-<tipo>-<proposta_id>': un doppio clic non manda due avvisi.
--   schedulato_per = finestra di quiete di tg_lead_richieste_notifica (22:00–07:59 Roma → 08:00), ma subito se il turno è oggi.
--
-- Scelte (da dire a Marco):
--  · Un solo trigger su cambi_turno_monitor invece dell'insert copiato in ogni funzione: copre da solo proposta,
--    accetta, rifiuta, ritira, chiusura automatica (Claudia si toglie / turno annullato) e scadenza, e le funzioni
--    della 08 restano quelle già provate. Dentro BEGIN … EXCEPTION WHEN OTHERS THEN NULL: se l'avviso fallisce il cambio vale.
--  · Proposta "a chiunque" (a_user_id nullo) — decisione Marco 9 nov, worker v3.1: proposto e ritirato si accodano con
--    user_id NULL e nel payload a_tutti: true e da_user_id (chi propone); a_nome nullo. Accettato/rifiutato/scaduto
--    vanno a X come sempre, con a_nome = chi ha accettato.
--  · Scaduta: nuovo stato 'scaduta' in cambi_turno_monitor. Le proposte ancora aperte a turno iniziato le chiude
--    _cambi_turno_scaduti(), chiamata da un blocco nuovo (10) di cron_genera_eventi_mattutini. Il blocco si aggiunge alla
--    definizione LIVE del cron (sostituzione di testo controllata, sotto), senza ricopiare a mano i 9 blocchi esistenti.
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1. stato 'scaduta' ───────────────────────────────────────────────────────────────────────────
ALTER TABLE public.cambi_turno_monitor DROP CONSTRAINT IF EXISTS cambi_turno_monitor_stato_check;
ALTER TABLE public.cambi_turno_monitor ADD CONSTRAINT cambi_turno_monitor_stato_check
  CHECK (stato IN ('proposta','accettata','rifiutata','ritirata','scaduta'));

-- ── 2. l'avviso di un cambio, secondo il contratto del worker v3.0 ──────────────────────────────
CREATE OR REPLACE FUNCTION public._cambio_turno_avvisa(p_cambio_id uuid, p_tipo text)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE c cambi_turno_monitor; i impegni_staff; v_dest uuid; v_canale text; v_a uuid; v_nota text; v_tutti boolean := false;
        v_ora int; v_quando timestamptz; v_oggi date := (now() AT TIME ZONE 'Europe/Rome')::date;
BEGIN
  SELECT * INTO c FROM cambi_turno_monitor WHERE id = p_cambio_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO i FROM impegni_staff WHERE id = c.impegno_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  -- Y: il destinatario della proposta, oppure (proposta a tutti) chi l'ha accettata; mai chi ritira
  v_a := coalesce(c.a_user_id, CASE WHEN p_tipo = 'accettato' THEN c.risposto_da END);
  CASE p_tipo
    WHEN 'proposto'  THEN v_dest := c.a_user_id;  v_canale := 'both'; v_nota := c.nota;
    WHEN 'accettato' THEN v_dest := c.da_user_id; v_canale := 'both';
    WHEN 'rifiutato' THEN v_dest := c.da_user_id; v_canale := 'both'; v_nota := c.nota_risposta;
    WHEN 'ritirato'  THEN v_dest := c.a_user_id;  v_canale := 'push';
    WHEN 'scaduto'   THEN v_dest := c.da_user_id; v_canale := 'both';
    ELSE RETURN NULL;
  END CASE;
  -- proposta a tutti (worker v3.1): proposto e ritirato senza destinatario, li smista il worker
  v_tutti := c.a_user_id IS NULL AND p_tipo IN ('proposto','ritirato');
  IF v_dest IS NULL AND NOT v_tutti THEN RETURN NULL; END IF;
  -- finestra di quiete come tg_lead_richieste_notifica, ma il turno di oggi si avvisa subito
  IF i.data = v_oggi THEN
    v_quando := now();
  ELSE
    v_ora := date_part('hour', now() AT TIME ZONE 'Europe/Rome')::int;
    IF v_ora >= 22 THEN    v_quando := (v_oggi + 1 + time '08:00') AT TIME ZONE 'Europe/Rome';
    ELSIF v_ora < 8 THEN   v_quando := (v_oggi + time '08:00') AT TIME ZONE 'Europe/Rome';
    ELSE                   v_quando := now();
    END IF;
  END IF;
  RETURN registra_evento_notifica(
    'turno.cambio.' || p_tipo, v_dest, v_canale,
    jsonb_build_object(
      'proposta_id', c.id,
      'da_nome',     (SELECT pe.nome FROM profile_data pd JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = c.da_user_id LIMIT 1),
      'a_nome',      (SELECT pe.nome FROM profile_data pd JOIN persone pe ON pe.id = pd.persona_id WHERE pd.user_id = v_a LIMIT 1),
      'data',        to_char(i.data, 'YYYY-MM-DD'),
      'ora_inizio',  to_char(i.ora_inizio, 'HH24:MI'),
      'ora_fine',    to_char(i.ora_fine, 'HH24:MI'),
      'nota',        v_nota)
    || CASE WHEN v_tutti THEN jsonb_build_object('a_tutti', true, 'da_user_id', c.da_user_id) ELSE '{}'::jsonb END,
    v_quando,
    'turno-' || p_tipo || '-' || c.id);
END $$;

-- ── 3. un trigger per tutti i passaggi della proposta ───────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tg_cambi_turno_notifica()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  BEGIN
    IF TG_OP = 'INSERT' AND NEW.stato = 'proposta' THEN
      PERFORM _cambio_turno_avvisa(NEW.id, 'proposto');
    ELSIF TG_OP = 'UPDATE' AND NEW.stato IS DISTINCT FROM OLD.stato AND OLD.stato = 'proposta' THEN
      PERFORM _cambio_turno_avvisa(NEW.id, CASE NEW.stato
        WHEN 'accettata' THEN 'accettato' WHEN 'rifiutata' THEN 'rifiutato'
        WHEN 'ritirata'  THEN 'ritirato'  WHEN 'scaduta'   THEN 'scaduto' END);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- l'avviso è un di più: se fallisce, il cambio turno vale lo stesso
  END;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_cambi_turno_notifica ON public.cambi_turno_monitor;
CREATE TRIGGER trg_cambi_turno_notifica AFTER INSERT OR UPDATE OF stato ON public.cambi_turno_monitor
  FOR EACH ROW EXECUTE FUNCTION public.tg_cambi_turno_notifica();

-- ── 4. scadenza: proposta ancora aperta a turno iniziato → scaduta (il trigger accoda turno.cambio.scaduto) ──
CREATE OR REPLACE FUNCTION public._cambi_turno_scaduti()
 RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE n int;
BEGIN
  UPDATE cambi_turno_monitor c
     SET stato = 'scaduta', risposto_il = now(),
         nota_risposta = coalesce(c.nota_risposta || ' · ', '') || 'scaduta: il turno è iniziato senza che nessuno accettasse'
    FROM impegni_staff i
   WHERE i.id = c.impegno_id AND c.stato = 'proposta'
     AND _ts_roma(i.data, i.ora_inizio) <= now();
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- ── 5. blocco 10 nel cron che il worker chiama ogni ~10 minuti (aggiunto alla definizione live) ──
DO $do$
DECLARE d text; n0 int;
  a_decl text := E'  v_priv_istr_count  int := 0;\nBEGIN';
  a_ret  text := E'  RETURN jsonb_build_object(\n    ''eseguito_il'', now(),';
  a_fine text := E'''promemoria_privata_istruttore_processati'', v_priv_istr_count\n  );';
BEGIN
  d := pg_get_functiondef('public.cron_genera_eventi_mattutini()'::regprocedure);
  IF position('_cambi_turno_scaduti' IN d) > 0 THEN RAISE NOTICE 'blocco 10 già presente'; RETURN; END IF;
  FOREACH n0 IN ARRAY ARRAY[
      (length(d) - length(replace(d, a_decl, ''))) / length(a_decl),
      (length(d) - length(replace(d, a_ret,  ''))) / length(a_ret),
      (length(d) - length(replace(d, a_fine, ''))) / length(a_fine)] LOOP
    IF n0 <> 1 THEN RAISE EXCEPTION 'cron_genera_eventi_mattutini è cambiato: punto di aggancio non trovato una sola volta. Fermarsi e rileggere la funzione.'; END IF;
  END LOOP;
  d := replace(d, a_decl, E'  v_priv_istr_count  int := 0;\n  v_cambi_scaduti    int := 0;  -- 10) sql/monitor/08c\nBEGIN');
  d := replace(d, a_ret,
    E'  -- 10) CAMBI TURNO MONITOR SCADUTI (sql/monitor/08c, 9 nov 2026): proposta ancora aperta a turno iniziato\n'
    || E'  --     → scaduta, e il trigger di cambi_turno_monitor accoda turno.cambio.scaduto a chi proponeva (dedup_key).\n'
    || E'  --     Se fallisce, gli altri avvisi del giro partono lo stesso.\n'
    || E'  BEGIN\n    v_cambi_scaduti := _cambi_turno_scaduti();\n  EXCEPTION WHEN OTHERS THEN\n    v_cambi_scaduti := -1;\n  END;\n\n'
    || a_ret);
  d := replace(d, a_fine, E'''promemoria_privata_istruttore_processati'', v_priv_istr_count,\n    ''cambi_turno_scaduti'', v_cambi_scaduti\n  );');
  EXECUTE d;
END $do$;

-- ── 6. permessi: funzioni interne, niente anon né authenticated ─────────────────────────────────
REVOKE ALL ON FUNCTION public._cambio_turno_avvisa(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.tg_cambi_turno_notifica() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cambi_turno_scaduti() FROM PUBLIC, anon, authenticated;
