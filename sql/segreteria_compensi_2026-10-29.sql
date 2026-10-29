-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- Segreteria e compensi staff — consegna 29 ott 2026 (portale v3.148)
-- Principio (Marco, 29 ott): la segreteria è la verità.
--
-- DA LANCIARE A MANO da Marco nel SQL Editor di Supabase, TUTTO IN UNA VOLTA, dopo averlo letto.
-- Prima questo file, poi il push del portale (il portale v3.148 passa p_slot_ids ad allineamento_decidi:
-- con la funzione vecchia la scelta "registra" darebbe errore).
--
-- Il risultato finale è una tabellina PRIMA / DOPO con i controlli. Per leggere le viste che filtrano
-- per utente (auth.uid() / is_segreteria()) i controlli girano "come Marco" (staff_creator) solo dentro
-- questa transazione: set_config(..., true) vale fino al COMMIT.
-- ═══════════════════════════════════════════════════════════════════════════════════════════

BEGIN;

SELECT set_config('request.jwt.claims', '{"sub":"27b04151-93a7-4ecc-824c-fe337cc631a6","role":"authenticated"}', true);

DROP TABLE IF EXISTS _controllo_291026;
CREATE TEMP TABLE _controllo_291026 (n serial, momento text, controllo text, valore text);

-- ───────────────────────────── CONTROLLI PRIMA ─────────────────────────────
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '1. firma allineamento_decidi', string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
 WHERE s.nspname = 'public' AND p.proname = 'allineamento_decidi';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'PRIMA', '2. cambia_giorni_abbonamento blocca il cambio di numero di giorni', (prosrc LIKE '%cambia il prezzo%')::text
  FROM pg_proc WHERE oid = 'public.cambia_giorni_abbonamento(uuid,uuid[],text)'::regprocedure;
--@@CONTROLLI_PRIMA@@

-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- 1. "Da sistemare" → registra abbonamento: i giorni del corso
--    (caso Arianna Calcaterra, Corso Genitori: "Scegli almeno un giorno del corso" senza caselle)
--    allineamento_decidi prende p_slot_ids e lo passa a registra_abbonamento.
--    Un parametro in più = una funzione nuova (overload): si toglie la firma vecchia e si ricrea.
--    SECURITY DEFINER, search_path e permessi come prima (postgres, authenticated, service_role).
-- ═══════════════════════════════════════════════════════════════════════════════════════════
DROP FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date);

