-- ============================================================================
-- SALA CON MONITOR · 02 — Persone seguite contate per TURNO, non per giorno
-- Data: 2026-10-07 · Preparata per Marco · APPLICATA 2026-10-07 (12:25, prove DOPO passate)
-- Richiede 01_riga_separata_sala.sql gia' applicato (il primo blocco lo controlla).
--
-- IL PROBLEMA
--   get_compenso_monitor e monitor_oggi (storico) contano le persone di un turno
--   cosi': righe osservazioni_allievo con contesto='sala_monitor' dello stesso
--   monitor nello STESSO GIORNO. Con due turni nello stesso giorno ogni turno
--   conta tutte le persone del giorno -> le ore a 8 € si pagano due volte.
--   In piu' la policy oss_allievo_autore_write lascia a qualsiasi utente staff
--   inserire direttamente righe 'sala_monitor' via API: oggi quelle righe
--   finirebbero nei compensi senza passare da monitor_segna.
--
-- LA CORREZIONE
--   Tabella turni_monitor_seguiti (turno, persona): la scrive SOLO monitor_segna,
--   che conosce il turno aperto. Nessuna policy di scrittura: da API si legge
--   (staff), non si scrive. Compensi e storico contano da qui, per turno.
--   La riga di sala del giorno in osservazioni_allievo resta com'e' (e' la nota
--   che leggono istruttori e segreteria): cambia solo da dove si conta.
--   Tabelle vuote al 7 ott (0 turni, 0 note): nessun dato da ricostruire.
--   La tabella OGGI di oggi.html (monitor_oggi.seguiti) resta per giorno: e'
--   "chi ho seguito oggi", non un conteggio pagato.
-- ============================================================================


-- ─── PRIMA · stato attuale ──────────────────────────────────────────────────
-- Giorni in cui lo stesso monitor ha piu' di un turno (sono i giorni a rischio).
-- Atteso al 7 ott: 0 righe.
SELECT monitor_user_id, data, count(*) AS turni
FROM public.turni_monitor
GROUP BY monitor_user_id, data
HAVING count(*) > 1;

-- Persone per turno con la regola di oggi (per giorno). Atteso al 7 ott: 0 righe.
SELECT t.id AS turno, t.monitor_user_id, t.data, t.inizio, t.fine,
  (SELECT count(*) FROM public.osservazioni_allievo o
    WHERE o.istruttore_user_id = t.monitor_user_id AND o.data = t.data AND o.contesto = 'sala_monitor') AS persone_contate_oggi
FROM public.turni_monitor t
ORDER BY t.data DESC, t.inizio DESC;


-- ─── CORREZIONE ─────────────────────────────────────────────────────────────
BEGIN;

DO $$
BEGIN
  IF to_regclass('public.osservazioni_allievo_sala_giorno_key') IS NULL THEN
    RAISE EXCEPTION 'Applica prima 01_riga_separata_sala.sql';
  END IF;
END $$;

CREATE TABLE public.turni_monitor_seguiti (
  turno_id    uuid NOT NULL REFERENCES public.turni_monitor(id) ON DELETE CASCADE,
  persona_id  uuid NOT NULL REFERENCES public.persone(id) ON DELETE CASCADE,
  primo_alle  timestamptz NOT NULL DEFAULT now(),
  ultimo_alle timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (turno_id, persona_id)
);
ALTER TABLE public.turni_monitor_seguiti ENABLE ROW LEVEL SECURITY;
CREATE POLICY turni_monitor_seguiti_staff_read ON public.turni_monitor_seguiti
  FOR SELECT USING (is_staff());
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.turni_monitor_seguiti FROM anon, authenticated;

-- monitor_segna: identica alla versione di 01, piu' la riga turno/persona.
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
  INSERT INTO turni_monitor_seguiti (turno_id, persona_id) VALUES (v_turno, p_persona_id)
  ON CONFLICT (turno_id, persona_id) DO UPDATE SET ultimo_alle = now();
  RETURN jsonb_build_object('ok',true,'id',v_id,'turno_id',v_turno);
END $function$;

