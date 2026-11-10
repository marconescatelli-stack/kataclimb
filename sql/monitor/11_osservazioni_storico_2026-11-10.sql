-- ═══════════════════════════════════════════════════════════════════════════════════════════════
-- sql/monitor/11 · OSSERVAZIONI DI CORSO: OGNI RISCRITTURA RESTA (Marco, 10 nov 2026)
-- MIGRAZIONE. Dopo la 10. Prova: 11_osservazioni_storico_PROVA.sql (BEGIN → corpo → verifiche → ROLLBACK), COMMIT col "vai".
--
-- Regola di Marco: le osservazioni non perdono mai il testo di prima. Ogni riscrittura dello stesso giorno resta separata,
-- con la sua ora e l'istruttore, come i report di sala. Lo storico già scritto non si tocca.
--
-- Prima: indice unico (persona, istruttore, giorno) per le osservazioni non di sala, e salva_osservazione faceva
-- ON CONFLICT … DO UPDATE: la seconda osservazione dello stesso giorno sovrascriveva la prima.
-- Adesso:
--  1. via l'indice unico (resta un indice normale per le letture); nessuna riga esistente cambia;
--  2. salva_osservazione inserisce sempre una riga nuova (created_at = ora in cui è scritta); il ramo Sala con Monitor
--     è quello della 10, invariato (lì l'unicità per giorno resta e ogni report è una riga con l'ora);
--  3. v_mio_diario_didattico (quello che l'allievo legge) dà anche scritta_alle, in fondo, e ordina per giorno e ora.
-- Nessun altro punto del DB contava su "una al giorno" (controllato: solo salva_osservazione usava quell'indice).
-- ═══════════════════════════════════════════════════════════════════════════════════════════════

DROP INDEX IF EXISTS public.osservazioni_allievo_oss_giorno_key;
CREATE INDEX IF NOT EXISTS osservazioni_allievo_autore_giorno_idx ON public.osservazioni_allievo (persona_id, istruttore_user_id, data);

CREATE OR REPLACE FUNCTION public.salva_osservazione(p_persona_id uuid, p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE v_id uuid; v_data date := coalesce((p->>'data')::date, CURRENT_DATE); v_turno uuid; v_testo text; v_prima int;
BEGIN
  -- 30 ott: 'monitor' e 'sala_monitor' sono la Sala con Monitor: nota e persona seguita insieme, nel turno aperto.
  -- Stesso permesso di monitor_segna (staff); viene prima del controllo "tuo allievo" perche' senza turno l'errore giusto e' sul turno.
  IF p->>'contesto' IN ('monitor','sala_monitor') THEN
    IF NOT is_staff() THEN RAISE EXCEPTION 'Solo staff'; END IF;
    SELECT id INTO v_turno FROM turni_monitor WHERE monitor_user_id=auth.uid() AND data=CURRENT_DATE AND fine IS NULL ORDER BY inizio DESC LIMIT 1;
    IF v_turno IS NULL THEN
      RAISE EXCEPTION 'Questa è una nota della Sala con Monitor ma il tuo turno non è aperto: non l''ho salvata. Apri il turno, oppure aggiungila da I miei turni.';
    END IF;
    v_testo := concat_ws(' · ', nullif(trim(p->>'temi_affrontati'),''), nullif(trim(p->>'trasformazione'),''), nullif(trim(p->>'note'),''),
                 nullif(trim(p->>'obiettivo'),''), nullif(trim(p->>'criticita'),''), nullif(trim(p->>'da_implementare'),''));
    IF coalesce(v_testo,'') = '' THEN RAISE EXCEPTION 'Scrivi su cosa avete lavorato e com''è andata'; END IF;
    v_id := _sala_annota(v_turno, p_persona_id, now(), to_char(now() AT TIME ZONE 'Europe/Rome','HH24:MI') || ' — ' || v_testo);
    RETURN jsonb_build_object('ok',true,'id',v_id,'data',CURRENT_DATE,'sala',true,'turno_id',v_turno);
  END IF;
  IF NOT (is_mio_allievo(p_persona_id) OR (is_staff() AND NOT is_monitor() AND in_turno_sala())) THEN RAISE EXCEPTION 'Non è un tuo allievo'; END IF;
  -- 10 nov 2026: ogni salvataggio è una riga nuova, quella di prima dello stesso giorno resta com'è
  SELECT count(*) INTO v_prima FROM osservazioni_allievo
   WHERE persona_id = p_persona_id AND istruttore_user_id = auth.uid() AND data = v_data AND contesto IS DISTINCT FROM 'sala_monitor';
  INSERT INTO osservazioni_allievo (persona_id, istruttore_user_id, data, contesto, obiettivo, interesse, aree_miglioramento,
    socializzazione, socializzazione_nota, fiducia, fiducia_nota, autostima, autostima_nota,
    concentrazione, concentrazione_nota, gestione_paura, gestione_paura_nota, note,
    temi_affrontati, criticita, trasformazione, da_implementare, per_allievo, visibile_allievo)
  VALUES (p_persona_id, auth.uid(), v_data, p->>'contesto', p->>'obiettivo', p->>'interesse', p->>'aree_miglioramento',
    (p->>'socializzazione')::smallint, p->>'socializzazione_nota', (p->>'fiducia')::smallint, p->>'fiducia_nota',
    (p->>'autostima')::smallint, p->>'autostima_nota', (p->>'concentrazione')::smallint, p->>'concentrazione_nota',
    (p->>'gestione_paura')::smallint, p->>'gestione_paura_nota', p->>'note',
    p->>'temi_affrontati', p->>'criticita', p->>'trasformazione', p->>'da_implementare', p->>'per_allievo',
    coalesce((p->>'visibile_allievo')::boolean, false))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('ok',true,'id',v_id,'data',v_data,'precedenti_oggi',v_prima);
END $function$;

CREATE OR REPLACE VIEW public.v_mio_diario_didattico AS
 SELECT o.id,
    o.data,
    o.contesto,
    o.temi_affrontati,
    o.trasformazione,
    o.per_allievo,
    COALESCE(i.nome, 'Istruttore'::text) AS istruttore,
    o.created_at AS scritta_alle
   FROM osservazioni_allievo o
     JOIN profile_data pd ON pd.persona_id = o.persona_id
     LEFT JOIN istruttori i ON i.user_id = o.istruttore_user_id
  WHERE pd.user_id = auth.uid() AND o.visibile_allievo = true AND o.contesto IS DISTINCT FROM 'sala_monitor'::text
  ORDER BY o.data DESC, o.created_at DESC;