CREATE FUNCTION public.allineamento_decidi(p_id uuid, p_azione text, p_metodo text DEFAULT NULL::text, p_importo numeric DEFAULT NULL::numeric, p_al date DEFAULT NULL::date, p_risposta text DEFAULT NULL::text, p_tipo text DEFAULT NULL::text, p_dal date DEFAULT NULL::date, p_slot_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v allineamento_proposte; v_met text; v_tipo text; v_dal date; v_al date; v_imp numeric;
  r jsonb; v_pag abbonamenti_pagamenti; v_isc iscrizioni_minori; v_esito text; v_lbl text;
begin
  if not public.is_segreteria() then raise exception 'Permesso negato: solo segreteria'; end if;
  select * into v from allineamento_proposte where id = p_id for update;
  if not found then raise exception 'Voce non trovata'; end if;
  if v.stato <> 'aperta' then raise exception 'Questa voce e'' gia'' chiusa (%)', v.stato; end if;

  v_tipo := coalesce(nullif(p_tipo,''), v.tipo_abbonamento);
  v_met  := lower(coalesce(nullif(p_metodo,''), v.metodo));
  if v_met = 'bancomat' then v_met := 'pos'; end if;
  if v_met is not null and v_met not in ('contanti','pos','bonifico') then
    raise exception 'Metodo non valido: contanti, bancomat o bonifico';
  end if;
  select label into v_lbl from abbonamenti_tipi where tipo = v_tipo;

  -- ---------- REGISTRA: crea l'abbonamento pagato adesso ----------
  if p_azione = 'registra' then
    if v.categoria = 'errore_elenco' then raise exception 'Questa voce riguarda il tuo foglio: correggilo e premi HO CORRETTO IL FOGLIO'; end if;
    if v.persona_id is null then raise exception 'La persona non e'' nel portale: prima inseriscila (Inserisci contatto)'; end if;
    if v_tipo is null then raise exception 'Scegli il tipo di abbonamento'; end if;
    v_dal := coalesce(p_dal, v.dal);
    v_al  := coalesce(p_al, v.al);
    v_imp := coalesce(p_importo, v.importo);
    if v_dal is null then raise exception 'Scrivi da quando vale'; end if;
    if v_al  is null then raise exception 'Scrivi fino a quando vale'; end if;
    if v_imp is null then raise exception 'Scrivi l''importo'; end if;
    if v_met is null then raise exception 'Scegli come ha pagato: contanti, bancomat o bonifico'; end if;

    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and tipo_abbonamento = v_tipo and dal = v_dal and al = v_al limit 1;
    if found then
      update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, deciso_da=auth.uid(), deciso_il=now(),
             risposta=coalesce(p_risposta,risposta), esito='Era gia'' registrato nel portale: nessun doppione'
       where id = p_id;
      return jsonb_build_object('success',true,'gia_registrato',true,'pagamento_id',v_pag.id,
        'esito','Era già registrato nel portale: nessun doppione');
    end if;

    -- 29 ott: i giorni del corso scelti nella finestra (vuoto = null: per un rinnovo restano quelli che ha)
    r := public.registra_abbonamento(v.persona_id, v_tipo, nullif(p_slot_ids, '{}'::uuid[]), v_dal, v_al, v_imp, v_met,
           'Console allineamento — notte ' || to_char(v.notte,'DD/MM/YYYY') || ' riga ' || v.n);
    v_esito := 'Registrato: ' || coalesce(v_lbl, v_tipo) || ' ' || to_char(v_dal,'DD/MM') || '–' || to_char(v_al,'DD/MM')
               || ', ' || trim(to_char(v_imp,'FM999990.00')) || ' € ' || case v_met when 'pos' then 'bancomat' else v_met end;
    update allineamento_proposte
       set stato='registrata', pagamento_id=(r->>'pagamento_id')::uuid, tipo_abbonamento=v_tipo, dal=v_dal, al=v_al,
           importo=v_imp, metodo=v_met, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito
     where id = p_id;
    return r || jsonb_build_object('esito', v_esito);

  -- ---------- PAGATO: il pagamento c'e' ma senza metodo / iscrizione non pagata ----------
  elsif p_azione = 'pagato' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    if v_met is null then raise exception 'Scegli come ha pagato: contanti, bancomat o bonifico'; end if;
    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and (v_tipo is null or tipo_abbonamento = v_tipo) and metodo is null
     order by al desc, registrato_il desc limit 1;
    if not found then
      raise exception 'Nel portale non c''e'' un pagamento in attesa da segnare: usa REGISTRA per inserirlo';
    end if;
    update abbonamenti_pagamenti
       set metodo = v_met, importo_eur = coalesce(p_importo, importo_eur),
           note = concat_ws(E'\n', note, 'Segnato pagato dalla segreteria (console allineamento) il ' || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY'))
     where id = v_pag.id;
    update iscrizioni_minori set paid = true where id = v_pag.iscrizione_id;
    v_esito := 'Segnato pagato: ' || coalesce(v_lbl, v_pag.tipo_abbonamento) || ' ' || to_char(v_pag.dal,'DD/MM') || '–' || to_char(v_pag.al,'DD/MM')
               || ', ' || trim(to_char(coalesce(p_importo, v_pag.importo_eur),'FM999990.00')) || ' € ' || case v_met when 'pos' then 'bancomat' else v_met end;
    update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, metodo=v_met, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'pagamento_id',v_pag.id,'esito',v_esito);

  -- ---------- CORREGGI IMPORTO: l'importo nel portale e' sbagliato ----------
  elsif p_azione = 'correggi_importo' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    if p_importo is null or p_importo < 0 then raise exception 'Scrivi l''importo giusto'; end if;
    select * into v_pag from abbonamenti_pagamenti
     where persona_id = v.persona_id and (v_tipo is null or tipo_abbonamento = v_tipo)
       and (v.dal is null or (dal <= v.dal and al >= v.dal))
     order by al desc, registrato_il desc limit 1;
    if not found then raise exception 'Non trovo il pagamento da correggere: usa REGISTRA'; end if;
    update abbonamenti_pagamenti
       set importo_eur = p_importo,
           metodo = coalesce(v_met, metodo),
           note = concat_ws(E'\n', note, 'Importo corretto dalla segreteria (console allineamento) il '
                  || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY') || ': era ' || trim(to_char(v_pag.importo_eur,'FM999990.00')) || ' €')
     where id = v_pag.id;
    if v_met is not null then update iscrizioni_minori set paid = true where id = v_pag.iscrizione_id; end if;
    v_esito := 'Importo corretto: ' || trim(to_char(v_pag.importo_eur,'FM999990.00')) || ' € → ' || trim(to_char(p_importo,'FM999990.00')) || ' €';
    update allineamento_proposte set stato='registrata', pagamento_id=v_pag.id, importo=p_importo, risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'pagamento_id',v_pag.id,'esito',v_esito);

  -- ---------- CHIUDI: non frequenta piu' ----------
  elsif p_azione = 'chiudi' then
    if v.persona_id is null then raise exception 'La persona non e'' nel portale'; end if;
    select * into v_isc from iscrizioni_minori
     where persona_id = v.persona_id and status = 'attiva' and (v_tipo is null or tipo_abbonamento = v_tipo)
     order by data_fine desc nulls first limit 1;
    if not found then raise exception 'Non trovo un abbonamento attivo da chiudere'; end if;
    update iscrizioni_minori
       set status = 'terminata',
           note = concat_ws(E'\n', note, 'Chiuso dalla segreteria (console allineamento) il '
                  || to_char(now() at time zone 'Europe/Rome','DD/MM/YYYY') || coalesce(': ' || nullif(trim(p_risposta),''), ''))
     where id = v_isc.id;
    v_esito := 'Chiuso: ' || coalesce((select label from abbonamenti_tipi where tipo = v_isc.tipo_abbonamento), v_isc.tipo_abbonamento) || ' non più attivo';
    update allineamento_proposte set stato='fatto', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=v_esito where id = p_id;
    return jsonb_build_object('success',true,'iscrizione_id',v_isc.id,'esito',v_esito);

  elsif p_azione = 'fatto' then
    update allineamento_proposte set stato='fatto', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now(), esito=coalesce(esito,'Sistemato') where id = p_id;

  elsif p_azione = 'rispondi' then
    if coalesce(trim(p_risposta),'') = '' then raise exception 'Scrivi la risposta'; end if;
    update allineamento_proposte set stato='risposta', risposta=p_risposta,
           deciso_da=auth.uid(), deciso_il=now() where id = p_id;

  elsif p_azione = 'scarta' then
    update allineamento_proposte set stato='scartata', risposta=coalesce(p_risposta,risposta),
           deciso_da=auth.uid(), deciso_il=now() where id = p_id;

  else
    raise exception 'Azione % non valida', p_azione;
  end if;

  return jsonb_build_object('success', true, 'azione', p_azione);
end $function$;

-- permessi come la firma vecchia: niente PUBLIC né anon (Supabase li darebbe in automatico a una funzione nuova)
REVOKE ALL ON FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.allineamento_decidi(uuid, text, text, numeric, date, text, text, date, uuid[]) TO authenticated, service_role;
-- ═══════════════════════════════════════════════════════════════════════════════════════════
-- 2. "Cambia giorni": la segreteria può cambiare anche QUANTI giorni
--    (caso Marina Ungari, Corso Bambini: lun+mer per errore, fa solo il mercoledì)
--    Via la guardia "stesso numero di giorni". Restano: solo segreteria, abbonamento attivo, tipo con
--    giorni, almeno un giorno, slot del tipo giusto e attivi, capienza. Importo, scadenza, pagato e
--    abbonamenti_pagamenti NON si toccano: la segreteria sa cosa è stato pagato.
--    CREATE OR REPLACE: stessa firma, i permessi restano.
-- ═══════════════════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION public.cambia_giorni_abbonamento(p_iscrizione_id uuid, p_slot_ids uuid[], p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_isc iscrizioni_minori; t abbonamenti_tipi;
  v_sid uuid; v_slot record; v_occ int;
  v_vecchi uuid[]; v_nuovi uuid[];
  v_txt_vecchi text; v_txt_nuovi text; v_riga text;
  g text[] := ARRAY['lun','mar','mer','gio','ven','sab','dom'];
BEGIN
  IF NOT is_segreteria_piena() THEN RAISE EXCEPTION 'Permesso negato: solo segreteria'; END IF;

  SELECT * INTO v_isc FROM iscrizioni_minori WHERE id = p_iscrizione_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento % non trovato', p_iscrizione_id; END IF;
  IF v_isc.status <> 'attiva' THEN RAISE EXCEPTION 'L''abbonamento non è attivo: non si possono cambiare i giorni'; END IF;

  SELECT * INTO t FROM abbonamenti_tipi WHERE tipo = v_isc.tipo_abbonamento;
  IF NOT FOUND THEN RAISE EXCEPTION 'Abbonamento senza tipo: sistemalo con "Abbonamento o corso"'; END IF;
  IF coalesce(array_length(t.slot_ammessi,1),0) = 0 THEN RAISE EXCEPTION '% non ha giorni da cambiare', t.label; END IF;

  SELECT coalesce(array_agg(DISTINCT x), '{}') INTO v_nuovi FROM unnest(p_slot_ids) x WHERE x IS NOT NULL;
  IF coalesce(array_length(v_nuovi,1),0) = 0 THEN RAISE EXCEPTION 'Scegli almeno un giorno'; END IF;

  SELECT coalesce(array_agg(slot_id), '{}') INTO v_vecchi FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;

  IF v_nuovi @> v_vecchi AND v_vecchi @> v_nuovi THEN RAISE EXCEPTION 'I giorni sono già questi: nessun cambio'; END IF;
  -- 29 ott: tolta la guardia "stesso numero di giorni" (la segreteria è la verità: niente prezzo da ricalcolare)

  FOREACH v_sid IN ARRAY v_nuovi LOOP
    SELECT id, tipo_corso, fascia, status, capienza_max, giorno_settimana, ora_inizio INTO v_slot
      FROM corsi_attivi_settimanali WHERE id = v_sid;
    IF NOT FOUND THEN RAISE EXCEPTION 'Giorno/slot % non trovato', v_sid; END IF;
    IF v_slot.status <> 'attivo' THEN RAISE EXCEPTION 'Il giorno % ore % non è attivo', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'); END IF;
    IF NOT (v_slot.tipo_corso||'/'||v_slot.fascia = ANY(t.slot_ammessi) OR v_slot.tipo_corso||'/*' = ANY(t.slot_ammessi)) THEN
      RAISE EXCEPTION 'Il giorno % ore % non fa parte di %', g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI'), t.label;
    END IF;
    IF v_slot.capienza_max IS NOT NULL AND NOT (v_sid = ANY(v_vecchi)) THEN
      SELECT count(*) INTO v_occ FROM iscrizioni_minori_slot ims JOIN iscrizioni_minori im ON im.id = ims.iscrizione_id
       WHERE ims.slot_id = v_sid AND im.status = 'attiva' AND im.id <> p_iscrizione_id;
      IF v_occ >= v_slot.capienza_max THEN
        RAISE EXCEPTION 'Pieno (%/%): % ore %', v_occ, v_slot.capienza_max, g[v_slot.giorno_settimana], to_char(v_slot.ora_inizio,'HH24:MI');
      END IF;
    END IF;
  END LOOP;

  SELECT coalesce(string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio), 'nessuno')
    INTO v_txt_vecchi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_vecchi);
  SELECT string_agg(g[s.giorno_settimana]||' '||to_char(s.ora_inizio,'HH24:MI'), ' + ' ORDER BY s.giorno_settimana, s.ora_inizio)
    INTO v_txt_nuovi FROM corsi_attivi_settimanali s WHERE s.id = ANY(v_nuovi);

  -- tipo fermo PRIMA di toccare gli slot (il trigger su INSERT ricalcola solo se tipo_da_slot)
  UPDATE iscrizioni_minori SET tipo_da_slot = false WHERE id = p_iscrizione_id;

  DELETE FROM iscrizioni_minori_slot WHERE iscrizione_id = p_iscrizione_id;
  INSERT INTO iscrizioni_minori_slot (iscrizione_id, slot_id) SELECT p_iscrizione_id, unnest(v_nuovi);

  v_riga := '['||to_char(CURRENT_DATE,'DD/MM/YYYY')||' giorni cambiati: '||v_txt_vecchi||' → '||v_txt_nuovi
            ||CASE WHEN nullif(trim(p_note),'') IS NOT NULL THEN ' · '||trim(p_note) ELSE '' END||']';
  UPDATE iscrizioni_minori SET note = concat_ws(E'\n', note, v_riga) WHERE id = p_iscrizione_id;

  RETURN jsonb_build_object('success', true, 'iscrizione_id', p_iscrizione_id, 'tipo', t.tipo, 'label', t.label,
    'prima', v_txt_vecchi, 'dopo', v_txt_nuovi, 'scadenza', v_isc.data_fine);
END $function$;
--@@CORPO@@

-- ───────────────────────────── CONTROLLI DOPO ─────────────────────────────
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '1. firma allineamento_decidi (deve finire con p_slot_ids uuid[])', string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
 WHERE s.nspname = 'public' AND p.proname = 'allineamento_decidi';
INSERT INTO _controllo_291026 (momento, controllo, valore)
SELECT 'DOPO', '2. cambia_giorni_abbonamento blocca il cambio di numero di giorni (deve essere false)', (prosrc LIKE '%cambia il prezzo%')::text
  FROM pg_proc WHERE oid = 'public.cambia_giorni_abbonamento(uuid,uuid[],text)'::regprocedure;
--@@CONTROLLI_DOPO@@

COMMIT;

SELECT momento, controllo, valore FROM _controllo_291026 ORDER BY controllo, n;