-- monitor_oggi: cambia solo 'persone' dello storico (per turno).
CREATE OR REPLACE FUNCTION public.monitor_oggi()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'turno', (SELECT to_jsonb(t) FROM turni_monitor t WHERE t.monitor_user_id=auth.uid() AND t.data=CURRENT_DATE ORDER BY t.inizio DESC LIMIT 1),
    'seguiti', (SELECT coalesce(jsonb_agg(jsonb_build_object('persona_id',o.persona_id,'nome',pe.nome||' '||pe.cognome,'note',o.note,'aggiornato',o.updated_at) ORDER BY o.updated_at DESC),'[]')
                FROM osservazioni_allievo o JOIN persone pe ON pe.id=o.persona_id WHERE o.istruttore_user_id=auth.uid() AND o.data=CURRENT_DATE AND o.contesto='sala_monitor'),
    'storico', (SELECT coalesce(jsonb_agg(jsonb_build_object('data',t.data,'inizio',t.inizio,'fine',t.fine,
                   'ore', ROUND(EXTRACT(EPOCH FROM (COALESCE(t.fine,t.inizio)-t.inizio))/3600.0*2)/2,
                   'persone', (SELECT count(*) FROM turni_monitor_seguiti s WHERE s.turno_id=t.id),
                   'note_turno', t.note) ORDER BY t.data DESC, t.inizio DESC),'[]')
                FROM turni_monitor t WHERE t.monitor_user_id=auth.uid() AND t.data >= CURRENT_DATE-30)
  ) WHERE is_staff();
$function$;

-- get_compenso_monitor: cambia solo n_pers (per turno). Firma e colonne invariate.
CREATE OR REPLACE FUNCTION public.get_compenso_monitor(p_da date, p_a date, p_monitor_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(monitor text, monitor_user_id uuid, data date, inizio timestamp with time zone, fine timestamp with time zone, ore numeric, persone integer, ore_8 integer, ore_5 numeric, importo numeric, aperto boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH t AS (
    SELECT tm.*, COALESCE(pr.nome||' '||pr.cognome,'—') AS nome,
      ROUND(EXTRACT(EPOCH FROM (COALESCE(tm.fine, tm.inizio) - tm.inizio))/3600.0 * 2) / 2 AS ore_calc,
      (SELECT count(*) FROM turni_monitor_seguiti s WHERE s.turno_id=tm.id)::int AS n_pers
    FROM turni_monitor tm LEFT JOIN profiles pr ON pr.user_id=tm.monitor_user_id
    WHERE is_segreteria_piena() AND tm.data BETWEEN p_da AND p_a AND (p_monitor_user_id IS NULL OR tm.monitor_user_id=p_monitor_user_id)
  )
  SELECT nome, monitor_user_id, data, inizio, fine, ore_calc, n_pers,
         LEAST(n_pers, FLOOR(ore_calc))::int, ore_calc - LEAST(n_pers, FLOOR(ore_calc)),
         LEAST(n_pers, FLOOR(ore_calc))*8 + (ore_calc - LEAST(n_pers, FLOOR(ore_calc)))*5, fine IS NULL
  FROM t ORDER BY data DESC, inizio DESC;
$function$;

COMMIT;


-- ─── DOPO · 1 · tabella e permessi ──────────────────────────────────────────
-- Atteso: rls=true, una policy SELECT, nessun INSERT/UPDATE/DELETE per anon e authenticated.
SELECT relname, relrowsecurity AS rls FROM pg_class WHERE oid = 'public.turni_monitor_seguiti'::regclass;
SELECT policyname, cmd FROM pg_policies WHERE tablename = 'turni_monitor_seguiti';
SELECT grantee, string_agg(privilege_type, ',' ORDER BY privilege_type) AS permessi
FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'turni_monitor_seguiti' AND grantee IN ('anon','authenticated')
GROUP BY grantee;

-- ─── DOPO · 2 · prova vera, annullata con ROLLBACK (nessuna riga resta) ──────
-- Eseguire il blocco intero in UNA sola chiamata. Si finge di essere Mello in
-- due turni nello stesso giorno: turno 1 con la persona A, turno 2 con la B.
-- Atteso nell'ultima SELECT: DUE turni con persone = 1 ciascuno.
-- Con la regola vecchia sarebbero stati 2 e 2.
BEGIN;
SELECT set_config('request.jwt.claim.sub', 'e4841ae2-aeef-4007-839d-7837d197195b', true);
SELECT set_config('request.jwt.claims', '{"sub":"e4841ae2-aeef-4007-839d-7837d197195b","role":"authenticated"}', true);
CREATE TEMP TABLE _prova ON COMMIT DROP AS SELECT id, row_number() OVER () AS n FROM public.persone LIMIT 2;
SELECT public.monitor_turno('inizio', NULL);
SELECT public.monitor_segna((SELECT id FROM _prova WHERE n = 1), 'PROVA turno uno', NULL);
SELECT public.monitor_turno('fine', 'PROVA');
SELECT public.monitor_turno('inizio', NULL);
SELECT public.monitor_segna((SELECT id FROM _prova WHERE n = 2), 'PROVA turno due', NULL);
SELECT x->>'inizio' AS inizio, x->>'fine' AS fine, x->>'persone' AS persone
FROM jsonb_array_elements(public.monitor_oggi()->'storico') x
WHERE (x->>'data')::date = CURRENT_DATE;
ROLLBACK;
